// Licensed under GPL-3.0. See LICENSE.
//
//  SplitPaneView.swift
//  Nook
//
//  One pane of the split view: a toolbar strip (back, forward, reload, address, the split menu,
//  close) above the page, as Arc draws it. The compositor keeps panes across refreshes so a web
//  view never leaves its superview while the split holds.
//

import AppKit
import SwiftUI
import WebKit
import NookDesign
import NookSettings
import NookTabsCore
import NookUI
import NookWeb

/// Where a pane sits in its split, which decides the corners it rounds.
struct SplitPanePosition: Equatable {
    var index: Int
    var count: Int
    var vertical: Bool
}

final class SplitPaneView: NSView {
    // A CGColor is frozen at creation; re-resolve it when light/dark changes.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    var position: SplitPanePosition {
        didSet { if position != oldValue { updateMask() } }
    }
    let itemID: UUID
    /// The page view's parent: the pane below the toolbar strip.
    let content = NSView()
    static let toolbarHeight = NookDesign.Size.navRow + 2 * NookDesign.Spacing.sm
    private let maskLayer = CAShapeLayer()
    private weak var settings: NookSettingsService?

    init(frame: NSRect, position: SplitPanePosition, itemID: UUID, browserManager: BrowserManager, windowState: BrowserWindowState, hoverManager: HoverSidebarManager) {
        self.position = position
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
        let buttons = host(SplitPaneButtons(itemID: itemID, split: browserManager.splitManager))
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
        maskLayer.path = Self.maskPath(position: position, bounds: bounds, settings: settings)
    }

    /// A corner between two of the page's own edges keeps the page's shape: square at the top,
    /// where the container rounds it, and the page radius at the bottom. Corners on the gutter
    /// round off.
    static func maskPath(position: SplitPanePosition, bounds: CGRect, settings: NookSettingsService?) -> CGPath {
        let radius = NookDesign.Radius.page
        let outer = settings?.hideWebContentBorder == true ? 0 : radius
        let first = position.index == 0, last = position.index == position.count - 1
        let leading = position.vertical || first, trailing = position.vertical || last
        let top = !position.vertical || first, bottom = !position.vertical || last
        return TabCompositorWrapper.createUnevenRoundedRectPath(
            rect: bounds,
            topLeadingRadius: top && leading ? 0 : radius,
            bottomLeadingRadius: bottom && leading ? outer : radius,
            bottomTrailingRadius: bottom && trailing ? outer : radius,
            topTrailingRadius: top && trailing ? 0 : radius
        )
    }
}

/// Add Split View's new pane until the command bar fills it. Not a tab, so there is no page:
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
    var position: SplitPanePosition {
        didSet { if position != oldValue { updateMask() } }
    }

    init(frame: NSRect, position: SplitPanePosition, settings: NookSettingsService?) {
        self.settings = settings
        self.position = position
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
        updateMask()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateMask()
    }

    private func updateMask() {
        maskLayer.path = SplitPaneView.maskPath(position: position, bounds: bounds, settings: settings)
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

/// The split menu and close, at the trailing end of the pane's strip.
private struct SplitPaneButtons: View {
    let itemID: UUID
    let split: SplitViewManager

    @Environment(TabsController.self) private var tabs

    var body: some View {
        HStack(spacing: NookDesign.Spacing.xxs) {
            SplitPaneMenu(itemID: itemID, split: split)
            SplitPaneButton(systemImage: "xmark", help: "Close Tab") {
                tabs.close(itemID)
            }
        }
        .frame(height: NookDesign.Size.navRow)
    }
}

/// Arc's split button: move the pane, add an empty one beside it, take its tab out of the split,
/// or turn the split on its side.
private struct SplitPaneMenu: View {
    let itemID: UUID
    let split: SplitViewManager

    @Environment(BrowserWindowState.self) private var windowState
    @State private var isHovering = false

    var body: some View {
        let record = windowState.split
        let index = record?.itemIDs.firstIndex(of: itemID)
        let vertical = record?.orientation == .vertical
        let canAdd = record?.isFull == false
        Menu {
            Button {
                split.move(itemID, by: -1, in: windowState)
            } label: {
                Label(vertical ? "Move Up" : "Move Left", systemImage: vertical ? "arrow.up" : "arrow.left")
            }
            .disabled(index == nil || index == 0)
            Button {
                split.move(itemID, by: 1, in: windowState)
            } label: {
                Label(vertical ? "Move Down" : "Move Right", systemImage: vertical ? "arrow.down" : "arrow.right")
            }
            .disabled(index == nil || index == (record?.itemIDs.count ?? 0) - 1)
            Divider()
            Button {
                split.addSplit(beside: itemID, after: true, in: windowState)
            } label: {
                Label(vertical ? "Add Below" : "Add Right Split", systemImage: vertical ? "rectangle.bottomhalf.inset.filled" : "rectangle.righthalf.inset.filled")
            }
            .disabled(!canAdd)
            Button {
                split.addSplit(beside: itemID, after: false, in: windowState)
            } label: {
                Label(vertical ? "Add Above" : "Add Left Split", systemImage: vertical ? "rectangle.tophalf.inset.filled" : "rectangle.lefthalf.inset.filled")
            }
            .disabled(!canAdd)
            Divider()
            Button {
                split.separate(itemID, in: windowState)
            } label: {
                Label("Separate Tab from Split", systemImage: "rectangle.split.2x1.slash")
            }
            Button {
                split.convert(in: windowState)
            } label: {
                Label(vertical ? "Convert to Horizontal Split View" : "Convert to Vertical Split View",
                      systemImage: vertical ? "rectangle.split.2x1" : "rectangle.split.1x2")
            }
        } label: {
            Image(systemName: vertical ? "rectangle.split.1x2" : "rectangle.split.2x1")
                .font(NookDesign.Font.secondary)
                .foregroundStyle(.primary)
                .frame(width: NookDesign.Size.rowButton, height: NookDesign.Size.rowButton)
                .background(isHovering ? NookDesign.Surface.fillPressed : Color.clear)
                .clipShape(NookDesign.Radius.shape(NookDesign.Radius.sm))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Split View")
        .onHoverTracking { isHovering = $0 }
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
