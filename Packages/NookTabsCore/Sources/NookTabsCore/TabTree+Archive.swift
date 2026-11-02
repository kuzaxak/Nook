// Licensed under GPL-3.0. See LICENSE.
import Foundation

extension TabTree {
    /// Normal tabs, in every space, last seen more than `interval` before `now`. A tab with no
    /// record has not started its clock; `keeping` holds tabs in use (selected, playing, split).
    public func staleTabs(lastSeen: [UUID: Date], now: Date, after interval: TimeInterval, keeping: Set<UUID>) -> [UUID] {
        items.values.compactMap { item in
            guard item.deletedAt == nil, !item.isFolder, !keeping.contains(item.id),
                  case .tabs = section(of: item.id), !isBookmark(item.id),
                  let seen = lastSeen[item.id], now.timeIntervalSince(seen) > interval
            else { return nil }
            return item.id
        }
    }
}
