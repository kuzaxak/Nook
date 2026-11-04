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
    /// Every space record in the account's zone, with its state here.
    var cloudSpaces: [SpaceSyncCloudSpace] { get }
    /// The names of the Macs whose changes the account holds.
    var cloudDevices: [String] { get }
    /// Deletes the space's records from iCloud, so the Macs that sync it delete it, and turns
    /// it Off here, where it stays.
    func removeFromICloud(_ spaceID: UUID)
    /// What the last fetch did with each record: ids, types, levels and times only.
    func syncReport() -> String
    /// Shares this account's zone with the iCloud account whose invite code the person pasted,
    /// as its Mac's Settings shows it. Only invited accounts can join.
    func invite(code: String) async -> SpaceSyncInviteResult
    func stopSharing()
    /// Joins another account's shared zone from its pasted sharing link.
    func joinSharedSync(link: String)
    /// Leaves the joined zone: the spaces stay here, every one Off, back on this account's zone.
    func leaveSharedSync()
    /// Deletes the old copies of moved spaces from this account's own zone.
    func removeOldCopies()
    /// Joins, after asking, a zone this account already joined on another Mac.
    func joinOffer(_ owner: String)
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
