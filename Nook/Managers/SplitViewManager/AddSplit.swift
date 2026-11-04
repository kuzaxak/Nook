// Licensed under GPL-3.0. See LICENSE.
//
//  AddSplit.swift
//  Nook
//
//  Arc's Add Split View while its right pane is still empty: the selected tab stays on the left
//  and the command bar, open over the empty pane, picks what fills the right. The empty pane is
//  not a tab and is never saved; dropping this leaves the window as it was. Foundation only,
//  checked by `scripts/tests/AddSplitCheck.swift`.
//

import Foundation

struct AddSplit: Equatable {
    let leftItemID: UUID

    /// nil with no tab selected, or with the window already split, since it shows two panes at most.
    static func start(selectedItemID: UUID?, isSplit: Bool) -> AddSplit? {
        guard let selectedItemID, !isSplit else { return nil }
        return AddSplit(leftItemID: selectedItemID)
    }

    /// False once the window selects another tab or space, closes the left tab, or splits.
    func shows(selectedItemID: UUID?, isSplit: Bool) -> Bool {
        selectedItemID == leftItemID && !isSplit
    }

    /// The tab that fills the right pane when `itemID` is chosen: an open tab, or the one a
    /// typed address, a search or a history row opened. nil leaves the window as it was, as
    /// for the tab already on the left.
    func rightItem(choosing itemID: UUID, selectedItemID: UUID?, isSplit: Bool) -> UUID? {
        guard shows(selectedItemID: selectedItemID, isSplit: isSplit), itemID != leftItemID else { return nil }
        return itemID
    }
}
