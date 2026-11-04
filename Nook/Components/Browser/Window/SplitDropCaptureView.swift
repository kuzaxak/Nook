// Licensed under GPL-3.0. See LICENSE.
import AppKit
import WebKit

final class SplitDropCaptureView: NSView {
    weak var browserManager: BrowserManager?
    weak var splitManager: SplitViewManager?
    var windowId: UUID?
    private var isDragActive: Bool = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        // Tab drags only: AppKit hands a drag to the frontmost view registered for one of its
        // types, so text here would take the page's own text drags, and the page its tab drags.
        registerForDraggedTypes([.nookTabItem])
        // Transparent to normal mouse events; only DnD uses these callbacks
        isHidden = false
    }

    // Only intercept events during an active drag; otherwise pass through
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Return nil to pass through all mouse events when not dragging
        // This allows right-clicks to reach the webview below for context menus
        return isDragActive ? self : nil
    }

    // Override acceptsFirstResponder to prevent this view from intercepting events
    override var acceptsFirstResponder: Bool { false }

    // MARK: - Dragging
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isDragActive = true
        guard let windowId, let sm = splitManager else { return [] }
        sm.updateDragLocation(convert(sender.draggingLocation, from: nil), for: windowId)
        guard let drop = drop(for: sender) else {
            if sm.getSplitState(for: windowId).isPreviewActive { sm.endPreview(cancel: true, for: windowId) }
            return []
        }
        if sm.getSplitState(for: windowId).isPreviewActive {
            sm.updatePreviewSide(drop.side, for: windowId)
        } else {
            sm.beginPreview(side: drop.side, for: windowId)
        }
        return SplitDrop.operation(allowed: sender.draggingSourceOperationMask)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDragActive = false
        if let windowId {
            splitManager?.updateDragLocation(nil, for: windowId)
            splitManager?.endPreview(cancel: true, for: windowId)
        }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDragActive = false
        guard let windowId, let sm = splitManager else { return false }
        sm.updateDragLocation(nil, for: windowId)
        sm.endPreview(cancel: false, for: windowId)
        guard let drop = drop(for: sender), let window = browserManager?.windowRegistry?.windows[windowId] else { return false }
        sm.enterSplit(with: drop.itemID, placeOn: drop.side, in: window)
        // The sidebar's own drop never ran, so its lifted row and preview are still up.
        DispatchQueue.main.async {
            NookDragSessionManager.shared.cancelDrag()
        }
        return true
    }

    // MARK: - Helpers

    /// The dragged tab and the half of the page it would take, when dropping it there changes the split.
    private func drop(for sender: NSDraggingInfo) -> (itemID: UUID, side: SplitDrop.Side)? {
        guard let bm = browserManager, let windowId, let window = bm.windowRegistry?.windows[windowId],
              let item = NookDragItem.fromPasteboard(sender.draggingPasteboard), bm.tabs.item(item.tabId) != nil,
              let side = SplitDrop.side(of: convert(sender.draggingLocation, from: nil), in: bounds) else { return nil }
        let pair = window.split.map { (left: $0.leftItemID, right: $0.rightItemID) }
        guard SplitDrop.outcome(of: item.tabId, on: side, selected: window.selectedItemID, split: pair) != nil else { return nil }
        return (item.tabId, side)
    }
}
