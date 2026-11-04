// Licensed under GPL-3.0. See LICENSE.
// swiftc Nook/Components/DragDrop/TabDropRouter.swift scripts/tests/TabDropRoutingCheck.swift -o /tmp/tdr && /tmp/tdr
//
// A sidebar tab dragged over the page reaches the page's split target, and one dragged within the
// sidebar still reaches its drop zone, whichever view AppKit keeps sending the drag to. The view
// tree is the running app's, from an LLDB dump: the space pager's strip holds the page of the
// selected space, whose zones sit in a scroll view; the page's target lies over its web view.

import AppKit

@main
struct TabDropRoutingCheck {
    @MainActor static func main() {
        let tab = TabDropRouter.tabType
        let window = Plain(NSRect(x: 0, y: 0, width: 1000, height: 700))
        let hosting = Plain(window.bounds)
        window.addSubview(hosting)

        let compositor = Plain(NSRect(x: 260, y: 0, width: 740, height: 690))
        let container = Plain(compositor.bounds)
        let webView = Plain(container.bounds, accepting: [NSPasteboard.PasteboardType("public.url")])
        let page = Target("page", container.bounds)
        hosting.addSubview(compositor)
        compositor.addSubview(container)
        container.addSubview(webView)
        container.addSubview(page)

        let pagerHost = Plain(NSRect(x: 0, y: 98, width: 260, height: 590))
        let pager = Plain(pagerHost.bounds)
        pager.wantsLayer = true
        pager.layer?.masksToBounds = true
        let strip = Plain(NSRect(x: -520, y: 0, width: 1040, height: 590))
        hosting.addSubview(pagerHost)
        pagerHost.addSubview(pager)
        pager.addSubview(strip)
        // The next space's page, left attached after a swipe, lies beside the sidebar over the page.
        let nextSpace = Plain(NSRect(x: 780, y: 0, width: 260, height: 590))
        nextSpace.addSubview(Target("next space's tabs", NSRect(x: 8, y: 300, width: 244, height: 168)))
        strip.addSubview(nextSpace)
        let spacePage = Plain(NSRect(x: 520, y: 0, width: 260, height: 590))
        strip.addSubview(spacePage)
        let favorites = Target("favorites", NSRect(x: 8, y: 550, width: 244, height: 32))
        spacePage.addSubview(favorites)
        let scroll = Plain(NSRect(x: 0, y: 0, width: 260, height: 500))
        let document = Plain(NSRect(x: 0, y: 200, width: 260, height: 300))
        let tabs = Target("tabs", NSRect(x: 8, y: 63, width: 244, height: 168))
        spacePage.addSubview(scroll)
        scroll.addSubview(document)
        document.addSubview(tabs)

        let row = NSPoint(x: 100, y: 98 + 200 + 100)
        let overPage = NSPoint(x: 600, y: 400)
        let besideSidebar = NSPoint(x: 300, y: 98 + 200 + 100)
        let header = NSPoint(x: 100, y: 690)

        // The view a tab drag belongs to is the one AppKit itself finds there.
        for point in [row, overPage, besideSidebar, header, NSPoint(x: 100, y: 98 + 590 - 24), NSPoint(x: 100, y: 120)] {
            precondition(TabDropRouter.target(at: point, in: window) === appKitTarget(in: window, at: point, types: [tab]),
                         "routing at \(point) differs from AppKit's")
        }
        precondition(TabDropRouter.target(at: row, in: window) === tabs)
        precondition(TabDropRouter.target(at: overPage, in: window) === page)
        precondition(TabDropRouter.target(at: besideSidebar, in: window) === page, "the next space's zones stay clipped to the sidebar")
        precondition(TabDropRouter.target(at: header, in: window) == nil)

        // The tree as a window's content, and a second Nook window over the page's right side.
        _ = NSApplication.shared
        func make(_ frame: NSRect, content: NSView) -> NSWindow {
            let made = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: true)
            made.isReleasedWhenClosed = false
            made.contentView = content
            return made
        }
        let main = make(window.frame, content: window)
        let otherContent = Plain(NSRect(x: 0, y: 0, width: 400, height: 700))
        let otherTabs = Target("other window's tabs", NSRect(x: 0, y: 300, width: 200, height: 200))
        otherContent.addSubview(otherTabs)
        let other = make(NSRect(x: 650, y: 0, width: 400, height: 700), content: otherContent)
        let router = TabDropRouter { point in [other, main].first { $0.frame.contains(point) } }
        func reset() { for target in [page, tabs, favorites, otherTabs] { target.log = [] } }

        // A drag from a sidebar row to the page. AppKit entered the tabs zone where the drag began
        // and keeps sending it every update and the drop: the page target gets them all.
        precondition(router.updated(Info(row), at: tabs) == .move)
        precondition(tabs.log == ["updated"] && page.log.isEmpty)
        reset()
        precondition(router.updated(Info(overPage), at: tabs) == .copy, "the page target's answer")
        precondition(tabs.log == ["exited"], "the zone lets go of the drag")
        precondition(page.log == ["updated"])
        precondition(router.updated(Info(overPage), at: tabs) == .copy)
        precondition(router.perform(Info(overPage), at: tabs))
        precondition(page.log == ["updated", "updated", "performed"], "the page takes the drop")
        precondition(tabs.log == ["exited"], "the zone takes no reorder")
        reset()

        // A reorder within the sidebar still reaches the zone.
        precondition(router.updated(Info(row), at: tabs) == .move)
        precondition(router.perform(Info(row), at: tabs))
        precondition(tabs.log == ["updated", "performed"] && page.log.isEmpty)
        reset()

        // Over the page and back to the sidebar, with AppKit still on the page target.
        _ = router.updated(Info(overPage), at: page)
        _ = router.updated(Info(row), at: page)
        precondition(page.log == ["updated", "exited"] && tabs.log == ["updated"])
        reset()

        // When AppKit does move the drag on, the view already holding it keeps it.
        router.exited(Info(row), at: page)
        precondition(tabs.log.isEmpty, "AppKit leaving a view the drag already left changes nothing")
        _ = router.updated(Info(row), at: tabs)
        precondition(tabs.log == ["updated"])
        router.exited(Info(NSPoint(x: -20, y: 400)), at: tabs)
        precondition(tabs.log == ["updated", "exited"], "leaving the window")
        reset()

        // Over a gap with no drop view, nothing takes the drag.
        _ = router.updated(Info(row), at: tabs)
        precondition(router.updated(Info(header), at: tabs) == [])
        precondition(!router.perform(Info(header), at: tabs))
        precondition(tabs.log == ["updated", "exited"])
        reset()

        // A drag that ends with nothing dropped: Escape, a release the target refused, or a pane
        // let go where it already is. AppKit exits the view it holds, or only ends the session;
        // either way the target holding the drag lets go, so the page takes clicks again.
        _ = router.updated(Info(overPage), at: page)
        router.exited(Info(overPage), at: page)
        precondition(page.log == ["updated", "exited"], "Escape over the page target AppKit holds")
        reset()
        page.answer = []
        _ = router.updated(Info(overPage), at: page)
        router.exited(Info(overPage), at: page)
        router.end()
        precondition(page.log == ["updated", "exited"], "a release the page refused")
        page.answer = nil
        reset()
        _ = router.updated(Info(overPage), at: tabs)
        router.exited(Info(overPage), at: tabs)
        precondition(page.log == ["updated"], "AppKit letting go of the zone it still holds")
        router.end()
        precondition(page.log == ["updated", "exited"], "the session's end lets the page target go")
        router.end()
        precondition(page.log == ["updated", "exited"] && tabs.log.isEmpty, "an end with nothing held")
        reset()

        // Text or a file dragged over the sidebar, whose zones take text too, is no tab drag: the
        // drop views stay out of it and the tab drag the router holds stays where it is.
        _ = router.updated(Info(row), at: tabs)
        precondition(router.updated(Info(overPage, carrying: .string), at: tabs) == [])
        router.exited(Info(overPage, carrying: .string), at: tabs)
        precondition(!router.perform(Info(overPage, carrying: .string), at: tabs))
        precondition(tabs.log == ["updated"] && page.log.isEmpty)
        router.end()
        precondition(tabs.log == ["updated", "exited"])
        reset()

        // Over another Nook window in front, the drag is that window's, whichever view AppKit holds.
        _ = router.updated(Info(row), at: tabs)
        precondition(router.updated(Info(NSPoint(x: 700, y: 400)), at: tabs) == .move)
        precondition(otherTabs.log == ["updated"] && tabs.log == ["updated", "exited"])
        precondition(router.perform(Info(NSPoint(x: 700, y: 400)), at: tabs))
        precondition(otherTabs.log == ["updated", "performed"] && page.log.isEmpty, "the page under the other window takes nothing")
        reset()

        // A view out of every window, such as a row a relayout took away, takes no drag.
        let gone = Target("gone", NSRect(x: 0, y: 0, width: 100, height: 100))
        precondition(router.updated(Info(NSPoint(x: 50, y: 50)), at: gone) == [])
        precondition(!router.perform(Info(NSPoint(x: 50, y: 50)), at: gone))
        precondition(gone.log.isEmpty && tabs.log.isEmpty)
        print("TabDropRoutingCheck passed")
    }

    final class Plain: NSView {
        init(_ frame: NSRect, accepting types: [NSPasteboard.PasteboardType] = []) {
            super.init(frame: frame)
            if !types.isEmpty { registerForDraggedTypes(types) }
        }
        required init?(coder: NSCoder) { fatalError() }
    }

    final class Target: NSView, TabDropTarget {
        let name: String
        var log: [String] = []
        /// What it answers, if not its usual.
        var answer: NSDragOperation?
        init(_ name: String, _ frame: NSRect) {
            self.name = name
            super.init(frame: frame)
            registerForDraggedTypes([TabDropRouter.tabType])
        }
        required init?(coder: NSCoder) { fatalError() }
        override var description: String { name }

        func tabDragUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            log.append("updated")
            return answer ?? (name == "page" ? .copy : .move)
        }
        func tabDragExited() { log.append("exited") }
        func tabDragPerform(_ sender: NSDraggingInfo) -> Bool {
            log.append("performed")
            return true
        }
    }

    /// A drag at `draggingLocation`, in the coordinates of the window AppKit sends it to.
    final class Info: NSObject, NSDraggingInfo {
        let draggingLocation: NSPoint
        let draggingPasteboard = NSPasteboard.withUniqueName()
        init(_ location: NSPoint, carrying type: NSPasteboard.PasteboardType = TabDropRouter.tabType) {
            draggingLocation = location
            draggingPasteboard.declareTypes([type], owner: nil)
        }

        var draggingDestinationWindow: NSWindow? { nil }
        var draggingSourceOperationMask: NSDragOperation { .move }
        var draggedImageLocation: NSPoint { draggingLocation }
        var draggedImage: NSImage? { nil }
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 1 }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                    classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func resetSpringLoading() {}
    }

    /// The view AppKit sends a drag to: its own search for the frontmost view under the point
    /// registered for one of the drag's types (`-[NSView _hitTest:dragTypes:]`, which takes the
    /// point by reference in the superview's coordinates).
    @MainActor static func appKitTarget(in root: NSView, at point: NSPoint, types: [NSPasteboard.PasteboardType]) -> NSView? {
        typealias DragHitTest = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSPoint>, AnyObject) -> Unmanaged<AnyObject>?
        let selector = NSSelectorFromString("_hitTest:dragTypes:")
        guard let method = class_getInstanceMethod(NSView.self, selector) else { fatalError("AppKit no longer has _hitTest:dragTypes:") }
        let hitTest = unsafeBitCast(method_getImplementation(method), to: DragHitTest.self)
        var location = point
        return hitTest(root, selector, &location, NSSet(array: types.map(\.rawValue)))?.takeUnretainedValue() as? NSView
    }
}
