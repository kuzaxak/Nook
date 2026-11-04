// Licensed under GPL-3.0. See LICENSE.
// swiftc Nook/Components/DragDrop/TabDragSink.swift scripts/tests/FloatingSidebarDropCheck.swift -o /tmp/fsd && /tmp/fsd
//
// The sidebar revealed by hovering the window's edge floats over the page. A tab dropped between
// its drop zones must land on neither the zones nor the page under it, which would split the window.

import AppKit

@main
struct FloatingSidebarDropCheck {
    @MainActor static func main() {
        let tabType = NSPasteboard.PasteboardType("com.nook.tab-drag-item")
        let root = Named("window", NSRect(x: 0, y: 0, width: 1000, height: 700))
        let page = Named("page", root.bounds, accepting: [tabType])
        let sidebar = Named("floating sidebar", NSRect(x: 8, y: 8, width: 250, height: 684))
        let sink = TabDragSink(types: [tabType])
        sink.frame = sidebar.bounds
        let favorites = Named("favorites zone", NSRect(x: 0, y: 600, width: 250, height: 60), accepting: [tabType])
        let tabs = Named("tabs zone", NSRect(x: 0, y: 0, width: 250, height: 460), accepting: [tabType])
        root.addSubview(page)
        root.addSubview(sidebar)
        sidebar.addSubview(sink)
        sidebar.addSubview(favorites)
        sidebar.addSubview(tabs)

        precondition(target(in: root, at: NSPoint(x: 100, y: 630), types: [tabType]) === favorites)
        precondition(target(in: root, at: NSPoint(x: 100, y: 300), types: [tabType]) === tabs)
        precondition(target(in: root, at: NSPoint(x: 100, y: 520), types: [tabType]) === sink, "a gap between the sidebar's zones")
        precondition(target(in: root, at: NSPoint(x: 600, y: 350), types: [tabType]) === page, "the page beside the sidebar")
        print("FloatingSidebarDropCheck passed")
    }

    final class Named: NSView {
        let name: String
        init(_ name: String, _ frame: NSRect, accepting types: [NSPasteboard.PasteboardType] = []) {
            self.name = name
            super.init(frame: frame)
            if !types.isEmpty { registerForDraggedTypes(types) }
        }
        required init?(coder: NSCoder) { fatalError() }
    }

    /// The view AppKit sends a drag to: its own search for the frontmost view under the point
    /// registered for one of the drag's types (`-[NSView _hitTest:dragTypes:]`, which takes the
    /// point by reference in the superview's coordinates).
    @MainActor static func target(in root: NSView, at point: NSPoint, types: [NSPasteboard.PasteboardType]) -> NSView? {
        typealias DragHitTest = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSPoint>, AnyObject) -> Unmanaged<AnyObject>?
        let selector = NSSelectorFromString("_hitTest:dragTypes:")
        guard let method = class_getInstanceMethod(NSView.self, selector) else { fatalError("AppKit no longer has _hitTest:dragTypes:") }
        let hitTest = unsafeBitCast(method_getImplementation(method), to: DragHitTest.self)
        var location = point
        return hitTest(root, selector, &location, NSSet(array: types.map(\.rawValue)))?.takeUnretainedValue() as? NSView
    }
}
