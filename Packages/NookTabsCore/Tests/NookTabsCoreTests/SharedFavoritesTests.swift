// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
@testable import NookTabsCore

/// Spaces that use the same profile (website data store) share their favorites, as in Arc.
struct SharedFavoritesTests {
    @Test func spacesWithTheSameDataStoreShowTheSameFavorites() throws {
        var tree = TabTree()
        let store = UUID()
        let work = UUID(), side = UUID(), personal = UUID()
        tree.createSpace(id: work, name: "Work", icon: "w", accentHex: "#000", after: nil, dataStoreID: store, now: fixedNow)
        tree.createSpace(id: personal, name: "Personal", icon: "p", accentHex: "#000", after: work, now: fixedNow)
        tree.createSpace(id: side, name: "Side", icon: "s", accentHex: "#000", after: personal, dataStoreID: store, now: fixedNow)
        let a1 = UUID(), a2 = UUID(), b1 = UUID(), p1 = UUID()
        try tree.createTab(id: a1, url: url("a1"), title: "a1", in: .favorites(spaceID: work), after: nil, now: fixedNow)
        try tree.createTab(id: a2, url: url("a2"), title: "a2", in: .favorites(spaceID: work), after: a1, now: fixedNow)
        try tree.createTab(id: b1, url: url("b1"), title: "b1", in: .favorites(spaceID: side), after: nil, now: fixedNow)
        try tree.createTab(id: p1, url: url("p1"), title: "p1", in: .favorites(spaceID: personal), after: nil, now: fixedNow)

        #expect(tree.favorites(of: work).map(\.id) == [a1, a2, b1])
        #expect(tree.favorites(of: side).map(\.id) == [a1, a2, b1])
        #expect(tree.favorites(of: personal).map(\.id) == [p1])
        #expect(tree.sharesFavorites(work, side))
        #expect(!tree.sharesFavorites(work, personal))
        #expect(tree.favoriteSpaces(sharedWith: side) == [work, side])
    }

    @Test func theAgentSpaceKeepsItsOwnFavorites() throws {
        var f = Fixture()
        let agent = try #require(f.tree.ensureAgentSpace(loginsFrom: f.spaceA, now: fixedNow)?.id)
        let mine = f.tab("mine", in: .favorites(spaceID: f.spaceA))
        #expect(!f.tree.sharesFavorites(f.spaceA, agent))
        #expect(f.tree.favorites(of: agent).isEmpty)
        #expect(f.tree.favorites(of: f.spaceA).map(\.id) == [mine])
    }
}
