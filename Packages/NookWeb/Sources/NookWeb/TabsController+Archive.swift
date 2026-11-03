// Licensed under GPL-3.0. See LICENSE.
//
//  TabsController+Archive.swift
//  Nook
//
//  Normal tabs left unseen are archived, as in Arc; bookmarks stay.
//

import Foundation
import NookTabsCore

extension TabsController {
    /// Closes normal tabs unseen for longer than the archive setting into the archive list, which
    /// Reopen Closed Tab also reads, newest entry first. Tabs in use stay: each window's selected tab in every space, split panes,
    /// pages on screen or in picture in picture, and pages playing sound.
    public func archiveStaleTabs(now: Date = Date()) {
        guard !isReadOnly else { return }
        var keep = Set(device.windows.flatMap { $0.selectedItemBySpace.values })
        for window in regularWindows {
            keep.formUnion(window.selectedItemBySpace.values)
            if let split = window.split { keep.formUnion([split.leftItemID, split.rightItemID]) }
        }
        keep.formUnion(sessions.filter { $0.hasAudioContent || isOnScreen($0.itemID) }.map(\.itemID))
        let interval = TimeInterval(settings.archiveTabsAfterHours) * 3600
        let stale = tree.staleTabs(lastSeen: device.lastSeen ?? [:], now: now, after: interval, keeping: keep)
        startSeenClocks(at: now)
        for id in stale where tree.item(id) != nil { remove(id, promotingChildren: true, archiving: true) }
    }
}
