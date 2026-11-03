// Licensed under GPL-3.0. See LICENSE.
//
//  PeekSlots.swift
//  NookWeb
//
//  Which Peek belongs to which tab in which window. Peek is the tab's, as in Arc: it hides while
//  another tab shows and comes back with its tab. Foundation only, checked by
//  `Checks/PeekSlotsCheck.swift`.
//

import Foundation

public struct PeekSlots<Page> {
    private struct Key: Hashable {
        let tab: UUID
        let window: UUID
    }

    private var pages: [Key: Page] = [:]

    public init() {}

    public var isEmpty: Bool { pages.isEmpty }

    public func page(tab: UUID, window: UUID) -> Page? {
        pages[Key(tab: tab, window: window)]
    }

    /// Returns the Peek it replaced, for the caller to end.
    @discardableResult
    public mutating func open(_ page: Page, tab: UUID, window: UUID) -> Page? {
        pages.updateValue(page, forKey: Key(tab: tab, window: window))
    }

    @discardableResult
    public mutating func close(tab: UUID, window: UUID) -> Page? {
        pages.removeValue(forKey: Key(tab: tab, window: window))
    }

    public mutating func closeAll(tab: UUID) -> [Page] {
        removeAll { $0.tab == tab }
    }

    public mutating func closeAll(window: UUID) -> [Page] {
        removeAll { $0.window == window }
    }

    private mutating func removeAll(where matches: (Key) -> Bool) -> [Page] {
        let keys = pages.keys.filter(matches)
        return keys.compactMap { pages.removeValue(forKey: $0) }
    }
}
