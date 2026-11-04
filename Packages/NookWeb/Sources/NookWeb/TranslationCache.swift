// Licensed under GPL-3.0. See LICENSE.
//
//  TranslationCache.swift
//  Nook
//
//  AI page translations kept per profile in an SQLite file, so text a site repeats on every page
//  (menus, buttons, footers) goes to the model once. Entries expire 30 days after last use and the
//  least recently used go first past the store's limits. Private windows have no cache.
//

import CryptoKit
import Foundation
import OSLog
import SQLite3

public actor TranslationCache {
    public struct Limits: Sendable {
        public let maxEntries: Int
        public let maxBytes: Int
        public let lifetime: TimeInterval

        public init(maxEntries: Int = 100_000, maxBytes: Int = 50_000_000, lifetime: TimeInterval = 30 * 86_400) {
            self.maxEntries = maxEntries
            self.maxBytes = maxBytes
            self.lifetime = lifetime
        }
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "TranslationCache")
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public nonisolated let fileURL: URL
    private let limits: Limits
    private let now: @Sendable () -> Date
    private var db: OpaquePointer?
    /// Set when the file cannot be opened; the cache stays off this launch.
    private var unavailable = false

    public init(fileURL: URL, limits: Limits = Limits(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.limits = limits
        self.now = now
    }

    /// SHA-256 of the five parts, each prefixed with its UTF-8 length so no two inputs encode alike.
    public nonisolated static func key(provider: String, model: String, source: String, target: String, text: String) -> String {
        var encoded = Data()
        for part in [provider, model, source, target, text] {
            encoded.append(Data("\(part.utf8.count):".utf8))
            encoded.append(Data(part.utf8))
        }
        return SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Reads and writes

    /// The stored translation for each key that has one, renewing its last use.
    public func translations(for keys: [String]) -> [String: String] {
        guard !keys.isEmpty, let db = open(create: false) else { return [:] }
        let time = now().timeIntervalSince1970
        run(db, "DELETE FROM translations WHERE usedAt < ?") { sqlite3_bind_double($0, 1, time - self.limits.lifetime) }
        var found: [String: String] = [:]
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        for key in Set(keys) {
            run(db, "SELECT translation FROM translations WHERE key = ?", bind: { sqlite3_bind_text($0, 1, key, -1, Self.transient) },
                row: { found[key] = Self.text($0, 0) })
        }
        for key in found.keys {
            run(db, "UPDATE translations SET usedAt = ? WHERE key = ?") { stmt in
                sqlite3_bind_double(stmt, 1, time)
                sqlite3_bind_text(stmt, 2, key, -1, Self.transient)
            }
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        return found
    }

    public func store(_ translations: [String: String]) {
        guard !translations.isEmpty, let db = open(create: true) else { return }
        let time = now().timeIntervalSince1970
        let sql = """
            INSERT INTO translations(key, translation, usedAt, size) VALUES(?, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET translation = excluded.translation, usedAt = excluded.usedAt, size = excluded.size
            """
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        for (key, translation) in translations {
            run(db, sql) { stmt in
                sqlite3_bind_text(stmt, 1, key, -1, Self.transient)
                sqlite3_bind_text(stmt, 2, translation, -1, Self.transient)
                sqlite3_bind_double(stmt, 3, time)
                sqlite3_bind_int64(stmt, 4, Int64(key.utf8.count + translation.utf8.count))
            }
        }
        evict(db, at: time)
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    public func remove(usedBefore cutoff: Date) {
        guard let db = open(create: false) else { return }
        run(db, "DELETE FROM translations WHERE usedAt < ?") { sqlite3_bind_double($0, 1, cutoff.timeIntervalSince1970) }
    }

    /// Closes and removes the file.
    public func erase() {
        if let db { sqlite3_close_v2(db) }
        db = nil
        for suffix in ["", "-journal", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: fileURL.path + suffix))
        }
    }

    /// Expired entries, then the least recently used past either limit.
    private func evict(_ db: OpaquePointer, at time: Double) {
        run(db, "DELETE FROM translations WHERE usedAt < ?") { sqlite3_bind_double($0, 1, time - self.limits.lifetime) }
        run(db, "DELETE FROM translations WHERE key IN (SELECT key FROM translations ORDER BY usedAt DESC, key LIMIT -1 OFFSET ?)") {
            sqlite3_bind_int64($0, 1, Int64(self.limits.maxEntries))
        }
        let sql = """
            DELETE FROM translations WHERE key IN (
                SELECT key FROM (SELECT key, SUM(size) OVER (ORDER BY usedAt DESC, key) AS total FROM translations) WHERE total > ?)
            """
        run(db, sql) { sqlite3_bind_int64($0, 1, Int64(self.limits.maxBytes)) }
    }

    // MARK: - SQLite

    private func open(create: Bool) -> OpaquePointer? {
        if let db { return db }
        guard !unavailable else { return nil }
        let fm = FileManager.default
        if !create, !fm.fileExists(atPath: fileURL.path) { return nil }
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open_v2(fileURL.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            Self.logger.error("Translation cache open failed: \(String(cString: sqlite3_errmsg(handle)), privacy: .public)")
            sqlite3_close_v2(handle)
            unavailable = true
            return nil
        }
        let schema = """
            PRAGMA secure_delete = ON;
            CREATE TABLE IF NOT EXISTS translations(key TEXT PRIMARY KEY, translation TEXT NOT NULL, usedAt REAL NOT NULL, size INTEGER NOT NULL);
            CREATE INDEX IF NOT EXISTS translations_used ON translations(usedAt);
            """
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else {
            Self.logger.error("Translation cache unavailable: \(String(cString: sqlite3_errmsg(handle)), privacy: .public)")
            sqlite3_close_v2(handle)
            unavailable = true
            return nil
        }
        db = handle
        return handle
    }

    private func run(_ db: OpaquePointer, _ sql: String, bind: (OpaquePointer) -> Void) {
        run(db, sql, bind: bind, row: { _ in })
    }

    private func run(_ db: OpaquePointer, _ sql: String, bind: (OpaquePointer) -> Void, row: (OpaquePointer) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            Self.logger.error("Translation cache prepare failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            return
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { row(stmt); continue }
            if rc != SQLITE_DONE {
                Self.logger.error("Translation cache step failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            }
            return
        }
    }

    private static func text(_ stmt: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
    }
}

/// One cache per profile, each in `<profile id>.sqlite` under `directory`.
@MainActor
public final class TranslationCaches {
    public let directory: URL
    private let limits: TranslationCache.Limits
    private let now: @Sendable () -> Date
    private var caches: [UUID: TranslationCache] = [:]

    public init(directory: URL, limits: TranslationCache.Limits = TranslationCache.Limits(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.limits = limits
        self.now = now
    }

    /// Nil for a private window, whose text is never kept.
    public func cache(forProfile id: UUID, isPrivate: Bool) -> TranslationCache? {
        guard !isPrivate else { return nil }
        if let cache = caches[id] { return cache }
        let cache = TranslationCache(fileURL: directory.appendingPathComponent("\(id.uuidString).sqlite"), limits: limits, now: now)
        caches[id] = cache
        return cache
    }

    /// The profile's website data was cleared.
    public func erase(profile id: UUID) async {
        await cache(forProfile: id, isPrivate: false)?.erase()
    }

    /// History was cleared from `cutoff` back, for one profile or, when nil, every profile.
    public func erase(profile id: UUID?, usedBefore cutoff: Date) async {
        for profile in id.map({ [$0] }) ?? storedProfiles() {
            await cache(forProfile: profile, isPrivate: false)?.remove(usedBefore: cutoff)
        }
    }

    /// Every profile's cache, including profiles not opened this launch.
    public func eraseAll() async {
        for profile in storedProfiles() {
            await erase(profile: profile)
        }
    }

    private func storedProfiles() -> [UUID] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let stored = files.filter { $0.pathExtension == "sqlite" }.compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) }
        return Array(Set(stored).union(caches.keys))
    }
}
