// Licensed under GPL-3.0. See LICENSE.
//
//  AddSplit.swift
//  Nook
//
//  Arc's Add Split View while its right pane is still empty: the selected tab stays on the left
//  and the command bar, open over the empty pane, picks what fills the right. The empty pane is
//  not a tab and is never saved; dropping this leaves the window as it was. Checked by
//  `scripts/tests/AddSplitCheck.swift`.
//

import Foundation

struct AddSplit: Equatable {
    let leftItemID: UUID

    /// nil with no tab selected, or while the window shows a split.
    static func start(selectedItemID: UUID?, split: SplitDrop.Pair?) -> AddSplit? {
        guard let selectedItemID, SplitDrop.current(split, selected: selectedItemID) == nil else { return nil }
        return AddSplit(leftItemID: selectedItemID)
    }

    /// False once the window selects another tab or space, closes the left tab, or shows a split.
    func shows(selectedItemID: UUID?, split: SplitDrop.Pair?) -> Bool {
        selectedItemID == leftItemID && SplitDrop.current(split, selected: selectedItemID) == nil
    }

    /// The tab that fills the right pane when `itemID` is chosen: an open tab, or the one a
    /// typed address, a search or a history row opened. nil leaves the window as it was, as
    /// for the tab already on the left.
    func rightItem(choosing itemID: UUID, selectedItemID: UUID?, split: SplitDrop.Pair?) -> UUID? {
        guard shows(selectedItemID: selectedItemID, split: split), itemID != leftItemID else { return nil }
        return itemID
    }

    /// A command bar row as Add Split View sees it.
    enum Row {
        /// An open tab in that space.
        case tab(spaceID: UUID?)
        /// An address, a search or a history entry, which opens in a new tab.
        case page
        /// A folder or an action.
        case other
    }

    /// Whether the bar lists `row` while it fills the empty pane: a tab of the window's space, so
    /// choosing it keeps the space, or a page to open there.
    static func offers(_ row: Row, windowSpace: UUID?) -> Bool {
        switch row {
        case .tab(let spaceID): return spaceID != nil && spaceID == windowSpace
        case .page: return true
        case .other: return false
        }
    }
}
