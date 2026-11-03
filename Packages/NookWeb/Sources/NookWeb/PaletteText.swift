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

    /// The ghost for `typed`: the first candidate address (best first) that starts with it once
    /// scheme, `www.` and a trailing slash are dropped, spelled with the typed part as typed.
    public static func completion(for typed: String, candidates: [String]) -> String? {
        guard !typed.isEmpty, !typed.contains(where: \.isWhitespace) else { return nil }
        let lowered = typed.lowercased()
        for candidate in candidates {
            var address = candidate
            for scheme in ["https://", "http://"] where address.lowercased().hasPrefix(scheme) {
                address.removeFirst(scheme.count)
            }
            if !lowered.hasPrefix("www."), address.lowercased().hasPrefix("www.") { address.removeFirst(4) }
            if address.hasSuffix("/") { address.removeLast() }
            if address.count > typed.count, address.lowercased().hasPrefix(lowered) {
                return typed + address.dropFirst(typed.count)
            }
        }
        return nil
    }

    private static func displayHost(_ url: URL) -> String {
        var host = url.host ?? url.absoluteString
        if host.lowercased().hasPrefix("www.") { host.removeFirst(4) }
        if let port = url.port { host += ":\(port)" }
        return host
    }
}
