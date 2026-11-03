// Licensed under GPL-3.0. See LICENSE.
//
//  TabSwitcherState.swift
//  NookWeb
//
//  The Control-Tab switcher's place in a window's recent tabs: which tabs it shows (most recent
//  first, the current one at the front) and which is highlighted. Foundation only, checked by
//  `Checks/TabSwitcherStateCheck.swift`.
//

import Foundation

public struct TabSwitcherState: Equatable, Sendable {
    public let items: [UUID]
    public private(set) var index: Int
    /// Tiles per row; the arrow keys move along a row and between rows.
    public let columns: Int
    /// Whether the card is drawn; it waits `presentDelay` so a quick tap switches with no flash.
    public var isPresented = false

    public static let presentDelay: TimeInterval = 0.1
    /// Recent tabs the card shows at most.
    public static let maxItems = 20
    public static let maxColumns = 6
    /// A tile's width with the gap after it, for fitting rows to the window.
    public static let tileStride: Double = 188

    public static func shouldPresent(elapsed: TimeInterval) -> Bool { elapsed >= presentDelay }

    /// Tiles per row that fit a window `width` points wide.
    public static func columns(forWidth width: Double) -> Int {
        min(maxColumns, max(1, Int((width - 2 * tileStride / 3) / tileStride)))
    }

    /// Opens on the tab you were on before this one (or the oldest, going backwards), as Arc's
    /// does; nil when there is nothing to switch to.
    public static func start(items: [UUID], step: Int, columns: Int = maxColumns) -> TabSwitcherState? {
        guard items.count > 1 else { return nil }
        return TabSwitcherState(items: items, index: step >= 0 ? 1 : items.count - 1,
                                columns: max(1, min(columns, items.count)), isPresented: false)
    }

    public mutating func advance(by step: Int) {
        index = ((index + step) % items.count + items.count) % items.count
    }

    /// Up or down a row; stays put when there is no tile there.
    public mutating func moveRow(by rows: Int) {
        let target = index + rows * columns
        if items.indices.contains(target) { index = target }
    }

    public var highlighted: UUID { items[index] }
}
