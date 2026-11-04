// Licensed under GPL-3.0. See LICENSE.
//
//  SpaceFile.swift
//  NookTabsCore
//
//  A space saved to a `.nookspace` file: its name, look, the favorites it shows, its pinned
//  section and its open tabs. Never logins, cookies, history, site data, Boosts or Air Traffic
//  Control rules.
//

import Foundation

public struct SpaceFile: Codable, Equatable, Sendable {
    public static let format = "nook.space"
    public static let currentVersion = 1
    public static let fileExtension = "nookspace"
    public static let typeIdentifier = "ee.qdo.nook.space"
    public static let maxBytes = 5 * 1024 * 1024
    /// Tabs and folders in all three sections together.
    public static let maxItems = 10_000
    /// Objects and arrays inside one another. A file Nook writes needs about 16.
    static let maxNesting = 32

    public var format: String
    public var version: Int
    public var exportedAt: Date
    public var appVersion: String
    public var space: SpaceSnapshot

    public init(space: SpaceSnapshot, appVersion: String, exportedAt: Date = Date()) {
        self.format = Self.format
        self.version = Self.currentVersion
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.space = space
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Just enough of a file to tell what it is before reading the rest.
    private struct Header: Decodable {
        var format: String?
        var version: Int?
    }

    /// Reads a file, refusing it whole when it is too big, not a space file, from a newer
    /// version, damaged, or holding more or deeper items than Nook keeps.
    public static func decode(_ data: Data) throws -> SpaceFile {
        guard data.count <= maxBytes else { throw SpaceFileError.tooLarge }
        // JSONDecoder recurses once per level and overflows the stack well inside its own depth limit.
        guard nesting(of: data, upTo: maxNesting) <= maxNesting else { throw SpaceFileError.tooDeep }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let header = try? decoder.decode(Header.self, from: data) else { throw SpaceFileError.unreadable }
        guard header.format == format else { throw SpaceFileError.wrongFormat }
        guard let version = header.version, version >= 1 else { throw SpaceFileError.unreadable }
        guard version <= currentVersion else { throw SpaceFileError.newerVersion(version) }
        guard let file = try? decoder.decode(SpaceFile.self, from: data) else { throw SpaceFileError.unreadable }
        let sections = [file.space.favorites, file.space.pinned, file.space.tabs]
        guard sections.reduce(0, { $0 + SpaceSnapshot.Entry.count($1) }) <= maxItems else { throw SpaceFileError.tooManyItems }
        guard sections.allSatisfy({ SpaceSnapshot.Entry.height($0) <= TabTree.maxFolderDepth }) else { throw SpaceFileError.tooDeep }
        return file
    }

    /// How deep objects and arrays nest in JSON text, counted up to one past `limit`.
    static func nesting(of data: Data, upTo limit: Int) -> Int {
        var depth = 0, deepest = 0
        var inString = false, escaped = false
        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                inString = true
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                depth += 1
                deepest = max(deepest, depth)
                if deepest > limit { return deepest }
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
            default:
                break
            }
        }
        return deepest
    }
}

public enum SpaceFileError: Error, Equatable, Sendable {
    case tooLarge
    case unreadable
    case wrongFormat
    case newerVersion(Int)
    case tooManyItems
    case tooDeep
}

/// A space as a tree. Every record keeps its id so a later sync can match it; an import makes
/// new ids.
public struct SpaceSnapshot: Codable, Equatable, Sendable {
    public static let defaultAccentHex = "#7C7C7C"

    public var id: UUID
    public var name: String
    public var icon: String
    public var accentHex: String
    public var theme: SpaceTheme?
    /// The favorites the space shows, which its whole profile shares.
    public var favorites: [Entry]
    public var pinned: [Entry]
    public var tabs: [Entry]

    public struct Entry: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case tab, folder }

        public var id: UUID
        public var kind: Kind
        /// A tab's address as written in the file; only web addresses are imported.
        public var url: String?
        /// A tab's page title or a folder's name.
        public var title: String
        public var customTitle: String?
        /// A folder's contents, or the tabs a tab opened (its trail).
        public var children: [Entry]

        static func count(_ entries: [Entry]) -> Int {
            entries.reduce(0) { $0 + 1 + count($1.children) }
        }

        /// Folder levels on the deepest path, counted as `TabTree.nestingHeight` counts them.
        static func height(_ entries: [Entry]) -> Int {
            entries.map { entry in
                entry.kind == .folder || !entry.children.isEmpty ? 1 + height(entry.children) : 0
            }.max() ?? 0
        }
    }
}

/// What an import made and what it left out.
public struct SpaceImportReport: Equatable, Sendable {
    public var spaceID: UUID
    /// The space's name, numbered when the file's name was taken.
    public var name: String
    /// Pinned and open tabs.
    public var tabs = 0
    public var folders = 0
    public var favorites = 0
    /// Favorites whose URL the profile already had.
    public var duplicateFavorites = 0
    /// Tabs and favorites whose link was not an http or https address.
    public var unsafeLinks = 0
}

extension TabTree {
    /// The space as a file holds it; nil for a missing space or the Agent space.
    public func spaceSnapshot(_ spaceID: UUID) -> SpaceSnapshot? {
        guard let space = space(spaceID), !space.isAgent else { return nil }
        let groups = childrenByParent()
        func entries(_ items: [Item]) -> [SpaceSnapshot.Entry] {
            items.map { item in
                SpaceSnapshot.Entry(
                    id: item.id, kind: item.isFolder ? .folder : .tab, url: item.url?.absoluteString,
                    title: item.isFolder ? item.displayTitle : item.pageTitle ?? "",
                    customTitle: item.isFolder ? nil : item.customTitle,
                    children: entries(groups[.folder(itemID: item.id)] ?? []))
            }
        }
        return SpaceSnapshot(
            id: space.id, name: space.name, icon: space.icon, accentHex: space.accentHex, theme: space.theme,
            favorites: entries(favorites(of: spaceID)),
            pinned: entries(groups[.pinned(spaceID: spaceID)] ?? []),
            tabs: entries(groups[.tabs(spaceID: spaceID)] ?? []))
    }

    /// Adds the snapshot as a new last space in the profile whose store is `storeID`, with new
    /// ids. Links that are not web addresses are dropped, and favorites the profile already has
    /// are not added again. Something Nook cannot hold where the file puts it (a folder in
    /// favorites, tabs under a pinned tab, a tab whose link was dropped) gives its contents its
    /// place.
    @discardableResult
    public mutating func importSpace(_ snapshot: SpaceSnapshot, intoProfile storeID: UUID, now: Date = Date()) throws -> (change: Change, report: SpaceImportReport) {
        guard profiles.contains(where: { $0.id == storeID }) else { throw TreeError.missingSpace }
        let spaceID = UUID()
        let name = unusedSpaceName(snapshot.name)
        let icon = SpaceRecord.isAgentIcon(snapshot.icon) ? "" : snapshot.icon
        let accent = ThemeRGB(hex: snapshot.accentHex)?.hex ?? SpaceSnapshot.defaultAccentHex
        var change = createSpace(id: spaceID, name: name, icon: icon, accentHex: accent,
                                 after: orderedSpaces.last?.id, dataStoreID: storeID, now: now)
        if let theme = snapshot.theme { change.merge(try setTheme(spaceID, theme: theme, now: now)) }
        var report = SpaceImportReport(spaceID: spaceID, name: name)
        var favoriteURLs = Set(favorites(of: spaceID).compactMap(\.url))

        /// Adds `entries` under `parent` after `after`, in order, and returns the last one added.
        @discardableResult
        func add(_ entries: [SpaceSnapshot.Entry], to parent: Parent, after: UUID?) -> UUID? {
            var last = after
            for entry in entries {
                let id = UUID()
                switch entry.kind {
                case .folder:
                    guard let made = try? createFolder(id: id, title: entry.title, in: parent, after: last, now: now) else {
                        last = add(entry.children, to: parent, after: last)
                        continue
                    }
                    change.merge(made)
                    report.folders += 1
                    last = id
                    add(entry.children, to: .folder(itemID: id), after: nil)
                case .tab:
                    guard let url = entry.url.flatMap(Self.webURL) else {
                        report.unsafeLinks += 1
                        last = add(entry.children, to: parent, after: last)
                        continue
                    }
                    let isFavorite = parent == .favorites(spaceID: spaceID)
                    if isFavorite, !favoriteURLs.insert(url).inserted {
                        report.duplicateFavorites += 1
                        continue
                    }
                    guard let made = try? createTab(id: id, url: url, title: entry.title, in: parent, after: last, now: now) else { continue }
                    change.merge(made)
                    if isFavorite { report.favorites += 1 } else { report.tabs += 1 }
                    last = id
                    if let custom = entry.customTitle, let renamed = try? rename(id, customTitle: custom, now: now) {
                        change.merge(renamed)
                    }
                    if entry.children.isEmpty { continue }
                    if canTakeChild(id) {
                        add(entry.children, to: .folder(itemID: id), after: nil)
                    } else {
                        last = add(entry.children, to: parent, after: last)
                    }
                }
            }
            return last
        }

        add(snapshot.favorites, to: .favorites(spaceID: spaceID), after: nil)
        add(snapshot.pinned, to: .pinned(spaceID: spaceID), after: nil)
        add(snapshot.tabs, to: .tabs(spaceID: spaceID), after: nil)
        return (change, report)
    }

    /// `wanted`, or with the first free number after it when a space already has that name.
    func unusedSpaceName(_ wanted: String) -> String {
        let trimmed = wanted.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "New Space" : trimmed
        let taken = Set(orderedSpaces.map { $0.name.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }

    /// An http or https address with a host; nil for any other scheme.
    static func webURL(_ string: String) -> URL? {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}
