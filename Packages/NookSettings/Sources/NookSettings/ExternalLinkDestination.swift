// Licensed under GPL-3.0. See LICENSE.
//
//  ExternalLinkDestination.swift
//  NookSettings
//
//  Where a link from another app opens: Nook's mini window, or a new tab in the current space,
//  as Arc offers Little Arc or the current space.
//

import Foundation

public enum ExternalLinkDestination: String, CaseIterable, Identifiable {
    case miniWindow
    case currentSpace

    public init(stored: String?) {
        self = stored.flatMap(Self.init(rawValue:)) ?? .miniWindow
    }

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .miniWindow: return "Mini window"
        case .currentSpace: return "Current space"
        }
    }

    /// The space a current-space link opens in, for a window showing `space`. The Agent space's
    /// pages are the agent's and its tabs close on their own, so a link never opens there.
    public static func space(showing space: UUID, spaces: [UUID], agentSpace: UUID?) -> UUID? {
        space == agentSpace ? spaces.first { $0 != agentSpace } : space
    }
}

/// The regular window a tab for a link from another app opens in.
public enum ExternalLinkWindow: Equatable {
    case existing(UUID)
    /// The regular window that is on its way, once it is set up.
    case opening
    case new

    /// `regularWindows` are the open non-private windows that show a space, front to back.
    /// `windowOpening` is true while a regular window is on its way: the one restored at launch,
    /// or one opened by an earlier call.
    public init(activeWindow: UUID?, regularWindows: [UUID], windowOpening: Bool) {
        if let window = regularWindows.first(where: { $0 == activeWindow }) ?? regularWindows.first {
            self = .existing(window)
        } else {
            self = windowOpening ? .opening : .new
        }
    }
}
