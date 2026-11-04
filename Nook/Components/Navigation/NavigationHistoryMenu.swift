// Licensed under GPL-3.0. See LICENSE.
//
//  NavigationHistoryMenu.swift
//  Nook
//
//  Created by Jonathan Caudill on 01/10/2025.
//

import AppKit
import SwiftUI
import WebKit
import NookDesign
import NookWeb

/// Back's or Forward's history behind its button: a right-click, Control-click or held press lists
/// the pages that way, nearest first, by title and favicon. Choosing one goes there in this
/// window's view of the tab.
struct NavigationHistoryMenu: View {
    enum Direction {
        case back
        case forward
    }

    let direction: Direction
    let windowState: BrowserWindowState
    @EnvironmentObject var browserManager: BrowserManager

    var body: some View {
        HoldMenuRegion(holdDelay: NookDesign.Motion.historyMenuHold, makeMenu: makeMenu)
    }

    private func makeMenu() -> NSMenu? {
        guard let session = browserManager.tabs.controllableSession(in: windowState),
              let webView = browserManager.webViewCoordinator?.getWebView(for: session.itemID, in: windowState.id)
                ?? session.assignedWebView
        else { return nil }
        let list = webView.backForwardList
        let entries = direction == .back ? Array(list.backList.reversed()) : list.forwardList
        guard !entries.isEmpty else { return nil }
        let menu = NSMenu()
        for entry in entries {
            let item = HandlerMenuItem(title: Self.title(of: entry)) { _ in webView.go(to: entry) }
            item.image = Self.favicon(for: entry.url)
            menu.addItem(item)
        }
        return menu
    }

    private static func title(of entry: WKBackForwardListItem) -> String {
        if let title = entry.title, !title.isEmpty { return title }
        return entry.url.host ?? entry.url.absoluteString
    }

    private static func favicon(for url: URL) -> NSImage? {
        let cached = url.host.flatMap { FaviconCache.shared.image(for: $0) ?? FaviconCache.shared.imageFromDiskSync(for: $0) }
        guard let image = (cached ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil))?.copy() as? NSImage
        else { return nil }
        image.size = NSSize(width: NookDesign.Size.favicon, height: NookDesign.Size.favicon)
        return image
    }
}
