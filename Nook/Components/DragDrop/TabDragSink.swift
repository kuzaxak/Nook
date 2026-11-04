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

final class TabDragSink: NSView {
    init(types: [NSPasteboard.PasteboardType]) {
        super.init(frame: .zero)
        registerForDraggedTypes(types)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { [] }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { false }
}
