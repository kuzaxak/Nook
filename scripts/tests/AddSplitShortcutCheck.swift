// Licensed under GPL-3.0. See LICENSE.
// swiftc Nook/Models/KeyboardShortcut/KeyboardShortcut.swift scripts/tests/AddSplitShortcutCheck.swift -o /tmp/ass && /tmp/ass
//
// Add Split View is Arc's ⌃⇧=: the key right of 0 on a US keyboard, whatever the layout types there.

import AppKit

@main
struct AddSplitShortcutCheck {
    static func main() {
        let addSplit = KeyboardShortcut.defaultShortcuts.first { $0.action == .addSplitView }!
        precondition(addSplit.keyCombination.displayString == "⌃⇧=", "shown as in Arc")

        // kVK_ANSI_Equal is 24. Shift turns its character into another one, and other layouts put
        // other characters on that key.
        precondition(action("+", "+", 24, [.control, .shift]) == .addSplitView, "US: Shift makes it +")
        precondition(action("`", "`", 24, [.control, .shift]) == .addSplitView, "German and Nordic: the accent key")
        precondition(action("¿", "¿", 24, [.control, .shift]) == .addSplitView, "Spanish")
        precondition(action("+", "+", 24, [.control, .shift]) == .addSplitView, "Russian – PC")
        precondition(action("ъ", "ъ", 24, [.control, .shift]) == .addSplitView, "a Cyrillic letter on that key")

        // A key's own character still comes first: ⌘] on Dvorak sits on that key and stays Go Forward,
        // and ⌃⇧= typed elsewhere on Dvorak is another key.
        precondition(action("]", "]", 24, [.command]) == .goForward, "Dvorak ⌘]")
        precondition(action("]", "]", 24, [.command], bound: ["cmd+]": .goForward, "cmd+=": .zoomIn]) == .goForward,
                     "what the key types wins over where it sits")
        precondition(action("+", "+", 30, [.control, .shift]) == nil, "Dvorak's = key is at another position")
        // Without ⌘ or Control the key types.
        precondition(action("+", "+", 24, [.shift], bound: ["shift+=": .zoomIn]) == nil, "Shift alone types +")
        print("AddSplitShortcutCheck passed")
    }

    private static let defaults = Dictionary(KeyboardShortcut.defaultShortcuts.map { ($0.lookupKey, $0.action) },
                                             uniquingKeysWith: { first, _ in first })

    /// The shortcut a key press runs, as KeyboardShortcutManager looks it up.
    private static func action(_ ignoringModifiers: String, _ characters: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags,
                               bound byKey: [String: ShortcutAction] = defaults) -> ShortcutAction? {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                           context: nil, characters: characters, charactersIgnoringModifiers: ignoringModifiers,
                                           isARepeat: false, keyCode: keyCode) else { return nil }
        return KeyCombination.lookupKeys(for: event).lazy.compactMap { byKey[$0] }.first
    }
}
