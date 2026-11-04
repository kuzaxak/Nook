// Licensed under GPL-3.0. See LICENSE.
//
//  SpaceSyncCatalog.swift
//  NookTabsCore
//
//  What the account's zone holds, whether this Mac syncs it or not, as Settings lists it: every
//  space record, which Mac last changed it and its state here. Also the report of what the last
//  fetch did with each record, made of ids, types, levels and times only.
//

import Foundation

/// Every record in the account's zone as this Mac last saw it.
public struct SpaceSyncCatalog: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public var space: UUID
        /// The latest change, in milliseconds.
        public var time: Int64
        public var device: String?
    }

    public var spaces: [UUID: SyncRecord] = [:]
    public var items: [UUID: Item] = [:]
    /// Spaces this Mac removes from iCloud, until iCloud has none of their records.
    public var removing: Set<UUID> = []
    /// Records iCloud refused to save, with the CloudKit error code.
    public var refused: [UUID: Int] = [:]

    public init() {}

    mutating func add(_ record: SyncRecord) {
        switch record.type {
        case .space:
            spaces[record.id] = record
        case .item:
            guard let space = record.uuid(SyncRecord.Key.space) else { return }
            items[record.id] = Item(space: space, time: record.latestTime, device: record.string(SyncRecord.Key.device))
        }
    }

    mutating func remove(_ id: UUID) {
        spaces[id] = nil
        items[id] = nil
        refused[id] = nil
        removing = removing.filter { space in spaces[space] != nil || items.values.contains { $0.space == space } }
    }

    /// The records of the spaces being removed that iCloud still has.
    var removals: Set<UUID> {
        Set(removing.filter { spaces[$0] != nil }).union(items.filter { removing.contains($0.value.space) }.keys)
    }
}

/// A space iCloud holds, as Settings lists it.
public struct SpaceSyncCloudSpace: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case syncing(SpaceSyncLevel)
        /// In iCloud and not synced here: a space here turned Off, one fetched while Off, or one
        /// deleted here while Off.
        case offHere
        /// Fetched, or asked for, and not in the tree yet.
        case arriving
        case error(String)
    }

    public let id: UUID
    public let name: String
    public let profile: String
    /// The Mac that saved the latest change to the space or one of its items.
    public let device: String?
    public let changedAt: Date
    public let itemCount: Int
    public let state: State
    /// Whether choosing a level here brings the space in: false for one deleted on this Mac.
    public let canSyncHere: Bool
}

/// What the last fetch did with each record: ids, types, levels and times, never names,
/// addresses or titles.
public struct SpaceSyncReport: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case space, item, deletion }
    public enum Outcome: String, Codable, Sendable { case applied, waiting, skipped, deleted }
    public enum Reason: String, Codable, Sendable {
        /// The space is Off on this Mac.
        case offHere
        /// This Mac's level for the space leaves out the item's section.
        case sectionOffHere
        case agentSpace
        /// Deleted on this Mac, and the deletion wins.
        case deletedHere
        /// This Mac's version is newer and stays, going back up if it syncs.
        case newerHere
        /// A record this build cannot hold: a link that is not a web address, a kind it does not
        /// know, or no place.
        case unsupported
        /// Its space has not arrived and too many items already wait.
        case inboxFull
        /// A deletion this Mac made itself or already applied.
        case alreadyDeleted
        /// A deletion of something this Mac does not sync.
        case notHere
    }

    public struct Decision: Codable, Equatable, Sendable {
        public var kind: Kind
        public var outcome: Outcome
        public var reason: Reason?
        /// The item's space.
        public var space: UUID?
        /// The space's level here before the record was applied.
        public var levelHere: SpaceSyncLevel
        /// The level a space record asks for.
        public var recordLevel: SpaceSyncLevel?
        /// The record's latest change, in milliseconds.
        public var time: Int64?
    }

    public var started: Date
    public var decisions: [UUID: Decision] = [:]

    public init(started: Date) {
        self.started = started
    }
}

extension SpaceSyncState {
    private typealias Key = SyncRecord.Key

    /// Every space record iCloud holds, in space order, with its state here.
    public func cloudSpaces(in tree: TabTree) -> [SpaceSyncCloudSpace] {
        guard let catalog else { return [] }
        let tooLarge = tooLarge(in: tree)
        var items: [UUID: [(id: UUID, entry: SpaceSyncCatalog.Item)]] = [:]
        for (id, entry) in catalog.items { items[entry.space, default: []].append((id, entry)) }
        let rows = catalog.spaces.values.map { record -> (order: String, row: SpaceSyncCloudSpace) in
            let own = items[record.id] ?? []
            let latest = own.map(\.entry).max { ($0.time, $0.device ?? "") < ($1.time, $1.device ?? "") }
            let spaceTime = record.latestTime
            let device = latest.map { $0.time > spaceTime ? $0.device : record.string(Key.device) } ?? record.string(Key.device)
            let local = tree.spaces[record.id]
            let level = level(of: record.id)
            let state: SpaceSyncCloudSpace.State
            let refused = ([record.id] + own.map(\.id)).compactMap { catalog.refused[$0] }.first
            if SpaceRecord.isAgentIcon(record.string(Key.icon) ?? "") {
                state = .error("The Agent space does not sync")
            } else if catalog.removing.contains(record.id) || local?.deletedAt != nil || levels[record.id] == .off
                        || (local != nil && level == .off) {
                state = .offHere
            } else if local == nil {
                state = .arriving
            } else if let refused {
                state = .error("iCloud refused a change (error \(refused))")
            } else if tooLarge.contains(where: { tree.spaceID(of: $0) == record.id }) {
                state = .error("A tab's address or title is too long for iCloud")
            } else {
                state = .syncing(level)
            }
            let row = SpaceSyncCloudSpace(
                id: record.id, name: record.string(Key.name) ?? "", profile: record.string(Key.profile) ?? "", device: device,
                changedAt: SpaceSyncCodec.date(max(spaceTime, latest?.time ?? 0)), itemCount: own.count, state: state,
                canSyncHere: local?.deletedAt == nil)
            return (record.string(Key.order) ?? "", row)
        }
        return rows.sorted { ($0.order, $0.row.id.uuidString) < ($1.order, $1.row.id.uuidString) }.map(\.row)
    }

    /// The names of the Macs whose changes iCloud holds.
    public var cloudDevices: [String] {
        guard let catalog else { return [] }
        let names = catalog.spaces.values.compactMap { $0.string(Key.device) } + catalog.items.values.compactMap(\.device)
        return Set(names).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Deletes the space's records from iCloud, which deletes it on the Macs that sync it, and
    /// turns it Off here, where it stays.
    public mutating func removeFromICloud(_ spaceID: UUID, now: Date = Date()) {
        setLevel(.off, for: spaceID, now: now)
        guard catalog?.spaces[spaceID] != nil else { return }
        catalog?.removing.insert(spaceID)
    }

    /// A save iCloud refused with a CloudKit error this Mac does not handle.
    public mutating func refused(_ id: UUID, code: Int) {
        catalog?.refused[id] = code
    }

    /// A fetch starts: the report covers what it receives.
    public mutating func beginReport(now: Date = Date()) {
        report = SpaceSyncReport(started: now)
    }

    /// The report as text to paste: the account's id, counts, then one line per record.
    public func reportText(account: String?, now: Date = Date()) -> String {
        let time = Date.ISO8601FormatStyle()
        var lines = ["Nook space sync report", "Generated: \(now.formatted(time))"]
        lines.append("Account ID: \(account.map(SpaceSyncCodec.accountID) ?? "none")")
        switch mode {
        case .own: lines.append("Zone: this account's")
        case .sharing(let people): lines.append("Zone: this account's, shared, participants: \(people)")
        case .joined: lines.append("Zone: joined, owner account ID \(zoneOwner.map(SpaceSyncCodec.accountID) ?? "unknown")")
        }
        if let moving = sharing?.moving, !moving.isEmpty {
            lines.append("Moving from this account's zone: \(moving.count) spaces, \(moving.values.map(\.count).reduce(0, +)) records left there")
        }
        if let catalog {
            lines.append("In iCloud: \(catalog.spaces.count) spaces, \(catalog.items.count) items, from \(cloudDevices.count) Macs")
            if !catalog.removing.isEmpty { lines.append("Removing: " + catalog.removing.map(\.uuidString).sorted().joined(separator: ", ")) }
            for (id, code) in catalog.refused.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                lines.append("Refused: \(id.uuidString) error \(code)")
            }
        } else {
            lines.append("In iCloud: not fetched yet")
        }
        let levelLines = levels.sorted { $0.key.uuidString < $1.key.uuidString }.map { "  \($0.key.uuidString) \($0.value.rawValue)" }
        lines.append("Levels here: \(levels.count)")
        lines += levelLines
        lines.append("Waiting: \(inbox.records.count) records, \(inbox.deletions.count) deletions")
        guard let report else {
            lines.append("Last fetch: none")
            return lines.joined(separator: "\n") + "\n"
        }
        let decisions = report.decisions.sorted { $0.key.uuidString < $1.key.uuidString }
        func count(_ kind: SpaceSyncReport.Kind) -> Int { decisions.filter { $0.value.kind == kind }.count }
        func count(_ outcome: SpaceSyncReport.Outcome) -> Int { decisions.filter { $0.value.outcome == outcome }.count }
        lines.append("Last fetch: \(report.started.formatted(time))")
        lines.append("Fetched: \(decisions.count) (\(count(.space)) spaces, \(count(.item)) items, \(count(.deletion)) deletions)")
        lines.append("Applied: \(count(.applied))")
        lines.append("Deleted: \(count(.deleted))")
        lines.append("Waiting for their space: \(count(.waiting))")
        let reasons = Dictionary(grouping: decisions.compactMap(\.value.reason), by: { $0 }).mapValues(\.count)
        let skipped = reasons.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue) \($0.value)" }
        lines.append("Skipped: \(count(.skipped))" + (skipped.isEmpty ? "" : " (" + skipped.joined(separator: ", ") + ")"))
        lines.append("Records:")
        for (id, decision) in decisions {
            var line = "  \(id.uuidString) \(decision.kind.rawValue) \(decision.outcome.rawValue)"
            if let reason = decision.reason { line += " \(reason.rawValue)" }
            if let space = decision.space { line += " space=\(space.uuidString)" }
            line += " here=\(decision.levelHere.rawValue)"
            if let level = decision.recordLevel { line += " record=\(level.rawValue)" }
            if let changed = decision.time { line += " changed=\(SpaceSyncCodec.date(changed).formatted(time))" }
            lines.append(line)
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
