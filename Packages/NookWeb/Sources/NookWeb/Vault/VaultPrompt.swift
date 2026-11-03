// Licensed under GPL-3.0. See LICENSE.
//
//  VaultPrompt.swift
//  Nook
//
//  Rules for the prompts Nook shows on a page's behalf: text the page controls cannot break
//  lines, reorder itself or run on, and the picker cannot be answered by a click or Return
//  the page lined up before it appeared.
//

import Foundation

public enum VaultPrompt {
    public static let maxTextLength = 64
    public static let armDelay: TimeInterval = 0.5

    /// `text` without control, format (bidi, zero-width) or line and paragraph separator
    /// characters, cut to 64 characters.
    public static func displayText(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: continue
            default: scalars.append(scalar)
            }
        }
        return String(String(scalars).prefix(maxTextLength))
    }

    /// Whether a pick at `now` counts for a picker shown at `shownAt`.
    public static func acceptsPick(shownAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(shownAt) >= armDelay
    }
}
