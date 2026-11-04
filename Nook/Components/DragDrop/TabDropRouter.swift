// Licensed under GPL-3.0. See LICENSE.
//
//  TabDropRouter.swift
//  Nook
//
//  Hands each AppKit callback of a tab drag to the drop view under the pointer. AppKit picks the
//  destination view only when the window server reports the drag moving; between those reports
//  it re-sends `draggingUpdated:` to the view it last entered every 50 ms, and the drop goes there
//  too. Checked by `scripts/tests/TabDropRoutingCheck.swift`.
//

import AppKit

/// A view that takes tab drags: a sidebar drop zone, the page's split target, or a sink.
@MainActor protocol TabDropTarget: NSView {
    func tabDragUpdated(_ sender: NSDraggingInfo) -> NSDragOperation
    func tabDragExited()
    func tabDragPerform(_ sender: NSDraggingInfo) -> Bool
}

@MainActor final class TabDropRouter {
    static let shared = TabDropRouter()
    static let tabType = NSPasteboard.PasteboardType("com.nook.tab-drag-item")

    private weak var current: TabDropTarget?

    /// `draggingEntered:` and `draggingUpdated:` of `receiver`.
    func updated(_ sender: NSDraggingInfo, at receiver: TabDropTarget) -> NSDragOperation {
        let owner = Self.owner(of: sender, at: receiver)
        if owner !== current {
            current?.tabDragExited()
            current = owner
        }
        return owner?.tabDragUpdated(sender) ?? []
    }

    /// `draggingExited:` of `receiver`. The drag stays with the view it was handed to while the
    /// pointer is still over that view.
    func exited(_ sender: NSDraggingInfo?, at receiver: TabDropTarget) {
        if let sender, let current, Self.owner(of: sender, at: receiver) === current { return }
        current?.tabDragExited()
        current = nil
    }

    /// `performDragOperation:` of `receiver`.
    func perform(_ sender: NSDraggingInfo, at receiver: TabDropTarget) -> Bool {
        let owner = Self.owner(of: sender, at: receiver)
        if owner !== current { current?.tabDragExited() }
        current = nil
        return owner?.tabDragPerform(sender) ?? false
    }

    private static func owner(of sender: NSDraggingInfo, at receiver: NSView) -> TabDropTarget? {
        var root = receiver
        while let superview = root.superview { root = superview }
        return target(at: root.convert(sender.draggingLocation, from: nil), in: root)
    }

    /// The drop view a tab drag at `point` belongs to, as AppKit finds one: the frontmost view
    /// under the point registered for the tab type. `point` is in `root`'s coordinates.
    static func target(at point: NSPoint, in root: NSView) -> TabDropTarget? {
        frontmost(in: root, at: point, of: root) as? TabDropTarget
    }

    private static func frontmost(in view: NSView, at point: NSPoint, of root: NSView) -> NSView? {
        guard !view.isHidden, view.bounds.contains(view.convert(point, from: root)) else { return nil }
        for subview in view.subviews.reversed() {
            if let found = frontmost(in: subview, at: point, of: root) { return found }
        }
        return view.registeredDraggedTypes.contains(tabType) ? view : nil
    }
}
