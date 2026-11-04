// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
@testable import NookTabsCore

/// Sync shared between two iCloud accounts: the owner shares its zone, the other account joins
/// it and moves its own synced spaces in, and either side can end it. Each zone is a fake cloud;
/// a Mac reaches the one its state routes it to.
struct SpaceSyncSharingTests {
    typealias Key = SyncRecord.Key
    typealias Mac = SpaceSyncTests.Mac
    typealias Cloud = SpaceSyncTests.Cloud
    typealias Work = SpaceSyncTests.Work

    static let ownerAccount = "_48e607c1179693a062ca0aefa4e62a57"
    static let guestAccount = "_12ae184189470032bbd84b751bc2e85d"

    private func later(_ seconds: TimeInterval) -> Date { fixedNow.addingTimeInterval(seconds) }

    /// The owner's zone, which it shares, and the guest's own zone.
    struct Zones {
        var owner = Cloud()
        var guest = Cloud()

        /// The zone a guest Mac's state sends to and fetches from.
        mutating func sync(_ mac: inout Mac, now: Date) {
            if mac.state.database == .shared {
                mac.sync(&owner, now: now)
            } else {
                mac.sync(&guest, now: now)
            }
        }

        /// Deletes what the guest may now delete from its own zone, as the app does after a send.
        mutating func deletePrivate(_ mac: inout Mac) {
            let ids = mac.state.privateDeletions(in: mac.tree)
            for id in ids {
                guest.records[id] = nil
                guest.journal.append(id)
            }
            mac.state.deletedFromPrivateZone(ids)
        }
    }

    /// The owner syncs Work in its zone and shares it; the guest syncs its own Side space in its
    /// own zone.
    private func setUp() throws -> (owner: Mac, guest: Mac, work: Work, side: UUID, sideTab: UUID, zones: Zones) {
        let work = try Work()
        var zones = Zones()
        var owner = Mac(work.tree)
        owner.device = "iMac"
        owner.state.account = Self.ownerAccount
        owner.state.setLevel(.pinned, for: work.space, now: fixedNow)
        owner.sync(&zones.owner)
        owner.state.shared(participants: [
            SpaceSyncParticipant(name: "Owner", status: .accepted, isOwner: true),
            SpaceSyncParticipant(name: "Guest", status: .pending, isOwner: false),
        ])

        var tree = TabTree.firstLaunch(homeURL: url("home"), now: fixedNow)
        let side = UUID(), sideTab = UUID()
        tree.createSpace(id: side, name: "Side", icon: "", accentHex: "#000000", after: nil, now: fixedNow)
        try tree.createTab(id: sideTab, url: url("side"), title: "Side tab", in: .pinned(spaceID: side), after: nil, now: fixedNow)
        var guest = Mac(tree)
        guest.device = "MacBook"
        guest.state.account = Self.guestAccount
        guest.state.setLevel(.pinned, for: side, now: fixedNow)
        zones.sync(&guest, now: fixedNow)
        #expect(zones.guest.records[side] != nil)
        return (owner, guest, work, side, sideTab, zones)
    }

    /// The guest joins the owner's zone, as accepting the owner's share does, and fetches
    /// everything there.
    private func join(_ guest: inout Mac, _ zones: inout Zones, now: Date) {
        let decision = guest.state.acceptance(containerID: SpaceSyncAvailability.containerID, zoneName: SpaceSyncAvailability.zoneName,
                                              zoneOwner: Self.ownerAccount, isOwner: false)
        #expect(decision == .join(owner: Self.ownerAccount))
        guest.state.join(owner: Self.ownerAccount, ownerName: "Vladimir")
        guest.cursor = 0
        guest.state.beginRefetch()
    }

    // MARK: - Routing

    @Test func aMacSyncsItsOwnZoneUntilItJoinsAnotherAccountsAndAfterItLeaves() throws {
        var (_, guest, _, _, _, zones) = try setUp()
        #expect(guest.state.database == .private)
        #expect(guest.state.zoneOwner == nil)

        join(&guest, &zones, now: later(10))
        #expect(guest.state.database == .shared)
        #expect(guest.state.zoneOwner == Self.ownerAccount)
        #expect(guest.state.mode == .joined(owner: "Vladimir"))

        guest.state.leaveSharedZone()
        #expect(guest.state.database == .private)
        #expect(guest.state.zoneOwner == nil)
        #expect(guest.state.mode == .own)
    }

    @Test func theOwnerSaysHowManyPeopleItSharesWith() throws {
        var (owner, _, _, _, _, _) = try setUp()
        #expect(owner.state.database == .private)
        #expect(owner.state.mode == .sharing(people: 1))

        owner.state.shared(participants: [
            SpaceSyncParticipant(name: "Owner", status: .accepted, isOwner: true),
            SpaceSyncParticipant(name: "Guest", status: .accepted, isOwner: false),
            SpaceSyncParticipant(name: "Gone", status: .removed, isOwner: false),
        ])
        #expect(owner.state.mode == .sharing(people: 1))
        owner.state.stoppedSharing()
        #expect(owner.state.mode == .own)
        #expect(owner.state.database == .private)
    }

    // MARK: - Joining

    @Test func joiningMovesTheGuestsSpacesInAndBringsTheOwnersSpacesBothWays() throws {
        var (owner, guest, work, side, sideTab, zones) = try setUp()
        join(&guest, &zones, now: later(10))
        zones.sync(&guest, now: later(10))
        guest.state.endRefetch()
        zones.deletePrivate(&guest)

        #expect(guest.tree.space(work.space)?.name == "Work")
        #expect(zones.owner.records[side] != nil)
        #expect(zones.owner.records[sideTab] != nil)
        #expect(zones.guest.records[side] == nil)
        #expect(zones.guest.records[sideTab] == nil)
        #expect(guest.state.sharing?.moving.isEmpty == true)

        owner.sync(&zones.owner, now: later(20))
        #expect(owner.tree.space(side)?.name == "Side")
        #expect(owner.tree.item(sideTab)?.displayTitle == "Side tab")

        try owner.tree.rename(work.wiki, customTitle: "From the owner", now: later(30))
        owner.sync(&zones.owner, now: later(30))
        try guest.tree.rename(work.mail, customTitle: "From the guest", now: later(40))
        zones.sync(&guest, now: later(40))
        owner.sync(&zones.owner, now: later(50))

        for mac in [owner, guest] {
            #expect(mac.tree.item(work.wiki)?.customTitle == "From the owner")
            #expect(mac.tree.item(work.mail)?.customTitle == "From the guest")
        }
        #expect(guest.state.cloudDevices == ["iMac", "MacBook"])
    }

    @Test func aSharedUploadThatStopsMidwayDeletesNothingFromTheGuestsZone() throws {
        var (_, guest, _, side, sideTab, zones) = try setUp()
        join(&guest, &zones, now: later(10))
        #expect(guest.pending.saves.isSuperset(of: [side, sideTab]))
        #expect(guest.state.privateDeletions(in: guest.tree).isEmpty)

        let first = guest.state.outgoing([side], in: guest.tree, now: later(10), device: guest.device)
        guest.state.didSend(saved: Array(first.values), systemFields: [side: Data("tag".utf8)], deleted: [], now: later(10))
        #expect(guest.state.privateDeletions(in: guest.tree).isEmpty)

        let reopened = try JSONDecoder().decode(SpaceSyncState.self, from: JSONEncoder().encode(guest.state))
        #expect(reopened.sharing?.moving[side] == [side, sideTab])
        #expect(reopened.privateDeletions(in: guest.tree).isEmpty)
        #expect(zones.guest.records[side] != nil)
        #expect(zones.guest.records[sideTab] != nil)

        guest.state = reopened
        let rest = guest.state.outgoing([sideTab], in: guest.tree, now: later(20), device: guest.device)
        guest.state.didSend(saved: Array(rest.values), systemFields: [sideTab: Data("tag".utf8)], deleted: [], now: later(20))
        #expect(guest.state.privateDeletions(in: guest.tree) == [side, sideTab])
    }

    @Test func aSpaceTurnedOffBeforeItReachedTheSharedZoneKeepsItsRecordsInTheGuestsZone() throws {
        var (_, guest, _, side, _, zones) = try setUp()
        join(&guest, &zones, now: later(10))
        guest.state.setLevel(.off, for: side, now: later(11))
        guest.state.prune(against: guest.tree)

        #expect(guest.state.privateDeletions(in: guest.tree).isEmpty)
        #expect(guest.state.sharing?.moving[side] == nil)
    }

    // MARK: - Ending

    @Test func leavingTurnsEverySpaceOffAndKeepsThemOnThisMac() throws {
        var (_, guest, work, side, _, zones) = try setUp()
        join(&guest, &zones, now: later(10))
        zones.sync(&guest, now: later(10))
        let tree = guest.tree

        guest.state.leaveSharedZone()

        #expect(guest.tree == tree)
        #expect(guest.tree.space(work.space) != nil)
        #expect(guest.state.level(of: work.space) == .off)
        #expect(guest.state.level(of: side) == .off)
        #expect(guest.state.account == Self.guestAccount)
        #expect(guest.state.engine == nil)
        #expect(guest.pending == ([], []))
    }

    @Test func theOwnerStoppingSharingTurnsTheGuestsSpacesOffAndDeletesNothing() throws {
        var (owner, guest, work, side, _, zones) = try setUp()
        join(&guest, &zones, now: later(10))
        zones.sync(&guest, now: later(10))
        owner.state.stoppedSharing()
        let tree = guest.tree

        guest.state.zoneLost(reuploading: false)

        #expect(guest.tree == tree)
        #expect(guest.state.database == .private)
        #expect(guest.state.level(of: work.space) == .off)
        #expect(guest.state.level(of: side) == .off)
        #expect(guest.pending == ([], []))
        #expect(owner.state.mode == .own)
    }

    @Test func anAccountChangeWhileJoinedGoesBackToTheNewAccountsOwnZone() throws {
        var (_, guest, _, side, _, zones) = try setUp()
        join(&guest, &zones, now: later(10))

        guest.state.reset(account: "_another")

        #expect(guest.state.database == .private)
        #expect(guest.state.sharing == nil)
        #expect(guest.state.level(of: side) == .off)
    }

    @Test func theReportSaysWhoseZoneThisMacSyncsWithoutNames() throws {
        var (owner, guest, _, _, _, zones) = try setUp()
        let shared = owner.state.reportText(account: Self.ownerAccount)
        #expect(shared.contains("Zone: this account's, shared, participants: 1"))
        #expect(!shared.contains("Guest"))

        join(&guest, &zones, now: later(10))
        let joined = guest.state.reportText(account: Self.guestAccount)
        #expect(joined.contains("Zone: joined, owner account ID e62a57"))
        #expect(!joined.contains("Vladimir"))
        #expect(!joined.contains(Self.ownerAccount))
    }

    // MARK: - Accepting

    @Test func aSharingLinkIsReadFromWhatThePersonPastes() {
        let link = "https://www.icloud.com/share/0aBcD_eFgHiJkLmNoPqRsTuVw#Nook_Spaces"
        #expect(SpaceSyncShareLink.parse(link)?.absoluteString == link)
        #expect(SpaceSyncShareLink.parse("  \(link)\n")?.absoluteString == link)
        #expect(SpaceSyncShareLink.parse("www.icloud.com/share/0aBcD")?.absoluteString == "https://www.icloud.com/share/0aBcD")
        #expect(SpaceSyncShareLink.parse("https://icloud.com/share/0aBcD")?.host == "icloud.com")
        for bad in ["", "hello", "https://www.icloud.com/share/", "https://www.icloud.com/notes/0aBcD",
                    "https://example.com/share/0aBcD", "http://www.icloud.com/share/0aBcD", "https://www.icloud.com.evil.com/share/x"] {
            #expect(SpaceSyncShareLink.parse(bad) == nil, "accepted \(bad)")
        }
    }

    @Test func aShareIsJoinedOnlyWhenItIsAnotherAccountsSpacesZone() throws {
        var (owner, guest, _, _, _, zones) = try setUp()
        let container = SpaceSyncAvailability.containerID, zone = SpaceSyncAvailability.zoneName

        #expect(owner.state.acceptance(containerID: container, zoneName: zone, zoneOwner: Self.ownerAccount, isOwner: true) == .ownShare)
        #expect(guest.state.acceptance(containerID: "iCloud.other", zoneName: zone, zoneOwner: Self.ownerAccount, isOwner: false) == .notASpacesShare)
        #expect(guest.state.acceptance(containerID: container, zoneName: "Other", zoneOwner: Self.ownerAccount, isOwner: false) == .notASpacesShare)
        #expect(owner.state.acceptance(containerID: container, zoneName: zone, zoneOwner: Self.guestAccount, isOwner: false) == .sharingOwnZone)
        join(&guest, &zones, now: later(10))
        #expect(guest.state.acceptance(containerID: container, zoneName: zone, zoneOwner: Self.ownerAccount, isOwner: false) == .alreadyJoined)
        #expect(guest.state.acceptance(containerID: container, zoneName: zone, zoneOwner: "_third", isOwner: false) == .alreadyJoined)
    }
}
