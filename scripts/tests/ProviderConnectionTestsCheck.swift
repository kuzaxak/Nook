// Licensed under GPL-3.0. See LICENSE.
//
//  ProviderConnectionTestsCheck.swift
//  Nook
//
//  Settings → AI → Providers: each provider's Test result shows under that provider only, and a
//  result that arrives after the provider was edited or tested again is dropped. Compiles the
//  shipped source directly:
//
//    swiftc Nook/Components/Settings/ProviderConnectionTests.swift \
//           scripts/tests/ProviderConnectionTestsCheck.swift -o /tmp/provider-tests-check && /tmp/provider-tests-check
//

import Foundation

@main
struct ProviderConnectionTestsCheck {
    static func main() {
        let verified = ProviderConnectionTests.Outcome(passed: true, message: "Success: Connection verified")
        let rejected = ProviderConnectionTests.Outcome(passed: false, message: "Failed: Invalid response")

        var tests = ProviderConnectionTests()
        let openAI = tests.start("openai")
        precondition(tests.isTesting("openai") && !tests.isTesting("gemini"), "only the tested row shows progress")
        precondition(tests.outcome(for: "gemini") == nil && tests.outcome(for: "openai") == nil)
        tests.finish(openAI, verified)
        precondition(tests.outcome(for: "openai") == verified && !tests.isTesting("openai"))
        precondition(tests.outcome(for: "gemini") == nil && tests.outcome(for: "anthropic") == nil, "no other row shows the result")

        let anthropic = tests.start("anthropic")
        tests.finish(anthropic, rejected)
        precondition(tests.outcome(for: "anthropic") == rejected && tests.outcome(for: "openai") == verified, "each row keeps its own")

        tests.invalidate("anthropic")
        precondition(tests.outcome(for: "anthropic") == nil, "editing the key, URL or switch clears that row's result")
        precondition(tests.outcome(for: "openai") == verified, "and only that row's")

        let beforeEdit = tests.start("openai")
        tests.invalidate("openai")
        tests.finish(beforeEdit, verified)
        precondition(tests.outcome(for: "openai") == nil && !tests.isTesting("openai"), "a reply for the old key is dropped")

        let first = tests.start("openai")
        let second = tests.start("openai")
        tests.finish(first, rejected)
        precondition(tests.isTesting("openai") && tests.outcome(for: "openai") == nil, "an earlier run's reply is dropped")
        tests.finish(second, verified)
        precondition(tests.outcome(for: "openai") == verified)

        let gone = tests.start("gemini")
        tests.finish(gone, nil)
        precondition(tests.outcome(for: "gemini") == nil && !tests.isTesting("gemini"), "a test with nothing to report leaves no result")

        print("ProviderConnectionTestsCheck passed")
    }
}
