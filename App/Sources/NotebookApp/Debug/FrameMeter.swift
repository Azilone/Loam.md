#if DEBUG || LOAM_AGENT_BRIDGE
import AppKit
import QuartzCore

/// Logs the main window's frame rate, for `LOAM_FRAMES=1 scripts/agent-run.sh NAME --release` (docs/PERF.md): each
/// second with a late frame, one line on stderr (the instance's app.log) with the frames shown, the expected rate and
/// the longest gap. A display link fires once per refresh while the main thread is free, so a missed tick is a frame
/// the main thread was too busy to draw; work in the render server is not seen.
@MainActor
final class FrameMeter: NSObject {
    private static var current: FrameMeter?
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var windowStart: CFTimeInterval = 0
    private var gaps: [CFTimeInterval] = []
    /// An input the driver just sent (`mark`), followed for half a second: when the next frame came and how late
    /// the frames after it were, the latency a person feels after a click or a key.
    private var input: (label: String, at: CFTimeInterval, ticks: [CFTimeInterval])?

    /// Starts following an input sent by the debug driver, when the meter runs.
    static func mark(_ label: String) {
        current?.input = (label, CACurrentMediaTime(), [])
    }

    static func startIfAsked(in window: NSWindow) {
        guard current == nil, ProcessInfo.processInfo.environment["LOAM_FRAMES"] != nil,
              let view = window.contentView else { return }
        let meter = FrameMeter()
        let link = view.displayLink(target: meter, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        meter.link = link
        current = meter
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        defer { last = now }
        followInput(CACurrentMediaTime(), expected: max(link.targetTimestamp - link.timestamp, 1.0 / 120))
        guard last > 0 else { windowStart = now; return }
        gaps.append(now - last)
        guard now - windowStart >= 1 else { return }
        let expected = max(link.targetTimestamp - link.timestamp, 1.0 / 120)
        let late = gaps.filter { $0 > expected * 1.5 }
        if !late.isEmpty {
            let line = String(
                format: "frames: %d in %.2f s at %.0f Hz expected, %d late, longest %.0f ms\n",
                gaps.count, now - windowStart, 1 / expected, late.count, (gaps.max() ?? 0) * 1000
            )
            FileHandle.standardError.write(Data(line.utf8))
        }
        gaps.removeAll()
        windowStart = now
    }

    private func followInput(_ now: CFTimeInterval, expected: CFTimeInterval) {
        guard var input else { return }
        input.ticks.append(now)
        self.input = input
        guard now - input.at >= 0.5 else { return }
        self.input = nil
        let times = [input.at] + input.ticks
        let steps = zip(times.dropFirst(), times).map { $0 - $1 }
        let late = steps.dropFirst().filter { $0 > expected * 1.5 }
        let line = String(
            format: "input %@: first frame +%.1f ms, then %d late of %d, longest %.0f ms\n",
            input.label, (steps.first ?? 0) * 1000, late.count, steps.count - 1, (steps.dropFirst().max() ?? 0) * 1000
        )
        FileHandle.standardError.write(Data(line.utf8))
    }
}
#endif
