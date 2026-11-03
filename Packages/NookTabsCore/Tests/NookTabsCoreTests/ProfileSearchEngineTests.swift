// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
@testable import NookTabsCore

/// A profile searches with one engine, kept on each of its spaces; nil follows the app's default.
struct ProfileSearchEngineTests {
    @Test func aProfileSetsTheEngineOfAllItsSpacesAndCanGoBackToTheDefault() throws {
        var f = Fixture()
        let shared = UUID()
        f.tree.createSpace(id: shared, name: "Work 2", icon: "", accentHex: "#000", after: f.spaceB,
                           dataStoreID: f.spaceA, now: fixedNow)
        #expect(f.tree.profile(ofSpace: f.spaceA)?.searchEngineId == nil)
        let change = try f.tree.setSearchEngine(profile: f.spaceA, engineId: "kagi", now: fixedNow)
        #expect(f.tree.profile(ofSpace: shared)?.searchEngineId == "kagi")
        #expect(f.tree.space(f.spaceA)?.searchEngineId == "kagi")
        #expect(f.tree.space(shared)?.searchEngineId == "kagi")
        #expect(f.tree.profile(ofSpace: f.spaceB)?.searchEngineId == nil)
        try f.tree.setSearchEngine(profile: f.spaceA, engineId: nil, now: fixedNow)
        #expect(f.tree.profile(ofSpace: f.spaceA)?.searchEngineId == nil)
        f.tree.apply(change)
        #expect(f.tree.space(shared)?.searchEngineId == nil, "undo restores the records before the first change")
        #expect(throws: TreeError.missingSpace) { try f.tree.setSearchEngine(profile: UUID(), engineId: "google", now: fixedNow) }
    }

    @Test func aSpaceTakesTheEngineOfTheProfileItMovesTo() throws {
        var f = Fixture()
        try f.tree.setSearchEngine(profile: f.spaceA, engineId: "kagi", now: fixedNow)
        try f.tree.setProfile(f.spaceB, to: f.spaceA, now: fixedNow)
        #expect(f.tree.space(f.spaceB)?.searchEngineId == "kagi")
        try f.tree.setProfile(f.spaceB, to: nil, now: fixedNow)
        #expect(f.tree.profile(ofSpace: f.spaceB)?.searchEngineId == nil, "a new profile starts on the default")
    }

    @Test func spacesThatDisagreeAfterASyncSearchWithTheFirstSetEngine() throws {
        var f = Fixture()
        let shared = UUID()
        f.tree.createSpace(id: shared, name: "Work 2", icon: "", accentHex: "#000", after: f.spaceB,
                           dataStoreID: f.spaceA, now: fixedNow)
        f.tree.spaces[shared]?.searchEngineId = "duckduckgo"
        #expect(f.tree.profile(ofSpace: f.spaceA)?.searchEngineId == "duckduckgo")
    }

    @Test func spacesSavedBeforeThisKeepTheDefault() throws {
        var f = Fixture()
        try f.tree.setSearchEngine(profile: f.spaceA, engineId: "kagi", now: fixedNow)
        let data = try JSONEncoder().encode(f.tree)
        #expect(try JSONDecoder().decode(TabTree.self, from: data).profile(ofSpace: f.spaceA)?.searchEngineId == "kagi")
        let legacy = try JSONSerialization.data(withJSONObject: removingKey("searchEngineId", from: JSONSerialization.jsonObject(with: data)))
        #expect(try JSONDecoder().decode(TabTree.self, from: legacy).profile(ofSpace: f.spaceA)?.searchEngineId == nil)
    }

    private func removingKey(_ key: String, from json: Any) -> Any {
        if let object = json as? [String: Any] {
            return object.filter { $0.key != key }.mapValues { removingKey(key, from: $0) }
        }
        if let array = json as? [Any] { return array.map { removingKey(key, from: $0) } }
        return json
    }
}
