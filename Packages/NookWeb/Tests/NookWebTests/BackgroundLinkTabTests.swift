// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
import WebKit
import NookBlocker
import NookSettings
import NookTabsCore
import NookTweaks
@testable import NookWeb

/// A tab opened from a link in the background loads at once, as in Arc; a tab made in the
/// background any other way waits until it is selected.
@MainActor
struct BackgroundLinkTabTests {
    // `.invalid` never resolves, so no favicon reaches the shared favicon cache.
    let link = URL(string: "https://link.invalid/article")!

    @Test func linkOpenedInBackgroundLoadsAndKeepsSelection() throws {
        let host = try Host()
        let opener = try #require(host.window.selectedItemID)
        let openerPage = try #require(host.tabs.ensureSession(for: opener))
        let before = host.items()

        openerPage.openInNewTab(link)

        let child = try #require(host.items().subtracting(before).first)
        #expect(host.window.selectedItemID == opener)
        let page = try #require(host.tabs.session(for: child))
        #expect(!page.isUnloaded)
        #expect((page.webView as? RecordingWebView)?.requested == [link])
        #expect(host.backgroundLoads == [child])
    }

    @Test func linkOpenedInBackgroundInPrivateWindowLoads() throws {
        let host = try Host(isPrivate: true)
        let spaceID = try #require(host.window.spaceID)
        let opener = try #require(host.tabs.open(url: URL(string: "https://opener.invalid")!, in: host.window,
                                                 placement: .newTab, parent: .tabs(spaceID: spaceID)))
        let openerPage = try #require(host.tabs.session(for: opener))
        let before = host.items()

        openerPage.openInNewTab(link)

        let child = try #require(host.items().subtracting(before).first)
        #expect(host.window.selectedItemID == opener)
        let page = try #require(host.tabs.session(for: child))
        #expect(page.isPrivate)
        #expect((page.webView as? RecordingWebView)?.requested == [link])
    }

    @Test func backgroundTabWithoutOpenerWaitsForSelection() throws {
        let host = try Host()
        let spaceID = try #require(host.window.spaceID)

        let imported = try #require(host.tabs.open(url: link, in: host.window, placement: .background,
                                                   parent: .tabs(spaceID: spaceID)))

        #expect(host.tabs.session(for: imported)?.isUnloaded ?? true)
        #expect(host.backgroundLoads.isEmpty)
    }
}

/// A TabsController with one window, on a throwaway directory, whose web views record loads
/// instead of navigating.
@MainActor
private final class Host {
    let tabs: TabsController
    let window = BrowserWindowState()
    let registry = WindowRegistry()
    let webViews = RecordingWebViews()
    /// Pages the app's unload policy was told about.
    private(set) var backgroundLoads: [UUID] = []

    init(isPrivate: Bool = false) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NookWebTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settings = NookSettingsService()
        tabs = TabsController(
            settings: settings, windowRegistry: registry, blocker: ContentBlockerManager(settings: settings),
            sponsorBlock: SponsorBlockManager(settings: settings), siteRouting: SiteRoutingManager(settings: settings),
            directory: directory)
        tabs.webViews = webViews
        tabs.onPageLoadedInBackground = { [weak self] in self?.backgroundLoads.append($0.itemID) }
        if isPrivate {
            window.isIncognito = true
            window.ephemeralProfile = Profile.createEphemeral()
        }
        registry.register(window)
        registry.setActive(window)
        tabs.attach(window: window)
    }

    /// The items of the tree this window shows.
    func items() -> Set<UUID> {
        Set((window.privateTree ?? tabs.tree).items.keys)
    }
}

@MainActor
private final class RecordingWebViews: WebViewProvider {
    func makeWebView(configuration: WKWebViewConfiguration) -> WKWebView {
        RecordingWebView(frame: .zero, configuration: configuration)
    }
    func webView(for itemID: UUID, in windowID: UUID) -> WKWebView? { nil }
    func allWebViews(for itemID: UUID) -> [WKWebView] { [] }
    func releaseWebViews(for session: PageSession) {}
    func removeFromContainers(_ webView: WKWebView) {}
}

private final class RecordingWebView: WKWebView, SessionWebView {
    weak var owningSession: PageSession?
    var contextMenuBridge: WebContextMenuBridge?
    private(set) var requested: [URL] = []

    func contextMenuPayloadDidUpdate(_ payload: WebContextMenuPayload?) {}

    override func load(_ request: URLRequest) -> WKNavigation? {
        request.url.map { requested.append($0) }
        return nil
    }
}
