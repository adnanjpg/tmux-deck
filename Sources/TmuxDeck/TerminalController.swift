import AppKit
import SwiftTerm

/// One live SSH connection showing one tmux session.
///
/// It reconnects on its own when the link drops — tmux kept everything running on the other
/// side, so there's nothing to decide — backing off so a host that's properly down isn't
/// hammered. The Reconnect button is still there for when you don't want to wait.
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
    /// Set while the app wants this terminal up; cleared by `stop()`, so a deliberate close
    /// doesn't start reconnecting.
    private var wanted = false
    private var retry: Task<Void, Never>?
    private var attempt = 0
    private(set) var reconnecting = false
    private var lastWindow: String?

    let remote: Remote

    init(session: String, remote: Remote) {
        self.session = session
        self.remote = remote
        self.viewSession = viewSessionPrefix + session + "-" + String(UUID().uuidString.prefix(4)).lowercased()
        self.view = ClickableTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        super.init()
        view.processDelegate = self
        view.font = Zoom.shared.font.terminal
        view.optionAsMetaKey = true
        applyColors()
        NotificationCenter.default.addObserver(forName: .fontSizeChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.view.font = Zoom.shared.font.terminal }
        }
        NotificationCenter.default.addObserver(forName: .themeChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyColors() }
        }
    }

    func applyColors() {
        applyTerminalTheme(to: view)
    }

    /// Connects if needed and brings `windowID` to the front.
    /// The pane this app zoomed so a single-pane tile shows only that pane.
    private var zoomedPane: String?

    /// Connects if needed and brings `windowID` to the front. With `paneID`, that
    /// pane is zoomed to fill the view (a tile showing one pane shouldn't show its
    /// neighbours); showing the whole window undoes a zoom this app made.
    func show(windowID: String, paneID: String? = nil) {
        lastWindow = windowID
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
        // Some TUIs pick a light or dark palette from COLORFGBG rather than probing with
        // OSC 11; tell them which one this terminal is using.
        env["COLORFGBG"] = Zoom.terminalIsDark ? "15;0" : "0;15"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        alive = true
        wanted = true
        lastWindow = initialWindow ?? lastWindow
        reconnecting = false
        let command = remote.interactiveCommand(script)
        view.startProcess(executable: command.executable,
                          args: command.args,
                          environment: env.map { "\($0.key)=\($0.value)" })
        onStateChange?()
    }

    func reconnect(window: String?) {
        retry?.cancel()
        retry = nil
        attempt = 0
        reconnecting = false
        view.resetToInitialState()
        connect(initialWindow: window ?? lastWindow)
    }

    func stop() {
        wanted = false
        retry?.cancel()
        retry = nil
        reconnecting = false
        if alive { view.terminate() }
        alive = false
    }

    /// Waits a bit longer each time, up to half a minute.
    private func scheduleReconnect() {
        guard wanted, retry == nil else { return }
        attempt += 1
        let delay = min(pow(1.7, Double(attempt)), 30)
        reconnecting = true
        onStateChange?()
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.wanted, !self.alive else { return }
            self.retry = nil
            self.view.resetToInitialState()
            self.connect(initialWindow: self.lastWindow)
        }
    }

    // MARK: LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            self.alive = false
            self.onStateChange?()
            self.scheduleReconnect()
        }
    }
}

