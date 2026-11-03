// Licensed under GPL-3.0. See LICENSE.
import Foundation

/// State that belongs to this Mac only and never syncs.
public struct DeviceState: Codable, Equatable, Sendable {
    public static let closedLimit = 50
    /// Tabs the archive sweep closed, kept apart so a big sweep never pushes out what the person
    /// closed themselves.
    public static let archivedLimit = 200

    public var openFolders: Set<UUID> = []
    /// Live pages of synced tabs (pinned and favorites), by item id.
    public var openPages: [UUID: OpenPage] = [:]
    public var windows: [WindowRecord] = []
    /// Newest last.
    public var closed: [ClosedEntry] = []
    public var firstLaunchCompleted = false
    /// Pages the person removed from a live folder, by folder id, so a refresh leaves them out.
    /// Optional because files written before live folders have no such key.
    public var liveDismissed: [UUID: Set<URL>]?
    /// The tab whose page opened each link tab that is not its child, so Back can return to it.
    /// Optional because files written before opener records have no such key.
    public var openers: [UUID: UUID]?
    /// When each normal tab was last selected or left, for archiving tabs left unseen.
    public var lastSeen: [UUID: Date]?
    /// Newest last. Optional because files written before archiving have no such key.
    public var archived: [ClosedEntry]?

    public init() {}

    public mutating func pushClosed(_ entry: ClosedEntry) {
        closed.append(entry)
        if closed.count > Self.closedLimit { closed.removeFirst(closed.count - Self.closedLimit) }
    }

    public mutating func pushArchived(_ entry: ClosedEntry) {
        var list = archived ?? []
        list.append(entry)
        if list.count > Self.archivedLimit { list.removeFirst(list.count - Self.archivedLimit) }
        archived = list
    }

    /// What Reopen Closed Tab brings back: the newer of the last closed and last archived entry.
    public var newestClosed: ClosedEntry? {
        guard let archivedLast = archived?.last else { return closed.last }
        guard let closedLast = closed.last else { return archivedLast }
        return archivedLast.closedAt > closedLast.closedAt ? archivedLast : closedLast
    }

    public mutating func dropNewestClosed() {
        guard let newest = newestClosed else { return }
        if newest == closed.last { closed.removeLast() } else { archived?.removeLast() }
    }

    /// Drops entries holding any of `ids` from both lists. True when something was dropped.
    @discardableResult
    public mutating func dropClosed(containing ids: Set<UUID>) -> Bool {
        let before = closed.count + (archived?.count ?? 0)
        closed.removeAll { entry in entry.items.contains { ids.contains($0.id) } }
        archived?.removeAll { entry in entry.items.contains { ids.contains($0.id) } }
        return closed.count + (archived?.count ?? 0) != before
    }

    /// Drops references to items and spaces that no longer exist.
    public mutating func prune(against tree: TabTree) {
        openFolders = openFolders.filter { tree.item($0)?.isFolder == true || tree.hasChildren($0) }
        openPages = openPages.filter { tree.item($0.key) != nil && tree.scope(of: $0.key) == .synced }
        liveDismissed = liveDismissed?.filter { tree.item($0.key)?.live != nil }
        openers = openers?.filter { tree.item($0.key) != nil && tree.item($0.value) != nil }
        lastSeen = lastSeen?.filter { tree.item($0.key) != nil }
        for i in windows.indices {
            if let spaceID = windows[i].spaceID, tree.space(spaceID) == nil { windows[i].spaceID = nil }
            windows[i].selectedItemBySpace = windows[i].selectedItemBySpace.filter { tree.space($0.key) != nil && tree.item($0.value) != nil }
            if let split = windows[i].split, tree.item(split.leftItemID) == nil || tree.item(split.rightItemID) == nil {
                windows[i].split = nil
            }
        }
    }
}

public struct OpenPage: Codable, Hashable, Sendable {
    public var url: URL
    public var title: String

    public init(url: URL, title: String) {
        self.url = url
        self.title = title
    }
}

public struct WindowRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var spaceID: UUID?
    public var selectedItemBySpace: [UUID: UUID]
    public var split: SplitRecord?
    /// `NSStringFromRect` of the window frame, restored by the app.
    public var frame: String?

    public init(id: UUID = UUID(), spaceID: UUID? = nil, selectedItemBySpace: [UUID: UUID] = [:], split: SplitRecord? = nil, frame: String? = nil) {
        self.id = id
        self.spaceID = spaceID
        self.selectedItemBySpace = selectedItemBySpace
        self.split = split
        self.frame = frame
    }
}

public struct SplitRecord: Codable, Hashable, Sendable {
    public var leftItemID: UUID
    public var rightItemID: UUID
    public var fraction: Double

    public init(leftItemID: UUID, rightItemID: UUID, fraction: Double) {
        self.leftItemID = leftItemID
        self.rightItemID = rightItemID
        self.fraction = fraction
    }
}
