import AppKit
import SwiftUI

/// `TmuxDeck --bench-chats [count]`: opens the largest cached conversations off-screen, the way
/// switching to them does, and prints how long each took to build and lay out — first open and
/// again warm. No server is contacted and no window is shown; the app exits when done. This is
/// how "switching is slow" gets a number instead of a feeling (docs/testing.md).
@MainActor
enum Bench {
    static let enabled = CommandLine.arguments.contains("--bench-chats")
        || CommandLine.arguments.contains("--check-poll")

    static func run() {
        if CommandLine.arguments.contains("--check-poll") { return checkPoll() }
        let args = CommandLine.arguments
        let count = args.firstIndex(of: "--bench-chats").flatMap { i in
            args.indices.contains(i + 1) ? Int(args[i + 1]) : nil } ?? 6
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TmuxDeck/chats-v10")
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("claude-") }
            .sorted { size($0) > size($1) }
            .prefix(count)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 820),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let model = TmuxModel(host: "bench-offline")
        print("chat                                    turns   open(ms)  reopen(ms)")
        for file in files {
            let sid = String(file.deletingPathExtension().lastPathComponent.dropFirst("claude-".count))
            let store = ChatStore(sessionID: sid, remote: Remote(host: "bench-offline"))
            let first = mount(store, model: model, in: window)
            window.contentView = NSView()
            let second = mount(store, model: model, in: window)
            window.contentView = NSView()
            print(sid.padding(toLength: 40, withPad: " ", startingAt: 0),
                  String(store.turns.count).padding(toLength: 7, withPad: " ", startingAt: 0),
                  String(first).padding(toLength: 9, withPad: " ", startingAt: 0), second)
        }
        exit(0)
    }

    /// `--check-poll`: one read-only poll of each saved server, printed as the app understood it —
    /// window states, Claude's activity line, status chips, question options. For checking the
    /// screen readers after a change without opening the UI.
    private static func checkPoll() {
        let hosts = (UserDefaults(suiteName: "io.github.tmuxdeck") ?? .standard).stringArray(forKey: "hosts") ?? []
        Task { @MainActor in
            for host in hosts {
                let model = TmuxModel(host: host)
                await model.refresh()
                print("server connected=\(model.connected) error=\(model.lastError ?? "-")")
                for session in model.sessions {
                    for w in session.windows {
                        print("  \(session.name) #\(w.index) \(w.state.label) claude=\(w.claude != nil) codex=\(w.codex != nil)")
                        if let a = model.activities[w.id] { print("      activity: \(a.glyph) \(a.headline)") }
                        if let chips = model.statusLines[w.id] { print("      status: \(chips.joined(separator: " | ").prefix(140))") }
                        if let o = model.promptOptions[w.id] { print("      options: \(o.map(\.label))") }
                        if let q = model.promptQuestions[w.id] { print("      question: \(q.prefix(100))") }
                        if let t = model.leftoverInput[w.id] { print("      leftover input: \(t.prefix(60))") }
                    }
                }
            }
            exit(0)
        }
    }

    private static func mount(_ store: ChatStore, model: TmuxModel, in window: NSWindow) -> Int64 {
        let start = ContinuousClock.now
        let root = ChatView(window: nil, store: store)
            .environment(\.theme, ThemeManager.shared.theme)
            .environment(\.fonts, Zoom.shared.font)
            .environment(model)
        let host = NSHostingView(rootView: root)
        host.frame = window.contentRect(forFrameRect: window.frame)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.display()
        // A second pass, as the scroll view settles and measures again.
        RunLoop.main.run(until: Date().addingTimeInterval(0.001))
        host.layoutSubtreeIfNeeded()
        let elapsed = Perf.ms(start.duration(to: .now))
        // BENCH_PNG=<dir>: also save what it drew, settled, to check the view isn't blank.
        if let dir = ProcessInfo.processInfo.environment["BENCH_PNG"] {
            RunLoop.main.run(until: Date().addingTimeInterval(Double(ProcessInfo.processInfo.environment["BENCH_SETTLE"] ?? "1.5") ?? 1.5))
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                let url = URL(fileURLWithPath: dir).appendingPathComponent("\(store.sessionID.prefix(8)).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
        }
        return elapsed
    }

    private static func size(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}
