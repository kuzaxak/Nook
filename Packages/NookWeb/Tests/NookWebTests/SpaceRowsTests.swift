// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Observation
import Testing
import NookTabsCore
@testable import NookWeb

/// A space's sidebar rows. A space page's body asks for them more than once each time it runs, so
/// asking again with nothing changed must not walk and sort the whole tree again; the rows still
/// follow every change to the tree and to which folders are open, and a view reading them hears it.
@MainActor
struct SpaceRowsTests {
    @Test func askingAgainForUnchangedRowsIsCheap() throws {
        let host = try Host()
        let spaceID = try #require(host.window.spaceID)
        host.tabs.perform(.main, "seed", undoable: false) { tree in
            var after: UUID?
            for index in 0..<1000 {
                let id = UUID()
                _ = try tree.createTab(id: id, url: URL(string: "https://tab\(index).invalid")!, title: "Tab \(index)",
                                       in: .tabs(spaceID: spaceID), after: after)
                after = id
            }
            return Change()
        }
        #expect(host.tabs.rows(space: spaceID).count > 1000)

        let elapsed = ContinuousClock().measure {
            for _ in 0..<100 { _ = host.tabs.rows(space: spaceID) }
        }
        #expect(elapsed < .milliseconds(25), "100 asks for unchanged rows took \(elapsed)")
    }

    @Test func rowsFollowTabsAndFolders() throws {
        let host = try Host()
        let spaceID = try #require(host.window.spaceID)
        func ids() -> [UUID] { host.tabs.rows(space: spaceID).map(\.id) }
        let before = ids()

        let tab = try #require(host.tabs.open(url: URL(string: "https://one.invalid")!, in: host.window,
                                               placement: .background, parent: .tabs(spaceID: spaceID)))
        #expect(ids().contains(tab))

        let folder = try #require(host.tabs.createFolder(title: "Folder", in: .tabs(spaceID: spaceID), after: nil))
        let inside = try #require(host.tabs.open(url: URL(string: "https://inside.invalid")!, in: host.window,
                                                  placement: .background, parent: .folder(itemID: folder)))
        #expect(ids().contains(folder) && ids().contains(inside), "a new folder opens with its tab showing")
        host.tabs.toggleFolder(folder)
        #expect(ids().contains(folder) && !ids().contains(inside), "a closed folder hides its tab")
        host.tabs.toggleFolder(folder)
        #expect(ids().contains(inside))

        host.tabs.remove(tab)
        #expect(!ids().contains(tab))
        #expect(ids() == host.tabs.tree.visibleRows(space: spaceID, openFolders: host.tabs.device.openFolders).map(\.id))
        #expect(Set(before).isSubset(of: Set(ids())))
    }

    @Test func aViewReadingRowsHearsChanges() throws {
        let host = try Host()
        let spaceID = try #require(host.window.spaceID)
        let folder = try #require(host.tabs.createFolder(title: "Folder", in: .tabs(spaceID: spaceID), after: nil))
        _ = host.tabs.rows(space: spaceID)

        func changes(after edit: () -> Void) -> Bool {
            var heard = false
            withObservationTracking { _ = host.tabs.rows(space: spaceID) } onChange: { heard = true }
            edit()
            return heard
        }
        #expect(changes { _ = host.tabs.open(url: URL(string: "https://two.invalid")!, in: host.window, placement: .background, parent: .tabs(spaceID: spaceID)) },
                "a new tab")
        #expect(changes { host.tabs.toggleFolder(folder) }, "a folder closing")
    }
}
