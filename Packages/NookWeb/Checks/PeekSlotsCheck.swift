// Licensed under GPL-3.0. See LICENSE.
// swiftc Packages/NookWeb/Sources/NookWeb/PeekSlots.swift Packages/NookWeb/Checks/PeekSlotsCheck.swift -o /tmp/peek-slots && /tmp/peek-slots

import Foundation

@main
struct PeekSlotsCheck {
    static func main() {
        let tabA = UUID(), tabB = UUID(), window = UUID(), other = UUID()
        var slots = PeekSlots<String>()

        precondition(slots.open("a1", tab: tabA, window: window) == nil)
        precondition(slots.page(tab: tabA, window: window) == "a1")
        precondition(slots.page(tab: tabB, window: window) == nil, "another tab shows no Peek")
        precondition(slots.page(tab: tabA, window: other) == nil, "nor does the same tab in another window")

        precondition(slots.open("b1", tab: tabB, window: window) == nil, "each tab keeps its own Peek")
        precondition(slots.page(tab: tabA, window: window) == "a1", "back on the first tab, its Peek is still there")

        precondition(slots.open("a2", tab: tabA, window: window) == "a1", "a new Peek on a tab replaces its old one")
        precondition(slots.close(tab: tabA, window: window) == "a2")
        precondition(slots.page(tab: tabA, window: window) == nil)
        precondition(slots.page(tab: tabB, window: window) == "b1")

        slots.open("a3", tab: tabA, window: other)
        precondition(slots.closeAll(tab: tabB) == ["b1"], "closing a tab ends its Peek")
        precondition(slots.closeAll(window: other) == ["a3"], "closing a window ends its Peeks")
        precondition(slots.isEmpty)
        print("PeekSlotsCheck passed")
    }
}
