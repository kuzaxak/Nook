// Licensed under GPL-3.0. See LICENSE.
// swiftc Packages/NookUI/Sources/NookUI/Rows/RowPress.swift scripts/tests/RowPressCheck.swift -o /tmp/rowpress && /tmp/rowpress
//
// A sidebar row selects its tab on a click only, as in Arc: a press that turns into a drag leaves
// the current tab selected, whenever the row's button reports the press.

import CoreGraphics

@main
struct RowPressCheck {
    @MainActor static func main() {
        var selections = 0
        func rowAction() { RowPress.click(byMouse: true) { selections += 1 } }
        func keyboardAction() { RowPress.click(byMouse: false) { selections += 1 } }

        // A click: pressed and released within the threshold.
        RowPress.current.down(at: CGPoint(x: 10, y: 10))
        precondition(!RowPress.current.moved(to: CGPoint(x: 12, y: 11)), "a small wobble is still a click")
        rowAction()
        precondition(selections == 0, "a press alone selects nothing until its release")
        RowPress.current.up()
        selections = 0
        rowAction()
        precondition(selections == 1, "a click selects")

        // A drag: the press passes the threshold, so the drag starts and nothing gets selected,
        // whether the row's button reports the press as the drag starts or once it ends.
        selections = 0
        RowPress.current.down(at: CGPoint(x: 10, y: 10))
        precondition(!RowPress.current.moved(to: CGPoint(x: 13.9, y: 10)), "under the threshold")
        precondition(RowPress.current.moved(to: CGPoint(x: 14, y: 10)), "the threshold starts the drag")
        precondition(!RowPress.current.moved(to: CGPoint(x: 40, y: 10)), "the drag starts once")
        rowAction()
        RowPress.current.up()
        rowAction()
        precondition(selections == 0, "a drag selects nothing")

        // The next press is a click again.
        RowPress.current.down(at: CGPoint(x: 200, y: 300))
        RowPress.current.up()
        rowAction()
        precondition(selections == 1, "a click after a drag selects")

        // VoiceOver's press and Full Keyboard Access's Space are no mouse click: they select
        // whatever press came before, one the drag loop, a menu or a ctrl-click never released.
        selections = 0
        RowPress.current.down(at: CGPoint(x: 10, y: 10))
        keyboardAction()
        precondition(selections == 1, "after a press with no release seen")
        rowAction()
        precondition(selections == 1, "a mouse event during that press still waits for its release")
        _ = RowPress.current.moved(to: CGPoint(x: 40, y: 10))
        RowPress.current.up()
        keyboardAction()
        precondition(selections == 2, "after a drag")
        rowAction()
        precondition(selections == 2, "a mouse event right after the drag still selects nothing")
        print("RowPressCheck passed")
    }
}
