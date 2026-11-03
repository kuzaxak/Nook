// Licensed under GPL-3.0. See LICENSE.
//
//  NewTabPlacementCheck.swift
//  Nook
//
//  Where Cmd+T and Cmd+click tabs land (brief WP2). The rules live in NookTabsCore, which needs
//  only Foundation, so this compiles its sources directly:
//
//    swiftc -parse-as-library Packages/NookTabsCore/Sources/NookTabsCore/*.swift \
//           Packages/NookWeb/Checks/NewTabPlacementCheck.swift -o /tmp/new-tab-placement-check && /tmp/new-tab-placement-check
//

import Foundation

@main
struct NewTabPlacementCheck {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let space = UUID()
        var tree = TabTree()
        tree.createSpace(id: space, name: "A", icon: "a", accentHex: "#000", after: nil, now: now)
        let tabs = Parent.tabs(spaceID: space)
        func tab(_ name: String, in parent: Parent) throws -> UUID {
            let id = UUID()
            try tree.createTab(id: id, url: URL(string: "https://example.com/\(name)")!, title: name,
                               in: parent, after: tree.children(of: parent).last?.id, now: now)
            return id
        }

        let first = try tab("first", in: tabs)
        let folder = UUID()
        try tree.createFolder(id: folder, title: "Boards", in: tabs, after: first, now: now)
        let inner = UUID()
        try tree.createFolder(id: inner, title: "Inner", in: .folder(itemID: folder), after: nil, now: now)
        let inFolder = try tab("in folder", in: .folder(itemID: inner))
        let pinned = try tab("pinned", in: .pinned(spaceID: space))
        let favorite = try tab("favorite", in: .favorites(spaceID: space))

        // Cmd+T on a tab inside a folder, at any depth: a top-level tab right below that folder.
        let fromFolder = tree.newTabPosition(in: space, after: inFolder, climbingFolders: true)
        precondition(fromFolder.0 == tabs && fromFolder.1 == folder, "below the outermost folder")
        let insideOff = tree.newTabPosition(in: space, after: inFolder, climbingFolders: false)
        precondition(insideOff.0 == .folder(itemID: inner), "with the setting off it stays in the folder")

        // Cmd+T on a pinned tab or a favorite, or with nothing selected: the top of Tabs.
        for anchor in [pinned, favorite, nil] as [UUID?] {
            let position = tree.newTabPosition(in: space, after: anchor, climbingFolders: true)
            precondition(position.0 == tabs && position.1 == nil, "top of Tabs")
        }

        // Cmd+click follows the nesting setting: a child of the opener, or a sibling right after it.
        let nested = tree.linkTabPosition(in: space, opener: first, nest: true, openers: [:])
        precondition(nested.0 == .folder(itemID: first), "nested under the opener")
        let flat = tree.linkTabPosition(in: space, opener: first, nest: false, openers: [:])
        precondition(flat.0 == tabs && flat.1 == first, "right after the opener")
        // A link opened from a bookmark never lands in a folder or under the bookmark.
        let fromBookmark = tree.linkTabPosition(in: space, opener: inFolder, nest: true, openers: [:])
        precondition(fromBookmark.0 == tabs, "out of the folder")

        print("NewTabPlacementCheck passed")
    }
}
