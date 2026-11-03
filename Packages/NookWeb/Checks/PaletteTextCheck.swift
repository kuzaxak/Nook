// Licensed under GPL-3.0. See LICENSE.
//
//  PaletteTextCheck.swift
//  Nook
//
//  Command bar text helpers. NookWeb has no test target, so this compiles the shipped source directly:
//
//    swiftc -parse-as-library Packages/NookWeb/Sources/NookWeb/PaletteText.swift \
//           Packages/NookWeb/Checks/PaletteTextCheck.swift -o /tmp/palette-text-check && /tmp/palette-text-check
//

import Foundation

@main
struct PaletteTextCheck {
    static func main() {
        // Words start at a stop character, as zsh splits with a short WORDCHARS.
        precondition(PaletteText.words("github.com/glia/infra-k8s") == ["github", ".com", "/glia", "/infra", "-k8s"])
        precondition(PaletteText.words("glia infra") == ["glia", " infra"])
        precondition(PaletteText.words("") == [])

        // ⌥→ takes the ghost one word at a time.
        precondition(PaletteText.nextWord(of: "hub.com/glia") == "hub")
        precondition(PaletteText.nextWord(of: ".com/glia") == ".com")
        precondition(PaletteText.nextWord(of: "/glia") == "/glia")
        precondition(PaletteText.nextWord(of: "") == "")

        // Ctrl+W and ⌥⌫ undo it word by word.
        var text = "github.com/glia/infra-k8s"
        var steps: [String] = []
        while !text.isEmpty { text = PaletteText.deletingLastWord(text); steps.append(text) }
        precondition(steps == ["github.com/glia/infra", "github.com/glia", "github.com", "github", ""], "\(steps)")
        precondition(PaletteText.deletingLastWord("open ai ") == "open ai", "trailing space goes first")
        precondition(PaletteText.wordStart(before: 15, in: "github.com/glia/infra") == 10)
        precondition(PaletteText.wordStart(before: 0, in: "abc") == 0)

        // Custom stops: with '-' left out, a hyphenated name is one word.
        precondition(PaletteText.words("infra-k8s/x", stops: ["/"]) == ["infra-k8s", "/x"])

        // Tab on a row refines to host and first path segment.
        precondition(PaletteText.refineText(for: URL(string: "https://www.github.com/glia/infra/pull/1?x=1")!) == "github.com/glia")
        precondition(PaletteText.refineText(for: URL(string: "https://kagi.com/")!) == "kagi.com")

        // Row line 2: host and the last path segments, no scheme, no www, no tracking.
        precondition(PaletteText.shortURL(URL(string: "https://www.github.com/glia/infra/pull/123?utm_source=x")!) == "github.com/…/pull/123")
        precondition(PaletteText.shortURL(URL(string: "https://github.com/glia/infra")!) == "github.com/glia/infra")
        precondition(PaletteText.shortURL(URL(string: "https://kagi.com/")!) == "kagi.com")
        precondition(PaletteText.shortURL(URL(string: "http://localhost:3000/admin")!) == "localhost:3000/admin")

        // The ghost: the best page whose address starts with what was typed, in the typed case.
        let candidates = ["https://www.github.com/glia/infra", "https://gitlab.com/", "github.com"]
        precondition(PaletteText.completion(for: "GitH", candidates: candidates) == "GitHub.com/glia/infra")
        precondition(PaletteText.completion(for: "gitl", candidates: candidates) == "gitlab.com")
        precondition(PaletteText.completion(for: "github.com/glia/infra", candidates: candidates) == nil, "nothing left to complete")
        precondition(PaletteText.completion(for: "git hub", candidates: candidates) == nil)
        precondition(PaletteText.completion(for: "", candidates: candidates) == nil)
        // Tabs and folders: every word must appear; word-prefix matches in the title rank first.
        precondition(PaletteText.matchScore(query: "team boa", title: "My Team Boards", detail: nil) == 2)
        precondition(PaletteText.matchScore(query: "glia", title: "Infra", detail: "https://github.com/glia/infra") == 1)
        precondition(PaletteText.matchScore(query: "eam", title: "My Team", detail: nil) == 0, "substring still matches")
        precondition(PaletteText.matchScore(query: "stage 4", title: "Stage 42 dashboard", detail: nil) == 2)
        precondition(PaletteText.matchScore(query: "boards x", title: "Boards", detail: nil) == nil)
        precondition(PaletteText.matchScore(query: "", title: "Boards", detail: nil) != nil, "an empty query lists everything")
        // Local servers: one row per origin, best score first, filtered by the typed port.
        let local: [(url: String, key: Double)] = [
            ("http://localhost:3000/admin", 5), ("http://localhost:3000/", 9), ("http://localhost:8080/api", 7),
            ("http://127.0.0.1:5173/", 8), ("https://localhost.example.com/", 20),
        ]
        precondition(PaletteText.localOrigins(local, typed: "loc") == ["http://localhost:3000", "http://localhost:8080"])
        precondition(PaletteText.localOrigins(local, typed: "localhost:8") == ["http://localhost:8080"])
        precondition(PaletteText.localOrigins(local, typed: "127") == ["http://127.0.0.1:5173"])
        precondition(PaletteText.localOrigins(local, typed: "lo").isEmpty, "two letters are not enough")
        precondition(PaletteText.localOrigins(local, typed: "github").isEmpty)
        precondition(PaletteText.isLocalServerQuery("localh") && PaletteText.isLocalServerQuery("127.0.0.1:30") && !PaletteText.isLocalServerQuery("kagi"))
        print("PaletteTextCheck passed")
    }
}
