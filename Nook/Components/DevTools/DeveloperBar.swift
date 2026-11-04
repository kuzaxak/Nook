// Licensed under GPL-3.0. See LICENSE.
//
//  DeveloperBar.swift
//  Nook
//
//  Arc's Developer Mode bar: the page's full address in monospace above the page, and the
//  developer tools a click away. Shown for sites with Developer Mode on (the site panel's
//  Settings section); the tools themselves are the ones Settings > Developer turns on.
//

import AppKit
import SwiftUI
import WebKit
import NookDesign
import NookWeb
import NookUI

extension BrowserManager {
    /// Whether the window's page is on a site with Developer Mode on.
    func showsDeveloperBar(in windowState: BrowserWindowState) -> Bool {
        guard !windowState.isIncognito, let settings = nookSettings,
              let host = tabs.selectedSession(in: windowState)?.url.host else { return false }
        return settings.isDeveloperSite(host)
    }

    /// Turns Developer Mode on or off for `host`. Off, every window whose bar goes with it closes a
    /// right column that shows a developer tool.
    func setDeveloperSite(_ host: String, on: Bool) {
        guard let settings = nookSettings else { return }
        let barred = windowRegistry?.allWindows.filter { showsDeveloperBar(in: $0) } ?? []
        settings.setDeveloperSite(host, on: on)
        closeDeveloperTools(in: barred.filter { !showsDeveloperBar(in: $0) }, developerMode: settings.developerModeEnabled)
    }

    /// Developer Mode going off beside these windows' pages: a right column that shows a developer
    /// tool closes, one on the Agent tab stays. `developerMode` is the Settings one it showed under.
    func closeDeveloperTools(in windows: [BrowserWindowState], developerMode: Bool) {
        let agent = nookSettings?.showAIAssistant == true
        withAnimation(NookDesign.Motion.standard) {
            for window in windows {
                let tab = DevPanelTab.shown(window.devPanelTab, developerMode: developerMode, agent: agent)
                let open = DevPanelTab.staysOpen(window.isSidebarAIChatVisible, showing: tab)
                if open != window.isSidebarAIChatVisible { window.isSidebarAIChatVisible = open }
            }
        }
    }

    /// The address bar over the page. The Developer Mode bar takes its place, as in Arc, and
    /// back, forward and the address return to the sidebar.
    func showsTopBar(in windowState: BrowserWindowState) -> Bool {
        nookSettings?.topBarAddressView == true && !showsDeveloperBar(in: windowState)
    }

    /// Runs a tool that needs page capture (Settings > Developer > Developer Mode). On a site with
    /// Developer Mode on, the bar's tools ask to turn it on rather than sit greyed out; turning it
    /// on here does what the Settings toggle does, Browser Control included.
    func withDeveloperCapture(_ action: @escaping () -> Void) {
        guard let settings = nookSettings else { return }
        if settings.developerModeEnabled { action(); return }
        guard let windowState = windowRegistry?.activeWindow, showsDeveloperBar(in: windowState),
              let window = windowState.windowHandle as? NSWindow else { return }
        let alert = NSAlert()
        alert.messageText = "Turn on Developer Mode?"
        alert.informativeText = "Console, Network, Performance and Pick Element record what pages do. While Developer Mode is on, that happens on every site, not only this one. You can turn it off in Settings → Developer."
        alert.addButton(withTitle: "Turn On")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self, weak windowState] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            settings.developerModeEnabled = true
            self.tabs.setDeveloperMode(true)
            DevMCPServer.shared.applyEnabledSetting(settings.browserControlServerEnabled)
            if let windowState { self.showWindowToast("Developer Mode on. Reload to capture this page", in: windowState) }
            action()
        }
    }

    func copyScreenshot(of webView: WKWebView?, in windowState: BrowserWindowState) {
        guard let webView else { return }
        webView.takeSnapshot(with: nil) { [weak self, weak windowState] image, _ in
            guard let image, let windowState else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
            self?.showWindowToast("Screenshot copied", in: windowState)
        }
    }

    func togglePortraitCapture(in windowState: BrowserWindowState) {
        withAnimation(NookDesign.Motion.spring) { windowState.isPortraitCaptureVisible.toggle() }
    }

    /// The copy toast with any message, for the developer tools.
    func showWindowToast(_ text: String, in windowState: BrowserWindowState) {
        windowState.copyToastText = text
        windowState.isShowingCopyURLToast = true
        Task { [weak windowState] in
            try? await Task.sleep(for: .seconds(2))
            windowState?.isShowingCopyURLToast = false
            windowState?.copyToastText = nil
        }
    }
}

struct DeveloperBar: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    let session: PageSession

    @State private var copied = false

    private let height: CGFloat = 38

    var body: some View {
        HStack(spacing: NookDesign.Spacing.md) {
            // Arc's lock opens the site's controls, as the sidebar's site controls button does.
            Button {
                withAnimation(.interpolatingSpring(Spring(response: 0.3, dampingRatio: 0.86))) {
                    windowState.isExtensionLibraryVisible.toggle()
                }
            } label: {
                Image(systemName: session.url.scheme == "https" ? "lock.fill" : "lock.open.fill")
                    .font(NookDesign.Font.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: NookDesign.Size.rowButton, height: NookDesign.Size.rowButton)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Site Controls")
            Text(session.url.absoluteString)
                .font(NookDesign.Font.mono)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: NookDesign.Spacing.lg)

            HStack(spacing: NookDesign.Spacing.xxs) {
                tool(copied ? "checkmark" : "link", "Copy Link", shortcut: .copyCurrentURL) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.url.absoluteString, forType: .string)
                    withAnimation(NookDesign.Motion.quick) { copied = true }
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        withAnimation(NookDesign.Motion.quick) { copied = false }
                    }
                }
                separator
                tool("photo.on.rectangle.angled", "Capture in Portrait Mode", shortcut: .capturePortrait,
                     isOn: windowState.isPortraitCaptureVisible) { browserManager.togglePortraitCapture(in: windowState) }
                tool("camera", "Copy Screenshot", shortcut: .copyScreenshot) { browserManager.perform(.copyScreenshot) }
                separator
                tool("terminal", "Console", shortcut: .openDevPanel, isOn: devTabShowing(.console)) { browserManager.toggleDevPanel(.console) }
                tool("network", "Network", shortcut: .openNetworkPanel, isOn: devTabShowing(.network)) { browserManager.toggleDevPanel(.network) }
                tool("scope", "Pick Element", shortcut: .pickElement) { browserManager.perform(.pickElement) }
                separator
                tool("hammer", "Web Inspector", shortcut: .openDevTools) { browserManager.perform(.webInspector) }
                tool("gauge.with.needle", "Performance", shortcut: .openPerformancePanel, isOn: devTabShowing(.perf)) { browserManager.toggleDevPanel(.perf) }
            }
        }
        .padding(.horizontal, NookDesign.Spacing.lg)
        .frame(height: height)
        .background(NookDesign.Surface.raised)
        .overlay(alignment: .bottom) { Rectangle().fill(NookDesign.Surface.hairline).frame(height: 1) }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var separator: some View {
        Rectangle()
            .fill(NookDesign.Surface.hairline)
            .frame(width: 1, height: NookDesign.Spacing.xl)
            .padding(.horizontal, NookDesign.Spacing.xs)
    }

    private func devTabShowing(_ tab: DevPanelTab) -> Bool {
        windowState.isSidebarAIChatVisible && windowState.devPanelTab == tab
    }

    private func tool(_ symbol: String, _ help: String, shortcut: ShortcutAction, isOn: Bool = false, action: @escaping () -> Void) -> some View {
        Button(help, systemImage: symbol, action: action)
            .labelStyle(.iconOnly)
            .contentTransition(.symbolEffect(.replace))
            .buttonStyle(NookIconButtonStyle())
            .background(isOn ? NookDesign.Surface.fillPressed : .clear, in: NookDesign.Radius.shape(NookDesign.Radius.md))
            .help(browserManager.help(help, shortcut: shortcut))
    }
}
