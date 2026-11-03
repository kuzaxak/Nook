// Licensed under GPL-3.0. See LICENSE.
//
//  VaultPromptCheck.swift
//  Nook
//
//  Page-controlled text in Nook's vault prompts (usernames, user and relying-party names) loses
//  newlines and control characters and stops at 64 characters; the picker ignores picks for its
//  first 500 ms:
//
//    swiftc -parse-as-library Packages/NookWeb/Sources/NookWeb/Vault/VaultPrompt.swift \
//           Packages/NookWeb/Checks/VaultPromptCheck.swift -o /tmp/vault-prompt && /tmp/vault-prompt
//

import Foundation

@main
struct VaultPromptCheck {
    static func main() {
        precondition(VaultPrompt.displayText("me@example.com") == "me@example.com")
        precondition(VaultPrompt.displayText("line\none\r\ntwo\tthree\u{0}\u{7f}") == "lineonetwothree")
        precondition(VaultPrompt.displayText("Bank\u{2028}Support\u{2029}") == "BankSupport")
        // Bidi overrides and zero-width characters can disguise a name.
        precondition(VaultPrompt.displayText("\u{202E}moc.evil\u{202C}\u{200B}") == "moc.evil")
        precondition(VaultPrompt.displayText("Zoë Ångström") == "Zoë Ångström")

        let long = String(repeating: "a", count: 100)
        precondition(VaultPrompt.displayText(long) == String(repeating: "a", count: 64))
        precondition(VaultPrompt.displayText(String(repeating: "\n", count: 10) + long).count == 64)
        let flags = String(repeating: "🇪🇪", count: 70)
        precondition(VaultPrompt.displayText(flags) == String(repeating: "🇪🇪", count: 64), "64 characters, not 64 scalars")

        let shown = Date(timeIntervalSinceReferenceDate: 1000)
        precondition(!VaultPrompt.acceptsPick(shownAt: shown, now: shown))
        precondition(!VaultPrompt.acceptsPick(shownAt: shown, now: shown.addingTimeInterval(0.499)))
        precondition(VaultPrompt.acceptsPick(shownAt: shown, now: shown.addingTimeInterval(0.5)))
        precondition(VaultPrompt.acceptsPick(shownAt: shown, now: shown.addingTimeInterval(30)))

        print("VaultPromptCheck passed")
    }
}
