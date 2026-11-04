// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
@testable import NookTabsCore

/// A space saved to a `.nookspace` file and added back as a new space.
struct SpaceFileTests {
    typealias Entry = SpaceSnapshot.Entry

    /// "Work": a theme, two favorites, a pinned folder holding a renamed tab and a folder, a
    /// pinned tab, and open tabs where one opened two others and one of those opened a third.
    private func sample() throws -> (tree: TabTree, space: UUID) {
        var tree = TabTree()
        let space = UUID()
        tree.createSpace(id: space, name: "Work", icon: "💼", accentHex: "#336699", after: nil, now: fixedNow)
        try tree.setTheme(space, theme: SpaceTheme(points: [.init(hue: 200, saturation: 0.8)], mode: .dark, intensity: 0.4, grain: 0.3), now: fixedNow)
        let mail = UUID()
        try tree.createTab(id: mail, url: url("mail"), title: "Mail", in: .favorites(spaceID: space), after: nil, now: fixedNow)
        try tree.createTab(url: url("calendar"), title: "Calendar", in: .favorites(spaceID: space), after: mail, now: fixedNow)
        let docs = UUID(), spec = UUID(), archive = UUID()
        try tree.createFolder(id: docs, title: "Docs", in: .pinned(spaceID: space), after: nil, now: fixedNow)
        try tree.createTab(id: spec, url: url("spec"), title: "Spec", in: .folder(itemID: docs), after: nil, now: fixedNow)
        try tree.rename(spec, customTitle: "The spec", now: fixedNow)
        try tree.createFolder(id: archive, title: "Archive", in: .folder(itemID: docs), after: spec, now: fixedNow)
        try tree.createTab(url: url("old"), title: "Old", in: .folder(itemID: archive), after: nil, now: fixedNow)
        try tree.createTab(url: url("wiki"), title: "Wiki", in: .pinned(spaceID: space), after: docs, now: fixedNow)
        let search = UUID(), first = UUID(), second = UUID()
        try tree.createTab(id: search, url: url("search"), title: "Search", in: .tabs(spaceID: space), after: nil, now: fixedNow)
        try tree.createTab(id: first, url: url("result 1"), title: "Result 1", in: .folder(itemID: search), after: nil, now: fixedNow)
        try tree.createTab(id: second, url: url("result 2"), title: "Result 2", in: .folder(itemID: search), after: first, now: fixedNow)
        try tree.createTab(url: url("detail"), title: "Detail", in: .folder(itemID: first), after: nil, now: fixedNow)
        try tree.createTab(url: url("news"), title: "News", in: .tabs(spaceID: space), after: search, now: fixedNow)
        return (tree, space)
    }

    /// A tree with one "Personal" space in its own profile, as a first launch leaves it.
    private func target() throws -> (tree: TabTree, profile: UUID) {
        let tree = TabTree.firstLaunch(homeURL: url("home"), now: fixedNow)
        return (tree, try #require(tree.profiles.first?.id))
    }

    /// A section as text without ids: "kind title url (custom) [children]".
    private func outline(_ entries: [Entry]) -> [String] {
        entries.map { entry in
            var line = "\(entry.kind) \(entry.title)"
            if let url = entry.url { line += " \(url)" }
            if let custom = entry.customTitle { line += " (\(custom))" }
            if !entry.children.isEmpty { line += " [" + outline(entry.children).joined(separator: ", ") + "]" }
            return line
        }
    }

    private func ids(_ entries: [Entry]) -> [UUID] {
        entries.flatMap { [$0.id] + ids($0.children) }
    }

    private func tab(_ url: String?, _ title: String = "t", custom: String? = nil, _ children: [Entry] = []) -> Entry {
        Entry(id: UUID(), kind: .tab, url: url, title: title, customTitle: custom, children: children)
    }

    private func folder(_ title: String, _ children: [Entry] = []) -> Entry {
        Entry(id: UUID(), kind: .folder, url: nil, title: title, customTitle: nil, children: children)
    }

    private func snapshot(name: String = "Imported", favorites: [Entry] = [], pinned: [Entry] = [], tabs: [Entry] = []) -> SpaceSnapshot {
        SpaceSnapshot(id: UUID(), name: name, icon: "star", accentHex: "#112233", theme: nil,
                      favorites: favorites, pinned: pinned, tabs: tabs)
    }

    private func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func decodeError(_ data: Data) -> SpaceFileError? {
        do {
            _ = try SpaceFile.decode(data)
            return nil
        } catch let error as SpaceFileError {
            return error
        } catch {
            Issue.record("unexpected \(error)")
            return nil
        }
    }

    // MARK: - Round trip

    @Test func aSpaceComesBackWithTheSameStructureAndFreshIDs() throws {
        let (source, spaceID) = try sample()
        let exported = try #require(source.spaceSnapshot(spaceID))
        let data = try SpaceFile(space: exported, appVersion: "1.5.3", exportedAt: fixedNow).encoded()
        let file = try SpaceFile.decode(data)
        #expect(file.format == "nook.space")
        #expect(file.version == 1)
        #expect(file.appVersion == "1.5.3")
        #expect(file.space == exported)

        var (tree, profile) = try target()
        let before = tree
        let report = try tree.importSpace(file.space, intoProfile: profile, now: fixedNow).report
        let imported = try #require(tree.spaceSnapshot(report.spaceID))

        #expect(imported.name == "Work")
        #expect(imported.icon == "💼")
        #expect(imported.theme == exported.theme)
        #expect(imported.accentHex == exported.accentHex)
        #expect(outline(imported.favorites) == outline(exported.favorites))
        #expect(outline(imported.pinned) == outline(exported.pinned))
        #expect(outline(imported.tabs) == outline(exported.tabs))
        #expect(outline(imported.pinned) == [
            "folder Docs [tab Spec \(url("spec")) (The spec), folder Archive [tab Old \(url("old"))]]",
            "tab Wiki \(url("wiki"))",
        ])

        let sourceIDs = Set(ids(exported.favorites + exported.pinned + exported.tabs) + [exported.id])
        let importedIDs = ids(imported.favorites + imported.pinned + imported.tabs) + [imported.id]
        #expect(Set(importedIDs).isDisjoint(with: sourceIDs))
        #expect(report == SpaceImportReport(spaceID: imported.id, name: "Work", tabs: 8, folders: 2, favorites: 2,
                                            duplicateFavorites: 0, unsafeLinks: 0))

        // A new space at the end, in the chosen profile; nothing that was there changed.
        #expect(tree.orderedSpaces.last?.id == report.spaceID)
        #expect(tree.dataStoreID(for: report.spaceID) == profile)
        for (id, space) in before.spaces { #expect(tree.spaces[id] == space) }
        for (id, item) in before.items { #expect(tree.items[id] == item) }
        checkInvariants(tree)
    }

    @Test func importedTabsKeepTheirPageAndCustomTitles() throws {
        var (tree, profile) = try target()
        let report = try tree.importSpace(snapshot(pinned: [tab("https://a.com/x", "Page", custom: "Mine")]),
                                          intoProfile: profile, now: fixedNow).report
        let item = try #require(tree.children(of: .pinned(spaceID: report.spaceID)).first)
        #expect(item.url == URL(string: "https://a.com/x"))
        #expect(item.pageTitle == "Page")
        #expect(item.customTitle == "Mine")
    }

    @Test func nestedFoldersKeepTheirOrderToTheDepthLimit() throws {
        let deepest = folder("5", [tab("https://a.com/deep", "deep")])
        let chain = folder("1", [tab("https://a.com/a", "a"), folder("2", [folder("3", [folder("4", [deepest])]), tab("https://a.com/b", "b")])])
        var (tree, profile) = try target()
        let file = try SpaceFile.decode(SpaceFile(space: snapshot(pinned: [chain, folder("empty")]), appVersion: "1").encoded())
        let report = try tree.importSpace(file.space, intoProfile: profile, now: fixedNow).report
        let imported = try #require(tree.spaceSnapshot(report.spaceID))
        #expect(outline(imported.pinned) == [
            "folder 1 [tab a https://a.com/a, folder 2 [folder 3 [folder 4 [folder 5 [tab deep https://a.com/deep]]], tab b https://a.com/b]]",
            "folder empty",
        ])
        #expect(report.folders == 6)
        checkInvariants(tree)
    }

    @Test func linkTabsStayUnderTheTabThatOpenedThem() throws {
        let (source, spaceID) = try sample()
        let exported = try #require(source.spaceSnapshot(spaceID))
        var (tree, profile) = try target()
        let report = try tree.importSpace(exported, intoProfile: profile, now: fixedNow).report
        let open = tree.children(of: .tabs(spaceID: report.spaceID))
        #expect(open.map(\.displayTitle) == ["Search", "News"])
        let search = try #require(open.first)
        let results = tree.children(of: .folder(itemID: search.id))
        #expect(results.map(\.displayTitle) == ["Result 1", "Result 2"])
        #expect(results.allSatisfy { tree.trailParent(of: $0.id) == search.id })
        let first = try #require(results.first)
        let detail = try #require(tree.children(of: .folder(itemID: first.id)).first)
        #expect(tree.trailParent(of: detail.id) == first.id)
        #expect(!tree.hasChildren(try #require(open.last).id))
    }

    // MARK: - Export

    @Test func exportCarriesTheFavoritesTheSpaceShows() throws {
        var tree = TabTree()
        let store = UUID(), work = UUID(), side = UUID()
        tree.createSpace(id: work, name: "Work", icon: "w", accentHex: "#000000", after: nil, dataStoreID: store, now: fixedNow)
        tree.createSpace(id: side, name: "Side", icon: "s", accentHex: "#000000", after: work, dataStoreID: store, now: fixedNow)
        try tree.createTab(url: url("shared"), title: "Shared", in: .favorites(spaceID: work), after: nil, now: fixedNow)
        try tree.createTab(url: url("own"), title: "Own", in: .favorites(spaceID: side), after: nil, now: fixedNow)
        let exported = try #require(tree.spaceSnapshot(side))
        #expect(exported.favorites.map(\.title) == ["Shared", "Own"])
    }

    @Test func anEmptySpaceExportsAndImportsAsAnEmptySpace() throws {
        var source = TabTree()
        let empty = UUID()
        source.createSpace(id: empty, name: "Empty", icon: "", accentHex: "#7C7C7C", after: nil, now: fixedNow)
        let exported = try #require(source.spaceSnapshot(empty))
        #expect(exported.favorites.isEmpty && exported.pinned.isEmpty && exported.tabs.isEmpty)
        #expect(exported.theme == nil)

        var (tree, profile) = try target()
        let file = try SpaceFile.decode(SpaceFile(space: exported, appVersion: "1").encoded())
        let report = try tree.importSpace(file.space, intoProfile: profile, now: fixedNow).report
        #expect(tree.space(report.spaceID)?.name == "Empty")
        #expect(tree.space(report.spaceID)?.theme == nil)
        #expect(tree.items(inSpaceForTest: report.spaceID).isEmpty)
    }

    @Test func theAgentSpaceIsNotExported() throws {
        var f = Fixture()
        let agent = try #require(f.tree.ensureAgentSpace(loginsFrom: f.spaceA, now: fixedNow)?.id)
        #expect(f.tree.spaceSnapshot(agent) == nil)
        #expect(f.tree.spaceSnapshot(UUID()) == nil)
    }

    // MARK: - Import into a profile

    @Test func favoritesMergeIntoTheProfileWithoutRepeatingAURL() throws {
        var (tree, profile) = try target()
        let personal = tree.orderedSpaces[0].id
        try tree.createTab(url: URL(string: "https://mail.com/")!, title: "Mail", in: .favorites(spaceID: personal), after: nil, now: fixedNow)
        let file = snapshot(favorites: [tab("https://mail.com/", "Mail again"), tab("https://news.com/", "News"),
                                        tab("https://news.com/", "News again")])
        let report = try tree.importSpace(file, intoProfile: profile, now: fixedNow).report
        #expect(report.favorites == 1)
        #expect(report.duplicateFavorites == 2)
        #expect(tree.favorites(of: report.spaceID).map(\.displayTitle) == ["Mail", "News"])
        #expect(tree.favorites(of: personal).map(\.displayTitle) == ["Mail", "News"])
    }

    @Test func favoritesGoToTheChosenProfileOnly() throws {
        var (tree, _) = try target()
        let other = UUID()
        tree.createSpace(id: other, name: "Other", icon: "", accentHex: "#000000", after: tree.orderedSpaces.last?.id, now: fixedNow)
        try tree.createTab(url: URL(string: "https://mail.com/")!, title: "Mail", in: .favorites(spaceID: other), after: nil, now: fixedNow)
        let personal = tree.orderedSpaces[0].id
        let store = try #require(tree.dataStoreID(for: personal))
        let report = try tree.importSpace(snapshot(favorites: [tab("https://mail.com/", "Mail")]), intoProfile: store, now: fixedNow).report
        #expect(report.favorites == 1)
        #expect(tree.favorites(of: personal).map(\.displayTitle) == ["Mail"])
        #expect(tree.favorites(of: other).map(\.displayTitle) == ["Mail"])
        #expect(tree.dataStoreID(for: report.spaceID) == store)
    }

    @Test func aNameInUseGetsTheNextFreeNumber() throws {
        var (tree, profile) = try target()
        tree.createSpace(name: "Work", icon: "", accentHex: "#000000", after: tree.orderedSpaces.last?.id, now: fixedNow)
        tree.createSpace(name: "work 2", icon: "", accentHex: "#000000", after: tree.orderedSpaces.last?.id, now: fixedNow)
        let first = try tree.importSpace(snapshot(name: "Work"), intoProfile: profile, now: fixedNow).report
        let second = try tree.importSpace(snapshot(name: "Work"), intoProfile: profile, now: fixedNow).report
        let fresh = try tree.importSpace(snapshot(name: "Fresh"), intoProfile: profile, now: fixedNow).report
        let blank = try tree.importSpace(snapshot(name: "  "), intoProfile: profile, now: fixedNow).report
        #expect(first.name == "Work 3")
        #expect(second.name == "Work 4")
        #expect(fresh.name == "Fresh")
        #expect(blank.name == "New Space")
        #expect(tree.space(first.spaceID)?.name == "Work 3")
    }

    @Test func importingTheSameFileTwiceMakesTwoSpaces() throws {
        let (source, spaceID) = try sample()
        let file = try SpaceFile.decode(SpaceFile(space: try #require(source.spaceSnapshot(spaceID)), appVersion: "1").encoded())
        var (tree, profile) = try target()
        let first = try tree.importSpace(file.space, intoProfile: profile, now: fixedNow).report
        let second = try tree.importSpace(file.space, intoProfile: profile, now: fixedNow).report
        #expect(first.spaceID != second.spaceID)
        #expect([first.name, second.name] == ["Work", "Work 2"])
        #expect(second.favorites == 0)
        #expect(second.duplicateFavorites == 2)
        #expect(tree.favorites(of: second.spaceID).count == 2)
        #expect(Set(tree.items.keys).count == tree.items.count)
        checkInvariants(tree)
    }

    @Test func aMissingProfileImportsNothing() throws {
        var (tree, _) = try target()
        let before = tree
        #expect(throws: TreeError.missingSpace) {
            try tree.importSpace(snapshot(tabs: [tab("https://a.com/")]), intoProfile: UUID(), now: fixedNow)
        }
        #expect(tree == before)
    }

    @Test func aFileCannotMakeTheAgentSpaceOrABadAccent() throws {
        var (tree, profile) = try target()
        var file = snapshot()
        file.icon = "nook.agent:\(UUID().uuidString)"
        file.accentHex = "javascript:alert(1)"
        let report = try tree.importSpace(file, intoProfile: profile, now: fixedNow).report
        let space = try #require(tree.space(report.spaceID))
        #expect(!space.isAgent)
        #expect(tree.agentSpace == nil)
        #expect(space.accentHex == "#7C7C7C")
    }

    // MARK: - Unsafe links

    @Test func onlyWebLinksComeIn() throws {
        let unsafe = ["javascript:alert(1)", "data:text/html,<b>hi</b>", "file:///etc/passwd", "zoommtg://join?id=1",
                      "nook://settings", "https://", "not a url", "about:blank"]
        let file = snapshot(
            favorites: [tab("javascript:alert(2)"), tab("https://fav.com/", "fav")],
            pinned: [folder("F", unsafe.map { tab($0) } + [tab("HTTPS://Example.com/ok", "ok")])],
            tabs: [tab(nil), tab("file:///tmp/opener", "opener", [tab("https://child.com/", "child")]), tab("http://plain.com/", "plain")])
        var (tree, profile) = try target()
        let report = try tree.importSpace(file, intoProfile: profile, now: fixedNow).report
        let imported = try #require(tree.spaceSnapshot(report.spaceID))
        #expect(report.unsafeLinks == unsafe.count + 3)
        #expect(outline(imported.favorites) == ["tab fav https://fav.com/"])
        #expect(outline(imported.pinned) == ["folder F [tab ok HTTPS://Example.com/ok]"])
        // A tab whose link was dropped gives the tabs it opened its place.
        #expect(outline(imported.tabs) == ["tab child https://child.com/", "tab plain http://plain.com/"])
        #expect(report.tabs == 3)
        checkInvariants(tree)
    }

    // MARK: - Limits

    @Test func aFileOverTheSizeLimitIsRefused() throws {
        #expect(decodeError(Data(repeating: 0x20, count: SpaceFile.maxBytes + 1)) == .tooLarge)
    }

    @Test func aFileWithTooManyItemsIsRefused() throws {
        let many = (0..<SpaceFile.maxItems).map { tab("https://a.com/\($0)") }
        let atLimit = try SpaceFile(space: snapshot(tabs: many), appVersion: "1").encoded()
        #expect(try SpaceFile.decode(atLimit).space.tabs.count == SpaceFile.maxItems)
        let over = try SpaceFile(space: snapshot(favorites: [tab("https://a.com/fav")], tabs: many), appVersion: "1").encoded()
        #expect(decodeError(over) == .tooManyItems)
        let nested = try SpaceFile(space: snapshot(pinned: [folder("F", many)]), appVersion: "1").encoded()
        #expect(decodeError(nested) == .tooManyItems)
    }

    @Test func foldersNestedPastTheLimitAreRefused() throws {
        func chain(_ levels: Int, leaf: Entry) -> Entry {
            (1..<levels).reduce(folder("1", [leaf])) { inner, level in folder("\(level + 1)", [inner]) }
        }
        let fits = try SpaceFile(space: snapshot(pinned: [chain(5, leaf: tab("https://a.com/"))]), appVersion: "1").encoded()
        #expect(decodeError(fits) == nil)
        let deep = try SpaceFile(space: snapshot(pinned: [chain(5, leaf: folder("6"))]), appVersion: "1").encoded()
        #expect(decodeError(deep) == .tooDeep)
        let trail = (0..<6).reduce(tab("https://a.com/leaf")) { inner, _ in tab("https://a.com/", "t", [inner]) }
        let deepTrail = try SpaceFile(space: snapshot(tabs: [trail]), appVersion: "1").encoded()
        #expect(decodeError(deepTrail) == .tooDeep)
    }

    @Test func deeplyNestedJSONIsRefusedWithoutCrashing() {
        let brackets = 100_000
        let data = Data(repeating: UInt8(ascii: "["), count: brackets) + Data(repeating: UInt8(ascii: "]"), count: brackets)
        #expect(decodeError(data) == .tooDeep)
        // Deep enough to overflow a decoder's stack while still inside JSONDecoder's own limit.
        let folder = "{\"id\":\"\(UUID().uuidString)\",\"kind\":\"folder\",\"title\":\"f\",\"children\":["
        var json = "{\"format\":\"nook.space\",\"version\":1,\"exportedAt\":\"2026-01-01T00:00:00Z\",\"appVersion\":\"1\","
        json += "\"space\":{\"id\":\"\(UUID().uuidString)\",\"name\":\"x\",\"icon\":\"\",\"accentHex\":\"#000000\","
        json += "\"favorites\":[],\"tabs\":[],\"pinned\":[" + String(repeating: folder, count: 250) + String(repeating: "]}", count: 250) + "]}}"
        #expect(decodeError(Data(json.utf8)) == .tooDeep)
    }

    // MARK: - Format and version

    @Test func anotherFormatIsRefused() throws {
        #expect(decodeError(try json(["format": "nook.tabs", "version": 1, "space": [:]])) == .wrongFormat)
        #expect(decodeError(try json(["version": 1, "space": [:]])) == .wrongFormat)
        #expect(decodeError(try json(["formatVersion": 2, "spaces": [], "items": []])) == .wrongFormat)
    }

    @Test func aNewerVersionIsRefused() throws {
        #expect(decodeError(try json(["format": "nook.space", "version": 2, "space": ["anything": true]])) == .newerVersion(2))
        #expect(decodeError(try json(["format": "nook.space", "version": 0, "space": [:]])) == .unreadable)
        #expect(decodeError(try json(["format": "nook.space", "space": [:]])) == .unreadable)
    }

    @Test func malformedJSONIsRefused() throws {
        let (source, spaceID) = try sample()
        let valid = try SpaceFile(space: try #require(source.spaceSnapshot(spaceID)), appVersion: "1").encoded()
        #expect(decodeError(valid.prefix(valid.count / 2)) == .unreadable)
        #expect(decodeError(Data("hello".utf8)) == .unreadable)
        #expect(decodeError(Data()) == .unreadable)
        #expect(decodeError(Data([0xFF, 0xFE, 0x00, 0x7B])) == .unreadable)
        #expect(decodeError(try json(["format": "nook.space", "version": 1, "exportedAt": "2026-01-01T00:00:00Z", "appVersion": "1"])) == .unreadable)
        var object = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        var space = try #require(object["space"] as? [String: Any])
        space["tabs"] = [["id": UUID().uuidString, "kind": "note", "title": "x", "children": []]]
        object["space"] = space
        #expect(decodeError(try json(object)) == .unreadable)
    }
}

private extension TabTree {
    /// Every live record in a space's sections.
    func items(inSpaceForTest spaceID: UUID) -> [Item] {
        items.values.filter { $0.deletedAt == nil && self.spaceID(of: $0.id) == spaceID }
    }
}
