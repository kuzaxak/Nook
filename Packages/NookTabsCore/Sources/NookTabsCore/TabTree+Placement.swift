// Licensed under GPL-3.0. See LICENSE.
import Foundation

extension TabTree {
    /// A tab the person chose to keep: anything in Pinned or Favorites, and anything inside a
    /// folder. Every other tab in the Tabs section is a normal tab.
    public func isBookmark(_ id: UUID) -> Bool {
        guard let chain = folderChain(of: id) else { return false }
        guard case .tabs = chain.section else { return true }
        return chain.folders.contains { items[$0]?.isFolder == true }
    }

    /// Where a new tab goes: right below `anchor` when it is a tab in `spaceID`'s Tabs section,
    /// else the top of that section. `climbingFolders` climbs out of folders and trails to the
    /// item sitting directly in the section; otherwise only trails are climbed.
    public func newTabPosition(in spaceID: UUID, after anchor: UUID?, climbingFolders: Bool) -> (Parent, UUID?) {
        guard let anchor, var item = item(anchor), !item.isFolder,
              scope(of: anchor) == .device, self.spaceID(of: anchor) == spaceID
        else { return (.tabs(spaceID: spaceID), nil) }
        if climbingFolders {
            while case .folder(let hostID) = item.parent, let host = self.item(hostID) { item = host }
        } else {
            while let host = trailParent(of: item.id).flatMap(self.item) { item = host }
        }
        return (item.parent, item.id)
    }

    /// Where a tab opened from `opener`'s page goes. With `nest`, a normal tab takes it as its
    /// last child (a trail), or as its next sibling at the depth limit. A bookmark takes no
    /// children, and neither does anything when `nest` is off: the tab lands like a new tab,
    /// outside every folder, after the tabs already opened from `opener` there (`openers`).
    public func linkTabPosition(in spaceID: UUID, opener: UUID, nest: Bool, openers: [UUID: UUID]) -> (Parent, UUID?) {
        let start: (Parent, UUID?)
        if nest, let item = item(opener), !item.isFolder, !isBookmark(opener), self.spaceID(of: opener) == spaceID {
            if canTakeChild(opener) {
                let trail = Parent.folder(itemID: opener)
                return (trail, children(of: trail).last?.id)
            }
            start = (item.parent, opener)
        } else {
            start = newTabPosition(in: spaceID, after: opener, climbingFolders: true)
        }
        var after = start.1
        let siblings = children(of: start.0)
        var index = after.flatMap { id in siblings.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
        while index < siblings.count, openers[siblings[index].id] == opener {
            after = siblings[index].id
            index += 1
        }
        return (start.0, after)
    }
}
