// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
@testable import NookTabsCore

/// What closing keeps, which tab Back returns to, and where a duplicate lands.
struct CloseBackDuplicateTests {
    @Test func closingKeepsBookmarksAndRemovesNormalTabsAndFolders() {
        var f = Fixture()
        let tabs = Parent.tabs(spaceID: f.spaceA)
        let normal = f.tab("normal", in: tabs)
        let trail = f.tab("trail", in: .folder(itemID: normal))
        let outer = f.folder("outer", in: tabs)
        let inner = f.folder("inner", in: .folder(itemID: outer))
        let inOuter = f.tab("in outer", in: .folder(itemID: outer))
        let deep = f.tab("deep", in: .folder(itemID: inner))
        let pinned = f.tab("pinned", in: .pinned(spaceID: f.spaceA))
        let favorite = f.tab("favorite", in: .favorites(spaceID: f.spaceA))

        for kept in [inOuter, deep, pinned, favorite] { #expect(f.tree.keepsItemOnClose(kept)) }
        for removed in [normal, trail, outer, inner] { #expect(!f.tree.keepsItemOnClose(removed)) }
        #expect(!f.tree.keepsItemOnClose(UUID()))
    }

    @Test func backReturnsToTheRecordedOpenerWhenLinkTabsAreNotNested() throws {
        var f = Fixture()
        let tabs = Parent.tabs(spaceID: f.spaceA)
        let opener = f.tab("opener", in: tabs)
        let position = f.tree.linkTabPosition(in: f.spaceA, opener: opener, nest: false, openers: [:])
        let link = UUID()
        _ = try f.tree.createTab(id: link, url: url("link"), title: "link", in: position.0, after: position.1, now: fixedNow)
        #expect(f.tree.trailParent(of: link) == nil, "with nesting off the link tab is a sibling")

        #expect(f.tree.opener(of: link, recorded: [link: opener]) == opener)
        #expect(f.tree.opener(of: link, recorded: [:]) == nil)

        _ = try f.tree.close(opener, promotingChildren: true, now: fixedNow)
        #expect(f.tree.opener(of: link, recorded: [link: opener]) == nil, "a closed opener is not returned to")
    }

    @Test func backReturnsToTheTrailParentWhenLinkTabsAreNested() {
        var f = Fixture()
        let tabs = Parent.tabs(spaceID: f.spaceA)
        let parent = f.tab("parent", in: tabs)
        let other = f.tab("other", in: tabs)
        let child = f.tab("child", in: .folder(itemID: parent))
        #expect(f.tree.opener(of: child, recorded: [:]) == parent)
        #expect(f.tree.opener(of: child, recorded: [child: other]) == parent, "the trail wins over a stale record")
    }

    @Test func aDuplicateLandsRightAfterTheOriginalUnderTheSameParent() throws {
        var f = Fixture()
        let tabs = Parent.tabs(spaceID: f.spaceA)
        let pinnedSection = Parent.pinned(spaceID: f.spaceA)
        let pinned = f.tab("pinned", in: pinnedSection)
        f.tab("pinned after", in: pinnedSection)
        let folder = f.folder("folder", in: tabs)
        let inFolder = f.tab("in folder", in: .folder(itemID: folder))
        f.tab("folder after", in: .folder(itemID: folder))
        let normal = f.tab("normal", in: tabs)
        _ = try f.tree.rename(normal, customTitle: "Renamed", now: fixedNow)

        let pinnedCopy = UUID()
        _ = try f.tree.duplicate(pinned, as: pinnedCopy, url: url("pinned now"), title: "pinned now", now: fixedNow)
        #expect(f.tree.item(pinnedCopy)?.parent == pinnedSection)
        #expect(f.titles(pinnedSection) == ["pinned", "pinned now", "pinned after"])
        #expect(f.tree.keepsItemOnClose(pinnedCopy), "a pinned tab's copy is pinned")

        let folderCopy = UUID()
        _ = try f.tree.duplicate(inFolder, as: folderCopy, url: url("in folder"), title: "in folder", now: fixedNow)
        #expect(f.titles(.folder(itemID: folder)) == ["in folder", "in folder", "folder after"])

        let normalCopy = UUID()
        _ = try f.tree.duplicate(normal, as: normalCopy, url: url("normal"), title: "normal", now: fixedNow)
        #expect(f.tree.item(normalCopy)?.customTitle == "Renamed", "a renamed tab's copy keeps the name")
        #expect(f.tree.children(of: tabs).map(\.id).suffix(2) == [normal, normalCopy])
        checkInvariants(f.tree)
    }

    @Test func aFolderIsNotDuplicated() {
        var f = Fixture()
        let folder = f.folder("folder", in: .tabs(spaceID: f.spaceA))
        #expect(throws: (any Error).self) {
            _ = try f.tree.duplicate(folder, as: UUID(), url: url("x"), title: "x", now: fixedNow)
        }
    }
}
