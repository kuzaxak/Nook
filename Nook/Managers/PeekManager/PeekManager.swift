// Licensed under GPL-3.0. See LICENSE.
//
//  PeekManager.swift
//  Nook
//
//  Created by Jonathan Caudill on 24/09/2025.
//

import AppKit
import Foundation
import NookDesign
import NookWeb
import SwiftUI

/// Peek: a link shown in a card over the tab that opened it, as a detached page that runs like a
/// tab and becomes one when moved to a tab or split. Each tab keeps its own Peek while another
/// tab shows, as in Arc.
@MainActor
@Observable
final class PeekManager {
    /// Each tab's Peek, outside the tab tree until it moves to a tab.
    private var slots = PeekSlots<PageSession>()
    /// Where in its window each Peek was opened from, as a fraction of the window: the card grows
    /// out of that point, as Arc's grows out of the link.
    @ObservationIgnored private var origins: [UUID: UnitPoint] = [:]

    @ObservationIgnored weak var browserManager: BrowserManager?

    func attach(browserManager: BrowserManager) {
        self.browserManager = browserManager
        // A tab's Peek is still drawn as the window leaves the tab: its picture is taken for the
        // Control-Tab card then, like the tab's own.
        browserManager.tabs.onLeavingTab = { [weak self] itemID, window in
            guard let peek = self?.slots.page(tab: itemID, window: window.id) else { return }
            peek.captureSwitcherSnapshot()
            // A Peek waits hidden with its tab; nothing would show a video playing in it.
            peek.webView?.pauseAllMediaPlayback(completionHandler: nil)
        }
        // A tab that lets go of its page, closed or unloaded, ends its Peeks with it.
        browserManager.tabs.onPageUnloaded = { [weak self] itemID in
            self?.tabClosed(itemID)
        }
    }

    func origin(of page: PageSession) -> UnitPoint {
        origins[page.itemID] ?? .center
    }

    /// The Peek over the tab `window` shows.
    func page(in window: BrowserWindowState) -> PageSession? {
        window.selectedItemID.flatMap { slots.page(tab: $0, window: window.id) }
    }

    func page(tab: UUID, window: UUID) -> PageSession? {
        slots.page(tab: tab, window: window)
    }

    func presentExternalURL(_ url: URL, from source: PageSession?) {
        // A private page never falls back to the default persistent store.
        guard let browserManager, let source, let profile = source.profile,
              let window = source.detachedWindow ?? browserManager.tabs.window(for: source),
              // A link in a Peek opens over the same tab, the one the window shows.
              let tab = source.isDetached ? window.selectedItemID : source.itemID else { return }

        // The same link again closes Peek.
        if slots.page(tab: tab, window: window.id)?.url == url {
            dismiss(tab: tab, window: window.id)
            return
        }

        let page = browserManager.tabs.openDetached(url: url, profile: profile, in: window)
        if let nsWindow = window.windowHandle as? NSWindow, let content = nsWindow.contentView, content.bounds.width > 0 {
            let pointer = nsWindow.mouseLocationOutsideOfEventStream
            origins[page.itemID] = UnitPoint(x: pointer.x / content.bounds.width, y: 1 - pointer.y / content.bounds.height)
        }
        let windowID = window.id
        page.onClose = { [weak self] in self?.dismiss(tab: tab, window: windowID) }
        let replaced = withAnimation(NookDesign.Motion.spring) { slots.open(page, tab: tab, window: window.id) }
        if let replaced {
            end(replaced)
        }
    }

    func dismissPeek(in window: BrowserWindowState) {
        guard let tab = window.selectedItemID else { return }
        dismiss(tab: tab, window: window.id)
    }

    func moveToSplitView(in window: BrowserWindowState) {
        guard let browserManager, let tab = window.selectedItemID, let itemID = adopt(in: window) else { return }
        // The adopted page is selected; pair it with the tab the Peek was over.
        if tab != itemID {
            browserManager.tabs.select(tab, in: window)
            browserManager.splitManager.enterSplit(with: itemID, placeOn: .right, in: window)
        }
    }

    func moveToNewTab(in window: BrowserWindowState) {
        adopt(in: window)
    }

    func canEnterSplitView(in window: BrowserWindowState) -> Bool {
        guard let browserManager else { return false }
        return !browserManager.splitManager.isSplit(for: window.id)
    }

    func tabClosed(_ itemID: UUID) {
        for page in slots.closeAll(tab: itemID) { end(page) }
    }

    func windowClosed(_ windowID: UUID) {
        for page in slots.closeAll(window: windowID) { end(page) }
    }

    private func dismiss(tab: UUID, window: UUID) {
        guard let page = withAnimation(NookDesign.Motion.spring, { slots.close(tab: tab, window: window) }) else { return }
        end(page)
    }

    private func end(_ page: PageSession) {
        origins[page.itemID] = nil
        browserManager?.tabs.endDetached(page)
    }

    /// Moves the current tab's Peek into the tab tree, nested under that tab.
    @discardableResult
    private func adopt(in window: BrowserWindowState) -> UUID? {
        guard let browserManager, let tab = window.selectedItemID,
              let page = withAnimation(NookDesign.Motion.spring, { slots.close(tab: tab, window: window.id) }) else { return nil }
        origins[page.itemID] = nil
        guard let itemID = browserManager.tabs.adopt(page, in: window, from: tab) else {
            end(page)
            return nil
        }
        return itemID
    }
}
