// Licensed under GPL-3.0. See LICENSE.
//
//  NookDropZoneHostView.swift
//  Nook
//

import SwiftUI
import AppKit

// MARK: - Drop Zone Coordinator

@MainActor
class NookDropZoneCoordinator: NSObject {
    var zoneID: DropZoneID
    var layout: DropLayout
    var onDrop: (UUID, DropPosition) -> Void
    let manager: NookDragSessionManager

    init(zoneID: DropZoneID, layout: DropLayout, manager: NookDragSessionManager, onDrop: @escaping (UUID, DropPosition) -> Void) {
        self.zoneID = zoneID
        self.layout = layout
        self.manager = manager
        self.onDrop = onDrop
    }
}

// MARK: - NookDropZoneNSView

class NookDropZoneNSView: NSView, TabDropTarget {
    weak var coordinator: NookDropZoneCoordinator?

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        TabDropRouter.shared.updated(sender, at: self)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        TabDropRouter.shared.updated(sender, at: self)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        TabDropRouter.shared.exited(sender, at: self)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        TabDropRouter.shared.perform(sender, at: self)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        TabDropRouter.shared.end()
    }

    func tabDragUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let coordinator, NookDragItem.fromPasteboard(sender.draggingPasteboard) != nil else { return [] }
        coordinator.manager.cursorEnteredZone(coordinator.zoneID)
        updatePosition(sender)
        return .move
    }

    func tabDragExited() {
        guard let coordinator else { return }
        coordinator.manager.cursorExitedZone(coordinator.zoneID)
    }

    func tabDragPerform(_ sender: NSDraggingInfo) -> Bool {
        guard let coordinator, let item = NookDragItem.fromPasteboard(sender.draggingPasteboard) else { return false }
        let point = flippedPoint(sender)
        let position = NookDragSessionManager.position(in: coordinator.zoneID, layout: coordinator.layout, point: point, width: bounds.width)
        let screenFrame = window?.convertToScreen(convert(bounds, to: nil)) ?? .zero
        coordinator.manager.finishDrag(at: position, layout: coordinator.layout, zoneScreenFrame: screenFrame) {
            coordinator.onDrop(item.tabId, position)
        }
        return true
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {}

    private func flippedPoint(_ sender: NSDraggingInfo) -> CGPoint {
        let localPoint = convert(sender.draggingLocation, from: nil)
        return CGPoint(x: localPoint.x, y: bounds.height - localPoint.y)
    }

    private func updatePosition(_ sender: NSDraggingInfo) {
        guard let coordinator = coordinator else { return }
        coordinator.manager.updateDropPosition(for: coordinator.zoneID, layout: coordinator.layout, localPoint: flippedPoint(sender), zoneWidth: bounds.width)
    }
}

// MARK: - Invisible Drop Zone Anchor (NSViewRepresentable)

private struct DropZoneAnchor: NSViewRepresentable {
    let zoneID: DropZoneID
    let layout: DropLayout
    let manager: NookDragSessionManager
    let onDrop: (UUID, DropPosition) -> Void

    func makeNSView(context: Context) -> NookDropZoneNSView {
        let view = NookDropZoneNSView()
        view.coordinator = context.coordinator
        view.registerForDraggedTypes([.nookTabItem, .string])
        return view
    }

    func updateNSView(_ nsView: NookDropZoneNSView, context: Context) {
        context.coordinator.zoneID = zoneID
        context.coordinator.layout = layout
        context.coordinator.onDrop = onDrop
    }

    func makeCoordinator() -> NookDropZoneCoordinator {
        NookDropZoneCoordinator(zoneID: zoneID, layout: layout, manager: manager, onDrop: onDrop)
    }
}

// MARK: - NookDropZoneHostView

/// Makes its content a drop target. `onDrop` runs on the main actor with the dragged item id.
struct NookDropZoneHostView<Content: View>: View {
    let zoneID: DropZoneID
    let layout: DropLayout
    let manager: NookDragSessionManager
    let onDrop: (UUID, DropPosition) -> Void
    @ViewBuilder let content: () -> Content

    init(zoneID: DropZoneID, layout: DropLayout, manager: NookDragSessionManager,
         onDrop: @escaping (UUID, DropPosition) -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.zoneID = zoneID
        self.layout = layout
        self.manager = manager
        self.onDrop = onDrop
        self.content = content
    }

    /// A row-less target such as a space title or switcher item.
    init(zoneID: DropZoneID, manager: NookDragSessionManager,
         onDrop: @escaping (UUID) -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.init(zoneID: zoneID, layout: .none, manager: manager, onDrop: { id, _ in onDrop(id) }, content: content)
    }

    var body: some View {
        content()
            .background(
                DropZoneAnchor(
                    zoneID: zoneID,
                    layout: layout,
                    manager: manager,
                    onDrop: onDrop
                )
            )
    }
}
