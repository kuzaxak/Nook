// Licensed under GPL-3.0. See LICENSE.
//
//  swiftc Nook/Models/KeyboardShortcut/KeyboardShortcut.swift Nook/Managers/BrowserManager/FrontPage.swift scripts/tests/FrontPageCheck.swift -o /tmp/fp && /tmp/fp
//
//  Which page a command acts on, and which commands act on a page at all.

import Foundation

@main
struct FrontPageCheck {
    static func main() {
        let tab = UUID(), peek = UUID(), left = UUID(), right = UUID()
        precondition(FrontPage(peek: peek, selectedTab: tab) == .peek(peek), "a Peek shown over its tab, as in Arc")
        precondition(FrontPage(peek: nil, selectedTab: right) == .tab(right), "a split whose right pane is active: the window selects it")
        precondition(FrontPage(peek: peek, selectedTab: left) == .peek(peek), "a Peek over a split pane")
        precondition(FrontPage(peek: nil, selectedTab: tab) == .tab(tab), "a plain tab")
        precondition(FrontPage(peek: nil, selectedTab: nil) == nil, "the empty space has no page")

        let onPage: [ShortcutAction: PageCommand] = [
            .goBack: .goBack, .goForward: .goForward, .refresh: .reload, .clearCookiesAndRefresh: .clearCookiesAndReload,
            .hardReload: .hardReload, .findInPage: .find, .zoomIn: .zoomIn, .zoomOut: .zoomOut, .actualSize: .actualSize,
            .copyCurrentURL: .copyURL, .printPage: .print, .openDevTools: .webInspector,
            .pickElement: .pickElement, .copyScreenshot: .copyScreenshot, .toggleDeveloperMode: .developerMode,
            .togglePictureInPicture: .pictureInPicture, .muteUnmuteAudio: .mute, .translatePage: .translate,
        ]
        for action in ShortcutAction.allCases {
            precondition(action.pageCommand == onPage[action],
                         "\(action.rawValue): \(onPage[action] == nil ? "acts on the window, a tab in the sidebar or the app" : "acts on the page in front")")
        }
        let menuOnly: Set<PageCommand> = [.reloadWithStandardProtection, .clearSiteCookies, .clearSiteCache, .boost]
        precondition(Set(onPage.values).union(menuOnly) == Set(PageCommand.allCases) && Set(onPage.values).isDisjoint(with: menuOnly),
                     "every page command is a shortcut's or a menu item's")
        print("FrontPageCheck passed")
    }
}
