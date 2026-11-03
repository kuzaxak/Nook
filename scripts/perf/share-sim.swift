// Licensed under GPL-3.0. See LICENSE.
//
// Captures the main display through ScreenCaptureKit the way a video call's screen share does,
// so screen-share lag can be reproduced without a call:
//   swiftc -O -parse-as-library scripts/perf/share-sim.swift -o /tmp/share-sim && /tmp/share-sim 30
// Prints how many frames macOS delivered: fewer than asked for means the compositor fell behind.

import CoreMedia
import Foundation
import ScreenCaptureKit

final class FrameCounter: NSObject, SCStreamOutput {
    private let lock = NSLock()
    private var count = 0

    var frames: Int { lock.withLock { count } }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        lock.withLock { count += 1 }
    }
}

@main
struct ShareSim {
    static func main() async throws {
        let seconds = Double(CommandLine.arguments.dropFirst().first ?? "30") ?? 30
        let fps = Int32(CommandLine.arguments.dropFirst(2).first ?? "30") ?? 30
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            FileHandle.standardError.write(Data("No display to capture.\n".utf8))
            exit(1)
        }
        let configuration = SCStreamConfiguration()
        configuration.width = display.width * 2
        configuration.height = display.height * 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: fps)
        configuration.queueDepth = 6
        configuration.showsCursor = true
        let counter = FrameCounter()
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration, delegate: nil)
        try stream.addStreamOutput(counter, type: .screen, sampleHandlerQueue: DispatchQueue(label: "share-sim.frames"))
        try await stream.startCapture()
        let started = Date()
        print("share-sim: capturing \(display.width)x\(display.height) at \(fps) fps for up to \(Int(seconds)) s")
        let report = {
            let elapsed = Date().timeIntervalSince(started)
            print(String(format: "share-sim: %d frames in %.0f s, %.1f fps delivered of %d asked",
                         counter.frames, elapsed, Double(counter.frames) / max(elapsed, 1), fps))
        }
        // An interrupt from the trace script ends the capture early and still reports.
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interrupt.setEventHandler { report(); exit(0) }
        interrupt.resume()
        try await Task.sleep(for: .seconds(seconds))
        try await stream.stopCapture()
        report()
    }
}
