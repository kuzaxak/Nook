// Licensed under GPL-3.0. See LICENSE.
//
//  TabDragSink.swift
//  Nook
//
//  Under a surface that floats over the page, so a tab dropped between that surface's own drop
//  zones lands nowhere instead of on the page beneath it. AppKit sends a drag to the frontmost
//  view under the pointer registered for one of its types, whatever is drawn above it. Checked
//  by `scripts/tests/FloatingSidebarDropCheck.swift`.
//

import AppKit

final class TabDragSink: NSView, TabDropTarget {
    init(types: [NSPasteboard.PasteboardType]) {
        super.init(frame: .zero)
        registerForDraggedTypes(types)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { TabDropRouter.shared.updated(sender, at: self) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { TabDropRouter.shared.updated(sender, at: self) }
    override func draggingExited(_ sender: NSDraggingInfo?) { TabDropRouter.shared.exited(sender, at: self) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { TabDropRouter.shared.perform(sender, at: self) }

    func tabDragUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { [] }
    func tabDragExited() {}
    func tabDragPerform(_ sender: NSDraggingInfo) -> Bool { false }
}
