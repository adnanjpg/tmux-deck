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

    init(session: String) {
        self.session = session
        self.viewSession = viewSessionPrefix + session + "-" + String(UUID().uuidString.prefix(4)).lowercased()
        self.view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        super.init()
        view.processDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: CGFloat(UserDefaults.standard.double(forKey: "fontSize").nonZero ?? 13), weight: .regular)
        view.optionAsMetaKey = true
        applyColors()
    }

    func applyColors() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        view.nativeBackgroundColor = dark ? NSColor(white: 0.11, alpha: 1) : NSColor(white: 0.995, alpha: 1)
        view.nativeForegroundColor = dark ? NSColor(white: 0.9, alpha: 1) : NSColor(white: 0.12, alpha: 1)
        view.caretColor = .controlAccentColor
        view.selectedTextBackgroundColor = NSColor.selectedTextBackgroundColor
    }

    /// Connects if needed and brings `windowID` to the front.
    func show(windowID: String, paneID: String? = nil) {
        if !alive {
            connect(initialWindow: windowID)
        } else {
            Task { _ = await Remote.run("tmux select-window -t \(sq(viewSession + ":" + windowID))") }
        }
        if let paneID {
            Task {
                try? await Task.sleep(for: .milliseconds(alive ? 0 : 800))
                _ = await Remote.run("tmux select-pane -t \(sq(paneID))")
            }
        }
    }

    func connect(initialWindow: String?) {
        let select = initialWindow.map { " \\; select-window -t \(sq(":" + $0))" } ?? ""
        // Grouped session: shares windows with `session`, has its own current window.
        // destroy-unattached cleans it up when the app disconnects or quits.
        let script = "exec tmux new-session -t \(sq(session)) -s \(sq(viewSession))"
            + " \\; set destroy-unattached on \\; set status off \\; set mouse on" + select

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        alive = true
        view.startProcess(executable: "/usr/bin/ssh",
                          args: Remote.interactiveArguments(script),
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
