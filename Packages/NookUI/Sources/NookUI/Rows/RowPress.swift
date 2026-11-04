// Licensed under GPL-3.0. See LICENSE.
//
//  RowPress.swift
//  NookUI
//
//  A press on a sidebar row, read as Arc reads it: released before the pointer moves
//  `dragThreshold` points, it is a click and the row's action runs; moved that far, it is a drag
//  and the row's action does nothing until the next press, so dragging a tab leaves the current
//  page showing. The app's drag monitor feeds it. Checked by `scripts/tests/RowPressCheck.swift`.
//

import CoreGraphics

public struct RowPress {
    public static let dragThreshold: CGFloat = 4
    @MainActor public static var current = RowPress()

    private var start: CGPoint?
    /// The press moved past the threshold. Stays set until the next press.
    public private(set) var isDrag = false

    public init() {}

    public mutating func down(at point: CGPoint) {
        start = point
        isDrag = false
    }

    /// True when this move turns the press into a drag.
    public mutating func moved(to point: CGPoint) -> Bool {
        guard let start, !isDrag, hypot(point.x - start.x, point.y - start.y) >= Self.dragThreshold else { return false }
        isDrag = true
        return true
    }

    public mutating func up() {
        start = nil
    }

    /// A row's click action: runs once the press is released, unless it became a drag.
    @MainActor public static func click(_ action: () -> Void) {
        if current.start == nil, !current.isDrag { action() }
    }
}
