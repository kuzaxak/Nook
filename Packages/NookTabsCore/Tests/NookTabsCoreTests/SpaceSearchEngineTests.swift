// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
@testable import NookTabsCore

/// Each space can search with its own engine; nil follows the app's default.
struct SpaceSearchEngineTests {
    @Test func aSpaceKeepsItsOwnEngineAndCanGoBackToTheDefault() throws {
        var f = Fixture()
        #expect(f.tree.space(f.spaceA)?.searchEngineId == nil)
        let change = try f.tree.setSearchEngine(f.spaceA, engineId: "kagi", now: fixedNow)
        #expect(f.tree.space(f.spaceA)?.searchEngineId == "kagi")
        #expect(f.tree.space(f.spaceB)?.searchEngineId == nil)
        try f.tree.setSearchEngine(f.spaceA, engineId: nil, now: fixedNow)
        #expect(f.tree.space(f.spaceA)?.searchEngineId == nil)
        f.tree.apply(change)
        #expect(f.tree.space(f.spaceA)?.searchEngineId == nil, "undo restores the record before the first change")
        #expect(throws: TreeError.missingSpace) { try f.tree.setSearchEngine(UUID(), engineId: "google", now: fixedNow) }
    }

    @Test func spacesSavedBeforeThisKeepTheDefault() throws {
        var f = Fixture()
        try f.tree.setSearchEngine(f.spaceA, engineId: "kagi", now: fixedNow)
        let data = try JSONEncoder().encode(f.tree)
        #expect(try JSONDecoder().decode(TabTree.self, from: data).space(f.spaceA)?.searchEngineId == "kagi")
        let legacy = String(decoding: data, as: UTF8.self).replacingOccurrences(of: #","searchEngineId":"kagi""#, with: "")
        #expect(try JSONDecoder().decode(TabTree.self, from: Data(legacy.utf8)).space(f.spaceA)?.searchEngineId == nil)
    }
}
