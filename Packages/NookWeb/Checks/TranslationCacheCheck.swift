// Licensed under GPL-3.0. See LICENSE.
//
//  TranslationCacheCheck.swift
//  Nook
//
//  The AI translation cache: its keys, what a lookup finds, expiry 30 days after last use,
//  least-recently-used eviction, one file per profile and none for a private window, and what
//  clearing history or website data removes. Compiles the shipped source directly:
//
//    swiftc -parse-as-library Packages/NookWeb/Sources/NookWeb/TranslationCache.swift \
//           Packages/NookWeb/Checks/TranslationCacheCheck.swift -o /tmp/translation-cache-check && /tmp/translation-cache-check
//

import Foundation

final class Clock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(days: Double) { now = now.addingTimeInterval(days * 86_400) }
}

@main
struct TranslationCacheCheck {
    @MainActor
    static func main() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        keys()
        await storage(in: directory.appendingPathComponent("storage"))
        await expiry(in: directory.appendingPathComponent("expiry"))
        await eviction(in: directory.appendingPathComponent("eviction"))
        await profiles(in: directory.appendingPathComponent("TranslationCache"))
        print("TranslationCacheCheck passed")
    }

    static func key(provider: String = "openai", model: String = "gpt-6-luna", source: String = "de", target: String = "en", text: String = "Menü") -> String {
        TranslationCache.key(provider: provider, model: model, source: source, target: target, text: text)
    }

    static func keys() {
        let base = key()
        precondition(base.count == 64 && base.allSatisfy(\.isHexDigit), "a SHA-256 in hex")
        precondition(base == key(), "the same text for the same model and languages has one key")
        precondition(key(text: "Menü ") != base && key(text: " Menü") != base, "whitespace counts, as sent")
        precondition(key(provider: "anthropic") != base && key(model: "gpt-6-terra") != base)
        precondition(key(source: "fr") != base && key(target: "et") != base)
        precondition(key(provider: "ab", model: "c") != key(provider: "a", model: "bc"), "parts cannot run into each other")
        precondition(key(source: "de", target: "en") != key(source: "en", target: "de"))
    }

    static func storage(in directory: URL) async {
        let clock = Clock()
        let file = directory.appendingPathComponent("profile.sqlite")
        let cache = TranslationCache(fileURL: file, now: { clock.now })
        let none = await cache.translations(for: ["k1"])
        precondition(none.isEmpty && !FileManager.default.fileExists(atPath: file.path), "a lookup creates nothing")

        await cache.store(["k1": "Menu", "k2": " Contact us "])
        let found = await cache.translations(for: ["k1", "k2", "k3"])
        precondition(found == ["k1": "Menu", "k2": " Contact us "], "hits come back exactly as stored, misses do not")

        let reopened = TranslationCache(fileURL: file, now: { clock.now })
        let kept = await reopened.translations(for: ["k1"])
        precondition(kept == ["k1": "Menu"], "the file outlives the launch")
    }

    static func expiry(in directory: URL) async {
        let clock = Clock()
        let cache = TranslationCache(fileURL: directory.appendingPathComponent("profile.sqlite"), now: { clock.now })
        await cache.store(["used": "A", "unused": "B"])
        clock.advance(days: 29)
        let touched = await cache.translations(for: ["used"])
        precondition(touched == ["used": "A"])
        clock.advance(days: 2)
        let later = await cache.translations(for: ["used", "unused"])
        precondition(later == ["used": "A"], "an entry not used for 30 days expires; using one renews it")
        clock.advance(days: 31)
        let gone = await cache.translations(for: ["used"])
        precondition(gone.isEmpty)
    }

    static func eviction(in directory: URL) async {
        let clock = Clock()
        let byCount = TranslationCache(
            fileURL: directory.appendingPathComponent("count.sqlite"),
            limits: TranslationCache.Limits(maxEntries: 3, maxBytes: 1_000_000),
            now: { clock.now }
        )
        for key in ["k1", "k2", "k3"] {
            await byCount.store([key: "text"])
            clock.advance(days: 0.01)
        }
        _ = await byCount.translations(for: ["k1"])
        clock.advance(days: 0.01)
        await byCount.store(["k4": "text"])
        let left = await byCount.translations(for: ["k1", "k2", "k3", "k4"])
        precondition(Set(left.keys) == ["k1", "k3", "k4"], "past the entry limit the least recently used goes")

        let bySize = TranslationCache(
            fileURL: directory.appendingPathComponent("size.sqlite"),
            limits: TranslationCache.Limits(maxEntries: 100, maxBytes: 300),
            now: { clock.now }
        )
        let long = String(repeating: "x", count: 100)
        for key in ["s1", "s2", "s3"] {
            await bySize.store([key: long])
            clock.advance(days: 0.01)
        }
        let fits = await bySize.translations(for: ["s1", "s2", "s3"])
        precondition(Set(fits.keys) == ["s2", "s3"], "past the size limit the least recently used goes")
    }

    @MainActor
    static func profiles(in directory: URL) async {
        let clock = Clock()
        let caches = TranslationCaches(directory: directory, now: { clock.now })
        let first = UUID(), second = UUID()

        precondition(caches.cache(forProfile: first, isPrivate: true) == nil, "a private window never reads or writes the cache")
        precondition(!FileManager.default.fileExists(atPath: directory.path))

        guard let a = caches.cache(forProfile: first, isPrivate: false),
              let b = caches.cache(forProfile: second, isPrivate: false)
        else { preconditionFailure("a profile has a cache") }
        precondition(a === caches.cache(forProfile: first, isPrivate: false), "one cache per profile")
        precondition(a !== b && a.fileURL != b.fileURL, "in a file of its own")
        await a.store(["k": "A"])
        await b.store(["k": "B"])
        let fromA = await a.translations(for: ["k"])
        precondition(fromA == ["k": "A"], "profiles do not share translations")

        // Clearing a profile's website data clears its cache, and only its.
        await caches.erase(profile: first)
        let clearedA = await a.translations(for: ["k"])
        let keptB = await b.translations(for: ["k"])
        precondition(clearedA.isEmpty && keptB == ["k": "B"])

        // Clearing a profile's history from a date removes what was last used before it.
        await b.store(["old": "1"])
        clock.advance(days: 10)
        await b.store(["new": "2"])
        await caches.erase(profile: second, usedBefore: clock.now.addingTimeInterval(-5 * 86_400))
        let afterHistory = await b.translations(for: ["old", "new"])
        precondition(afterHistory == ["new": "2"])

        // Clearing every profile's history empties every cache.
        await a.store(["k": "A"])
        await caches.erase(profile: nil, usedBefore: .distantFuture)
        let allA = await a.translations(for: ["k"])
        let allB = await b.translations(for: ["new"])
        precondition(allA.isEmpty && allB.isEmpty)

        // Clear All Website Data and Clear Translation Cache reach profiles not opened this launch.
        let earlier = UUID()
        let lastLaunch = TranslationCache(fileURL: directory.appendingPathComponent("\(earlier.uuidString).sqlite"), now: { clock.now })
        await lastLaunch.store(["k": "C"])
        let nextLaunch = TranslationCaches(directory: directory, now: { clock.now })
        await nextLaunch.eraseAll()
        let reopened = nextLaunch.cache(forProfile: earlier, isPrivate: false)
        let leftover = await reopened?.translations(for: ["k"])
        precondition(leftover?.isEmpty == true)
    }
}
