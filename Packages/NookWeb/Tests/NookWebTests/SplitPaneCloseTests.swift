// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
import NookTabsCore
@testable import NookWeb

/// Closing a pane's tab, as Cmd+W or the pane's close button do, takes that pane out of the split:
/// the pane beside it takes the selection, and with one pane left the split ends.
@MainActor
struct SplitPaneCloseTests {
    @Test func closingAPaneKeepsTheOtherPanes() throws {
        let host = try Host()
        let spaceID = try #require(host.window.spaceID)
        let panes = try (0..<3).map { index in
            try #require(host.tabs.open(url: URL(string: "https://pane\(index).invalid")!, in: host.window,
                                        placement: .background, parent: .tabs(spaceID: spaceID)))
        }
        host.window.split = SplitRecord(panes)
        host.tabs.select(panes[1], in: host.window)

        host.tabs.close(panes[1])
        #expect(host.window.split?.itemIDs == [panes[0], panes[2]])
        #expect(host.window.selectedItemID == panes[2], "the next pane takes the selection")

        host.tabs.close(panes[0])
        #expect(host.window.split == nil, "one tab left is no split")
        #expect(host.window.selectedItemID == panes[2], "a pane that is not selected leaves the selection alone")
    }

    @Test func closingTheLastPaneSelectsThePaneBeforeIt() throws {
        let host = try Host()
        let spaceID = try #require(host.window.spaceID)
        let panes = try (0..<2).map { index in
            try #require(host.tabs.open(url: URL(string: "https://pane\(index).invalid")!, in: host.window,
                                        placement: .background, parent: .tabs(spaceID: spaceID)))
        }
        host.window.split = SplitRecord(panes)
        host.tabs.select(panes[1], in: host.window)

        host.tabs.close(panes[1])
        #expect(host.window.split == nil)
        #expect(host.window.selectedItemID == panes[0])
    }
}
