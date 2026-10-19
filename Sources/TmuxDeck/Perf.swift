import AppKit
import Foundation
import os

/// Where the time goes. Everything here is off unless it finds something slow, and reads with:
///
///     log stream --predicate 'subsystem == "io.github.tmuxdeck"' --style compact
///
/// `timed` logs any main-thread job slower than a frame; the watchdog logs every stretch the
/// main thread didn't service its queue for a quarter second (what a click that "didn't take"
/// looks like from the inside). See docs/testing.md, "Profiling lag".
enum Perf {
    static let log = Logger(subsystem: "io.github.tmuxdeck", category: "perf")

    @discardableResult
    static func timed<T>(_ label: String, threshold: TimeInterval = 0.016,
                         _ body: () throws -> T) rethrows -> T {
        let start = ContinuousClock.now
        defer {
            let elapsed = start.duration(to: .now)
            if elapsed > .milliseconds(Int64(threshold * 1000)) {
                log.notice("\(label, privacy: .public) took \(Self.ms(elapsed))ms")
            }
        }
        return try body()
    }

    /// A timestamped breadcrumb: a click, a selection, a tile appearing.
    static func event(_ message: String) {
        log.notice("\(message, privacy: .public)")
    }

    static func ms(_ d: Duration) -> Int64 {
        d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000
    }

    /// Pings the main queue from a background thread and reports when the answer comes late.
    static func startWatchdog() {
        let queue = DispatchQueue(label: "io.github.tmuxdeck.watchdog", qos: .utility)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: .milliseconds(100))
        var waiting = false
        var pings = 0, late = 0, windowStart = ContinuousClock.now
        timer.setEventHandler {
            guard !waiting else { return }
            waiting = true
            let sent = ContinuousClock.now
            DispatchQueue.main.async {
                let delay = sent.duration(to: .now)
                queue.async {
                    waiting = false
                    pings += 1
                    if delay > .milliseconds(50) { late += 1 }
                    // Many short stalls feel as bad as one long one: say so once in a while.
                    if windowStart.duration(to: .now) > .seconds(5) {
                        if pings > 0 && late * 100 / pings >= 30 {
                            log.notice("main thread saturated: \(late * 100 / pings)% of pings came late over 5s")
                        }
                        pings = 0; late = 0; windowStart = .now
                    }
                }
                if delay > .milliseconds(120) {
                    log.notice("main thread was busy for \(Self.ms(delay))ms")
                }
            }
        }
        timer.resume()
        watchdog = timer
        // Every click, so a click that "didn't take" can be told from one that never arrived.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
            let p = event.locationInWindow
            let kind = event.type == .leftMouseDown ? "down" : "up"
            log.notice("mouse \(kind, privacy: .public) at \(Int(p.x)),\(Int(p.y)) window=\(event.window?.windowNumber ?? 0)")
            return event
        }
    }
    nonisolated(unsafe) private static var clickMonitor: Any?
    nonisolated(unsafe) private static var watchdog: DispatchSourceTimer?
}
