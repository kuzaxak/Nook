// Licensed under GPL-3.0. See LICENSE.
//
//  WebsiteView.swift
//  Nook
//
//  Created by Maciek Bagiński on 28/07/2025.
//

import SwiftUI
import WebKit
import AppKit
import NookDesign
import NookWeb
import NookUI

// MARK: - Status Bar View
struct LinkStatusBar: View {
    let hoveredLink: String?
    let isCommandPressed: Bool
    let accentColor: Color
    @Environment(\.colorScheme) var colorScheme
    @State private var shouldShow: Bool = false
    @State private var hoverTask: Task<Void, Never>?
    @State private var displayedLink: String? = nil
    
    var body: some View {
        // Show the view if we have a link to display (current or last shown)
        if let link = displayedLink, !link.isEmpty {
            Text(displayText(for: link))
                .font(NookDesign.Font.secondary)
                .foregroundColor(textColor)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(.ultraThickMaterial)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(borderColor, lineWidth: 1)
                )
                .opacity(shouldShow ? 1 : 0)
                .animation(NookDesign.Motion.standard, value: shouldShow)
                .onChange(of: hoveredLink) {_,  newLink in
                    handleHoverChange(newLink: newLink)
                }
                .onAppear {
                    handleHoverChange(newLink: hoveredLink)
                }
                .onDisappear {
                    hoverTask?.cancel()
                    hoverTask = nil
                    shouldShow = false
                    displayedLink = nil
                }
        } else {
            Color.clear
                .onChange(of: hoveredLink) {_,  newLink in
                    handleHoverChange(newLink: newLink)
                }
        }
    }
    
    private func displayText(for link: String) -> String {
        let truncatedLink = truncateLink(link)
        if isCommandPressed {
            return "Open \(truncatedLink) in a new tab and focus it"
        } else {
            return truncatedLink
        }
    }
    
    private func handleHoverChange(newLink: String?) {
        // Cancel any existing task
        hoverTask?.cancel()
        hoverTask = nil
        
        if let link = newLink, !link.isEmpty {
            // New link - update displayed link immediately
            displayedLink = link
            
            // Wait then show if not already showing
            if !shouldShow {
                hoverTask = Task {
                    try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
                    if !Task.isCancelled {
                        await MainActor.run { shouldShow = true }
                    }
                }
            }
        } else {
            // Link cleared - wait then hide
            hoverTask = Task {
                try? await Task.sleep(nanoseconds: 250_000_000) // 0.25s delay
                if !Task.isCancelled {
                    await MainActor.run {
                        shouldShow = false
                    }
                    // Clear displayed link after fade out animation completes
                    try? await Task.sleep(nanoseconds: 250_000_000) // 0.25s for fade out
                    if !Task.isCancelled {
                        await MainActor.run {
                            displayedLink = nil
                        }
                    }
                }
            }
        }
    }
    
    private func truncateLink(_ link: String) -> String {
        if link.count > 60 {
            let firstPart = String(link.prefix(30))
            let lastPart = String(link.suffix(30))
            return "\(firstPart)...\(lastPart)"
        }
        return link
    }
    
    private var backgroundColor: some View {
        Group {
            if colorScheme == .dark {
                // Dark mode: gradient background using accent color
                LinearGradient(
                    gradient: Gradient(colors: [
                        accentColor,
                        lighterAccentColor
                    ]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
            } else {
                // Light mode: white background
                Color.white
            }
        }
    }
    
    private var lighterAccentColor: Color {
        #if os(macOS)
        // Blend the accent color with white for lighter variant
        let nsColor = NSColor(accentColor)
        if let blended = nsColor.blended(withFraction: 0.35, of: .white) {
            return Color(nsColor: blended)
        } else {
            return accentColor
        }
        #else
        return accentColor
        #endif
    }
    
    private var textColor: Color {
        if colorScheme == .dark {
            return Color.white
        } else {
            // Light mode: colored text using accent color
            return accentColor
        }
    }
    
    private var borderColor: Color {
        if colorScheme == .dark {
            return .white.opacity(0.2)
        } else {
            return accentColor.opacity(0.3)
        }
    }
}

struct WebsiteView: View {
    @EnvironmentObject private var hoverManager: HoverSidebarManager
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    @EnvironmentObject var splitManager: SplitViewManager
    @Environment(CommandPalette.self) private var commandPalette
    @Environment(\.nookSettings) var nookSettings
    @State private var hoveredLink: String?
    @State private var isCommandPressed: Bool = false
    @State private var isDropTargeted: Bool = false
    
    private let dragCoordinateSpace = "splitPreview"

    private var cornerRadius: CGFloat {
        nookSettings.hideWebContentBorder ? 0 : NookDesign.Radius.page
    }

    private var webViewClipShape: AnyShape {
        // The top bar and the developer bar both sit flush on the page.
        let hasTopBar = nookSettings.topBarAddressView || browserManager.showsDeveloperBar(in: windowState)

        if hasTopBar {
            return AnyShape(UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: cornerRadius,
                bottomTrailingRadius: cornerRadius,
                topTrailingRadius: 0,
                style: .continuous
            ))
        } else {
            return AnyShape(NookDesign.Radius.shape(cornerRadius))
        }
    }

    var body: some View {
        // Read observable properties directly so SwiftUI tracks changes
        let _ = windowState.compositorVersion
        ZStack() {
            Group {
                if browserManager.tabs.selectedSession(in: windowState) != nil {
                    GeometryReader { proxy in
                        TabCompositorWrapper(
                            browserManager: browserManager,
                            hoverManager: hoverManager,
                            hoveredLink: $hoveredLink,
                            isCommandPressed: $isCommandPressed,
                            splitFraction: splitManager.dividerFraction(for: windowState.id),
                            isSplit: splitManager.isSplit(for: windowState.id),
                            leftId: splitManager.leftTabId(for: windowState.id),
                            rightId: splitManager.rightTabId(for: windowState.id),
                            addSplitLeftId: showsAddSplit ? commandPalette.addSplit?.leftItemID : nil,
                            windowState: windowState,
                            compositorVersion: windowState.compositorVersion,
                            selectedItemID: windowState.selectedItemID,
                            cornerRadius: cornerRadius,
                            squareTopCorners: nookSettings.topBarAddressView || browserManager.showsDeveloperBar(in: windowState)
                        )
                        .coordinateSpace(name: dragCoordinateSpace)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { commandPalette.pageFrame = $0 }
                        // The page-frame shadow is drawn separately by WindowView, and the
                        // corners come from the container layer's cornerRadius. A clipShape mask,
                        // shadow or compositingGroup on this branch recomposites the
                        // WKWebView's live video layer and flashes it black one frame at a
                        // time during playback.
                        .background(
                            webViewClipShape
                                .fill(shouldShowSplit ? Color.clear : Color(nsColor: .windowBackgroundColor))
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // Critical: Use allowsHitTesting to prevent SwiftUI from intercepting mouse events
                        // This allows right-clicks to pass through to the underlying NSView (WKWebView)
                        .allowsHitTesting(!browserManager.dialogManager.isVisible)
                        .contentShape(Rectangle())
                    }
                    // Removed SwiftUI contextMenu - it intercepts ALL right-clicks
                    // WKWebView's willOpenMenu will handle context menus for images
                } else {
                    EmptyWebsiteView()
                }
            }
            VStack {
                Spacer()
                if nookSettings.showLinkStatusBar {
                    HStack {
                        LinkStatusBar(
                            hoveredLink: hoveredLink,
                            isCommandPressed: isCommandPressed,
                            accentColor: browserManager.gradientColorManager.accentColor
                        )
                        .padding(10)
                        Spacer()
                    }
                }
                
            }
            
            // WebKit's PDF bar is off (BrowserConfiguration.applyPlatformPreferences); these replace it.
            if !shouldShowSplit,
               let session = browserManager.tabs.controllableSession(in: windowState),
               session.isDisplayingPDF,
               let webView = browserManager.getWebView(for: session.itemID, in: windowState.id) {
                VStack {
                    Spacer()
                    PDFControlsView(session: session, webView: webView)
                        .padding(.bottom, NookDesign.Spacing.xxxl)
                }
            }

            if !shouldShowSplit, let session = browserManager.tabs.controllableSession(in: windowState) {
                BlockedPageView(session: session)
            }

            // Link Previews: Shift held over a link in the page.
            if nookSettings.linkPreviews, !shouldShowSplit,
               let session = browserManager.tabs.controllableSession(in: windowState),
               !session.isPrivate, !session.isAgentPage {
                LinkPreviewHost(
                    session: session,
                    zoom: browserManager.getWebView(for: session.itemID, in: windowState.id)?.pageZoom ?? 1,
                    blocker: browserManager.contentBlockerManager)
                    .id(session.itemID)
            }

            // The unselected split pane can be translated from its context menu too.
            if shouldShowSplit, let other = [splitManager.leftTabId(for: windowState.id), splitManager.rightTabId(for: windowState.id)]
                .compactMap({ $0 }).first(where: { $0 != windowState.selectedItemID }),
               let session = browserManager.tabs.session(for: other) {
                TranslationTaskHost(session: session)
            }

            if let session = browserManager.tabs.controllableSession(in: windowState) {
                TranslationTaskHost(session: session)
                if let language = session.translationOffer, !session.isTranslated {
                    VStack {
                        TranslateOfferView(session: session, language: language)
                            .padding(.top, NookDesign.Spacing.lg)
                        Spacer()
                    }
                } else if let notice = session.translationNotice, session.isTranslated {
                    VStack {
                        TranslationNoticeView(session: session, notice: notice)
                            .padding(.top, NookDesign.Spacing.lg)
                        Spacer()
                    }
                }
                if let offer = browserManager.autofillManager.saveOffer, offer.itemID == session.itemID {
                    VStack {
                        VaultSaveOfferView(offer: offer) { browserManager.autofillManager.answerSaveOffer($0) }
                            .padding(.top, NookDesign.Spacing.lg)
                        Spacer()
                    }
                }
            }

            // History, as a page over the web content (Cmd-Y).
            if windowState.isHistoryPageVisible {
                HistoryPageView()
                    .environmentObject(browserManager)
                    .environment(windowState)
                    .clipShape(webViewClipShape)
                    .transition(.opacity.combined(with: .scale(scale: 0.99)))
            }

            // Split preview overlay - shows cards during drag operations
            if splitManager.getSplitState(for: windowState.id).isPreviewActive {
                SplitPreviewOverlay()
                    .environmentObject(splitManager)
                    .environmentObject(browserManager)
                    .environment(windowState)
                    .coordinateSpace(name: dragCoordinateSpace)
                    .animation(
                        NookDesign.Motion.spring,
                        value: splitManager.getSplitState(for: windowState.id).isPreviewActive
                    )
            }

            // A glance or a screenshot of the window shows that an agent drives this page.
            if windowState.spaceID != nil, windowState.spaceID == browserManager.tabs.agentSpaceID {
                AgentFrame(shape: webViewClipShape, busy: browserManager.tabs.agentCallsInFlight > 0)
            }
        }
    }

}

/// The Agent space's frame and label over its page. Never takes a click.
private struct AgentFrame: View {
    let shape: AnyShape
    let busy: Bool

    var body: some View {
        shape.stroke(NookDesign.Surface.agentGradient, lineWidth: NookDesign.Surface.agentFrameWidth)
            .overlay(alignment: .top) {
                Label("Agent", systemImage: "sparkles")
                    .font(NookDesign.Font.captionStrong)
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, isActive: busy)
                    .padding(.horizontal, NookDesign.Spacing.md)
                    .padding(.vertical, NookDesign.Spacing.xs)
                    .background(NookDesign.Surface.agentGradient, in: Capsule())
                    .padding(.top, NookDesign.Spacing.md)
            }
            .allowsHitTesting(false)
    }
}

// MARK: - Split Preview Overlay
/// While a tab is dragged over the page, each half of it is a drop target, as in Arc: the half
/// under the pointer lights up and dropping there puts the tab on that side.
private struct SplitPreviewOverlay: View {
    @EnvironmentObject var splitManager: SplitViewManager
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState

    var body: some View {
        let splitState = splitManager.getSplitState(for: windowState.id)
        HStack(spacing: NookDesign.Spacing.md) {
            zone(.left, isSplit: splitState.activeSide != nil, hovered: splitState.previewSide == .left)
            zone(.right, isSplit: splitState.activeSide != nil, hovered: splitState.previewSide == .right)
        }
        .padding(NookDesign.Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .animation(NookDesign.Motion.quick, value: splitState.previewSide)
    }

    private func zone(_ side: SplitViewManager.Side, isSplit: Bool, hovered: Bool) -> some View {
        let accent = browserManager.gradientColorManager.accentColor
        let shape = NookDesign.Radius.shape(NookDesign.Radius.page)
        return shape
            .fill(accent.opacity(hovered ? 0.22 : 0.05))
            .overlay(shape.strokeBorder(accent.opacity(hovered ? 0.9 : 0.25), lineWidth: hovered ? 2 : 1))
            .overlay {
                VStack(spacing: NookDesign.Spacing.sm) {
                    Image(systemName: side == .left ? "rectangle.lefthalf.filled" : "rectangle.righthalf.filled")
                        .font(.system(size: 28, weight: .medium))
                    Text(isSplit ? (side == .left ? "Replace left side" : "Replace right side")
                                 : (side == .left ? "Open on the left" : "Open on the right"))
                        .font(NookDesign.Font.label)
                }
                .foregroundStyle(hovered ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
                .opacity(hovered ? 1 : 0.6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Tab Compositor Wrapper
struct TabCompositorWrapper: NSViewRepresentable {
    let browserManager: BrowserManager
    let hoverManager: HoverSidebarManager
    @Binding var hoveredLink: String?
    @Binding var isCommandPressed: Bool
    var splitFraction: CGFloat
    var isSplit: Bool
    var leftId: UUID?
    var rightId: UUID?
    var addSplitLeftId: UUID?
    let windowState: BrowserWindowState
    var compositorVersion: Int
    var selectedItemID: UUID?
    var cornerRadius: CGFloat
    var squareTopCorners: Bool

    /// Rounds the container's own layer instead of masking the SwiftUI branch:
    /// CALayer.cornerRadius composites directly, while a shape mask over the
    /// hosted WKWebView flashed its video layer black during playback.
    private func applyCornerRadius(to containerView: NSView) {
        guard let layer = containerView.layer else { return }
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        let bottom: CACornerMask = containerView.isFlipped
            ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        let top: CACornerMask = containerView.isFlipped
            ? [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            : [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        layer.maskedCorners = squareTopCorners ? bottom : bottom.union(top)
    }

    class Coordinator {
        weak var browserManager: BrowserManager?
        let windowState: BrowserWindowState
        var lastIsSplit: Bool = false
        var lastLeftId: UUID? = nil
        var lastRightId: UUID? = nil
        var lastAddSplitLeftId: UUID? = nil
        var lastCurrentId: UUID? = nil
        var lastFraction: CGFloat = -1
        var lastSize: CGSize = .zero
        var lastVersion: Int = -1
        var frameObserver: NSObjectProtocol? = nil
        init(browserManager: BrowserManager?, windowState: BrowserWindowState) {
            self.browserManager = browserManager
            self.windowState = windowState
        }
        deinit {
            if let token = frameObserver {
                NotificationCenter.default.removeObserver(token)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(browserManager: browserManager, windowState: windowState) }

    func makeNSView(context: Context) -> NSView {
        let containerView = ContainerView()
        containerView.wantsLayer = true
        // Use windowBackgroundColor instead of clear to prevent black flashes during
        // video playback when the WKWebView's GPU compositing layer briefly shows through.
        containerView.viewDidChangeEffectiveAppearance()
        applyCornerRadius(to: containerView)
        containerView.postsFrameChangedNotifications = true

        // Store reference to container view in WebViewCoordinator
        browserManager.webViewCoordinator?.setCompositorContainerView(containerView, for: windowState.id)
        
        // Install AppKit drag-capture overlay above all webviews
        let overlay = SplitDropCaptureView(frame: containerView.bounds)
        overlay.autoresizingMask = [NSView.AutoresizingMask.width, NSView.AutoresizingMask.height]
        overlay.browserManager = browserManager
        overlay.splitManager = browserManager.splitManager
        overlay.layer?.zPosition = 10_000
        containerView.addSubview(overlay)

        // Observe size changes to recompute pane layout when available width changes
        let coord = context.coordinator
        // MEMORY LEAK FIX: Capture coord weakly to break potential retain cycle
        // Coordinator → frameObserver token → closure → Coordinator
        coord.frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: containerView,
            queue: .main
        ) { [weak containerView, weak coord] _ in
            guard let cv = containerView else { return }
            // Only rebuild when bounds size actually changed — spurious frame
            // notifications (e.g. from SwiftUI layout passes) should not trigger
            // a compositor rebuild that could interrupt video playback.
            let newSize = cv.bounds.size
            guard coord?.lastSize != newSize else { return }
            updateCompositor(cv)
            coord?.lastSize = newSize
        }

        // Set up link hover callbacks for the selected page
        if let session = browserManager.tabs.selectedSession(in: windowState) {
            setupHoverCallbacks(for: session)
        }
        
        return containerView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        applyCornerRadius(to: nsView)
        // Only rebuild compositor when meaningful inputs change
        let size = nsView.bounds.size
        let currentId = windowState.selectedItemID
        let compositorVersion = windowState.compositorVersion
        let needsRebuild =
            context.coordinator.lastIsSplit != isSplit ||
            context.coordinator.lastLeftId != leftId ||
            context.coordinator.lastRightId != rightId ||
            context.coordinator.lastAddSplitLeftId != addSplitLeftId ||
            context.coordinator.lastCurrentId != currentId ||
            abs(CGFloat(context.coordinator.lastFraction) - CGFloat(splitFraction)) > 0.0001 ||
            context.coordinator.lastSize != size ||
            context.coordinator.lastVersion != compositorVersion

        if needsRebuild {
            let previousCurrentId = context.coordinator.lastCurrentId
            updateCompositor(nsView)
            context.coordinator.lastIsSplit = isSplit
            context.coordinator.lastLeftId = leftId
            context.coordinator.lastRightId = rightId
            context.coordinator.lastAddSplitLeftId = addSplitLeftId
            context.coordinator.lastCurrentId = currentId
            context.coordinator.lastFraction = splitFraction
            context.coordinator.lastSize = size
            context.coordinator.lastVersion = compositorVersion

            // Restore focus when tab changed (webview is now in hierarchy)
            if previousCurrentId != currentId {
                DispatchQueue.main.async {
                    guard let window = nsView.window else { return }
                    for subview in nsView.subviews.reversed() {
                        if subview is SplitDropCaptureView { continue }
                        if let webView = subview as? WKWebView, !webView.isHidden {
                            window.makeFirstResponder(webView)
                            return
                        }
                        // Split view: the selected pane's page
                        // A docked Web Inspector, itself a WKWebView, sits below its page.
                        if let pane = subview as? SplitPaneView, pane.itemID == currentId,
                           let webView = pane.content.subviews.last(where: { $0 is WKWebView }) {
                            window.makeFirstResponder(webView)
                            return
                        }
                    }
                }
            }
        }
        
        // Mark the selected page as accessed (resets its unload timer)
        if let session = browserManager.tabs.selectedSession(in: windowState) {
            browserManager.compositorManager.markTabAccessed(session.itemID)
            setupHoverCallbacks(for: session)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.browserManager?.webViewCoordinator?.removeCompositorContainerView(for: coordinator.windowState.id)
    }

    private func updateCompositor(_ containerView: NSView) {
        // Non-destructive compositor: avoid removing/re-adding WKWebViews that are
        // already correctly positioned. Removing a WKWebView from its superview
        // disconnects its GPU video surface, causing black flashes during playback.

        let tabs = browserManager.tabs
        let selected = tabs.selectedSession(in: windowState)
        let split = browserManager.splitManager

        // While fullscreen, WebKit's window holds the page and leaves a placeholder here. Moving
        // either strands the page off screen when fullscreen ends, still playing.
        let pages = [selected] + [split.leftTabId(for: windowState.id), split.rightTabId(for: windowState.id)]
            .map { $0.flatMap(tabs.session(for:)) }
        if pages.contains(where: { ($0?.webView?.fullscreenState ?? .notInFullscreen) != .notInFullscreen }) { return }

        // Identify overlay (always preserved)
        let overlay = containerView.subviews.compactMap { $0 as? SplitDropCaptureView }.first
        // Keep the drop overlay and resize divider separate from page content.
        let contentSubviews = containerView.subviews.filter {
            !($0 is SplitDropCaptureView) && !($0 is SplitDividerView)
        }

        // A drag preview leaves the panes alone; the drop cards draw over them.
        let currentId = selected?.itemID
        let leftId = split.leftTabId(for: windowState.id)
        let rightId = split.rightTabId(for: windowState.id)
        let isCurrentPane = (currentId != nil) && (currentId == leftId || currentId == rightId)
        let adding = windowState.commandPalette?.addSplit.flatMap {
            $0.shows(selectedItemID: currentId, split: windowState.splitPair) ? $0 : nil
        }

        if isCurrentPane, let leftId, let rightId,
           let leftSession = tabs.ensureSession(for: leftId),
           let rightSession = tabs.ensureSession(for: rightId) {
            (containerView as? ContainerView)?.showsSplit = true
            let total = containerView.bounds
            let (leftRect, rightRect) = SplitViewManager.paneFrames(in: total, fraction: split.dividerFraction(for: windowState.id))

            let divider: SplitDividerView
            if let existing = containerView.subviews.compactMap({ $0 as? SplitDividerView }).first {
                divider = existing
            } else {
                divider = SplitDividerView()
                containerView.addSubview(divider)
            }
            divider.isHidden = false
            divider.frame = NSRect(x: leftRect.maxX, y: total.minY,
                                   width: rightRect.minX - leftRect.maxX, height: total.height)
            divider.fraction = split.dividerFraction(for: windowState.id)
            divider.onResize = { [weak windowState] fraction in
                guard let windowState, var record = windowState.split else { return }
                record.fraction = Double(fraction)
                windowState.split = record
            }
            divider.onResizeEnded = { [weak browserManager, weak windowState] in
                guard let windowState else { return }
                browserManager?.tabs.mirror(windowState)
            }

            // A pane stays while its side keeps its tab: taking a WKWebView out of its superview
            // drops its video surface, so a selection change, or filling Add Split View's empty
            // pane, leaves the page in place.
            let existing = contentSubviews.compactMap { $0 as? SplitPaneView }
            let panes = [(SplitViewManager.Side.left, leftId, leftRect), (.right, rightId, rightRect)].map { side, id, rect in
                existing.first { $0.side == side && $0.itemID == id }
                    ?? SplitPaneView(frame: rect, side: side, itemID: id, browserManager: browserManager, windowState: windowState, hoverManager: hoverManager)
            }
            removeContentViews(contentSubviews.filter { view in !panes.contains { $0 === view } })
            for pane in panes where pane.superview !== containerView { containerView.addSubview(pane) }

            for (pane, session, rect) in [(panes[0], leftSession, leftRect), (panes[1], rightSession, rightRect)] {
                pane.frame = rect
                pane.show(pageView(for: session, reusing: pane.content.subviews))
            }
        } else if let adding, let session = tabs.ensureSession(for: adding.leftItemID) {
            (containerView as? ContainerView)?.showsSplit = true
            containerView.subviews.compactMap { $0 as? SplitDividerView }.forEach { $0.isHidden = true }
            let (leftRect, rightRect) = SplitViewManager.paneFrames(in: containerView.bounds, fraction: 0.5)
            let left = contentSubviews.compactMap { $0 as? SplitPaneView }.first { $0.side == .left && $0.itemID == adding.leftItemID }
                ?? SplitPaneView(frame: leftRect, side: .left, itemID: adding.leftItemID, browserManager: browserManager, windowState: windowState, hoverManager: hoverManager)
            let empty = contentSubviews.compactMap { $0 as? EmptySplitPaneView }.first
                ?? EmptySplitPaneView(frame: rightRect, settings: browserManager.nookSettings)
            removeContentViews(contentSubviews.filter { $0 !== left && $0 !== empty })
            for pane in [left, empty] where pane.superview !== containerView { containerView.addSubview(pane) }
            left.frame = leftRect
            empty.frame = rightRect
            left.show(pageView(for: session, reusing: left.content.subviews))
        } else {
            (containerView as? ContainerView)?.showsSplit = false
            containerView.subviews.compactMap { $0 as? SplitDividerView }.forEach { $0.isHidden = true }
            // Single tab (most common path during video playback)
            if let session = selected, !session.isUnloaded {
                let page = pageView(for: session, reusing: contentSubviews)
                containerView.showPage(page, inspector: (page as? WKWebView)?.dockedInspector, replacing: contentSubviews)
            } else {
                removeContentViews(contentSubviews)
            }
        }

        // Ensure overlay is on top
        if let overlay = overlay {
            overlay.frame = containerView.bounds
            overlay.autoresizingMask = [NSView.AutoresizingMask.width, NSView.AutoresizingMask.height]
            overlay.browserManager = browserManager
            overlay.splitManager = browserManager.splitManager
            overlay.windowId = windowState.id
            // Re-order to top if needed
            if overlay !== containerView.subviews.last {
                overlay.removeFromSuperview()
                containerView.addSubview(overlay)
            }
            overlay.layer?.zPosition = 10_000
        } else {
            let newOverlay = SplitDropCaptureView(frame: containerView.bounds)
            newOverlay.autoresizingMask = [NSView.AutoresizingMask.width, NSView.AutoresizingMask.height]
            newOverlay.browserManager = browserManager
            newOverlay.splitManager = browserManager.splitManager
            newOverlay.windowId = windowState.id
            newOverlay.layer?.zPosition = 10_000
            containerView.addSubview(newOverlay)
        }
    }

    /// Removes all non-overlay content subviews
    private func removeContentViews(_ contentSubviews: [NSView]) {
        for subview in contentSubviews {
            subview.removeFromSuperview()
        }
    }

    static func createUnevenRoundedRectPath(
        rect: CGRect,
        topLeadingRadius: CGFloat,
        bottomLeadingRadius: CGFloat,
        bottomTrailingRadius: CGFloat,
        topTrailingRadius: CGFloat
    ) -> CGPath {
        let path = CGMutablePath()
        
        let minX = rect.minX
        let minY = rect.minY
        let maxX = rect.maxX
        let maxY = rect.maxY
        
        // Start from top-left, move clockwise
        path.move(to: CGPoint(x: minX + topLeadingRadius, y: maxY))
        
        // Top edge to top-right corner
        path.addLine(to: CGPoint(x: maxX - topTrailingRadius, y: maxY))
        if topTrailingRadius > 0 {
            path.addArc(tangent1End: CGPoint(x: maxX, y: maxY), tangent2End: CGPoint(x: maxX, y: maxY - topTrailingRadius), radius: topTrailingRadius)
        }
        
        // Right edge to bottom-right corner
        path.addLine(to: CGPoint(x: maxX, y: minY + bottomTrailingRadius))
        if bottomTrailingRadius > 0 {
            path.addArc(tangent1End: CGPoint(x: maxX, y: minY), tangent2End: CGPoint(x: maxX - bottomTrailingRadius, y: minY), radius: bottomTrailingRadius)
        }
        
        // Bottom edge to bottom-left corner
        path.addLine(to: CGPoint(x: minX + bottomLeadingRadius, y: minY))
        if bottomLeadingRadius > 0 {
            path.addArc(tangent1End: CGPoint(x: minX, y: minY), tangent2End: CGPoint(x: minX, y: minY + bottomLeadingRadius), radius: bottomLeadingRadius)
        }
        
        // Left edge to top-left corner
        path.addLine(to: CGPoint(x: minX, y: maxY - topLeadingRadius))
        if topLeadingRadius > 0 {
            path.addArc(tangent1End: CGPoint(x: minX, y: maxY), tangent2End: CGPoint(x: minX + topLeadingRadius, y: maxY), radius: topLeadingRadius)
        }
        
        path.closeSubpath()
        return path
    }

    private func setupHoverCallbacks(for session: PageSession) {
        // Set up link hover callback
        session.onLinkHover = { [self] href in
            DispatchQueue.main.async {
                self.hoveredLink = href
                if let href = href {
                }
            }
        }
        
        // Set up command hover callback
        session.onCommandHover = { [self] href in
            DispatchQueue.main.async {
                self.isCommandPressed = href != nil
            }
        }
    }

    /// The session's live view when this window holds it, else the "Open in another window"
    /// placeholder (reused from `existing` when it already stands in for this item).
    private func pageView(for session: PageSession, reusing existing: [NSView]) -> NSView {
        let tabs = browserManager.tabs
        guard tabs.isPageShownElsewhere(session.itemID, from: windowState) else {
            return webView(for: session, windowId: windowState.id)
        }
        if let host = existing.compactMap({ $0 as? PageElsewhereHostView }).first(where: { $0.itemID == session.itemID }) {
            return host
        }
        let itemID = session.itemID
        let window = windowState
        return PageElsewhereHostView(itemID: itemID, rootView: PageElsewhereView(
            title: session.title,
            onShowHere: { tabs.takeControl(itemID, in: window) },
            onGoToWindow: { tabs.showOwnerWindow(of: itemID) }
        ))
    }

    private func webView(for session: PageSession, windowId: UUID) -> WKWebView {
        // One view per window: the session's primary in the first window, clones elsewhere.
        guard let coordinator = browserManager.webViewCoordinator else { return session.activeWebView }
        return coordinator.createWebView(for: session, in: windowId)
    }


}

// MARK: - WebsiteView Extensions

private extension WebsiteView {
    var showsAddSplit: Bool {
        commandPalette.addSplit?.shows(selectedItemID: windowState.selectedItemID, split: windowState.splitPair) == true
    }

    var shouldShowSplit: Bool {
        if showsAddSplit { return true }
        guard splitManager.isSplit(for: windowState.id) else { return false }
        guard let current = windowState.selectedItemID else { return false }
        return current == splitManager.leftTabId(for: windowState.id) || current == splitManager.rightTabId(for: windowState.id)
    }
}

// MARK: - Container View that forwards right-clicks to webviews

/// Native events keep the drag captured when the pointer moves over either web page.
private final class SplitDividerView: NSView {
    var fraction: CGFloat = 0.5
    var onResize: ((CGFloat) -> Void)?
    var onResizeEnded: (() -> Void)?
    private var dragStartX: CGFloat?
    private var dragStartFraction: CGFloat = 0.5

    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        if !isHidden { addCursorRect(bounds, cursor: .resizeLeftRight) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let parent = superview else { return }
        dragStartX = parent.convert(event.locationInWindow, from: nil).x
        dragStartFraction = fraction
    }

    override func mouseDragged(with event: NSEvent) {
        guard let parent = superview, let dragStartX, parent.bounds.width > 0 else { return }
        let x = parent.convert(event.locationInWindow, from: nil).x
        let minimum = min(0.45, 160 / parent.bounds.width)
        let proposed = dragStartFraction + (x - dragStartX) / parent.bounds.width
        onResize?(min(1 - minimum, max(minimum, proposed)))
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStartX != nil else { return }
        mouseDragged(with: event)
        dragStartX = nil
        onResizeEnded?()
    }
}

private class ContainerView: NSView {
    var showsSplit = false {
        didSet { if showsSplit != oldValue { updateBackground() } }
    }

    // Only the actual pages need the opaque video fallback. The split gutter must show
    // the single window-coordinate theme underneath, including its gradient and grain.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = showsSplit ? NSColor.clear.cgColor : NSColor.windowBackgroundColor.cgColor
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let target = super.hitTest(point)
        // Exposed gutter belongs to the window frame; panes and their controls still
        // receive their own clicks, context menus and page selection normally.
        return target === self ? nil : target
    }

    // Don't intercept events - let them pass through to webviews
    override var acceptsFirstResponder: Bool { false }

    override func resetCursorRects() {
        // Empty: prevents NSHostingView and other ancestors from registering
        // arrow cursor rects over the webview. WKWebView uses NSCursor.set()
        // internally, which works correctly when cursor rects don't override it.
    }

    // Forward right-clicks to the webview below so context menus work
    override func rightMouseDown(with event: NSEvent) {
        // Find the webview at this point and forward the event
        let point = convert(event.locationInWindow, from: nil)
        // Use hitTest to find the actual view at this point (will skip overlay if hitTest returns nil)
        if let hitView = hitTest(point) {
            if let webView = hitView as? WKWebView {
                webView.rightMouseDown(with: event)
                return
            }
            // Check if hitView contains a webview
            if let webView = findWebView(in: hitView, at: point) {
                webView.rightMouseDown(with: event)
                return
            }
        }
        // Fallback: search all subviews
        for subview in subviews.reversed() {
            if let webView = findWebView(in: subview, at: point) {
                webView.rightMouseDown(with: event)
                return
            }
        }
        super.rightMouseDown(with: event)
    }
    
    private func findWebView(in view: NSView, at point: NSPoint) -> WKWebView? {
        let pointInView = view.convert(point, from: self)
        if view.bounds.contains(pointInView) {
            if let webView = view as? WKWebView {
                return webView
            }
            for subview in view.subviews {
                if let webView = findWebView(in: subview, at: point) {
                    return webView
                }
            }
        }
        return nil
    }
}
