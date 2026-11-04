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
import IOKit
import Security

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
    /// The person asked to leave the joined zone and CloudKit has not answered yet.
    @ObservationIgnored private var leaving = false
    /// Owners whose share this Mac looked up this session, found or not.
    @ObservationIgnored private var lookedUpOwners: Set<String> = []
    /// A zone fetch in the current fetch failed, so a fetch of everything is not complete yet.
    @ObservationIgnored private var fetchFailed = false
    /// Items already reported as too large for iCloud.
    @ObservationIgnored private var reportedTooLarge: Set<UUID> = []
    @ObservationIgnored private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "SpaceSync")
    /// This Mac's kind, such as "iMac" or "MacBook Pro", which every save carries.
    @ObservationIgnored private let deviceName = SpaceSyncDevice.name(productName: SpaceSyncManager.productName, model: SpaceSyncManager.model)

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

    private static let leaveBeforeInviting = "Leave the shared sync before inviting others."

    /// Shares this account's zone with the account that has this code, making the share on the
    /// first invite. Switching iCloud account, or joining another account's sync, while it runs
    /// stops it before its next write, and it reports no invite.
    func invite(code text: String) async -> SpaceSyncInviteResult {
        guard let container, engine != nil, status.availability == .available, let account = state.account else {
            return .failed(message: "iCloud is not available right now.")
        }
        guard state.database == .private else { return .failed(message: Self.leaveBeforeInviting) }
        guard let code = SpaceSyncInviteCode.parse(text) else {
            return .failed(message: "That is not an invite code. Copy it again from the Mac you are inviting.")
        }
        func interrupted() -> SpaceSyncInviteResult? {
            if state.account != account {
                return .failed(message: "The iCloud account changed before the invite finished. Invite again.")
            }
            return state.database == .private ? nil : .failed(message: Self.leaveBeforeInviting)
        }
        do {
            let existing = try await zoneShare(in: container)
            let participants = existing?.participants.map {
                (recordName: $0.userIdentity.userRecordID?.recordName, status: Self.status($0.acceptanceStatus))
            } ?? []
            var invitee: CKShare.Participant?
            switch SpaceSyncInviteDecision(code: code, account: account, participants: participants) {
            case .ownCode:
                return .failed(message: "That is this iCloud account's own code. Copy the code from the Mac you are inviting.")
            case .alreadyInvited:
                break
            case .invite:
                invitee = try await participant(code, in: container)
                if invitee == nil {
                    return .failed(message: "No iCloud account has that code. Copy it again from the Mac you are inviting.")
                }
            }
            if let interrupted = interrupted() { return interrupted }
            var share: CKShare
            if let existing {
                share = try await onlyInvited(existing, in: container)
            } else {
                share = try await createShare(in: container)
            }
            if let invitee {
                if let interrupted = interrupted() { return interrupted }
                share = try await adding(invitee, as: code, to: share, in: container)
            }
            if let interrupted = interrupted() { return interrupted }
            shareChanged(share)
            guard let link = share.url else { return .failed(message: "iCloud gave the share no link. Invite again.") }
            return .invited(link: link)
        } catch {
            log.error("Space sync invite error \((error as? CKError)?.code.rawValue ?? -1, privacy: .public)")
            return .failed(message: Self.text(error))
        }
    }

    /// The participant CloudKit makes for the account with this user record name, nil when no
    /// account has it: CloudKit then fails that one lookup with Invalid Arguments (12).
    private func participant(_ code: String, in container: CKContainer) async throws -> CKShare.Participant? {
        let found = OSAllocatedUnfairLock<Result<CKShare.Participant, Error>?>(initialState: nil)
        return try await withCheckedThrowingContinuation { continuation in
            let operation = CKFetchShareParticipantsOperation(userIdentityLookupInfos: [
                CKUserIdentity.LookupInfo(userRecordID: CKRecord.ID(recordName: code)),
            ])
            operation.perShareParticipantResultBlock = { _, result in found.withLock { $0 = result } }
            operation.fetchShareParticipantsResultBlock = { result in
                switch (found.withLock { $0 }, result) {
                case (.success(let participant)?, _):
                    continuation.resume(returning: participant)
                case (.failure(let error as CKError)?, _) where error.code == .invalidArguments:
                    continuation.resume(returning: nil)
                case (.failure(let error)?, _), (nil, .failure(let error)):
                    continuation.resume(throwing: error)
                case (nil, .success):
                    continuation.resume(returning: nil)
                }
            }
            container.add(operation)
        }
    }

    /// The share saved with this participant able to change the spaces, in place of any earlier
    /// participant with the same code, such as one removed before.
    private func adding(_ participant: CKShare.Participant, as code: String, to share: CKShare,
                        in container: CKContainer) async throws -> CKShare {
        for old in share.participants where old.userIdentity.userRecordID?.recordName == code {
            share.removeParticipant(old)
        }
        participant.permission = .readWrite
        participant.role = .privateUser
        share.addParticipant(participant)
        let saved = try await container.privateCloudDatabase.modifyRecords(saving: [share], deleting: []).saveResults[share.recordID]?.get()
        guard let saved = saved as? CKShare else { throw CKError(.internalError) }
        return saved
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
            } catch let error as CKError where error.code == .unknownItem {
                note(error, as: SpaceSyncErrorText.notInvited)
            } catch {
                note(error)
            }
        }
    }

    /// A share the person opened from a link, accepted in the system's prompt, or pasted in
    /// Settings. Nothing is accepted or sent before the person agrees.
    func accept(_ metadata: CKShare.Metadata) {
        guard let container else { return }
        let zone = metadata.share.recordID.zoneID
        switch state.acceptance(containerID: metadata.containerIdentifier, zoneName: zone.zoneName, zoneOwner: zone.ownerName,
                                isOwner: metadata.participantRole == .owner,
                                zoneWide: metadata.share.recordID.recordName == CKRecordNameZoneWideShare,
                                readWrite: metadata.participantPermission == .readWrite) {
        case .join(let owner):
            let ownerName = metadata.ownerIdentity.nameComponents.flatMap(Self.name)
            guard let moving = askToJoin(ownerName: ownerName) else { return }
            Task {
                do {
                    if metadata.participantStatus != .accepted {
                        _ = try await container.accept([metadata])[metadata]?.get()
                    }
                    try await join(owner: owner, ownerName: ownerName, moving: moving, in: container)
                } catch {
                    note(error)
                }
            }
            return
        case .ownShare:
            state.lastError = "That link shares this iCloud account's own spaces."
        case .readOnly:
            state.lastError = "That link lets this iCloud account only view the spaces. Ask the person who shared them to allow changes."
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
        guard let container, state.database == .shared, !leaving else { return }
        leaving = true
        Task {
            defer { leaving = false }
            do {
                _ = try await container.sharedCloudDatabase.deleteRecord(withID: state.shareRecordID)
            } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            } catch {
                return note(error)
            }
            endSharedSync(message: nil)
        }
    }

    /// Back to this account's own zone, once, whichever of leaving and the joined zone going
    /// away comes first.
    private func endSharedSync(message: String?) {
        guard state.database == .shared else { return }
        state.leaveSharedZone(in: tabs.tree)
        state.lastError = message
        restartEngine()
        scheduleSave()
    }

    /// The share again open to invited people only, should it have been opened to anyone with
    /// its link elsewhere.
    private func onlyInvited(_ share: CKShare, in container: CKContainer) async throws -> CKShare {
        guard share.publicPermission != .none else { return share }
        share.publicPermission = .none
        let saved = try await container.privateCloudDatabase.modifyRecords(saving: [share], deleting: []).saveResults[share.recordID]?.get()
        guard let saved = saved as? CKShare else { throw CKError(.internalError) }
        return saved
    }

    private static var model: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "" }
        return String(cString: bytes)
    }

    /// The product name Apple silicon Macs report, such as "MacBook Pro (14-inch, 2021)".
    private static var productName: String? {
        let product = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard product != 0 else { return nil }
        defer { IOObjectRelease(product) }
        guard let data = IORegistryEntryCreateCFProperty(product, "product-name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data else { return nil }
        return String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
    }

    func removeOldCopies() {
        guard let container, state.database == .shared else { return }
        let ids = state.oldCopyRecords
        guard !ids.isEmpty else { return }
        let zone = CKRecordZone.ID(zoneName: SpaceSyncAvailability.zoneName, ownerName: CKCurrentUserDefaultName)
        Task {
            do {
                let results = try await container.privateCloudDatabase.modifyRecords(
                    saving: [], deleting: ids.map { CKRecord.ID(recordName: $0.uuidString, zoneID: zone) }, atomically: false).deleteResults
                var removed: Set<UUID> = []
                for (recordID, result) in results {
                    guard let id = UUID(uuidString: recordID.recordName) else { continue }
                    switch result {
                    case .success:
                        removed.insert(id)
                    case .failure(let error as CKError) where error.code == .unknownItem:
                        removed.insert(id)
                    case .failure(let error):
                        note(error)
                    }
                }
                state.removedOldCopies(removed)
            } catch let error as CKError where error.code == .zoneNotFound {
                state.removedOldCopies(ids)
            } catch {
                note(error)
            }
            publish()
            scheduleSave()
        }
    }

    /// A zone this account already joined on another Mac, which this Mac joins without a link.
    func joinOffer(_ owner: String) {
        guard let container, let offer = state.joinOffers.first(where: { $0.owner == owner }),
              let moving = askToJoin(ownerName: offer.name) else { return }
        Task {
            do {
                try await join(owner: owner, ownerName: offer.name, moving: moving, in: container)
            } catch {
                note(error)
            }
        }
    }

    /// An iCloud sharing link opened from another app, Nook being the default browser. A share of
    /// these spaces goes to the prompt to join; any other link is left to `open` as a page, and
    /// Settings says when this account is not invited to it. False when it is no sharing link at
    /// all.
    func openShareLink(_ url: URL, otherwise open: @escaping () -> Void) -> Bool {
        guard SpaceSyncShareLink.parse(url.absoluteString) != nil else { return false }
        guard let container else {
            open()
            return true
        }
        Task {
            do {
                if let metadata = try await container.shareMetadatas(for: [url])[url]?.get(),
                   metadata.containerIdentifier == SpaceSyncAvailability.containerID {
                    return accept(metadata)
                }
            } catch let error as CKError where error.code == .unknownItem {
                note(error, as: SpaceSyncErrorText.notInvited)
            } catch {
                log.error("Space sync link error \((error as? CKError)?.code.rawValue ?? -1, privacy: .public)")
            }
            open()
        }
        return true
    }

    /// Names the owner and how many spaces would move: true moves them, false joins without,
    /// nil cancels.
    private func askToJoin(ownerName: String?) -> Bool? {
        let count = state.spacesToMove(in: tabs.tree).count
        let owner = ownerName.map { "\($0)\u{2019}s" } ?? "another iCloud account\u{2019}s"
        let alert = NSAlert()
        alert.messageText = "Join \(owner) sync?"
        guard count > 0 else {
            alert.informativeText = "This Mac syncs the spaces in \(owner) sync, and changes made here reach everyone in it."
            alert.addButton(withTitle: "Join")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn ? false : nil
        }
        let spaces = count == 1 ? "the space" : "the \(count) spaces"
        alert.informativeText = "This Mac syncs the spaces in \(owner) sync. Move \(spaces) this Mac syncs now into it, for everyone in it to use, or keep them in this iCloud account, turned Off on this Mac."
        alert.addButton(withTitle: count == 1 ? "Join and Move 1 Space" : "Join and Move \(count) Spaces")
        alert.addButton(withTitle: "Join Without Moving")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return true
        case .alertSecondButtonReturn: return false
        default: return nil
        }
    }

    /// Joins after the person agreed: moving marks the spaces in this account's zone first,
    /// with this account's engine stopped so it cannot fetch those marks and turn the spaces
    /// Off here before they move.
    private func join(owner: String, ownerName: String?, moving: Bool, in container: CKContainer) async throws {
        let running = engine != nil
        if moving {
            let marked = state.markedOnMove(in: tabs.tree)
            dropEngine()
            do {
                try await markMoved(marked, to: owner, in: container)
            } catch {
                if running, let account = state.account { start(account: account) }
                throw error
            }
        }
        apply(state.join(owner: owner, ownerName: ownerName, moving: moving, tree: tabs.tree, kept: tabs.device.keptProfiles ?? []))
        dropEngine()
        if running, let account = state.account { start(account: account) }
        scheduleSave()
    }

    /// Looks up the share of each zone this account's spaces moved into, so Settings can offer
    /// to join it.
    private func lookUpOffers() {
        guard let container else { return }
        for owner in state.ownersToOffer.subtracting(lookedUpOwners) {
            lookedUpOwners.insert(owner)
            let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare,
                                      zoneID: CKRecordZone.ID(zoneName: SpaceSyncAvailability.zoneName, ownerName: owner))
            Task {
                guard let share = try? await container.sharedCloudDatabase.record(for: shareID) as? CKShare else { return }
                state.offered(owner: owner, name: share.owner.userIdentity.nameComponents.flatMap(Self.name))
                publish()
                scheduleSave()
            }
        }
    }

    /// Marks each moved space's record in this account's zone with the owner of the zone it moves
    /// into, so this account's other Macs turn the space Off and keep it.
    private func markMoved(_ ids: Set<UUID>, to owner: String, in container: CKContainer) async throws {
        guard !ids.isEmpty else { return }
        let database = container.privateCloudDatabase
        let zone = CKRecordZone.ID(zoneName: SpaceSyncAvailability.zoneName, ownerName: CKCurrentUserDefaultName)
        var marked: [CKRecord] = []
        for (_, result) in try await database.records(for: ids.map { CKRecord.ID(recordName: $0.uuidString, zoneID: zone) }) {
            switch result {
            case .success(let record):
                record[SyncRecord.Key.movedTo] = owner as NSString
                marked.append(record)
            case .failure(let error as CKError) where error.code == .unknownItem:
                continue
            case .failure(let error):
                throw error
            }
        }
        for (_, result) in try await database.modifyRecords(saving: marked, deleting: [], atomically: false).saveResults {
            _ = try result.get()
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
                    name: SpaceSyncParticipant.name(identityName: identity.nameComponents.flatMap(Self.name),
                                                    recordName: identity.userRecordID?.recordName),
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
        apply(state.receive(into: tabs.tree, kept: tabs.device.keptProfiles ?? []))
    }

    private func apply(_ inbound: SpaceSyncInbound) {
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
        if sent.failedRecordSaves.contains(where: { Self.isOutdatedSchema($0.error) }) { resend = [] }
        state.didSend(saved: saved, systemFields: fields, deleted: deleted)
        applyInbox()
        queuePending(only: resend)
        scheduleSave()
    }

    /// The zone is gone from iCloud: nothing here is deleted for it. After a reset of the
    /// person's encryption keys everything goes up again; otherwise every space turns Off. A
    /// joined zone gone means its owner stopped sharing or removed this account, and this Mac
    /// goes back to its own zone.
    private func zoneLost(reuploading: Bool) {
        guard state.database == .private else {
            return endSharedSync(message: leaving ? nil : "The shared sync ended. Your spaces stay on this Mac, turned Off.")
        }
        state.zoneLost(reuploading: reuploading, in: tabs.tree)
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
        if status.inviteCode != state.account { status.inviteCode = state.account }
        let spaces = state.cloudSpaces(in: tabs.tree)
        if cloudSpaces != spaces { cloudSpaces = spaces }
        let devices = state.cloudDevices
        if cloudDevices != devices { cloudDevices = devices }
        if status.mode != state.mode { status.mode = state.mode }
        let participants = state.sharing?.participants?.filter { !$0.isOwner } ?? []
        if status.participants != participants { status.participants = participants }
        if status.oldCopies != state.oldCopies { status.oldCopies = state.oldCopies }
        if status.joinOffers != state.joinOffers { status.joinOffers = state.joinOffers }
    }

    private func note(_ error: Error, as text: String? = nil) {
        log.error("Space sync error \((error as? CKError)?.code.rawValue ?? -1, privacy: .public)")
        state.lastError = text ?? Self.text(error)
        publish()
        scheduleSave()
    }

    /// The error as Settings words it.
    private static func text(_ error: Error) -> String {
        switch (error as? CKError)?.code {
        case .quotaExceeded?: return "iCloud storage is full. Nook syncs again when there is room."
        case .networkUnavailable?, .networkFailure?: return "No network connection. Nook syncs when it is back."
        case .requestRateLimited?, .zoneBusy?, .serviceUnavailable?: return "iCloud is busy. Nook tries again shortly."
        case .notAuthenticated?: return "Sign in to iCloud to sync spaces."
        default: return isOutdatedSchema(error) ? SpaceSyncErrorText.outdatedSchema : error.localizedDescription
        }
    }

    /// A save refused because iCloud's production schema lacks a field this build writes.
    private static func isOutdatedSchema(_ error: Error) -> Bool {
        guard let error = error as? CKError else { return false }
        let messages = [error.localizedDescription] + error.userInfo.values.compactMap { $0 as? String }
        return SpaceSyncErrorText.isOutdatedSchema(code: error.code.rawValue, message: messages.joined(separator: " "))
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
            let fetched = state.fetched(changes.modifications.map(\.record), deletions: changes.deletions.map { ($0.recordID, $0.recordType) })
            if let share = fetched.share { shareChanged(share) }
            if fetched.shareDeleted { shareDeleted() }
            scheduleSave()
        case .sentRecordZoneChanges(let sent):
            didSend(sent)
        case .sentDatabaseChanges(let sent):
            for failure in sent.failedZoneSaves { note(failure.error) }
        case .didFetchRecordZoneChanges(let fetched):
            if let error = fetched.error, fetched.zoneID == state.zoneID {
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
            lookUpOffers()
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
