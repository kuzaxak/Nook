// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
@testable import NookTabsCore

/// Where Cmd+T and link tabs land, and which tabs count as bookmarks.
struct PlacementTests {
    @Test func bookmarksAreSyncedTabsAndAnythingInAFolder() {
        var f = Fixture()
        let tabs = Parent.tabs(spaceID: f.spaceA)
        let top = f.tab("top", in: tabs)
        let child = f.tab("child", in: .folder(itemID: top))
        let folder = f.folder("folder", in: tabs)
        let inFolder = f.tab("in folder", in: .folder(itemID: folder))
        let trailInFolder = f.tab("trail in folder", in: .folder(itemID: inFolder))
        let pinned = f.tab("pinned", in: .pinned(spaceID: f.spaceA))
        let favorite = f.tab("favorite", in: .favorites(spaceID: f.spaceA))

        #expect(!f.tree.isBookmark(top))
        #expect(!f.tree.isBookmark(child))
        #expect(f.tree.isBookmark(inFolder))
        #expect(f.tree.isBookmark(trailInFolder))
        #expect(f.tree.isBookmark(pinned))
        #expect(f.tree.isBookmark(favorite))
    }

    @Test func newTabFromAFolderLandsBelowTheOutermostFolder() {
        var f = Fixture()
        let tabs = Parent.tabs(spaceID: f.spaceA)
        let outer = f.folder("outer", in: tabs)
        let inner = f.folder("inner", in: .folder(itemID: outer))
        let deep = f.tab("deep", in: .folder(itemID: inner))
        let inOuter = f.tab("in outer", in: .folder(itemID: outer))
        let trail = f.tab("trail", in: .folder(itemID: inOuter))

        for anchor in [deep, inOuter, trail] {
            let position = f.tree.newTabPosition(in: f.spaceA, after: anchor, climbingFolders: true)
            #expect(position.0 == tabs)
            #expect(position.1 == outer)
        }
        // Off: only trails are climbed, so the tab stays in the folder.
        let off = f.tree.newTabPosition(in: f.spaceA, after: trail, climbingFolders: false)
        #expect(off.0 == .folder(itemID: outer))
        #expect(off.1 == inOuter)
    }

    @Test func newTabFromATopLevelTabLandsRightBelowIt() {
        var f = Fixture()
        let tabs = Parent.tabs(spaceID: f.spaceA)
        let top = f.tab("top", in: tabs)
        let child = f.tab("child", in: .folder(itemID: top))
        for climbing in [true, false] {
            let position = f.tree.newTabPosition(in: f.spaceA, after: child, climbingFolders: climbing)
            #expect(position.0 == tabs)
            #expect(position.1 == top)
        }
    }

    @Test func newTabFromAPinnedTabOrNothingGoesToTheTopOfTabs() {
        var f = Fixture()
        let tabs = Parent.tabs(spaceID: f.spaceA)
        let pinnedFolder = f.folder("pinned folder", in: .pinned(spaceID: f.spaceA))
        let inPinnedFolder = f.tab("in pinned folder", in: .folder(itemID: pinnedFolder))
        let favorite = f.tab("favorite", in: .favorites(spaceID: f.spaceA))
        for anchor in [inPinnedFolder, favorite, nil] {
            let position = f.tree.newTabPosition(in: f.spaceA, after: anchor, climbingFolders: true)
            #expect(position.0 == tabs)
            #expect(position.1 == nil)
        }
    }

    @Test func linkTabsNestUnderANormalOpenerWhenNestingIsOn() {
        var f = Fixture()
        let tabs = Parent.tabs(spaceID: f.spaceA)
        let opener = f.tab("opener", in: tabs)
        let first = f.tab("first", in: .folder(itemID: opener))
        let position = f.tree.linkTabPosition(in: f.spaceA, opener: opener, nest: true, openers: [:])
        #expect(position.0 == .folder(itemID: opener))
        #expect(position.1 == first)
    }

    @Test func linkTabsFromABookmarkNeverNestAndLeaveTheFolder() {
        var f = Fixture()
        let tabs = Parent.tabs(spaceID: f.spaceA)
        let folder = f.folder("folder", in: tabs)
        let inFolder = f.tab("in folder", in: .folder(itemID: folder))
        let pinned = f.tab("pinned", in: .pinned(spaceID: f.spaceA))
        for nest in [true, false] {
            let fromFolder = f.tree.linkTabPosition(in: f.spaceA, opener: inFolder, nest: nest, openers: [:])
            #expect(fromFolder.0 == tabs)
            #expect(fromFolder.1 == folder)
            let fromPinned = f.tree.linkTabPosition(in: f.spaceA, opener: pinned, nest: nest, openers: [:])
            #expect(fromPinned.0 == tabs)
            #expect(fromPinned.1 == nil)
        }
    }

    @Test func backgroundLinkTabsKeepClickOrderWithNestingOff() throws {
        var f = Fixture()
        let tabs = Parent.tabs(spaceID: f.spaceA)
        let opener = f.tab("opener", in: tabs)
        let other = f.tab("other", in: tabs)
        var openers: [UUID: UUID] = [:]
        for name in ["one", "two", "three"] {
            let position = f.tree.linkTabPosition(in: f.spaceA, opener: opener, nest: false, openers: openers)
            #expect(position.0 == tabs)
            let id = UUID()
            try f.tree.createTab(id: id, url: url(name), title: name, in: position.0, after: position.1, now: fixedNow)
            openers[id] = opener
        }
        #expect(f.titles(tabs) == ["opener", "one", "two", "three", "other"])
        _ = other
        checkInvariants(f.tree)
    }

    @Test func linkTabsFromAPinnedTabKeepClickOrderAtTheTopOfTabs() throws {
        var f = Fixture()
        let tabs = Parent.tabs(spaceID: f.spaceA)
        f.tab("existing", in: tabs)
        let pinned = f.tab("pinned", in: .pinned(spaceID: f.spaceA))
        var openers: [UUID: UUID] = [:]
        for name in ["one", "two"] {
            let position = f.tree.linkTabPosition(in: f.spaceA, opener: pinned, nest: true, openers: openers)
            let id = UUID()
            try f.tree.createTab(id: id, url: url(name), title: name, in: position.0, after: position.1, now: fixedNow)
            openers[id] = pinned
        }
        #expect(f.titles(tabs) == ["one", "two", "existing"])
    }

    @Test func openerRecordsSurviveSavingAndDropWithEitherTab() throws {
        var f = Fixture()
        let tabs = Parent.tabs(spaceID: f.spaceA)
        let opener = f.tab("opener", in: tabs)
        let link = f.tab("link", in: tabs)
        let other = f.tab("other", in: tabs)
        let otherLink = f.tab("other link", in: tabs)
        var device = DeviceState()
        device.openers = [link: opener, otherLink: other]

        let decoded = try JSONDecoder().decode(DeviceState.self, from: JSONEncoder().encode(device))
        #expect(decoded.openers == [link: opener, otherLink: other])
        // Files written before opener records still load.
        let legacy = try JSONDecoder().decode(DeviceState.self, from: Data(#"{"openFolders":[],"openPages":[],"windows":[],"closed":[],"firstLaunchCompleted":true}"#.utf8))
        #expect(legacy.openers == nil)

        _ = try f.tree.close(opener, promotingChildren: true, now: fixedNow)
        _ = try f.tree.close(otherLink, promotingChildren: true, now: fixedNow)
        device.prune(against: f.tree)
        #expect(device.openers == [:])
    }

    @Test func aLinkTabFromAnotherSpaceGoesToTheTopOfTabs() {
        var f = Fixture()
        let opener = f.tab("opener", in: .tabs(spaceID: f.spaceB))
        f.tab("a", in: .tabs(spaceID: f.spaceA))
        let position = f.tree.linkTabPosition(in: f.spaceA, opener: opener, nest: true, openers: [:])
        #expect(position.0 == .tabs(spaceID: f.spaceA))
        #expect(position.1 == nil)
    }
}
