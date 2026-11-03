// Licensed under GPL-3.0. See LICENSE.
//
//  PublicSuffixList.swift
//  Nook
//
//  The Public Suffix List algorithm (https://publicsuffix.org/list/) over the bundled
//  Resources/public_suffix_list.dat, which is MPL-2.0 (see PUBLIC_SUFFIX_LIST_NOTICE.txt).
//  Used to stop a passkey rpId from naming a suffix shared by unrelated sites.
//

import Foundation

public struct PublicSuffixList {
    private var rules: Set<String> = []
    /// `*.ck` is stored as `ck`.
    private var wildcards: Set<String> = []
    /// `!www.ck` is stored as `www.ck`.
    private var exceptions: Set<String> = []

    public init(text: String) {
        for line in text.split(whereSeparator: \.isNewline) {
            guard let token = line.split(whereSeparator: \.isWhitespace).first, !token.hasPrefix("//") else { continue }
            // The list spells IDN rules in Unicode; WebKit reports hosts in ASCII.
            let rule = token.split(separator: ".").map { Self.asciiLabel(String($0).lowercased()) }.joined(separator: ".")
            if rule.hasPrefix("!") {
                exceptions.insert(String(rule.dropFirst()))
            } else if rule.hasPrefix("*.") {
                wildcards.insert(String(rule.dropFirst(2)))
            } else {
                rules.insert(rule)
            }
        }
    }

    /// The public suffix of a lowercase ASCII domain. A domain no rule matches gets its last
    /// label, the list's implicit `*` rule.
    public func publicSuffix(of domain: String) -> String {
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        func suffix(from index: Int) -> String { labels[index...].joined(separator: ".") }

        // An exception rule always prevails; the suffix is the rule without its first label.
        for index in labels.indices where exceptions.contains(suffix(from: index)) {
            return suffix(from: index + 1)
        }
        // Otherwise the matching rule with the most labels.
        for index in labels.indices {
            if rules.contains(suffix(from: index)) { return suffix(from: index) }
            if index + 1 < labels.count, wildcards.contains(suffix(from: index + 1)) { return suffix(from: index) }
        }
        return labels.last ?? domain
    }

    public func isPublicSuffix(_ domain: String) -> Bool {
        publicSuffix(of: domain) == domain
    }

    // MARK: - Punycode (RFC 3492)

    /// An ASCII label unchanged; any other as `xn--` and its Punycode.
    static func asciiLabel(_ label: String) -> String {
        guard !label.unicodeScalars.allSatisfy(\.isASCII) else { return label }
        return "xn--" + punycode(label.unicodeScalars.map(\.value))
    }

    private static func punycode(_ input: [UInt32]) -> String {
        let base = 36, tMin = 1, tMax = 26
        func digit(_ value: Int) -> Character {
            Character(UnicodeScalar(UInt8(value < 26 ? 97 + value : 22 + value)))
        }
        func adapt(_ delta: Int, _ points: Int, _ first: Bool) -> Int {
            var delta = first ? delta / 700 : delta / 2
            delta += delta / points
            var k = 0
            while delta > ((base - tMin) * tMax) / 2 {
                delta /= base - tMin
                k += base
            }
            return k + (base - tMin + 1) * delta / (delta + 38)
        }

        var output = String(input.filter { $0 < 0x80 }.map { Character(UnicodeScalar(UInt8($0))) })
        let basicCount = output.count
        var handled = basicCount
        if basicCount > 0 { output.append("-") }
        var n = 0x80, delta = 0, bias = 72
        while handled < input.count {
            let next = Int(input.filter { Int($0) >= n }.min()!)
            delta += (next - n) * (handled + 1)
            n = next
            for code in input.map(Int.init) {
                if code < n { delta += 1 }
                guard code == n else { continue }
                var q = delta
                var k = base
                while true {
                    let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                    if q < t { break }
                    output.append(digit(t + (q - t) % (base - t)))
                    q = (q - t) / (base - t)
                    k += base
                }
                output.append(digit(q))
                bias = adapt(delta, handled + 1, handled == basicCount)
                delta = 0
                handled += 1
            }
            delta += 1
            n += 1
        }
        return output
    }
}
