// Licensed under GPL-3.0. See LICENSE.
import AppKit
import WebKit
import NookDesign

final class SplitDropCaptureView: NSView, TabDropTarget {
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
        TabDropRouter.shared.updated(sender, at: self)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        TabDropRouter.shared.updated(sender, at: self)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        TabDropRouter.shared.exited(sender, at: self)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        TabDropRouter.shared.perform(sender, at: self)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        TabDropRouter.shared.end()
    }

    func tabDragUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isDragActive = NookDragItem.fromPasteboard(sender.draggingPasteboard) != nil
        guard let windowId, let sm = splitManager else { return [] }
        guard let drop = drop(for: sender) else {
            sm.setPreview(nil, for: windowId)
            return []
        }
        sm.setPreview(SplitViewManager.Preview(outcome: drop.outcome, zone: drop.zone), for: windowId)
        return SplitDrop.operation(allowed: sender.draggingSourceOperationMask)
    }

    func tabDragExited() {
        isDragActive = false
        if let windowId { splitManager?.setPreview(nil, for: windowId) }
    }

    func tabDragPerform(_ sender: NSDraggingInfo) -> Bool {
        isDragActive = false
        guard let windowId, let sm = splitManager else { return false }
        sm.setPreview(nil, for: windowId)
        guard let drop = drop(for: sender), let window = browserManager?.windowRegistry?.windows[windowId] else { return false }
        sm.drop(drop.itemID, drop.outcome, in: window)
        // The sidebar's own drop never ran, so its lifted row and preview are still up.
        DispatchQueue.main.async {
            NookDragSessionManager.shared.cancelDrag()
        }
        return true
    }

    // MARK: - Helpers

    /// The dragged tab, what dropping it here does, and the part of the page that shows it, as a
    /// fraction of the page from its top-left corner. nil when the drop changes nothing.
    private func drop(for sender: NSDraggingInfo) -> (itemID: UUID, outcome: SplitDrop.Outcome, zone: CGRect)? {
        guard let sm = splitManager, let windowId, let window = browserManager?.windowRegistry?.windows[windowId],
              bounds.width > 0, bounds.height > 0,
              let item = NookDragItem.fromPasteboard(sender.draggingPasteboard), let dragged = sm.dragged(item.tabId, in: window)
        else { return nil }
        let page = CGRect(origin: .zero, size: bounds.size)
        let local = convert(sender.draggingLocation, from: nil)
        let point = CGPoint(x: local.x, y: bounds.height - local.y)
        let gap = NookDesign.Chrome.splitGap
        guard let outcome = SplitDrop.outcome(of: dragged, at: point, in: page, gap: gap, selected: window.selectedItemID,
                                              split: window.splitLayout) else { return nil }
        let zone = SplitDrop.zone(of: outcome, in: page, gap: gap, split: SplitDrop.current(window.splitLayout, selected: window.selectedItemID))
        return (item.tabId, outcome, CGRect(x: zone.minX / page.width, y: zone.minY / page.height,
                                            width: zone.width / page.width, height: zone.height / page.height))
    }
}
