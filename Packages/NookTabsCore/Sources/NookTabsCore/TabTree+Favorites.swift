// Licensed under GPL-3.0. See LICENSE.
import Foundation

extension TabTree {
    /// Whether two spaces show the same favorites: both are the person's (not the Agent space)
    /// and use the same website data store, as Arc shares favorites per profile.
    public func sharesFavorites(_ a: UUID, _ b: UUID) -> Bool {
        guard let first = space(a), let second = space(b), !first.isAgent, !second.isAgent else { return false }
        return a == b || dataStoreID(for: a) == dataStoreID(for: b)
    }

    /// The spaces whose favorites `spaceID` shows, in space order, itself included.
    public func favoriteSpaces(sharedWith spaceID: UUID) -> [UUID] {
        guard let space = space(spaceID) else { return [] }
        if space.isAgent { return [spaceID] }
        return orderedSpaces.filter { sharesFavorites($0.id, spaceID) }.map(\.id)
    }

    /// The favorites a space shows: its own and those of every space sharing its data store,
    /// grouped by space in space order. Each favorite stays stored under the space it was added in.
    public func favorites(of spaceID: UUID) -> [Item] {
        favoriteSpaces(sharedWith: spaceID).flatMap { children(of: .favorites(spaceID: $0)) }
    }
}
