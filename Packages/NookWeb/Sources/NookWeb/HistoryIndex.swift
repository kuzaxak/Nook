// Licensed under GPL-3.0. See LICENSE.
//
//  HistoryIndex.swift
//  Nook
//
//  Visited pages in an SQLite FTS5 file beside the history store, one row per URL and profile,
//  ranked by frecency. Kept out of SwiftData so the shared store's schema stays put, and kept
//  past the history store's retention so old pages stay findable from the command palette.
//

import Foundation
import OSLog
import SQLite3

/// A history row as the index holds it.
public struct IndexedVisit: Sendable, Equatable {
    public let url: String
    public let title: String
    public let visitCount: Int
    public let lastVisited: Date
    /// log2 of the decayed visit score plus time over the half-life; higher ranks first.
    public let key: Double
}

/// A history store row copied into the index on its first launch.
public struct HistorySeed: Sendable {
    public let url: String
    public let title: String
    public let profile: UUID?
    public let visitCount: Int
    public let lastVisited: Date

    public init(url: String, title: String, profile: UUID?, visitCount: Int, lastVisited: Date) {
        self.url = url
        self.title = title
        self.profile = profile
        self.visitCount = visitCount
        self.lastVisited = lastVisited
    }
}

/// What the person chose from the palette for a typed prefix.
public struct HistoryPick: Sendable, Equatable {
    public let prefix: String
    public let url: String
    public let n: Int
}

public actor HistoryIndex {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "HistoryIndex")
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let schemaVersion: Int32 = 1
    /// Rows read in key order before a search falls back to the FTS join.
    private static let topScan = 3000
    /// Times count from here, so `t / halfLife` stays a small number.
    nonisolated static let epoch = Date(timeIntervalSince1970: 1_577_836_800)
    /// Characters that split words, besides whitespace: in URLs, in queries and in the FTS table.
    nonisolated public static let separators: Set<Character> = [".", "/", "?", "&", "=", "#", ":", "-", "_"]
    /// Query parameters that carry secrets or tracking, dropped before a URL is stored.
    nonisolated static let secretParameters: Set<String> = ["token", "access_token", "code", "state", "session", "fbclid", "gclid"]

    public let fileURL: URL
    private var halfLife: TimeInterval
    private var db: OpaquePointer?
    /// Set when FTS5 is missing or the file cannot be opened; callers fall back to the history store.
    private var unavailable = false

    public init(fileURL: URL, halfLife: TimeInterval) {
        self.fileURL = fileURL
        self.halfLife = halfLife
    }

    // MARK: - Frecency

    /// A key with `visitCount` visits all at `lastVisited`, for rows copied from the history store.
    nonisolated public static func seedKey(visitCount: Int, lastVisited: Date, halfLife: TimeInterval) -> Double {
        log2(Double(max(visitCount, 1))) + lastVisited.timeIntervalSince(epoch) / halfLife
    }

    /// `key` with one more visit of `weight` at `date`: log2(2^key + weight · 2^(t/H)), computed
    /// as max + log2(1 + 2^(min − max)) so nothing overflows.
    nonisolated public static func addVisit(to key: Double?, weight: Double, at date: Date, halfLife: TimeInterval) -> Double {
        let visit = log2(weight) + date.timeIntervalSince(epoch) / halfLife
        guard let key else { return visit }
        let high = max(key, visit), low = min(key, visit)
        return high + log2(1 + exp2(low - high))
    }

    // MARK: - URLs and Words

    /// `url` without secret or tracking parameters (`token`, `code`, `utm_*`, …).
    nonisolated public static func cleanURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.percentEncodedQueryItems, !items.isEmpty else { return url }
        let kept = items.filter { item in
            let name = item.name.lowercased()
            return !secretParameters.contains(name) && !name.hasPrefix("utm_")
        }
        guard kept.count != items.count else { return url }
        components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return components.url ?? url
    }

    /// Lowercased words of `text`, split on whitespace and `separators`.
    nonisolated public static func tokens(_ text: String) -> [String] {
        text.lowercased().split { $0.isWhitespace || separators.contains($0) }.map(String.init)
    }

    /// Words as the FTS table's unicode61 tokenizer sees them: split on anything but letters
    /// and digits, lowercased, diacritics folded.
    nonisolated static func indexWords(_ text: String) -> [Substring] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
    }

    /// Each word as a quoted prefix term, so no FTS5 operator or quote in the query can reach the parser.
    nonisolated static func matchExpression(for query: String) -> String? {
        let terms = tokens(query)
            .filter { $0.contains { $0.isLetter || $0.isNumber } }
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }
        return terms.isEmpty ? nil : terms.joined(separator: " ")
    }

    // MARK: - Ranking

    /// Orders search results by their key plus log2 of the match multipliers: host starts with
    /// the first word ×4, a title word starts with a query word ×2, open as a tab ×1.5. Each pick
    /// of the row for a prefix of the query, or for a longer query this one starts, adds log2(1 + n).
    nonisolated public static func rank(_ visits: [IndexedVisit], query: String, isOpen: (String) -> Bool, picks: [HistoryPick]) -> [IndexedVisit] {
        let words = tokens(query)
        guard let first = words.first else { return visits }
        let typed = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var picked: [String: Int] = [:]
        for pick in picks where typed.hasPrefix(pick.prefix) || pick.prefix.hasPrefix(typed) {
            picked[pick.url, default: 0] += pick.n
        }
        func score(_ visit: IndexedVisit) -> Double {
            var multiplier = 1.0
            var host = URL(string: visit.url)?.host?.lowercased() ?? ""
            if host.hasPrefix("www.") { host.removeFirst(4) }
            if host.hasPrefix(first) { multiplier *= 4 }
            let titleWords = tokens(visit.title)
            if words.contains(where: { word in titleWords.contains { $0.hasPrefix(word) } }) { multiplier *= 2 }
            if isOpen(visit.url) { multiplier *= 1.5 }
            return visit.key + log2(multiplier) + log2(1 + Double(picked[visit.url] ?? 0))
        }
        return visits.map { ($0, score($0)) }.sorted { $0.1 > $1.1 }.map(\.0)
    }

    // MARK: - Writes

    /// Whether the history store still has to be copied in.
    public func needsMigration() -> Bool {
        guard let db = open(create: true) else { return false }
        return userVersion(db) < Self.schemaVersion
    }

    /// Copies history store rows in, in one transaction, and marks the file migrated. Secrets
    /// are dropped from each URL first, and rows that become the same URL merge their visits.
    public func migrate(_ seeds: [HistorySeed]) {
        guard let db = open(create: true) else { return }
        var merged: [String: HistorySeed] = [:]
        for seed in seeds {
            let url = URL(string: seed.url).map { Self.cleanURL($0).absoluteString } ?? seed.url
            let key = Self.profileKey(seed.profile) + " " + url
            guard let earlier = merged[key] else {
                merged[key] = HistorySeed(url: url, title: seed.title, profile: seed.profile, visitCount: seed.visitCount, lastVisited: seed.lastVisited)
                continue
            }
            let newer = seed.lastVisited > earlier.lastVisited ? seed : earlier
            merged[key] = HistorySeed(url: url, title: newer.title, profile: seed.profile,
                                      visitCount: earlier.visitCount + seed.visitCount, lastVisited: newer.lastVisited)
        }
        let rows = Array(merged.values)
        let sql = """
            INSERT INTO visits(url, profile, title, host, key, visitCount, lastVisited) VALUES(?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(url, profile) DO NOTHING
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        for row in rows {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, row.url, -1, Self.transient)
            sqlite3_bind_text(stmt, 2, Self.profileKey(row.profile), -1, Self.transient)
            sqlite3_bind_text(stmt, 3, row.title, -1, Self.transient)
            sqlite3_bind_text(stmt, 4, URL(string: row.url)?.host ?? "", -1, Self.transient)
            sqlite3_bind_double(stmt, 5, Self.seedKey(visitCount: row.visitCount, lastVisited: row.lastVisited, halfLife: halfLife))
            sqlite3_bind_int64(stmt, 6, Int64(max(row.visitCount, 1)))
            sqlite3_bind_double(stmt, 7, row.lastVisited.timeIntervalSince1970)
            if sqlite3_step(stmt) != SQLITE_DONE {
                Self.logger.error("History index migration row failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            }
        }
        sqlite3_exec(db, "PRAGMA user_version = \(Self.schemaVersion)", nil, nil, nil)
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    /// One visit of `weight` (2 typed or chosen in the palette, 1 a link, 0 a reload, which is
    /// skipped). A visit from a profile claims the URL's untagged row, as the history store does.
    public func record(url: String, title: String, profile: UUID?, at date: Date, weight: Double) {
        guard weight > 0, let db = open(create: true) else { return }
        let profileKey = Self.profileKey(profile)
        var existing: (rowid: Int64, key: Double, lastVisited: Double)?
        for candidate in profile == nil ? [profileKey] : [profileKey, ""] where existing == nil {
            run(db, "SELECT rowid, key, lastVisited FROM visits WHERE url = ? AND profile = ?", bind: { stmt in
                sqlite3_bind_text(stmt, 1, url, -1, Self.transient)
                sqlite3_bind_text(stmt, 2, candidate, -1, Self.transient)
            }, row: { stmt in
                existing = (sqlite3_column_int64(stmt, 0), sqlite3_column_double(stmt, 1), sqlite3_column_double(stmt, 2))
            })
        }
        guard let existing else {
            run(db, "INSERT INTO visits(url, profile, title, host, key, visitCount, lastVisited) VALUES(?, ?, ?, ?, ?, 1, ?)") { stmt in
                sqlite3_bind_text(stmt, 1, url, -1, Self.transient)
                sqlite3_bind_text(stmt, 2, profileKey, -1, Self.transient)
                sqlite3_bind_text(stmt, 3, title, -1, Self.transient)
                sqlite3_bind_text(stmt, 4, URL(string: url)?.host ?? "", -1, Self.transient)
                sqlite3_bind_double(stmt, 5, Self.addVisit(to: nil, weight: weight, at: date, halfLife: halfLife))
                sqlite3_bind_double(stmt, 6, date.timeIntervalSince1970)
            }
            return
        }
        let newer = date.timeIntervalSince1970 >= existing.lastVisited
        let sql = """
            UPDATE visits SET profile = ?, key = ?, visitCount = visitCount + 1,
                lastVisited = max(lastVisited, ?), title = CASE WHEN ? AND ? != '' THEN ? ELSE title END
            WHERE rowid = ?
            """
        run(db, sql) { stmt in
            sqlite3_bind_text(stmt, 1, profileKey, -1, Self.transient)
            sqlite3_bind_double(stmt, 2, Self.addVisit(to: existing.key, weight: weight, at: date, halfLife: self.halfLife))
            sqlite3_bind_double(stmt, 3, date.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 4, newer ? 1 : 0)
            sqlite3_bind_text(stmt, 5, title, -1, Self.transient)
            sqlite3_bind_text(stmt, 6, title, -1, Self.transient)
            sqlite3_bind_int64(stmt, 7, existing.rowid)
        }
    }

    /// Removes `url` for `profile`, or for every profile when nil.
    public func delete(url: String, profile: UUID?) {
        guard let db = open(create: false) else { return }
        run(db, "DELETE FROM visits WHERE url = ?1 AND (?2 IS NULL OR profile = ?2)") { stmt in
            sqlite3_bind_text(stmt, 1, url, -1, Self.transient)
            Self.bindProfile(stmt, 2, profile)
        }
        run(db, "DELETE FROM picks WHERE url = ?1 AND (?2 IS NULL OR profile = ?2)") { stmt in
            sqlite3_bind_text(stmt, 1, url, -1, Self.transient)
            Self.bindProfile(stmt, 2, profile)
        }
    }

    /// Removes rows last visited before `date`: `profile`'s and untagged ones, or all when nil.
    public func clear(before date: Date, profile: UUID?) {
        guard let db = open(create: false) else { return }
        run(db, "DELETE FROM visits WHERE lastVisited < ?1 AND (?2 IS NULL OR profile IN (?2, ''))") { stmt in
            sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
            Self.bindProfile(stmt, 2, profile)
        }
        run(db, "DELETE FROM picks WHERE NOT EXISTS (SELECT 1 FROM visits v WHERE v.url = picks.url)") { _ in }
    }

    /// Remembers that the person chose `url` after typing `prefix`.
    public func recordPick(prefix: String, url: String, profile: UUID?, at date: Date) {
        let prefix = prefix.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty, let db = open(create: true) else { return }
        let sql = """
            INSERT INTO picks(profile, prefix, url, n, lastPicked) VALUES(?, ?, ?, 1, ?)
            ON CONFLICT(profile, prefix, url) DO UPDATE SET n = n + 1, lastPicked = excluded.lastPicked
            """
        run(db, sql) { stmt in
            sqlite3_bind_text(stmt, 1, Self.profileKey(profile), -1, Self.transient)
            sqlite3_bind_text(stmt, 2, prefix, -1, Self.transient)
            sqlite3_bind_text(stmt, 3, url, -1, Self.transient)
            sqlite3_bind_double(stmt, 4, date.timeIntervalSince1970)
        }
    }

    /// New scores use `halfLife`; existing rows are re-seeded from their counts and last visits.
    public func setHalfLife(_ halfLife: TimeInterval) {
        guard halfLife != self.halfLife else { return }
        self.halfLife = halfLife
        guard let db = open(create: false) else { return }
        reseed(db)
    }

    /// Closes and removes the file.
    public func erase() {
        if let db { sqlite3_close_v2(db) }
        db = nil
        for suffix in ["", "-journal", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: fileURL.path + suffix))
        }
    }

    // MARK: - Reads

    /// Rows whose title or URL holds every word of `query` as a prefix, highest key first. Rows of
    /// `profile` and untagged ones, or all when nil. nil when the index is unavailable.
    public func search(_ query: String, profile: UUID?, limit: Int = 60) -> [IndexedVisit]? {
        guard let db = open(create: true) else { return nil }
        guard limit > 0, let match = Self.matchExpression(for: query) else { return [] }
        // One short word matches most rows, and the FTS join then sorts all of them. The best
        // rows by key usually hold enough matches; when they do, those are the answer.
        let words = Self.indexWords(query)
        if words.count == 1 {
            let top = topByKey(db, matching: String(words[0]), profile: profile, limit: limit)
            if top.count >= limit { return top }
        }
        let sql = """
            SELECT v.url, v.title, v.visitCount, v.lastVisited, v.key
            FROM visits_fts JOIN visits v ON v.rowid = visits_fts.rowid
            WHERE visits_fts MATCH ?1 AND (?2 IS NULL OR v.profile IN (?2, ''))
            ORDER BY v.key DESC LIMIT ?3
            """
        var results: [IndexedVisit] = []
        run(db, sql, bind: { stmt in
            sqlite3_bind_text(stmt, 1, match, -1, Self.transient)
            Self.bindProfile(stmt, 2, profile)
            sqlite3_bind_int(stmt, 3, Int32(limit))
        }, row: { stmt in
            results.append(IndexedVisit(
                url: Self.text(stmt, 0), title: Self.text(stmt, 1), visitCount: Int(sqlite3_column_int64(stmt, 2)),
                lastVisited: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)), key: sqlite3_column_double(stmt, 4)))
        })
        return results
    }

    /// Matches for one word among the `topScan` highest keys, checked as the FTS tokenizer would.
    private func topByKey(_ db: OpaquePointer, matching word: String, profile: UUID?, limit: Int) -> [IndexedVisit] {
        let profileKey = profile.map(Self.profileKey)
        var top: [IndexedVisit] = []
        run(db, "SELECT url, title, visitCount, lastVisited, key, profile FROM visits INDEXED BY visits_rank ORDER BY key DESC LIMIT \(Self.topScan)", bind: { _ in }, row: { stmt in
            guard top.count < limit else { return }
            if let profileKey {
                let rowProfile = Self.text(stmt, 5)
                guard rowProfile == profileKey || rowProfile.isEmpty else { return }
            }
            let title = Self.text(stmt, 1), url = Self.text(stmt, 0)
            var haystack = (title + " " + url).lowercased()
            if !haystack.utf8.allSatisfy({ $0 < 128 }) {
                haystack = haystack.folding(options: .diacriticInsensitive, locale: nil)
            }
            guard haystack.contains(word),
                  haystack.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(word) })
            else { return }
            top.append(IndexedVisit(url: url, title: title, visitCount: Int(sqlite3_column_int64(stmt, 2)),
                                    lastVisited: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)), key: sqlite3_column_double(stmt, 4)))
        })
        return top
    }

    /// Every pick `profile` made, untagged ones included.
    public func picks(profile: UUID?) -> [HistoryPick] {
        guard let db = open(create: false) else { return [] }
        var picks: [HistoryPick] = []
        run(db, "SELECT prefix, url, n FROM picks WHERE ?1 IS NULL OR profile IN (?1, '')", bind: { stmt in
            Self.bindProfile(stmt, 1, profile)
        }, row: { stmt in
            picks.append(HistoryPick(prefix: Self.text(stmt, 0), url: Self.text(stmt, 1), n: Int(sqlite3_column_int64(stmt, 2))))
        })
        return picks
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
            Self.logger.error("History index open failed: \(String(cString: sqlite3_errmsg(handle)), privacy: .public)")
            sqlite3_close_v2(handle)
            unavailable = true
            return nil
        }
        // External-content FTS5 over the visits table; the triggers keep the two in step. Only a
        // title or URL change reindexes, so a visit's score update leaves the FTS table alone.
        let schema = """
            PRAGMA journal_mode = WAL;
            PRAGMA secure_delete = ON;
            CREATE TABLE IF NOT EXISTS visits(
                url TEXT NOT NULL, profile TEXT NOT NULL DEFAULT '',
                title TEXT, host TEXT, key REAL NOT NULL, typed INTEGER NOT NULL DEFAULT 0,
                visitCount INTEGER NOT NULL DEFAULT 0, lastVisited REAL NOT NULL,
                PRIMARY KEY(url, profile));
            CREATE INDEX IF NOT EXISTS visits_key ON visits(profile, key DESC);
            CREATE INDEX IF NOT EXISTS visits_rank ON visits(key DESC);
            CREATE VIRTUAL TABLE IF NOT EXISTS visits_fts USING fts5(
                title, url, content='visits', content_rowid='rowid', prefix='1 2 3 4 5 6 7 8',
                tokenize="unicode61 remove_diacritics 2 separators './?&=#:-_'");
            CREATE TRIGGER IF NOT EXISTS visits_ai AFTER INSERT ON visits BEGIN
                INSERT INTO visits_fts(rowid, title, url) VALUES (new.rowid, new.title, new.url);
            END;
            CREATE TRIGGER IF NOT EXISTS visits_ad AFTER DELETE ON visits BEGIN
                INSERT INTO visits_fts(visits_fts, rowid, title, url) VALUES ('delete', old.rowid, old.title, old.url);
            END;
            CREATE TRIGGER IF NOT EXISTS visits_au AFTER UPDATE OF title, url ON visits BEGIN
                INSERT INTO visits_fts(visits_fts, rowid, title, url) VALUES ('delete', old.rowid, old.title, old.url);
                INSERT INTO visits_fts(rowid, title, url) VALUES (new.rowid, new.title, new.url);
            END;
            CREATE TABLE IF NOT EXISTS picks(
                profile TEXT NOT NULL, prefix TEXT NOT NULL, url TEXT NOT NULL,
                n INTEGER NOT NULL, lastPicked REAL NOT NULL,
                PRIMARY KEY(profile, prefix, url));
            CREATE TABLE IF NOT EXISTS meta(name TEXT PRIMARY KEY, value REAL NOT NULL);
            """
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK, let handle else {
            Self.logger.error("History index unavailable (FTS5): \(String(cString: sqlite3_errmsg(handle)), privacy: .public)")
            sqlite3_close_v2(handle)
            unavailable = true
            return nil
        }
        db = handle
        // Keys mean something only under the half-life they were written with.
        var stored: Double?
        run(handle, "SELECT value FROM meta WHERE name = 'halfLife'", bind: { _ in }, row: { stored = sqlite3_column_double($0, 0) })
        if stored != halfLife { reseed(handle) }
        return handle
    }

    private func reseed(_ db: OpaquePointer) {
        var rows: [(Int64, Int64, Double)] = []
        run(db, "SELECT rowid, visitCount, lastVisited FROM visits", bind: { _ in }, row: { stmt in
            rows.append((sqlite3_column_int64(stmt, 0), sqlite3_column_int64(stmt, 1), sqlite3_column_double(stmt, 2)))
        })
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE visits SET key = ? WHERE rowid = ?", -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        for (rowid, count, last) in rows {
            sqlite3_reset(stmt)
            sqlite3_bind_double(stmt, 1, Self.seedKey(visitCount: Int(count), lastVisited: Date(timeIntervalSince1970: last), halfLife: halfLife))
            sqlite3_bind_int64(stmt, 2, rowid)
            sqlite3_step(stmt)
        }
        run(db, "INSERT INTO meta(name, value) VALUES('halfLife', ?) ON CONFLICT(name) DO UPDATE SET value = excluded.value") { stmt in
            sqlite3_bind_double(stmt, 1, self.halfLife)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    private func userVersion(_ db: OpaquePointer) -> Int32 {
        var version: Int32 = 0
        run(db, "PRAGMA user_version", bind: { _ in }, row: { version = sqlite3_column_int($0, 0) })
        return version
    }

    private static func profileKey(_ profile: UUID?) -> String { profile?.uuidString ?? "" }

    private static func bindProfile(_ stmt: OpaquePointer, _ index: Int32, _ profile: UUID?) {
        if let profile {
            sqlite3_bind_text(stmt, index, profile.uuidString, -1, transient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func run(_ db: OpaquePointer, _ sql: String, bind: (OpaquePointer) -> Void) {
        run(db, sql, bind: bind, row: { _ in })
    }

    private func run(_ db: OpaquePointer, _ sql: String, bind: (OpaquePointer) -> Void, row: (OpaquePointer) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            Self.logger.error("History index prepare failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            return
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { row(stmt); continue }
            if rc != SQLITE_DONE {
                Self.logger.error("History index step failed: \(String(cString: sqlite3_errmsg(db)), privacy: .public)")
            }
            return
        }
    }

    private static func text(_ stmt: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
    }
}
