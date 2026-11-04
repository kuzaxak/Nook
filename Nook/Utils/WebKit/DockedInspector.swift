// Licensed under GPL-3.0. See LICENSE.
//
//  DockedInspector.swift
//  Nook
//
//  A page and the Web Inspector docked to it. WebKit puts the inspector's view beside the page in
//  the page's superview and sizes the two itself; `scripts/tests/DockedInspectorCheck.swift`
//  checks this file against a real docked inspector.
//

import AppKit
import WebKit

extension WKWebView {
    /// The view of the Web Inspector docked to this page, also while it is out of the window with
    /// the page; nil while the inspector is closed or in its own window. `_inspector`, `isVisible`
    /// and `inspectorWebView` are WebKit SPI.
    var dockedInspector: NSView? {
        let selector = NSSelectorFromString("_inspector")
        guard responds(to: selector), let inspector = perform(selector)?.takeUnretainedValue() as? NSObject,
              inspector.responds(to: NSSelectorFromString("isVisible")),
              inspector.responds(to: NSSelectorFromString("inspectorWebView")),
              inspector.value(forKey: "isVisible") as? Bool == true,
              let view = inspector.value(forKey: "inspectorWebView") as? NSView
        else { return nil }

        return view.window == nil || (view.superview != nil && view.superview === superview) ? view : nil
    }
}

extension NSView {
    /// Makes `page` this view's page, filling it, and takes the rest of `views` out. The page's docked
    /// `inspector` shares the space: while it is here WebKit sizes the two, and one that left with its
    /// page comes back just below it, so WebKit shares the space out again.
    func showPage(_ page: NSView, inspector: NSView?, replacing views: [NSView]) {
        for view in views where view !== page && view !== inspector { view.removeFromSuperview() }
        if page.superview !== self { addSubview(page) }
        page.autoresizingMask = [.width, .height]
        page.isHidden = false
        if let inspector, inspector.superview === self { return }

        page.frame = bounds
        if let inspector { addSubview(inspector, positioned: .below, relativeTo: page) }
    }
}
