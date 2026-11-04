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

    /// The owner's zone, which it shares, and the guest account's own zone.
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

        /// Writes the move marker on these space records in the guest's zone, as the app does
        /// before a Mac joins and moves its spaces.
        mutating func mark(_ spaces: Set<UUID>, movedTo owner: String) {
            for id in spaces {
                guard var entry = guest.records[id] else { continue }
                entry.record.fields[Key.movedTo] = .string(owner)
                entry.tag = Data("\(guest.nextTag)".utf8)
                guest.nextTag += 1
                guest.records[id] = entry
                guest.journal.append(id)
            }
        }
    }

    /// The owner syncs Work in its zone and shares it; the guest Mac ("MacBook") syncs its own
    /// Side space in the guest account's zone.
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

    /// A second Mac ("Mac mini") on the guest's account, which takes in Side.
    private func secondGuestMac(_ zones: inout Zones) -> Mac {
        var mac = Mac(TabTree.firstLaunch(homeURL: url("home"), now: fixedNow))
        mac.device = "Mac mini"
        mac.state.account = Self.guestAccount
        zones.sync(&mac, now: fixedNow)
        return mac
    }

    /// The guest joins the owner's zone as the app does once the person agrees: it marks the
    /// spaces it moves in its own zone, joins, writes what was still waiting, and fetches
    /// everything in the owner's zone.
    private func join(_ guest: inout Mac, _ zones: inout Zones, moving: Bool = true, now: Date) {
        let decision = guest.state.acceptance(containerID: SpaceSyncAvailability.containerID, zoneName: SpaceSyncAvailability.zoneName,
                                              zoneOwner: Self.ownerAccount, isOwner: false)
        #expect(decision == .join(owner: Self.ownerAccount))
        if moving { zones.mark(guest.state.markedOnMove(in: guest.tree), movedTo: Self.ownerAccount) }
        let inbound = guest.state.join(owner: Self.ownerAccount, ownerName: "Vladimir", moving: moving, tree: guest.tree, now: now)
        guest.tree.apply(inbound.change)
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

        guest.state.leaveSharedZone(in: guest.tree)
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

    @Test func joiningMovesTheGuestsSpacesInBothWaysAndDeletesNothingFromTheGuestsZone() throws {
        var (owner, guest, work, side, sideTab, zones) = try setUp()
        join(&guest, &zones, now: later(10))
        zones.sync(&guest, now: later(10))
        guest.state.endRefetch()

        #expect(guest.tree.space(work.space)?.name == "Work")
        #expect(zones.owner.records[side] != nil)
        #expect(zones.owner.records[sideTab] != nil)
        #expect(zones.guest.records[side]?.record.string(Key.movedTo) == Self.ownerAccount)
        #expect(zones.guest.records[sideTab] != nil)

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

    @Test func anotherMacOnTheGuestsAccountTurnsAMovedSpaceOffAndKeepsIt() throws {
        var (_, guest, _, side, sideTab, zones) = try setUp()
        var mini = secondGuestMac(&zones)
        #expect(mini.tree.item(sideTab) != nil)

        join(&guest, &zones, now: later(10))
        mini.sync(&zones.guest, now: later(20))

        #expect(mini.tree.space(side)?.name == "Side")
        #expect(mini.tree.item(sideTab)?.displayTitle == "Side tab")
        #expect(mini.state.level(of: side) == .off)
        #expect(mini.state.sharing?.moved[side] == Self.ownerAccount)
        #expect(mini.state.report?.decisions[side]?.reason == .movedAway)
        #expect(mini.state.cloudSpaces(in: mini.tree).first { $0.id == side }?.state == .moved)
        #expect(mini.pending == ([], []))
        #expect(zones.guest.records[side] != nil)
        #expect(zones.guest.records[sideTab] != nil)
    }

    @Test func theOldCopyGoesOnlyWhenRemovedAndTheOtherGuestMacKeepsTheSpace() throws {
        var (_, guest, _, side, sideTab, zones) = try setUp()
        var mini = secondGuestMac(&zones)
        try mini.tree.rename(sideTab, customTitle: "Renamed on the mini", now: later(5))
        mini.state.setLevel(.pinned, for: side, now: later(5))
        mini.sync(&zones.guest, now: later(5))
        zones.sync(&guest, now: later(6))

        join(&guest, &zones, now: later(10))
        zones.sync(&guest, now: later(10))
        mini.sync(&zones.guest, now: later(15))
        #expect(guest.state.oldCopies == SpaceSyncLeftBehind(spaces: 1, devices: ["Mac mini", "MacBook"]))
        #expect(zones.guest.records[side] != nil)

        let ids = guest.state.oldCopyRecords
        #expect(ids == [side, sideTab])
        for id in ids {
            zones.guest.records[id] = nil
            zones.guest.journal.append(id)
        }
        guest.state.removedOldCopies(ids)
        mini.state.setLevel(.pinned, for: side, now: later(16))
        mini.sync(&zones.guest, now: later(20))

        #expect(guest.state.oldCopies == nil)
        #expect(mini.tree.space(side) != nil)
        #expect(mini.tree.item(sideTab)?.customTitle == "Renamed on the mini")
        #expect(mini.state.report?.decisions[side]?.reason == .movedAway)
    }

    @Test func joiningWritesChangesFetchedButNotYetAppliedFirst() throws {
        var (_, guest, _, side, sideTab, zones) = try setUp()
        var mini = secondGuestMac(&zones)
        mini.state.setLevel(.pinned, for: side, now: later(4))
        try mini.tree.rename(sideTab, customTitle: "Waiting", now: later(5))
        mini.sync(&zones.guest, now: later(5))
        let waiting = try #require(zones.guest.records[sideTab])
        guest.state.fetched(waiting.record, systemFields: waiting.tag)

        join(&guest, &zones, now: later(10))
        zones.sync(&guest, now: later(10))

        #expect(guest.tree.item(sideTab)?.customTitle == "Waiting")
        #expect(zones.owner.records[sideTab]?.record.string(Key.customTitle) == "Waiting")
    }

    @Test func joiningWithoutMovingTurnsThisMacsSpacesOffAndLeavesThemToItsAccount() throws {
        var (_, guest, work, side, sideTab, zones) = try setUp()
        var mini = secondGuestMac(&zones)
        #expect(guest.state.markedOnMove(in: guest.tree) == [side])

        join(&guest, &zones, moving: false, now: later(10))
        zones.sync(&guest, now: later(10))
        mini.sync(&zones.guest, now: later(20))

        #expect(guest.state.level(of: side) == .off)
        #expect(guest.tree.item(sideTab) != nil)
        #expect(guest.tree.space(work.space) != nil)
        #expect(zones.owner.records[side] == nil)
        #expect(zones.guest.records[side]?.record.string(Key.movedTo) == nil)
        #expect(guest.state.oldCopies == nil)
        #expect(mini.state.level(of: side) == .pinned)
    }

    // MARK: - Ending

    @Test func leavingTurnsEverySpaceOffAndKeepsThemOnThisMac() throws {
        var (_, guest, work, side, _, zones) = try setUp()
        join(&guest, &zones, now: later(10))
        zones.sync(&guest, now: later(10))
        let tree = guest.tree

        guest.state.leaveSharedZone(in: guest.tree)

        #expect(guest.tree == tree)
        #expect(guest.tree.space(work.space) != nil)
        #expect(guest.state.level(of: work.space) == .off)
        #expect(guest.state.level(of: side) == .off)
        #expect(guest.state.levels[work.space] == .off)
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

        guest.state.zoneLost(reuploading: false, in: guest.tree)

        #expect(guest.tree == tree)
        #expect(guest.state.database == .private)
        #expect(guest.state.level(of: work.space) == .off)
        #expect(guest.state.level(of: side) == .off)
        #expect(guest.pending == ([], []))
        #expect(owner.state.mode == .own)
    }

    /// Leaving, or the owner ending the share, then fetching this account's zone again: a space
    /// this Mac had Off, here one it deleted before joining whose tombstone is long gone, stays out.
    @Test(arguments: [false, true])
    func afterTheSharedSyncEndsASpaceOffBeforeStaysOut(ownerStopped: Bool) throws {
        var (_, guest, work, side, _, zones) = try setUp()
        var mini = secondGuestMac(&zones)
        let old = UUID()
        mini.tree.createSpace(id: old, name: "Old", icon: "", accentHex: "#000000", after: nil, now: fixedNow)
        mini.state.setLevel(.pinned, for: old, now: fixedNow)
        mini.sync(&zones.guest, now: later(1))
        zones.sync(&guest, now: later(2))
        #expect(guest.tree.space(old) != nil)
        guest.state.setLevel(.off, for: old, now: later(3))
        _ = try guest.tree.deleteSpace(old, now: later(3))
        guest.state.prune(against: guest.tree)
        guest.tree.repair(now: later(4 + TabTree.tombstoneLifetime))
        #expect(guest.tree.spaces[old] == nil)

        join(&guest, &zones, now: later(10))
        zones.sync(&guest, now: later(10))
        if ownerStopped {
            guest.state.zoneLost(reuploading: false, in: guest.tree)
        } else {
            guest.state.leaveSharedZone(in: guest.tree)
        }
        guest.cursor = 0
        guest.refetch(zones.guest, now: later(20))

        #expect(guest.tree.spaces[old] == nil)
        #expect(guest.state.level(of: old) == .off)
        #expect(guest.state.level(of: side) == .off)
        #expect(guest.state.level(of: work.space) == .off)
        #expect(guest.tree.space(work.space) != nil)
        #expect(guest.pending == ([], []))
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
        #expect(joined.contains("Old copies in this account's zone: 1 spaces, 2 records"))
        #expect(!joined.contains("Vladimir"))
        #expect(!joined.contains("MacBook"))
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
