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

    /// Spaces this Mac syncs, and spaces it keeps out: an explicit Off for a space that is gone
    /// here keeps it from arriving again. A space with no entry is Off.
    public var levels: [UUID: SpaceSyncLevel] = [:]
    /// When the level of each space last changed here, in milliseconds.
    public var levelTimes: [UUID: Int64] = [:]
    /// The last version of each record iCloud and this Mac agreed on.
    public var shadow: [UUID: SyncRecord] = [:]
    /// CloudKit's system fields for each record in `shadow`, as the app archived them.
    public var systemFields: [UUID: Data] = [:]
    /// CKSyncEngine's own state, as the app encoded it.
    public var engine: Data?
    /// The iCloud user this state belongs to.
    public var account: String?
    public var inbox = Inbox()
    public var lastSync: Date?
    public var lastError: String?

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

    /// Sets a space's level here. Off forgets what iCloud holds for it without deleting any of
    /// it. True when the space was Off, so the app fetches everything again to find what iCloud
    /// already has for it.
    @discardableResult
    public mutating func setLevel(_ level: SpaceSyncLevel, for spaceID: UUID, now: Date = Date()) -> Bool {
        let old = self.level(of: spaceID)
        guard level != old else { return false }
        levels[spaceID] = level
        levelTimes[spaceID] = SpaceSyncCodec.milliseconds(now)
        guard level == .off else { return old == .off }
        let items = shadow.values.filter { $0.type == .item && $0.uuid(Key.space) == spaceID }.map(\.id)
        for id in items + [spaceID] {
            shadow[id] = nil
            systemFields[id] = nil
        }
        return false
    }

    /// Records to save because they differ from what iCloud has, and records to delete because
    /// this Mac no longer keeps them.
    public func pendingChanges(in tree: TabTree) -> (saves: Set<UUID>, deletes: Set<UUID>) {
        let local = records(of: tree)
        let saves = local.compactMap { id, record in shadow[id]?.sameValues(as: record) == true ? nil : id }
        return (Set(saves), Set(shadow.keys.filter { local[$0] == nil }))
    }

    /// The records to save, each group timed after the version it replaces.
    public func outgoing(_ ids: Set<UUID>, in tree: TabTree) -> [UUID: SyncRecord] {
        records(of: tree).filter { ids.contains($0.key) }.mapValues { SyncMerge.outgoing($0, shadow: shadow[$0.id]) }
    }

    /// iCloud took these saves and deletions. A save for a space turned Off meanwhile is not kept,
    /// so it never reads as something to delete.
    public mutating func didSend(saved: [SyncRecord], systemFields fields: [UUID: Data], deleted: [UUID]) {
        for record in saved {
            let spaceID = record.type == .space ? record.id : record.uuid(Key.space)
            guard let spaceID, level(of: spaceID) != .off else { continue }
            shadow[record.id] = record.normalized()
            systemFields[record.id] = fields[record.id]
        }
        for id in deleted {
            shadow[id] = nil
            systemFields[id] = nil
        }
    }

    /// Applies the inbox: merges each record with this Mac's version, field group by field group,
    /// and returns the new value of every record it changed. A deletion beats an edit, and so
    /// does a removal from sync here that has not gone out yet. When two moves put folders inside
    /// each other, the later move is undone.
    public mutating func receive(into tree: TabTree, kept: [KeptProfile] = [], now: Date = Date()) -> SpaceSyncInbound {
        let inbox = self.inbox
        self.inbox = Inbox()
        var result = SpaceSyncInbound()
        guard !inbox.isEmpty else { return result }
        let local = records(of: tree)
        var working = tree
        var touched: [UUID] = []
        var positionTimes: [UUID: Int64] = [:]

        func keep(_ remote: SyncRecord) {
            shadow[remote.id] = remote
            systemFields[remote.id] = inbox.systemFields[remote.id]
        }
        func forget(_ id: UUID) {
            shadow[id] = nil
            systemFields[id] = nil
        }
        let incoming = inbox.records.values.sorted { $0.id.uuidString < $1.id.uuidString }

        for remote in incoming where remote.type == .space {
            guard levels[remote.id] != .off, !SpaceRecord.isAgentIcon(remote.string(Key.icon) ?? "") else { continue }
            if let space = working.spaces[remote.id] {
                guard space.deletedAt == nil, let mine = local[remote.id] else { continue }
                let merged = SyncMerge.merge(local: mine, shadow: shadow[remote.id], remote: remote)
                working.spaces[remote.id] = merged.applied(to: space)
                levels[remote.id] = merged.level
            } else {
                working.spaces[remote.id] = arriving(remote, in: working, kept: kept)
                levels[remote.id] = remote.level
            }
            keep(remote)
        }

        for remote in incoming where remote.type == .item {
            let id = remote.id
            let existing = working.items[id]
            guard let spaceID = remote.uuid(Key.space), let section = remote.section,
                  working.space(spaceID)?.isAgent == false, level(of: spaceID).syncs(section),
                  var next = remote.item(existing: existing) else {
                if local[id] != nil, var item = working.item(id) {
                    item.deletedAt = now
                    item.modifiedAt = now
                    working.items[id] = item
                }
                forget(id)
                continue
            }
            var positionTime = remote.times["position"] ?? 0
            if let mine = local[id] {
                let merged = SyncMerge.merge(local: mine, shadow: shadow[id], remote: remote)
                guard let item = merged.item(existing: existing) else { continue }
                next = item
                positionTime = merged.times["position"] ?? positionTime
            } else if shadow[id] != nil {
                continue
            } else if let existing, SpaceSyncCodec.milliseconds(existing.deletedAt ?? existing.modifiedAt) >= remote.latestTime {
                keep(remote)
                continue
            }
            working.items[id] = next
            positionTimes[id] = positionTime
            touched.append(id)
            keep(remote)
        }

        let deletions = inbox.deletions.sorted { $0.uuidString < $1.uuidString }
        for id in deletions where working.spaces[id] == nil {
            forget(id)
            guard var item = working.item(id), syncs(id, in: working) else { continue }
            item.deletedAt = now
            item.modifiedAt = now
            working.items[id] = item
        }
        for id in deletions where working.spaces[id] != nil {
            forget(id)
            guard working.space(id) != nil, levels[id].map({ $0 != .off }) == true else { continue }
            result.deletedSpaces.append(id)
            levels[id] = nil
            levelTimes[id] = nil
        }

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
        for id in touched {
            if case .folder(let parentID)? = working.item(id)?.parent, working.item(parentID) == nil { lift(id) }
        }
        func positionTime(_ id: UUID) -> Int64 {
            positionTimes[id] ?? local[id].map { SyncMerge.outgoing($0, shadow: shadow[id]).times["position"] ?? 0 } ?? 0
        }
        for id in touched {
            guard let loop = cycle(through: id, in: working) else { continue }
            let times = Dictionary(uniqueKeysWithValues: loop.map { ($0, positionTime($0)) })
            if let mover = loop.max(by: { (times[$0] ?? 0, $0.uuidString) < (times[$1] ?? 0, $1.uuidString) }) { lift(mover) }
        }
        working.repair(now: now)

        for (id, space) in working.spaces where tree.spaces[id] != space { result.change.spaces[id] = .some(space) }
        for id in tree.spaces.keys where working.spaces[id] == nil { result.change.spaces[id] = .some(nil) }
        for (id, item) in working.items where tree.items[id] != item { result.change.items[id] = .some(item) }
        for id in tree.items.keys where working.items[id] == nil { result.change.items[id] = .some(nil) }
        return result
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

    /// Drops levels of spaces that are gone and keeps out spaces deleted here.
    public mutating func prune(against tree: TabTree) {
        for (id, level) in levels where level != .off && tree.space(id) == nil {
            levels[id] = nil
            levelTimes[id] = nil
        }
        for space in tree.spaces.values where space.deletedAt != nil && levels[space.id] == nil {
            levels[space.id] = .off
        }
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
