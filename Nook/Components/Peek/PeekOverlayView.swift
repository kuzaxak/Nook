// Licensed under GPL-3.0. See LICENSE.
//
//  PeekOverlayView.swift
//  Nook
//
//  Created by Jonathan Caudill on 24/09/2025.
//

import NookTabsCore
import SwiftUI
import NookDesign
import NookWeb
import AppKit
import NookUI

struct PeekOverlayView: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(TabsController.self) private var tabs
    @Environment(BrowserWindowState.self) var windowState
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.nookSettings) var nookSettings

    private var peek: PeekManager { browserManager.peekManager }

    /// The Peek of the tab this window shows; other tabs and windows show theirs.
    private var page: PageSession? { peek.page(in: windowState) }

    private var currentSpaceColor: Color {
        windowState.spaceID.flatMap { tabs.space($0)?.accentColor } ?? Color.accentColor
    }

    var body: some View {
        ZStack {
            if let page {
                backgroundOverlay
                    .transition(.opacity)
                peekContent(page: page)
                    .transition(.scale(scale: 0.05, anchor: peek.origin(of: page)).combined(with: .opacity))
                    .zIndex(1000)
            }
        }
    }

    /// Dims the page area only; the sidebar stays bright and takes clicks.
    private var backgroundOverlay: some View {
        GeometryReader { geometry in
            let area = webArea(in: geometry.size)
            NookDesign.Surface.peekWash
                .frame(width: area.width, height: area.height)
                .contentShape(Rectangle())
                .onTapGesture { peek.dismissPeek(in: windowState) }
                .offset(x: area.minX)
        }
    }

    private func peekContent(page: PageSession) -> some View {
        GeometryReader { geometry in
            let (frame, cornerRadius) = calculateLayout(geometry: geometry)

            ZStack {
                // The card's surface and shadow sit behind the page, never on it: see DetachedPageHost.
                NookDesign.Radius.shape(cornerRadius)
                    .fill(colorScheme == .dark ? Color.black : Color.white)
                    .nookElevation(.floating)

                VStack(spacing: 0) {
                    PeekNavigationBar(page: page, cornerRadius: cornerRadius)
                    ZStack {
                        DetachedPageHost(page: page, cornerRadius: cornerRadius, squareTop: true)
                            .id(page.itemID)

                        BlockedPageView(session: page)
                        TranslationTaskHost(session: page)

                        if let webView = page.webView {
                            PageLoadBar(webView: webView, tint: currentSpaceColor)
                                .frame(maxHeight: .infinity, alignment: .top)
                                .id(page.itemID)
                        }
                    }
                }
            }
            .frame(width: frame.width, height: frame.height)
            // Arc keeps the buttons in the margin right of the card, just below its top edge.
            .overlay(alignment: .topTrailing) {
                actionButtons
                    .alignmentGuide(.trailing) { $0[.leading] - NookDesign.Spacing.md }
                    .padding(.top, NookDesign.Spacing.sm)
            }
            .position(
                x: frame.minX + (frame.width / 2),
                y: geometry.size.height / 2
            )
        }
    }

    /// Close, open as a tab and open in split view: one round floating button each, as in Arc.
    private var actionButtons: some View {
        VStack(spacing: NookDesign.Spacing.sm) {
            peekButton("Close", systemImage: "xmark") { peek.dismissPeek(in: windowState) }
            peekButton("Open as Tab", systemImage: "arrow.up.left.and.arrow.down.right") { peek.moveToNewTab(in: windowState) }
            peekButton("Open in Split View", systemImage: "square.split.2x1") { peek.moveToSplitView(in: windowState) }
                .disabled(!peek.canEnterSplitView(in: windowState))
        }
    }

    private func peekButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .font(.system(size: NookDesign.Size.rowGlyph, weight: .semibold))
            .buttonStyle(NookIconButtonStyle(size: NookDesign.Size.iconButton, radius: NookDesign.Size.iconButton / 2))
            .foregroundStyle(.secondary)
            .nookFloatingSurface(in: Circle())
            .help(title)
    }

    // MARK: - Layout Calculation

    /// The window minus the sidebar, on whichever side it is.
    private func webArea(in windowSize: CGSize) -> CGRect {
        let sidebarWidth: CGFloat = windowState.isSidebarVisible ? windowState.sidebarWidth : 0
        let width = max(0, windowSize.width - sidebarWidth)
        let x: CGFloat = nookSettings.sidebarPosition == .left ? sidebarWidth : 0
        return CGRect(x: x, y: 0, width: width, height: windowSize.height)
    }

    private func calculateLayout(geometry: GeometryProxy) -> (frame: CGRect, cornerRadius: CGFloat) {
        let area = webArea(in: geometry.size)
        // As in Arc: most of the page area's width, leaving a margin for the buttons, and nearly its height.
        let width = area.width * 0.82
        let height = geometry.size.height - 2 * NookDesign.Spacing.md
        return (
            frame: CGRect(x: area.minX + (area.width - width) / 2, y: NookDesign.Spacing.md, width: width, height: height),
            cornerRadius: NookDesign.Radius.xl
        )
    }
}

/// Arc's Peek bar: back, forward and reload at the leading edge and the site in the middle, which
/// copies the link. It takes the page's colour, as the top bar does.
private struct PeekNavigationBar: View {
    let page: PageSession
    let cornerRadius: CGFloat
    @EnvironmentObject private var browserManager: BrowserManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var copied = false

    private var copyURLHelp: String { browserManager.help("Copy URL", shortcut: .copyCurrentURL) }

    private var pageColor: NSColor? { page.topBarBackgroundColor ?? page.pageBackgroundColor }

    var body: some View {
        ZStack {
            HStack(spacing: NookDesign.Spacing.xxs) {
                Button("Back", systemImage: "chevron.backward") { page.goBack(in: page.webView) }
                    .disabled(!page.canGoBack)
                Button("Forward", systemImage: "chevron.forward") { page.goForward() }
                    .disabled(!page.canGoForward)
                Button(page.isLoading ? "Stop" : "Reload", systemImage: page.isLoading ? "xmark" : "arrow.clockwise") {
                    page.isLoading ? page.stop() : page.refresh()
                }
                Spacer()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(NookIconButtonStyle(size: NookDesign.Size.navRow, radius: NookDesign.Radius.sm))

            Button(action: copyLink) {
                Label(page.url.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? page.url.absoluteString,
                      systemImage: copied ? "checkmark" : "link")
                    .font(NookDesign.Font.secondary)
                    .lineLimit(1)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(copyURLHelp)
            .padding(.horizontal, NookDesign.Size.navRow * 3 + NookDesign.Spacing.lg)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, NookDesign.Spacing.sm)
        .frame(height: NookDesign.Size.peekBar)
        .background(
            pageColor.map { Color(nsColor: $0) } ?? NookDesign.Surface.raised,
            in: UnevenRoundedRectangle(topLeadingRadius: cornerRadius, topTrailingRadius: cornerRadius, style: .continuous)
        )
        .environment(\.colorScheme, pageColor.map { $0.isPerceivedDark ? .dark : .light } ?? colorScheme)
    }

    private func copyLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(page.url.absoluteString, forType: .string)
        withAnimation(NookDesign.Motion.quick) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(NookDesign.Motion.quick) { copied = false }
        }
    }
}
