// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
import NookTabsCore
@testable import NookWeb

/// What space sync needs from the controller: word of every tree edit, and a space deleted on
/// another Mac leaving this Mac's logins for its profile in place.
@MainActor
struct SpaceSyncHookTests {
    @Test func treeEditsAreReportedAndWindowStateIsNot() throws {
        let host = try Host()
        let spaceID = try #require(host.window.spaceID)
        var reports = 0
        host.tabs.onTreeChanged = { reports += 1 }

        host.tabs.updateSpace(spaceID, name: "Renamed", icon: nil, accentHex: nil)
        #expect(reports == 1)
        host.tabs.mirror(host.window)
        host.tabs.setOpenPage(UUID(), OpenPage(url: URL(string: "https://example.invalid")!, title: ""))
        #expect(reports == 1)
    }

    @Test(arguments: [true, false])
    func aSpaceDeletedOnAnotherMacKeepsItsProfileHere(keepingLeftProfile: Bool) throws {
        let host = try Host()
        let other = try #require(host.tabs.createSpace(name: "Work", icon: "", accentHex: "#000000", after: nil, profileName: "Job"))
        let store = try #require(host.tabs.tree.dataStoreID(for: other))

        host.tabs.deleteSpace(other, keepingLeftProfile: keepingLeftProfile)

        #expect(host.tabs.tree.space(other) == nil)
        #expect((host.tabs.device.keptProfiles?.contains { $0.id == store && $0.name == "Job" } ?? false) == keepingLeftProfile)
    }
}
