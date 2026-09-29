import AppKit
import SwiftTerm
import SwiftUI

/// A normal terminal on this Mac, without tmux: a shell, Claude, or Codex running
/// directly in the app, like a Terminal.app tab. It ends when the app quits;
/// the app reopens it in the same folder next time.
@MainActor
final class PlainTerminal: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    enum Kind: String, Codable {
        case shell
        case claude
        case codex

        var assistant: CodingAssistant? {
            switch self {
            case .shell: nil
            case .claude: .claude
            case .codex: .codex
            }
        }

        var displayName: String { assistant?.displayName ?? "Terminal" }
        var systemImage: String { assistant?.systemImage ?? "terminal" }
    }

    let id: String
    let kind: Kind
    /// The conversation running in here, when there is one.
    @Published private(set) var claudeSessionID: String?
    @Published private(set) var codex: CodexSessionInfo?
    @Published private(set) var state: WindowState = .shell
    private var claudeStatus: String?
    private var claudeWaiting: String?

    var assistant: CodingAssistant? { kind.assistant }

    /// The chat store for whatever is running here, if its transcript has been found.
    var store: ChatStore? {
        if let id = claudeSessionID {
            return PastStores.shared.store(host: Remote.localHost, assistant: .claude,
                                           sessionID: id, path: "")
        }
        if let codex {
            return PastStores.shared.store(host: Remote.localHost, assistant: .codex,
                                           sessionID: codex.sessionID, path: codex.path)
        }
        return nil
    }
    @Published var name: String?          // set by you (Rename)
    @Published private(set) var folder: String
    @Published private(set) var claudeTitle: String?
    @Published private(set) var running = false
    let view: LocalProcessTerminalView
    private var pollTask: Task<Void, Never>?

    var tag: String { "plain#\(id)" }
    var title: String {
        if let name, !name.isEmpty { return name }
        if kind == .claude { return claudeTitle ?? "Claude · \((folder as NSString).lastPathComponent)" }
        if kind == .codex { return "Codex · \((folder as NSString).lastPathComponent)" }
        return (folder as NSString).lastPathComponent.isEmpty ? "Terminal" : (folder as NSString).lastPathComponent
    }

    init(id: String = UUID().uuidString, kind: Kind, folder: String, name: String? = nil) {
        self.id = id
        self.kind = kind
        self.folder = folder
        self.name = name
        self.view = ClickableTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        super.init()
        view.processDelegate = self
        view.font = Zoom.shared.font.terminal
        view.optionAsMetaKey = true
        applyTerminalTheme(to: view)
        NotificationCenter.default.addObserver(forName: .fontSizeChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.view.font = Zoom.shared.font.terminal }
        }
        NotificationCenter.default.addObserver(forName: .themeChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let v = self?.view { applyTerminalTheme(to: v) } }
        }
        start()
    }

    func start() {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        // Some TUIs pick a light or dark palette from COLORFGBG rather than probing with
        // OSC 11; tell them which one this terminal is using.
        env["COLORFGBG"] = Zoom.terminalIsDark ? "15;0" : "0;15"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        let shell = env["SHELL"] ?? "/bin/zsh"
        // Coding CLIs run inside a login shell, so quitting one leaves a prompt behind.
        let args = kind.assistant.map { ["-lc", "\($0.command); exec \(shell) -l"] } ?? ["-l"]
        running = true
        view.startProcess(executable: shell, args: args, environment: env.map { "\($0.key)=\($0.value)" },
                          execName: nil, currentDirectory: FileManager.default.fileExists(atPath: folder) ? folder : NSHomeDirectory())
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshInfo()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        if running { view.terminate() }
        running = false
    }

    /// Types a message and submits it. Bracketed paste keeps a multi-line message as one
    /// message, the same as the tmux side; the Enter follows once the app has taken it in.
    func type(_ message: String) {
        guard running else { return }
        view.send(txt: "\u{1b}[200~" + message + "\u{1b}[201~")
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            view.send(txt: "\r")
        }
    }

    /// tmux-style key names, so the compose box can forward the same set it does for tmux panes.
    func send(key: String) {
        guard running else { return }
        let codes = ["Enter": "\r", "Escape": "\u{1b}", "Up": "\u{1b}[A", "Down": "\u{1b}[B",
                     "Tab": "\t", "BTab": "\u{1b}[Z", "BSpace": "\u{7f}",
                     "PPage": "\u{1b}[5~", "NPage": "\u{1b}[6~", "C-c": "\u{3}"]
        view.send(txt: codes[key] ?? key)
    }

    /// Follows the shell's folder, and the conversation an assistant is running in it.
    ///
    /// A local Claude or Codex writes the same session files as a remote one, so a plain
    /// terminal can have the same chat view; it just has to find them itself, since there's no
    /// tmux pane id to match on. Claude names its pid in ~/.claude/sessions; Codex is matched by
    /// folder and recency, exactly as the tmux side does.
    private func refreshInfo() async {
        guard running, let pid = view.process?.shellPid, pid > 0 else { return }
        let result = await Remote(host: Remote.localHost).run("""
        lsof -a -d cwd -p \(pid) -Fn 2>/dev/null | sed -n 's/^n//p' | head -1
        c=$(pgrep -P \(pid) -x claude | head -1); [ -z "$c" ] && c=$(pgrep -P \(pid) claude | head -1)
        if [ -n "$c" ] && [ -f ~/.claude/sessions/$c.json ]; then
          printf '@@CLAUDE '; tr -d '\\n' < ~/.claude/sessions/$c.json; echo
          sid=$(grep -o '"sessionId":"[^"]*"' ~/.claude/sessions/$c.json | head -1 | cut -d'"' -f4)
          f=$(ls ~/.claude/projects/*/$sid.jsonl 2>/dev/null | head -1)
          [ -n "$f" ] && { grep -a '"type":"custom-title"' "$f" | tail -1; grep -a '"type":"ai-title"' "$f" | tail -1; } | head -1
        fi
        """)
        var lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let dir = lines.first, dir.hasPrefix("/"), dir != folder { folder = dir; PlainTerminalStore.shared.save() }
        lines = Array(lines.dropFirst())
        var foundClaude: String?
        for line in lines where line.hasPrefix("@@CLAUDE ") {
            if let obj = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(9).utf8)) as? [String: Any] {
                foundClaude = obj["sessionId"] as? String
                claudeStatus = obj["status"] as? String
                claudeWaiting = obj["waitingFor"] as? String
            }
        }
        if foundClaude != claudeSessionID { claudeSessionID = foundClaude }
        for line in lines where line.contains("\"type\":\"custom-title\"") || line.contains("\"type\":\"ai-title\"") {
            if let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               let t = (obj["customTitle"] ?? obj["aiTitle"]) as? String, t != claudeTitle {
                claudeTitle = t
            }
        }
        if kind == .codex { await refreshCodex(pid: pid) }
        refreshState()
    }

    private func refreshCodex(pid: Int32) async {
        let result = await Remote(host: Remote.localHost).run(
            "printf '%%s %%s %%s\\n' plain \(pid) \(sq(folder)) | python3 -",
            input: TmuxModel.codexFinderScript)
        for line in result.stdout.split(separator: "\n") where line.hasPrefix("@@CODEX ") {
            let f = line.dropFirst(8).split(separator: " ", maxSplits: 2).map(String.init)
            guard f.count == 3 else { continue }
            let tab = f[2].split(separator: "\t", maxSplits: 1).map(String.init)
            let info = CodexSessionInfo(sessionID: f[1], path: tab[0], title: tab.count > 1 ? tab[1] : nil)
            if info != codex { codex = info }
        }
    }

    /// What the assistant in this terminal is doing, read from its screen the same way the tmux
    /// side reads a pane. Without this a local Claude finishing is completely silent.
    private func refreshState() {
        guard let assistant else { state = .shell; return }
        let screen = view.visibleScreenText()
        let lines = screen.split(separator: "\n").map(String.init)
        let next: WindowState = assistant == .codex
            ? TmuxModel.codexState(lines)
            : TmuxModel.claudeState(Array(lines.suffix(12)),
                                    info: claudeSessionID.map {
                                        ClaudeSessionInfo(sessionID: $0, name: nil,
                                                          status: claudeStatus, waitingFor: claudeWaiting)
                                    })
        guard next != state else { return }
        let before = state
        state = next
        PlainTerminalStore.shared.stateChanged(self, from: before)
    }

    // MARK: LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, let url = URL(string: directory), url.isFileURL else { return }
        Task { @MainActor in self.folder = url.path }
    }
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in self.running = false }
    }
}

/// Your plain terminals on this Mac, remembered across launches (reopened in their folders).
@MainActor
final class PlainTerminalStore: ObservableObject {
    static let shared = PlainTerminalStore()

    @Published private(set) var terminals: [PlainTerminal] = []
    /// Tells you when a local assistant finishes or needs you, the same way the tmux side does.
    func stateChanged(_ terminal: PlainTerminal, from before: WindowState) {
        guard terminal.assistant != nil else { return }
        let tag = terminal.tag
        let onScreen = NSApp.isActive && LayoutModel.shared.root.leaves.contains { $0.tag == tag }
        let finished = before == .claudeWorking && terminal.state == .claudeReady
        let asking = terminal.state == .claudeNeedsYou
        guard finished || asking else { return }
        if asking { Sounds.play(.question) } else { Sounds.play(.finish) }
        guard !onScreen else { return }
        let name = terminal.assistant?.displayName ?? "Claude"
        Notifications.post(asking ? .question : .finish,
                           title: asking ? "\(name) needs your answer" : "\(name) finished",
                           subtitle: "This Mac", body: terminal.title, tag: tag)
    }

    /// Plain terminals you've switched to the raw terminal view.
    @Published private(set) var rawTerminals: Set<String> = []

    func toggleRaw(_ terminal: PlainTerminal) {
        if rawTerminals.contains(terminal.id) {
            rawTerminals.remove(terminal.id)
        } else {
            rawTerminals.insert(terminal.id)
        }
    }

    /// Whether the "This Mac · terminals" section is shown.
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "plain.enabled") }
    }

    private struct Saved: Codable {
        var id: String
        var kind: PlainTerminal.Kind
        var folder: String
        var name: String?
    }

    private init() {
        enabled = UserDefaults.standard.bool(forKey: "plain.enabled")
        if let data = UserDefaults.standard.data(forKey: "plain.terminals"),
           let saved = try? JSONDecoder().decode([Saved].self, from: data) {
            terminals = saved.map { PlainTerminal(id: $0.id, kind: $0.kind, folder: $0.folder, name: $0.name) }
        }
    }

    func save() {
        let saved = terminals.map { Saved(id: $0.id, kind: $0.kind, folder: $0.folder, name: $0.name) }
        if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: "plain.terminals") }
    }

    @discardableResult
    func new(_ kind: PlainTerminal.Kind, in folder: String? = nil) -> PlainTerminal {
        enabled = true
        let t = PlainTerminal(kind: kind, folder: folder ?? terminals.last?.folder ?? NSHomeDirectory())
        terminals.append(t)
        save()
        return t
    }

    func close(_ t: PlainTerminal) {
        t.stop()
        terminals.removeAll { $0.id == t.id }
        save()
    }

    func rename(_ t: PlainTerminal, to name: String) {
        t.name = name.trimmingCharacters(in: .whitespaces)
        save()
    }

    func terminal(forTag tag: String) -> PlainTerminal? {
        guard tag.hasPrefix("plain#") else { return nil }
        let id = String(tag.dropFirst(6))
        return terminals.first { $0.id == id }
    }

    func stopAll() { for t in terminals { t.stop() } }
}

/// A plain terminal in a tile: the chat when an assistant is running in it, the raw terminal
/// otherwise (or when you ask for it).
struct PlainTerminalView: View {
    @ObservedObject var terminal: PlainTerminal
    @ObservedObject private var store = PlainTerminalStore.shared

    var body: some View {
        if terminal.assistant != nil, let chat = terminal.store,
           !store.rawTerminals.contains(terminal.id) {
            PlainChatView(terminal: terminal, store: chat)
        } else {
            rawTerminal
        }
    }

    private var rawTerminal: some View {
        PlainTerminalHost(view: terminal.view)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: terminal.view.nativeBackgroundColor))
            .overlay {
                if !terminal.running {
                    ContentUnavailableView {
                        Label("Process ended", systemImage: "terminal")
                    } actions: {
                        Button("Start again") { terminal.start() }.keyboardShortcut(.defaultAction)
                        Button("Close") { PlainTerminalStore.shared.close(terminal) }
                    }
                    .background(.regularMaterial)
                }
            }
            .onAppear {
                DispatchQueue.main.async { terminal.view.window?.makeFirstResponder(terminal.view) }
            }
    }
}

/// A local Claude or Codex as a chat, reading the transcript it writes on this Mac.
struct PlainChatView: View {
    @Environment(\.theme) private var theme
    @Environment(\.fonts) private var fonts
    @ObservedObject var terminal: PlainTerminal
    @ObservedObject var store: ChatStore

    var body: some View {
        VStack(spacing: 0) {
            ChatView(window: nil, store: store)
            Divider()
            PlainComposeBar(terminal: terminal)
        }
        .background(theme.bg)
        .task(id: store.sessionID) {
            while !Task.isCancelled {
                await store.poll()
                try? await Task.sleep(for: .seconds(terminal.state == .claudeWorking ? 1 : 2))
            }
        }
    }
}

/// The message box for a plain terminal. It writes straight into the process — there's no tmux
/// in the way, so none of the paste-and-wait-for-Enter machinery is needed.
struct PlainComposeBar: View {
    @Environment(\.theme) private var theme
    @Environment(\.fonts) private var fonts
    @ObservedObject var terminal: PlainTerminal
    @State private var text = ""
    @State private var height: CGFloat = 22
    @State private var focusToken = 0

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Message \(terminal.assistant?.displayName ?? "the terminal") — Enter to send, Shift+Enter for a new line")
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                ComposeTextView(text: $text, height: $height, focusToken: focusToken,
                                suggestion: nil,
                                onSubmit: submit,
                                onForward: { keys in for k in keys { terminal.send(key: k) } },
                                onAcceptSuggestion: {},
                                onImages: { _ in })
                    .frame(height: min(max(height, 22), 160))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(theme.input))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.line))

            Button { terminal.send(key: "Escape") } label: { Image(systemName: "stop.fill") }
                .help("Stop (Esc)")
                .controlSize(.large)
                .disabled(terminal.state != .claudeWorking)
            Button(action: submit) { Image(systemName: "arrow.up").fontWeight(.semibold) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send (Enter)")
        }
        .font(fonts.body)
        .padding(12)
        .background(theme.panel)
        .onAppear { focusToken += 1 }
    }

    private func submit() {
        let message = text.trimmingCharacters(in: .newlines)
        guard !message.trimmingCharacters(in: .whitespaces).isEmpty else {
            terminal.send(key: "Enter")
            return
        }
        terminal.store?.addSending(message)
        terminal.type(message)
        text = ""
    }
}

private struct PlainTerminalHost: NSViewRepresentable {
    let view: LocalProcessTerminalView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if view.superview !== container { attach(to: container) }
    }

    private func attach(to container: NSView) {
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

/// A plain terminal's row in the sidebar.
struct PlainTerminalRow: View {
    @ObservedObject var terminal: PlainTerminal

    var body: some View {
        HStack(spacing: 8) {
            Group {
                switch terminal.running ? terminal.state : .shell {
                case .claudeWorking:
                    Image(systemName: terminal.kind.systemImage).foregroundStyle(.blue).symbolEffect(.pulse)
                case .claudeNeedsYou:
                    Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.orange)
                default:
                    Image(systemName: terminal.kind.systemImage).foregroundStyle(.secondary)
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(terminal.title).lineLimit(1)
                Text((terminal.running
                      ? (terminal.assistant != nil ? terminal.state.label : terminal.kind.displayName)
                      : "Ended")
                     + " · " + (terminal.folder as NSString).abbreviatingWithTildeInPath)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A terminal view that responds to its very first click even when the app's
/// window isn't key yet — otherwise that click only activates the window and
/// the terminal itself ignores it, which looks exactly like the UI "not working".
final class ClickableTerminalView: LocalProcessTerminalView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Same first-click fix for read-only text (the console view for plain shells).
final class ClickThroughTextView: NSTextView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension TerminalView {
    /// The screen's current text (no scrollback), last non-blank lines first —
    /// used for the ⌃⇥ switcher's live preview. Reads straight from the live
    /// buffer, so it works even for a terminal that isn't on screen right now.
    func visibleScreenText(maxLines: Int = 10) -> String {
        guard let t = terminal else { return "" }
        var lines: [String] = []
        for r in 0..<t.rows {
            guard let line = t.getLine(row: r) else { continue }
            let text = line.translateToString(trimRight: true)
            if !text.isEmpty { lines.append(text) }
        }
        return lines.suffix(maxLines).joined(separator: "\n")
    }
}

/// Theme colors for any terminal view (tmux or plain).
@MainActor
func applyTerminalTheme(to view: LocalProcessTerminalView) {
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

extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
