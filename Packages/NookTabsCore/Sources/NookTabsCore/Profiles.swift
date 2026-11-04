// Licensed under GPL-3.0. See LICENSE.
//
//  Profiles.swift
//  NookTabsCore
//
//  A profile is the spaces that share one website data store: logins, cookies and history.
//  Its id is the store id; its name and search engine ride on its spaces. Only a profile kept
//  with no space has a record of its own, a `KeptProfile`.
//

import Foundation

public struct ProfileSummary: Identifiable, Equatable, Sendable {
    /// The data store id.
    public let id: UUID
    public let name: String
    /// Empty for a kept profile.
    public let spaceIDs: [UUID]
    /// Nil searches with the app's default engine.
    public let searchEngineId: String?
}

/// A profile no space uses that the person kept, with its logins, cookies and history. It lives
/// on this Mac only, like its website data, in `DeviceState.keptProfiles`.
public struct KeptProfile: Codable, Hashable, Sendable, Identifiable {
    /// The data store id.
    public let id: UUID
    public var name: String
    public var searchEngineId: String?

    public init(_ profile: ProfileSummary) {
        id = profile.id
        name = profile.name
        searchEngineId = profile.searchEngineId
    }
}

extension TabTree {
    /// Every profile in space order. The Agent space borrows a store and belongs to none.
    public var profiles: [ProfileSummary] {
        var order: [UUID] = []
        var members: [UUID: [SpaceRecord]] = [:]
        for space in orderedSpaces where !space.isAgent {
            let store = space.dataStoreID ?? space.id
            if members[store] == nil { order.append(store) }
            members[store, default: []].append(space)
        }
        return order.map { store in
            let spaces = members[store] ?? []
            // ponytail: each space carries the name; the first set one wins if two disagree after a sync.
            let name = spaces.lazy.compactMap(\.profileName).first ?? spaces.first?.name ?? ""
            return ProfileSummary(id: store, name: name, spaceIDs: spaces.map(\.id),
                                  searchEngineId: spaces.lazy.compactMap(\.searchEngineId).first)
        }
    }

    public func profile(ofSpace spaceID: UUID) -> ProfileSummary? {
        profiles.first { $0.spaceIDs.contains(spaceID) }
    }

    /// Every profile in space order, then the kept ones no space uses, with no spaces.
    public func profiles(keeping kept: [KeptProfile]) -> [ProfileSummary] {
        let inUse = profiles
        let used = Set(inUse.map(\.id))
        return inUse + kept.filter { !used.contains($0.id) }.map {
            ProfileSummary(id: $0.id, name: $0.name, spaceIDs: [], searchEngineId: $0.searchEngineId)
        }
    }

    /// The profile `spaceID` leaves by moving to `storeID` (nil: a new profile) when no other space
    /// uses it, which the person then keeps or deletes. Nil when another space still uses it.
    public func profileLeftEmpty(byMoving spaceID: UUID, to storeID: UUID?) -> ProfileSummary? {
        guard let current = profile(ofSpace: spaceID), current.id != storeID, current.spaceIDs == [spaceID] else { return nil }
        return current
    }

    /// Moves a space into the profile whose store is `storeID`, or into a new profile when nil.
    /// A kept profile in `kept` has no space to carry its name and engine, so the space takes them.
    @discardableResult
    public mutating func setProfile(_ spaceID: UUID, to storeID: UUID?, name: String? = nil, kept: [KeptProfile] = [], now: Date = Date()) throws -> Change {
        guard var target = space(spaceID), !target.isAgent else { throw TreeError.missingSpace }
        let joined = storeID.flatMap { store in profiles(keeping: kept).first { $0.id == store } }
        target.searchEngineId = joined?.searchEngineId
        // Never back to nil: the space's own id may still be the store of spaces it left behind.
        target.dataStoreID = storeID ?? UUID()
        target.profileName = storeID == nil ? name : joined.flatMap { $0.spaceIDs.isEmpty ? $0.name : nil }
        target.modifiedAt = now
        var change = Change()
        record(&change, space: target)
        return change
    }

    /// Sets the engine every space of the profile searches with; nil goes back to the app's default.
    @discardableResult
    public mutating func setSearchEngine(profile storeID: UUID, engineId: String?, now: Date = Date()) throws -> Change {
        guard let profile = profiles.first(where: { $0.id == storeID }) else { throw TreeError.missingSpace }
        var change = Change()
        for id in profile.spaceIDs {
            guard var space = space(id), space.searchEngineId != engineId else { continue }
            space.searchEngineId = engineId
            space.modifiedAt = now
            record(&change, space: space)
        }
        return change
    }

    @discardableResult
    public mutating func renameProfile(_ storeID: UUID, to name: String, now: Date = Date()) throws -> Change {
        guard let profile = profiles.first(where: { $0.id == storeID }) else { throw TreeError.missingSpace }
        var change = Change()
        for id in profile.spaceIDs {
            guard var space = space(id), space.profileName != name else { continue }
            space.profileName = name
            space.modifiedAt = now
            record(&change, space: space)
        }
        return change
    }
}
