// Licensed under GPL-3.0. See LICENSE.
import SwiftUI
import NookDesign
import NookTabsCore
import NookUI
import NookWeb

/// The window's split shown as one sidebar row (from `BrowserWindowState.split`), a part per pane.
/// The parts' visuals are `SplitHalfLabel` in NookUI; this file is the drag source around them.
struct SplitTabRow: View {
    let items: [Item]
    /// The drop zone the parts drag from.
    let zoneID: DropZoneID

    @Environment(BrowserWindowState.self) private var windowState
    @State private var isHovering = false

    /// The whole row is the selection while the window shows the split.
    private var isActive: Bool {
        items.contains { $0.id == windowState.selectedItemID }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Rectangle()
                        .fill(NookDesign.Surface.hairline)
                        .frame(width: NookDesign.Size.hairlineWidth)
                        .padding(.vertical, NookDesign.Spacing.sm)
                }
                SplitHalfTab(item: item, zoneID: zoneID)
            }
        }
        .frame(height: NookDesign.Tab.height)
        .nookTabSurface(selected: isActive, hovered: isHovering)
        .padding(.vertical, NookDesign.Tab.verticalInset)
        .onHoverTracking { isHovering = $0 }
    }
}

private struct SplitHalfTab: View {
    let item: Item
    let zoneID: DropZoneID

    @Environment(TabsController.self) private var tabs
    @ObservedObject private var dragSession = NookDragSessionManager.shared

    var body: some View {
        let session = tabs.session(for: item.id)
        NookDragSourceView(
            item: NookDragItem(tabId: item.id, title: tabs.title(for: item), urlString: tabs.currentURL(for: item)?.absoluteString ?? ""),
            icon: session?.favicon,
            zoneID: zoneID,
            manager: dragSession
        ) {
            SplitHalfLabel(item: item)
        }
        .opacity(dragSession.draggedItem?.tabId == item.id ? NookDesign.Surface.unloadedOpacity : 1)
    }
}
