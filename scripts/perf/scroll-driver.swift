// Licensed under GPL-3.0. See LICENSE.
//
// Scrolls the page under the pointer down and up for a number of seconds, the same way every run,
// so traced passes are comparable:
//   swiftc -O scripts/perf/scroll-driver.swift -o /tmp/scroll-driver && /tmp/scroll-driver 20 960 540
// The arguments are seconds and the screen point to scroll at (the Nook page).

import CoreGraphics
import Foundation

let arguments = CommandLine.arguments.dropFirst().map { Double($0) ?? 0 }
let seconds = arguments.first ?? 20

/// The middle of Nook's front window, where its page is, when no point is given.
func nookWindowCenter() -> CGPoint? {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for window in windows where (window[kCGWindowOwnerName as String] as? String) == "Nook" && (window[kCGWindowLayer as String] as? Int) == 0 {
        guard let bounds = window[kCGWindowBounds as String] as? [String: Double],
              let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"],
              width > 400 else { continue }
        return CGPoint(x: x + width * 0.6, y: y + height / 2)
    }
    return nil
}

let point = arguments.count >= 3 ? CGPoint(x: arguments[1], y: arguments[2]) : (nookWindowCenter() ?? CGPoint(x: 960, y: 540))
let source = CGEventSource(stateID: .hidSystemState)
CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)

let start = Date()
var step = 0
while Date().timeIntervalSince(start) < seconds {
    // Two seconds down, two seconds up, in 60 Hz steps.
    let direction: Int32 = (step / 120) % 2 == 0 ? -6 : 6
    CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: direction, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
    step += 1
    usleep(16_667)
}
