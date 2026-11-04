// Licensed under GPL-3.0. See LICENSE.
//
//  SpaceSyncSharing.swift
//  NookTabsCore
//
//  Sync between two iCloud accounts. The owner shares its zone with a zone-wide share; a Mac on
//  another account that accepts it syncs that zone through its shared database instead of its
//  own zone, and can move its synced spaces in. A moved space keeps its records in the old zone,
//  marked with where it went, so the account's other Macs turn it Off instead of losing it; only
//  the person removes that old copy. Leaving, or the owner ending the share, takes that Mac back
//  to its own zone with every space Off and nothing deleted.
//

import Foundation

/// The database a Mac's sync engine works in.
public enum SpaceSyncDatabase: String, Codable, Sendable {
    /// This account's own zone.
    case `private`
    /// Another account's zone this Mac joined.
    case shared
}

/// Whose zone this Mac syncs, as Settings says it.
public enum SpaceSyncMode: Equatable, Sendable {
    case own
    /// This account's zone, shared with that many people besides its owner.
    case sharing(people: Int)
    /// Another account's zone, by its owner's name when CloudKit gives one.
    case joined(owner: String?)
}

/// Someone in this account's share, as its share lists them.
public struct SpaceSyncParticipant: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable { case pending, accepted, removed, unknown }

    public var name: String
    public var status: Status
    public var isOwner: Bool

    public init(name: String, status: Status, isOwner: Bool) {
        self.name = name
        self.status = status
        self.isOwner = isOwner
    }
}

public struct SpaceSyncSharing: Codable, Equatable, Sendable {
    /// The CloudKit user record name of the account whose zone this Mac joined.
    public var joinedOwner: String?
    public var ownerName: String?
    /// Everyone this account's zone is shared with, its owner included; nil while not shared.
    public var participants: [SpaceSyncParticipant]?
    /// Spaces another Mac on this account moved into a shared zone, by the CloudKit user record
    /// name of that zone's owner, as their marked records in this account's zone say.
    public var moved: [UUID: String] = [:]
    /// On a Mac that joined and moved its spaces: each moved space's records left in this
    /// account's own zone, and the Macs that synced them there.
    public var oldCopies: [UUID: SpaceSyncOldCopy] = [:]

    public init(joinedOwner: String? = nil, ownerName: String? = nil, participants: [SpaceSyncParticipant]? = nil) {
        self.joinedOwner = joinedOwner
        self.ownerName = ownerName
        self.participants = participants
    }
}

public struct SpaceSyncOldCopy: Codable, Equatable, Sendable {
    public var records: Set<UUID>
    public var devices: [String]
}

/// The old copies of moved spaces, as Settings names them before removing them.
public struct SpaceSyncLeftBehind: Equatable, Sendable {
    public let spaces: Int
    /// The Macs that synced them in this account's zone.
    public let devices: [String]

    public init(spaces: Int, devices: [String]) {
        self.spaces = spaces
        self.devices = devices
    }
}

/// What to do with a share someone opened or pasted.
public enum SpaceSyncShareAcceptance: Equatable, Sendable {
    case join(owner: String)
    /// This account owns it.
    case ownShare
    /// Another app's share, or another zone.
    case notASpacesShare
    /// This Mac already syncs a zone it joined; it leaves that one first.
    case alreadyJoined
    /// This account shares its own zone; it stops sharing first.
    case sharingOwnZone
}

public enum SpaceSyncShareLink {
    /// The iCloud sharing link in pasted text: https://www.icloud.com/share/<token>, the scheme
    /// optional.
    public static func parse(_ text: String) -> URL? {
        var link = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !link.contains("://") { link = "https://" + link }
        guard let url = URL(string: link), url.scheme == "https",
              let host = url.host?.lowercased(), host == "www.icloud.com" || host == "icloud.com" else { return nil }
        let path = url.path.split(separator: "/")
        guard path.count >= 2, path[0] == "share" else { return nil }
        return url
    }
}

extension SpaceSyncState {
    private typealias Key = SyncRecord.Key

    public var database: SpaceSyncDatabase { sharing?.joinedOwner == nil ? .private : .shared }

    /// The owner of the zone this Mac syncs; nil for this account's own.
    public var zoneOwner: String? { sharing?.joinedOwner }

    public var mode: SpaceSyncMode {
        if sharing?.joinedOwner != nil { return .joined(owner: sharing?.ownerName) }
        guard let participants = sharing?.participants else { return .own }
        return .sharing(people: participants.filter { !$0.isOwner && $0.status != .removed }.count)
    }

    public func acceptance(containerID: String, zoneName: String, zoneOwner: String, isOwner: Bool) -> SpaceSyncShareAcceptance {
        guard containerID == SpaceSyncAvailability.containerID, zoneName == SpaceSyncAvailability.zoneName else { return .notASpacesShare }
        if isOwner { return .ownShare }
        if sharing?.joinedOwner != nil { return .alreadyJoined }
        if sharing?.participants != nil { return .sharingOwnZone }
        return .join(owner: zoneOwner)
    }

    /// The spaces syncing here, which joining can move into the shared zone.
    public func spacesToMove(in tree: TabTree) -> Set<UUID> {
        Set(tree.orderedSpaces.filter { !$0.isAgent && level(of: $0.id) != .off }.map(\.id))
    }

    /// The spaces to move whose records this account's zone holds: the app marks each one there
    /// with where it went before joining.
    public func markedOnMove(in tree: TabTree) -> Set<UUID> {
        spacesToMove(in: tree).filter { catalog?.spaces[$0] != nil }
    }

    /// Joins another account's zone. Fetched changes still waiting are applied first; the app
    /// writes the returned change. Moving keeps the levels, so every space syncing here goes up
    /// into the joined zone, and its records stay in this account's zone as an old copy. Without
    /// moving, those spaces turn Off and stay in this account's zone for its other Macs.
    public mutating func join(owner: String, ownerName: String?, moving: Bool, tree: TabTree, kept: [KeptProfile] = [],
                              now: Date = Date()) -> SpaceSyncInbound {
        let inbound = receive(into: tree, kept: kept, now: now)
        var after = tree
        after.apply(inbound.change)
        var oldCopies: [UUID: SpaceSyncOldCopy] = [:]
        for space in spacesToMove(in: after) {
            if moving {
                let items = catalog?.items.filter { $0.value.space == space } ?? [:]
                guard let record = catalog?.spaces[space] else { continue }
                let devices = Set([record.string(Key.device)].compactMap { $0 } + items.values.compactMap(\.device))
                oldCopies[space] = SpaceSyncOldCopy(records: Set(items.keys).union([space]),
                                                    devices: devices.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
            } else {
                setLevel(.off, for: space, now: now)
            }
        }
        forgetRecords()
        deletedInCloud = [:]
        refetchSeen = nil
        engine = nil
        catalog = SpaceSyncCatalog()
        report = nil
        sharing = SpaceSyncSharing(joinedOwner: owner, ownerName: ownerName)
        sharing?.oldCopies = oldCopies
        return inbound
    }

    /// The old copies of moved spaces still in this account's own zone.
    public var oldCopies: SpaceSyncLeftBehind? {
        guard let copies = sharing?.oldCopies, !copies.isEmpty else { return nil }
        let devices = Set(copies.values.flatMap(\.devices)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return SpaceSyncLeftBehind(spaces: copies.count, devices: devices)
    }

    /// The records of every old copy, for the app to delete from this account's zone when the
    /// person removes them.
    public var oldCopyRecords: Set<UUID> {
        Set(sharing?.oldCopies.values.flatMap(\.records) ?? [])
    }

    public mutating func removedOldCopies(_ ids: Set<UUID>) {
        guard let copies = sharing?.oldCopies else { return }
        sharing?.oldCopies = copies.compactMapValues { copy in
            var left = copy
            left.records.subtract(ids)
            return left.records.isEmpty ? nil : left
        }
    }

    /// Back to this account's own zone with every space Off, after leaving the joined zone or
    /// its owner ending the share. Nothing on this Mac is deleted. Every space this Mac knows of
    /// stays Off by name, so the fetch of this account's zone brings back none it kept out,
    /// such as one deleted here long ago.
    public mutating func leaveSharedZone(in tree: TabTree) {
        var known = Set(levels.keys).union(tree.spaces.keys)
        if let catalog { known.formUnion(catalog.spaces.keys) }
        reset(account: account)
        for id in known { levels[id] = .off }
    }

    /// This account's zone is shared with these people.
    public mutating func shared(participants: [SpaceSyncParticipant]) {
        guard sharing?.joinedOwner == nil else { return }
        if sharing == nil { sharing = SpaceSyncSharing() }
        sharing?.participants = participants
    }

    public mutating func stoppedSharing() {
        guard sharing?.joinedOwner == nil else { return }
        sharing?.participants = nil
    }
}
