// Licensed under GPL-3.0. See LICENSE.
// swiftc Packages/NookSettings/Sources/NookSettings/DefaultBrowserPrompt.swift Packages/NookSettings/Checks/DefaultBrowserPromptCheck.swift -o /tmp/default-browser-prompt && /tmp/default-browser-prompt

import Foundation

@main
struct DefaultBrowserPromptCheck {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 86_400
        precondition(DefaultBrowserPrompt.shouldAsk(isDefault: false, dismissedAt: nil, now: now), "asks when Nook is not the default")
        precondition(!DefaultBrowserPrompt.shouldAsk(isDefault: true, dismissedAt: nil, now: now), "never asks once Nook is the default")
        precondition(!DefaultBrowserPrompt.shouldAsk(isDefault: false, dismissedAt: now - 29 * day, now: now), "Not Now holds for 30 days")
        precondition(DefaultBrowserPrompt.shouldAsk(isDefault: false, dismissedAt: now - 30 * day, now: now), "then asks again")
        print("DefaultBrowserPromptCheck passed")
    }
}
