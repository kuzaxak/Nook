// Licensed under GPL-3.0. See LICENSE.
//
//  SplitRecord.swift
//  NookTabsCore
//
//  A window's split view as Arc lays it out: two to four tab panes side by side, or stacked, with
//  a draggable divider between each two. Saved with the window.
//

import Foundation

public struct SplitRecord: Hashable, Sendable {
    public enum Orientation: String, Codable, Sendable {
        /// Side by side.
        case horizontal
        /// Stacked.
        case vertical
    }

    public static let maxPanes = 4

    /// The panes' tabs, leading to trailing, or top to bottom when stacked.
    public private(set) var itemIDs: [UUID]
    public var orientation: Orientation
    /// Where each divider sits, as a fraction of the page from its leading or top edge.
    public private(set) var dividers: [Double]

    /// nil unless 2 to `maxPanes` different tabs. The panes start out the same size.
    public init?(_ itemIDs: [UUID], orientation: Orientation = .horizontal) {
        guard (2...Self.maxPanes).contains(itemIDs.count), Set(itemIDs).count == itemIDs.count else { return nil }
        self.itemIDs = itemIDs
        self.orientation = orientation
        dividers = (1..<itemIDs.count).map { Double($0) / Double(itemIDs.count) }
    }

    public var isFull: Bool { itemIDs.count == Self.maxPanes }

    public func contains(_ itemID: UUID) -> Bool { itemIDs.contains(itemID) }

    /// `itemID` as a new pane at `index`. nil once full, or for a tab that is a pane already.
    public func inserting(_ itemID: UUID, at index: Int) -> SplitRecord? {
        guard !contains(itemID), (0...itemIDs.count).contains(index) else { return nil }
        var ids = itemIDs
        ids.insert(itemID, at: index)
        return SplitRecord(ids, orientation: orientation)
    }

    /// `itemID` as a new pane after `pane`, or before it.
    public func inserting(_ itemID: UUID, beside pane: UUID, after: Bool) -> SplitRecord? {
        guard let index = itemIDs.firstIndex(of: pane) else { return nil }
        return inserting(itemID, at: after ? index + 1 : index)
    }

    /// `itemID` in place of `pane`, at that pane's size.
    public func replacing(_ pane: UUID, with itemID: UUID) -> SplitRecord? {
        guard let index = itemIDs.firstIndex(of: pane), !contains(itemID) else { return nil }
        var record = self
        record.itemIDs[index] = itemID
        return record
    }

    /// `pane` moved after `other`, or before it. nil when that leaves the order as it is.
    public func moving(_ pane: UUID, beside other: UUID, after: Bool) -> SplitRecord? {
        guard pane != other, contains(pane) else { return nil }
        var ids = itemIDs.filter { $0 != pane }
        guard let index = ids.firstIndex(of: other) else { return nil }
        ids.insert(pane, at: after ? index + 1 : index)
        guard ids != itemIDs else { return nil }
        var record = self
        record.itemIDs = ids
        return record
    }

    /// `pane` moved `offset` places: Move Left or Right, or Up or Down when stacked. nil past an end.
    public func moving(_ pane: UUID, by offset: Int) -> SplitRecord? {
        guard let index = itemIDs.firstIndex(of: pane), itemIDs.indices.contains(index + offset), offset != 0 else { return nil }
        return moving(pane, beside: itemIDs[index + offset], after: offset > 0)
    }

    /// Without `pane`. nil once one tab would be left, which ends the split.
    public func removing(_ pane: UUID) -> SplitRecord? {
        guard contains(pane) else { return self }
        return SplitRecord(itemIDs.filter { $0 != pane }, orientation: orientation)
    }

    /// Side by side made stacked, or stacked made side by side.
    public func converted() -> SplitRecord {
        var record = self
        record.orientation = orientation == .horizontal ? .vertical : .horizontal
        return record
    }

    /// Moves divider `index` toward `position`, leaving both panes beside it at least `minimum` of
    /// the page, or as much as they have between them.
    public mutating func moveDivider(_ index: Int, to position: Double, minimum: Double) {
        guard dividers.indices.contains(index) else { return }
        let previous = index == 0 ? 0 : dividers[index - 1]
        let next = index == dividers.count - 1 ? 1 : dividers[index + 1]
        let room = min(minimum, (next - previous) / 2)
        dividers[index] = min(next - room, max(previous + room, position))
    }
}

extension SplitRecord: Codable {
    private enum CodingKeys: String, CodingKey {
        case itemIDs, orientation, dividers
        case leftItemID, rightItemID, fraction
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let ids = try container.decodeIfPresent([UUID].self, forKey: .itemIDs)
            ?? [container.decode(UUID.self, forKey: .leftItemID), container.decode(UUID.self, forKey: .rightItemID)]
        let orientation = try container.decodeIfPresent(Orientation.self, forKey: .orientation) ?? .horizontal
        guard let record = SplitRecord(ids, orientation: orientation) else {
            throw DecodingError.dataCorruptedError(forKey: .itemIDs, in: container, debugDescription: "A split holds 2 to 4 different tabs")
        }
        self = record
        let dividers = try container.decodeIfPresent([Double].self, forKey: .dividers)
            ?? container.decodeIfPresent(Double.self, forKey: .fraction).map { [$0] }
        if let dividers, dividers.count == self.dividers.count,
           zip([0] + dividers, dividers + [1]).allSatisfy({ $0 < $1 }) {
            self.dividers = dividers
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(itemIDs, forKey: .itemIDs)
        try container.encode(orientation, forKey: .orientation)
        try container.encode(dividers, forKey: .dividers)
        // Builds from before more than two panes read only these.
        try container.encode(itemIDs[0], forKey: .leftItemID)
        try container.encode(itemIDs[1], forKey: .rightItemID)
        try container.encode(dividers[0], forKey: .fraction)
    }
}
