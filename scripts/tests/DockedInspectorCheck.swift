// Licensed under GPL-3.0. See LICENSE.
//
// swiftc -parse-as-library Nook/Utils/WebKit/DockedInspector.swift scripts/tests/DockedInspectorCheck.swift -o /tmp/docked-inspector && /tmp/docked-inspector
//
// Where the compositor leaves a page and the Web Inspector docked to it: plain views first, then a
// real page whose inspector docks at the bottom, through a relayout, another tab, a split pane, a
// close and an undock. Opens an off-screen window for about ten seconds.

import AppKit
import WebKit

@main
struct DockedInspectorCheck {
    /// WebKit keeps the inspector's docked state in the running program's defaults.
    static let startsAttached = "__WebInspectorPageGroupLevel1__.WebKit2InspectorStartsAttached"

    @MainActor
    static func main() {
        checkViews()
        checkWebKit()
    }

    @MainActor
    static func checkViews() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let page = NSView(), stale = NSView(), overlay = NSView()
        container.addSubview(stale)
        container.addSubview(overlay)
        container.showPage(page, inspector: nil, replacing: [stale])
        precondition(page.superview === container && page.frame == container.bounds, "With no inspector the page fills its pane")
        precondition(stale.superview == nil && overlay.superview === container, "Only the views given are taken out")

        // Docked: WebKit put the inspector below the page and sized both.
        let inspector = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 250))
        container.addSubview(inspector, positioned: .below, relativeTo: page)
        page.frame = NSRect(x: 0, y: 250, width: 800, height: 350)
        container.showPage(page, inspector: inspector, replacing: [inspector, page])
        precondition(inspector.superview === container, "A relayout keeps the docked inspector")
        precondition(page.frame == NSRect(x: 0, y: 250, width: 800, height: 350) && inspector.frame.height == 250,
                     "and leaves both where WebKit put them")

        // Another tab: the page and its inspector leave together.
        let other = NSView()
        container.showPage(other, inspector: nil, replacing: [inspector, page])
        precondition(page.superview == nil && inspector.superview == nil && other.frame == container.bounds)

        // Back: the page fills its pane for WebKit to share out again, with its inspector just below.
        container.showPage(page, inspector: inspector, replacing: [other])
        let order = container.subviews
        precondition(other.superview == nil && page.frame == container.bounds && inspector.superview === container)
        precondition(order.firstIndex(of: inspector)! + 1 == order.firstIndex(of: page)!, "The inspector goes back below its page")
        print("PASS: the compositor keeps a docked inspector with its page")
    }

    @MainActor
    static func checkWebKit() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        UserDefaults.standard.removeObject(forKey: startsAttached)
        defer { UserDefaults.standard.removeObject(forKey: startsAttached) }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 900), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 900))
        window.contentView = root
        let single = NSView(frame: root.bounds)
        let pane = NSView(frame: NSRect(x: 500, y: 0, width: 500, height: 860))
        root.addSubview(single)
        window.orderFront(nil)

        let page = makePage(), other = makePage()
        func show(_ view: WKWebView, in container: NSView) {
            container.showPage(view, inspector: view.dockedInspector, replacing: container.subviews)
        }
        /// No grey band: the page fills its pane, or the page and its docked inspector tile it.
        func covered(_ container: NSView) -> Bool {
            guard page.superview === container else { return false }
            if page.frame == container.bounds { return true }
            guard let inspector = page.dockedInspector, inspector.superview === container else { return false }
            return page.frame.union(inspector.frame) == container.bounds && !page.frame.intersects(inspector.frame)
        }
        func dock() {
            perform("show", on: page)
            perform("attach", on: page)
            waitUntil("the inspector docks") { page.dockedInspector?.superview === page.superview && page.superview != nil }
            wait(0.3)
        }

        show(page, in: single)
        wait(1)
        dock()
        precondition(covered(single) && page.frame.height < single.bounds.height, "Docked at the bottom, sharing the pane")

        show(page, in: single)
        wait(0.3)
        precondition(covered(single), "A relayout keeps the inspector beside the page")

        show(other, in: single)
        wait(0.3)
        precondition(other.frame == single.bounds && page.superview == nil)
        show(page, in: single)
        wait(0.5)
        precondition(covered(single), "Back on the page after another tab, its inspector is back too")

        single.subviews.forEach { $0.removeFromSuperview() }
        root.addSubview(pane)
        show(page, in: pane)
        wait(0.5)
        precondition(covered(pane), "In a split pane the inspector stays with its page")
        pane.removeFromSuperview()
        show(page, in: single)
        wait(0.5)
        precondition(covered(single), "and comes back out of the split with it")
        print("PASS: a docked inspector stays beside its page through a relayout, a tab switch and a split")

        perform("close", on: page)
        waitUntil("the inspector closes") { page.dockedInspector == nil }
        wait(0.3)
        precondition(page.frame == single.bounds, "Closed, the page fills its pane again, got \(page.frame)")

        dock()
        show(other, in: single)
        wait(0.3)
        show(page, in: single)
        wait(0.5)
        perform("detach", on: page)
        waitUntil("the inspector undocks") { page.dockedInspector == nil }
        wait(0.3)
        precondition(page.frame == single.bounds, "Undocked after a tab switch, the page fills its pane, got \(page.frame)")
        perform("close", on: page)
        wait(0.5)
        print("PASS: closed or undocked, the page fills its pane")
    }

    @MainActor
    static func makePage() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let page = WKWebView(frame: .zero, configuration: configuration)
        page.loadHTMLString("<h1>page</h1>", baseURL: nil)
        return page
    }

    @MainActor
    static func perform(_ name: String, on page: WKWebView) {
        let inspector = page.perform(NSSelectorFromString("_inspector"))!.takeUnretainedValue() as! NSObject
        inspector.perform(NSSelectorFromString(name))
    }

    @MainActor
    static func wait(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor
    static func waitUntil(_ what: String, timeout: TimeInterval = 10, _ done: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() {
            precondition(Date() < deadline, "Timed out waiting for \(what)")
            wait(0.05)
        }
    }
}
