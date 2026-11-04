// Licensed under GPL-3.0. See LICENSE.
//
//  SpaceSyncManager.swift
//  Nook
//
//  Syncs spaces between the person's Macs with CKSyncEngine, in one zone of the private
//  database, or in another iCloud account's zone through the shared database once this Mac joins
//  that account's share. NookTabsCore's SpaceSyncState decides what each record holds, how fetched
//  records merge and which zone to use; this moves records to and from CloudKit, shares the zone,
//  follows the iCloud account, and keeps the sync state in Sync/spaces.json beside the tabs. A
//  build without the iCloud entitlement never makes a CKContainer.
//

import AppKit
import CloudKit
import NookTabsCore
import NookUI
import NookWeb
import OSLog
import Security
import SystemConfiguration

@MainActor
@Observable
final class SpaceSyncManager: SpaceSyncControls {
    private(set) var status: SpaceSyncStatus
    private(set) var cloudSpaces: [SpaceSyncCloudSpace] = []
    private(set) var cloudDevices: [String] = []
    private var levels: [UUID: SpaceSyncLevel] = [:]

    @ObservationIgnored private let tabs: TabsController
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var state = SpaceSyncState()
    @ObservationIgnored private var container: CKContainer?
    @ObservationIgnored private var engine: CKSyncEngine?
    @ObservationIgnored private var queueTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var registeredForPushes = false
    /// Records of spaces moved into a joined zone are being deleted from this account's zone.
    @ObservationIgnored private var deletingPrivate = false
    @ObservationIgnored private var sharingPicker: NSSharingServicePicker?
    /// A zone fetch in the current fetch failed, so a fetch of everything is not complete yet.
    @ObservationIgnored private var fetchFailed = false
    /// Items already reported as too large for iCloud.
    @ObservationIgnored private var reportedTooLarge: Set<UUID> = []
    @ObservationIgnored private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "SpaceSync")
    /// This Mac's name as Sharing settings give it, which every save carries.
    @ObservationIgnored private let deviceName = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac"

    init(tabs: TabsController) {
        self.tabs = tabs
        fileURL = tabs.directory.deletingLastPathComponent()
            .appendingPathComponent("Sync", isDirectory: true)
            .appendingPathComponent("spaces.json")
        guard Self.isEntitled else {
            status = SpaceSyncStatus(availability: .needsSignedBuild)
            return
        }
        if case .readOnly = tabs.loadOutcome {
            status = SpaceSyncStatus(availability: .readOnlyTabs)
            return
        }
        state = Self.load(fileURL)
        if tabs.loadOutcome != .loaded { state.startOver() }
        status = SpaceSyncStatus(availability: .checking, lastSync: state.lastSync, lastError: state.lastError)
        levels = state.levels
        container = CKContainer(identifier: SpaceSyncAvailability.containerID)
        tabs.onTreeChanged = { [weak self] in self?.scheduleQueue() }
        _ = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAccount() }
        }
        checkAccount()
    }

    private static var isEntitled: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        func strings(_ key: String) -> [String]? {
            let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil)
            return value as? [String] ?? (value as? String).map { [$0] }
        }
        return SpaceSyncAvailability.isEntitled(
            containers: strings("com.apple.developer.icloud-container-identifiers"),
            services: strings("com.apple.developer.icloud-services"))
    }

    // MARK: - SpaceSyncControls

    func level(of spaceID: UUID) -> SpaceSyncLevel { levels[spaceID] ?? .off }

    func setLevel(_ level: SpaceSyncLevel, for spaceID: UUID) {
        let inICloud = cloudSpaces.contains { $0.id == spaceID && $0.canSyncHere }
        guard container != nil, tabs.tree.space(spaceID).map({ !$0.isAgent }) ?? inICloud else { return }
        if state.setLevel(level, for: spaceID) { restartEngine() }
        queuePending()
        scheduleSave()
    }

    func removeFromICloud(_ spaceID: UUID) {
        guard container != nil, state.catalog?.spaces[spaceID] != nil else { return }
        state.removeFromICloud(spaceID)
        queuePending()
        scheduleSave()
    }

    func syncReport() -> String {
        state.reportText(account: state.account)
    }

    // MARK: - Sharing

    func shareWithAnotherAccount() {
        guard let container, engine != nil, state.database == .private else { return }
        Task {
            do {
                let share: CKShare
                if let existing = try await zoneShare(in: container) {
                    share = existing
                } else {
                    share = try await createShare(in: container)
                }
                shareChanged(share)
                presentSharing(share, container: container)
            } catch {
                note(error)
            }
        }
    }

    func stopSharing() {
        guard let container, state.database == .private, state.sharing?.participants != nil else { return }
        Task {
            do {
                _ = try await container.privateCloudDatabase.deleteRecord(withID: state.shareRecordID)
            } catch let error as CKError where error.code == .unknownItem {
            } catch {
                return note(error)
            }
            state.stoppedSharing()
            publish()
            scheduleSave()
        }
    }

    func joinSharedSync(link: String) {
        guard let container else { return }
        guard let url = SpaceSyncShareLink.parse(link) else {
            state.lastError = "That is not an iCloud sharing link."
            return publish()
        }
        Task {
            do {
                if let metadata = try await container.shareMetadatas(for: [url])[url]?.get() { accept(metadata) }
            } catch {
                note(error)
            }
        }
    }

    /// A share the person opened from a link, or pasted in Settings.
    func accept(_ metadata: CKShare.Metadata) {
        guard let container else { return }
        let zone = metadata.share.recordID.zoneID
        switch state.acceptance(containerID: metadata.containerIdentifier, zoneName: zone.zoneName, zoneOwner: zone.ownerName,
                                isOwner: metadata.participantRole == .owner) {
        case .join(let owner):
            Task {
                do {
                    if metadata.participantStatus != .accepted {
                        _ = try await container.accept([metadata])[metadata]?.get()
                    }
                    state.join(owner: owner, ownerName: metadata.ownerIdentity.nameComponents.flatMap(Self.name))
                    restartEngine()
                    scheduleSave()
                } catch {
                    note(error)
                }
            }
            return
        case .ownShare:
            state.lastError = "That link shares this iCloud account's own spaces."
        case .notASpacesShare:
            state.lastError = "That link does not share Nook spaces."
        case .alreadyJoined:
            state.lastError = zone.ownerName == state.zoneOwner ? nil : "Leave the shared sync before joining another."
        case .sharingOwnZone:
            state.lastError = "Stop sharing this account's spaces before joining another account's."
        }
        publish()
    }

    func leaveSharedSync() {
        guard let container, state.database == .shared else { return }
        Task {
            do {
                _ = try await container.sharedCloudDatabase.deleteRecord(withID: state.shareRecordID)
            } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            } catch {
                return note(error)
            }
            state.leaveSharedZone()
            restartEngine()
            scheduleSave()
        }
    }

    private func zoneShare(in container: CKContainer) async throws -> CKShare? {
        do {
            return try await container.privateCloudDatabase.record(for: state.shareRecordID) as? CKShare
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    private func createShare(in container: CKContainer) async throws -> CKShare {
        let share = CKShare(recordZoneID: state.zoneID)
        share.publicPermission = .none
        share[CKShare.SystemFieldKey.title] = "Nook Spaces" as NSString
        let saved = try await container.privateCloudDatabase.modifyRecords(saving: [share], deleting: []).saveResults[share.recordID]?.get()
        guard let saved = saved as? CKShare else { throw CKError(.internalError) }
        return saved
    }

    /// The system's sharing popover at the pointer, which has just clicked Share in Settings:
    /// it invites people by Messages, Mail or a link, and only they can join.
    private func presentSharing(_ share: CKShare, container: CKContainer) {
        guard let window = NSApp.keyWindow, let view = window.contentView else { return }
        let provider = NSItemProvider()
        provider.registerCKShare(share, container: container, allowedSharingOptions: CKAllowedSharingOptions(
            allowedParticipantPermissionOptions: .readWrite, allowedParticipantAccessOptions: .specifiedRecipientsOnly))
        let picker = NSSharingServicePicker(items: [provider])
        sharingPicker = picker
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        picker.show(relativeTo: NSRect(origin: point, size: .zero), of: view, preferredEdge: .minY)
    }

    /// The zone's share is gone: the owner stopped sharing.
    private func shareDeleted() {
        if state.database == .shared {
            zoneLost(reuploading: false)
        } else {
            state.stoppedSharing()
            publish()
            scheduleSave()
        }
    }

    private func shareChanged(_ share: CKShare) {
        if state.database == .shared {
            state.sharing?.ownerName = share.owner.userIdentity.nameComponents.flatMap(Self.name)
        } else {
            state.shared(participants: share.participants.map { participant in
                let identity = participant.userIdentity
                return SpaceSyncParticipant(
                    name: identity.nameComponents.flatMap(Self.name) ?? identity.lookupInfo?.emailAddress ?? identity.lookupInfo?.phoneNumber ?? "Someone",
                    status: Self.status(participant.acceptanceStatus), isOwner: participant.role == .owner)
            })
        }
        publish()
        scheduleSave()
    }

    private static func name(_ components: PersonNameComponents) -> String? {
        let name = PersonNameComponentsFormatter.localizedString(from: components, style: .default)
        return name.isEmpty ? nil : name
    }

    private static func status(_ status: CKShare.ParticipantAcceptanceStatus) -> SpaceSyncParticipant.Status {
        switch status {
        case .pending: return .pending
        case .accepted: return .accepted
        case .removed: return .removed
        default: return .unknown
        }
    }

    /// Once the joined zone holds a moved space's records, deletes them from this account's zone.
    private func deleteMovedPrivateRecords() {
        guard let container, !deletingPrivate else { return }
        let ids = state.privateDeletions(in: tabs.tree)
        guard !ids.isEmpty else { return }
        deletingPrivate = true
        let zone = CKRecordZone.ID(zoneName: SpaceSyncAvailability.zoneName, ownerName: CKCurrentUserDefaultName)
        Task {
            defer { deletingPrivate = false }
            do {
                let results = try await container.privateCloudDatabase.modifyRecords(
                    saving: [], deleting: ids.map { CKRecord.ID(recordName: $0.uuidString, zoneID: zone) }, atomically: false).deleteResults
                var deleted: Set<UUID> = []
                for (recordID, result) in results {
                    guard let id = UUID(uuidString: recordID.recordName) else { continue }
                    switch result {
                    case .success:
                        deleted.insert(id)
                    case .failure(let error as CKError) where error.code == .unknownItem:
                        deleted.insert(id)
                    case .failure(let error):
                        note(error)
                    }
                }
                state.deletedFromPrivateZone(deleted)
            } catch let error as CKError where error.code == .zoneNotFound {
                state.deletedFromPrivateZone(ids)
            } catch {
                note(error)
            }
            scheduleSave()
        }
    }

    func syncNow() {
        guard let engine else { return checkAccount() }
        queuePending()
        Task {
            do {
                try await engine.fetchChanges()
                try await engine.sendChanges()
            } catch {
                note(error)
            }
        }
    }

    // MARK: - App

    /// A push for the private database's subscription: fetch now rather than at the next poll.
    func remoteNotification(_ userInfo: [AnyHashable: Any]) {
        guard let engine, CKNotification(fromRemoteNotificationDictionary: userInfo) != nil else { return }
        Task {
            do {
                try await engine.fetchChanges()
            } catch {
                note(error)
            }
        }
    }

    /// Writes the sync state now; the app calls it at quit, after the tabs are written.
    func flush() {
        guard container != nil else { return }
        saveState()
    }

    // MARK: - Account

    private func checkAccount() {
        guard let container else { return }
        Task {
            do {
                switch try await container.accountStatus() {
                case .available:
                    start(account: try await container.userRecordID().recordName)
                case .noAccount:
                    stop(.noAccount)
                case .restricted:
                    stop(.restricted)
                default:
                    status.availability = .unavailable
                }
            } catch {
                note(error)
                status.availability = .unavailable
            }
        }
    }

    private func start(account: String) {
        if let previous = state.account, previous != account {
            state.reset(account: account)
            dropEngine()
        }
        state.account = account
        status.availability = .available
        if !registeredForPushes {
            NSApplication.shared.registerForRemoteNotifications()
            registeredForPushes = true
        }
        guard engine == nil, let container else { return publish() }
        let serialization = state.catalog == nil ? nil
            : state.engine.flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        let engine = CKSyncEngine(CKSyncEngine.Configuration(
            database: container.database(with: state.databaseScope), stateSerialization: serialization, delegate: self))
        if serialization == nil {
            state.beginRefetch()
            if state.database == .private {
                engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: state.zoneID))])
            }
        }
        self.engine = engine
        applyInbox()
        queuePending()
        scheduleSave()
    }

    /// Signed out or restricted: the old account's sync state goes, and the spaces stay.
    private func stop(_ availability: SpaceSyncAvailability) {
        if state.account != nil {
            state.reset(account: nil)
            scheduleSave()
        }
        dropEngine()
        status.availability = availability
        publish()
    }

    private func dropEngine() {
        let old = engine
        engine = nil
        Task { await old?.cancelOperations() }
    }

    /// Starts over from an empty engine state, which fetches every record again.
    private func restartEngine() {
        state.engine = nil
        guard engine != nil, let account = state.account else { return }
        dropEngine()
        start(account: account)
    }

    // MARK: - Records

    private func recordID(_ id: UUID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.uuidString, zoneID: state.zoneID)
    }

    private func scheduleQueue() {
        queueTask?.cancel()
        queueTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.queuePending()
        }
    }

    /// Tells the engine what differs from iCloud, and takes back what no longer does. `only`
    /// limits additions to those records.
    private func queuePending(only ids: Set<UUID>? = nil) {
        state.prune(against: tabs.tree)
        let tooLarge = state.tooLarge(in: tabs.tree)
        if !tooLarge.isSubset(of: reportedTooLarge) {
            state.lastError = "A tab's address or title is too long for iCloud, so it stays on this Mac."
            scheduleSave()
        }
        reportedTooLarge = tooLarge
        publish()
        guard let engine else { return }
        let pending = state.pendingChanges(in: tabs.tree)
        let queued = engine.state.pendingRecordZoneChanges
        engine.state.remove(pendingRecordZoneChanges: queued.filter { change in
            switch change {
            case .saveRecord(let recordID): return UUID(uuidString: recordID.recordName).map { !pending.saves.contains($0) } ?? true
            case .deleteRecord(let recordID): return UUID(uuidString: recordID.recordName).map { !pending.deletes.contains($0) } ?? true
            @unknown default: return false
            }
        })
        let saves = ids.map { pending.saves.intersection($0) } ?? pending.saves
        let deletes = ids.map { pending.deletes.intersection($0) } ?? pending.deletes
        let known = Set(queued)
        let changes = saves.map { CKSyncEngine.PendingRecordZoneChange.saveRecord(recordID($0)) }
            + deletes.map { CKSyncEngine.PendingRecordZoneChange.deleteRecord(recordID($0)) }
        engine.state.add(pendingRecordZoneChanges: changes.filter { !known.contains($0) })
    }

    /// Merges fetched records into the tree, then writes the tree before the sync state, so the
    /// state on disk is never ahead of the tabs.
    private func applyInbox() {
        guard !state.inbox.isEmpty else { return }
        let inbound = state.receive(into: tabs.tree, kept: tabs.device.keptProfiles ?? [])
        if !inbound.change.isEmpty { tabs.apply(inbound.change) }
        for id in inbound.deletedSpaces {
            tabs.deleteSpace(id, keepingLeftProfile: true)
            if tabs.tree.space(id) != nil { state.setLevel(.off, for: id) }
        }
        tabs.saveNow()
        saveState()
        publish()
    }

    private func didSend(_ sent: CKSyncEngine.Event.SentRecordZoneChanges) {
        if sent.failedRecordSaves.contains(where: { $0.error.code == .zoneNotFound }) {
            return zoneLost(reuploading: false)
        }
        var saved: [SyncRecord] = []
        var fields: [UUID: Data] = [:]
        for record in sent.savedRecords {
            guard let synced = SyncRecord(record) else { continue }
            saved.append(synced)
            fields[synced.id] = record.archivedSystemFields
        }
        var deleted = sent.deletedRecordIDs.compactMap { UUID(uuidString: $0.recordName) }
        var resend: Set<UUID> = []
        for failure in sent.failedRecordSaves {
            guard let id = UUID(uuidString: failure.record.recordID.recordName) else { continue }
            switch failure.error.code {
            case .serverRecordChanged:
                guard let server = failure.error.serverRecord, let record = SyncRecord(server) else { continue }
                state.fetched(record, systemFields: server.archivedSystemFields)
                resend.insert(id)
            case .unknownItem:
                if state.systemFields[id] != nil { state.fetchedDeletion(id) }
            case .batchRequestFailed:
                resend.insert(id)
            default:
                state.refused(id, code: failure.error.code.rawValue)
                note(failure.error)
            }
        }
        for (recordID, error) in sent.failedRecordDeletes {
            if error.code == .unknownItem, let id = UUID(uuidString: recordID.recordName) {
                deleted.append(id)
            } else {
                note(error)
            }
        }
        state.didSend(saved: saved, systemFields: fields, deleted: deleted)
        applyInbox()
        queuePending(only: resend)
        deleteMovedPrivateRecords()
        scheduleSave()
    }

    /// The zone is gone from iCloud: nothing here is deleted for it. After a reset of the
    /// person's encryption keys everything goes up again; otherwise every space turns Off. A
    /// joined zone gone means its owner stopped sharing or removed this account, and this Mac
    /// goes back to its own zone.
    private func zoneLost(reuploading: Bool) {
        let joined = state.database == .shared
        state.zoneLost(reuploading: reuploading)
        if joined {
            state.lastError = "The shared sync ended. Your spaces stay on this Mac, turned Off."
            restartEngine()
            return scheduleSave()
        }
        if reuploading {
            engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: state.zoneID))])
        }
        queuePending()
        scheduleSave()
    }

    // MARK: - Status

    private func publish() {
        if levels != state.levels { levels = state.levels }
        if status.lastSync != state.lastSync { status.lastSync = state.lastSync }
        if status.lastError != state.lastError { status.lastError = state.lastError }
        let accountID = state.account.map(SpaceSyncCodec.accountID)
        if status.accountID != accountID { status.accountID = accountID }
        let spaces = state.cloudSpaces(in: tabs.tree)
        if cloudSpaces != spaces { cloudSpaces = spaces }
        let devices = state.cloudDevices
        if cloudDevices != devices { cloudDevices = devices }
        if status.mode != state.mode { status.mode = state.mode }
        let participants = state.sharing?.participants?.filter { !$0.isOwner } ?? []
        if status.participants != participants { status.participants = participants }
    }

    private func note(_ error: Error) {
        let code = (error as? CKError)?.code
        log.error("Space sync error \(code?.rawValue ?? -1, privacy: .public)")
        switch code {
        case .quotaExceeded?: state.lastError = "iCloud storage is full. Nook syncs again when there is room."
        case .networkUnavailable?, .networkFailure?: state.lastError = "No network connection. Nook syncs when it is back."
        case .requestRateLimited?, .zoneBusy?, .serviceUnavailable?: state.lastError = "iCloud is busy. Nook tries again shortly."
        case .notAuthenticated?: state.lastError = "Sign in to iCloud to sync spaces."
        default: state.lastError = error.localizedDescription
        }
        publish()
        scheduleSave()
    }

    private func finished() {
        status.isSyncing = false
        state.lastSync = Date()
        publish()
        scheduleSave()
    }

    // MARK: - Storage

    private static func load(_ url: URL) -> SpaceSyncState {
        guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(SpaceSyncState.self, from: data) else {
            return SpaceSyncState()
        }
        return state
    }

    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveState()
        }
    }

    private func saveState() {
        saveTask?.cancel()
        saveTask = nil
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: fileURL, options: .atomic)
        } catch {
            log.error("Space sync state not saved: \(String(describing: error), privacy: .public)")
        }
    }
}

extension SpaceSyncManager: CKSyncEngineDelegate {
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard syncEngine === engine else { return }
        switch event {
        case .stateUpdate(let update):
            state.engine = try? JSONEncoder().encode(update.stateSerialization)
            scheduleSave()
        case .accountChange(let change):
            switch change.changeType {
            case .signIn(let user), .switchAccounts(_, let user):
                start(account: user.recordName)
            case .signOut:
                stop(.noAccount)
            @unknown default:
                checkAccount()
            }
        case .fetchedDatabaseChanges(let changes):
            if let deletion = changes.deletions.first(where: { $0.zoneID == state.zoneID }) {
                zoneLost(reuploading: deletion.reason == .encryptedDataReset)
            }
        case .fetchedRecordZoneChanges(let changes):
            for modification in changes.modifications {
                if let share = modification.record as? CKShare {
                    shareChanged(share)
                    continue
                }
                guard let record = SyncRecord(modification.record) else { continue }
                state.fetched(record, systemFields: modification.record.archivedSystemFields)
            }
            for deletion in changes.deletions {
                if deletion.recordType == CKRecord.SystemType.share {
                    shareDeleted()
                    continue
                }
                if let id = UUID(uuidString: deletion.recordID.recordName) { state.fetchedDeletion(id) }
            }
            scheduleSave()
        case .sentRecordZoneChanges(let sent):
            didSend(sent)
        case .sentDatabaseChanges(let sent):
            for failure in sent.failedZoneSaves { note(failure.error) }
        case .didFetchRecordZoneChanges(let fetched):
            if let error = fetched.error {
                fetchFailed = true
                if error.code == .zoneNotFound {
                    zoneLost(reuploading: false)
                } else {
                    note(error)
                }
            }
        case .willFetchChanges:
            fetchFailed = false
            status.isSyncing = true
            state.lastError = nil
            state.beginReport()
        case .willSendChanges:
            status.isSyncing = true
            state.lastError = nil
        case .didFetchChanges:
            applyInbox()
            if !fetchFailed { state.endRefetch() }
            queuePending()
            deleteMovedPrivateRecords()
            finished()
        case .didSendChanges:
            finished()
        case .willFetchRecordZoneChanges:
            break
        @unknown default:
            break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard syncEngine === engine else { return nil }
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !changes.isEmpty else { return nil }
        let ids = Set(changes.compactMap { change -> UUID? in
            guard case .saveRecord(let recordID) = change else { return nil }
            return UUID(uuidString: recordID.recordName)
        })
        var records: [String: CKRecord] = [:]
        for (id, record) in state.outgoing(ids, in: tabs.tree, now: Date(), device: deviceName) {
            records[id.uuidString] = record.record(in: state.zoneID, systemFields: state.systemFields[id])
        }
        let gone = changes.filter { change in
            guard case .saveRecord(let recordID) = change else { return false }
            return records[recordID.recordName] == nil
        }
        syncEngine.state.remove(pendingRecordZoneChanges: gone)
        let batch = records
        let sending = changes.filter { change in
            guard case .saveRecord(let recordID) = change else { return true }
            return batch[recordID.recordName] != nil
        }
        var next = await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: sending) { batch[$0.recordName] }
        if next?.recordsToSave.contains(where: { $0.recordType == SyncRecord.RecordType.space.rawValue }) == true {
            next?.atomicByZone = true
        }
        return next
    }
}
