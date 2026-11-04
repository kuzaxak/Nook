// Licensed under GPL-3.0. See LICENSE.
//
//  SpaceSync+Records.swift
//  NookTabsCore
//
//  A space and its items as records, read from the same snapshot a `.nookspace` file holds, and
//  records back into spaces and items. What never syncs is left out here: the Agent space, live
//  folders and their pages, tabs whose link is not a web address with what they opened, records
//  too large for iCloud, and the favorites another space holds.
//

import Foundation

extension SpaceSyncState {
    private typealias Key = SyncRecord.Key

    public func records(of tree: TabTree) -> [UUID: SyncRecord] {
        var tooLarge: Set<UUID> = []
        return records(of: tree, tooLarge: &tooLarge)
    }

    /// Items left out of sync because their record is larger than iCloud takes.
    public func tooLarge(in tree: TabTree) -> Set<UUID> {
        var tooLarge: Set<UUID> = []
        _ = records(of: tree, tooLarge: &tooLarge)
        return tooLarge
    }

    /// Also holds a tab or folder moved from a synced section into one this Mac does not sync
    /// (unpinned at Favorites & Pinned), with its new place, so the other Macs move it too.
    func records(of tree: TabTree, tooLarge: inout Set<UUID>) -> [UUID: SyncRecord] {
        var out: [UUID: SyncRecord] = [:]
        for space in tree.orderedSpaces where !space.isAgent {
            let level = self.level(of: space.id)
            guard level != .off, let snapshot = tree.spaceSnapshot(space.id) else { continue }
            let modified = SpaceSyncCodec.milliseconds(space.modifiedAt)
            var fields: [String: SyncValue] = [
                Key.name: .string(snapshot.name), Key.icon: .string(snapshot.icon), Key.accent: .string(snapshot.accentHex),
                Key.level: .string(level.rawValue), Key.order: .string(space.order.rawValue),
                Key.profile: .string(tree.profile(ofSpace: space.id)?.name ?? ""),
            ]
            fields[Key.theme] = snapshot.theme.map { .bytes(SpaceSyncCodec.data($0)) }
            var times = SyncRecord.RecordType.space.groups.mapValues { _ in modified }
            times["level"] = max(modified, levelTimes[space.id] ?? 0)
            out[space.id] = SyncRecord(type: .space, id: space.id, fields: fields, times: times)

            func movedOut(_ id: UUID) -> Bool {
                guard let agreed = shadow[id], agreed.uuid(Key.space) == space.id, let section = agreed.section else { return false }
                return level.syncs(section)
            }
            func add(_ entries: [SpaceSnapshot.Entry], _ section: SyncSection, under parent: UUID?, leaving: Bool) {
                for entry in entries {
                    guard let item = tree.items[entry.id], item.live == nil else { continue }
                    if entry.kind == .tab, entry.url.flatMap(TabTree.webURL) == nil { continue }
                    guard !leaving || movedOut(entry.id) else {
                        add(entry.children, section, under: entry.id, leaving: leaving)
                        continue
                    }
                    var fields: [String: SyncValue] = [
                        Key.space: .string(space.id.uuidString), Key.section: .string(section.rawValue),
                        Key.kind: .string(entry.kind.rawValue), Key.order: .string(item.order.rawValue), Key.title: .string(entry.title),
                    ]
                    fields[Key.parent] = parent.map { .string($0.uuidString) }
                    fields[Key.url] = entry.url.map { .string($0) }
                    fields[Key.customTitle] = entry.customTitle.map { .string($0) }
                    let modified = SpaceSyncCodec.milliseconds(item.modifiedAt)
                    let record = SyncRecord(type: .item, id: entry.id, fields: fields,
                                            times: SyncRecord.RecordType.item.groups.mapValues { _ in modified })
                    guard record.byteCount <= SyncRecord.maxBytes else {
                        tooLarge.insert(entry.id)
                        continue
                    }
                    out[entry.id] = record
                    add(entry.children, section, under: entry.id, leaving: leaving)
                }
            }
            add(snapshot.favorites.filter { tree.items[$0.id]?.parent == .favorites(spaceID: space.id) }, .favorites, under: nil, leaving: false)
            add(snapshot.pinned, .pinned, under: nil, leaving: false)
            add(snapshot.tabs, .tabs, under: nil, leaving: !level.syncs(.tabs))
        }
        return out
    }
}

extension SyncRecord {
    /// CloudKit takes at most 1 MB per record, and encryption makes the fields it stores larger
    /// than the values counted by `byteCount`.
    public static let maxBytes = 900_000

    var byteCount: Int {
        fields.reduce(times.count * 16) { total, field in
            switch field.value {
            case .string(let text): return total + field.key.utf8.count + text.utf8.count
            case .bytes(let data): return total + field.key.utf8.count + data.count
            case .int: return total + field.key.utf8.count + 8
            }
        }
    }

    /// The record as this build reads it back, so a field a newer build writes differently never
    /// looks like a change made here.
    func normalized() -> SyncRecord {
        var out = self
        if let data = bytes(Key.theme) { out.fields[Key.theme] = SpaceSyncCodec.theme(data).map { .bytes(SpaceSyncCodec.data($0)) } }
        if let link = string(Key.url) { out.fields[Key.url] = URL(string: link).map { .string($0.absoluteString) } }
        if type == .space { out.fields[Key.level] = .string(level.rawValue) }
        return out
    }

    /// `space` with this record's name, look and place.
    func applied(to space: SpaceRecord) -> SpaceRecord {
        var out = space
        if let name = string(Key.name) { out.name = name }
        if let icon = string(Key.icon) { out.icon = icon }
        if let accent = string(Key.accent).flatMap(ThemeRGB.init(hex:)) { out.accentHex = accent.hex }
        out.theme = bytes(Key.theme).flatMap(SpaceSyncCodec.theme)
        if let order = string(Key.order) { out.order = OrderKey(order) }
        out.modifiedAt = max(out.modifiedAt, SpaceSyncCodec.date(latestTime))
        return out
    }

    /// The item this record describes, or nil when it is not one this build keeps: a tab whose
    /// link is not a web address, or a kind it does not know.
    func item(existing: Item?) -> Item? {
        guard type == .item, let spaceID = uuid(Key.space), let section, let order = string(Key.order) else { return nil }
        let title = string(Key.title) ?? ""
        let kind: ItemKind
        let customTitle: String?
        switch string(Key.kind) {
        case SpaceSnapshot.Entry.Kind.folder.rawValue:
            kind = .folder
            customTitle = title
        case SpaceSnapshot.Entry.Kind.tab.rawValue:
            guard let url = string(Key.url).flatMap(TabTree.webURL) else { return nil }
            kind = .tab(url: url, pageTitle: title)
            customTitle = string(Key.customTitle)
        default:
            return nil
        }
        return Item(id: id, parent: uuid(Key.parent).map { .folder(itemID: $0) } ?? section.parent(in: spaceID),
                    order: OrderKey(order), kind: kind, customTitle: customTitle,
                    modifiedAt: max(existing?.modifiedAt ?? .distantPast, SpaceSyncCodec.date(latestTime)),
                    live: existing?.live)
    }
}

/// Last-writer-wins per group of fields.
enum SyncMerge {
    private static func values(_ record: SyncRecord?, _ keys: [String]) -> [SyncValue?] {
        keys.map { record?.fields[$0] }
    }

    /// The time a local group goes out with: the agreed one while it matches `shadow`, else after it.
    static func time(_ group: String, _ keys: [String], local: SyncRecord, shadow: SyncRecord?) -> Int64 {
        let modified = local.times[group] ?? 0
        guard let shadow else { return modified }
        let seen = shadow.times[group] ?? 0
        return values(local, keys) == values(shadow, keys) ? seen : max(modified, seen + 1)
    }

    static func samePosition(_ a: SyncRecord, _ b: SyncRecord) -> Bool {
        let keys = SyncRecord.RecordType.item.groups["position"] ?? []
        return values(a, keys) == values(b, keys)
    }

    static func outgoing(_ local: SyncRecord, shadow: SyncRecord?) -> SyncRecord {
        var out = local
        for (group, keys) in local.type.groups { out.times[group] = time(group, keys, local: local, shadow: shadow) }
        return out
    }

    /// `remote`, with every group this Mac changed later than `remote` did taken from `local`.
    /// A group this Mac left as `shadow` has it always takes `remote`'s.
    static func merge(local: SyncRecord, shadow: SyncRecord?, remote: SyncRecord) -> SyncRecord {
        var merged = remote
        for (group, keys) in remote.type.groups {
            let mine = values(local, keys), theirs = values(remote, keys)
            guard mine != theirs, shadow.map({ values($0, keys) != mine }) ?? true else { continue }
            let localTime = time(group, keys, local: local, shadow: shadow), remoteTime = remote.times[group] ?? 0
            guard localTime == remoteTime ? rank(mine) > rank(theirs) : localTime > remoteTime else { continue }
            for key in keys { merged.fields[key] = local.fields[key] }
            merged.times[group] = localTime
        }
        return merged
    }

    /// An order on values both Macs compute alike, for edits stamped the same millisecond.
    private static func rank(_ values: [SyncValue?]) -> String {
        values.map { value -> String in
            switch value {
            case .string(let text)?: return "s" + text
            case .int(let number)?: return "i\(number)"
            case .bytes(let data)?: return "b" + data.base64EncodedString()
            case nil: return ""
            }
        }.joined(separator: "\u{1F}")
    }
}
