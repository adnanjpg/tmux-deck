import AppKit
import SwiftTerm

/// One live SSH connection showing one tmux session.
///
/// It attaches to a private view session grouped with the real one, with tmux's
/// status bar hidden (the sidebar replaces it) and mouse support on (click panes,
/// drag dividers, scroll history). Switching windows from the sidebar just tells
/// tmux to change the view session's current window; nothing reconnects.
@MainActor
final class TerminalController: NSObject, LocalProcessTerminalViewDelegate {
    var session: String
    let viewSession: String
    let view: LocalProcessTerminalView
    private(set) var alive = false
    var onStateChange: (() -> Void)?
    private var pendingWindow: String?

    let remote: Remote

    init(session: String, remote: Remote) {
        self.session = session
        self.remote = remote
        self.viewSession = viewSessionPrefix + session + "-" + String(UUID().uuidString.prefix(4)).lowercased()
        self.view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        super.init()
        view.processDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: CGFloat(UserDefaults.standard.double(forKey: "fontSize").nonZero ?? 13), weight: .regular)
        view.optionAsMetaKey = true
        applyColors()
        NotificationCenter.default.addObserver(forName: .themeChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyColors() }
        }
    }

    func applyColors() {
        let theme = ThemeManager.shared.theme
        let dark = theme.isDark ?? (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        view.nativeBackgroundColor = theme.terminalBackground ?? (dark ? NSColor(white: 0.11, alpha: 1) : NSColor(white: 0.995, alpha: 1))
        view.nativeForegroundColor = theme.terminalForeground ?? (dark ? NSColor(white: 0.9, alpha: 1) : NSColor(white: 0.12, alpha: 1))
        view.caretColor = theme.terminalCursor ?? theme.accent
        view.selectedTextBackgroundColor = theme.terminalSelection ?? NSColor.selectedTextBackgroundColor
        if let ansi = theme.ansi {
            view.installColors(ansi.map { c in
                let rgb = c.usingColorSpace(.sRGB) ?? c
                return SwiftTerm.Color(red: UInt16(rgb.redComponent * 65535), green: UInt16(rgb.greenComponent * 65535),
                                       blue: UInt16(rgb.blueComponent * 65535))
            })
        }
    }

    /// Connects if needed and brings `windowID` to the front.
    /// The pane this app zoomed so a single-pane tile shows only that pane.
    private var zoomedPane: String?

    /// Connects if needed and brings `windowID` to the front. With `paneID`, that
    /// pane is zoomed to fill the view (a tile showing one pane shouldn't show its
    /// neighbours); showing the whole window undoes a zoom this app made.
    func show(windowID: String, paneID: String? = nil) {
        let wasAlive = alive
        if !alive {
            connect(initialWindow: windowID)
        } else {
            Task { _ = await remote.run("tmux select-window -t \(sq(viewSession + ":" + windowID))") }
        }
        let previous = zoomedPane
        zoomedPane = paneID
        Task {
            if !wasAlive { try? await Task.sleep(for: .milliseconds(800)) }
            var script = ""
            if let previous, previous != paneID {
                script += "[ \"$(tmux display -p -t \(sq(previous)) '#{window_zoomed_flag}')\" = 1 ] && tmux resize-pane -Z -t \(sq(previous)); "
            }
            if let paneID {
                let p = sq(paneID)
                // select-pane on another pane of a zoomed window unzooms it, so zoom after selecting.
                script += "tmux select-pane -t \(p) && { [ \"$(tmux display -p -t \(p) '#{window_zoomed_flag}')\" = 1 ] || tmux resize-pane -Z -t \(p); }"
            }
            if !script.isEmpty { _ = await remote.run(script) }
        }
    }

    /// Undoes this app's zoom when the terminal tile goes away.
    func releaseZoom() {
        guard let pane = zoomedPane else { return }
        zoomedPane = nil
        Task {
            _ = await remote.run("[ \"$(tmux display -p -t \(sq(pane)) '#{window_zoomed_flag}')\" = 1 ] && tmux resize-pane -Z -t \(sq(pane)); true")
        }
    }

    func connect(initialWindow: String?) {
        let select = initialWindow.map { " \\; select-window -t \(sq(":" + $0))" } ?? ""
        // Grouped session: shares windows with `session`, has its own current window.
        // Never set destroy-unattached here: in tmux 3.4 that also destroys the real
        // session whenever nothing is attached to it, killing every window in it.
        // Stale view sessions are cleaned up by TmuxModel's refresh instead.
        let script = "tmux kill-session -t \(sq("=" + viewSession)) 2>/dev/null; "
            + "exec tmux new-session -t \(sq(session)) -s \(sq(viewSession))"
            + " \\; set status off \\; set mouse on" + select

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        alive = true
        view.startProcess(executable: "/usr/bin/ssh",
                          args: remote.interactiveArguments(script),
                          environment: env.map { "\($0.key)=\($0.value)" })
        onStateChange?()
    }

    func reconnect(window: String?) {
        view.resetToInitialState()
        connect(initialWindow: window)
    }

    func stop() {
        if alive { view.terminate() }
        alive = false
    }

    // MARK: LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            self.alive = false
            self.onStateChange?()
        }
    }
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
