// Licensed under GPL-3.0. See LICENSE.
//
//  swiftc Nook/Models/KeyboardShortcut/KeyboardShortcut.swift Nook/Managers/KeyboardShortcutManager/CloseShortcut.swift scripts/tests/CloseShortcutCheck.swift -o /tmp/cs && /tmp/cs
//
//  What ⌘W closes, and that ⌘W reaches the shortcut on any layout instead of the menu's Close.

import AppKit

@main
struct CloseShortcutCheck {
    static func main() {
        let tab = CloseShortcut.BrowserWindow(showsCommandBar: false, showsPeek: false, showsTab: true)
        let empty = CloseShortcut.BrowserWindow(showsCommandBar: false, showsPeek: false, showsTab: false)
        precondition(CloseShortcut.target(in: tab, isRepeat: false) == .tab,
                     "a tab, pinned tab, favorite, folder tab or split pane closes, whatever has focus in the window")
        precondition(CloseShortcut.target(in: tab, isRepeat: true) == .tab, "a held ⌘W keeps closing tabs")
        precondition(CloseShortcut.target(in: empty, isRepeat: false) == .window, "the empty space: no tab, so the window closes")
        precondition(CloseShortcut.target(in: empty, isRepeat: true) == .nothing, "a held ⌘W stops at the empty window")
        precondition(CloseShortcut.target(in: .init(showsCommandBar: false, showsPeek: true, showsTab: true), isRepeat: false) == .peek,
                     "a Peek closes, not the tab it is over, as in Arc")
        precondition(CloseShortcut.target(in: .init(showsCommandBar: true, showsPeek: false, showsTab: true), isRepeat: false) == .commandBar,
                     "the command bar closes, not the tab under it")
        precondition(CloseShortcut.target(in: .init(showsCommandBar: true, showsPeek: true, showsTab: true), isRepeat: false) == .commandBar,
                     "the command bar over a Peek closes first")
        precondition(CloseShortcut.target(in: .init(showsCommandBar: true, showsPeek: false, showsTab: false), isRepeat: false) == .commandBar,
                     "⌘T on the empty space, then ⌘W: the command bar closes, not the window")
        precondition(CloseShortcut.target(in: nil, isRepeat: false) == .window,
                     "Settings, a mini window, a Web Inspector or an extension popup closes itself")
        precondition(CloseShortcut.closesOtherWindow(lookupKey: key("ц", "w", 13, [.command])),
                     "⌘W closes Settings or a mini window on any layout, whatever Close Tab is bound to")
        precondition(!CloseShortcut.closesOtherWindow(lookupKey: key("ц", "w", 13, [.command, .shift])), "other keys are the window's own")
        precondition(CloseShortcut.isHeldKey(keyDown(isARepeat: true)), "a held ⌘W reaching the menu's Close Tab")
        precondition(!CloseShortcut.isHeldKey(keyDown(isARepeat: false)))
        precondition(!CloseShortcut.isHeldKey(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0,
                                                                 windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)),
                     "Close Tab chosen with the pointer")
        precondition(!CloseShortcut.isHeldKey(nil))

        // ⌘W on a Russian layout reports its own letter ignoring modifiers and the Latin one with ⌘.
        precondition(key("ц", "w", 13, [.command]) == "cmd+w", "⌘W on a Russian layout")
        precondition(key("ц", "w", 13, [.command, .shift]) == "cmd+shift+w", "⇧⌘W on a Russian layout")
        precondition(key("х", "[", 33, [.command]) == "cmd+[", "⌘[ on a Russian layout, as its ⌘ keymap types it")
        precondition(key("в", "\u{4}", 2, [.control]) == "ctrl+d", "Control-D on a Russian layout, by key position")
        precondition(key("ф", "d", 0, [.command, .option]) == "cmd+opt+a", "⌥⌘A on Russian – PC, whose Option layer types d there")
        precondition(key("ш", "^", 34, [.command, .option]) == "cmd+opt+i", "⌥⌘I on a Cyrillic layout whose Option layer types ^")
        precondition(key("в", "ѓ", 2, [.option]) == "opt+в", "Option alone keeps what the layout types")
        precondition(key("w", "w", 13, [.command]) == "cmd+w", "⌘W on a Latin layout")
        precondition(key(",", ",", 13, [.command]) == "cmd+,", "Dvorak matches by the character it types")
        precondition(key("\u{F702}", "\u{F702}", 123, [.command, .option]) == "cmd+opt+left", "arrows")
        print("CloseShortcutCheck passed")
    }

    private static func key(_ ignoringModifiers: String, _ characters: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags) -> String? {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                     context: nil, characters: characters, charactersIgnoringModifiers: ignoringModifiers,
                                     isARepeat: false, keyCode: keyCode)
        return event.flatMap(KeyCombination.init(from:))?.lookupKey
    }

    private static func keyDown(isARepeat: Bool) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0,
                         context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: isARepeat, keyCode: 13)
    }
}
