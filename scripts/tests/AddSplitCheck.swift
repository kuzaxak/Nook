// Licensed under GPL-3.0. See LICENSE.
// swiftc Nook/Managers/SplitViewManager/AddSplit.swift CommandPalette/CommandPalette.swift scripts/tests/AddSplitCheck.swift -o /tmp/addsplit && /tmp/addsplit

import Foundation

@main
struct AddSplitCheck {
    @MainActor static func main() {
        let current = UUID(), other = UUID(), opened = UUID()

        // A tab selected and no split: the tab stays on the left beside an empty pane.
        let adding = AddSplit.start(selectedItemID: current, isSplit: false)!
        precondition(adding.leftItemID == current)
        precondition(adding.shows(selectedItemID: current, isSplit: false))
        // No tab to split, or two panes already: nothing happens.
        precondition(AddSplit.start(selectedItemID: nil, isSplit: false) == nil, "no selection")
        precondition(AddSplit.start(selectedItemID: current, isSplit: true) == nil, "already split")

        // An open tab moves into the right pane; an address or a search fills it with the tab it opened.
        precondition(adding.rightItem(choosing: other, selectedItemID: current, isSplit: false) == other, "tab")
        precondition(adding.rightItem(choosing: opened, selectedItemID: current, isSplit: false) == opened, "URL")
        // The tab on the left cannot fill the right too: the window stays as it was.
        precondition(adding.rightItem(choosing: current, selectedItemID: current, isSplit: false) == nil, "left tab")

        // Another tab or space selected, the left tab closed, or a split made some other way: the
        // empty pane goes, and a late choice changes nothing.
        precondition(!adding.shows(selectedItemID: other, isSplit: false))
        precondition(!adding.shows(selectedItemID: nil, isSplit: false))
        precondition(!adding.shows(selectedItemID: current, isSplit: true))
        precondition(adding.rightItem(choosing: opened, selectedItemID: other, isSplit: false) == nil)

        // The bar holds the empty pane while it is open for it. Escape, a click outside and the
        // pane's close button all close the bar, which drops it; opening the bar for anything
        // else (Cmd+T, Cmd+L) drops it too.
        let palette = CommandPalette()
        palette.open(addSplit: adding)
        precondition(palette.addSplit == adding && !palette.shouldNavigateCurrentTab)
        palette.close()
        precondition(palette.addSplit == nil, "cancel")
        palette.open(addSplit: adding)
        palette.open(prefill: "https://example.com", navigateCurrentTab: true)
        precondition(palette.addSplit == nil, "the bar opened for something else")
        print("AddSplitCheck passed")
    }
}
