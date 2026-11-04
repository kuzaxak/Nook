// Licensed under GPL-3.0. See LICENSE.
//
//  HoldMenuRegion.swift
//  Nook
//
//  A menu behind a button for a right-click, a Control-click or a press held past `holdDelay`,
//  as Safari's Back and Forward have. A local event monitor takes the press before the window
//  routes it: over the title band the window's toolbar answers a right-click with its own Icon
//  and Text menu, so SwiftUI's context menu never sees it there. It goes over its button
//  (`.overlay`) and answers only for presses that land on it, not on something drawn over it.
//

import AppKit
import SwiftUI

struct HoldMenuRegion: NSViewRepresentable {
    let holdDelay: TimeInterval
    /// Nil when there is nothing to list: a right-click then opens nothing and a held press
    /// stays an ordinary press.
    let makeMenu: () -> NSMenu?

    final class Region: NSView {
        var holdDelay: TimeInterval = 0
        var makeMenu: () -> NSMenu? = { nil }
        private var monitor: Any?
        /// Set while the region asks the window what is frontmost under a press; clicks otherwise
        /// pass through it to the button.
        private var probing = false

        override func hitTest(_ point: NSPoint) -> NSView? { probing ? super.hitTest(point) : nil }

        private func isFrontmost(at locationInWindow: NSPoint) -> Bool {
            guard let content = window?.contentView, let frame = content.superview else { return false }
            probing = true
            defer { probing = false }
            return content.hitTest(frame.convert(locationInWindow, from: nil)) === self
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

        /// Nil when the press opened the menu or was a context click; else the press goes on.
        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window, !isHiddenOrHasHiddenAncestor,
                  bounds.contains(convert(event.locationInWindow, from: nil)),
                  isFrontmost(at: event.locationInWindow) else { return event }
            if event.type == .rightMouseDown || event.modifierFlags.contains(.control) {
                if let menu = makeMenu() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
                return nil
            }
            let released = window.nextEvent(matching: .leftMouseUp, until: Date(timeIntervalSinceNow: holdDelay),
                                            inMode: .eventTracking, dequeue: false)
            guard released == nil, let menu = makeMenu() else { return event }
            menu.popUp(positioning: nil, at: NSPoint(x: bounds.minX, y: isFlipped ? bounds.maxY : bounds.minY), in: self)
            return nil
        }
    }

    func makeNSView(context: Context) -> Region {
        let region = Region()
        updateNSView(region, context: context)
        return region
    }

    func updateNSView(_ nsView: Region, context: Context) {
        nsView.holdDelay = holdDelay
        nsView.makeMenu = makeMenu
    }

    static func dismantleNSView(_ nsView: Region, coordinator: ()) { nsView.stop() }
}
