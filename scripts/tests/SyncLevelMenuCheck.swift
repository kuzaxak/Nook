// Licensed under GPL-3.0. See LICENSE.
//
//  mkdir -p /tmp/sync-level-menu-check
//  swiftc -emit-library -emit-module -module-name NookTabsCore Packages/NookTabsCore/Sources/NookTabsCore/*.swift \
//         -emit-module-path /tmp/sync-level-menu-check/NookTabsCore.swiftmodule -o /tmp/sync-level-menu-check/libNookTabsCore.dylib
//  swiftc -parse-as-library -I /tmp/sync-level-menu-check -L /tmp/sync-level-menu-check -lNookTabsCore \
//         -Xlinker -rpath -Xlinker /tmp/sync-level-menu-check \
//         Packages/NookUI/Sources/NookUI/SpaceSyncControls.swift Packages/NookUI/Sources/NookUI/Settings/SpaceSyncMenu.swift \
//         scripts/tests/SyncLevelMenuCheck.swift -o /tmp/sync-level-menu-check/check && /tmp/sync-level-menu-check/check
//
//  A space's iCloud Sync menu in Settings offers every level, checks the current one, and choosing
//  a level sets it and changes the cloud. The row sits in a grouped Form under a custom
//  ToggleStyle, as in the Settings window, in a window off screen. The menu is read through
//  Accessibility, as VoiceOver reads it, so the terminal needs Accessibility access.

import AppKit
import ApplicationServices
import NookTabsCore
import Observation
import SwiftUI

@MainActor @Observable
private final class Sync: SpaceSyncControls {
    var status = SpaceSyncStatus(availability: .available)
    var levels: [UUID: SpaceSyncLevel] = [:]
    var chosen: [SpaceSyncLevel] = []

    func level(of spaceID: UUID) -> SpaceSyncLevel { levels[spaceID] ?? .off }
    func setLevel(_ level: SpaceSyncLevel, for spaceID: UUID) {
        chosen.append(level)
        levels[spaceID] = level
    }
    func syncNow() {}
    var cloudSpaces: [SpaceSyncCloudSpace] = []
    var cloudDevices: [String] = []
    func removeFromICloud(_ spaceID: UUID) {}
    func syncReport() -> String { "" }
    func shareWithAnotherAccount() {}
    func stopSharing() {}
    func joinSharedSync(link: String) {}
    func leaveSharedSync() {}
}

/// SettingsWindow's switch style.
private struct SettingsSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration)
            .toggleStyle(.switch)
            .controlSize(.small)
    }
}

private struct Pane: View {
    let space: SpaceRecord
    let sync: Sync

    var body: some View {
        Form {
            Section("Spaces") {
                HStack {
                    Text(space.name)
                    Spacer()
                    SpaceSyncMenu(space: space, sync: sync)
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(SettingsSwitch())
    }
}

struct Item {
    let element: AXUIElement
    let title: String
    let enabled: Bool
    let checked: Bool
}

@main
@MainActor
struct SyncLevelMenuCheck {
    nonisolated static let levels = SpaceSyncLevel.allCases.map(\.title)

    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard AXIsProcessTrusted() else { fail("give the terminal Accessibility access in System Settings") }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let space = SpaceRecord(name: "Work", icon: "", accentHex: "#336699", order: OrderKey("a"))
        let sync = Sync()
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 500, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Pane(space: space, sync: sync))
        window.orderBack(nil)

        let pid = getpid()
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 1)
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, 3)

            let offButton = button(in: axApp, labelled: "iCloud Sync for Work: Off")
            let offSymbol = onMain { popUp(in: window)?.image?.accessibilityDescription }
            let first = open(offButton, in: window)
            expect(first.map(\.title) == levels, "the menu offers \(levels), got \(first.map(\.title))")
            expect(first.allSatisfy(\.enabled), "every level can be chosen: \(describe(first))")
            expect(first.map(\.checked) == [true, false, false], "Off is checked: \(describe(first))")

            let everything = first[2]
            AXUIElementPerformAction(everything.element, kAXPressAction as CFString)
            Thread.sleep(forTimeInterval: 0.5)
            let chosen = onMain { sync.chosen }
            expect(chosen == [.everything], "choosing Everything sets it once, got \(chosen)")

            let everythingButton = button(in: axApp, labelled: "iCloud Sync for Work: Everything")
            let everythingSymbol = onMain { popUp(in: window)?.image?.accessibilityDescription }
            let drawn = [offSymbol, everythingSymbol]
            let expected = [SpaceSyncLevel.off, .everything].map {
                NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil)?.accessibilityDescription
            }
            expect(drawn == expected && expected[0] != expected[1], "the cloud shows Off, then Everything: drew \(drawn), expected \(expected)")
            let second = open(everythingButton, in: window)
            expect(second.map(\.checked) == [false, false, true], "Everything is checked once set: \(describe(second))")
            close(window)

            print("SyncLevelMenu ok: every level can be chosen under Settings' switch style, the current one is checked, and choosing one sets it and changes the cloud")
            exit(0)
        }
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 30)
            fail("timed out")
        }
        app.run()
    }

    // MARK: - Menu

    /// Clicks the pop-up and returns the level items of the menu it opens; the menu stays open.
    nonisolated static func open(_ button: AXUIElement, in window: NSWindow) -> [Item] {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated { popUp(in: window)?.performClick(nil) }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        Thread.sleep(forTimeInterval: 0.7)
        guard let menu = children(button).first(where: { string($0, kAXRoleAttribute) == kAXMenuRole }) else {
            fail("the pop-up opened no menu")
        }
        return children(menu).compactMap { element in
            guard let title = string(element, kAXTitleAttribute), levels.contains(title) else { return nil }
            return Item(element: element, title: title,
                        enabled: attribute(element, kAXEnabledAttribute) as? Bool ?? false,
                        checked: string(element, kAXMenuItemMarkCharAttribute)?.isEmpty == false)
        }
    }

    nonisolated static func close(_ window: NSWindow) {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated { popUp(in: window)?.menu?.cancelTracking() }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        Thread.sleep(forTimeInterval: 0.3)
    }

    static func popUp(in window: NSWindow) -> NSPopUpButton? {
        func find(_ view: NSView) -> NSPopUpButton? {
            (view as? NSPopUpButton) ?? view.subviews.lazy.compactMap(find).first
        }
        return window.contentView.flatMap(find)
    }

    // MARK: - Accessibility

    nonisolated static func button(in app: AXUIElement, labelled label: String) -> AXUIElement {
        func find(_ element: AXUIElement) -> AXUIElement? {
            if string(element, kAXDescriptionAttribute) == label { return element }
            return children(element).lazy.compactMap(find).first
        }
        guard let button = find(app) else { fail("no pop-up labelled \"\(label)\"") }
        return button
    }

    nonisolated static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    nonisolated static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    nonisolated static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    // MARK: - Reporting

    nonisolated static func onMain<T: Sendable>(_ body: @MainActor () -> T) -> T {
        DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }

    nonisolated static func describe(_ items: [Item]) -> String {
        items.map { "\($0.title) enabled=\($0.enabled) checked=\($0.checked)" }.joined(separator: ", ")
    }

    nonisolated static func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
        if !condition { fail(message()) }
    }

    nonisolated static func fail(_ message: String) -> Never {
        print("SyncLevelMenu FAILED: \(message)")
        exit(1)
    }
}
