// Licensed under GPL-3.0. See LICENSE.
//
//  swiftc -parse-as-library Nook/Components/Navigation/HoldMenuRegion.swift App/Window/TitlebarDragRegion.swift \
//         scripts/tests/HoldMenuRegionCheck.swift -o /tmp/hold-menu-check && /tmp/hold-menu-check
//
//  Back and Forward open their history on a right-click, a Control-click or a held press, also in
//  the title band, where the window's toolbar answers a right-click with its Icon and Text menu.
//  A plain click still reaches the button. The window is built as Nook's is and sits off screen;
//  each menu that opens is closed at once.

import AppKit
import SwiftUI

private struct Controls: View {
    let history: () -> NSMenu?
    let onClick: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            button("Back", at: HoldMenuRegionCheck.band, menu: history)
            button("Forward", at: HoldMenuRegionCheck.bandEmpty, menu: { nil })
            button("Low", at: HoldMenuRegionCheck.below, menu: history)
            button("Washed", at: HoldMenuRegionCheck.washed, menu: history)
            // Peek's wash: drawn over the button and taking its own clicks.
            Color.gray.opacity(0.45)
                .frame(width: 90, height: 50)
                .contentShape(Rectangle())
                .onTapGesture {}
                .position(HoldMenuRegionCheck.washed)
        }
        .ignoresSafeArea()
    }

    private func button(_ title: String, at point: CGPoint, menu: @escaping () -> NSMenu?) -> some View {
        Button(title, action: onClick)
            .frame(width: 60, height: 28)
            .overlay(HoldMenuRegion(holdDelay: HoldMenuRegionCheck.hold, makeMenu: menu))
            .position(point)
    }
}

@main
@MainActor
struct HoldMenuRegionCheck {
    static let hold: TimeInterval = 0.3
    /// Button centres from the window's top left. The toolbar's band is 52 points or more.
    static let band = CGPoint(x: 100, y: 20)
    static let bandEmpty = CGPoint(x: 200, y: 20)
    static let below = CGPoint(x: 100, y: 200)
    static let washed = CGPoint(x: 300, y: 200)

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        var opened: [[String]] = []
        var clicks = 0
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            guard let menu = note.object as? NSMenu else { return }
            opened.append(menu.items.map(\.title))
            DispatchQueue.main.async { menu.cancelTracking() }
        }
        let history = {
            let menu = NSMenu()
            menu.addItem(withTitle: "Earlier Page", action: nil, keyEquivalent: "")
            return menu
        }

        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 400, height: 300),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbar = NSToolbar()
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = NSHostingView(rootView: Controls(history: history, onClick: { clicks += 1 }))
        window.orderBack(nil)
        TitlebarDragRegion.letAppKitViewsBlockDrags(in: window)

        func post(_ type: NSEvent.EventType, at point: CGPoint, flags: NSEvent.ModifierFlags = []) {
            let height = window.contentView!.bounds.height
            let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: point.x, y: height - point.y), modifierFlags: flags,
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            NSApp.postEvent(event, atStart: false)
        }
        func expect(_ condition: Bool, _ message: String) {
            guard condition else { fatalError("\(message): menus \(opened), clicks \(clicks)") }
        }

        let steps: [(String, () -> Void, () -> Void)] = [
            ("right-click in the band", {
                post(.rightMouseDown, at: band); post(.rightMouseUp, at: band)
            }, {
                expect(opened == [["Earlier Page"]], "a right-click in the title band opens the history, not the toolbar's menu")
            }),
            ("Control-click", {
                post(.leftMouseDown, at: band, flags: .control); post(.leftMouseUp, at: band, flags: .control)
            }, {
                expect(opened == [["Earlier Page"]] && clicks == 0, "a Control-click opens the history and does not click")
            }),
            ("held press", {
                post(.leftMouseDown, at: band)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { post(.leftMouseUp, at: band) }
            }, {
                expect(opened == [["Earlier Page"]] && clicks == 0, "a held press opens the history and does not click")
            }),
            ("right-click with no history", {
                post(.rightMouseDown, at: bandEmpty); post(.rightMouseUp, at: bandEmpty)
            }, {
                expect(opened.isEmpty, "a right-click on a button with no history opens nothing")
            }),
            ("click", {
                post(.leftMouseDown, at: below); post(.leftMouseUp, at: below)
            }, {
                expect(opened.isEmpty && clicks == 1, "a quick click reaches the button and opens nothing")
            }),
            ("right-click on a wash over the button", {
                post(.rightMouseDown, at: washed); post(.rightMouseUp, at: washed)
            }, {
                expect(opened.isEmpty, "a right-click on something drawn over the button opens no history")
            }),
            ("held press on a wash over the button", {
                post(.leftMouseDown, at: washed)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { post(.leftMouseUp, at: washed) }
            }, {
                expect(opened.isEmpty && clicks == 0, "nor does a held press on it")
            }),
        ]

        func run(_ index: Int) {
            guard index < steps.count else {
                print("HoldMenuRegion ok: right-click, Control-click and a held press open the history; a click clicks; a wash over the button opens nothing")
                exit(0)
            }
            let (name, act, check) = steps[index]
            opened = []
            clicks = 0
            print("-- \(name)")
            act()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                check()
                run(index + 1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { run(0) }
        app.run()
    }
}
