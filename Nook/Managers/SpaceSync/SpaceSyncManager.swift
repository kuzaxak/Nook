// Licensed under GPL-3.0. See LICENSE.
//
//  SpaceSyncManager.swift
//  Nook
//
//  Syncs spaces between the person's Macs with CKSyncEngine, in one zone of the private
//  database. NookTabsCore's SpaceSyncState decides what each record holds and how fetched records
//  merge; this moves records to and from CloudKit, follows the iCloud account, and keeps the sync
//  state in Sync/spaces.json beside the tabs. A build without the iCloud entitlement never makes
//  a CKContainer.
//

import AppKit
import CloudKit
import NookTabsCore
import NookUI
import NookWeb
import OSLog
import Security

@MainActor
@Observable
final class SpaceSyncManager: SpaceSyncControls {
    static let zoneID = CKRecordZone.ID(zoneName: "Spaces", ownerName: CKCurrentUserDefaultName)

    private(set) var status: SpaceSyncStatus
    private var levels: [UUID: SpaceSyncLevel] = [:]

    @ObservationIgnored private let tabs: TabsController
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var state = SpaceSyncState()
    @ObservationIgnored private var container: CKContainer?
    @ObservationIgnored private var engine: CKSyncEngine?
    @ObservationIgnored private var queueTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var registeredForPushes = false
    @ObservationIgnored private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "SpaceSync")

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
        if tabs.loadOutcome != .loaded {
            // A tree restored from a backup or started over is older than the records iCloud and
            // this Mac last agreed on; compared with them, every newer record would read as deleted.
            state.forgetRecords()
            state.engine = nil
        }
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
        guard container != nil, tabs.tree.space(spaceID)?.isAgent == false else { return }
        if state.setLevel(level, for: spaceID) { restartEngine() }
        queuePending()
        scheduleSave()
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
        let serialization = state.engine.flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        let engine = CKSyncEngine(CKSyncEngine.Configuration(
            database: container.privateCloudDatabase, stateSerialization: serialization, delegate: self))
        if serialization == nil {
            engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
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
        CKRecord.ID(recordName: id.uuidString, zoneID: Self.zoneID)
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
        var saved: [SyncRecord] = []
        var fields: [UUID: Data] = [:]
        for record in sent.savedRecords {
            guard let synced = SyncRecord(record) else { continue }
            saved.append(synced)
            fields[synced.id] = record.archivedSystemFields
        }
        var deleted = sent.deletedRecordIDs.compactMap { UUID(uuidString: $0.recordName) }
        var resend: Set<UUID> = []
        var zoneMissing = false
        for failure in sent.failedRecordSaves {
            guard let id = UUID(uuidString: failure.record.recordID.recordName) else { continue }
            switch failure.error.code {
            case .serverRecordChanged:
                guard let server = failure.error.serverRecord, let record = SyncRecord(server) else { continue }
                state.inbox.add(record, systemFields: server.archivedSystemFields)
                resend.insert(id)
            case .unknownItem:
                state.inbox.delete(id)
            case .zoneNotFound:
                zoneMissing = true
            default:
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
        if zoneMissing {
            state.forgetRecords()
            engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
            queuePending()
        } else {
            queuePending(only: resend)
        }
        scheduleSave()
    }

    /// The zone went from iCloud. Deleted by the person: every space stops syncing and stays
    /// here. Reset with the person's encryption keys: everything goes up again.
    private func zoneDeleted(_ deletion: CKDatabase.DatabaseChange.Deletion) {
        state.forgetRecords()
        if deletion.reason == .encryptedDataReset {
            engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        } else {
            state.levels = [:]
            state.levelTimes = [:]
        }
        queuePending()
        scheduleSave()
    }

    // MARK: - Status

    private func publish() {
        if levels != state.levels { levels = state.levels }
        if status.lastSync != state.lastSync { status.lastSync = state.lastSync }
        if status.lastError != state.lastError { status.lastError = state.lastError }
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
            if let deletion = changes.deletions.first(where: { $0.zoneID == Self.zoneID }) { zoneDeleted(deletion) }
        case .fetchedRecordZoneChanges(let changes):
            for modification in changes.modifications {
                guard let record = SyncRecord(modification.record) else { continue }
                state.inbox.add(record, systemFields: modification.record.archivedSystemFields)
            }
            for deletion in changes.deletions {
                if let id = UUID(uuidString: deletion.recordID.recordName) { state.inbox.delete(id) }
            }
            scheduleSave()
        case .sentRecordZoneChanges(let sent):
            didSend(sent)
        case .sentDatabaseChanges(let sent):
            for failure in sent.failedZoneSaves { note(failure.error) }
        case .didFetchRecordZoneChanges(let fetched):
            if let error = fetched.error {
                if error.code == .zoneNotFound {
                    syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
                } else {
                    note(error)
                }
            }
        case .willFetchChanges, .willSendChanges:
            status.isSyncing = true
            state.lastError = nil
        case .didFetchChanges:
            applyInbox()
            queuePending()
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
        for (id, record) in state.outgoing(ids, in: tabs.tree) {
            records[id.uuidString] = record.record(in: Self.zoneID, systemFields: state.systemFields[id])
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
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: sending) { batch[$0.recordName] }
    }
}
