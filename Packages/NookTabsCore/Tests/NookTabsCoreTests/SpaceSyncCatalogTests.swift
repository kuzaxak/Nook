// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
@testable import NookTabsCore

/// What iCloud holds as Settings lists it: every space record in the account's zone with its
/// state here, the Macs that changed them, removing a space from iCloud, and the sync report.
struct SpaceSyncCatalogTests {
    typealias Key = SyncRecord.Key
    typealias Mac = SpaceSyncTests.Mac
    typealias Cloud = SpaceSyncTests.Cloud
    typealias Work = SpaceSyncTests.Work

    private func later(_ seconds: TimeInterval) -> Date { fixedNow.addingTimeInterval(seconds) }

    /// Mac A ("iMac") syncs Work at Favorites & Pinned and Shared at Everything. Mac B
    /// ("MacBook") has its own copy of Shared, same id, Off, and a first-launch space.
    private func setUp() throws -> (a: Mac, b: Mac, work: Work, shared: UUID, cloud: Cloud) {
        var work = try Work()
        let shared = UUID(), sharedTab = UUID()
        work.tree.createSpace(id: shared, name: "Shared", icon: "", accentHex: "#112233", after: work.space, now: fixedNow)
        try work.tree.createTab(id: sharedTab, url: url("shared"), title: "Shared tab", in: .pinned(spaceID: shared), after: nil, now: fixedNow)
        var cloud = Cloud()
        var a = Mac(work.tree)
        a.device = "iMac"
        a.state.setLevel(.pinned, for: work.space, now: fixedNow)
        a.state.setLevel(.everything, for: shared, now: fixedNow)
        a.sync(&cloud)

        var tree = TabTree.firstLaunch(homeURL: url("home"), now: fixedNow)
        tree.createSpace(id: shared, name: "Shared here", icon: "", accentHex: "#445566", after: nil, now: later(-100))
        var b = Mac(tree)
        b.device = "MacBook"
        b.sync(&cloud)
        return (a, b, work, shared, cloud)
    }

    private func row(_ mac: Mac, _ id: UUID) -> SpaceSyncCloudSpace? {
        mac.state.cloudSpaces(in: mac.tree).first { $0.id == id }
    }

    // MARK: - The list

    @Test func theListHoldsEverySpaceInICloudWithWhoChangedItAndItsStateHere() throws {
        let (_, b, work, shared, _) = try setUp()

        let rows = b.state.cloudSpaces(in: b.tree)
        #expect(Set(rows.map(\.id)) == [work.space, shared])
        let workRow = try #require(row(b, work.space))
        #expect(workRow.name == "Work")
        #expect(workRow.profile == "Job")
        #expect(workRow.device == "iMac")
        #expect(workRow.itemCount == work.pinnedIDs.count - 1)
        #expect(workRow.changedAt == fixedNow)
        #expect(workRow.state == .syncing(.pinned))
        let sharedRow = try #require(row(b, shared))
        #expect(sharedRow.name == "Shared")
        #expect(sharedRow.itemCount == 1)
        #expect(sharedRow.state == .offHere)
        #expect(b.state.cloudDevices == ["iMac"])
    }

    @Test func aSpaceFetchedAndNotYetAppliedIsArriving() throws {
        let work = try Work()
        var cloud = Cloud()
        var a = Mac(work.tree)
        a.state.setLevel(.pinned, for: work.space, now: fixedNow)
        a.sync(&cloud)
        var b = Mac(TabTree.firstLaunch(homeURL: url("home"), now: fixedNow))
        for entry in cloud.records.values { b.state.fetched(entry.record, systemFields: entry.tag) }

        #expect(row(b, work.space)?.state == .arriving)
        b.apply(fixedNow)
        #expect(row(b, work.space)?.state == .syncing(.pinned))
    }

    @Test func aSyncedSpaceWithATabTooLargeForICloudShowsAnError() throws {
        var (a, _, work, _, _) = try setUp()
        try a.tree.rename(work.wiki, customTitle: String(repeating: "x", count: 1_100_000), now: later(10))

        guard case .error? = row(a, work.space)?.state else {
            Issue.record("expected an error, got \(String(describing: row(a, work.space)?.state))")
            return
        }
    }

    @Test func theMacsThatChangedSpacesAreListedOnceEach() throws {
        var (_, b, _, _, cloud) = try setUp()
        let side = UUID()
        b.tree.createSpace(id: side, name: "Side", icon: "", accentHex: "#000000", after: nil, now: later(5))
        b.state.setLevel(.pinned, for: side, now: later(5))
        b.sync(&cloud, now: later(5))

        #expect(b.state.cloudDevices == ["iMac", "MacBook"])
        #expect(row(b, side)?.device == "MacBook")
    }

    // MARK: - Off here

    @Test func aSpaceOffHereIsNotAppliedAndKeepsItsNameHere() throws {
        let (_, b, _, shared, _) = try setUp()

        #expect(b.tree.space(shared)?.name == "Shared here")
        #expect(b.tree.children(of: .pinned(spaceID: shared)).isEmpty)
        #expect(b.state.level(of: shared) == .off)
        #expect(b.state.report?.decisions[shared]?.reason == .offHere)
    }

    @Test func syncHereTakesInASpaceOffHereAndMergesItByTime() throws {
        var (_, b, _, shared, cloud) = try setUp()
        let fromOff = b.state.setLevel(.pinned, for: shared, now: later(10))
        #expect(fromOff)
        b.refetch(cloud, now: later(10))
        b.send(&cloud, now: later(10))

        #expect(b.tree.space(shared)?.name == "Shared")
        #expect(b.tree.children(of: .pinned(spaceID: shared)).map(\.displayTitle) == ["Shared tab"])
        #expect(row(b, shared)?.state == .syncing(.pinned))
    }

    @Test func syncHereForASpaceNotOnThisMacBringsItInAtTheChosenLevel() throws {
        let work = try Work()
        var cloud = Cloud()
        var a = Mac(work.tree)
        a.state.setLevel(.pinned, for: work.space, now: fixedNow)
        a.sync(&cloud)
        var b = Mac(TabTree.firstLaunch(homeURL: url("home"), now: fixedNow))
        for entry in cloud.records.values { b.state.fetched(entry.record, systemFields: entry.tag) }
        b.state.setLevel(.off, for: work.space, now: fixedNow)
        b.apply(fixedNow)
        #expect(b.tree.space(work.space) == nil)
        #expect(row(b, work.space)?.state == .offHere)

        b.state.setLevel(.everything, for: work.space, now: later(10))
        b.state.prune(against: b.tree)
        #expect(row(b, work.space)?.state == .arriving)
        b.refetch(cloud, now: later(10))

        #expect(b.tree.space(work.space)?.name == "Work")
        #expect(b.state.level(of: work.space) == .everything)
    }

    // MARK: - Removing from iCloud

    @Test func removeFromICloudDeletesTheSpacesRecordsThereAndKeepsItHereOff() throws {
        var (a, b, work, _, cloud) = try setUp()
        let ids = Set(cloud.records.values.filter { $0.record.id == work.space || $0.record.uuid(Key.space) == work.space }.map(\.record.id))
        #expect(ids.count == work.pinnedIDs.count)

        b.state.removeFromICloud(work.space, now: later(10))
        #expect(b.pending.deletes == ids)
        #expect(b.pending.saves.isEmpty)
        b.send(&cloud, now: later(10))

        #expect(ids.allSatisfy { cloud.records[$0] == nil })
        #expect(b.tree.space(work.space) != nil)
        #expect(b.state.level(of: work.space) == .off)
        #expect(row(b, work.space) == nil)
        #expect(b.state.catalog?.removing.isEmpty == true)
        #expect(b.pending == ([], []))

        let inbound = a.fetch(cloud, now: later(20))
        #expect(inbound.deletedSpaces == [work.space])
    }

    // MARK: - Report

    @Test func theReportCountsDecisionsWithIDsAndNoNamesAddressesOrTitles() throws {
        let (_, b, work, shared, _) = try setUp()
        let report = b.state.reportText(account: "_48e607c1179693a062ca0aefa4e62a57", now: later(30))

        #expect(report.contains("Account ID: e62a57"))
        #expect(!report.contains("_48e607c1179693a062ca0aefa4e62a57"))
        #expect(report.contains(work.space.uuidString))
        #expect(report.contains(shared.uuidString))
        #expect(report.contains("skipped offHere"))
        #expect(report.contains("Applied: \(work.pinnedIDs.count)"))
        for secret in ["Work", "Job", "Shared", "Mail", "Calendar", "The spec", "Docs", "example.com", "https", "iMac", "MacBook"] {
            #expect(!report.contains(secret), "report holds \(secret)")
        }
    }

    @Test func theAccountIDIsTheLastSixCharactersOfTheUserRecordName() {
        #expect(SpaceSyncCodec.accountID("_48e607c1179693a062ca0aefa4e62a57") == "e62a57")
        #expect(SpaceSyncCodec.accountID("abc") == "abc")
    }

    // MARK: - Stored state

    @Test func aStateSavedBeforeTheListStillLoadsWithItsLevels() throws {
        let space = UUID()
        let json = """
        {"levels":["\(space.uuidString)","pinned"],"levelTimes":[],"shadow":[],"systemFields":[],"deletedInCloud":[],
         "account":"_abc","inbox":{"records":[],"systemFields":[],"deletions":[]}}
        """
        let state = try JSONDecoder().decode(SpaceSyncState.self, from: Data(json.utf8))

        #expect(state.level(of: space) == .pinned)
        #expect(state.account == "_abc")
        #expect(state.catalog == nil)
    }
}
