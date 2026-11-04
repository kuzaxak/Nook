// Licensed under GPL-3.0. See LICENSE.
// swiftc Nook/Managers/SplitViewManager/AddSplit.swift Nook/Components/Browser/Window/SplitDrop.swift CommandPalette/CommandPalette.swift scripts/tests/AddSplitCheck.swift -o /tmp/addsplit && /tmp/addsplit

import Foundation

@main
struct AddSplitCheck {
    @MainActor static func main() {
        let current = UUID(), other = UUID(), opened = UUID(), hiddenLeft = UUID(), hiddenRight = UUID()
        let showing = (left: current, right: other)
        // A pair saved from before, while the window shows another tab.
        let hidden = (left: hiddenLeft, right: hiddenRight)

        // A tab selected and no split: the tab stays on the left beside an empty pane.
        let adding = AddSplit.start(selectedItemID: current, split: nil)!
        precondition(adding.leftItemID == current)
        precondition(adding.shows(selectedItemID: current, split: nil))
        // No tab to split, or two panes already: nothing happens.
        precondition(AddSplit.start(selectedItemID: nil, split: nil) == nil, "no selection")
        precondition(AddSplit.start(selectedItemID: current, split: showing) == nil, "already split")
        // A saved pair the window does not show is no split: the selected tab gets a new one.
        precondition(AddSplit.start(selectedItemID: current, split: hidden) == adding, "a hidden pair")
        precondition(adding.shows(selectedItemID: current, split: hidden))

        // An open tab moves into the right pane; an address or a search fills it with the tab it opened.
        precondition(adding.rightItem(choosing: other, selectedItemID: current, split: nil) == other, "tab")
        precondition(adding.rightItem(choosing: opened, selectedItemID: current, split: nil) == opened, "URL")
        precondition(adding.rightItem(choosing: hiddenRight, selectedItemID: current, split: hidden) == hiddenRight)
        // The tab on the left cannot fill the right too: the window stays as it was.
        precondition(adding.rightItem(choosing: current, selectedItemID: current, split: nil) == nil, "left tab")

        // Another tab or space selected, the left tab closed, or a split made some other way: the
        // empty pane goes, and a late choice changes nothing.
        precondition(!adding.shows(selectedItemID: other, split: nil))
        precondition(!adding.shows(selectedItemID: nil, split: nil))
        precondition(!adding.shows(selectedItemID: current, split: showing))
        precondition(adding.rightItem(choosing: opened, selectedItemID: other, split: nil) == nil)

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
