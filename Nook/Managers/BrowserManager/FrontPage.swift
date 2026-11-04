// Licensed under GPL-3.0. See LICENSE.
//
//  FrontPage.swift
//  Nook
//
//  The page a command acts on, as in Arc, and the commands that act on it. Foundation only, so
//  `scripts/tests/FrontPageCheck.swift` can compile and check it.
//

import Foundation

/// The page in front of a window: its Peek when one is shown, else its selected tab, which in a
/// split is the active pane.
enum FrontPage: Equatable {
    case peek(UUID)
    case tab(UUID)

    init?(peek: UUID?, selectedTab: UUID?) {
        if let peek {
            self = .peek(peek)
        } else if let selectedTab {
            self = .tab(selectedTab)
        } else {
            return nil
        }
    }
}

/// A command on the page in front (`FrontPage`), from a shortcut, the menu bar or a page tool.
enum PageCommand: CaseIterable {
    case goBack, goForward, reload, clearCookiesAndReload, hardReload, reloadWithStandardProtection
    case find, zoomIn, zoomOut, actualSize
    case copyURL, print
    case webInspector, pickElement, copyScreenshot, developerMode
    case pictureInPicture, mute, translate
    case clearSiteCookies, clearSiteCache, boost
}

extension ShortcutAction {
    /// The page command this shortcut runs; nil for one on the window, a tab in the sidebar or the
    /// app. The command bar, the developer columns and portrait capture open on the window, with
    /// no page too, and work on its page in front.
    var pageCommand: PageCommand? {
        switch self {
        case .goBack: .goBack
        case .goForward: .goForward
        case .refresh: .reload
        case .clearCookiesAndRefresh: .clearCookiesAndReload
        case .hardReload: .hardReload
        case .findInPage: .find
        case .zoomIn: .zoomIn
        case .zoomOut: .zoomOut
        case .actualSize: .actualSize
        case .copyCurrentURL: .copyURL
        case .printPage: .print
        case .openDevTools: .webInspector
        case .pickElement: .pickElement
        case .copyScreenshot: .copyScreenshot
        case .toggleDeveloperMode: .developerMode
        case .togglePictureInPicture: .pictureInPicture
        case .muteUnmuteAudio: .mute
        case .translatePage: .translate
        case .newTab, .closeTab, .undoCloseTab, .nextTab, .previousTab,
             .goToTab1, .goToTab2, .goToTab3, .goToTab4, .goToTab5, .goToTab6, .goToTab7, .goToTab8, .goToLastTab,
             .duplicateTab, .toggleBookmark, .pinToSpace, .addToFavorites, .addToFolder, .moveToSpace, .renameTab,
             .toggleTopBarAddressView, .nextSpace, .previousSpace,
             .goToSpace1, .goToSpace2, .goToSpace3, .goToSpace4, .goToSpace5, .goToSpace6, .goToSpace7, .goToSpace8, .goToSpace9,
             .newWindow, .closeWindow, .closeBrowser, .toggleFullScreen, .addSplitView, .openCommandPalette, .focusAddressBar,
             .openDevPanel, .openNetworkPanel, .openPerformancePanel, .capturePortrait,
             .viewDownloads, .viewHistory, .expandAllFolders, .toggleSidebar, .toggleAIAssistant, .installExtension,
             .customizeSpaceGradient, .organizeTabs, .toggleExtensionLibrary, .manageExtensions, .toggleDarkMode:
            nil
        }
    }
}
