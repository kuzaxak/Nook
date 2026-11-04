// Licensed under GPL-3.0. See LICENSE.
//
//  SecurityKeySheetPresenter.swift
//  Nook
//
//  Shows a security key prompt over the page that asked, inside its web view, so it belongs to
//  that tab alone: the sidebar and other tabs stay usable, and closing the tab or moving to
//  another one ends the request. Clicks, scrolling and keys on the prompt never reach the page.
//

import AppKit
import SwiftUI
import WebKit
import NookWeb

@MainActor
final class SecurityKeySheetPresenter: SecurityKeyPresenter {
    private var shown: [ObjectIdentifier: SecurityKeyOverlayView] = [:]

    func present(_ sheet: SecurityKeySheet, in webView: WKWebView) -> Bool {
        guard let window = webView.window else { return false }
        let overlay = SecurityKeyOverlayView(sheet: sheet)
        overlay.frame = webView.bounds
        overlay.autoresizingMask = [.width, .height]
        webView.addSubview(overlay)
        overlay.onLeave = { [weak sheet] in sheet?.abandon() }
        shown[ObjectIdentifier(sheet)] = overlay
        window.makeFirstResponder(overlay)
        return true
    }

    func dismiss(_ sheet: SecurityKeySheet) {
        guard let overlay = shown.removeValue(forKey: ObjectIdentifier(sheet)) else { return }
        overlay.onLeave = nil
        let window = overlay.window
        let refocus = window?.firstResponder.flatMap { $0 as? NSView }?.isDescendant(of: overlay) == true
        let page = overlay.superview
        overlay.removeFromSuperview()
        if refocus, let page { window?.makeFirstResponder(page) }
    }
}

final class SecurityKeyOverlayView: NSView {
    private let sheet: SecurityKeySheet
    var onLeave: (() -> Void)?

    init(sheet: SecurityKeySheet) {
        self.sheet = sheet
        super.init(frame: .zero)
        let content = NSHostingView(rootView: SecurityKeySheetView(sheet: sheet))
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { onLeave?() }
    }

    override func viewDidHide() {
        super.viewDidHide()
        onLeave?()
    }

    // An NSView hands unhandled events to its next responder, here the web view.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func keyUp(with event: NSEvent) {}
    override func flagsChanged(with event: NSEvent) {}
    override func menu(for event: NSEvent) -> NSMenu? { nil }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            sheet.cancel()
        case 36, 76:
            if case .failed? = sheet.step { sheet.answer(.dismissed) }
        default:
            break
        }
    }

    override func cancelOperation(_ sender: Any?) {
        sheet.cancel()
    }
}
