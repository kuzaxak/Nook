// Licensed under GPL-3.0. See LICENSE.
//
//  SplitDrop.swift
//  Nook
//
//  What a tab dragged from the sidebar does on the page, as in Arc: the half under the pointer
//  takes it, beside the selected tab or in place of that pane. AppKit only, checked by
//  `scripts/tests/SplitDropCheck.swift`.
//

import AppKit

enum SplitDrop {
    enum Side: Hashable { case left, right }

    enum Outcome: Equatable {
        /// The window splits: the tab on this side, the selected tab on the other.
        case split(Side)
        /// The tab takes the pane on this side.
        case replace(Side)
    }

    /// What is dragged, as the page sees it.
    struct Dragged {
        let id: UUID
        /// A tab, not a folder.
        let isTab: Bool
        /// In the tree the window shows: a private window's own tabs, or the regular windows' shared ones.
        let isInWindow: Bool
    }

    /// The half of `page` under `point`; nil off the page, such as over the sidebar.
    static func side(of point: CGPoint, in page: CGRect) -> Side? {
        guard page.contains(point) else { return nil }
        return point.x < page.midX ? .left : .right
    }

    /// nil when the drop changes nothing: a folder or another window's tab, the selected tab beside
    /// itself, a pane's own tab, or no selected tab to pair with.
    static func outcome(of dragged: Dragged, on side: Side, selected: UUID?, split: (left: UUID, right: UUID)?) -> Outcome? {
        guard dragged.isTab, dragged.isInWindow else { return nil }
        let itemID = dragged.id
        guard let split else {
            guard let selected, selected != itemID else { return nil }
            return .split(side)
        }
        guard itemID != split.left, itemID != split.right else { return nil }
        return .replace(side)
    }

    /// The tab moves into the pane. AppKit drops nothing whose answer the drag does not allow, and
    /// a drag inside Nook allows only a move.
    static func operation(allowed: NSDragOperation) -> NSDragOperation {
        allowed.contains(.move) ? .move : allowed.intersection(.copy)
    }
}
