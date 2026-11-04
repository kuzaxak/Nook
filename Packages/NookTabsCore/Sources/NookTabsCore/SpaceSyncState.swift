// Licensed under GPL-3.0. See LICENSE.
//
//  SpaceSyncState.swift
//  NookTabsCore
//
//  What one Mac keeps between syncs: each space's level here, the last version of every record
//  iCloud and this Mac agreed on, and the changes fetched but not yet applied. From these it
//  works out what to send, and how fetched records change the tree.
//

import Foundation

public struct SpaceSyncState: Codable, Equatable, Sendable {
    private typealias Key = SyncRecord.Key

    /// Fetched items that wait for their space to arrive, at most.
    static let maxWaiting = SpaceFile.maxItems

    /// Spaces this Mac syncs, and spaces it keeps out: an explicit Off for a space that is gone
    /// here keeps it from arriving again. A space with no entry is Off.
    public var levels: [UUID: SpaceSyncLevel] = [:]
    /// When the level of each space last changed here, in milliseconds.
    public var levelTimes: [UUID: Int64] = [:]
    /// The last version of each record iCloud and this Mac agreed on.
    public var shadow: [UUID: SyncRecord] = [:]
    /// CloudKit's system fields for each record in `shadow`, as the app archived them.
    public var systemFields: [UUID: Data] = [:]
    /// Records this Mac deleted from iCloud or saw deleted there, with when, in milliseconds.
    /// A deletion of one coming back is ignored, and one saved again goes out stamped with the
    /// time of that save. Kept as long as a tombstone.
    public var deletedInCloud: [UUID: Int64] = [:]
    /// Records a fetch of everything returned so far; nil when no such fetch is running.
    public var refetchSeen: Set<UUID>?
    /// CKSyncEngine's own state, as the app encoded it.
    public var engine: Data?
    /// The iCloud user this state belongs to.
    public var account: String?
    public var inbox = Inbox()
    public var lastSync: Date?
    public var lastError: String?
    /// Every record the zone holds, synced here or not. Nil in a state saved before there was
    /// one, so the app fetches everything again to build it.
    public var catalog: SpaceSyncCatalog?
    public var report: SpaceSyncReport?
    /// Sharing with another iCloud account; nil while this Mac syncs its own account's zone
    /// unshared.
    public var sharing: SpaceSyncSharing?

    /// Records fetched and not yet applied to the tree, kept with the engine's state so a quit
    /// in between loses none.
    public struct Inbox: Codable, Equatable, Sendable {
        public var records: [UUID: SyncRecord] = [:]
        public var systemFields: [UUID: Data] = [:]
        public var deletions: Set<UUID> = []

        public init() {}

        public var isEmpty: Bool { records.isEmpty && deletions.isEmpty }

        public mutating func add(_ record: SyncRecord, systemFields fields: Data?) {
            records[record.id] = record.normalized()
            systemFields[record.id] = fields
            deletions.remove(record.id)
        }

        public mutating func delete(_ id: UUID) {
            records[id] = nil
            systemFields[id] = nil
            deletions.insert(id)
        }
    }

    public init() {}

    public func level(of spaceID: UUID) -> SpaceSyncLevel { levels[spaceID] ?? .off }

    /// Sets a space's level here. Off and Favorites & Pinned forget what iCloud holds that this
    /// Mac no longer syncs, without deleting any of it. True when the level now takes in records
    /// this Mac ignored before, so the app fetches everything again. Off is kept even for a space
    /// with no level yet, so one in iCloud and not on this Mac stays out.
    @discardableResult
    public mutating func setLevel(_ level: SpaceSyncLevel, for spaceID: UUID, now: Date = Date()) -> Bool {
        let old = self.level(of: spaceID)
        guard level != old || levels[spaceID] == nil else { return false }
        levels[spaceID] = level
        levelTimes[spaceID] = SpaceSyncCodec.milliseconds(now)
        guard level == .off else {
            catalog?.removing.remove(spaceID)
            return old == .off || level == .everything
        }
        let items = shadow.values.filter { $0.type == .item && $0.uuid(Key.space) == spaceID }.map(\.id)
        for id in items + [spaceID] {
            shadow[id] = nil
            systemFields[id] = nil
        }
        return false
    }

    // MARK: - Fetching

    public mutating func fetched(_ record: SyncRecord, systemFields fields: Data?) {
        inbox.add(record, systemFields: fields)
        refetchSeen?.insert(record.id)
        catalog = catalog ?? SpaceSyncCatalog()
        catalog?.add(record.normalized())
    }

    public mutating func fetchedDeletion(_ id: UUID) {
        inbox.delete(id)
        catalog?.remove(id)
    }

    /// A fetch of every record starts, as an empty engine state makes.
    public mutating func beginRefetch() {
        refetchSeen = []
        catalog = catalog ?? SpaceSyncCatalog()
    }

    /// The fetch of every record finished: records iCloud did not return are no longer agreed
    /// on. Nothing here is deleted for them; what this Mac still has goes up again.
    public mutating func endRefetch() {
        guard let seen = refetchSeen else { return }
        refetchSeen = nil
        for id in shadow.keys where !seen.contains(id) {
            shadow[id] = nil
            systemFields[id] = nil
        }
        guard var catalog else { return }
        for id in Set(catalog.spaces.keys).union(catalog.items.keys) where !seen.contains(id) {
            catalog.remove(id)
        }
        self.catalog = catalog
    }

    // MARK: - Sending

    /// Records to save because they differ from what iCloud has, and records to delete because
    /// they are gone here. A record that only stops syncing here, such as a tab on a link that is
    /// not a web address, is never deleted.
    public func pendingChanges(in tree: TabTree) -> (saves: Set<UUID>, deletes: Set<UUID>) {
        let local = records(of: tree)
        let saves = local.compactMap { id, record in shadow[id]?.sameValues(as: record) == true ? nil : id }
        let deletes = Set(shadow.keys.filter { local[$0] == nil && isGone($0, in: tree) })
        return (Set(saves), deletes.union(catalog?.removals.subtracting(saves) ?? []))
    }

    /// The records to save, each group timed after the version it replaces and naming the Mac
    /// that saves it. One saved again after it was deleted from iCloud is stamped `now`.
    public func outgoing(_ ids: Set<UUID>, in tree: TabTree, now: Date = Date(), device: String? = nil) -> [UUID: SyncRecord] {
        let stamp = SpaceSyncCodec.milliseconds(now)
        return records(of: tree).filter { ids.contains($0.key) }.mapValues { record in
            var out = SyncMerge.outgoing(record, shadow: shadow[record.id])
            if shadow[record.id] == nil, deletedInCloud[record.id] != nil {
                out.times = record.times.mapValues { _ in stamp }
            }
            out.fields[Key.device] = device.map { .string($0) }
            return out
        }
    }

    /// iCloud took these saves and deletions. A save this Mac no longer syncs, such as a tab moved
    /// out of a synced section or a space turned Off meanwhile, is not kept.
    public mutating func didSend(saved: [SyncRecord], systemFields fields: [UUID: Data], deleted: [UUID], now: Date = Date()) {
        for record in saved {
            deletedInCloud[record.id] = nil
            refetchSeen?.insert(record.id)
            catalog = catalog ?? SpaceSyncCatalog()
            catalog?.add(record.normalized())
            catalog?.refused[record.id] = nil
            guard syncs(record) else {
                shadow[record.id] = nil
                systemFields[record.id] = nil
                continue
            }
            shadow[record.id] = record.normalized()
            systemFields[record.id] = fields[record.id]
        }
        for id in deleted {
            shadow[id] = nil
            systemFields[id] = nil
            deletedInCloud[id] = SpaceSyncCodec.milliseconds(now)
            catalog?.remove(id)
        }
    }

    // MARK: - Receiving

    /// Applies the inbox: merges each record with this Mac's version, field group by field group,
    /// and returns the new value of every record it changed. A deletion beats an edit, and so
    /// does a deletion here that has not gone out yet. A tab is never closed because another Mac
    /// moved it where this Mac does not sync: it moves to the root of that section, or stays and
    /// its record goes back up. Items wait for a space that has not arrived. When two moves put
    /// folders inside each other, the later move is undone.
    public mutating func receive(into tree: TabTree, kept: [KeptProfile] = [], now: Date = Date()) -> SpaceSyncInbound {
        let fetched = inbox
        inbox = Inbox()
        var result = SpaceSyncInbound()
        guard !fetched.isEmpty else { return result }
        let local = records(of: tree)
        var working = tree
        var touched: [UUID] = []
        var positionTimes: [UUID: Int64] = [:]

        func keep(_ remote: SyncRecord) {
            shadow[remote.id] = remote
            systemFields[remote.id] = fetched.systemFields[remote.id]
            deletedInCloud[remote.id] = nil
        }
        func forget(_ id: UUID) {
            shadow[id] = nil
            systemFields[id] = nil
        }
        /// This Mac's version goes back up over the fetched one.
        func outrank(_ remote: SyncRecord) {
            shadow[remote.id] = nil
            systemFields[remote.id] = fetched.systemFields[remote.id]
        }
        @discardableResult
        func wait(_ remote: SyncRecord) -> Bool {
            guard inbox.records.count < Self.maxWaiting else { return false }
            inbox.records[remote.id] = remote
            inbox.systemFields[remote.id] = fetched.systemFields[remote.id]
            return true
        }
        var decisions = report ?? SpaceSyncReport(started: now)
        func decide(_ remote: SyncRecord, _ outcome: SpaceSyncReport.Outcome, _ reason: SpaceSyncReport.Reason? = nil, levelHere: SpaceSyncLevel) {
            decisions.decisions[remote.id] = SpaceSyncReport.Decision(
                kind: remote.type == .space ? .space : .item, outcome: outcome, reason: reason,
                space: remote.type == .item ? remote.uuid(Key.space) : nil, levelHere: levelHere,
                recordLevel: remote.type == .space ? remote.level : nil, time: remote.latestTime)
        }
        func decide(deletion id: UUID, _ outcome: SpaceSyncReport.Outcome, _ reason: SpaceSyncReport.Reason? = nil, space: UUID?) {
            decisions.decisions[id] = SpaceSyncReport.Decision(
                kind: .deletion, outcome: outcome, reason: reason, space: space == id ? nil : space,
                levelHere: space.map(level(of:)) ?? .off, recordLevel: nil, time: nil)
        }
        let incoming = fetched.records.values.sorted { $0.id.uuidString < $1.id.uuidString }

        for remote in incoming where remote.type == .space {
            let here = level(of: remote.id)
            if database == .private, let owner = remote.movedTo, sharing?.moved[remote.id] == nil {
                if sharing == nil { sharing = SpaceSyncSharing() }
                sharing?.moved[remote.id] = owner
                setLevel(.off, for: remote.id, now: now)
                decide(remote, .skipped, .movedAway, levelHere: here)
                continue
            }
            guard levels[remote.id] != .off else {
                decide(remote, .skipped, sharing?.moved[remote.id] != nil ? .movedAway : .offHere, levelHere: here)
                continue
            }
            guard !SpaceRecord.isAgentIcon(remote.string(Key.icon) ?? "") else {
                decide(remote, .skipped, .agentSpace, levelHere: here)
                continue
            }
            if let space = working.spaces[remote.id] {
                guard space.deletedAt == nil else {
                    decide(remote, .skipped, .deletedHere, levelHere: here)
                    continue
                }
                guard let mine = local[remote.id] else {
                    decide(remote, .skipped, .offHere, levelHere: here)
                    continue
                }
                let merged = SyncMerge.merge(local: mine, shadow: shadow[remote.id], remote: remote)
                working.spaces[remote.id] = merged.applied(to: space)
                levels[remote.id] = merged.level
            } else {
                working.spaces[remote.id] = arriving(remote, in: working, kept: kept)
                levels[remote.id] = levels[remote.id] ?? remote.level
            }
            decide(remote, .applied, levelHere: here)
            keep(remote)
        }

        for remote in incoming where remote.type == .item {
            let id = remote.id
            let existing = working.items[id]
            let mine = local[id]
            let merged = mine.map { SyncMerge.merge(local: $0, shadow: shadow[id], remote: remote) } ?? remote
            guard let spaceID = merged.uuid(Key.space), let section = merged.section else {
                decide(remote, .skipped, .unsupported, levelHere: .off)
                forget(id)
                continue
            }
            let here = level(of: spaceID)
            if working.spaces[spaceID] == nil, levels[spaceID] != .off {
                let waits = wait(remote)
                decide(remote, waits ? .waiting : .skipped, waits ? nil : .inboxFull, levelHere: here)
                continue
            }
            let target = working.space(spaceID)
            let next = merged.item(existing: existing)
            if let target, !target.isAgent, here.syncs(section), let next {
                if mine == nil {
                    if shadow[id] != nil {
                        decide(remote, .skipped, .deletedHere, levelHere: here)
                        if !isGone(id, in: working) { forget(id) }
                        continue
                    }
                    if let existing, SpaceSyncCodec.milliseconds(existing.modifiedAt) >= remote.latestTime {
                        decide(remote, .skipped, .newerHere, levelHere: here)
                        forget(id)
                        continue
                    }
                }
                working.items[id] = next
                positionTimes[id] = merged.times["position"] ?? remote.times["position"] ?? 0
                touched.append(id)
                decide(remote, .applied, levelHere: here)
                keep(remote)
                continue
            }
            guard let mine, var moved = next, let existing else {
                decide(remote, .skipped, skipReason(mine: mine, next: next, target: target, spaceID: spaceID, in: working), levelHere: here)
                if mine != nil { outrank(remote) } else { forget(id) }
                continue
            }
            if SyncMerge.samePosition(merged, mine) {
                moved.parent = existing.parent
                moved.order = existing.order
                working.items[id] = moved
                decide(remote, .applied, levelHere: here)
                keep(remote)
            } else if let target, !target.isAgent {
                if !(working.spaceID(of: id) == spaceID && moved.parent == existing.parent) {
                    let root = section.parent(in: spaceID)
                    moved.parent = root
                    moved.order = OrderKey.between(nil, working.children(of: root).first?.order) ?? moved.order
                }
                moved.modifiedAt = now
                working.items[id] = moved
                decide(remote, .applied, levelHere: here)
                forget(id)
            } else {
                decide(remote, .skipped, .newerHere, levelHere: here)
                outrank(remote)
            }
        }

        let deletions = fetched.deletions.sorted { $0.uuidString < $1.uuidString }
        for id in deletions where working.spaces[id] == nil {
            let lastAgreed = shadow[id]?.latestTime
            let space = (shadow[id] ?? local[id])?.uuid(Key.space)
            forget(id)
            guard deletedInCloud[id] == nil else {
                decide(deletion: id, .skipped, .alreadyDeleted, space: space)
                continue
            }
            deletedInCloud[id] = SpaceSyncCodec.milliseconds(now)
            if let space, sharing?.moved[space] != nil {
                decide(deletion: id, .skipped, .movedAway, space: space)
                continue
            }
            guard local[id] != nil, var item = working.item(id), syncs(id, in: working) else {
                decide(deletion: id, .skipped, .notHere, space: space)
                continue
            }
            item.deletedAt = now
            item.modifiedAt = lastAgreed.map(SpaceSyncCodec.date) ?? item.modifiedAt
            working.items[id] = item
            decide(deletion: id, .deleted, space: space)
        }
        for id in deletions where working.spaces[id] != nil {
            forget(id)
            guard deletedInCloud[id] == nil else {
                decide(deletion: id, .skipped, .alreadyDeleted, space: id)
                continue
            }
            deletedInCloud[id] = SpaceSyncCodec.milliseconds(now)
            if sharing?.moved[id] != nil {
                decide(deletion: id, .skipped, .movedAway, space: id)
                continue
            }
            guard working.space(id) != nil, levels[id].map({ $0 != .off }) == true else {
                decide(deletion: id, .skipped, .offHere, space: id)
                continue
            }
            decide(deletion: id, .deleted, space: id)
            result.deletedSpaces.append(id)
            levels[id] = nil
            levelTimes[id] = nil
        }
        report = decisions

        func root(of id: UUID) -> Parent? {
            guard let record = shadow[id] ?? local[id], let spaceID = record.uuid(Key.space), let section = record.section,
                  working.space(spaceID) != nil else { return nil }
            return section.parent(in: spaceID)
        }
        func lift(_ id: UUID) {
            guard var item = working.items[id], let parent = root(of: id) else { return }
            item.parent = parent
            item.modifiedAt = now
            working.items[id] = item
        }
        func positionTime(_ id: UUID) -> Int64 {
            positionTimes[id] ?? local[id].map { SyncMerge.outgoing($0, shadow: shadow[id]).times["position"] ?? 0 } ?? 0
        }
        for id in touched {
            guard let loop = cycle(through: id, in: working) else { continue }
            let times = Dictionary(uniqueKeysWithValues: loop.map { ($0, positionTime($0)) })
            if let mover = loop.max(by: { (times[$0] ?? 0, $0.uuidString) < (times[$1] ?? 0, $1.uuidString) }) { lift(mover) }
        }
        for id in touched {
            guard case .folder(let parentID)? = working.item(id)?.parent, let record = shadow[id] else { continue }
            let followed = working.item(parentID).map { parent in
                parent.live == nil && working.spaceID(of: parentID) == record.uuid(Key.space)
                    && working.section(of: parentID).flatMap(SyncSection.init) == record.section
            } ?? false
            if !followed { lift(id) }
        }
        working.repair(now: now)

        for (id, space) in working.spaces where tree.spaces[id] != space { result.change.spaces[id] = .some(space) }
        for id in tree.spaces.keys where working.spaces[id] == nil { result.change.spaces[id] = .some(nil) }
        for (id, item) in working.items where tree.items[id] != item { result.change.items[id] = .some(item) }
        for id in tree.items.keys where working.items[id] == nil { result.change.items[id] = .some(nil) }
        return result
    }

    /// Why an item that cannot go where its record puts it is left out.
    private func skipReason(mine: SyncRecord?, next: Item?, target: SpaceRecord?, spaceID: UUID, in tree: TabTree) -> SpaceSyncReport.Reason {
        if mine != nil { return .newerHere }
        if next == nil { return .unsupported }
        if target?.isAgent == true { return .agentSpace }
        if target == nil { return tree.spaces[spaceID]?.deletedAt != nil ? .deletedHere : .offHere }
        return level(of: spaceID) == .off ? .offHere : .sectionOffHere
    }

    /// A space from another Mac, in the profile with its profile's name, or a new one by that name.
    private func arriving(_ remote: SyncRecord, in tree: TabTree, kept: [KeptProfile]) -> SpaceRecord {
        let name = remote.string(Key.profile) ?? ""
        let profiles = tree.profiles(keeping: kept)
        let joined = profiles.first { $0.name == name }
            ?? profiles.first { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
        let profileName: String?
        if let joined {
            profileName = joined.spaceIDs.isEmpty ? joined.name : nil
        } else {
            profileName = name.isEmpty ? nil : name
        }
        var space = remote.applied(to: SpaceRecord(
            id: remote.id, name: "", icon: "", accentHex: SpaceSnapshot.defaultAccentHex, order: OrderKey("V"),
            modifiedAt: .distantPast, dataStoreID: joined?.id, profileName: profileName))
        space.searchEngineId = joined?.searchEngineId
        return space
    }

    /// Whether a live item is in a section its space syncs here.
    private func syncs(_ id: UUID, in tree: TabTree) -> Bool {
        guard let section = tree.section(of: id), let spaceID = section.spaceID, let kind = SyncSection(section),
              tree.space(spaceID)?.isAgent == false else { return false }
        return level(of: spaceID).syncs(kind)
    }

    /// Whether a record's place is one this Mac syncs.
    private func syncs(_ record: SyncRecord) -> Bool {
        guard record.type == .item else { return level(of: record.id) != .off }
        guard let spaceID = record.uuid(Key.space), let section = record.section else { return false }
        return level(of: spaceID).syncs(section)
    }

    /// Whether a record is deleted here: never there, removed, or a tombstone.
    private func isGone(_ id: UUID, in tree: TabTree) -> Bool {
        if let space = tree.spaces[id] { return space.deletedAt != nil }
        if let item = tree.items[id] { return item.deletedAt != nil }
        return true
    }

    /// The items in a loop of parents that passes through `id`, or nil when there is none.
    private func cycle(through id: UUID, in tree: TabTree) -> [UUID]? {
        var loop = [id]
        var seen: Set<UUID> = [id]
        var parent = tree.items[id]?.parent
        while case .folder(let next)? = parent {
            if next == id { return loop }
            guard seen.insert(next).inserted else { return nil }
            loop.append(next)
            parent = tree.items[next]?.parent
        }
        return nil
    }

    // MARK: - Starting over

    /// A signed-out or switched iCloud account: everything about the old one goes, and every
    /// space is Off until turned on again. The spaces stay.
    public mutating func reset(account: String?) {
        self = SpaceSyncState()
        self.account = account
    }

    /// Forgets the records iCloud holds, keeping the levels, for a sync that starts over.
    public mutating func forgetRecords() {
        shadow = [:]
        systemFields = [:]
        inbox = Inbox()
    }

    /// For a tree that did not load as it was last saved: the records and the engine state go, so
    /// the next sync fetches everything and merges it by time.
    public mutating func startOver() {
        forgetRecords()
        engine = nil
    }

    /// The zone is gone from iCloud. Nothing here is deleted for it. Unless everything goes up
    /// again, as after a reset of the person's encryption keys, every space turns Off.
    public mutating func zoneLost(reuploading: Bool) {
        guard sharing?.joinedOwner == nil else { return leaveSharedZone() }
        forgetRecords()
        deletedInCloud = [:]
        refetchSeen = nil
        catalog = SpaceSyncCatalog()
        guard !reuploading else { return }
        levels = [:]
        levelTimes = [:]
    }

    /// Drops levels of spaces that are gone, keeps out spaces deleted here, forgets records that
    /// stopped syncing here without being deleted, and drops deletions older than a tombstone.
    public mutating func prune(against tree: TabTree, now: Date = Date()) {
        for (id, level) in levels where level != .off && tree.space(id) == nil {
            let arriving = tree.spaces[id] == nil && catalog?.spaces[id] != nil
            guard !arriving else { continue }
            levels[id] = nil
            levelTimes[id] = nil
        }
        for space in tree.spaces.values where space.deletedAt != nil && levels[space.id] == nil {
            levels[space.id] = .off
        }
        let local = records(of: tree)
        for id in shadow.keys where local[id] == nil && !isGone(id, in: tree) {
            shadow[id] = nil
            systemFields[id] = nil
        }
        let cutoff = SpaceSyncCodec.milliseconds(now.addingTimeInterval(-TabTree.tombstoneLifetime))
        deletedInCloud = deletedInCloud.filter { $0.value >= cutoff }
    }
}

/// What applying fetched records does to the tree.
public struct SpaceSyncInbound: Equatable, Sendable {
    /// The new value of every record that changed; `TabTree.apply` writes them.
    public var change = Change()
    /// Spaces deleted on another Mac, for the app to delete with their windows and pages.
    public var deletedSpaces: [UUID] = []

    public init() {}

    public var isEmpty: Bool { change.isEmpty && deletedSpaces.isEmpty }
}
