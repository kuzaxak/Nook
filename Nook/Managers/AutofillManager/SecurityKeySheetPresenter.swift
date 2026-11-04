// Licensed under GPL-3.0. See LICENSE.
//
//  SecurityKeySheetPresenter.swift
//  Nook
//
//  Puts a security key sheet on the window of the tab that asked, and takes it off again.
//

import AppKit
import SwiftUI
import WebKit
import NookWeb

@MainActor
final class SecurityKeySheetPresenter: SecurityKeyPresenter {
    private var shown: [ObjectIdentifier: (window: NSWindow, parent: NSWindow)] = [:]

    func present(_ sheet: SecurityKeySheet, in webView: WKWebView) -> Bool {
        guard let parent = webView.window else { return false }
        let content = NSHostingController(rootView: SecurityKeySheetView(sheet: sheet))
        content.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: content)
        window.styleMask = [.titled]
        shown[ObjectIdentifier(sheet)] = (window, parent)
        parent.beginSheet(window)
        return true
    }

    func dismiss(_ sheet: SecurityKeySheet) {
        guard let (window, parent) = shown.removeValue(forKey: ObjectIdentifier(sheet)) else { return }
        parent.endSheet(window)
        window.orderOut(nil)
    }
}
