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

    @Test func archivedTabsKeepTheirOwnListAndReopenNewestFirst() {
        var f = Fixture()
        let tabs = Parent.tabs(spaceID: f.spaceA)
        func entry(_ name: String, at offset: TimeInterval) -> ClosedEntry {
            let id = f.tab(name, in: tabs)
            return ClosedEntry(items: [f.tree.item(id)!], section: tabs, closedAt: fixedNow.addingTimeInterval(offset))
        }
        var device = DeviceState()
        let manual = entry("manual", at: 0)
        device.pushClosed(manual)
        for index in 0..<(DeviceState.archivedLimit + 20) {
            device.pushArchived(entry("archived \(index)", at: 10))
        }
        // A big sweep never pushes a manual close out, and its own list stays bounded.
        #expect(device.closed == [manual])
        #expect(device.archived?.count == DeviceState.archivedLimit)

        // Reopen takes the newest entry of either list.
        #expect(device.newestClosed == device.archived?.last)
        device.dropNewestClosed()
        #expect(device.archived?.count == DeviceState.archivedLimit - 1)
        let later = entry("later manual", at: 20)
        device.pushClosed(later)
        #expect(device.newestClosed == later)

        // Entries for items back in the tree leave both lists.
        let ids = Set([later.items[0].id, device.archived!.last!.items[0].id])
        device.dropClosed(containing: ids)
        #expect(device.closed == [manual])
        #expect(device.archived?.count == DeviceState.archivedLimit - 2)
    }
}
