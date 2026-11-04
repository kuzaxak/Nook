// Licensed under GPL-3.0. See LICENSE.
//
//  SplitDrop.swift
//  Nook
//
//  What a tab dragged from the sidebar does on the page, as in Arc. Without a split the half under
//  the pointer takes it, beside the selected tab. Over a split the pointer picks the pane under it
//  and that pane's nearer edge: the tab opens beside the pane there, or moves there when it is a
//  pane already, and with four panes it takes the pane instead. Geometry is top-down, as SwiftUI
//  lays the page out. AppKit only, checked by `scripts/tests/SplitDropCheck.swift`.
//

import AppKit

enum SplitDrop {
    /// A pane's leading or trailing side: left or right, or top or bottom when stacked.
    enum Edge: Hashable { case leading, trailing }

    /// What is dragged, as the page sees it.
    struct Dragged {
        let id: UUID
        /// A tab, not a folder.
        let isTab: Bool
        /// In the tree the window shows: a private window's own tabs, or the regular windows' shared ones.
        let isInWindow: Bool
    }

    /// A window's split as the page lays it out.
    struct Layout: Equatable {
        var panes: [UUID]
        var vertical: Bool
        /// Each divider's position from the leading or top edge, as a fraction of the page.
        var dividers: [CGFloat]
        /// No room for another pane.
        var isFull: Bool
    }

    enum Outcome: Equatable {
        /// No split yet: the window splits with the tab on this side of the selected tab.
        case split(Edge)
        /// The tab opens as a new pane on this side of the pane.
        case insert(beside: UUID, Edge)
        /// The tab takes the pane.
        case replace(UUID)
        /// The tab, a pane already, moves to this side of the pane.
        case move(beside: UUID, Edge)
    }

    /// The split the window shows: its saved one while one of its panes is selected. Selecting
    /// another tab keeps the split saved, but the window shows that tab alone.
    static func current(_ split: Layout?, selected: UUID?) -> Layout? {
        guard let split, let selected, split.panes.contains(selected) else { return nil }
        return split
    }

    /// Dividers that make `count` panes the same size.
    static func equalDividers(_ count: Int) -> [CGFloat] {
        (1..<max(count, 1)).map { CGFloat($0) / CGFloat(count) }
    }

    /// Each pane's frame in `page`, leading or top first, with `gap` between two panes.
    static func paneFrames(in page: CGRect, count: Int, vertical: Bool, dividers: [CGFloat], gap: CGFloat) -> [CGRect] {
        let length = vertical ? page.height : page.width
        let cuts = [0] + dividers.prefix(count - 1).map { floor(length * $0) } + [length]
        return (0..<count).map { index in
            let start = cuts[index] + (index == 0 ? 0 : gap / 2)
            let size = max(1, cuts[index + 1] - (index == count - 1 ? 0 : gap / 2) - start)
            return vertical
                ? CGRect(x: page.minX, y: page.minY + start, width: page.width, height: size)
                : CGRect(x: page.minX + start, y: page.minY, width: size, height: page.height)
        }
    }

    /// The pane under `point`, the nearest one over a gutter, and the edge of it the point is nearer.
    static func pane(at point: CGPoint, in frames: [CGRect], vertical: Bool) -> (index: Int, edge: Edge) {
        let along = vertical ? point.y : point.x
        func distance(_ frame: CGRect) -> CGFloat {
            max((vertical ? frame.minY : frame.minX) - along, 0, along - (vertical ? frame.maxY : frame.maxX))
        }
        let index = frames.indices.min { distance(frames[$0]) < distance(frames[$1]) } ?? 0
        let frame = frames[index]
        return (index, along < (vertical ? frame.midY : frame.midX) ? .leading : .trailing)
    }

    /// nil when the drop changes nothing: a folder or another window's tab, the selected tab beside
    /// itself, a pane moved to where it is, or no selected tab to pair with. `pane` is the index of
    /// the pane the tab goes beside, ignored without a split.
    static func outcome(of dragged: Dragged, beside pane: Int, _ edge: Edge, selected: UUID?, split: Layout?) -> Outcome? {
        guard dragged.isTab, dragged.isInWindow else { return nil }
        guard let split = current(split, selected: selected) else {
            guard let selected, selected != dragged.id else { return nil }
            return .split(edge)
        }
        let target = split.panes[pane]
        if let from = split.panes.firstIndex(of: dragged.id) {
            let stays = target == dragged.id || (edge == .leading && pane == from + 1) || (edge == .trailing && pane == from - 1)
            return stays ? nil : .move(beside: target, edge)
        }
        return split.isFull ? .replace(target) : .insert(beside: target, edge)
    }

    /// A drop at `point` on `page`: the half of the page without a split, else the pane under it.
    static func outcome(of dragged: Dragged, at point: CGPoint, in page: CGRect, gap: CGFloat, selected: UUID?, split: Layout?) -> Outcome? {
        guard let shown = current(split, selected: selected) else {
            return outcome(of: dragged, beside: 0, point.x < page.midX ? .leading : .trailing, selected: selected, split: nil)
        }
        let frames = paneFrames(in: page, count: shown.panes.count, vertical: shown.vertical, dividers: shown.dividers, gap: gap)
        let target = pane(at: point, in: frames, vertical: shown.vertical)
        return outcome(of: dragged, beside: target.index, target.edge, selected: selected, split: shown)
    }

    /// What lights up on `page` for `outcome`: the half of the page that splits, the half of the
    /// pane on the side the tab goes, or the pane it takes.
    static func zone(of outcome: Outcome, in page: CGRect, gap: CGFloat, split: Layout?) -> CGRect {
        func half(_ frame: CGRect, _ edge: Edge, vertical: Bool) -> CGRect {
            let (first, second) = frame.divided(atDistance: (vertical ? frame.height : frame.width) / 2, from: vertical ? .minYEdge : .minXEdge)
            return edge == .leading ? first : second
        }
        guard let split else {
            if case .split(let edge) = outcome { return half(page, edge, vertical: false) }
            return page
        }
        let frames = paneFrames(in: page, count: split.panes.count, vertical: split.vertical, dividers: split.dividers, gap: gap)
        func frame(of pane: UUID) -> CGRect { split.panes.firstIndex(of: pane).map { frames[$0] } ?? page }
        switch outcome {
        case .split(let edge): return half(page, edge, vertical: false)
        case .insert(let pane, let edge), .move(let pane, let edge): return half(frame(of: pane), edge, vertical: split.vertical)
        case .replace(let pane): return frame(of: pane)
        }
    }

    /// The zone's words: "Open on the left", "Add to the right of “Docs”", "Replace “Docs”".
    static func label(of outcome: Outcome, vertical: Bool, title: (UUID) -> String) -> String {
        func side(_ edge: Edge, of pane: UUID) -> String {
            let name = "\u{201C}\(title(pane))\u{201D}"
            switch (vertical, edge) {
            case (false, .leading): return "to the left of \(name)"
            case (false, .trailing): return "to the right of \(name)"
            case (true, .leading): return "above \(name)"
            case (true, .trailing): return "below \(name)"
            }
        }
        switch outcome {
        case .split(let edge): return edge == .leading ? "Open on the left" : "Open on the right"
        case .insert(let pane, let edge): return "Add \(side(edge, of: pane))"
        case .move(let pane, let edge): return "Move \(side(edge, of: pane))"
        case .replace(let pane): return "Replace \u{201C}\(title(pane))\u{201D}"
        }
    }

    /// The tab moves into the pane. AppKit drops nothing whose answer the drag does not allow, and
    /// a drag inside Nook allows only a move.
    static func operation(allowed: NSDragOperation) -> NSDragOperation {
        allowed.contains(.move) ? .move : allowed.intersection(.copy)
    }
}
