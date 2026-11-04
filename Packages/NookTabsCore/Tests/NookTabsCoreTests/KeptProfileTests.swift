// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
@testable import NookTabsCore

/// Moving a space off a profile no other space uses asks to keep or delete it. A kept profile
/// stays listed with no space, keeps its name and engine, and can be picked for a space again.
struct KeptProfileTests {
    @Test func movingTheLastSpaceOffAProfileLeavesItEmpty() throws {
        var f = Fixture()
        #expect(f.tree.profileLeftEmpty(byMoving: f.spaceB, to: f.spaceA)?.id == f.spaceB)
        #expect(f.tree.profileLeftEmpty(byMoving: f.spaceB, to: nil)?.id == f.spaceB, "a new profile leaves the old one empty too")
        #expect(f.tree.profileLeftEmpty(byMoving: f.spaceB, to: f.spaceB) == nil, "staying is no move")

        let shared = UUID()
        f.tree.createSpace(id: shared, name: "A 2", icon: "", accentHex: "#000", after: f.spaceB,
                           dataStoreID: f.spaceA, now: fixedNow)
        #expect(f.tree.profileLeftEmpty(byMoving: f.spaceA, to: f.spaceB) == nil, "another space still uses it")
    }

    @Test func aKeptProfileIsListedWithNoSpaceAndCanBePickedAgain() throws {
        var f = Fixture()
        try f.tree.renameProfile(f.spaceB, to: "QDO", now: fixedNow)
        try f.tree.setSearchEngine(profile: f.spaceB, engineId: "kagi", now: fixedNow)
        var device = DeviceState()

        let left = try #require(f.tree.profileLeftEmpty(byMoving: f.spaceB, to: f.spaceA))
        try f.tree.setProfile(f.spaceB, to: f.spaceA, now: fixedNow)
        device.keep(left)
        device.prune(against: f.tree)
        let kept = device.keptProfiles ?? []
        #expect(f.tree.profiles(keeping: kept).map(\.id) == [f.spaceA, f.spaceB])
        let listed = try #require(f.tree.profiles(keeping: kept).last)
        #expect(listed.name == "QDO" && listed.spaceIDs.isEmpty && listed.searchEngineId == "kagi")
        #expect(f.tree.profiles(keeping: []).map(\.id) == [f.spaceA], "a deleted profile is not listed")

        try f.tree.setProfile(f.spaceA, to: f.spaceB, kept: kept, now: fixedNow)
        #expect(f.tree.dataStoreID(for: f.spaceA) == f.spaceB)
        #expect(f.tree.profile(ofSpace: f.spaceA)?.name == "QDO", "the space takes the kept profile's name")
        #expect(f.tree.profile(ofSpace: f.spaceA)?.searchEngineId == "kagi")
        device.prune(against: f.tree)
        #expect(device.keptProfiles?.isEmpty == true, "a profile a space uses is no longer kept apart")
        #expect(f.tree.profiles(keeping: device.keptProfiles ?? []).map(\.id) == [f.spaceB, f.spaceA], "listed once, in space order")
    }

    @Test func keepingAgainReplacesTheEntryAndDroppingForgetsIt() throws {
        let f = Fixture()
        var device = DeviceState()
        let profile = try #require(f.tree.profile(ofSpace: f.spaceB))
        device.keep(profile)
        device.keep(profile)
        #expect(device.keptProfiles?.count == 1)
        device.dropKeptProfile(f.spaceB)
        #expect(device.keptProfiles?.isEmpty == true)
    }

    @Test func keptProfilesSurviveSaveAndLoadAndOlderFilesLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("KeptProfileTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var f = Fixture()
        var device = DeviceState()
        device.firstLaunchCompleted = true
        let left = try #require(f.tree.profileLeftEmpty(byMoving: f.spaceB, to: f.spaceA))
        try f.tree.setProfile(f.spaceB, to: f.spaceA, now: fixedNow)
        device.keep(left)
        let store = TabStore(directory: dir)
        store.save(f.tree, device)
        store.flush()
        let reloaded = TabStore(directory: dir).load(now: fixedNow)
        #expect(reloaded.tree.profiles(keeping: reloaded.device.keptProfiles ?? []).map(\.id) == [f.spaceA, f.spaceB])

        let older = try JSONSerialization.jsonObject(with: JSONEncoder().encode(DeviceState())) as? [String: Any]
        #expect(older?["keptProfiles"] == nil)
        let decoded = try JSONDecoder().decode(DeviceState.self, from: JSONSerialization.data(withJSONObject: older ?? [:]))
        #expect(decoded.keptProfiles == nil)
    }
}
