// Licensed under GPL-3.0. See LICENSE.
//
//  CloseShortcut.swift
//  Nook
//
//  What Close Tab (⌘W) closes, as in Arc. Foundation only, so
//  `scripts/tests/CloseShortcutCheck.swift` can compile and check it.
//

import Foundation

enum CloseShortcut {
    /// What the key window shows, when it is a browser window.
    struct BrowserWindow: Equatable {
        var showsCommandBar: Bool
        var showsPeek: Bool
        var showsTab: Bool
    }

    enum Target: Equatable {
        case commandBar
        case peek
        case tab
        /// The key window: a browser window with no tab, or any other window.
        case window
        case nothing
    }

    /// `browserWindow` is nil when the key window is not a browser window: Settings, a mini
    /// window, a Web Inspector or an extension popup. `isRepeat` is a held ⌘W.
    static func target(in browserWindow: BrowserWindow?, isRepeat: Bool) -> Target {
        guard let browserWindow else { return .window }
        if browserWindow.showsCommandBar { return .commandBar }
        if browserWindow.showsPeek { return .peek }
        if browserWindow.showsTab { return .tab }
        return isRepeat ? .nothing : .window
    }
}
