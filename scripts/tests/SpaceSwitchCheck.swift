// Licensed under GPL-3.0. See LICENSE.
//
// swiftc $(rg --files Nook/ThirdParty/BigUIPaging -g '*.swift') scripts/tests/SpaceSwitchCheck.swift -o /tmp/space-switch-check && /tmp/space-switch-check
//
// The space pager against the Arc behavior in docs/research/arc-teardown/10-sidebar-spaces-paging.md:
// the pure math, then real AppKit motion with deterministic gesture input, then made-up scroll and
// wheel events dispatched over a page's vertical list. Feel still needs a trackpad.

import AppKit
import SwiftUI

typealias Pager = PlatformPageView<Int, Text>.SwipePagerView

@main
struct SpaceSwitchCheck {
    @MainActor
    static func main() {
        checkMath()
        checkView()
        checkEvents()
    }

    @MainActor
    static func checkMath() {
        func near(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.01) -> Bool { abs(a - b) <= tolerance }

        // Rubber band: identity inside, 255 * (1 - 1/(x * 0.15/255 + 1)) past an end, invertible.
        precondition(Pager.rubberBand(120, max: 600) == 120)
        precondition(near(Pager.rubberBand(-100, max: 600), -255 * (1 - 1 / (100 * 0.15 / 255 + 1))))
        precondition(near(Pager.rubberBand(700, max: 600), 600 + 255 * (1 - 1 / (100 * 0.15 / 255 + 1))))
        precondition(Pager.rubberBand(-1_000_000, max: 600) > -255)
        precondition(near(Pager.inverseRubberBand(Pager.rubberBand(-140, max: 600), max: 600), -140))

        // Page choice at lift. Width 300, four pages.
        func target(_ position: CGFloat, _ velocity: CGFloat, adopted: Bool = false) -> Int {
            Pager.target(position: position, velocity: velocity, width: 300, count: 4, adopted: adopted)
        }
        precondition(target(140, 0) == 0 && target(160, 0) == 1, "Slow release goes to the nearest page")
        precondition(target(30, 5) == 1, "Any flick of 5 pt/s moves one page its way")
        precondition(target(270, -5) == 0, "A backward flick returns to the floor page")
        precondition(target(30, 4.9) == 0)
        precondition(target(420, -50, adopted: true) == 0, "A flick during a settle moves on past the page in flight")
        precondition(target(-80, -50) == 0 && target(980, 50) == 3, "Never past either end")

        // Velocity only from the last 100 ms.
        precondition(near(Pager.velocity([(1.00, 0), (1.05, 50)]), 1000, 0.5))
        precondition(Pager.velocity([(1.00, 0), (1.20, 50)]) == 0)

        // Critically damped spring: starts at the offset, never overshoots from rest, ends at 0.
        let offsets = Pager.springOffsets(from: -300, velocity: 0)
        precondition(offsets.first == -300 && offsets.last == 0)
        precondition(zip(offsets, offsets.dropFirst()).allSatisfy { $0 <= $1 }, "No overshoot from rest")
        let duration = Double(offsets.count - 1) * Pager.sampleStep
        precondition(duration > 0.2 && duration < 0.6, "Response 0.25 s settles in roughly 0.3 to 0.5 s, got \(duration)")
        print("PASS: rubber band, page choice, velocity window, spring")

        // Wheel: one page per burst, a burst ending after a 0.25 s pause.
        var wheel = Pager.Wheel()
        precondition(wheel.step(deltaX: -0.1, precise: false, inverted: false, time: 10) == 1, "The first tick of a burst moves forward, however slow")
        precondition(wheel.step(deltaX: -5, precise: false, inverted: false, time: 10.1) == 0, "The rest of the burst does not")
        precondition(wheel.step(deltaX: -5, precise: false, inverted: false, time: 10.3) == 0, "Nor does a spin that keeps going")
        precondition(wheel.step(deltaX: 1, precise: false, inverted: false, time: 10.6) == -1, "After a pause the next tick moves back")
        var natural = Pager.Wheel()
        precondition(natural.step(deltaX: 1, precise: false, inverted: true, time: 0) == 1, "Wheel down moves forward with natural scrolling too")
        var smooth = Pager.Wheel()
        precondition(smooth.step(deltaX: -4, precise: true, inverted: false, time: 0) == 0, "Precise points add up first")
        precondition(smooth.step(deltaX: -4, precise: true, inverted: false, time: 0.01) == 0)
        precondition(smooth.step(deltaX: -4, precise: true, inverted: false, time: 0.02) == 1, "and move at 10")
        print("PASS: wheel bursts")
    }

    @MainActor
    static func checkView() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        var selection = 0
        let parent = PlatformPageView(
            selection: Binding(get: { selection }, set: { selection = $0 }),
            configuration: PlatformPageViewConfiguration(transition: .historyStack, orientation: .horizontal, spacing: 0),
            next: { $0 < 3 ? $0 + 1 : nil }, previous: { $0 > 0 ? $0 - 1 : nil },
            content: { Text("Space \($0)") })
        let coordinator = parent.makeCoordinator()
        let pager = Pager(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        let window = NSWindow(contentRect: pager.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = pager
        window.setFrameOrigin(NSPoint(x: -2000, y: -2000))
        window.orderFront(nil)
        coordinator.pager = pager
        pager.coordinator = coordinator
        var swipes: [PageSwipePosition?] = []
        coordinator.onSwipe = { swipes.append($0) }

        let strip = pager.subviews[0]
        /// Where the strip shows: its frame, the settle animating it, and the drag's move of its layer.
        func shown() -> CGFloat {
            guard let layer = strip.layer else { return -strip.frame.minX }
            let current = layer.animationKeys()?.isEmpty == false ? layer.presentation() ?? layer : layer
            return -(current.position.x - layer.anchorPoint.x * layer.bounds.width + current.affineTransform().tx)
        }
        func wait(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

        coordinator.show(0)
        pager.layout()
        wait(0.05)
        precondition(strip.subviews.count == 1 && strip.frame.minX == 0)

        // Swipe left: fingers move the strip at half speed.
        precondition(pager.beginDrag())
        for step in 1...6 { pager.drag(.changed, delta: -40, time: 1 + Double(step) * 0.01) }
        precondition(shown() == 120, "Six -40 pt deltas move the strip 120 pt")
        precondition(strip.frame.minX == 0, "The fingers move the strip's layer, not its frame")
        wait(0.03)
        precondition(swipes.count == 2, "Six events within a frame reach the listener as its first position and its latest, got \(swipes.count)")
        precondition(swipes.last??.to == AnyHashable(1) && abs((swipes.last??.progress ?? 0) - 0.4) < 0.001)
        pager.drag(.ended, delta: 0, time: 1.07)
        precondition(selection == 1, "The selection commits at lift, before the slide")
        precondition(pager.isTracking)
        precondition(swipes.last! == nil)
        wait(0.08)
        let midway = shown()
        precondition(midway > 120 && midway < 300, "Still sliding toward page 1, at \(midway)")
        wait(0.6)
        precondition(!pager.isTracking && strip.frame.minX == -300)
        precondition(strip.subviews.count == 3 && strip.subviews.filter { !$0.isHidden }.count == 1,
                     "At rest the pages either side are built and hidden, only the selected one shows")
        print("PASS: half-speed drag, commit at lift, spring settle, neighbours waiting hidden")

        // A switch without animation shows its page at once, though it waited hidden.
        selection = 2
        coordinator.refresh(to: 2, animated: false)
        precondition(strip.frame.minX == -600 && strip.subviews.filter { !$0.isHidden }.map(\.frame.minX) == [600],
                     "The page switched to shows straight away")
        selection = 1
        coordinator.refresh(to: 1, animated: false)
        wait(0.05)
        print("PASS: a switch without animation shows a page that waited hidden")

        // A far programmatic jump slides right through the pages between.
        selection = 3
        coordinator.parent = parent
        coordinator.refresh(to: 3, animated: true)
        precondition(strip.subviews.filter { !$0.isHidden }.count == 3, "Pages 1 to 3 show on the strip during the jump")
        wait(0.06)
        let early = shown()
        precondition(early > 300 && early < 900, "Moves forward from page 1 toward page 3, at \(early)")
        wait(0.7)
        precondition(strip.frame.minX == -900 && !pager.isTracking)
        print("PASS: far jump moves by position, forward, through every page")

        // A swipe grabs the strip in flight at its on-screen position.
        coordinator.refresh(to: 0, animated: true)
        selection = 0
        wait(0.08)
        let inFlight = shown()
        precondition(pager.beginDrag())
        precondition(abs(-strip.frame.minX - inFlight) < 30, "Adopted near \(inFlight), got \(-strip.frame.minX)")
        pager.drag(.cancelled, delta: 0, time: 3)
        wait(0.7)
        precondition(strip.frame.minX == 0 && selection == 0, "A cancelled swipe returns to the selected page")
        print("PASS: interruption adopts the moving strip, cancel returns")

        // A resize mid-settle lands on the selected page at the new width.
        coordinator.refresh(to: 2, animated: true)
        selection = 2
        wait(0.05)
        pager.setFrameSize(NSSize(width: 250, height: 400))
        pager.layout()
        precondition(strip.frame.minX == -500 && !pager.isTracking)
        precondition(strip.subviews.allSatisfy { $0.frame.width == 250 })
        print("PASS: resize mid-settle")

        // Past the first page with a listener, the fingers drive the listener one to one and the
        // strip holds still.
        var pulls: [PageLeadingPull] = []
        coordinator.onLeadingOverscroll = { pulls.append($0) }
        selection = 0
        coordinator.refresh(to: 0, animated: false)
        precondition(pager.beginDrag())
        for step in 1...3 { pager.drag(.changed, delta: 40, time: 4 + Double(step) * 0.01) }
        guard case .changed(let distance) = pulls.last, distance == 120 else { preconditionFailure("The pull is heard as it goes, got \(pulls)") }
        precondition(shown() == 0, "The first page holds still under a pull, at \(shown())")
        pager.drag(.ended, delta: 0, time: 4.04)
        guard case .ended(let released, _) = pulls.last, released == 120 else { preconditionFailure("The release is heard, got \(pulls)") }
        precondition(!pager.isTracking && strip.frame.minX == 0 && shown() == 0 && selection == 0)
        coordinator.onLeadingOverscroll = nil
        print("PASS: a pull past the first page goes to its listener and the strip holds")
    }

    /// Real scroll events dispatched over a page holding a vertical list, as the sidebar's tabs are.
    @MainActor
    static func checkEvents() {
        typealias ListPager = PlatformPageView<Int, AnyView>
        var selection = 1
        let parent = ListPager(
            selection: Binding(get: { selection }, set: { selection = $0 }),
            configuration: PlatformPageViewConfiguration(transition: .scroll, orientation: .horizontal, spacing: 0),
            next: { $0 < 3 ? $0 + 1 : nil }, previous: { $0 > 0 ? $0 - 1 : nil },
            content: { _ in
                AnyView(ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(0..<200) { Text("Tab \($0)").frame(maxWidth: .infinity, minHeight: 20) }
                    }
                })
            })
        let coordinator = parent.makeCoordinator()
        let pager = ListPager.SwipePagerView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        let window = NSWindow(contentRect: pager.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = pager
        window.setFrameOrigin(NSPoint(x: -3000, y: -3000))
        window.orderFront(nil)
        coordinator.pager = pager
        pager.coordinator = coordinator
        coordinator.show(1)
        pager.layout()
        dispatch(in: window, for: 0.3)

        let overList = NSPoint(x: 150, y: 300)
        func reset() {
            selection = 1
            coordinator.refresh(to: 1, animated: false)
            dispatch(in: window, for: 0.1)
        }
        func list() -> NSScrollView? {
            func find(_ view: NSView) -> NSScrollView? {
                if view.isHidden { return nil }
                if let scroll = view as? NSScrollView { return scroll }
                return view.subviews.lazy.compactMap(find).first
            }
            return find(pager)
        }
        /// The view AppKit sends `event` to: the one hit while it is the current event.
        func receiver(of event: NSEvent) -> NSView? {
            NSApp.postEvent(event, atStart: true)
            _ = NSApp.nextEvent(matching: .scrollWheel, until: .distantFuture, inMode: .default, dequeue: true)
            return pager.hitTest(overList)
        }
        // CGScrollPhase: began 1, changed 2, ended 4.
        func swipe(dx: Int32, dy: Int32) {
            NSApp.postEvent(scroll(dx: dx, dy: dy, precise: true, phase: 1, at: overList), atStart: false)
            for _ in 0..<12 { NSApp.postEvent(scroll(dx: dx, dy: dy, precise: true, phase: 2, at: overList), atStart: false) }
            NSApp.postEvent(scroll(dx: 0, dy: 0, precise: true, phase: 4, at: overList), atStart: false)
            dispatch(in: window, for: 0.8)
        }
        func wheel(dx: Int32, dy: Int32 = 0) {
            NSApp.postEvent(scroll(dx: dx, dy: dy, precise: false, phase: 0, at: overList), atStart: false)
        }

        typealias View = ListPager.SwipePagerView
        precondition(View.isWheel(scroll(dx: -1, dy: 0, precise: false, phase: 0, at: overList)), "A wheel tick")
        precondition(View.isWheel(scroll(dx: -8, dy: 0, precise: true, phase: 0, at: overList)), "Precise deltas with no gesture")
        precondition(!View.isWheel(scroll(dx: -8, dy: 0, precise: true, phase: 1, at: overList)), "A trackpad gesture")

        let setting = NSEvent.isSwipeTrackingFromScrollEventsEnabled ? "on" : "off"
        reset()
        swipe(dx: -40, dy: 0)
        precondition(selection == 2, "A sideways swipe over the list pages forward with Swipe between pages \(setting), got \(selection)")
        reset()
        swipe(dx: 40, dy: 0)
        precondition(selection == 0, "and back, got \(selection)")
        reset()
        precondition(!View.startsDrag(scroll(dx: -6, dy: -20, precise: true, phase: 1, at: overList)),
                     "A swipe that starts upright is the list's")
        precondition(View.startsDrag(scroll(dx: -20, dy: -6, precise: true, phase: 1, at: overList)))
        precondition(!View.startsDrag(scroll(dx: -20, dy: 0, precise: true, phase: 2, at: overList)),
                     "Only a gesture's first event can start a drag")
        swipe(dx: 0, dy: -40)
        precondition(selection == 1 && !pager.isTracking, "A vertical swipe stays on the space")
        precondition(receiver(of: scroll(dx: 0, dy: -40, precise: true, phase: 1, at: overList))?.isDescendant(of: list()!) == true,
                     "and goes to the list")
        print("PASS: trackpad swipes over the list page sideways; upright ones are the list's")

        // A swipe cut short, as by switching apps mid-swipe, never gets its `.ended`. The pager lets
        // go on its own and settles on its space instead of holding the app's events until the next
        // scroll; a check that still hangs is stopped here.
        let watchdog = DispatchWorkItem {
            fputs("FAIL: a swipe with no end still holds the pager's event loop\n", stderr)
            exit(1)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: watchdog)
        let strip = pager.subviews[0]
        var presses = 0
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { presses += 1; return $0 }
        /// Starts a swipe that never ends, does `meanwhile`, and returns how long the pager's loop held on.
        func unfinishedSwipe(_ meanwhile: () -> Void = {}) -> TimeInterval {
            reset()
            NSApp.postEvent(scroll(dx: -40, dy: 0, precise: true, phase: 1, at: overList), atStart: false)
            for _ in 0..<3 { NSApp.postEvent(scroll(dx: -40, dy: 0, precise: true, phase: 2, at: overList), atStart: false) }
            meanwhile()
            let start = Date()
            dispatch(in: window, for: 0.05)
            return Date().timeIntervalSince(start)
        }
        func settledBack() -> Bool {
            dispatch(in: window, for: 0.7)
            return selection == 1 && !pager.isTracking && strip.frame.minX == -300
        }

        let idle = unfinishedSwipe()
        precondition(idle > 0.5 && idle < 3, "Left alone, the swipe ends after a second without events, took \(idle) s")
        precondition(settledBack(), "and the pager settles back on its space")

        let pressed = unfinishedSwipe {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.postEvent(NSEvent.mouseEvent(with: type, location: overList, modifierFlags: [],
                                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!, atStart: false)
            }
        }
        precondition(pressed < 0.5 && presses == 1, "A click ends the swipe at once and still goes through, took \(pressed) s, \(presses) clicks")
        precondition(settledBack())

        for (name, object) in [(NSApplication.didResignActiveNotification, NSApp as AnyObject), (NSWindow.didResignKeyNotification, window)] {
            let woken = unfinishedSwipe {
                let timer = Timer(timeInterval: 0.2, repeats: false) { _ in
                    MainActor.assumeIsolated { NotificationCenter.default.post(name: name, object: object) }
                }
                RunLoop.main.add(timer, forMode: .common)
            }
            precondition(woken > 0.15 && woken < 0.6, "\(name.rawValue) ends the swipe, took \(woken) s")
            precondition(settledBack())
        }
        watchdog.cancel()
        NSEvent.removeMonitor(monitor!)
        print("PASS: a swipe that never ends lets go after a pause, a click, or the app or window losing focus")

        reset()
        wheel(dx: -1)
        dispatch(in: window, for: 0.6)
        precondition(selection == 2, "One sideways wheel tick over the list moves one space, got \(selection)")
        reset()
        for delta: Int32 in [-1, -1, -3, -2] { wheel(dx: delta) }
        dispatch(in: window, for: 0.6)
        precondition(selection == 2, "A fast spin moves one space too, got \(selection)")
        wheel(dx: 1)
        dispatch(in: window, for: 0.6)
        precondition(selection == 1, "A tick after a pause moves again, the other way, got \(selection)")
        wheel(dx: 0, dy: -3)
        dispatch(in: window, for: 0.6)
        precondition(selection == 1, "An upright wheel tick stays on the space")
        precondition(receiver(of: scroll(dx: 0, dy: -3, precise: false, phase: 0, at: overList))?.isDescendant(of: list()!) == true,
                     "and goes to the list")
        precondition(receiver(of: scroll(dx: -1, dy: 0, precise: false, phase: 0, at: overList)) === pager,
                     "A sideways tick goes to the pager, not the list that would keep it")
        print("PASS: a sideways wheel burst over the list moves one space; upright ticks are the list's")
    }

    /// A scroll event at `point` in the window. With no window of its own the event's location is
    /// read as a screen point, so the point goes in as one and the window can stay off screen.
    @MainActor
    static func scroll(dx: Int32, dy: Int32, precise: Bool, phase: Int64, at point: NSPoint) -> NSEvent {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line,
                            wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)!
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: precise ? 1 : 0)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.location = CGPoint(x: point.x, y: NSScreen.screens[0].frame.height - point.y)
        // A made-up CGEvent is stamped 0; real ones carry nanoseconds of uptime.
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
