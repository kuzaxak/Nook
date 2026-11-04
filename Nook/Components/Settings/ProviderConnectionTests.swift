// Licensed under GPL-3.0. See LICENSE.
//
//  ProviderConnectionTests.swift
//  Nook
//
//  The Test button's results in Settings → AI → Providers, one per provider. A result belongs to
//  the provider it ran for, and one that arrives after that provider was edited or tested again
//  is dropped.
//

import Foundation

struct ProviderConnectionTests {
    struct Outcome: Equatable {
        let passed: Bool
        let message: String
    }

    /// One press of Test, handed back with its outcome.
    struct Run {
        let providerId: String
        let number: Int
    }

    private var outcomes: [String: Outcome] = [:]
    private var running: [String: Int] = [:]
    private var lastRun: [String: Int] = [:]

    func outcome(for providerId: String) -> Outcome? {
        outcomes[providerId]
    }

    func isTesting(_ providerId: String) -> Bool {
        running[providerId] != nil
    }

    mutating func start(_ providerId: String) -> Run {
        let number = lastRun[providerId, default: 0] + 1
        lastRun[providerId] = number
        running[providerId] = number
        outcomes[providerId] = nil
        return Run(providerId: providerId, number: number)
    }

    mutating func finish(_ run: Run, _ outcome: Outcome?) {
        guard running[run.providerId] == run.number else { return }
        running[run.providerId] = nil
        outcomes[run.providerId] = outcome
    }

    /// The provider's key, URL or switch changed, so its result and any test under way no longer apply.
    mutating func invalidate(_ providerId: String) {
        running[providerId] = nil
        outcomes[providerId] = nil
    }
}
