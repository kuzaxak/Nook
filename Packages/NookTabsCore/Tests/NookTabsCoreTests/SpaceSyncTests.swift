// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
@testable import NookTabsCore

/// Spaces kept in iCloud: the records a space becomes, how two Macs' edits merge, what never
/// leaves a Mac, and the sync state each Mac keeps.
struct SpaceSyncTests {
    typealias Key = SyncRecord.Key

    /// iCloud as the tests see it: the latest record per id with a change tag, and a journal Macs
    /// fetch from. A save made from an out-of-date tag is refused with the server's record, and a
    /// save of a record the server no longer has is refused as deleted, as CloudKit does.
    struct Cloud {
        var records: [UUID: (record: SyncRecord, tag: Data)] = [:]
        var journal: [UUID] = []
        var nextTag = 1
    }

    /// One Mac: its tree and sync state, fetching and sending the way the app's engine does.
    struct Mac {
        var tree: TabTree
        var state = SpaceSyncState()
        var kept: [KeptProfile] = []
        var cursor = 0

        init(_ tree: TabTree) { self.tree = tree }

        @discardableResult
        mutating func fetch(_ cloud: Cloud, now: Date = fixedNow) -> SpaceSyncInbound {
            for id in Set(cloud.journal[cursor...]) {
                if let entry = cloud.records[id] {
                    state.fetched(entry.record, systemFields: entry.tag)
                } else {
                    state.fetchedDeletion(id)
                }
            }
            cursor = cloud.journal.count
            return apply(now)
        }

        @discardableResult
        mutating func apply(_ now: Date) -> SpaceSyncInbound {
            let inbound = state.receive(into: tree, kept: kept, now: now)
            tree.apply(inbound.change)
            for id in inbound.deletedSpaces { _ = try? tree.deleteSpace(id, now: now) }
            state.prune(against: tree)
            return inbound
        }

        mutating func send(_ cloud: inout Cloud, now: Date = fixedNow) {
            for _ in 0..<5 {
                state.prune(against: tree)
                let pending = state.pendingChanges(in: tree)
                guard !pending.saves.isEmpty || !pending.deletes.isEmpty else { return }
                var saved: [SyncRecord] = []
                var tags: [UUID: Data] = [:]
                var refused = false
                for record in state.outgoing(pending.saves, in: tree, now: now).values {
                    if let server = cloud.records[record.id], state.systemFields[record.id] != server.tag {
                        state.inbox.add(server.record, systemFields: server.tag)
                        refused = true
                        continue
                    }
                    if cloud.records[record.id] == nil, state.systemFields[record.id] != nil {
                        state.inbox.delete(record.id)
                        refused = true
                        continue
                    }
                    let tag = Data("\(cloud.nextTag)".utf8)
                    cloud.nextTag += 1
                    cloud.records[record.id] = (record, tag)
                    cloud.journal.append(record.id)
                    saved.append(record)
                    tags[record.id] = tag
                }
                for id in pending.deletes {
                    cloud.records[id] = nil
                    cloud.journal.append(id)
                }
                state.didSend(saved: saved, systemFields: tags, deleted: Array(pending.deletes), now: now)
                if refused { apply(now) }
            }
            Issue.record("sending did not settle")
        }

        /// What a new engine fetches: every record iCloud has, and no deletions.
        mutating func refetch(_ cloud: Cloud, now: Date = fixedNow) {
            state.beginRefetch()
            for entry in cloud.records.values { state.fetched(entry.record, systemFields: entry.tag) }
            cursor = cloud.journal.count
            apply(now)
            state.endRefetch()
        }

        mutating func sync(_ cloud: inout Cloud, now: Date = fixedNow) {
            fetch(cloud, now: now)
            send(&cloud, now: now)
        }

        var pending: (saves: Set<UUID>, deletes: Set<UUID>) { state.pendingChanges(in: tree) }
    }

    /// "Work" in its own profile "Job", beside an unsynced "Home": two favorites, a pinned folder
    /// holding a renamed tab and a folder with a tab, a pinned tab, and two open tabs where one
    /// opened a third.
    struct Work {
        var tree = TabTree()
        let home = UUID(), space = UUID()
        let mail = UUID(), calendar = UUID(), docs = UUID(), spec = UUID(), archive = UUID(), old = UUID(), wiki = UUID()
        let search = UUID(), result = UUID(), news = UUID()

        init() throws {
            tree.createSpace(id: home, name: "Home", icon: "house", accentHex: "#7C7C7C", after: nil, now: fixedNow)
            tree.createSpace(id: space, name: "Work", icon: "💼", accentHex: "#336699", after: home, profileName: "Job", now: fixedNow)
            try tree.setTheme(space, theme: SpaceTheme(points: [.init(hue: 200, saturation: 0.8)], mode: .dark, intensity: 0.4, grain: 0.3), now: fixedNow)
            try tree.createTab(id: mail, url: url("mail"), title: "Mail", in: .favorites(spaceID: space), after: nil, now: fixedNow)
            try tree.createTab(id: calendar, url: url("calendar"), title: "Calendar", in: .favorites(spaceID: space), after: mail, now: fixedNow)
            try tree.createFolder(id: docs, title: "Docs", in: .pinned(spaceID: space), after: nil, now: fixedNow)
            try tree.createTab(id: spec, url: url("spec"), title: "Spec", in: .folder(itemID: docs), after: nil, now: fixedNow)
            try tree.rename(spec, customTitle: "The spec", now: fixedNow)
            try tree.createFolder(id: archive, title: "Archive", in: .folder(itemID: docs), after: spec, now: fixedNow)
            try tree.createTab(id: old, url: url("old"), title: "Old", in: .folder(itemID: archive), after: nil, now: fixedNow)
            try tree.createTab(id: wiki, url: url("wiki"), title: "Wiki", in: .pinned(spaceID: space), after: docs, now: fixedNow)
            try tree.createTab(id: search, url: url("search"), title: "Search", in: .tabs(spaceID: space), after: nil, now: fixedNow)
            try tree.createTab(id: result, url: url("result"), title: "Result", in: .folder(itemID: search), after: nil, now: fixedNow)
            try tree.createTab(id: news, url: url("news"), title: "News", in: .tabs(spaceID: space), after: search, now: fixedNow)
        }

        var pinnedIDs: Set<UUID> { [space, mail, calendar, docs, spec, archive, old, wiki] }
        var openTabIDs: Set<UUID> { [search, result, news] }
    }

    /// Mac A sends Work at `level` and Mac B, a first launch, receives it; both then agree on
    /// every record.
    private func pair(_ level: SpaceSyncLevel) throws -> (a: Mac, b: Mac, work: Work, cloud: Cloud) {
        let work = try Work()
        var cloud = Cloud()
        var a = Mac(work.tree)
        a.state.setLevel(level, for: work.space, now: fixedNow)
        a.sync(&cloud)
        var b = Mac(TabTree.firstLaunch(homeURL: url("home"), now: fixedNow))
        b.sync(&cloud)
        a.fetch(cloud)
        return (a, b, work, cloud)
    }

    private func later(_ seconds: TimeInterval) -> Date { fixedNow.addingTimeInterval(seconds) }

    /// Every item's parent and title in a space, for comparing two Macs; open tabs only with
    /// `openTabs`.
    private func layout(_ tree: TabTree, _ space: UUID, openTabs: Bool = true) -> [String] {
        tree.items.values.filter { $0.deletedAt == nil && tree.spaceID(of: $0.id) == space }
            .filter { openTabs || tree.section(of: $0.id) != .tabs(spaceID: space) }
            .map { "\($0.displayTitle) in \($0.parent) at \($0.order)" }.sorted()
    }

    // MARK: - Records

    @Test func favoritesAndPinnedSendsTheSpaceItsFavoritesPinnedTabsAndFolders() throws {
        let work = try Work()
        var state = SpaceSyncState()
        state.setLevel(.pinned, for: work.space, now: fixedNow)
        let records = state.records(of: work.tree)

        #expect(Set(records.keys) == work.pinnedIDs)
        let space = try #require(records[work.space])
        let local = try #require(work.tree.space(work.space))
        #expect(space.type == .space)
        #expect(space.string(Key.name) == "Work")
        #expect(space.string(Key.icon) == "💼")
        #expect(space.string(Key.accent) == local.accentHex)
        #expect(space.string(Key.profile) == "Job")
        #expect(space.string(Key.level) == "pinned")
        #expect(space.string(Key.order) == local.order.rawValue)
        #expect(space.bytes(Key.theme).flatMap(SpaceSyncCodec.theme) == local.theme)

        let order = { (id: UUID) in work.tree.items[id]!.order.rawValue }
        #expect(records[work.spec]?.fields == [
            Key.space: .string(work.space.uuidString), Key.section: .string("pinned"), Key.kind: .string("tab"),
            Key.parent: .string(work.docs.uuidString), Key.order: .string(order(work.spec)),
            Key.url: .string(url("spec").absoluteString), Key.title: .string("Spec"), Key.customTitle: .string("The spec"),
        ])
        #expect(records[work.docs]?.fields == [
            Key.space: .string(work.space.uuidString), Key.section: .string("pinned"), Key.kind: .string("folder"),
            Key.order: .string(order(work.docs)), Key.title: .string("Docs"),
        ])
        #expect(records[work.old]?.uuid(Key.parent) == work.archive)
        #expect(records[work.mail]?.string(Key.section) == "favorites")
        #expect(records[work.mail]?.uuid(Key.parent) == nil)
    }

    @Test func everythingAlsoSendsOpenTabsTheirOrderAndTheTabsTheyOpened() throws {
        let work = try Work()
        var state = SpaceSyncState()
        state.setLevel(.everything, for: work.space, now: fixedNow)
        let records = state.records(of: work.tree)

        #expect(Set(records.keys) == work.pinnedIDs.union(work.openTabIDs))
        #expect(records[work.space]?.string(Key.level) == "everything")
        #expect(records[work.search]?.string(Key.section) == "tabs")
        #expect(records[work.search]?.uuid(Key.parent) == nil)
        #expect(records[work.result]?.uuid(Key.parent) == work.search)
        #expect(records[work.news]?.string(Key.order) == work.tree.items[work.news]?.order.rawValue)
    }

    @Test(arguments: [SpaceSyncLevel.pinned, .everything])
    func aSpaceArrivesWholeOnAnotherMac(level: SpaceSyncLevel) throws {
        let (a, b, work, _) = try pair(level)

        var expected = try #require(a.tree.spaceSnapshot(work.space))
        if level == .pinned { expected.tabs = [] }
        #expect(b.tree.spaceSnapshot(work.space) == expected)
        #expect(b.tree.space(work.space)?.order == a.tree.space(work.space)?.order)
        #expect(b.state.level(of: work.space) == level)
        #expect(b.tree.space(work.home) == nil)
        checkInvariants(b.tree)
    }

    // MARK: - Never synced

    @Test func agentSpaceLiveFoldersOtherLinksAndOtherSpacesFavoritesStayOnThisMac() throws {
        var work = try Work()
        let live = UUID(), page = UUID(), file = UUID(), opened = UUID(), side = UUID(), sideFavorite = UUID()
        try work.tree.createFolder(id: live, title: "PRs", in: .pinned(spaceID: work.space), after: nil, live: .githubPulls, now: fixedNow)
        try work.tree.createTab(id: page, url: url("pr"), title: "PR", in: .folder(itemID: live), after: nil, now: fixedNow)
        try work.tree.createTab(id: file, url: URL(string: "file:///Users/me/notes.html")!, title: "Notes", in: .tabs(spaceID: work.space), after: nil, now: fixedNow)
        try work.tree.createTab(id: opened, url: url("opened"), title: "Opened", in: .folder(itemID: file), after: nil, now: fixedNow)
        work.tree.createSpace(id: side, name: "Side", icon: "", accentHex: "#000000", after: work.space, dataStoreID: work.space, now: fixedNow)
        try work.tree.createTab(id: sideFavorite, url: url("side"), title: "Side", in: .favorites(spaceID: side), after: nil, now: fixedNow)
        let made = work.tree.ensureAgentSpace(loginsFrom: work.space, now: fixedNow)
        let agent = try #require(made).id
        try work.tree.createTab(url: url("agent"), title: "Agent tab", in: .tabs(spaceID: agent), after: nil, now: fixedNow)

        var state = SpaceSyncState()
        state.setLevel(.everything, for: work.space, now: fixedNow)
        state.setLevel(.everything, for: agent, now: fixedNow)
        let records = state.records(of: work.tree)

        #expect(Set(records.keys) == work.pinnedIDs.union(work.openTabIDs))
        #expect(!records.values.contains { $0.uuid(Key.space) == agent })
        #expect(work.tree.favorites(of: work.space).map(\.id).contains(sideFavorite))
    }

    @Test func recordsThisMacDoesNotKeepAreIgnored() throws {
        var (a, b, work, cloud) = try pair(.pinned)

        // An Agent space from elsewhere, and open tabs of a space this Mac keeps at Favorites &
        // Pinned once it goes back to that level.
        var agent = try #require(a.state.records(of: a.tree)[work.space])
        agent.id = UUID()
        agent.fields[Key.icon] = .string(SpaceRecord.agentIcon(loginsFrom: work.space))
        a.state.setLevel(.everything, for: work.space, now: later(5))
        a.sync(&cloud)
        let openTab = try #require(cloud.records[work.search]?.record)
        b.state.inbox.add(agent, systemFields: nil)
        b.fetch(cloud)

        #expect(b.tree.space(agent.id) == nil)
        #expect(b.state.level(of: work.space) == .everything)
        #expect(b.tree.item(openTab.id) != nil)

        b.state.setLevel(.pinned, for: work.space, now: later(10))
        let before = b.tree
        b.state.inbox.add(openTab, systemFields: nil)
        b.apply(later(10))
        #expect(b.tree == before)
    }

    // MARK: - Merging

    @Test func editsToDifferentFieldsBothSurvive() throws {
        var (a, b, work, cloud) = try pair(.pinned)
        try a.tree.rename(work.wiki, customTitle: "Team wiki", now: later(10))
        try b.tree.setURL(work.wiki, url("wiki/home"), now: later(20))
        a.sync(&cloud)
        b.sync(&cloud)
        a.sync(&cloud)

        for mac in [a, b] {
            #expect(mac.tree.item(work.wiki)?.customTitle == "Team wiki")
            #expect(mac.tree.item(work.wiki)?.url == url("wiki/home"))
        }
        #expect(a.pending == ([], []))
    }

    @Test(arguments: [true, false])
    func editsToTheSameFieldKeepTheNewer(newerSendsFirst: Bool) throws {
        var (a, b, work, cloud) = try pair(.pinned)
        try a.tree.rename(work.wiki, customTitle: "Newer", now: later(20))
        try b.tree.rename(work.wiki, customTitle: "Older", now: later(10))
        if newerSendsFirst {
            a.sync(&cloud); b.sync(&cloud); a.sync(&cloud)
        } else {
            b.sync(&cloud); a.sync(&cloud); b.sync(&cloud)
        }

        #expect(a.tree.item(work.wiki)?.customTitle == "Newer")
        #expect(b.tree.item(work.wiki)?.customTitle == "Newer")
    }

    @Test func reordersOnTwoMacsBothHold() throws {
        var (a, b, work, cloud) = try pair(.pinned)
        let chat = UUID()
        try a.tree.createTab(id: chat, url: url("chat"), title: "Chat", in: .favorites(spaceID: work.space), after: work.calendar, now: later(1))
        a.sync(&cloud)
        b.sync(&cloud)

        try a.tree.move(chat, to: .favorites(spaceID: work.space), after: nil, now: later(10))
        try b.tree.move(work.mail, to: .favorites(spaceID: work.space), after: work.calendar, now: later(20))
        a.sync(&cloud)
        b.sync(&cloud)
        a.sync(&cloud)

        let favorites = Parent.favorites(spaceID: work.space)
        #expect(a.tree.children(of: favorites).map(\.id) == [chat, work.calendar, work.mail])
        #expect(b.tree.children(of: favorites).map(\.id) == [chat, work.calendar, work.mail])
    }

    @Test(arguments: [true, false])
    func aDeletionBeatsAnEditMadeAtTheSameTime(deleterSendsFirst: Bool) throws {
        var (a, b, work, cloud) = try pair(.pinned)
        _ = try a.tree.close(work.wiki, now: later(10))
        try b.tree.rename(work.wiki, customTitle: "Edited later", now: later(20))
        if deleterSendsFirst {
            a.sync(&cloud); b.sync(&cloud); a.sync(&cloud)
        } else {
            b.sync(&cloud); a.sync(&cloud); b.sync(&cloud)
        }

        #expect(a.tree.item(work.wiki) == nil)
        #expect(b.tree.item(work.wiki) == nil)
        #expect(cloud.records[work.wiki] == nil)
        #expect(b.pending == ([], []))
    }

    @Test func folderMovesThatWouldNestTwoFoldersInEachOtherSettleTheSameOnBothMacs() throws {
        var (a, b, work, cloud) = try pair(.pinned)
        let links = UUID()
        try a.tree.createFolder(id: links, title: "Links", in: .pinned(spaceID: work.space), after: work.wiki, now: later(1))
        a.sync(&cloud)
        b.sync(&cloud)

        try a.tree.move(links, to: .folder(itemID: work.archive), after: nil, now: later(10))
        try b.tree.move(work.docs, to: .folder(itemID: links), after: nil, now: later(20))
        a.sync(&cloud)
        b.sync(&cloud)
        a.sync(&cloud)
        b.sync(&cloud)

        checkInvariants(a.tree)
        checkInvariants(b.tree)
        #expect(layout(a.tree, work.space, openTabs: false) == layout(b.tree, work.space, openTabs: false))
        // The later move made the loop, so it is the one undone.
        #expect(a.tree.item(work.docs)?.parent == .pinned(spaceID: work.space))
        #expect(a.tree.item(links)?.parent == .folder(itemID: work.archive))
        #expect(a.pending == ([], []))
        #expect(b.pending == ([], []))
    }

    @Test func aFolderMovedToTabsTakesItsContentsAlong() throws {
        var (a, b, work, cloud) = try pair(.everything)
        try a.tree.move(work.docs, to: .tabs(spaceID: work.space), after: work.news, now: later(10))
        a.sync(&cloud)
        b.sync(&cloud)

        #expect(b.tree.section(of: work.old) == .tabs(spaceID: work.space))
        #expect(b.tree.item(work.old)?.parent == .folder(itemID: work.archive))
        #expect(layout(a.tree, work.space) == layout(b.tree, work.space))
        #expect(cloud.records[work.old]?.record.string(Key.section) == "tabs")
    }

    // MARK: - Arriving spaces

    @Test func anArrivingSpaceJoinsTheProfileWithItsName() throws {
        let work = try Work()
        var cloud = Cloud()
        var a = Mac(work.tree)
        a.state.setLevel(.pinned, for: work.space, now: fixedNow)
        a.sync(&cloud)

        var tree = TabTree.firstLaunch(homeURL: url("home"), now: fixedNow)
        let side = UUID()
        tree.createSpace(id: side, name: "Side", icon: "", accentHex: "#000000", after: nil, profileName: "Job", now: fixedNow)
        var b = Mac(tree)
        b.sync(&cloud)

        #expect(b.tree.dataStoreID(for: work.space) == b.tree.dataStoreID(for: side))
        #expect(b.tree.profile(ofSpace: work.space)?.name == "Job")
        #expect(b.tree.profiles.count == 2)
    }

    @Test func anArrivingSpaceTakesAKeptProfileWithItsName() throws {
        let work = try Work()
        var cloud = Cloud()
        var a = Mac(work.tree)
        a.state.setLevel(.pinned, for: work.space, now: fixedNow)
        a.sync(&cloud)

        var b = Mac(TabTree.firstLaunch(homeURL: url("home"), now: fixedNow))
        let kept = ProfileSummary(id: UUID(), name: "Job", spaceIDs: [], searchEngineId: "kagi")
        b.kept = [KeptProfile(kept)]
        b.sync(&cloud)

        #expect(b.tree.dataStoreID(for: work.space) == kept.id)
        #expect(b.tree.profile(ofSpace: work.space)?.name == "Job")
        #expect(b.tree.profile(ofSpace: work.space)?.searchEngineId == "kagi")
    }

    @Test func anArrivingSpaceMakesItsProfileWhenThisMacHasNone() throws {
        let (_, b, work, _) = try pair(.pinned)
        let personal = try #require(b.tree.orderedSpaces.first { $0.id != work.space })

        #expect(b.tree.dataStoreID(for: work.space) != b.tree.dataStoreID(for: personal.id))
        #expect(b.tree.profile(ofSpace: work.space)?.name == "Job")
        #expect(b.tree.profile(ofSpace: personal.id)?.name == "Personal")
    }

    @Test func aSpaceDeletedOnAnotherMacIsDeletedHere() throws {
        var (a, b, work, cloud) = try pair(.pinned)
        _ = try a.tree.deleteSpace(work.space, now: later(10))
        a.sync(&cloud)
        let inbound = b.fetch(cloud)

        #expect(inbound.deletedSpaces == [work.space])
        #expect(b.tree.space(work.space) == nil)
        #expect(cloud.records.isEmpty)
        #expect(b.pending == ([], []))
    }

    // MARK: - Echoes

    @Test func thisMacsOwnRecordsComingBackChangeNothing() throws {
        var (a, _, work, cloud) = try pair(.everything)
        try a.tree.move(work.news, to: .tabs(spaceID: work.space), after: nil, now: later(10))
        try a.tree.rename(work.wiki, customTitle: "Wiki!", now: later(10))
        a.send(&cloud)
        let before = a.tree

        let inbound = a.fetch(cloud)
        #expect(inbound.change.isEmpty)
        #expect(a.tree == before)
        #expect(a.pending == ([], []))
    }

    @Test func anEchoArrivingBeforeItsSendIsConfirmedChangesNothing() throws {
        var (a, _, work, _) = try pair(.everything)
        try a.tree.move(work.news, to: .tabs(spaceID: work.space), after: nil, now: later(10))
        let pending = a.pending
        #expect(pending.saves == [work.news])
        let before = a.tree

        for record in a.state.outgoing(pending.saves, in: a.tree, now: later(10)).values {
            a.state.inbox.add(record, systemFields: Data("echo".utf8))
        }
        let inbound = a.apply(later(11))
        #expect(inbound.change.isEmpty)
        #expect(a.tree == before)
        #expect(a.tree.items.count == before.items.count)
    }

    // MARK: - Account and levels

    @Test func anAccountChangeClearsSyncStateAndKeepsTheSpaces() throws {
        var (a, _, work, _) = try pair(.everything)
        a.state.engine = Data("engine".utf8)
        a.state.lastError = "Network"
        a.state.account = "first"
        let tree = a.tree

        a.state.reset(account: "second")

        #expect(a.state == {
            var expected = SpaceSyncState()
            expected.account = "second"
            return expected
        }())
        #expect(a.state.level(of: work.space) == .off)
        #expect(a.pending == ([], []))
        #expect(a.tree == tree)
    }

    @Test func turningASpaceOffStopsSendingAndReceivingItAndLeavesItInICloud() throws {
        var (a, b, work, cloud) = try pair(.pinned)
        b.state.setLevel(.off, for: work.space, now: later(1))
        #expect(b.pending == ([], []))

        try a.tree.rename(work.wiki, customTitle: "Renamed", now: later(10))
        a.sync(&cloud)
        try b.tree.rename(work.mail, customTitle: "Here only", now: later(20))
        b.sync(&cloud)

        #expect(b.tree.item(work.wiki)?.customTitle == nil)
        #expect(cloud.records[work.mail]?.record.string(Key.customTitle) == nil)
        #expect(cloud.records.count == work.pinnedIDs.count)
    }

    @Test func turningASpaceOnOrWideningItUploadsAndAsksForAFullFetch() throws {
        let work = try Work()
        var state = SpaceSyncState()

        let fromOff = state.setLevel(.pinned, for: work.space, now: fixedNow)
        #expect(fromOff)
        #expect(state.pendingChanges(in: work.tree).saves == work.pinnedIDs)
        let fromPinned = state.setLevel(.everything, for: work.space, now: fixedNow)
        #expect(fromPinned)
        #expect(state.pendingChanges(in: work.tree).saves == work.pinnedIDs.union(work.openTabIDs))
    }

    @Test func goingBackToFavoritesAndPinnedForgetsOpenTabsWithoutDeletingThem() throws {
        var (a, b, work, cloud) = try pair(.everything)
        a.state.setLevel(.pinned, for: work.space, now: later(10))
        #expect(a.pending.deletes.isEmpty)
        a.sync(&cloud, now: later(10))
        b.sync(&cloud, now: later(20))

        #expect(work.openTabIDs.isSubset(of: Set(cloud.records.keys)))
        for mac in [a, b] {
            #expect(work.openTabIDs.allSatisfy { mac.tree.item($0) != nil })
            #expect(work.openTabIDs.allSatisfy { mac.state.shadow[$0] == nil })
            #expect(mac.state.level(of: work.space) == .pinned)
            #expect(mac.pending == ([], []))
        }
    }

    /// Off by choice, or Off because an account change reset this Mac and it fetches everything
    /// again; the space stays out after its tombstone is purged.
    @Test(arguments: [false, true])
    func aSpaceDeletedHereWhileOffDoesNotComeBack(afterAccountReset: Bool) throws {
        var (a, b, work, cloud) = try pair(.pinned)
        if afterAccountReset {
            b.state.reset(account: "same")
            b.cursor = 0
        } else {
            b.state.setLevel(.off, for: work.space, now: later(1))
        }
        _ = try b.tree.deleteSpace(work.space, now: later(2))
        b.sync(&cloud)
        b.tree.repair(now: later(3 + TabTree.tombstoneLifetime))
        #expect(b.tree.spaces[work.space] == nil)
        try a.tree.rename(work.wiki, customTitle: "Renamed", now: later(10))
        try a.tree.updateSpace(work.space, name: "Work 2", now: later(10))
        a.sync(&cloud)
        b.sync(&cloud)

        #expect(b.tree.space(work.space) == nil)
        #expect(cloud.records[work.space] != nil)
    }

    // MARK: - Signed builds

    @Test func syncRunsOnlyInABuildSignedForTheContainer() {
        let container = SpaceSyncAvailability.containerID
        #expect(!SpaceSyncAvailability.isEntitled(containers: nil, services: nil))
        #expect(!SpaceSyncAvailability.isEntitled(containers: [container], services: nil))
        #expect(!SpaceSyncAvailability.isEntitled(containers: ["iCloud.other"], services: ["CloudKit"]))
        #expect(!SpaceSyncAvailability.isEntitled(containers: [container], services: ["CloudDocuments"]))
        #expect(SpaceSyncAvailability.isEntitled(containers: [container], services: ["CloudKit"]))
        #expect(SpaceSyncAvailability.isEntitled(containers: [container], services: ["*"]))
    }

    // MARK: - Leaving sync

    @Test func aTabOnALinkThatIsNotAWebAddressStaysOnEveryMac() throws {
        var (a, b, work, cloud) = try pair(.everything)
        try a.tree.setURL(work.search, URL(string: "file:///tmp/x.pdf")!, now: later(10))
        #expect(a.pending.deletes.isEmpty)
        a.sync(&cloud, now: later(10))
        b.sync(&cloud, now: later(20))
        a.fetch(cloud, now: later(25))

        for mac in [a, b] {
            #expect(mac.tree.item(work.search) != nil)
            #expect(mac.tree.item(work.result) != nil)
        }
        #expect(cloud.records[work.search] != nil)
        #expect(cloud.records[work.result] != nil)

        try a.tree.setURL(work.search, url("search"), now: later(30))
        a.sync(&cloud, now: later(30))
        b.sync(&cloud, now: later(40))
        a.sync(&cloud, now: later(50))

        for mac in [a, b] {
            #expect(mac.tree.item(work.search)?.url == url("search"))
            #expect(mac.tree.item(work.result) != nil)
            #expect(mac.pending == ([], []))
        }
        #expect(cloud.records[work.result] != nil)
    }

    @Test func aReopenedTabStaysWhenItsOwnDeletionComesBack() throws {
        var (a, b, work, cloud) = try pair(.pinned)
        let closed = try a.tree.close(work.wiki, now: later(10)).closed
        a.send(&cloud, now: later(10))
        try a.tree.reopen(closed, fallback: .tabs(spaceID: work.space), now: later(12))
        a.fetch(cloud, now: later(15))
        #expect(a.tree.item(work.wiki) != nil)

        a.send(&cloud, now: later(15))
        b.sync(&cloud, now: later(20))
        #expect(cloud.records[work.wiki] != nil)
        #expect(b.tree.item(work.wiki) != nil)
    }

    @Test func aTabUndoneAfterItsDeletionReachedAnotherMacComesBackThere() throws {
        var (a, b, work, cloud) = try pair(.pinned)
        let undo = try a.tree.close(work.wiki, now: later(10)).change
        a.sync(&cloud, now: later(10))
        b.sync(&cloud, now: later(20))
        #expect(b.tree.item(work.wiki) == nil)

        a.tree.apply(undo)
        a.sync(&cloud, now: later(30))
        b.sync(&cloud, now: later(40))
        a.sync(&cloud, now: later(50))

        #expect(a.tree.item(work.wiki) != nil)
        #expect(b.tree.item(work.wiki) != nil)
        #expect(cloud.records[work.wiki] != nil)
    }

    @Test func aRecordThisMacRefusesIsNotDeletedFromICloud() throws {
        var (_, b, work, cloud) = try pair(.pinned)
        _ = try b.tree.close(work.wiki, now: later(50))
        b.state.forgetRecords()
        b.refetch(cloud, now: later(60))
        b.send(&cloud, now: later(60))

        #expect(b.tree.item(work.wiki) == nil)
        #expect(b.state.shadow[work.wiki] == nil)
        #expect(cloud.records[work.wiki] != nil)
    }

    @Test func unpinningOnOneMacMovesTheTabsToTabsOnTheOther() throws {
        var (a, b, work, cloud) = try pair(.pinned)
        try b.tree.move(work.wiki, to: .tabs(spaceID: work.space), after: nil, now: later(10))
        try b.tree.move(work.docs, to: .tabs(spaceID: work.space), after: nil, now: later(10))
        b.sync(&cloud, now: later(10))
        a.sync(&cloud, now: later(20))

        for mac in [a, b] {
            #expect(mac.tree.item(work.wiki)?.parent == .tabs(spaceID: work.space))
            #expect(mac.tree.item(work.docs)?.parent == .tabs(spaceID: work.space))
            #expect(mac.tree.item(work.old)?.parent == .folder(itemID: work.archive))
            #expect(mac.tree.item(work.spec)?.parent == .folder(itemID: work.docs))
            #expect(mac.state.shadow[work.wiki] == nil)
            #expect(mac.pending == ([], []))
        }
        #expect(cloud.records[work.wiki]?.record.string(Key.section) == "tabs")
    }

    // MARK: - Order of arrival

    @Test func itemsFetchedBeforeTheirSpaceWaitForIt() throws {
        let work = try Work()
        var cloud = Cloud()
        var a = Mac(work.tree)
        a.state.setLevel(.pinned, for: work.space, now: fixedNow)
        a.sync(&cloud)

        var b = Mac(TabTree.firstLaunch(homeURL: url("home"), now: fixedNow))
        for entry in cloud.records.values where entry.record.type == .item {
            b.state.fetched(entry.record, systemFields: entry.tag)
        }
        b.apply(fixedNow)
        #expect(b.tree.item(work.wiki) == nil)
        let space = try #require(cloud.records[work.space])
        b.state.fetched(space.record, systemFields: space.tag)
        b.apply(fixedNow)

        var expected = try #require(a.tree.spaceSnapshot(work.space))
        expected.tabs = []
        #expect(b.tree.spaceSnapshot(work.space) == expected)
        #expect(b.state.inbox.isEmpty)
    }

    @Test func anIncomingParentOutsideItsSyncedSpaceIsNotFollowed() throws {
        var (_, b, work, cloud) = try pair(.pinned)
        let made = b.tree.ensureAgentSpace(loginsFrom: work.space, now: fixedNow)
        let agent = try #require(made).id
        let agentTab = UUID(), live = UUID()
        try b.tree.createTab(id: agentTab, url: url("agent"), title: "Agent", in: .tabs(spaceID: agent), after: nil, now: fixedNow)
        try b.tree.createFolder(id: live, title: "PRs", in: .pinned(spaceID: work.space), after: nil, live: .githubPulls, now: fixedNow)
        let entry = try #require(cloud.records[work.wiki])

        for (step, parent) in [agentTab, live].enumerated() {
            var wiki = entry.record
            wiki.fields[Key.parent] = .string(parent.uuidString)
            wiki.times["position"] = SpaceSyncCodec.milliseconds(later(TimeInterval(10 + step)))
            b.state.fetched(wiki, systemFields: entry.tag)
            b.apply(later(TimeInterval(10 + step)))
            #expect(b.tree.item(work.wiki)?.parent == .pinned(spaceID: work.space))
        }
    }

    // MARK: - Limits and starting over

    @Test func aRecordTooLargeForICloudStaysOnThisMac() throws {
        var work = try Work()
        try work.tree.rename(work.wiki, customTitle: String(repeating: "x", count: 1_100_000), now: fixedNow)
        var state = SpaceSyncState()
        state.setLevel(.pinned, for: work.space, now: fixedNow)

        #expect(state.pendingChanges(in: work.tree).saves == work.pinnedIDs.subtracting([work.wiki]))
        #expect(state.tooLarge(in: work.tree) == [work.wiki])
    }

    @Test func aFullFetchForgetsRecordsICloudNoLongerHasAndDeletesNothing() throws {
        var (a, _, work, cloud) = try pair(.pinned)
        cloud.records[work.wiki] = nil
        a.refetch(cloud, now: later(10))

        #expect(a.state.shadow[work.wiki] == nil)
        #expect(a.tree.item(work.wiki) != nil)
        #expect(a.pending.saves == [work.wiki])
        #expect(a.pending.deletes.isEmpty)
    }

    @Test(arguments: [false, true])
    func aZoneGoneFromICloudDeletesNothingHere(reuploading: Bool) throws {
        var (a, _, work, _) = try pair(.everything)
        let tree = a.tree
        a.state.zoneLost(reuploading: reuploading)

        #expect(a.tree == tree)
        #expect(a.state.shadow.isEmpty)
        #expect(a.pending.deletes.isEmpty)
        #expect(a.state.level(of: work.space) == (reuploading ? .everything : .off))
        #expect(a.pending.saves == (reuploading ? work.pinnedIDs.union(work.openTabIDs) : []))
    }
}
