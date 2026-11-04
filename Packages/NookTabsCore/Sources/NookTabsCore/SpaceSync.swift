// Licensed under GPL-3.0. See LICENSE.
//
//  SpaceSync.swift
//  NookTabsCore
//
//  Spaces kept in iCloud: the records a space becomes, how much of a space each Mac sends, and
//  whether this build may sync at all. CloudKit itself lives in the app.
//

import Foundation

/// How much of a space this Mac keeps in iCloud. Off on one Mac stops that Mac sending and
/// receiving the space; it stays in iCloud and on the other Macs.
public enum SpaceSyncLevel: String, Codable, Sendable, CaseIterable {
    case off
    /// Favorites, pinned tabs and their folders.
    case pinned
    /// Also the open tabs, their order and the tabs opened from them.
    case everything

    public func syncs(_ section: SyncSection) -> Bool {
        switch self {
        case .off: return false
        case .pinned: return section != .tabs
        case .everything: return true
        }
    }
}

/// The section an item record sits in.
public enum SyncSection: String, Codable, Sendable {
    case favorites, pinned, tabs

    init?(_ parent: Parent) {
        switch parent {
        case .favorites: self = .favorites
        case .pinned: self = .pinned
        case .tabs: self = .tabs
        case .folder: return nil
        }
    }

    func parent(in spaceID: UUID) -> Parent {
        switch self {
        case .favorites: return .favorites(spaceID: spaceID)
        case .pinned: return .pinned(spaceID: spaceID)
        case .tabs: return .tabs(spaceID: spaceID)
        }
    }
}

public enum SyncValue: Codable, Hashable, Sendable {
    case string(String)
    case int(Int64)
    case bytes(Data)
}

/// A space or an item as iCloud holds it: its field values and when each group of fields last
/// changed.
public struct SyncRecord: Codable, Equatable, Sendable {
    public enum RecordType: String, Codable, Sendable, CaseIterable {
        case space = "Space"
        case item = "Item"
    }

    public enum Key {
        public static let name = "name"
        public static let icon = "icon"
        public static let accent = "accent"
        public static let theme = "theme"
        /// The space's profile name, read only when the space first arrives on a Mac to pick
        /// the profile it joins.
        public static let profile = "profile"
        public static let level = "level"
        public static let order = "order"
        public static let space = "space"
        public static let section = "section"
        /// "tab" or "folder", as in a `.nookspace` file.
        public static let kind = "kind"
        /// The folder an item is in, or the tab that opened it.
        public static let parent = "parent"
        public static let url = "url"
        /// A tab's page title or a folder's name.
        public static let title = "title"
        public static let customTitle = "customTitle"
        /// The name of the Mac that saved the record, for Settings' list of what iCloud holds.
        public static let device = "device"
        /// On a space record in an account's own zone: the CloudKit user record name of the
        /// account whose shared zone a Mac moved the space into.
        public static let movedTo = "movedTo"
    }

    public var type: RecordType
    public var id: UUID
    public var fields: [String: SyncValue]
    /// Milliseconds since 1970, per group in `RecordType.groups`.
    public var times: [String: Int64]

    public init(type: RecordType, id: UUID, fields: [String: SyncValue], times: [String: Int64]) {
        self.type = type
        self.id = id
        self.fields = fields
        self.times = times
    }
}

extension SyncRecord.RecordType {
    private typealias Key = SyncRecord.Key

    /// Fields that change together. Each group has one modification time, and a conflict keeps
    /// the newer group whole.
    public var groups: [String: [String]] {
        switch self {
        case .space:
            return ["name": [Key.name], "icon": [Key.icon], "look": [Key.accent, Key.theme], "level": [Key.level], "order": [Key.order]]
        case .item:
            return ["position": [Key.space, Key.section, Key.parent, Key.order], "kind": [Key.kind], "url": [Key.url],
                    "title": [Key.title], "customTitle": [Key.customTitle]]
        }
    }

    public var keys: [String] {
        groups.values.flatMap { $0 } + (self == .space ? [Key.profile] : []) + [Key.device]
    }

    /// Fields a save sets but never clears, so a Mac that does not know of them, or did not
    /// write them, leaves them as they are.
    public var markerKeys: [String] { self == .space ? [Key.movedTo] : [] }

    /// Fields iCloud encrypts with the person's own keys: names, addresses, titles, looks and
    /// the Mac's name.
    public var encryptedKeys: Set<String> {
        Set(keys).intersection([Key.name, Key.icon, Key.accent, Key.theme, Key.profile, Key.url, Key.title, Key.customTitle, Key.device])
    }
}

extension SyncRecord {
    public func string(_ key: String) -> String? {
        if case .string(let value)? = fields[key] { return value }
        return nil
    }

    public func bytes(_ key: String) -> Data? {
        if case .bytes(let value)? = fields[key] { return value }
        return nil
    }

    public func uuid(_ key: String) -> UUID? { string(key).flatMap(UUID.init(uuidString:)) }

    /// The owner of the shared zone a Mac moved this space into, from its record in the old zone.
    var movedTo: String? { string(Key.movedTo).flatMap { $0.isEmpty ? nil : $0 } }

    var latestTime: Int64 { times.values.max() ?? 0 }

    var section: SyncSection? { string(Key.section).flatMap(SyncSection.init(rawValue:)) }

    /// The level a space record asks for; a record never says Off.
    var level: SpaceSyncLevel {
        guard let level = string(Key.level).flatMap(SpaceSyncLevel.init(rawValue:)), level != .off else { return .pinned }
        return level
    }

    /// Whether every merged field matches, whatever the times.
    func sameValues(as other: SyncRecord) -> Bool {
        type.groups.values.allSatisfy { keys in keys.allSatisfy { fields[$0] == other.fields[$0] } }
    }
}

/// Encodings shared by the records and the app's CloudKit mapping.
public enum SpaceSyncCodec {
    public static func data(_ theme: SpaceTheme) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(theme)) ?? Data()
    }

    public static func theme(_ data: Data) -> SpaceTheme? {
        try? JSONDecoder().decode(SpaceTheme.self, from: data)
    }

    public static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }

    public static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }

    /// The account as Settings and the sync report name it: the end of its CloudKit user record
    /// name, which stays the same for the account on every Mac. CloudKit gives no email address.
    public static func accountID(_ userRecordName: String) -> String {
        String(userRecordName.suffix(6))
    }
}

/// CloudKit refusals Settings words for the person.
public enum SpaceSyncErrorText {
    public static let outdatedSchema = "iCloud hasn't been updated for this version of Nook yet; sync resumes once it is."

    /// Whether CloudKit refused a save because its production schema lacks a record type or field
    /// the save carries, or defines one differently. It answers Invalid Arguments (12), or Server
    /// Rejected Request (15), with a server message that says so.
    public static func isOutdatedSchema(code: Int, message: String) -> Bool {
        guard code == 12 || code == 15 else { return false }
        let text = message.lowercased()
        return ["production schema", "unknown field", "defined to be"].contains { text.contains($0) }
    }
}

/// Whether this Mac can sync, as Settings shows it.
public enum SpaceSyncAvailability: Equatable, Sendable {
    /// An unsigned build, or one signed without the iCloud container. CloudKit is never touched.
    case needsSignedBuild
    /// Nook could not read its tabs this session, so nothing it has may reach iCloud.
    case readOnlyTabs
    case checking
    case noAccount
    case restricted
    /// iCloud did not answer; Nook asks again when the account changes or on Sync Now.
    case unavailable
    case available

    public static let containerID = "iCloud.ee.qdo.nook"
    /// The zone that holds the spaces, in the owner's private database.
    public static let zoneName = "Spaces"

    /// Whether levels can be set: not in an unsigned build, nor while the tabs are read-only.
    public var takesLevels: Bool { self != .needsSignedBuild && self != .readOnlyTabs }

    /// Whether the app's signature grants the container and CloudKit: the values of
    /// `com.apple.developer.icloud-container-identifiers` and `com.apple.developer.icloud-services`.
    public static func isEntitled(containers: [String]?, services: [String]?) -> Bool {
        guard containers?.contains(containerID) == true, let services else { return false }
        return services.contains("CloudKit") || services.contains("*")
    }
}

/// What Settings shows about sync.
public struct SpaceSyncStatus: Equatable, Sendable {
    public var availability: SpaceSyncAvailability
    public var lastSync: Date?
    public var lastError: String?
    public var isSyncing = false
    /// The iCloud account this Mac syncs with, as `SpaceSyncCodec.accountID` gives it.
    public var accountID: String?
    public var mode: SpaceSyncMode = .own
    /// The people this account's zone is shared with, its owner left out.
    public var participants: [SpaceSyncParticipant] = []
    /// The old copies of spaces this Mac moved into the zone it joined.
    public var oldCopies: SpaceSyncLeftBehind?
    /// Zones this account joined on another Mac, which this Mac can join too.
    public var joinOffers: [SpaceSyncOffer] = []

    public init(availability: SpaceSyncAvailability, lastSync: Date? = nil, lastError: String? = nil, isSyncing: Bool = false, accountID: String? = nil) {
        self.availability = availability
        self.lastSync = lastSync
        self.lastError = lastError
        self.isSyncing = isSyncing
        self.accountID = accountID
    }
}
