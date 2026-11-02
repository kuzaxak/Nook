// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
@testable import NookTabsCore

/// Normal tabs left unseen for the archive interval are cleaned up; bookmarks never are.
struct ArchiveTests {
    let day: TimeInterval = 86_400

    @Test func onlyNormalTabsUnseenForTheIntervalAreStale() {
        var f = Fixture()
        let tabs = Parent.tabs(spaceID: f.spaceA)
        let old = f.tab("old", in: tabs)
        let fresh = f.tab("fresh", in: tabs)
        let oldChild = f.tab("old child", in: .folder(itemID: fresh))
        let kept = f.tab("kept", in: tabs)
        let folder = f.folder("folder", in: tabs)
        let inFolder = f.tab("in folder", in: .folder(itemID: folder))
        let pinned = f.tab("pinned", in: .pinned(spaceID: f.spaceA))
        let otherSpace = f.tab("other space", in: .tabs(spaceID: f.spaceB))
        let longAgo = fixedNow.addingTimeInterval(-4 * day)
        let lastSeen: [UUID: Date] = [
            old: longAgo, fresh: fixedNow.addingTimeInterval(-day), oldChild: longAgo, kept: longAgo,
            inFolder: longAgo, pinned: longAgo, otherSpace: longAgo,
        ]

        let stale = f.tree.staleTabs(lastSeen: lastSeen, now: fixedNow, after: 3 * day, keeping: [kept])
        #expect(Set(stale) == [old, oldChild, otherSpace])
    }

    @Test func aTabNeverSeenIsNotStaleYet() {
        var f = Fixture()
        f.tab("unseen", in: .tabs(spaceID: f.spaceA))
        #expect(f.tree.staleTabs(lastSeen: [:], now: fixedNow, after: 3 * day, keeping: []).isEmpty)
    }

    @Test func lastSeenSurvivesSavingAndDropsWithTheTab() throws {
        var f = Fixture()
        let tab = f.tab("tab", in: .tabs(spaceID: f.spaceA))
        var device = DeviceState()
        device.lastSeen = [tab: fixedNow]
        let decoded = try JSONDecoder().decode(DeviceState.self, from: JSONEncoder().encode(device))
        #expect(decoded.lastSeen == [tab: fixedNow])
        _ = try f.tree.close(tab, promotingChildren: true, now: fixedNow)
        device.prune(against: f.tree)
        #expect(device.lastSeen == [:])
    }
}
