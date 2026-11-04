// Licensed under GPL-3.0. See LICENSE.
//
//  SplitPaneView.swift
//  Nook
//
//  One pane of the split view: a toolbar strip (back, forward, reload, address, separate, close)
//  above the page, as Arc draws it. The compositor keeps panes across refreshes so a web view
//  never leaves its superview while the pair holds.
//

import AppKit
import SwiftUI
import WebKit
import NookDesign
import NookSettings
import NookTabsCore
import NookUI
import NookWeb

final class SplitPaneView: NSView {
    // A CGColor is frozen at creation; re-resolve it when light/dark changes.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    let side: SplitViewManager.Side
    let itemID: UUID
    /// The page view's parent: the pane below the toolbar strip.
    let content = NSView()
    static let toolbarHeight = NookDesign.Size.navRow + 2 * NookDesign.Spacing.sm
    private let maskLayer = CAShapeLayer()
    private weak var settings: NookSettingsService?

    init(frame: NSRect, side: SplitViewManager.Side, itemID: UUID, browserManager: BrowserManager, windowState: BrowserWindowState, hoverManager: HoverSidebarManager) {
        self.side = side
        self.itemID = itemID
        self.settings = browserManager.nookSettings
        super.init(frame: frame)
        wantsLayer = true
        layer?.mask = maskLayer
        viewDidChangeEffectiveAppearance()
        // Fixed top margin, flexible height: the strip keeps its height as the pane resizes.
        content.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - Self.toolbarHeight))
        content.autoresizingMask = [.width, .height]
        addSubview(content)

        // Each control is its own hosting view sized to its content, so the rest of the pane
        // passes clicks to the page.
        func host(_ view: some View, textCursor: Bool = false) -> NSView {
            let host = SplitControlHostingView(rootView: view
                .environment(browserManager.tabs)
                .environment(windowState)
                .environment(\.tabActions, browserManager))
            host.usesTextCursor = textCursor
            host.translatesAutoresizingMaskIntoConstraints = false
            host.safeAreaRegions = []
            addSubview(host)
            return host
        }
        let title = host(URLBarView(isSidebarHovered: false, splitItemID: itemID)
            .environmentObject(browserManager)
            .environmentObject(hoverManager), textCursor: true)
        let buttons = host(SplitPaneButtons(itemID: itemID))
        let navigation = host(SplitPaneNavigation(itemID: itemID))
        let inset = NookDesign.Spacing.sm
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            navigation.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            navigation.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            title.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            title.centerXAnchor.constraint(equalTo: centerXAnchor).withPriority(.defaultHigh),
            title.leadingAnchor.constraint(greaterThanOrEqualTo: navigation.trailingAnchor, constant: inset),
            title.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -inset),
            buttons.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
        ])
        updateMask()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Puts `view` in the pane, leaving it alone when it is already there.
    func show(_ view: NSView) {
        content.showPage(view, inspector: (view as? WKWebView)?.dockedInspector, replacing: content.subviews)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateMask()
    }

    private func updateMask() {
        // Toggling the border resizes the pane, so this reruns through setFrameSize.
        maskLayer.path = Self.maskPath(side: side, bounds: bounds, settings: settings)
    }

    static func maskPath(side: SplitViewManager.Side, bounds: CGRect, settings: NookSettingsService?) -> CGPath {
        let radius = NookDesign.Radius.page
        let outer = settings?.hideWebContentBorder == true ? 0 : radius
        return TabCompositorWrapper.createUnevenRoundedRectPath(
            rect: bounds,
            topLeadingRadius: side == .left ? 0 : radius,
            bottomLeadingRadius: side == .left ? outer : radius,
            bottomTrailingRadius: side == .right ? outer : radius,
            topTrailingRadius: side == .right ? 0 : radius
        )
    }
}

/// Add Split View's right pane until the command bar fills it. Not a tab, so there is no page:
/// only the strip with the bar's placeholder. The bar draws the pane's close button.
final class EmptySplitPaneView: NSView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    private let maskLayer = CAShapeLayer()
    private weak var settings: NookSettingsService?

    init(frame: NSRect, settings: NookSettingsService?) {
        self.settings = settings
        super.init(frame: frame)
        wantsLayer = true
        layer?.mask = maskLayer
        viewDidChangeEffectiveAppearance()
        let strip = NSHostingView(rootView: EmptySplitPaneStrip())
        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.safeAreaRegions = []
        addSubview(strip)
        let inset = NookDesign.Spacing.sm
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            strip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            strip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
        ])
        maskLayer.path = SplitPaneView.maskPath(side: .right, bounds: bounds, settings: settings)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        maskLayer.path = SplitPaneView.maskPath(side: .right, bounds: bounds, settings: settings)
    }
}

private struct EmptySplitPaneStrip: View {
    var body: some View {
        Text(CommandPaletteView.placeholder)
            .font(NookDesign.Font.secondary)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: NookDesign.Size.navRow)
    }
}

/// Back, forward and reload for this pane's page, at the leading end of its strip.
private struct SplitPaneNavigation: View {
    let itemID: UUID

    @Environment(TabsController.self) private var tabs

    var body: some View {
        let session = tabs.session(for: itemID)
        HStack(spacing: NookDesign.Spacing.xxs) {
            SplitPaneButton(systemImage: "chevron.left", help: "Back") { session?.goBack() }
                .disabled(!(session?.canGoBackOrReturn ?? false))
            SplitPaneButton(systemImage: "chevron.right", help: "Forward") { session?.goForward() }
                .disabled(!(session?.canGoForward ?? false))
            SplitPaneButton(systemImage: "arrow.clockwise", help: "Reload") { session?.refresh() }
        }
        .frame(height: NookDesign.Size.navRow)
    }
}

/// Separate and close, at the trailing end of the pane's strip.
private struct SplitPaneButtons: View {
    let itemID: UUID

    @Environment(TabsController.self) private var tabs
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(\.tabActions) private var actions

    var body: some View {
        HStack(spacing: NookDesign.Spacing.xxs) {
            SplitPaneButton(systemImage: "rectangle.split.2x1.slash", help: "Separate Tabs") {
                actions?.separateSplit(in: windowState)
            }
            SplitPaneButton(systemImage: "xmark", help: "Close Tab") {
                tabs.close(itemID)
            }
        }
        .frame(height: NookDesign.Size.navRow)
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: NSLayoutConstraint.Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}

struct SplitPaneButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(NookDesign.Font.secondary)
                .foregroundStyle(.primary)
                .frame(width: NookDesign.Size.rowButton, height: NookDesign.Size.rowButton)
                .background(isHovering ? NookDesign.Surface.fillPressed : Color.clear)
                .clipShape(NookDesign.Radius.shape(NookDesign.Radius.sm))
        }
        .buttonStyle(PlainButtonStyle())
        .help(help)
        .onHoverTracking { isHovering = $0 }
    }
}

/// The title is hosted above WKWebView, which manages its own cursors. Register the
/// text cursor on that native host so the page and SwiftUI button cannot replace it.
private final class SplitControlHostingView<Content: View>: NSHostingView<Content> {
    var usesTextCursor = false
    private var textCursorTracking: NSTrackingArea?

    override func resetCursorRects() {
        super.resetCursorRects()
        if usesTextCursor { addCursorRect(bounds, cursor: .iBeam) }
    }

    override func updateTrackingAreas() {
        if let textCursorTracking { removeTrackingArea(textCursorTracking) }
        textCursorTracking = nil
        super.updateTrackingAreas()
        if usesTextCursor {
            let area = NSTrackingArea(rect: .zero,
                                      options: [.cursorUpdate, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            textCursorTracking = area
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        if usesTextCursor { NSCursor.iBeam.set() }
        else { super.cursorUpdate(with: event) }
    }
}
