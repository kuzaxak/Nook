// Licensed under GPL-3.0. See LICENSE.
//
// swiftc -O $(rg --files Nook/ThirdParty/BigUIPaging -g '*.swift') scripts/tests/SpaceSwipeCostCheck.swift -o /tmp/space-swipe-cost-check && /tmp/space-swipe-cost-check
//
// What a sidebar swipe costs the main thread. Trackpad events at 120 Hz, as a Magic Trackpad sends
// them, go over a page's list in a SwiftUI window, as the sidebar's do. While the fingers move the
// strip, the window must not lay out, the pages must not see their geometry change and none may be
// built, the window's body must not run, and the swipe's listener hears at most one position a
// display frame (1/60 s, the off-screen window's).

import AppKit
import Observation
import SwiftUI

@MainActor
final class Counts {
    static var measuring = false
    static var windowLayouts = 0
    static var windowBodies = 0
    static var pageBuilds = 0
    static var pageMoves = 0
    static var reports = 0
    static var dots = 0

    static func reset() {
        windowLayouts = 0; windowBodies = 0; pageBuilds = 0; pageMoves = 0; reports = 0; dots = 0
    }
}

@Observable
final class SidebarModel {
    var space = 1
    var swipe: Double?
    var showsDots = false
}

/// The window's root hosting view, counting the layout passes that run window-wide SwiftUI work.
final class WindowHost<Root: View>: NSHostingView<Root> {
    override func layout() {
        if Counts.measuring { Counts.windowLayouts += 1 }
        super.layout()
    }
}

/// Stands in for `WindowView`: reads the space, as its chrome does.
struct WindowBody: View {
    let model: SidebarModel

    var body: some View {
        let _ = Counts.measuring ? Counts.windowBodies += 1 : ()
        let _ = model.space
        VStack(spacing: 0) {
            PageView(selection: Binding(get: { model.space }, set: { model.space = $0 })) {
                ForEach(0..<4, id: \.self) { space in
                    let _ = Counts.measuring ? Counts.pageBuilds += 1 : ()
                    SpacePage(space: space)
                }
            }
            .pageViewStyle(.scroll)
            .onPageSwipe { position in
                if Counts.measuring, position != nil { Counts.reports += 1 }
                model.swipe = position?.progress
            }
            if model.showsDots { Dots(model: model).frame(height: 20) }
        }
    }
}

/// The space dots: the one view that reads the swipe's position.
struct Dots: View {
    let model: SidebarModel

    var body: some View {
        let _ = Counts.measuring ? Counts.dots += 1 : ()
        let progress = model.swipe ?? 0
        HStack {
            ForEach(0..<4, id: \.self) { index in
                Circle().frame(width: 6 + 4 * progress, height: 6 + 4 * progress).opacity(index == model.space ? 1 : 0.3)
            }
        }
    }
}

struct SpacePage: View {
    let space: Int

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(0..<60, id: \.self) { row in
                    Text("Space \(space) tab \(row)").frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                }
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.frame(in: .global)) { _, _ in
                    if Counts.measuring { Counts.pageMoves += 1 }
                }
            }
        }
    }
}

@main
struct SpaceSwipeCostCheck {
    static let eventsPerSecond = 120.0
    static let frameInterval = 1.0 / 60
    static let moves = 60

    struct Swipe {
        var windowLayouts = 0, windowBodies = 0, pageBuilds = 0, pageMoves = 0, reports = 0, dots = 0
        var events = 0
        var frames = 0
        var cpuPerEvent = 0.0
    }

    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let model = SidebarModel()
        let host = WindowHost(rootView: WindowBody(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        let window = NSWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderFront(nil)
        dispatch(in: window, for: 0.6)

        typealias Pager = PlatformPageView<PageViewStyleConfiguration.Value, PageViewStyleConfiguration.Page>.SwipePagerView
        let pager = find(Pager.self, in: host)!
        let overList = pager.convert(NSPoint(x: 150, y: 300), to: nil)

        // The strip alone: nothing in the window reads the swipe's position.
        var strip: [Swipe] = []
        for direction in [-1, 1, -1, 1] as [Int32] {
            strip.append(swipe(dx: 6 * direction, at: overList, in: window))
        }
        // The dots follow the swipe; they are the only view that reads it.
        model.showsDots = true
        dispatch(in: window, for: 0.3)
        var withDots: [Swipe] = []
        for direction in [-1, 1] as [Int32] {
            withDots.append(swipe(dx: 6 * direction, at: overList, in: window))
        }

        for (index, swipe) in strip.enumerated() {
            print("strip swipe \(index): \(swipe.events) events over \(swipe.frames) frames, window layouts \(swipe.windowLayouts), page geometry changes \(swipe.pageMoves), page builds \(swipe.pageBuilds), window bodies \(swipe.windowBodies), positions heard \(swipe.reports), \(String(format: "%.2f", swipe.cpuPerEvent)) ms of main thread an event")
        }
        for (index, swipe) in withDots.enumerated() {
            print("dots swipe \(index): \(swipe.events) events over \(swipe.frames) frames, dots redrawn \(swipe.dots), positions heard \(swipe.reports), window bodies \(swipe.windowBodies)")
        }

        var failed = false
        func check(_ condition: Bool, _ message: String) {
            if !condition { failed = true; fputs("FAIL: \(message)\n", stderr) }
        }
        check(model.space == 1, "Swipes back and forth end on the space they started on, got \(model.space)")
        for (index, swipe) in strip.enumerated() {
            check(swipe.windowLayouts <= 1, "Swipe \(index): moving the strip lays the window out \(swipe.windowLayouts) times over \(swipe.events) events")
            check(swipe.pageMoves == 0, "Swipe \(index): moving the strip changes the pages' geometry \(swipe.pageMoves) times over \(swipe.events) events")
            check(swipe.pageBuilds == 0, "Swipe \(index): \(swipe.pageBuilds) pages built during the swipe")
            check(swipe.windowBodies == 0, "Swipe \(index): the window's body runs \(swipe.windowBodies) times while the fingers move")
            check(swipe.reports <= swipe.frames + 1, "Swipe \(index): the listener hears \(swipe.reports) positions in \(swipe.frames) frames")
            check(swipe.cpuPerEvent < 0.75, "Swipe \(index): each event costs the main thread \(String(format: "%.2f", swipe.cpuPerEvent)) ms")
        }
        for (index, swipe) in withDots.enumerated() {
            check(swipe.dots > 0, "Dots swipe \(index): the dots follow the swipe")
            check(swipe.dots <= swipe.frames + 1, "Dots swipe \(index): the dots redraw \(swipe.dots) times in \(swipe.frames) frames")
            check(swipe.reports <= swipe.frames + 1, "Dots swipe \(index): the listener hears \(swipe.reports) positions in \(swipe.frames) frames")
            check(swipe.windowBodies == 0, "Dots swipe \(index): the window's body runs \(swipe.windowBodies) times while the dots follow")
        }
        if failed { exit(1) }
        print("PASS: while the fingers move the strip: no window layout, no page geometry change or build, no window body, a position a frame at most")
    }

    /// One sideways swipe over the list: a began event, `moves` changes at 120 Hz, then the end.
    /// Page builds count from the first event; the rest only while the strip moves, from the third
    /// change to the last.
    @MainActor
    static func swipe(dx: Int32, at point: NSPoint, in window: NSWindow) -> Swipe {
        var events = [scroll(dx: dx, phase: 1, at: point)]
        events += (0..<moves).map { _ in scroll(dx: dx, phase: 2, at: point) }
        events.append(scroll(dx: 0, phase: 4, at: point))

        var result = Swipe()
        var early = Swipe()
        var next = 0
        var cpuStart: UInt64 = 0
        var start = Date()
        func snapshot() -> Swipe {
            Swipe(windowLayouts: Counts.windowLayouts, windowBodies: Counts.windowBodies, pageBuilds: Counts.pageBuilds,
                  pageMoves: Counts.pageMoves, reports: Counts.reports, dots: Counts.dots)
        }
        let timer = Timer(timeInterval: 1 / eventsPerSecond, repeats: true) { timer in
            MainActor.assumeIsolated {
                switch next {
                case 0:
                    Counts.reset()
                    Counts.measuring = true
                case 3:
                    early = snapshot()
                    start = Date()
                    cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                case events.count - 1:
                    Counts.measuring = false
                    let late = snapshot()
                    let moved = next - 3
                    result = Swipe(windowLayouts: late.windowLayouts - early.windowLayouts,
                                   windowBodies: late.windowBodies - early.windowBodies,
                                   pageBuilds: late.pageBuilds,
                                   pageMoves: late.pageMoves - early.pageMoves,
                                   reports: late.reports - early.reports,
                                   dots: late.dots - early.dots,
                                   events: moved,
                                   frames: Int((Date().timeIntervalSince(start) / frameInterval).rounded(.up)),
                                   cpuPerEvent: Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1e6 / Double(moved))
                default:
                    break
                }
                guard next < events.count else { return timer.invalidate() }
                NSApp.postEvent(events[next], atStart: false)
                next += 1
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dispatch(in: window, for: Double(events.count) / eventsPerSecond + 0.1)
        dispatch(in: window, for: 0.8)
        return result
    }

    static func find<V: NSView>(_ type: V.Type, in view: NSView) -> V? {
        if let match = view as? V { return match }
        return view.subviews.lazy.compactMap { find(type, in: $0) }.first
    }

    /// A trackpad scroll event at `point` in the window. With no window of its own the event's location
    /// is read as a screen point, so the point goes in as one and the window can stay off screen.
    /// CGScrollPhase: began 1, changed 2, ended 4.
    @MainActor
    static func scroll(dx: Int32, phase: Int64, at point: NSPoint) -> NSEvent {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0)!
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.location = CGPoint(x: point.x, y: NSScreen.screens[0].frame.height - point.y)
        event.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        return NSEvent(cgEvent: event)!
    }

    /// Runs the app's event loop, handing scroll events to `window` as AppKit would for one under the pointer.
    @MainActor
    static func dispatch(in window: NSWindow, for seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while let event = NSApp.nextEvent(matching: .any, until: until, inMode: .default, dequeue: true) {
            if event.type == .scrollWheel, event.window == nil { window.sendEvent(event) } else { NSApp.sendEvent(event) }
        }
    }
}
