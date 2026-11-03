// Licensed under GPL-3.0. See LICENSE.
//
//  VaultService.swift
//  Nook
//
//  The app-wide side of the Pawl Vault bridge: the setting, the socket client, the status
//  Settings shows, and the per-web-view bridges. Status comes from `hello`, asked when the
//  setting turns on, at most every few seconds on navigation, and before every passkey request.
//

#if os(macOS)
import Foundation
import NookSettings
import Observation
import WebKit

@MainActor
@Observable
public final class VaultService {
    /// The last `hello`'s answer; nil while the setting is off or before the first answer.
    public private(set) var status: VaultStatus?

    @ObservationIgnored public weak var presenter: VaultPresenter?
    @ObservationIgnored let client = VaultClient()
    @ObservationIgnored private let settings: NookSettingsService
    @ObservationIgnored private var lastNavigationRefresh: ContinuousClock.Instant?
    @ObservationIgnored private var settingObserver: NSObjectProtocol?

    /// The bundled Public Suffix List, read on the first passkey request.
    static let suffixes: PublicSuffixList = {
        let url = Bundle.module.url(forResource: "public_suffix_list", withExtension: "dat", subdirectory: "Resources")
        return PublicSuffixList(text: url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "")
    }()

    public init(settings: NookSettingsService) {
        self.settings = settings
        settingObserver = NotificationCenter.default.addObserver(
            forName: NookSettingsService.pawlVaultEnabledDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingChanged() }
        }
        if settings.pawlVaultEnabled { Task { await refresh() } }
    }

    public var isEnabled: Bool { settings.pawlVaultEnabled }

    /// Paired and unlocked as of the last `hello`.
    public var isConnected: Bool { isEnabled && status == .connected }

    /// Asks the vault for its status and swaps the passkey scripts on every page when the
    /// answer changes whether passkeys go to the vault.
    @discardableResult
    public func refresh(profile: String? = nil) async -> VaultStatus? {
        guard isEnabled else { return nil }
        let answer: VaultStatus
        do {
            answer = VaultStatus(try await client.send(VaultHello(profile: profile)))
        } catch let error as VaultClientError {
            answer = VaultStatus(error)
        } catch {
            answer = .notRunning
        }
        guard isEnabled else { return nil }
        let wasConnected = isConnected
        status = answer
        if isConnected != wasConnected { VaultBridge.syncAll() }
        return answer
    }

    func send<C: VaultCall>(_ call: C) async throws -> C.Reply {
        try await client.send(call)
    }

    // MARK: - Page hooks

    /// Installs the bridge on a page's web view. Agent pages never reach the vault.
    public func attach(to webView: WKWebView, session: PageSession) {
        guard !session.isAgentPage else { return }
        VaultBridge.install(on: webView, session: session, service: self)
    }

    public static func detach(from controller: WKUserContentController) {
        VaultBridge.uninstall(from: controller)
    }

    /// A main-frame navigation is starting: refresh the status for the pages after this one.
    public func navigationStarted() {
        guard isEnabled else { return }
        let now = ContinuousClock.now
        if let last = lastNavigationRefresh, now - last < .seconds(3) { return }
        lastNavigationRefresh = now
        Task { await refresh() }
    }

    /// A new document committed in `webView`: requests and pickers from the old one end.
    public func pageCommitted(in webView: WKWebView) {
        VaultBridge.bridge(for: webView)?.documentChanged()
    }

    private func settingChanged() {
        if isEnabled {
            Task { await refresh() }
        } else {
            status = nil
            Task { await client.disconnect() }
        }
        VaultBridge.syncAll()
    }
}
#endif
