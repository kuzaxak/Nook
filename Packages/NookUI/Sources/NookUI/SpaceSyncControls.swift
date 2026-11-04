// Licensed under GPL-3.0. See LICENSE.
//
//  SpaceSyncControls.swift
//  NookUI
//
//  iCloud sync of spaces as Settings and the space menu see it. The macOS app conforms with
//  its CloudKit engine; iOS has none, and the controls stay hidden.
//

import Foundation
import NookTabsCore

@MainActor public protocol SpaceSyncControls: AnyObject {
    var status: SpaceSyncStatus { get }
    func level(of spaceID: UUID) -> SpaceSyncLevel
    func setLevel(_ level: SpaceSyncLevel, for spaceID: UUID)
    func syncNow()
}

extension SpaceSyncLevel {
    public var title: String {
        switch self {
        case .off: return "Off"
        case .pinned: return "Favorites & Pinned"
        case .everything: return "Everything"
        }
    }

    public var symbol: String {
        switch self {
        case .off: return "icloud.slash"
        case .pinned: return "icloud"
        case .everything: return "icloud.fill"
        }
    }
}
