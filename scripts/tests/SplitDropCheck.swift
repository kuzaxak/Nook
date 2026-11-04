// Licensed under GPL-3.0. See LICENSE.
// swiftc Nook/Components/Browser/Window/SplitDrop.swift scripts/tests/SplitDropCheck.swift -o /tmp/splitdrop && /tmp/splitdrop

import AppKit

@main
struct SplitDropCheck {
    static func main() {
        let page = CGRect(x: 0, y: 0, width: 800, height: 600)
        // The half of the page under the pointer takes the tab; a pointer over the sidebar, beside
        // the page, is no drop on it, so a drag that stays in the sidebar only reorders.
        precondition(SplitDrop.side(of: CGPoint(x: 100, y: 300), in: page) == .left)
        precondition(SplitDrop.side(of: CGPoint(x: 700, y: 300), in: page) == .right)
        precondition(SplitDrop.side(of: CGPoint(x: -40, y: 300), in: page) == nil, "over the sidebar")

        let selected = UUID(), dragged = UUID(), left = UUID(), right = UUID()
        func tab(_ id: UUID) -> SplitDrop.Dragged { SplitDrop.Dragged(id: id, isTab: true, isInWindow: true) }
        // No split: the dragged tab goes to that side, the selected tab to the other.
        precondition(SplitDrop.outcome(of: tab(dragged), on: .left, selected: selected, split: nil) == .split(.left))
        precondition(SplitDrop.outcome(of: tab(dragged), on: .right, selected: selected, split: nil) == .split(.right))
        // The selected tab cannot sit beside itself, and with nothing selected there is no pair.
        precondition(SplitDrop.outcome(of: tab(selected), on: .right, selected: selected, split: nil) == nil)
        precondition(SplitDrop.outcome(of: tab(dragged), on: .right, selected: nil, split: nil) == nil)
        // Only a tab of this window's own tree: a folder row is no page, and a private window's
        // tabs stay in it, as regular tabs stay out of private windows.
        let folder = SplitDrop.Dragged(id: dragged, isTab: false, isInWindow: true)
        precondition(SplitDrop.outcome(of: folder, on: .right, selected: selected, split: nil) == nil, "a folder")
        let elsewhere = SplitDrop.Dragged(id: dragged, isTab: true, isInWindow: false)
        precondition(SplitDrop.outcome(of: elsewhere, on: .right, selected: selected, split: nil) == nil, "another window's tab")

        // A split: the tab replaces the pane it is dropped on.
        let pair = (left: left, right: right)
        precondition(SplitDrop.outcome(of: tab(dragged), on: .left, selected: left, split: pair) == .replace(.left))
        precondition(SplitDrop.outcome(of: tab(dragged), on: .right, selected: left, split: pair) == .replace(.right))
        precondition(SplitDrop.outcome(of: folder, on: .left, selected: left, split: pair) == nil, "a folder on a pane")
        // A pane's own tab changes nothing, on its side or on the other one.
        precondition(SplitDrop.outcome(of: tab(left), on: .left, selected: left, split: pair) == nil)
        precondition(SplitDrop.outcome(of: tab(right), on: .left, selected: left, split: pair) == nil)

        // The answer is one the drag allows: a tab dragged inside Nook allows only a move, and
        // AppKit drops nothing that answers with another operation.
        precondition(SplitDrop.operation(allowed: .move) == .move, "a drag from the sidebar")
        precondition(SplitDrop.operation(allowed: [.copy, .move, .generic]) == .move)
        precondition(SplitDrop.operation(allowed: .copy) == .copy)
        precondition(SplitDrop.operation(allowed: []) == [])
        print("SplitDropCheck passed")
    }
}
