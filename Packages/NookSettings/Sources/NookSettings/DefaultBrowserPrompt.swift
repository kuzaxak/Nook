// Licensed under GPL-3.0. See LICENSE.
//
//  DefaultBrowserPrompt.swift
//  NookSettings
//
//  When Nook offers to become the default browser: whenever it is not, except for 30 days after
//  the person answers Not Now.
//

import Foundation

public enum DefaultBrowserPrompt {
    public static let quietPeriod: TimeInterval = 30 * 86_400

    public static func shouldAsk(isDefault: Bool, dismissedAt: Date?, now: Date = Date()) -> Bool {
        guard !isDefault else { return false }
        guard let dismissedAt else { return true }
        return now.timeIntervalSince(dismissedAt) >= quietPeriod
    }
}
