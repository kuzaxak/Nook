// Licensed under GPL-3.0. See LICENSE.
//
//  PaletteText.swift
//  Nook
//
//  Word splitting, completion and short addresses for the command bar's field and rows.
//

import Foundation

public enum PaletteText {
    /// Characters a word starts at, besides whitespace, as zsh's WORDCHARS leaves them out.
    public static let defaultStops: Set<Character> = ["/", ".", "?", "&", "=", "#", ":", "-"]
    /// The characters URLs separate their parts with; any that are not stops belong to words.
    static let urlPunctuation: Set<Character> = defaultStops.union(["_"])

    /// The stops in Settings: its punctuation and symbols, or the defaults when it has none.
    public static func stops(from setting: String) -> Set<Character> {
        let stops = Set(setting.filter { $0.isPunctuation || $0.isSymbol })
        return stops.isEmpty ? defaultStops : stops
    }

    /// Lowercased search words of `text`, split on whitespace and `stops`, which are dropped.
    public static func terms(_ text: String, stops: Set<Character> = defaultStops) -> [String] {
        text.lowercased().split { $0.isWhitespace || stops.contains($0) }.map(String.init)
    }

    /// URL punctuation a search index keeps inside words because it is not a stop.
    public static func wordCharacters(stops: Set<Character>) -> Set<Character> {
        urlPunctuation.subtracting(stops)
    }

    /// `text` split before each run of stop characters: `github.com/glia/infra-k8s` is
    /// `github` · `.com` · `/glia` · `/infra` · `-k8s`. Joined, the words are `text` again.
    public static func words(_ text: String, stops: Set<Character> = defaultStops) -> [String] {
        var words: [String] = []
        var current = ""
        var inBody = false
        for character in text {
            let isStop = character.isWhitespace || stops.contains(character)
            if isStop, inBody {
                words.append(current)
                current = ""
                inBody = false
            }
            if !isStop { inBody = true }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// The part of `ghost` that ⌥→ accepts: its first word.
    public static func nextWord(of ghost: String, stops: Set<Character> = defaultStops) -> String {
        words(ghost, stops: stops).first ?? ""
    }

    /// `text` without its last word, for Ctrl+W and ⌥⌫.
    public static func deletingLastWord(_ text: String, stops: Set<Character> = defaultStops) -> String {
        words(text, stops: stops).dropLast().joined()
    }

    /// Offset of the start of the word that ends at `offset`, for deleting or moving back a word
    /// from the caret.
    public static func wordStart(before offset: Int, in text: String, stops: Set<Character> = defaultStops) -> Int {
        let prefix = String(text.prefix(offset))
        return prefix.count - (words(prefix, stops: stops).last?.count ?? 0)
    }

    /// What Tab puts in the field from a row: host and first path segment, no scheme or `www.`.
    public static func refineText(for url: URL) -> String {
        let segments = url.pathComponents.filter { $0 != "/" }
        return ([displayHost(url)] + segments.prefix(1)).joined(separator: "/")
    }

    /// A row's second line: host and the last one or two path segments, no scheme, `www.` or query.
    public static func shortURL(_ url: URL) -> String {
        let segments = url.pathComponents.filter { $0 != "/" }
        guard segments.count > 2 else { return ([displayHost(url)] + segments).joined(separator: "/") }
        return ([displayHost(url), "…"] + segments.suffix(2)).joined(separator: "/")
    }

    /// What the typed text completes to: the rest of the segment being typed (the host, else one
    /// path segment, up to the next `/`, `?` or `#`) in the address of a matching candidate. The
    /// completion most candidates share wins, the earlier one on a tie. Nil when the typed text
    /// already ends a segment, so Return opens exactly what was typed or taken.
    public static func completion(for typed: String, candidates: [String]) -> String? {
        guard !typed.isEmpty, !typed.contains(where: \.isWhitespace) else { return nil }
        let lowered = typed.lowercased()
        var tallies: [(key: String, completion: String, count: Int)] = []
        for candidate in candidates {
            guard let completion = segmentCompletion(of: typed, lowered: lowered, in: address(of: candidate, typed: lowered))
            else { continue }
            let key = completion.lowercased()
            if let index = tallies.firstIndex(where: { $0.key == key }) {
                tallies[index].count += 1
            } else {
                tallies.append((key, completion, 1))
            }
        }
        return tallies.max { $0.count < $1.count }?.completion
    }

    private static let segmentEnds: Set<Character> = ["/", "?", "#"]

    /// `candidate` as the field shows addresses: no scheme, no trailing `/`, and no `www.` unless typed.
    private static func address(of candidate: String, typed lowered: String) -> String {
        var address = candidate
        for scheme in ["https://", "http://"] where address.lowercased().hasPrefix(scheme) {
            address.removeFirst(scheme.count)
        }
        if !lowered.hasPrefix("www."), address.lowercased().hasPrefix("www.") { address.removeFirst(4) }
        if address.hasSuffix("/") { address.removeLast() }
        return address
    }

    private static func segmentCompletion(of typed: String, lowered: String, in address: String) -> String? {
        guard address.count > typed.count, address.lowercased().hasPrefix(lowered) else { return nil }
        let rest = address.dropFirst(typed.count)
        guard let next = rest.first, !segmentEnds.contains(next) else { return nil }
        return typed + rest.prefix { !segmentEnds.contains($0) }
    }

    /// How well a tab or folder matches `query`: nil unless every word appears in `title` or
    /// `detail` (its address); 2 when each word starts a title word, 1 when each starts a word of
    /// either, 0 for a substring match.
    public static func matchScore(query: String, title: String, detail: String?) -> Int? {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let titleText = title.lowercased(), detailText = detail?.lowercased() ?? ""
        guard words.allSatisfy({ titleText.contains($0) || detailText.contains($0) }) else { return nil }
        let split: (String) -> [Substring] = { $0.split { !$0.isLetter && !$0.isNumber } }
        let titleWords = split(titleText), allWords = titleWords + split(detailText)
        if words.allSatisfy({ word in titleWords.contains { $0.hasPrefix(word) } }) { return 2 }
        if words.allSatisfy({ word in allWords.contains { $0.hasPrefix(word) } }) { return 1 }
        return 0
    }

    private static let localHosts = ["localhost", "127.0.0.1"]

    /// Typed text that asks for a local server: three or more letters of `localhost` or
    /// `127.0.0.1`, or either with a port after the colon.
    public static func isLocalServerQuery(_ typed: String) -> Bool {
        let text = typed.lowercased().trimmingCharacters(in: .whitespaces)
        return localHosts.contains { host in
            (text.count >= 3 && host.hasPrefix(text)) || text.hasPrefix(host + ":")
        }
    }

    /// One origin per local server among history rows (`key` is the frecency score), best first,
    /// keeping the host family and port prefix that was typed.
    public static func localOrigins(_ rows: [(url: String, key: Double)], typed: String) -> [String] {
        guard isLocalServerQuery(typed) else { return [] }
        let text = typed.lowercased().trimmingCharacters(in: .whitespaces)
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        let typedPort = parts.count == 2 ? parts[1] : ""
        var best: [String: Double] = [:]
        for row in rows {
            guard let url = URL(string: row.url), let host = url.host?.lowercased(),
                  localHosts.contains(host), host.hasPrefix(parts[0]) || parts[0].hasPrefix(host) else { continue }
            let port = url.port.map(String.init) ?? ""
            guard port.hasPrefix(typedPort) else { continue }
            let origin = "\(url.scheme ?? "http")://\(host)" + (port.isEmpty ? "" : ":\(port)")
            best[origin] = max(best[origin] ?? -.infinity, row.key)
        }
        return best.sorted { $0.value > $1.value }.map(\.key)
    }

    private static func displayHost(_ url: URL) -> String {
        var host = url.host ?? url.absoluteString
        if host.lowercased().hasPrefix("www.") { host.removeFirst(4) }
        if let port = url.port { host += ":\(port)" }
        return host
    }
}
