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

    /// Starts following an input sent by the debug driver, when the meter runs. An input still followed (keys
    /// typed faster than two a second) is logged first, over the frames until this one.
    static func mark(_ label: String) {
        guard let current else { return }
        if current.input != nil { current.logInput() }
        current.input = (label, CACurrentMediaTime(), [])
        current.busy?.mark(label)
    }

    /// The main thread's work after each input, turn by turn of its run loop: it needs no display, so it measures
    /// while the screen is asleep or locked, when the display link gives no frames.
    private var busy: BusyMeter?

    static func startIfAsked(in window: NSWindow) {
        guard current == nil, ProcessInfo.processInfo.environment["LOAM_FRAMES"] != nil,
              let view = window.contentView else { return }
        let meter = FrameMeter()
        let link = view.displayLink(target: meter, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        meter.link = link
        meter.busy = BusyMeter()
        current = meter
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        defer { last = now }
        followInput(CACurrentMediaTime())
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

    private func followInput(_ now: CFTimeInterval) {
        guard var input else { return }
        input.ticks.append(now)
        self.input = input
        guard now - input.at >= 0.5 else { return }
        logInput()
    }

    private func logInput() {
        guard let input else { return }
        self.input = nil
        let expected = max((link.map { $0.targetTimestamp - $0.timestamp }) ?? 0, 1.0 / 120)
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
/// Logs, for an input marked by the driver, the longest turn of the main run loop in the second after it and the
/// time the main thread was busy in all: `busy press: longest 4.1 ms, 9.0 ms in 6 turns`.
@MainActor
final class BusyMeter {
    private var observer: CFRunLoopObserver?
    private var turnStart: CFTimeInterval?
    private var input: (label: String, at: CFTimeInterval, longest: CFTimeInterval, total: CFTimeInterval, turns: Int)?

    init() {
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
                                                          true, 0) { [weak self] _, activity in
            MainActor.assumeIsolated { self?.observe(activity) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
        turnStart = CACurrentMediaTime()
    }

    func mark(_ label: String) {
        log()
        // The marked input runs in the turn under way: it counts from now.
        turnStart = CACurrentMediaTime()
        input = (label, CACurrentMediaTime(), 0, 0, 0)
    }

    private func observe(_ activity: CFRunLoopActivity) {
        let now = CACurrentMediaTime()
        if activity == .afterWaiting {
            turnStart = now
            if let input, now - input.at > 1 { log() }
            return
        }
        guard let start = turnStart else { return }
        turnStart = nil
        guard var input else { return }
        let turn = now - start
        input.longest = max(input.longest, turn)
        input.total += turn
        input.turns += 1
        self.input = input
    }

    private func log() {
        guard let input else { return }
        self.input = nil
        let line = String(format: "busy %@: longest %.1f ms, %.1f ms in %d turns\n",
                          input.label, input.longest * 1000, input.total * 1000, input.turns)
        FileHandle.standardError.write(Data(line.utf8))
    }
}
#endif
