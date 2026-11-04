// Licensed under GPL-3.0. See LICENSE.
//
//  AddSplit.swift
//  Nook
//
//  Arc's Add Split View while its new pane is still empty: the window keeps showing its tab, or
//  its split's panes, and the command bar, open over the empty pane, picks what fills it. The
//  empty pane goes after the last pane, or beside the pane whose Add Left or Right Split asked
//  for it. It is not a tab and is never saved; dropping this leaves the window as it was.
//  Checked by `scripts/tests/AddSplitCheck.swift`.
//

import Foundation

struct AddSplit: Equatable {
    /// What the window shows, leading or top first: the selected tab alone, or the split's panes.
    let panes: [UUID]
    /// Where the empty pane goes among them.
    let index: Int
    let vertical: Bool

    /// Whether the command bar, ⌃⇧= and the sidebar's New Split offer it: unless four panes show.
    /// With no tab selected it is offered and `start` declines.
    static func isOffered(selectedItemID: UUID?, split: SplitDrop.Layout?) -> Bool {
        SplitDrop.current(split, selected: selectedItemID)?.isFull != true
    }

    /// The empty pane after what the window shows. nil with no tab selected, or four panes.
    static func start(selectedItemID: UUID?, split: SplitDrop.Layout?) -> AddSplit? {
        guard let selectedItemID, isOffered(selectedItemID: selectedItemID, split: split) else { return nil }
        guard let shown = SplitDrop.current(split, selected: selectedItemID) else {
            return AddSplit(panes: [selectedItemID], index: 1, vertical: false)
        }
        return AddSplit(panes: shown.panes, index: shown.panes.count, vertical: shown.vertical)
    }

    /// A pane's Add Right Split, or Add Left Split, or Below and Above when stacked.
    static func start(beside pane: UUID, after: Bool, selectedItemID: UUID?, split: SplitDrop.Layout?) -> AddSplit? {
        guard isOffered(selectedItemID: selectedItemID, split: split),
              let shown = SplitDrop.current(split, selected: selectedItemID), let index = shown.panes.firstIndex(of: pane) else { return nil }
        return AddSplit(panes: shown.panes, index: after ? index + 1 : index, vertical: shown.vertical)
    }

    /// The page's panes in order, nil standing for the empty one.
    var slots: [UUID?] {
        var slots = panes.map(Optional.some)
        slots.insert(nil, at: index)
        return slots
    }

    /// False once the window shows anything else: another tab or space, a pane closed, or a split
    /// changed some other way.
    func shows(selectedItemID: UUID?, split: SplitDrop.Layout?) -> Bool {
        guard let selectedItemID, panes.contains(selectedItemID) else { return false }
        return (SplitDrop.current(split, selected: selectedItemID)?.panes ?? [selectedItemID]) == panes
    }

    /// The tab that fills the empty pane when `itemID` is chosen: an open tab, or the one a typed
    /// address, a search or a history row opened. nil leaves the window as it was, as for a tab
    /// the window already shows.
    func filling(choosing itemID: UUID, selectedItemID: UUID?, split: SplitDrop.Layout?) -> UUID? {
        guard shows(selectedItemID: selectedItemID, split: split), !panes.contains(itemID) else { return nil }
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
