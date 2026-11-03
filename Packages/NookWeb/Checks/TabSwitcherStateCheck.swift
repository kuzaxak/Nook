// Licensed under GPL-3.0. See LICENSE.
// swiftc Packages/NookWeb/Sources/NookWeb/TabSwitcherState.swift Packages/NookWeb/Checks/TabSwitcherStateCheck.swift -o /tmp/ts && /tmp/ts

import Foundation

@main
struct TabSwitcherStateCheck {
    static func main() {
        let a = UUID(), b = UUID(), c = UUID()
        precondition(TabSwitcherState.start(items: [a], step: 1) == nil, "nothing to switch to")

        // Control-Tab once: the previous tab. Again: the one before. Then round to the current.
        var s = TabSwitcherState.start(items: [a, b, c], step: 1)!
        precondition(s.highlighted == b)
        s.advance(by: 1); precondition(s.highlighted == c)
        s.advance(by: 1); precondition(s.highlighted == a)
        // Shift-Control-Tab goes back, and wraps the other way.
        s.advance(by: -1); precondition(s.highlighted == c)

        // Opened backwards: the oldest.
        precondition(TabSwitcherState.start(items: [a, b, c], step: -1)!.highlighted == c)
        // The card waits 0.1 s; a quicker release switches with no card.
        precondition(!TabSwitcherState.shouldPresent(elapsed: 0.05))
        precondition(TabSwitcherState.shouldPresent(elapsed: 0.1))
        precondition(!TabSwitcherState.start(items: [a, b], step: 1)!.isPresented)
        // Up to maxItems recent tabs, laid out in rows of `columns`; arrows move along and across rows.
        precondition(TabSwitcherState.maxItems >= 20)
        let many = (0..<12).map { _ in UUID() }
        var grid = TabSwitcherState.start(items: many, step: 1, columns: 5)!
        precondition(grid.index == 1 && grid.columns == 5)
        grid.moveRow(by: 1); precondition(grid.index == 6, "down one row")
        grid.moveRow(by: 1); precondition(grid.index == 11)
        grid.moveRow(by: 1); precondition(grid.index == 11, "no row below: stays")
        grid.moveRow(by: -1); precondition(grid.index == 6)
        grid.advance(by: -1); precondition(grid.index == 5, "left")
        precondition(TabSwitcherState.start(items: [a, b], step: 1, columns: 5)!.columns == 2, "never more columns than tabs")
        precondition(TabSwitcherState.columns(forWidth: 600) < TabSwitcherState.columns(forWidth: 1400))
        precondition(TabSwitcherState.columns(forWidth: 100) == 1)
        // Control is held, and macOS keeps Control-arrows for Spaces and Mission Control, so
        // Cocoa's Control-F/B/N/P move as well.
        var keys = TabSwitcherState.start(items: many, step: 1, columns: 5)!
        precondition(keys.move(keyCode: 3, characters: "f") && keys.index == 2, "Control-F: next")
        precondition(keys.move(keyCode: 11, characters: "b") && keys.index == 1, "Control-B: previous")
        precondition(keys.move(keyCode: 45, characters: "n") && keys.index == 6, "Control-N: row below")
        precondition(keys.move(keyCode: 35, characters: "p") && keys.index == 1, "Control-P: row above")
        precondition(keys.move(keyCode: 124, characters: nil) && keys.index == 2, "arrows where Mission Control lets them through")
        precondition(!keys.move(keyCode: 0, characters: "a") && keys.index == 2)
        print("TabSwitcherStateCheck passed")
    }
}
