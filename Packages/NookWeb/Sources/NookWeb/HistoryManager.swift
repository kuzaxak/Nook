// Licensed under GPL-3.0. See LICENSE.
// History persistence stays on its own executor; UI consumers receive value records.
import Foundation
import SwiftData
import Observation
import OSLog

public struct HistoryVisit: Sendable {
    public let url: URL
    public let title: String
    public let timestamp: Date
    public let tabId: UUID?
    public let profileId: UUID?
    /// How much the visit counts toward frecency: 2 typed or chosen in the palette, 1 a link,
    /// 0 a reload.
    public let weight: Double

    public init(url: URL, title: String, timestamp: Date, tabId: UUID?, profileId: UUID?, weight: Double = 1) {
        self.url = HistoryIndex.cleanURL(url)
        self.title = title
        self.timestamp = timestamp
        self.tabId = tabId
        self.profileId = profileId
        self.weight = weight
    }
}

@MainActor
@Observable
public final class HistoryManager {
    @ObservationIgnored private let storeTask: Task<HistoryStore, Never>
    @ObservationIgnored private var pendingWrite: Task<Void, Never>?
    /// Visited pages' text for the command palette. Nil leaves the feature out entirely.
    @ObservationIgnored private let pageText: HistoryTextIndex?
    /// Every visited page ranked by frecency, for the command palette. Nil, or unavailable,
    /// falls back to scanning the history store.
    @ObservationIgnored private let index: HistoryIndex?
    public var currentProfileId: UUID?
    /// Visits older than this are pruned at launch, so "All time" in the history panel means this.
    nonisolated public static let retentionDays = 100

    public init(context: ModelContext, profileId: UUID? = nil, pageTextURL: URL? = nil, indexURL: URL? = nil, halfLifeDays: Int = 10) {
        currentProfileId = profileId
        pageText = pageTextURL.map(HistoryTextIndex.init(fileURL:))
        index = indexURL.map { HistoryIndex(fileURL: $0, halfLife: TimeInterval(halfLifeDays) * 86_400) }
        let container = context.container
        // Construct the model executor off the main actor as well as calling it there.
        storeTask = Task.detached { HistoryStore(modelContainer: container) }
        if let index {
            enqueue { store in
                if await index.needsMigration() { await index.migrate(await store.seeds()) }
            }
        }
        // Every space's rows, not only the launch space's. The index keeps them past this, so
        // old pages stay findable from the palette.
        clear(days: Self.retentionDays, profile: nil, includingIndex: false)
    }

    /// The frecency half-life, 3 to 60 days.
    public func setHalfLife(days: Int) {
        let index = index
        enqueue { _ in await index?.setHalfLife(TimeInterval(days) * 86_400) }
    }

    public func switchProfile(_ profileId: UUID?) { currentProfileId = profileId }

    private func enqueue(_ operation: @escaping @Sendable (HistoryStore) async -> Void) {
        let previous = pendingWrite
        let storeTask = storeTask
        pendingWrite = Task {
            await previous?.value
            await operation(storeTask.value)
        }
    }

    public func addVisit(url: URL, title: String, timestamp: Date = Date(), tabId: UUID?, profileId: UUID? = nil, isEphemeral: Bool = false, weight: Double = 1) {
        guard !isEphemeral else { return }
        importVisits([HistoryVisit(url: url, title: title, timestamp: timestamp, tabId: tabId, profileId: profileId ?? currentProfileId, weight: weight)])
    }

    public func importVisits(_ visits: [HistoryVisit]) {
        let index = index
        enqueue { store in
            await store.addVisits(visits)
            guard let index else { return }
            for visit in visits where visit.url.scheme == "http" || visit.url.scheme == "https" {
                let title = visit.title.isEmpty ? (visit.url.host ?? "") : visit.title
                await index.record(url: visit.url.absoluteString, title: title, profile: visit.profileId, at: visit.timestamp, weight: visit.weight)
            }
        }
    }

    /// Paged by offset, so a caller that deleted rows it already shows asks for exactly the next ones.
    public func getHistory(days: Int = 7, offset: Int = 0, limit: Int = 50) async -> (entries: [HistoryEntry], hasMore: Bool) {
        let profile = currentProfileId
        await pendingWrite?.value
        return await storeTask.value.history(days: days, profile: profile, offset: offset, limit: limit)
    }

    public func searchHistory(query: String) async -> [HistoryEntry] {
        await searchHistory(query: query, offset: 0, limit: 1000).entries
    }

    public func searchHistory(query: String, offset: Int = 0, limit: Int = 50) async -> (entries: [HistoryEntry], hasMore: Bool) {
        let profile = currentProfileId
        await pendingWrite?.value
        guard !Task.isCancelled else { return ([], false) }
        return await storeTask.value.search(query: query, profile: profile, offset: offset, limit: limit)
    }

    /// Bare host for omnibox inline autofill, e.g. `facebo` -> `facebook.com`. Nil when nothing qualifies.
    /// Skips the pending-write await the other reads take: a keystroke-rate query wants speed, and a
    /// host that is one visit stale autofills the same either way.
    public func autofillHost(prefix: String, minVisits: Int = 2) async -> String? {
        let profile = currentProfileId
        guard !Task.isCancelled else { return nil }
        return await storeTask.value.autofillHost(prefix: prefix, profile: profile, minVisits: minVisits)
    }

    public func clearHistory(olderThan days: Int = 0, profileId: UUID? = nil) {
        clear(days: days, profile: profileId ?? currentProfileId, includingIndex: true)
    }

    private func clear(days: Int, profile: UUID?, includingIndex: Bool) {
        let pageText = pageText
        let index = includingIndex ? index : nil
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        enqueue { store in
            await store.clear(before: cutoff, profile: profile)
            await index?.clear(before: cutoff, profile: profile)
            // Page text goes with its history row, whichever space cleared it.
            if let pageText { await pageText.retain(only: await store.allURLs()) }
        }
    }

    /// A profile was deleted: its history goes with its cookies and logins.
    public func deleteHistory(forProfile profile: UUID) {
        let pageText = pageText
        let index = index
        enqueue { store in
            await store.deleteProfile(profile)
            await index?.deleteProfile(profile)
            if let pageText { await pageText.retain(only: await store.allURLs()) }
        }
    }

    public func deleteHistoryEntry(_ entryId: UUID) {
        let pageText = pageText
        let index = index
        enqueue { store in
            guard let row = await store.delete(entryId) else { return }
            await pageText?.delete(url: row.url)
            await index?.delete(url: row.url, profile: row.profile)
        }
    }

    /// Forgets a page this space sees, from the history store and the index alike.
    public func forget(_ url: URL) {
        let pageText = pageText
        let index = index
        let profile = currentProfileId
        let key = url.absoluteString
        enqueue { store in
            await store.delete(url: key, profile: profile)
            await index?.delete(url: key, profile: profile)
            if let pageText, !(await store.allURLs().contains(key)) { await pageText.delete(url: key) }
        }
    }

    // MARK: - Index

    /// Pages matching every word of `query` as a prefix, ranked by frecency, match quality,
    /// open tabs (`isOpen`) and past picks. Nil when the index is unavailable.
    public func searchIndex(query: String, limit: Int, isOpen: @escaping (String) -> Bool) async -> [HistoryEntry]? {
        guard let index else { return nil }
        let profile = currentProfileId
        await pendingWrite?.value
        guard !Task.isCancelled, let rows = await index.search(query, profile: profile) else { return nil }
        let picks = await index.picks(profile: profile)
        return HistoryIndex.rank(rows, query: query, isOpen: isOpen, picks: picks).prefix(limit).map(HistoryEntry.init(indexed:))
    }

    /// Index rows matching `query`, highest key first, before ranking. Nil when the index is unavailable.
    public func indexRows(matching query: String) async -> [IndexedVisit]? {
        guard let index else { return nil }
        let profile = currentProfileId
        return await index.search(query, profile: profile)
    }

    /// Remembers that `url` was chosen in the palette after typing `prefix`.
    public func recordPick(prefix: String, url: URL) {
        guard let index else { return }
        let profile = currentProfileId
        let key = HistoryIndex.cleanURL(url).absoluteString
        let date = Date()
        enqueue { _ in await index.recordPick(prefix: prefix, url: key, profile: profile, at: date) }
    }

    // MARK: - Page Text

    /// Queued behind history writes, so a Clear issued after a capture also removes it.
    public func recordPageText(url: URL, title: String, body: String) {
        guard let pageText, url.scheme == "http" || url.scheme == "https" else { return }
        let key = HistoryIndex.cleanURL(url).absoluteString, date = Date()
        enqueue { _ in await pageText.record(url: key, title: title, body: body, visitedAt: date) }
    }

    /// History rows whose page text matches every word of `query`, best match first.
    public func searchPageText(query: String, limit: Int) async -> [HistoryEntry] {
        guard let pageText else { return [] }
        let profile = currentProfileId
        let urls = await pageText.search(query, limit: limit * 3).map(\.url)
        guard !Task.isCancelled, !urls.isEmpty else { return [] }
        // Through the history store, so only rows this space can see come back.
        return Array(await storeTask.value.entries(forURLs: urls, profile: profile).prefix(limit))
    }

    public func erasePageText() {
        let pageText = pageText
        enqueue { _ in await pageText?.erase() }
    }
}

@ModelActor
actor HistoryStore {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "History")
    /// Past this age the autofill index is rebuilt, whatever it holds.
    private static let indexMaxAge: TimeInterval = 300

    private struct AutofillIndex {
        let profile: UUID?
        let built: Date
        var hosts: [String: HostStat]

        /// Folds a visit in, when this index covers that profile. The test mirrors what
        /// `visible(to:)` selects: an all-profiles index covers every visit, and a per-profile
        /// index also covers the profile-less rows it would have fetched.
        mutating func record(url: String, profile visitProfile: UUID?, at date: Date) {
            guard profile == nil || visitProfile == nil || profile == visitProfile else { return }
            AutofillRanking.add(url: url, visits: 1, at: date, to: &hosts)
        }
    }

    private var autofillCache: AutofillIndex?

    private func visible(to profile: UUID?) -> Predicate<HistoryEntity> {
        guard let profile else { return #Predicate { _ in true } }
        return #Predicate { $0.profileId == profile || $0.profileId == nil }
    }

    private func exactURL(_ url: String, profile: UUID?) throws -> HistoryEntity? {
        var descriptor = FetchDescriptor<HistoryEntity>(predicate: #Predicate { $0.url == url && $0.profileId == profile })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    func addVisits(_ visits: [HistoryVisit]) {
        let interval = BrowserPerformance.signposter.beginInterval("HistoryWrite")
        defer { BrowserPerformance.signposter.endInterval("HistoryWrite", interval) }
        modelContext.autosaveEnabled = false
        do {
            for (index, visit) in visits.enumerated() {
                guard visit.url.scheme == "http" || visit.url.scheme == "https" else { continue }
                let url = visit.url.absoluteString
                let existing = try exactURL(url, profile: visit.profileId)
                    ?? (visit.profileId == nil ? nil : exactURL(url, profile: nil))
                if let entry = existing {
                    entry.visitCount += 1
                    // An import of older history must not move a recent visit backwards.
                    if visit.timestamp >= entry.lastVisited {
                        entry.lastVisited = visit.timestamp
                        if !visit.title.isEmpty { entry.title = visit.title }
                        entry.tabId = visit.tabId
                    }
                    if entry.profileId == nil, visit.profileId != nil {
                        entry.profileId = visit.profileId
                        // The row leaves every other profile's `visible(to:)` here, so an index
                        // built for one of those is still counting a row it can no longer see.
                        autofillCache = nil
                    }
                } else {
                    modelContext.insert(HistoryEntity(url: url, title: visit.title.isEmpty ? (visit.url.host ?? "Unknown") : visit.title,
                        visitDate: visit.timestamp, tabId: visit.tabId, lastVisited: visit.timestamp, profileId: visit.profileId))
                }
                autofillCache?.record(url: url, profile: visit.profileId, at: visit.timestamp)
                // Bound each transaction while avoiding a disk save for every imported row.
                if (index + 1).isMultiple(of: 500) { try modelContext.save() }
            }
            try modelContext.save()
        } catch {
            modelContext.rollback()
            autofillCache = nil
            Self.logger.error("History write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func history(days: Int, profile: UUID?, offset: Int, limit: Int) -> (entries: [HistoryEntry], hasMore: Bool) {
        guard offset >= 0, limit > 0 else { return ([], false) }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let predicate: Predicate<HistoryEntity>
        if let profile {
            predicate = #Predicate { $0.lastVisited >= cutoff && ($0.profileId == profile || $0.profileId == nil) }
        } else {
            predicate = #Predicate { $0.lastVisited >= cutoff }
        }
        var descriptor = FetchDescriptor<HistoryEntity>(predicate: predicate, sortBy: [SortDescriptor(\.lastVisited, order: .reverse)])
        descriptor.fetchOffset = offset
        descriptor.fetchLimit = limit + 1
        let entries = (try? modelContext.fetch(descriptor)) ?? []
        return (entries.prefix(limit).map(HistoryEntry.init), entries.count > limit)
    }

    func search(query: String, profile: UUID?, offset: Int, limit: Int) -> (entries: [HistoryEntry], hasMore: Bool) {
        if query.isEmpty { return history(days: 7, profile: profile, offset: offset, limit: limit) }
        let interval = BrowserPerformance.signposter.beginInterval("HistorySearch")
        defer { BrowserPerformance.signposter.endInterval("HistorySearch", interval) }
        guard offset >= 0, limit > 0 else { return ([], false) }
        // Keep Foundation's localized matching semantics. Scan bounded chunks off-main,
        // stopping once this page plus its lookahead is satisfied.
        let start = offset
        let pageSize = limit
        // Every word has to appear, in the title or the URL, in any order.
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        var matches: [HistoryEntry] = []
        var descriptor = FetchDescriptor<HistoryEntity>(predicate: visible(to: profile), sortBy: [SortDescriptor(\.lastVisited, order: .reverse)])
        descriptor.fetchLimit = 128
        do {
            for offset in stride(from: 0, to: 5000, by: 128) {
                guard !Task.isCancelled else { return ([], false) }
                descriptor.fetchOffset = offset
                descriptor.fetchLimit = min(128, 5000 - offset)
                let entries = try modelContext.fetch(descriptor)
                for entry in entries where words.allSatisfy({ entry.title.localizedCaseInsensitiveContains($0) || entry.url.localizedCaseInsensitiveContains($0) }) {
                    matches.append(HistoryEntry(from: entry))
                    if matches.count > start + pageSize {
                        return (Array(matches.dropFirst(start).prefix(pageSize)), true)
                    }
                }
                if entries.count < descriptor.fetchLimit! { break }
            }
        } catch { Self.logger.error("History search failed: \(error.localizedDescription, privacy: .public)") }
        return (Array(matches.dropFirst(start).prefix(pageSize)), false)
    }

    /// Highest-ranked host whose name, minus `www.`, starts with `prefix`. Ranked by total visits
    /// across the whole host, then recency, so a popular origin beats a deep page visited once.
    /// Reads the cached index, so a keystroke costs a prefix scan over hosts rather than a fetch.
    func autofillHost(prefix: String, profile: UUID?, minVisits: Int) -> String? {
        guard AutofillRanking.isUsable(prefix: prefix) else { return nil }
        return AutofillRanking.bestHost(in: autofillIndex(for: profile), prefix: prefix, minVisits: minVisits)
    }

    /// Host index for `profile`, built on first use. `addVisits` folds new visits in rather than
    /// dropping it, and the age check bounds how long a delete made elsewhere can leave it wrong.
    private func autofillIndex(for profile: UUID?) -> [String: HostStat] {
        if let cache = autofillCache, cache.profile == profile,
           Date().timeIntervalSince(cache.built) < Self.indexMaxAge {
            return cache.hosts
        }
        let interval = BrowserPerformance.signposter.beginInterval("HistoryAutofillIndex")
        defer { BrowserPerformance.signposter.endInterval("HistoryAutofillIndex", interval) }
        // ponytail: one fetch of the 10k most-visited rows; page it if a history that size shows up.
        var descriptor = FetchDescriptor<HistoryEntity>(
            predicate: visible(to: profile),
            sortBy: [SortDescriptor(\.visitCount, order: .reverse), SortDescriptor(\.lastVisited, order: .reverse)]
        )
        descriptor.fetchLimit = 10_000
        let entries: [HistoryEntity]
        do {
            entries = try modelContext.fetch(descriptor)
        } catch {
            // Caching this as an empty index would suppress autofill until it aged out. Offer
            // nothing for this keystroke and let the next one retry the fetch.
            Self.logger.error("Autofill index build failed: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
        let hosts = AutofillRanking.aggregate(entries.map { ($0.url, $0.visitCount, $0.lastVisited) })
        autofillCache = AutofillIndex(profile: profile, built: Date(), hosts: hosts)
        return hosts
    }

    func clear(before cutoff: Date, profile: UUID?) {
        do {
            if let profile {
                // Same rows `visible(to:)` shows: untagged legacy rows appear in every space,
                // so clearing one space has to take them too.
                try modelContext.delete(model: HistoryEntity.self, where: #Predicate { $0.lastVisited < cutoff && ($0.profileId == profile || $0.profileId == nil) })
            } else {
                try modelContext.delete(model: HistoryEntity.self, where: #Predicate { $0.lastVisited < cutoff })
            }
            try modelContext.save()
            autofillCache = nil
        } catch { Self.logger.error("History clear failed: \(error.localizedDescription, privacy: .public)") }
    }

    /// Deletes one row and returns its URL and profile.
    @discardableResult
    func delete(_ id: UUID) -> (url: String, profile: UUID?)? {
        do {
            var descriptor = FetchDescriptor<HistoryEntity>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            let row = try modelContext.fetch(descriptor).first.map { ($0.url, $0.profileId) }
            try modelContext.delete(model: HistoryEntity.self, where: #Predicate { $0.id == id })
            try modelContext.save()
            autofillCache = nil
            return row.map { (url: $0.0, profile: $0.1) }
        } catch {
            Self.logger.error("History deletion failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Deletes the rows a deleted profile recorded; untagged rows, which every profile sees, stay.
    func deleteProfile(_ profile: UUID) {
        do {
            try modelContext.delete(model: HistoryEntity.self, where: #Predicate { $0.profileId == profile })
            try modelContext.save()
            autofillCache = nil
        } catch {
            Self.logger.error("History deletion failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Deletes the rows for `url` that `profile` sees.
    func delete(url: String, profile: UUID?) {
        do {
            if let profile {
                try modelContext.delete(model: HistoryEntity.self, where: #Predicate { $0.url == url && ($0.profileId == profile || $0.profileId == nil) })
            } else {
                try modelContext.delete(model: HistoryEntity.self, where: #Predicate { $0.url == url })
            }
            try modelContext.save()
            autofillCache = nil
        } catch {
            Self.logger.error("History deletion failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Every row, for the index's first launch.
    func seeds() -> [HistorySeed] {
        let rows = (try? modelContext.fetch(FetchDescriptor<HistoryEntity>())) ?? []
        return rows.map { HistorySeed(url: $0.url, title: $0.title, profile: $0.profileId, visitCount: $0.visitCount, lastVisited: $0.lastVisited) }
    }

    /// Every URL still in history, across spaces.
    func allURLs() -> Set<String> {
        var descriptor = FetchDescriptor<HistoryEntity>()
        descriptor.propertiesToFetch = [\.url]
        return Set(((try? modelContext.fetch(descriptor)) ?? []).map(\.url))
    }

    /// The rows `profile` sees for `urls`, in the order given, one per URL.
    func entries(forURLs urls: [String], profile: UUID?) -> [HistoryEntry] {
        let predicate: Predicate<HistoryEntity>
        if let profile {
            predicate = #Predicate { urls.contains($0.url) && ($0.profileId == profile || $0.profileId == nil) }
        } else {
            predicate = #Predicate { urls.contains($0.url) }
        }
        let rows = (try? modelContext.fetch(FetchDescriptor(predicate: predicate))) ?? []
        let byURL = Dictionary(rows.map { ($0.url, $0) }, uniquingKeysWith: { $0.lastVisited >= $1.lastVisited ? $0 : $1 })
        return urls.compactMap { byURL[$0].map(HistoryEntry.init) }
    }
}

// MARK: - HistoryEntry Model

public struct HistoryEntry: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let url: URL
    public let title: String
    public let visitDate: Date
    public let tabId: UUID?
    public let visitCount: Int
    public let lastVisited: Date

    /// A row from the history index, which may be older than the history store keeps.
    public init(indexed visit: IndexedVisit) {
        self.id = UUID()
        self.url = URL(string: visit.url) ?? URL(string: "https://www.google.com")!
        self.title = visit.title
        self.visitDate = visit.lastVisited
        self.tabId = nil
        self.visitCount = visit.visitCount
        self.lastVisited = visit.lastVisited
    }

    public init(from entity: HistoryEntity) {
        self.id = entity.id
        self.url = URL(string: entity.url) ?? URL(string: "https://www.google.com")!
        self.title = entity.title
        self.visitDate = entity.visitDate
        self.tabId = entity.tabId
        self.visitCount = entity.visitCount
        self.lastVisited = entity.lastVisited
    }
    
    public var displayTitle: String {
        return title.isEmpty ? (url.host ?? "Unknown") : title
    }
    
    public var displayURL: String {
        return url.absoluteString
    }
}
