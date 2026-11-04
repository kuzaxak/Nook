#if canImport(AppKit)

import SwiftUI

// Nook: a trackpad pager modeled on Arc's. Pages sit on one strip; fingers move it at half
// speed with rubber-banded ends, lifting commits the selection at once, and a critically
// damped spring settles it on the render server so a new swipe can grab it mid-flight.
extension PlatformPageView: NSViewRepresentable {

    func makeNSView(context: Context) -> SwipePagerView {
        let view = SwipePagerView()
        view.coordinator = context.coordinator
        context.coordinator.pager = view
        context.coordinator.onSwipe = context.environment.pageSwipeAction
        context.coordinator.onLeadingOverscroll = context.environment.pageLeadingOverscrollAction
        context.coordinator.swipeEnabled = context.environment.pageSwipeEnabled
        context.coordinator.show(selection)
        return view
    }

    func updateNSView(_ view: SwipePagerView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.onSwipe = context.environment.pageSwipeAction
        context.coordinator.onLeadingOverscroll = context.environment.pageLeadingOverscrollAction
        context.coordinator.swipeEnabled = context.environment.pageSwipeEnabled
        context.coordinator.refresh(to: selection, animated: context.transaction.animation != nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator {
        var parent: PlatformPageView
        weak var pager: SwipePagerView?
        var onSwipe: ((PageSwipePosition?) -> Void)?
        var onLeadingOverscroll: ((PageLeadingPull) -> Void)?
        var swipeEnabled = true
        private var views: [SelectionValue: PageHostView] = [:]

        init(_ parent: PlatformPageView) {
            self.parent = parent
        }

        var current: SelectionValue? { pager?.selectedValue }

        func view(for value: SelectionValue) -> PageHostView {
            if let view = views[value] {
                view.rootView = parent.content(value)
                return view
            }
            let view = PageHostView(rootView: parent.content(value))
            views[value] = view
            return view
        }

        /// Every page in order, walked out from the selection.
        func order() -> [SelectionValue] {
            var before: [SelectionValue] = []
            var cursor = parent.selection
            while let previous = parent.previous(cursor), before.count < 256 {
                before.append(previous)
                cursor = previous
            }
            var after: [SelectionValue] = []
            cursor = parent.selection
            while let next = parent.next(cursor), after.count < 256 {
                after.append(next)
                cursor = next
            }
            return before.reversed() + [parent.selection] + after
        }

        func show(_ value: SelectionValue) {
            pager?.move(to: value, animated: false)
        }

        func refresh(to value: SelectionValue, animated: Bool) {
            pager?.move(to: value, animated: animated)
        }

        func commit(_ value: SelectionValue) {
            parent.selection = value
        }

        func evict(keeping keep: Set<SelectionValue>) {
            views = views.filter { keep.contains($0.key) }
        }
    }

    // MARK: - Pager

    final class SwipePagerView: NSView {
        weak var coordinator: Coordinator?

        private let strip = NSView()
        private var pages: [SelectionValue] = []
        private var selected = 0
        private var attached: [Int: PageHostView] = [:]
        // Strip offset in points; page i starts at i * width. Unclamped while dragging.
        private var raw: CGFloat = 0
        private var lastWidth: CGFloat = 0
        private var motion: Motion = .idle
        private var motionID: UInt = 0
        private var wheel = Wheel()
        /// How far a pull past the first page has gone, while its listener has not heard it end.
        private var leadingPull: CGFloat?
        /// The selection and the pages either side of it when those pages were last built.
        private var builtNeighbours: [SelectionValue] = []
        private var neighbourTimer: Timer?
        private var lastReport: TimeInterval = -.infinity
        private var pendingReport: PageSwipePosition?
        private var reportTimer: Timer?

        private struct Drag {
            var samples: [(time: TimeInterval, position: CGFloat)] = []
            var detent: Int
            let adopted: Bool
        }

        private struct Settle {
            let target: CGFloat
        }

        /// Sideways wheel movement, one page per burst: a fast spin or a held tilt moves one page,
        /// and the next burst after a pause moves the next.
        struct Wheel {
            private var lastEvent: TimeInterval = -.infinity
            private var cumulative: CGFloat = 0
            private var stepped = false

            /// The page step for a sideways wheel event: 1 forward, -1 back, 0 none. Line deltas step
            /// on the first tick; a precise device's points first add up to `wheelStepPoints`.
            mutating func step(deltaX: CGFloat, precise: Bool, inverted: Bool, time: TimeInterval) -> Int {
                if time - lastEvent > SwipePagerView.wheelBurstGap {
                    cumulative = 0
                    stepped = false
                }
                lastEvent = time
                guard !stepped else { return 0 }

                cumulative += deltaX
                guard cumulative != 0, !precise || abs(cumulative) >= SwipePagerView.wheelStepPoints else { return 0 }

                stepped = true
                // Wheel down or tilt right reports a negative delta unless natural scrolling inverts it.
                return (cumulative < 0) != inverted ? 1 : -1
            }
        }

        private enum Motion {
            case idle
            case dragging(Drag)
            case settling(Settle)
        }

        var isTracking: Bool {
            if case .idle = motion { return false }

            return true
        }

        var selectedValue: SelectionValue? {
            pages.indices.contains(selected) ? pages[selected] : nil
        }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            strip.wantsLayer = true
            addSubview(strip)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        private var width: CGFloat { bounds.width }
        private var maxPosition: CGFloat { CGFloat(max(pages.count - 1, 0)) * width }

        // MARK: Selection

        /// Shows `value`, sliding the strip there when `animated`.
        func move(to value: SelectionValue, animated: Bool) {
            guard let coordinator else { return }

            pages = coordinator.order()
            guard let index = pages.firstIndex(of: value) else { return }

            if case .dragging = motion {
                guard index != selected else { return }
                // A keyboard or menu switch ends the swipe in place.
                motion = .idle
                report(nil)
            }

            // Our own commit at lift lands here while the strip is still settling.
            if index == selected, isTracking || attached[index] != nil {
                attach(index, refresh: true)
                if builtNeighbours != neighbourValues { scheduleNeighbours() }
                return
            }

            selected = index
            if animated, window != nil, width > 0 {
                settle(to: index, velocity: 0)
            } else {
                snap()
            }
            scheduleNeighbours()
        }

        private func snap() {
            stopSettling()
            motion = .idle
            raw = CGFloat(selected) * width
            attach(selected)
            detach(keeping: Set(neighbours))
            rest()
            relayout()
            evict()
        }

        private var neighbours: [Int] {
            [selected - 1, selected, selected + 1].filter(pages.indices.contains)
        }

        private var neighbourValues: [SelectionValue] { neighbours.map { pages[$0] } }

        private func evict() {
            guard let coordinator, !pages.isEmpty else { return }

            coordinator.evict(keeping: Set(neighbourValues))
        }

        /// Builds the pages either side of the selection while the strip is at rest, so a swipe starts
        /// on pages that already exist. The timer fires in the default run loop mode only, so never
        /// inside a swipe's own event loop.
        private func scheduleNeighbours(after delay: TimeInterval = 0) {
            neighbourTimer?.invalidate()
            let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.buildNeighbours() }
            }
            RunLoop.main.add(timer, forMode: .default)
            neighbourTimer = timer
        }

        private func buildNeighbours() {
            neighbourTimer = nil
            guard case .idle = motion, width > 0, window != nil, !pages.isEmpty else { return }

            let stale = builtNeighbours != neighbourValues
            for index in neighbours where index != selected { attach(index, refresh: stale) }
            builtNeighbours = neighbourValues
            rest()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { scheduleNeighbours() }
        }

        /// At rest only the selected page shows; the ones either side wait hidden, out of the way of
        /// the pointer and VoiceOver.
        private func rest() {
            for (index, view) in attached { view.isHidden = index != selected }
        }

        // MARK: Layout

        override func layout() {
            super.layout()

            if width != lastWidth {
                // A resize mid-motion lands on the selected page rather than at a stale offset.
                if case .dragging = motion { report(nil) }
                lastWidth = width
                snap()
                // A sidebar resize changes the width on every mouse event; build once it stops.
                scheduleNeighbours(after: Self.resizeQuiet)
                return
            }
            relayout()
        }

        private func relayout() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // A leading pull belongs to its listener, so the first page does not band away.
            let position = coordinator?.onLeadingOverscroll != nil && selected == 0 ? max(raw, 0) : raw
            let shown = Self.rubberBand(position, max: maxPosition)
            if case .dragging = motion {
                if strip.frame.height != bounds.height {
                    strip.frame.size.height = bounds.height
                    for view in attached.values { view.frame.size.height = bounds.height }
                }
                // Only the strip's layer follows the fingers: a frame change has AppKit tell every view
                // on the strip its place in the window moved, and each page's hosting view and the
                // window's lay out again on every event.
                strip.layer?.setAffineTransform(CGAffineTransform(translationX: -shown - strip.frame.minX, y: 0))
            } else {
                strip.layer?.setAffineTransform(.identity)
                strip.frame = NSRect(x: -shown, y: 0, width: CGFloat(max(pages.count, 1)) * width, height: bounds.height)
                for (index, view) in attached {
                    view.frame = NSRect(x: CGFloat(index) * width, y: 0, width: width, height: bounds.height)
                }
            }
            CATransaction.commit()
        }

        // Content is set once per attach; only a SwiftUI update refreshes it, never a scroll event.
        private func attach(_ index: Int, refresh: Bool = false) {
            guard pages.indices.contains(index), let coordinator else { return }
            if !refresh, let view = attached[index], view.superview === strip { return }

            let view = coordinator.view(for: pages[index])
            attached[index] = view
            view.frame = NSRect(x: CGFloat(index) * width, y: 0, width: width, height: bounds.height)
            if view.superview !== strip { strip.addSubview(view) }
        }

        private func attach(range: ClosedRange<CGFloat>) {
            guard width > 0, !pages.isEmpty else { return }

            let last = pages.count - 1
            let low = min(max(Int((range.lowerBound / width).rounded(.down)), 0), last)
            let high = min(max(Int((range.upperBound / width).rounded(.up)) - 1, low), last)
            for index in low...high {
                attach(index)
                attached[index]?.isHidden = false
            }
        }

        private func detach(keeping keep: Set<Int>) {
            for (index, view) in attached where !keep.contains(index) {
                if view.superview === strip { view.removeFromSuperview() }
                attached[index] = nil
            }
        }

        // MARK: Gestures

        override func wantsForwardedScrollEvents(for axis: NSEvent.GestureAxis) -> Bool {
            axis == .horizontal
        }

        // SwiftUI's vertical scroll views keep the sideways wheel ticks they cannot scroll by, though
        // they pass a sideways gesture on, so the pager takes those ticks before the views inside it.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let hit = super.hitTest(point) else { return nil }
            guard coordinator?.swipeEnabled ?? true, let event = NSApp.currentEvent, event.type == .scrollWheel,
                  Self.isWheel(event), Self.isSideways(event)
            else { return hit }

            return self
        }

        /// A wheel pages a step at a time; a trackpad or Magic Mouse gesture, with its phases, drags the strip.
        static func isWheel(_ event: NSEvent) -> Bool {
            !event.hasPreciseScrollingDeltas || (event.phase == [] && event.momentumPhase == [])
        }

        static func isSideways(_ event: NSEvent) -> Bool {
            abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        }

        /// A gesture drags the strip when its first event is more sideways than upright.
        static func startsDrag(_ event: NSEvent) -> Bool {
            event.phase == .began && isSideways(event)
        }

        override func scrollWheel(with event: NSEvent) {
            guard coordinator?.swipeEnabled ?? true else { return super.scrollWheel(with: event) }
            let horizontal = Self.isSideways(event)

            if Self.isWheel(event) {
                if !(horizontal && wheelPage(event)) { super.scrollWheel(with: event) }
                return
            }

            guard Self.startsDrag(event), beginDrag() else {
                // The momentum that follows a swipe belongs to the swipe.
                if horizontal, event.momentumPhase != [] { return }
                return super.scrollWheel(with: event)
            }

            track()
        }

        func beginDrag() -> Bool {
            if case .dragging = motion { return false }

            guard let coordinator, width > 0 else { return false }

            pages = coordinator.order()
            // One page still drags when something listens for the pull past it.
            guard pages.count > 1 || (pages.count == 1 && coordinator.onLeadingOverscroll != nil) else { return false }

            let adopted = adoptSettle()
            let nearest = Self.nearest(raw, width: width, count: pages.count)
            motion = .dragging(Drag(detent: nearest, adopted: adopted))
            let shown = Self.rubberBand(raw, max: maxPosition)
            attach(range: (shown - width)...(shown + 2 * width))
            relayout()

            return true
        }

        // Arc's pager runs its own loop while fingers are down, so every event of the swipe
        // reaches it whichever view is under the pointer. A swipe cut short by the window or the
        // app losing focus never gets its `.ended`: the notifications wake the loop, a press ends
        // it and goes on to its view, and the idle timeout covers the rest.
        private func track() {
            guard let window else {
                motion = .idle
                return
            }

            var interrupted = false
            let wake = {
                interrupted = true
                if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                                  context: nil, subtype: 0, data1: 0, data2: 0) {
                    NSApp.postEvent(event, atStart: true)
                }
            }
            let center = NotificationCenter.default
            let observers = [
                center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: nil) { _ in wake() },
                center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: nil) { _ in wake() },
            ]
            defer { observers.forEach(center.removeObserver) }

            let presses: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            let mask = presses.union([.scrollWheel, .swipe, .mouseMoved, .mouseExited, .keyDown, .keyUp, .applicationDefined])
            tracking: while case .dragging = motion, !interrupted,
                            let event = window.nextEvent(matching: mask, until: Date(timeIntervalSinceNow: Self.swipeIdleTimeout),
                                                         inMode: .eventTracking, dequeue: true) {
                switch event.type {
                case .scrollWheel:
                    drag(event.phase, delta: event.scrollingDeltaX, time: event.timestamp)
                case .applicationDefined where interrupted:
                    break tracking
                case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                    NSApp.postEvent(event, atStart: true)
                    break tracking
                default:
                    NSApp.sendEvent(event)
                }
            }
            // Drop the wake event if the loop left before reading it.
            if interrupted { _ = window.nextEvent(matching: .applicationDefined, until: .distantPast, inMode: .eventTracking, dequeue: true) }
            if case .dragging = motion { drag(.cancelled, delta: 0, time: ProcessInfo.processInfo.systemUptime) }
            // However the loop ended, a pull the listener is holding must be let go, or the
            // library would stay where the fingers left it.
            if let distance = leadingPull { endLeadingPull(distance: distance, velocity: 0) }
        }

        private func endLeadingPull(distance: CGFloat, velocity: CGFloat) {
            leadingPull = nil
            coordinator?.onLeadingOverscroll?(.ended(distance: distance, velocity: velocity))
        }

        func drag(_ phase: NSEvent.Phase, delta: CGFloat, time: TimeInterval) {
            guard case .dragging(var drag) = motion else { return }

            switch phase {
            case .changed:
                raw += delta * -0.5
                drag.samples.append((time, raw))
                // Past the first page with a listener, the fingers drive what it shows (Arc's
                // library) one to one, and the strip holds still at the first page.
                if raw < 0, selected == 0, let action = coordinator?.onLeadingOverscroll {
                    drag.samples.removeAll { time - $0.time > Self.velocityWindow }
                    motion = .dragging(drag)
                    relayout()
                    leadingPull = -raw * 2
                    action(.changed(distance: -raw * 2))
                    return
                }
                // Back past the first page the other way: the pull is over, so let it go.
                if leadingPull != nil { endLeadingPull(distance: 0, velocity: 0) }
                drag.samples.removeAll { time - $0.time > Self.velocityWindow }

                let nearest = Self.nearest(raw, width: width, count: pages.count)
                // Arc plays .alignment; .levelChange is the firmest pattern AppKit offers.
                if nearest != drag.detent {
                    drag.detent = nearest
                    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                }

                motion = .dragging(drag)
                let shown = Self.rubberBand(raw, max: maxPosition)
                attach(range: shown...(shown + width))
                relayout()
                reportPosition(shown)
            case .ended where leadingPull != nil:
                let velocity = Self.velocity(drag.samples)
                let distance = max(-raw * 2, 0)
                raw = 0
                motion = .idle
                relayout()
                report(nil)
                endLeadingPull(distance: distance, velocity: -velocity * 2)
            case .ended:
                var velocity = Self.velocity(drag.samples)
                let target = Self.target(position: raw, velocity: velocity, width: width,
                                         count: pages.count, adopted: drag.adopted)
                // Carry the flick into the spring only when it heads for the target.
                if (velocity >= 0) == (CGFloat(target) * width < raw) { velocity = 0 }

                let changed = target != selected
                selected = target
                settle(to: target, velocity: velocity)
                if changed { commitAfterSlideStarts(pages[target]) }
            case .cancelled, []:
                if leadingPull != nil {
                    raw = 0
                    endLeadingPull(distance: 0, velocity: 0)
                }
                settle(to: selected, velocity: 0)
            default:
                break
            }
        }

        private func wheelPage(_ event: NSEvent) -> Bool {
            guard let coordinator else { return false }
            if case .dragging = motion { return true }

            let step = wheel.step(deltaX: event.scrollingDeltaX, precise: event.hasPreciseScrollingDeltas,
                                  inverted: event.isDirectionInvertedFromDevice, time: event.timestamp)
            guard step != 0 else { return true }

            pages = coordinator.order()
            let target = selected + step
            guard pages.indices.contains(target) else { return true }

            selected = target
            settle(to: target, velocity: 0)
            commitAfterSlideStarts(pages[target])
            return true
        }

        /// Hands the slide to the render server before the switch's main-thread work, which
        /// otherwise held the strip still for its length. The page still changes as it starts.
        private func commitAfterSlideStarts(_ value: SelectionValue) {
            CATransaction.flush()
            coordinator?.commit(value)
        }

        // MARK: Settling

        private func settle(to index: Int, velocity: CGFloat) {
            guard width > 0 else { return snap() }

            adoptSettle()
            motionID &+= 1
            let id = motionID
            let target = CGFloat(index) * width
            let offsets = Self.springOffsets(from: raw - target, velocity: velocity)
            // A flick carries the spring past its page, so the strip shows the page beyond for a moment.
            let path = offsets.map { Self.rubberBand(target + $0, max: maxPosition) }

            attach(range: (path.min() ?? target)...((path.max() ?? target) + width))
            raw = target
            motion = .settling(Settle(target: target))
            report(nil)

            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.motionID == id else { return }
                    self.motion = .idle
                    self.detach(keeping: Set(self.neighbours))
                    self.evict()
                    self.rest()
                    if self.builtNeighbours != self.neighbourValues { self.scheduleNeighbours() }
                }
            }
            relayout()
            if offsets.count > 1 {
                // Additive keyframes of the strip's x, sampled at 240 Hz as Arc does.
                let animation = CAKeyframeAnimation(keyPath: "position.x")
                animation.isAdditive = true
                animation.values = offsets.map { target - Self.rubberBand(target + $0, max: maxPosition) }
                animation.keyTimes = offsets.indices.map { NSNumber(value: Double($0) / Double(offsets.count - 1)) }
                animation.duration = Double(offsets.count - 1) * Self.sampleStep
                animation.calculationMode = .linear
                strip.layer?.add(animation, forKey: "settle")
            }
            CATransaction.commit()
        }

        /// Takes over a settle in flight at its on-screen position. Returns whether one was running.
        @discardableResult
        private func adoptSettle() -> Bool {
            guard case .settling(let settle) = motion else { return false }

            motionID &+= 1
            if let layer = strip.layer, let presented = layer.presentation() {
                let shown = settle.target - (presented.position.x - layer.position.x)
                raw = Self.inverseRubberBand(shown, max: maxPosition)
            }
            stopSettling()
            motion = .idle
            relayout()

            return true
        }

        private func stopSettling() {
            strip.layer?.removeAnimation(forKey: "settle")
        }

        // MARK: Reporting

        private func reportPosition(_ shown: CGFloat) {
            guard width > 0, !pages.isEmpty else { return }

            let fraction = min(max(shown / width, 0), CGFloat(pages.count - 1))
            let floor = Int(fraction.rounded(.down))
            let ceil = min(floor + 1, pages.count - 1)
            report(PageSwipePosition(from: AnyHashable(pages[floor]), to: AnyHashable(pages[ceil]),
                                     progress: Double(fraction - CGFloat(floor))))
        }

        /// The end of a swipe goes out at once; positions at most once a display frame, the latest
        /// one, since the trackpad can send more events than the screen shows frames.
        private func report(_ position: PageSwipePosition?) {
            guard let position else {
                reportTimer?.invalidate()
                reportTimer = nil
                pendingReport = nil
                coordinator?.onSwipe?(nil)
                return
            }
            let now = ProcessInfo.processInfo.systemUptime
            let frame = window?.screen?.minimumRefreshInterval ?? Self.frameInterval
            if reportTimer == nil, now - lastReport >= frame {
                lastReport = now
                coordinator?.onSwipe?(position)
                return
            }
            pendingReport = position
            guard reportTimer == nil else { return }

            let timer = Timer(timeInterval: max(lastReport + frame - now, 0), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.sendPendingReport() }
            }
            RunLoop.main.add(timer, forMode: .common)
            reportTimer = timer
        }

        private func sendPendingReport() {
            reportTimer = nil
            guard let position = pendingReport else { return }

            pendingReport = nil
            lastReport = ProcessInfo.processInfo.systemUptime
            coordinator?.onSwipe?(position)
        }

        // MARK: Arc's constants

        static var velocityWindow: TimeInterval { 0.1 }
        static var flingVelocity: CGFloat { 5 }
        static var springResponse: Double { 0.25 }
        static var sampleStep: Double { 1.0 / 240 }

        // MARK: Nook's wheel constants

        /// A pause longer than this ends a wheel burst.
        static var wheelBurstGap: TimeInterval { 0.25 }
        /// About one line of a wheel, for a precise device without gesture phases.
        static var wheelStepPoints: CGFloat { 10 }
        /// A tracked swipe with no event this long is over, as the library's swipe is.
        static var swipeIdleTimeout: TimeInterval { 1 }
        /// A window on no screen reports positions this often.
        static var frameInterval: TimeInterval { 1.0 / 60 }
        /// A width that has not changed for this long is a resize that stopped.
        static var resizeQuiet: TimeInterval { 0.25 }

        /// Arc's end resistance: 255 points at most past either end.
        static func rubberBand(_ raw: CGFloat, max upper: CGFloat) -> CGFloat {
            let clamped = min(max(raw, 0), upper)
            let over = abs(raw - clamped)
            guard over > 0 else { return raw }

            return clamped + (raw < clamped ? -1 : 1) * 255 * (1 - 1 / (over * 0.15 / 255 + 1))
        }

        static func inverseRubberBand(_ shown: CGFloat, max upper: CGFloat) -> CGFloat {
            let clamped = min(max(shown, 0), upper)
            let over = min(abs(shown - clamped), 254.9)
            guard over > 0 else { return shown }

            return clamped + (shown < clamped ? -1 : 1) * over * 255 / ((255 - over) * 0.15)
        }

        static func nearest(_ position: CGFloat, width: CGFloat, count: Int) -> Int {
            min(max(Int((position / width).rounded()), 0), count - 1)
        }

        /// Points per second over the last 100 ms of samples.
        static func velocity(_ samples: [(time: TimeInterval, position: CGFloat)]) -> CGFloat {
            guard let first = samples.first, let last = samples.last else { return 0 }

            let elapsed = last.time - first.time
            guard elapsed > 0, elapsed < velocityWindow else { return 0 }

            return (last.position - first.position) / elapsed
        }

        /// Arc's page choice at lift: any flick moves one page its way, otherwise the nearest page.
        static func target(position: CGFloat, velocity: CGFloat, width: CGFloat, count: Int, adopted: Bool) -> Int {
            guard count > 0, width > 0 else { return 0 }
            guard position >= 0 else { return 0 }

            let floor = min(Int((position / width).rounded(.down)), count - 1)
            let pick: Int
            if abs(velocity) >= flingVelocity {
                pick = adopted ? floor + (velocity > 0 ? 1 : -1) : (velocity > 0 ? floor + 1 : floor)
            } else {
                pick = Int((position / width).rounded())
            }

            return min(max(pick, floor - 1, 0), floor + 1, count - 1)
        }

        /// A critically damped spring from `offset` toward 0, sampled at 240 Hz until it rests.
        static func springOffsets(from offset: CGFloat, velocity: CGFloat) -> [CGFloat] {
            let omega = 2 * Double.pi / springResponse
            let x0 = Double(offset), v0 = Double(velocity)
            var offsets: [CGFloat] = []
            var t = 0.0
            while t < 2 {
                let decay = exp(-omega * t)
                let x = (x0 + (v0 + omega * x0) * t) * decay
                let v = (v0 - omega * (v0 + omega * x0) * t) * decay
                offsets.append(CGFloat(x))
                if t > 0, abs(x) < 0.1, abs(v) < 1 { break }
                t += sampleStep
            }
            offsets[offsets.count - 1] = 0

            return offsets
        }
    }

    // Owns its frame outside SwiftUI so selection updates cannot interrupt the strip.
    final class PageHostView: NSView {
        private let hostingView: HostingView

        var rootView: Content {
            get { hostingView.rootView }
            set { hostingView.rootView = newValue }
        }

        init(rootView: Content) {
            hostingView = HostingView(rootView: rootView)
            super.init(frame: .zero)
            wantsLayer = true
            hostingView.autoresizingMask = [.width, .height]
            addSubview(hostingView)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            hostingView.frame = bounds
        }

        override func wantsForwardedScrollEvents(for axis: NSEvent.GestureAxis) -> Bool {
            axis == .horizontal
        }
    }

    final class HostingView: NSHostingView<Content> {
        // Scroll views inside forward horizontal swipes up to the pager.
        override func wantsForwardedScrollEvents(for axis: NSEvent.GestureAxis) -> Bool {
            axis == .horizontal
        }
    }
}

struct PlatformPageView_Mac_Previews: PreviewProvider {

    static var previews: some View {
        PageViewBasicExample()
            .pageViewStyle(.scroll)
    }
}

#endif
