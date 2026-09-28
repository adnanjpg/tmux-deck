import AppKit
import SwiftTerm
import SwiftUI

/// A normal terminal on this Mac, without tmux: a shell (or Claude) running
/// directly in the app, like a Terminal.app tab. It ends when the app quits;
/// the app reopens it in the same folder next time.
@MainActor
final class PlainTerminal: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    enum Kind: String, Codable { case shell, claude }

    let id: String
    let kind: Kind
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
        view.font = NSFont.monospacedSystemFont(ofSize: CGFloat(UserDefaults.standard.double(forKey: "fontSize").nonZero ?? 13), weight: .regular)
        view.optionAsMetaKey = true
        applyTerminalTheme(to: view)
        NotificationCenter.default.addObserver(forName: .themeChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let v = self?.view { applyTerminalTheme(to: v) } }
        }
        start()
    }

    func start() {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        let shell = env["SHELL"] ?? "/bin/zsh"
        // Claude runs inside a login shell, so when you quit Claude you're left at a prompt.
        let args = kind == .claude ? ["-lc", "claude; exec \(shell) -l"] : ["-l"]
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

    /// Follows the shell's current folder, and the title of a Claude conversation running in it.
    private func refreshInfo() async {
        guard running, let pid = view.process?.shellPid, pid > 0 else { return }
        let result = await Remote(host: Remote.localHost).run("""
        lsof -a -d cwd -p \(pid) -Fn 2>/dev/null | sed -n 's/^n//p' | head -1
        c=$(pgrep -P \(pid) -x claude | head -1); [ -z "$c" ] && c=$(pgrep -P \(pid) claude | head -1)
        if [ -n "$c" ] && [ -f ~/.claude/sessions/$c.json ]; then
          sid=$(grep -o '"sessionId":"[^"]*"' ~/.claude/sessions/$c.json | head -1 | cut -d'"' -f4)
          f=$(ls ~/.claude/projects/*/$sid.jsonl 2>/dev/null | head -1)
          [ -n "$f" ] && { grep -a '"type":"custom-title"' "$f" | tail -1; grep -a '"type":"ai-title"' "$f" | tail -1; } | head -1
        fi
        """)
        let lines = result.stdout.split(separator: "\n").map(String.init)
        if let dir = lines.first, dir.hasPrefix("/"), dir != folder { folder = dir; PlainTerminalStore.shared.save() }
        if lines.count > 1, let obj = try? JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any],
           let t = (obj["customTitle"] ?? obj["aiTitle"]) as? String, t != claudeTitle {
            claudeTitle = t
        }
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

/// A plain terminal in a tile.
struct PlainTerminalView: View {
    @ObservedObject var terminal: PlainTerminal

    var body: some View {
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
            Image(systemName: terminal.kind == .claude ? "sparkle" : "terminal")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(terminal.title).lineLimit(1)
                Text((terminal.running ? (terminal.kind == .claude ? "Claude" : "Terminal") : "Ended")
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
