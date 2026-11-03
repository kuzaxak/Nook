// Licensed under GPL-3.0. See LICENSE.
import Foundation

extension TabTree {
    /// Whether closing `id` ends its page and keeps it, as for a pinned tab: true for bookmarks.
    /// A normal tab and any folder are removed instead.
    public func keepsItemOnClose(_ id: UUID) -> Bool {
        guard let item = item(id), !item.isFolder else { return false }
        return isBookmark(id)
    }

    /// The tab Back returns to once `id`'s page has no history: its trail parent, else the
    /// opener `recorded` for a link tab placed as a sibling, while that tab still exists.
    public func opener(of id: UUID, recorded: [UUID: UUID]) -> UUID? {
        if let parent = trailParent(of: id) { return parent }
        return recorded[id].flatMap { item($0) != nil ? $0 : nil }
    }

    /// A copy of tab `id` showing `url`, right after it under the same parent, with its custom title.
    public mutating func duplicate(_ id: UUID, as copyID: UUID, url: URL, title: String, now: Date = Date()) throws -> Change {
        guard let item = item(id) else { throw TreeError.missingItem }
        guard case .tab = item.kind else { throw TreeError.notATab }
        var change = try createTab(id: copyID, url: url, title: title, in: item.parent, after: id, now: now)
        if let customTitle = item.customTitle { change.merge(try rename(copyID, customTitle: customTitle, now: now)) }
        return change
    }
}
