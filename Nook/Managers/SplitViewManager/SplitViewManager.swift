// Licensed under GPL-3.0. See LICENSE.
import SwiftUI
import NookDesign
import NookTabsCore
import NookWeb

/// Split view per window. The panes live on `BrowserWindowState.split` (item ids, saved with the
/// window); the active pane is whichever one the window selects. Only the drop preview is kept here.
@MainActor
final class SplitViewManager: ObservableObject {
    /// What a tab dragged over the page would do, and where: `zone` is a fraction of the page,
    /// from its top-left corner.
    struct Preview: Equatable {
        var outcome: SplitDrop.Outcome
        var zone: CGRect
    }

    /// The page's panes in order, nil standing for Add Split View's empty pane.
    struct PageLayout: Equatable {
        var slots: [UUID?]
        var vertical: Bool
        var dividers: [CGFloat]
    }

    weak var browserManager: BrowserManager?

    @Published private var previews: [UUID: Preview] = [:]

    init(browserManager: BrowserManager? = nil) {
        self.browserManager = browserManager
    }

    private var tabs: TabsController? { browserManager?.tabs }

    // MARK: - State

    /// The split `window` shows: its saved one while one of its panes is selected.
    func shownSplit(in window: BrowserWindowState) -> SplitRecord? {
        guard let split = window.split, let selected = window.selectedItemID, split.contains(selected) else { return nil }
        return split
    }

    /// What the page lays out: Add Split View's panes while its bar is open, else the split shown.
    func pageLayout(in window: BrowserWindowState) -> PageLayout? {
        if let adding = window.commandPalette?.addSplit, adding.shows(selectedItemID: window.selectedItemID, split: window.splitLayout) {
            return PageLayout(slots: adding.slots, vertical: adding.vertical, dividers: SplitDrop.equalDividers(adding.slots.count))
        }
        return shownSplit(in: window).map {
            PageLayout(slots: $0.itemIDs, vertical: $0.orientation == .vertical, dividers: $0.dividers.map { CGFloat($0) })
        }
    }

    /// Each pane's frame in the page area `bounds`, top-down, with the gutter between them.
    static func paneFrames(in bounds: CGRect, of layout: PageLayout) -> [CGRect] {
        SplitDrop.paneFrames(in: bounds, count: layout.slots.count, vertical: layout.vertical,
                             dividers: layout.dividers, gap: NookDesign.Chrome.splitGap)
    }

    /// `itemID` as a split sees it: whether it is a tab, and one of the tree `window` shows.
    func dragged(_ itemID: UUID, in window: BrowserWindowState) -> SplitDrop.Dragged? {
        guard let tabs, let item = tabs.item(itemID) else { return nil }
        return SplitDrop.Dragged(id: itemID, isTab: !item.isFolder, isInWindow: tabs.holds(itemID, in: window))
    }

    // MARK: - Dropping and Opening

    /// What `SplitDrop` decided for a tab dropped on the page. A new split keeps the selected tab
    /// selected; a tab that opens in a pane or takes one becomes the selection.
    func drop(_ itemID: UUID, _ outcome: SplitDrop.Outcome, in window: BrowserWindowState) {
        guard let tabs else { return }
        switch outcome {
        case .split(let edge):
            guard let current = window.selectedItemID,
                  let record = SplitRecord(edge == .leading ? [itemID, current] : [current, itemID]) else { return }
            window.split = record
            loadPanes(of: window)
            // Selecting again saves the window record with its new split.
            tabs.select(current, in: window)
        case .insert(let pane, let edge):
            guard let record = shownSplit(in: window)?.inserting(itemID, beside: pane, after: edge == .trailing) else { return }
            window.split = record
            loadPanes(of: window)
            tabs.select(itemID, in: window)
        case .replace(let pane):
            guard let record = shownSplit(in: window)?.replacing(pane, with: itemID) else { return }
            window.split = record
            loadPanes(of: window)
            tabs.select(itemID, in: window)
        case .move(let pane, let edge):
            guard let record = shownSplit(in: window)?.moving(itemID, beside: pane, after: edge == .trailing) else { return }
            update(window, to: record)
        }
    }

    /// Open in Split View, from a tab's menu, a link or a Peek: on `edge` of the selected tab, or of
    /// the selected pane, which it takes once four show.
    func enterSplit(with itemID: UUID, placeOn edge: SplitDrop.Edge = .trailing, in window: BrowserWindowState) {
        guard let dragged = dragged(itemID, in: window) else { return }
        let layout = window.splitLayout
        let pane = window.selectedItemID.flatMap { SplitDrop.current(layout, selected: $0)?.panes.firstIndex(of: $0) } ?? 0
        guard let outcome = SplitDrop.outcome(of: dragged, beside: pane, edge, selected: window.selectedItemID, split: layout) else { return }
        drop(itemID, outcome, in: window)
    }

    // MARK: - Add Split View

    /// Arc's Add Split View, for ⌃⇧=, the command bar and the sidebar's New Split: the command bar
    /// opens over an empty pane after the window's tab, or after its split's last pane.
    func addSplitView(in window: BrowserWindowState) {
        guard let addSplit = AddSplit.start(selectedItemID: window.selectedItemID, split: window.splitLayout) else { return }
        window.commandPalette?.open(addSplit: addSplit)
    }

    func offersAddSplitView(in window: BrowserWindowState) -> Bool {
        AddSplit.isOffered(selectedItemID: window.selectedItemID, split: window.splitLayout)
    }

    /// A pane's Add Right Split or Add Left Split: the empty pane beside that pane.
    func addSplit(beside itemID: UUID, after: Bool, in window: BrowserWindowState) {
        guard let addSplit = AddSplit.start(beside: itemID, after: after, selectedItemID: window.selectedItemID,
                                            split: window.splitLayout) else { return }
        window.commandPalette?.open(addSplit: addSplit)
    }

    /// `itemID`, chosen in the command bar, takes Add Split View's empty pane and becomes the selection.
    func fill(_ addSplit: AddSplit, with itemID: UUID, in window: BrowserWindowState) {
        guard let tabs, let filled = addSplit.filling(choosing: itemID, selectedItemID: window.selectedItemID, split: window.splitLayout),
              let record = shownSplit(in: window).map({ $0.inserting(filled, at: addSplit.index) }) ?? SplitRecord(addSplit.panes + [filled])
        else { return }
        window.split = record
        loadPanes(of: window)
        tabs.select(filled, in: window)
    }

    // MARK: - A Pane's Menu

    /// Move Left or Right, Up or Down when stacked.
    func move(_ itemID: UUID, by offset: Int, in window: BrowserWindowState) {
        guard let record = shownSplit(in: window)?.moving(itemID, by: offset) else { return }
        update(window, to: record)
    }

    /// Convert to Vertical, or Horizontal, Split View.
    func convert(in window: BrowserWindowState) {
        guard let record = shownSplit(in: window) else { return }
        update(window, to: record.converted())
    }

    /// Separate Tab from Split: the tab leaves the split and stays in the sidebar. With one pane
    /// left the split ends. A separated selected tab hands the selection to the pane beside it.
    func separate(_ itemID: UUID, in window: BrowserWindowState) {
        guard let tabs, let split = shownSplit(in: window), let index = split.itemIDs.firstIndex(of: itemID) else { return }
        let remaining = split.removing(itemID)
        guard window.selectedItemID == itemID else { return update(window, to: remaining) }
        window.split = remaining
        tabs.select(split.itemIDs[index + 1 < split.itemIDs.count ? index + 1 : index - 1], in: window)
    }

    /// Ends the split and keeps all its tabs open. The active pane stays selected.
    func separateAll(in window: BrowserWindowState) {
        guard window.split != nil else { return }
        update(window, to: nil)
    }

    /// Divider `index` dragged to `position`, a fraction of the page's width or height.
    func moveDivider(_ index: Int, to position: CGFloat, length: CGFloat, in window: BrowserWindowState) {
        guard var record = window.split, length > 0 else { return }
        record.moveDivider(index, to: Double(position), minimum: min(0.9 / Double(record.itemIDs.count), 160 / Double(length)))
        window.split = record
    }

    /// A divider let go: the window record keeps where it was left.
    func dividerMoveEnded(in window: BrowserWindowState) {
        tabs?.mirror(window)
    }

    /// No selection change to save the record, so save it here.
    private func update(_ window: BrowserWindowState, to record: SplitRecord?) {
        window.split = record
        tabs?.mirror(window)
        window.refreshCompositor()
    }

    /// A pane shows its page, so the sidebar gives it back first.
    private func loadPanes(of window: BrowserWindowState) {
        guard let bm = browserManager, let split = window.split else { return }
        for id in split.itemIDs {
            bm.exitSidebarPiP(showing: id)
            if let session = bm.tabs.ensureSession(for: id) {
                PiPManager.shared.leaveAutomatic(session)
                bm.compositorManager.load(session)
            }
        }
    }

    func cleanupWindow(_ windowId: UUID) {
        previews.removeValue(forKey: windowId)
    }

    // MARK: - Preview During Drag-Over

    func preview(for windowId: UUID) -> Preview? { previews[windowId] }

    func setPreview(_ preview: Preview?, for windowId: UUID) {
        guard previews[windowId] != preview else { return }
        previews[windowId] = preview
    }
}

extension BrowserWindowState {
    /// The saved split as `SplitDrop` and `AddSplit` take it.
    var splitLayout: SplitDrop.Layout? {
        split.map {
            SplitDrop.Layout(panes: $0.itemIDs, vertical: $0.orientation == .vertical, dividers: $0.dividers.map { CGFloat($0) }, isFull: $0.isFull)
        }
    }
}
