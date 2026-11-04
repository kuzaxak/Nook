// Licensed under GPL-3.0. See LICENSE.
// swiftc Nook/Components/Browser/Window/SplitDrop.swift scripts/tests/SplitDropCheck.swift -o /tmp/splitdrop && /tmp/splitdrop

import AppKit

@main
struct SplitDropCheck {
    static func main() {
        let page = CGRect(x: 0, y: 0, width: 800, height: 600)
        let selected = UUID(), dragged = UUID(), a = UUID(), b = UUID(), c = UUID(), d = UUID()
        func tab(_ id: UUID) -> SplitDrop.Dragged { SplitDrop.Dragged(id: id, isTab: true, isInWindow: true) }
        func layout(_ panes: [UUID], vertical: Bool = false) -> SplitDrop.Layout {
            SplitDrop.Layout(panes: panes, vertical: vertical, dividers: SplitDrop.equalDividers(panes.count), isFull: panes.count == 4)
        }
        func drop(_ id: UUID, at x: CGFloat, _ y: CGFloat = 300, selected: UUID?, split: SplitDrop.Layout?) -> SplitDrop.Outcome? {
            SplitDrop.outcome(of: tab(id), at: CGPoint(x: x, y: y), in: page, gap: 8, selected: selected, split: split)
        }

        // No split: the dragged tab takes the half under the pointer, the selected tab the other.
        precondition(drop(dragged, at: 100, selected: selected, split: nil) == .split(.leading))
        precondition(drop(dragged, at: 700, selected: selected, split: nil) == .split(.trailing))
        precondition(SplitDrop.zone(of: .split(.leading), in: page, gap: 8, split: nil) == CGRect(x: 0, y: 0, width: 400, height: 600))
        // The selected tab cannot sit beside itself, and with nothing selected there is no pair.
        precondition(drop(selected, at: 700, selected: selected, split: nil) == nil)
        precondition(drop(dragged, at: 700, selected: nil, split: nil) == nil)
        // Only a tab of this window's own tree: a folder row is no page, and a private window's
        // tabs stay in it, as regular tabs stay out of private windows.
        let folder = SplitDrop.Dragged(id: dragged, isTab: false, isInWindow: true)
        let elsewhere = SplitDrop.Dragged(id: dragged, isTab: true, isInWindow: false)
        precondition(SplitDrop.outcome(of: folder, at: CGPoint(x: 700, y: 300), in: page, gap: 8, selected: selected, split: nil) == nil, "a folder")
        precondition(SplitDrop.outcome(of: elsewhere, at: CGPoint(x: 700, y: 300), in: page, gap: 8, selected: selected, split: nil) == nil, "another window's tab")

        // A split: the pane under the pointer and its nearer edge take the tab as a new pane.
        let pair = layout([a, b])
        precondition(drop(dragged, at: 100, selected: a, split: pair) == .insert(beside: a, .leading))
        precondition(drop(dragged, at: 300, selected: a, split: pair) == .insert(beside: a, .trailing))
        precondition(drop(dragged, at: 500, selected: a, split: pair) == .insert(beside: b, .leading))
        precondition(drop(dragged, at: 700, selected: a, split: pair) == .insert(beside: b, .trailing))
        precondition(drop(dragged, at: 401, selected: a, split: pair) == .insert(beside: b, .leading), "the gutter belongs to a pane")
        precondition(SplitDrop.zone(of: .insert(beside: b, .trailing), in: page, gap: 8, split: pair) == CGRect(x: 602, y: 0, width: 198, height: 600))
        precondition(SplitDrop.outcome(of: folder, at: CGPoint(x: 100, y: 300), in: page, gap: 8, selected: a, split: pair) == nil, "a folder on a pane")
        // Stacked panes take it above or below.
        let stacked = layout([a, b], vertical: true)
        precondition(drop(dragged, at: 700, 100, selected: a, split: stacked) == .insert(beside: a, .leading))
        precondition(drop(dragged, at: 700, 550, selected: a, split: stacked) == .insert(beside: b, .trailing))
        precondition(SplitDrop.zone(of: .insert(beside: b, .trailing), in: page, gap: 8, split: stacked) == CGRect(x: 0, y: 452, width: 800, height: 148))
        // Four panes are the most: the tab takes the pane under the pointer.
        let four = layout([a, b, c, d])
        precondition(drop(dragged, at: 250, selected: a, split: four) == .replace(b))
        precondition(drop(dragged, at: 790, selected: a, split: four) == .replace(d))
        precondition(SplitDrop.zone(of: .replace(b), in: page, gap: 8, split: four) == CGRect(x: 204, y: 0, width: 192, height: 600))
        // A pane dragged onto the page moves there, and changes nothing where it already is.
        let three = layout([a, b, c])
        precondition(drop(a, at: 790, selected: b, split: three) == .move(beside: c, .trailing))
        precondition(drop(c, at: 10, selected: b, split: three) == .move(beside: a, .leading))
        precondition(drop(a, at: 100, selected: b, split: three) == nil, "onto itself")
        precondition(drop(a, at: 300, selected: b, split: three) == nil, "just before the next pane")
        precondition(drop(b, at: 250, selected: b, split: three) == nil, "just after the previous pane")
        precondition(drop(a, at: 790, selected: b, split: four) == .move(beside: d, .trailing), "moving needs no room")

        // The split shows only while one of its tabs is selected. With another tab selected the
        // split stays saved but is not the window's split: a drop starts a new pair with that tab.
        precondition(SplitDrop.current(pair, selected: b) != nil)
        precondition(SplitDrop.current(pair, selected: selected) == nil, "a saved split, not showing")
        precondition(drop(dragged, at: 700, selected: selected, split: pair) == .split(.trailing),
                     "a new split beside the selected tab, not a pane of the hidden split")
        precondition(drop(a, at: 100, selected: selected, split: pair) == .split(.leading), "a tab of the hidden split can join the new one")

        // Panes start the same size; dividers set where they end, with the gutter between them.
        precondition(SplitDrop.paneFrames(in: page, count: 2, vertical: false, dividers: [0.25], gap: 8)
                     == [CGRect(x: 0, y: 0, width: 196, height: 600), CGRect(x: 204, y: 0, width: 596, height: 600)])
        precondition(SplitDrop.paneFrames(in: page, count: 3, vertical: true, dividers: SplitDrop.equalDividers(3), gap: 8).map(\.minY) == [0, 204, 404])

        // Each zone says what the drop does.
        let titles = [a: "Docs", b: "Mail"]
        func label(_ outcome: SplitDrop.Outcome, vertical: Bool = false) -> String {
            SplitDrop.label(of: outcome, vertical: vertical) { titles[$0] ?? "" }
        }
        precondition(label(.split(.leading)) == "Open on the left")
        precondition(label(.split(.trailing)) == "Open on the right")
        precondition(label(.insert(beside: a, .trailing)) == "Add to the right of \u{201C}Docs\u{201D}")
        precondition(label(.insert(beside: b, .leading), vertical: true) == "Add above \u{201C}Mail\u{201D}")
        precondition(label(.move(beside: a, .leading)) == "Move to the left of \u{201C}Docs\u{201D}")
        precondition(label(.replace(b)) == "Replace \u{201C}Mail\u{201D}")

        // The answer is one the drag allows: a tab dragged inside Nook allows only a move, and
        // AppKit drops nothing that answers with another operation.
        precondition(SplitDrop.operation(allowed: .move) == .move, "a drag from the sidebar")
        precondition(SplitDrop.operation(allowed: [.copy, .move, .generic]) == .move)
        precondition(SplitDrop.operation(allowed: .copy) == .copy)
        precondition(SplitDrop.operation(allowed: []) == [])
        print("SplitDropCheck passed")
    }
}
