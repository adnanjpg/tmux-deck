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

    static func ms(_ d: Duration) -> Int64 {
        d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000
    }

    /// Pings the main queue from a background thread and reports when the answer comes late.
    static func startWatchdog() {
        let queue = DispatchQueue(label: "io.github.tmuxdeck.watchdog", qos: .utility)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: .milliseconds(250))
        var waiting = false
        timer.setEventHandler {
            guard !waiting else { return }
            waiting = true
            let sent = ContinuousClock.now
            DispatchQueue.main.async {
                let late = sent.duration(to: .now)
                queue.async { waiting = false }
                if late > .milliseconds(250) {
                    log.notice("main thread was busy for \(Self.ms(late))ms")
                }
            }
        }
        timer.resume()
        watchdog = timer
    }
    nonisolated(unsafe) private static var watchdog: DispatchSourceTimer?
}
