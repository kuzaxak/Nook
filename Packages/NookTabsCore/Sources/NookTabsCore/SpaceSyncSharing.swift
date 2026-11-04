// Licensed under GPL-3.0. See LICENSE.
//
//  SpaceSyncSharing.swift
//  NookTabsCore
//
//  Sync between two iCloud accounts. The owner shares its zone with a zone-wide share; a Mac on
//  another account that accepts it syncs that zone through its shared database instead of its
//  own zone, after moving its synced spaces in. Leaving, or the owner ending the share, takes
//  that Mac back to its own zone with every space Off and nothing deleted.
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
    /// Spaces moved from this account's zone into the joined one, each with its records still in
    /// this account's zone. They are deleted there only once the joined zone holds every record of
    /// the space as this Mac has it.
    public var moving: [UUID: Set<UUID>] = [:]

    public init(joinedOwner: String? = nil, ownerName: String? = nil, participants: [SpaceSyncParticipant]? = nil) {
        self.joinedOwner = joinedOwner
        self.ownerName = ownerName
        self.participants = participants
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

    /// Joins another account's zone. What this Mac knows of its own zone goes, the levels stay,
    /// so every space syncing here goes up into the joined zone, and each one's records in this
    /// account's zone are kept until `privateDeletions` lets them go.
    public mutating func join(owner: String, ownerName: String?) {
        var moving: [UUID: Set<UUID>] = [:]
        for (space, level) in levels where level != .off {
            var ids = Set(shadow.values.filter { $0.id == space || $0.uuid(Key.space) == space }.map(\.id))
            if let catalog {
                if catalog.spaces[space] != nil { ids.insert(space) }
                ids.formUnion(catalog.items.filter { $0.value.space == space }.keys)
            }
            if !ids.isEmpty { moving[space] = ids }
        }
        forgetRecords()
        deletedInCloud = [:]
        refetchSeen = nil
        engine = nil
        catalog = SpaceSyncCatalog()
        report = nil
        sharing = SpaceSyncSharing(joinedOwner: owner, ownerName: ownerName)
        sharing?.moving = moving
    }

    /// Back to this account's own zone with every space Off, after leaving the joined zone or
    /// its owner ending the share. Nothing on this Mac is deleted.
    public mutating func leaveSharedZone() {
        reset(account: account)
    }

    /// This account's zone is shared with these people.
    public mutating func shared(participants: [SpaceSyncParticipant]) {
        guard sharing?.joinedOwner == nil else { return }
        sharing = SpaceSyncSharing(participants: participants)
    }

    public mutating func stoppedSharing() {
        guard sharing?.joinedOwner == nil else { return }
        sharing = nil
    }

    /// Records of moved spaces this Mac may delete from its own account's zone: those of every
    /// space whose records the joined zone now holds as this Mac has them.
    public func privateDeletions(in tree: TabTree) -> Set<UUID> {
        guard let moving = sharing?.moving, !moving.isEmpty else { return [] }
        let local = records(of: tree).values
        var out: Set<UUID> = []
        for (space, ids) in moving where level(of: space) != .off {
            let own = local.filter { $0.id == space || $0.uuid(Key.space) == space }
            guard !own.isEmpty, own.allSatisfy({ shadow[$0.id]?.sameValues(as: $0) == true }) else { continue }
            out.formUnion(ids)
        }
        return out
    }

    public mutating func deletedFromPrivateZone(_ ids: Set<UUID>) {
        guard let moving = sharing?.moving else { return }
        sharing?.moving = moving.compactMapValues { records in
            let left = records.subtracting(ids)
            return left.isEmpty ? nil : left
        }
    }
}
