// Licensed under GPL-3.0. See LICENSE.
//
//  HistoryIndexCheck.swift
//  Nook
//
//  History index check. NookWeb has no test target, so this compiles the shipped source directly:
//
//    swiftc -O -parse-as-library Packages/NookWeb/Sources/NookWeb/HistoryIndex.swift \
//           Packages/NookWeb/Checks/HistoryIndexCheck.swift -o /tmp/history-index-check && /tmp/history-index-check
//

import Foundation

@main
struct HistoryIndexCheck {
    static let day: TimeInterval = 86_400

    static func main() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let halfLife = 10 * day
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let work = UUID(), home = UUID()

        // Frecency: one visit now outranks two visits a half-life ago plus a bit; the update is a log-sum-exp.
        let fresh = HistoryIndex.addVisit(to: nil, weight: 1, at: now, halfLife: halfLife)
        let twiceOld = HistoryIndex.addVisit(to: HistoryIndex.addVisit(to: nil, weight: 1, at: now.addingTimeInterval(-halfLife - day), halfLife: halfLife),
                                             weight: 1, at: now.addingTimeInterval(-halfLife - day), halfLife: halfLife)
        precondition(fresh > twiceOld, "decayed visits rank below a fresh one")
        let twiceOldExact = HistoryIndex.addVisit(to: nil, weight: 2, at: now.addingTimeInterval(-halfLife - day), halfLife: halfLife)
        precondition(abs(twiceOld - twiceOldExact) < 1e-9, "two visits at once weigh the same as one of weight 2")
        let typed = HistoryIndex.addVisit(to: nil, weight: 2, at: now, halfLife: halfLife)
        precondition(abs(typed - fresh - 1) < 1e-9, "a typed visit counts double")
        precondition(abs(HistoryIndex.seedKey(visitCount: 4, lastVisited: now, halfLife: halfLife) - (fresh + 2)) < 1e-9)

        // Secrets never reach the index; other parameters stay in order.
        let cleaned = HistoryIndex.cleanURL(URL(string: "https://kagi.com/search?token=abc&q=swift&utm_source=x&gclid=1&page=2#top")!)
        precondition(cleaned.absoluteString == "https://kagi.com/search?q=swift&page=2#top", cleaned.absoluteString)
        precondition(HistoryIndex.cleanURL(URL(string: "https://a.example/cb?code=1&state=2")!).absoluteString == "https://a.example/cb")
        precondition(HistoryIndex.cleanURL(URL(string: "https://a.example/p")!).absoluteString == "https://a.example/p")
        precondition(HistoryIndex.cleanURL(URL(string: "https://kagi.com/search?q=c%2B%2B&utm_x=1")!).absoluteString == "https://kagi.com/search?q=c%2B%2B")

        // Tokens split on the URL separators, as the FTS table does.
        precondition(HistoryIndex.tokens("github.com/glia/infra-k8s  Foo_bar") == ["github", "com", "glia", "infra", "k8s", "foo", "bar"])

        let index = HistoryIndex(fileURL: dir.appendingPathComponent("History/history-index.sqlite"), halfLife: halfLife)

        // Migration seeds every row once, a year-old page included.
        do { let ok = await index.needsMigration(); precondition(ok) }
        await index.migrate([
            HistorySeed(url: "https://old.example/annual-report", title: "Annual report", profile: work, visitCount: 1, lastVisited: now.addingTimeInterval(-365 * day)),
            HistorySeed(url: "https://github.com/glia/infra", title: "glia/infra", profile: work, visitCount: 3, lastVisited: now.addingTimeInterval(-2 * day)),
            HistorySeed(url: "https://github.com/glia/infra-k8s", title: "infra-k8s", profile: work, visitCount: 30, lastVisited: now.addingTimeInterval(-60 * day)),
            HistorySeed(url: "https://legacy.example/infra", title: "Legacy infra", profile: nil, visitCount: 1, lastVisited: now.addingTimeInterval(-3 * day)),
            HistorySeed(url: "https://github.com/home/infra", title: "home infra", profile: home, visitCount: 50, lastVisited: now),
        ])
        do { let ok = await !index.needsMigration(); precondition(ok) }
        do { let ok = await index.search("annual", profile: work)?.map(\.url) == ["https://old.example/annual-report"]; precondition(ok, "year-old page found") }

        // Decay: two recent visits beat thirty visits two months ago. Legacy untagged rows show in
        // every space; another profile's rows never do.
        let infra = await index.search("infra", profile: work)!.map(\.url)
        precondition(infra == ["https://github.com/glia/infra", "https://legacy.example/infra", "https://github.com/glia/infra-k8s"], "\(infra)")
        do { let ok = await index.search("git inf", profile: home)!.map(\.url) == ["https://github.com/home/infra"]; precondition(ok) }

        // A visit updates the score; a reload (weight 0) does not.
        await index.record(url: "https://github.com/glia/infra-k8s", title: "infra-k8s", profile: work, at: now, weight: 2)
        await index.record(url: "https://github.com/glia/infra-k8s", title: "infra-k8s", profile: work, at: now, weight: 2)
        do { let ok = await index.search("infra", profile: work)!.first?.url == "https://github.com/glia/infra-k8s"; precondition(ok) }
        let before = await index.search("annual", profile: work)!.first!
        await index.record(url: "https://old.example/annual-report", title: "Annual report", profile: work, at: now, weight: 0)
        do { let ok = await index.search("annual", profile: work)!.first! == before; precondition(ok, "a reload leaves the row alone") }

        // A visit from a space claims an untagged row, as the history store does.
        await index.record(url: "https://legacy.example/infra", title: "Legacy infra", profile: work, at: now, weight: 1)
        do { let ok = await index.search("legacy", profile: home)!.isEmpty; precondition(ok) }
        do { let ok = await index.search("legacy", profile: work)!.first?.visitCount == 2; precondition(ok) }

        // Ranking: host prefix, title word, open tab and picks multiply the stored score.
        let rows = await index.search("git", profile: work)!
        let ranked = HistoryIndex.rank(rows, query: "git", isOpen: { _ in false }, picks: [])
        precondition(ranked.first?.url == "https://github.com/glia/infra-k8s")
        await index.recordPick(prefix: "gi", url: "https://github.com/glia/infra", profile: work, at: now)
        for _ in 0..<40 { await index.recordPick(prefix: "git", url: "https://github.com/glia/infra", profile: work, at: now) }
        let picks = await index.picks(profile: work)
        precondition(picks.contains { $0.prefix == "git" && $0.n == 40 })
        let picked = HistoryIndex.rank(rows, query: "git", isOpen: { _ in false }, picks: picks)
        precondition(picked.first?.url == "https://github.com/glia/infra", "picks lift a row")
        do { let ok = await index.picks(profile: home).isEmpty; precondition(ok) }

        // Deletion: one profile's row, a time range, and everything.
        await index.delete(url: "https://github.com/glia/infra", profile: work)
        do { let ok = await index.search("glia infra", profile: work)!.map(\.url) == ["https://github.com/glia/infra-k8s"]; precondition(ok) }
        await index.clear(before: now.addingTimeInterval(-day), profile: work)
        do { let ok = await index.search("annual", profile: work)!.isEmpty; precondition(ok) }
        do { let ok = await index.search("infra", profile: home)!.count == 1; precondition(ok, "another space's rows survive its neighbour's clear") }
        await index.clear(before: now.addingTimeInterval(1), profile: nil)
        do { let ok = await index.search("infra", profile: home)!.isEmpty; precondition(ok) }

        // Migrated rows lose their secrets too; rows that become one URL merge their visits.
        let merged = HistoryIndex(fileURL: dir.appendingPathComponent("merge.sqlite"), halfLife: halfLife)
        await merged.migrate([
            HistorySeed(url: "https://a.example/cb?code=SECRET&state=S2", title: "Callback", profile: work, visitCount: 2, lastVisited: now.addingTimeInterval(-day)),
            HistorySeed(url: "https://a.example/cb", title: "Callback newer", profile: work, visitCount: 3, lastVisited: now),
        ])
        do {
            let rows = await merged.search("callback", profile: work)!
            precondition(rows.count == 1 && rows[0].url == "https://a.example/cb", "\(rows)")
            precondition(rows[0].visitCount == 5 && rows[0].title == "Callback newer" && rows[0].lastVisited == now)
        }

        // Timing on 200k rows.
        let big = HistoryIndex(fileURL: dir.appendingPathComponent("big.sqlite"), halfLife: halfLife)
        let words = ["github", "glia", "infra", "kagi", "swift", "docs", "issue", "pull", "board", "stage", "deploy", "grafana", "metrics", "nook", "browser", "report"]
        var generator = SystemRandomNumberGenerator()
        let seeds = (0..<200_000).map { i -> HistorySeed in
            let a = words.randomElement(using: &generator)!, b = words.randomElement(using: &generator)!
            return HistorySeed(url: "https://\(a)\(i % 5000).example.com/\(b)/\(i)", title: "\(a) \(b) page \(i)", profile: work,
                               visitCount: Int.random(in: 1...40, using: &generator), lastVisited: now.addingTimeInterval(-Double(i) * 60))
        }
        let migrateStart = Date()
        await big.migrate(seeds)
        print("migrate 200k: \(Int(Date().timeIntervalSince(migrateStart) * 1000)) ms")
        for query in ["g", "gi", "glia", "glia infra", "stage deploy 123"] {
            _ = await big.search(query, profile: work)
            let start = Date()
            let found = await big.search(query, profile: work)!
            let ms = Date().timeIntervalSince(start) * 1000
            print("search \"\(query)\" on 200k: \(String(format: "%.1f", ms)) ms, \(found.count) rows")
            precondition(ms < 25, "search too slow")
        }
        print("HistoryIndexCheck passed")
    }
}
