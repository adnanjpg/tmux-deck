import AppKit
import Foundation
import UserNotifications

/// What a window is doing, as far as the sidebar is concerned.
enum WindowState: Equatable {
    case claudeWorking
    case claudeNeedsYou
    case claudeReady
    case shell
    case running(String)

    var label: String {
        switch self {
        case .claudeWorking: "Working…"
        case .claudeNeedsYou: "Needs your answer"
        case .claudeReady: "Ready"
        case .shell: "Terminal"
        case .running(let command): "Running \(command)"
        }
    }

    /// Full-screen programs (vim, htop, cloudflared…) only make sense in a real terminal.
    var isRunningProgram: Bool {
        if case .running = self { return true }
        return false
    }

    var isClaude: Bool {
        switch self {
        case .claudeWorking, .claudeNeedsYou, .claudeReady: true
        default: false
        }
    }
}

struct TmuxWindow: Identifiable, Hashable {
    var session: String
    var windowID: String   // tmux's stable id, e.g. "@7"
    var index: Int
    var name: String
    var command: String
    var panes: Int
    var path: String
    var state: WindowState
    var claude: ClaudeSessionInfo?
    /// The pane this item shows and types into ("%12"). For a window it's the
    /// Claude pane if there is one, otherwise the active pane.
    var paneID: String = ""
    var paneIndex: Int = 0
    /// True for the per-pane rows listed under a window with several panes.
    var isPane = false
    var zoomed = false
    /// One item per pane, only when the window has more than one.
    var paneItems: [TmuxWindow] = []

    var id: String { isPane ? "\(session)|\(windowID)|\(paneID)" : "\(session)|\(windowID)" }
    var windowTarget: String { "\(session):\(windowID)" }

    /// tmux names windows after the running program, so every Claude window is
    /// just "claude". When the name is still automatic, show the project folder.
    var title: String {
        name == command ? folder : name
    }

    var folder: String {
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }

    static func == (a: TmuxWindow, b: TmuxWindow) -> Bool {
        a.id == b.id && a.name == b.name && a.index == b.index && a.command == b.command
            && a.panes == b.panes && a.path == b.path && a.state == b.state && a.claude == b.claude
            && a.paneID == b.paneID && a.zoomed == b.zoomed && a.paneItems == b.paneItems
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// What Claude Code records about a running session in ~/.claude/sessions/<pid>.json.
struct ClaudeSessionInfo: Hashable {
    var sessionID: String
    var name: String?
    var status: String?        // "busy" while working, "idle", "shell" (idle with a background shell)…
    var waitingFor: String?    // set when Claude is waiting on you
}

/// Claude's live status line from its screen, e.g. "Thinking… (1m 3s · ↓ 2.3k tokens)",
/// plus whatever it lists under it (to-dos, running tools).
struct ClaudeActivity: Equatable {
    var glyph: String
    var headline: String
    var details: [String]
}

struct PromptOption: Hashable {
    var key: String
    var label: String
}

struct TmuxSession: Identifiable, Hashable {
    var name: String
    var windows: [TmuxWindow]
    var id: String { name }
}

/// Prefix of the private "view" sessions the app attaches to. Each one is grouped
/// with a real session, so it shares its windows but keeps its own current window
/// and options. That way the app never moves your other tmux clients around.
let viewSessionPrefix = "deck-"

/// Everything the app knows about one server: its tmux sessions, Claude
/// conversations and terminals. `AppModel` holds one of these per server.
@MainActor
final class TmuxModel: ObservableObject, Identifiable {
    let remote: Remote
    var host: String { remote.host }
    nonisolated var id: String { remote.host }
    /// Called after each refresh so the app can update the Dock badge across servers.
    var onRefresh: (() -> Void)?

    init(host: String) {
        self.remote = Remote(host: host)
    }

    @Published var sessions: [TmuxSession] = []
    @Published var selection: TmuxWindow.ID?
    @Published var connected = false
    @Published var lastError: String?
    @Published var toast: String?
    /// Choices Claude is currently offering in each window, e.g. ["1": "Yes", "2": "No"].
    @Published var promptOptions: [String: [PromptOption]] = [:]
    /// Claude's own suggestion for the next message (the dim text in its input line).
    @Published var suggestions: [String: String] = [:]
    /// The lines under Claude's input box (its status line, mode, hints) per item.
    @Published var statusLines: [String: [String]] = [:]
    /// Claude's live status line per item.
    @Published var activities: [String: ClaudeActivity] = [:]
    /// Conversation titles Claude generated, by session id.
    @Published var titles: [String: String] = [:]
    /// Windows the person switched to the raw terminal view.
    @Published var rawTerminal: Set<String> = []
    /// Unsent text in each window's message box.
    var drafts: [String: String] = [:]

    private(set) var needsYouCount = 0
    private var terminals: [String: TerminalController] = [:]
    private var chatStores: [String: ChatStore] = [:]
    private var prefetched = Set<String>()
    private var pollTask: Task<Void, Never>?
    private var lastUserSelection = Date.distantPast
    private var previousStates: [String: WindowState] = [:]

    var selectedWindow: TmuxWindow? {
        guard let selection else { return nil }
        for w in sessions.lazy.flatMap(\.windows) {
            if w.id == selection { return w }
            if let pane = w.paneItems.first(where: { $0.id == selection }) { return pane }
        }
        return nil
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: Refresh

    private static let sep = ":::"

    private static let pollScript: String = {
        let fields = ["session_name", "window_id", "window_index", "window_name",
                      "pane_current_command", "window_panes", "window_active", "pane_current_path",
                      "pane_id", "pane_index", "pane_active", "window_zoomed_flag"]
        let format = fields.map { "#{\($0)}" }.joined(separator: sep)
        return """
        tmux list-panes -a -F \(sq(format)) 2>/dev/null || echo @@NOSERVER
        for f in ~/.claude/sessions/*.json; do
          [ -f "$f" ] || continue
          kill -0 "$(basename "$f" .json)" 2>/dev/null || continue
          printf '@@SES '; tr -d '\\n' < "$f"; echo
        done
        for w in $(tmux list-panes -a -f '#{m:*claude*,#{pane_current_command}}' -F '#{pane_id}' 2>/dev/null | sort -u); do
          printf '@@CAP %s\\n' "$w"
          tmux capture-pane -e -p -t "$w" 2>/dev/null | tail -30
        done
        """
    }()

    func refresh() async {
        let result = await remote.run(Self.pollScript)
        guard result.ok else {
            connected = false
            lastError = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }
        connected = true
        lastError = nil
        apply(result.stdout)
    }

    private func apply(_ output: String) {
        var captures: [String: [String]] = [:]
        var rows: [[String]] = []
        var currentCapture: String?
        var claudeByPane: [String: (info: ClaudeSessionInfo, updated: Double)] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("@@SES ") {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any],
                      let sid = obj["sessionId"] as? String,
                      let tmuxTarget = obj["tmux"] as? String,
                      let pct = tmuxTarget.lastIndex(of: "%") else { continue }
                let paneID = String(tmuxTarget[pct...])
                let updated = obj["updatedAt"] as? Double ?? 0
                if let existing = claudeByPane[paneID], existing.updated > updated { continue }
                claudeByPane[paneID] = (ClaudeSessionInfo(sessionID: sid, name: obj["name"] as? String,
                                                              status: obj["status"] as? String,
                                                              waitingFor: obj["waitingFor"] as? String), updated)
                currentCapture = nil
                continue
            }
            if line.hasPrefix("@@CAP ") {
                currentCapture = String(line.dropFirst(6))
                captures[currentCapture!] = []
            } else if let id = currentCapture {
                captures[id, default: []].append(line)
            } else if line.contains(Self.sep) {
                rows.append(line.components(separatedBy: Self.sep))
            }
        }

        // Group pane rows into windows.
        var order: [String] = []
        var windowOrder: [String: [String]] = [:]          // session -> window ids
        var panesByWindow: [String: [TmuxWindow]] = [:]    // "session|@w" -> pane items
        var viewActive: [String: String] = [:]             // view session -> active window id
        for f in rows where f.count >= 12 {
            let session = f[0]
            if session.hasPrefix(viewSessionPrefix) {
                if f[6] == "1" { viewActive[session] = f[1] }
                continue
            }
            let command = f[4], paneID = f[8]
            let raw = captures[paneID] ?? []
            let claudeInfo = command.contains("claude") ? claudeByPane[paneID]?.info : nil
            let state: WindowState
            if command.contains("claude") {
                let plain = raw.map(stripANSI).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                state = Self.claudeState(Array(plain.suffix(12)), info: claudeInfo)
            } else if ["bash", "zsh", "sh", "fish"].contains(command) {
                state = .shell
            } else {
                state = .running(command)
            }
            var pane = TmuxWindow(session: session, windowID: f[1], index: Int(f[2]) ?? 0,
                                  name: f[3], command: command, panes: Int(f[5]) ?? 1, path: f[7],
                                  state: state, claude: claudeInfo)
            pane.paneID = paneID
            pane.paneIndex = Int(f[9]) ?? 0
            pane.isPane = true
            pane.zoomed = f[11] == "1"
            let key = "\(session)|\(f[1])"
            if windowOrder[session] == nil { order.append(session) }
            if panesByWindow[key] == nil { windowOrder[session, default: []].append(key) }
            panesByWindow[key, default: []].append(pane)
        }
        let activePane = Set(rows.filter { $0.count >= 12 && $0[10] == "1" }.map { $0[8] })

        var bySession: [String: [TmuxWindow]] = [:]
        for session in order {
            for key in windowOrder[session] ?? [] {
                let panes = (panesByWindow[key] ?? []).sorted { $0.paneIndex < $1.paneIndex }
                guard let primary = panes.first(where: { $0.state.isClaude })
                        ?? panes.first(where: { activePane.contains($0.paneID) }) ?? panes.first else { continue }
                var window = primary
                window.isPane = false
                window.paneItems = panes.count > 1 ? panes : []
                bySession[session, default: []].append(window)
            }
        }

        var options: [String: [PromptOption]] = [:]
        var newSuggestions: [String: String] = [:]
        var newActivities: [String: ClaudeActivity] = [:]
        var newStatusLines: [String: [String]] = [:]
        let allItems = bySession.values.joined().flatMap { [$0] + $0.paneItems }
        for w in allItems where w.state.isClaude {
            let raw = captures[w.paneID] ?? []
            if let activity = Self.activity(raw) { newActivities[w.id] = activity }
            if let lines = Self.footer(raw) { newStatusLines[w.id] = lines }
            if w.state == .claudeNeedsYou {
                options[w.id] = Self.promptOptions(raw.suffix(15).map(stripANSI))
            } else if let suggestion = Self.suggestion(raw) {
                newSuggestions[w.id] = suggestion
            }
        }
        if options != promptOptions { promptOptions = options }
        if newSuggestions != suggestions { suggestions = newSuggestions }
        if newActivities != activities { activities = newActivities }
        if newStatusLines != statusLines { statusLines = newStatusLines }
        let claudeIDs = allItems.compactMap(\.claude?.sessionID)
        fetchMissingTitles(claudeIDs)
        prefetchChats(claudeIDs)

        let newSessions = order.map { TmuxSession(name: $0, windows: bySession[$0]!.sorted { $0.index < $1.index }) }
        if newSessions != sessions { sessions = newSessions }

        notifyStateChanges()
        followTmuxSelection(viewActive)

        if selection == nil || selectedWindow == nil {
            selection = sessions.first?.windows.first?.id
        }
    }

    /// Reads the bottom of a Claude Code screen and guesses what it's doing.
    /// A question on screen wins; otherwise trust the status Claude Code records,
    /// falling back to reading the screen.
    static func claudeState(_ lines: [String], info: ClaudeSessionInfo?) -> WindowState {
        let text = lines.joined(separator: "\n")
        if text.contains("Do you want") || text.contains("❯ 1.") || text.contains("(y/n)")
            || info?.waitingFor != nil || info?.status == "waiting" || info?.status == "blocked" {
            return .claudeNeedsYou
        }
        if let status = info?.status {
            return ["busy", "running", "working", "compacting"].contains(status) ? .claudeWorking : .claudeReady
        }
        return text.contains("esc to interrupt") ? .claudeWorking : .claudeReady
    }

    /// The lines below Claude's input box: its status line, mode line and hints.
    static func footer(_ rawLines: [String]) -> [String]? {
        let lines = rawLines.map(stripANSI).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let rules = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("───") }
        guard rules.count >= 2, let bottom = rules.last, bottom + 1 < lines.count else { return nil }
        return Array(lines[(bottom + 1)...].prefix(6))
    }

    private static let spinnerGlyphs: Set<Character> = ["✻", "✽", "✢", "✳", "✶", "✷", "✸", "✹", "✺", "·", "*", "⏺", "●"]

    /// Finds Claude's status line just above its input box, and the lines under it.
    static func activity(_ rawLines: [String]) -> ClaudeActivity? {
        let lines = rawLines.map(stripANSI).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let rules = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("───") }
        guard rules.count >= 2 else { return nil }
        let top = rules[rules.count - 2]
        var i = top - 1
        while i >= 0 && i >= top - 12 {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if let first = t.first, spinnerGlyphs.contains(first), t.contains("…") || t.contains(" for ") {
                var headline = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
                headline = headline.replacingOccurrences(of: #"\s*·\s*esc to interrupt"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: "esc to interrupt", with: "")
                    .replacingOccurrences(of: "()", with: "")
                    .trimmingCharacters(in: .whitespaces)
                let details = lines[(i + 1)..<top]
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .map { $0.hasPrefix("⎿") ? String($0.dropFirst()).trimmingCharacters(in: .whitespaces) : $0 }
                    .filter { !$0.isEmpty }
                return ClaudeActivity(glyph: String(first), headline: headline, details: Array(details.prefix(10)))
            }
            i -= 1
        }
        return nil
    }

    /// Claude shows its suggested next message as dim text after the ❯ prompt.
    static func suggestion(_ rawLines: [String]) -> String? {
        guard let line = rawLines.last(where: { stripANSI($0).trimmingCharacters(in: .whitespaces).hasPrefix("❯") }),
              let prompt = line.range(of: "❯") else { return nil }
        var dim = false, sawDim = false, sawBright = false
        var text = ""
        var i = prompt.upperBound
        while i < line.endIndex {
            if line[i] == "\u{1b}", let end = line[i...].firstIndex(where: { $0.isLetter }) {
                let code = line[line.index(after: i)..<end]
                if line[end] == "m" {
                    let params = code.dropFirst().split(separator: ";").map(String.init)
                    if params.isEmpty || params.contains("0") || params.contains("22") { dim = false }
                    if params.contains("2") { dim = true }
                }
                i = line.index(after: end)
                continue
            }
            let ch = line[i]
            if !ch.isWhitespace { if dim { sawDim = true } else { sawBright = true } }
            text.append(ch)
            i = line.index(after: i)
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\u{a0}")))
        return sawDim && !sawBright && !trimmed.isEmpty ? trimmed : nil
    }

    private var titleFetched: [String: Date] = [:]

    /// Reads the AI-generated title of each conversation, refreshing every minute.
    private func fetchMissingTitles(_ ids: [String]) {
        let due = ids.filter { Date().timeIntervalSince(titleFetched[$0] ?? .distantPast) > 60 }
        guard !due.isEmpty else { return }
        for id in due { titleFetched[id] = Date() }
        let script = due.map { id in
            "f=$(ls ~/.claude/projects/*/\(id).jsonl 2>/dev/null | head -1); [ -n \"$f\" ] && printf '%s\\t' \(id) && grep -a '\"type\":\"ai-title\"' \"$f\" | tail -1"
        }.joined(separator: "; ")
        Task {
            let result = await remote.run(script)
            for line in result.stdout.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 1)
                guard parts.count == 2,
                      let obj = try? JSONSerialization.jsonObject(with: Data(parts[1].utf8)) as? [String: Any],
                      let title = obj["aiTitle"] as? String else { continue }
                titles[String(parts[0])] = title
            }
        }
    }

    /// Pulls numbered choices like "❯ 1. Yes" out of a Claude permission prompt.
    static func promptOptions(_ lines: [String]) -> [PromptOption] {
        let pattern = try! Regex(#"^[\s│|]*(?:❯\s*)?(\d)\.\s+(.+?)[\s│|]*$"#)
        var seen = Set<String>()
        var result: [PromptOption] = []
        for line in lines {
            guard let m = line.firstMatch(of: pattern) else { continue }
            guard let key = m[1].substring.map(String.init),
                  let label = m[2].substring.map(String.init) else { continue }
            if seen.insert(key).inserted {
                result.append(PromptOption(key: key, label: label))
            }
        }
        return result
    }

    private var lastViewActive: [String: String] = [:]

    /// If you switch windows from inside the raw terminal (a tmux shortcut or
    /// `tmux select-window`), move the sidebar selection to match. Only reacts
    /// when tmux's window actually changed, and only while the raw terminal is
    /// on screen, so the chat view never gets pulled to another window.
    private func followTmuxSelection(_ viewActive: [String: String]) {
        defer { lastViewActive = viewActive }
        guard Date().timeIntervalSince(lastUserSelection) > 3, let current = selectedWindow,
              rawTerminal.contains(current.id) || current.state.isRunningProgram,
              let controller = terminals[current.session], controller.alive,
              let active = viewActive[controller.viewSession],
              let previous = lastViewActive[controller.viewSession],
              active != previous, active != current.windowID else { return }
        selection = "\(current.session)|\(active)"
    }

    private func notifyStateChanges() {
        let windows = sessions.flatMap(\.windows)
        needsYouCount = windows.filter { $0.state == .claudeNeedsYou }.count
        onRefresh?()

        let appActive = NSApp.isActive
        var finished = false, asking = false
        for w in windows {
            let before = previousStates[w.id]
            previousStates[w.id] = w.state
            guard let before, before != w.state else { continue }
            let isFinish = before == .claudeWorking && w.state == .claudeReady
            let isQuestion = w.state == .claudeNeedsYou
            finished = finished || isFinish
            asking = asking || isQuestion
            // Banners only for chats you aren't looking at; the sound plays either way.
            if appActive && w.id == selection { continue }
            if isFinish {
                notify("Claude finished", "\(w.session) › \(displayTitle(w)) is ready for you.")
            } else if isQuestion {
                notify("Claude needs your answer", "\(w.session) › \(displayTitle(w)) is waiting for you.")
            }
        }
        if asking { Sounds.play(.question) } else if finished { Sounds.play(.finish) }
    }

    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = host
        content.body = body
        content.sound = nil   // Sounds.play handles sound, so it isn't doubled
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Claude's conversation title if it has one, then a name you gave the window, then the folder.
    func displayTitle(_ w: TmuxWindow) -> String {
        let base = baseTitle(w)
        guard !w.isPane, let siblings = sessions.first(where: { $0.name == w.session })?.windows,
              siblings.filter({ !$0.isPane && baseTitle($0) == base }).count > 1 else { return base }
        return "\(base) (\(w.index))"
    }

    private func baseTitle(_ w: TmuxWindow) -> String {
        if let id = w.claude?.sessionID, let title = titles[id], w.isPane || w.name == w.command { return title }
        if w.isPane { return w.state.isClaude ? "Claude · \(w.folder)" : "\(w.command) · \(w.folder)" }
        return w.title
    }

    private var repoByPath: [String: String?] = [:]

    /// The GitHub "owner/name" of the git repository at `path` on this server, if any.
    func repository(for path: String) async -> String? {
        if let cached = repoByPath[path] { return cached }
        let result = await remote.run("git -C \(sq(path)) remote get-url origin 2>/dev/null")
        let url = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // git@github.com:owner/repo.git, git@alias.github.com:owner/repo, https://github.com/owner/repo.git
        var repo: String?
        if url.contains("github"), let m = url.firstMatch(of: try! Regex(#"[:/]([\w.-]+)/([\w.-]+?)(?:\.git)?/?$"#)),
           let o = m[1].substring, let r = m[2].substring {
            repo = "\(o)/\(r)"
        }
        repoByPath[path] = repo
        return repo
    }

    /// Stops polling and closes this server's terminals, e.g. when the server is removed.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        for t in terminals.values { t.stop() }
        terminals = [:]
    }

    /// One store per conversation, kept for the life of the app so switching is instant.
    func chatStore(for sessionID: String) -> ChatStore {
        if let store = chatStores[sessionID] { return store }
        let store = ChatStore(sessionID: sessionID, remote: remote)
        chatStores[sessionID] = store
        return store
    }

    /// Quietly loads every conversation in the background, one at a time,
    /// so even chats you haven't opened yet appear immediately.
    private func prefetchChats(_ ids: [String]) {
        let pending = ids.filter { !prefetched.contains($0) }
        guard !pending.isEmpty else { return }
        prefetched.formUnion(pending)
        Task(priority: .background) {
            for id in pending { await chatStore(for: id).poll() }
        }
    }

    // MARK: Window and pane actions

    private func windowAction(_ script: String, select: ((String) -> String?)? = nil) {
        Task {
            let result = await tmux(script)
            let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.ok, let select, let id = select(out) { userSelected(id) }
        }
    }

    func moveWindow(_ w: TmuxWindow, by delta: Int) {
        guard let list = sessions.first(where: { $0.name == w.session })?.windows,
              let i = list.firstIndex(where: { $0.windowID == w.windowID }),
              list.indices.contains(i + delta) else { return }
        windowAction("tmux swap-window -d -s \(sq(w.windowTarget)) -t \(sq(list[i + delta].windowTarget))")
    }

    func moveWindow(_ w: TmuxWindow, toSession session: String) {
        guard session != w.session else { return }
        windowAction("tmux move-window -s \(sq(w.windowTarget)) -t \(sq(session + ":"))") { _ in "\(session)|\(w.windowID)" }
    }

    func moveWindowToNewSession(_ w: TmuxWindow, name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        // A new session always starts with a window, so create it, move ours in, drop the spare.
        windowAction("""
        spare=$(tmux new-session -d -P -F '#{window_id}' -s \(sq(name))) && tmux move-window -s \(sq(w.windowTarget)) -t \(sq(name + ":")) && tmux kill-window -t "$spare"
        """) { _ in "\(name)|\(w.windowID)" }
    }

    func evenLayout(_ w: TmuxWindow) {
        windowAction("tmux select-layout -t \(sq(w.windowTarget)) tiled")
    }

    func breakPane(_ p: TmuxWindow) {
        windowAction("tmux break-pane -d -P -F '#{window_id}' -s \(sq(p.paneID))") { id in
            id.hasPrefix("@") ? "\(p.session)|\(id)" : nil
        }
    }

    func breakPane(_ p: TmuxWindow, toSession session: String) {
        windowAction("tmux break-pane -d -P -F '#{window_id}' -s \(sq(p.paneID)) -t \(sq(session + ":"))") { id in
            id.hasPrefix("@") ? "\(session)|\(id)" : nil
        }
    }

    func joinPane(_ p: TmuxWindow, into w: TmuxWindow, sideBySide: Bool = true) {
        guard p.windowID != w.windowID || p.session != w.session else { return }
        windowAction("tmux join-pane -d \(sideBySide ? "-h" : "-v") -s \(sq(p.paneID)) -t \(sq(w.windowTarget))") { _ in
            "\(w.session)|\(w.windowID)|\(p.paneID)"
        }
    }

    func swapPane(_ p: TmuxWindow, previous: Bool) {
        windowAction("tmux swap-pane -d -t \(sq(p.paneID)) \(previous ? "-U" : "-D")")
    }

    func toggleZoom(_ p: TmuxWindow) {
        windowAction("tmux resize-pane -Z -t \(sq(p.paneID))")
    }

    func killPane(_ p: TmuxWindow) {
        if selection == p.id { userSelected("\(p.session)|\(p.windowID)") }
        windowAction("tmux kill-pane -t \(sq(p.paneID))")
    }

    /// Drag and drop in the sidebar. `ids` are dragged item ids.
    func handleDrop(_ ids: [String], onto w: TmuxWindow?, session: String) -> Bool {
        guard let id = ids.first else { return false }
        let all = sessions.flatMap(\.windows).flatMap { [$0] + $0.paneItems }
        guard let dragged = all.first(where: { $0.id == id }) else { return false }
        if dragged.isPane {
            if let w { joinPane(dragged, into: w) } else { breakPane(dragged, toSession: session) }
        } else if let w, w.session == dragged.session {
            guard w.windowID != dragged.windowID else { return false }
            windowAction("tmux swap-window -d -s \(sq(dragged.windowTarget)) -t \(sq(w.windowTarget))")
        } else {
            moveWindow(dragged, toSession: session)
        }
        return true
    }

    func window(containing pane: TmuxWindow) -> TmuxWindow? {
        sessions.lazy.flatMap(\.windows).first { $0.session == pane.session && $0.windowID == pane.windowID }
    }

    func toggleRawTerminal() {
        guard let w = selectedWindow else { return }
        if rawTerminal.contains(w.id) { rawTerminal.remove(w.id) } else { rawTerminal.insert(w.id) }
    }

    // MARK: Terminals

    func controller(for session: String) -> TerminalController {
        if let existing = terminals[session] { return existing }
        let controller = TerminalController(session: session, remote: remote)
        terminals[session] = controller
        return controller
    }

    func userSelected(_ id: TmuxWindow.ID?) {
        lastUserSelection = Date()
        selection = id   // TerminalPane reacts and tells tmux to switch.
    }

    // MARK: Actions

    private func tmux(_ script: String) async -> Remote.Result {
        let result = await remote.run(script)
        if !result.ok {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            flash(message.isEmpty ? "That didn't work." : message)
        }
        await refresh()
        return result
    }

    /// Targets the window through this app's view session so splits and
    /// new windows land where you're looking.
    private func target(_ w: TmuxWindow) -> String {
        if !w.paneID.isEmpty { return w.paneID }
        let view = terminals[w.session]?.viewSession ?? w.session
        return "\(view):\(w.windowID)"
    }

    func newWindow(claude: Bool, in session: String? = nil) {
        guard let sessionName = session ?? selectedWindow?.session ?? sessions.first?.name else {
            newSession(named: "main"); return
        }
        // Target the view session so the new window opens in the folder you're looking at.
        let targetSession = terminals[sessionName]?.viewSession ?? sessionName
        let launch = claude ? "tmux send-keys -t \"$id\" claude Enter" : ":"
        let script = """
        id=$(tmux new-window -d -P -F '#{window_id}' -c '#{pane_current_path}' -t \(sq(targetSession + ":"))) && \(launch) && echo "$id"
        """
        Task {
            let result = await tmux(script)
            let id = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.ok, id.hasPrefix("@") { userSelected("\(sessionName)|\(id)") }
        }
    }

    func split(vertical: Bool) {
        guard let w = selectedWindow else { return }
        Task { _ = await tmux("tmux split-window \(vertical ? "-v" : "-h") -c '#{pane_current_path}' -t \(sq(target(w)))") }
    }

    func rename(_ w: TmuxWindow, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        Task { _ = await tmux("tmux rename-window -t \(sq(w.windowTarget)) \(sq(name))") }
    }

    func close(_ w: TmuxWindow) {
        if selection == w.id {
            let all = sessions.flatMap(\.windows)
            if let i = all.firstIndex(of: w) {
                let next = all.indices.contains(i + 1) ? all[i + 1] : (i > 0 ? all[i - 1] : nil)
                if let next { userSelected(next.id) }
            }
        }
        Task { _ = await tmux("tmux kill-window -t \(sq(w.windowTarget))") }
    }

    func newSession(named name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        Task {
            let result = await tmux("tmux new-session -d -s \(sq(name)) -P -F '#{window_id}'")
            let id = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.ok, id.hasPrefix("@") { userSelected("\(name)|\(id)") }
        }
    }

    func renameSession(_ session: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != session else { return }
        Task {
            let result = await tmux("tmux rename-session -t \(sq(session)) \(sq(name))")
            if result.ok, let controller = terminals.removeValue(forKey: session) {
                controller.session = name
                terminals[name] = controller
                if let sel = selection, sel.hasPrefix(session + "|") {
                    selection = name + sel.dropFirst(session.count)
                }
            }
        }
    }

    func killSession(_ session: String) {
        terminals.removeValue(forKey: session)?.stop()
        Task { _ = await tmux("tmux kill-session -t \(sq(session))") }
    }

    func copyOutput() {
        guard let w = selectedWindow else { return }
        Task {
            let result = await remote.run("tmux capture-pane -p -J -S -5000 -t \(sq(target(w)))")
            guard result.ok else { flash("Couldn't read that window."); return }
            let text = result.stdout.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
            flash("Copied \(lines.formatted()) lines")
        }
    }

    /// Types `text` into the window and presses Enter. Uses a bracketed paste so
    /// multi-line messages arrive as one message instead of one per line.
    func send(text: String, images: [String] = [], to w: TmuxWindow) {
        if let id = w.claude?.sessionID { chatStore(for: id).addSending(text, images: images.count) }
        let t = sq(target(w))
        // Each image path is pasted on its own, like dragging an image into Claude's terminal.
        let imagePaste = images.map { path in
            "tmux set-buffer -b deck-img -- \(sq(path)) && tmux paste-buffer -p -d -b deck-img -t \(t) && sleep 0.5 && "
        }.joined()
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Task {
                let result = await remote.run(imagePaste + "tmux send-keys -t \(t) Enter")
                if !result.ok { flash("Couldn't send that. Check the connection.") }
                await refresh()
            }
            return
        }
        let script: String
        if w.state.isClaude {
            // Claude Code can swallow an Enter that arrives while it's still taking in a
            // paste, and for /commands the first Enter only picks the autocomplete entry.
            // So: wait until the text shows in Claude's input line, press Enter, and keep
            // pressing (up to 3 times) until the input line no longer holds it.
            // Claude's prompt is "❯" plus a no-break space, normalised here with sed.
            script = """
            \(imagePaste)f=$(mktemp) && cat > "$f" && tmux load-buffer -b deck-compose "$f" && tmux paste-buffer -p -d -b deck-compose -t \(t) || exit 1
            first=$(head -n1 "$f" | sed 's/^[[:space:]]*//' | cut -c1-20)
            inbox() { tmux capture-pane -p -t \(t) | sed 's/\\xc2\\xa0/ /g' | grep '^❯' | tail -1 | cut -c4-; }
            waiting() { l=$(inbox); case "$l" in *"$first"*|*"[Pasted text"*) return 0;; *) return 1;; esac; }
            for i in 1 2 3 4 5 6 7 8 9 10; do waiting && break; sleep 0.2; done
            sleep 0.25
            for i in 1 2 3; do tmux send-keys -t \(t) Enter; sleep 0.9; waiting || break; done
            rm -f "$f"
            """
        } else {
            script = """
            \(imagePaste)f=$(mktemp) && cat > "$f" && tmux load-buffer -b deck-compose "$f" && tmux paste-buffer -p -d -b deck-compose -t \(t) \
              && sleep 0.2 && tmux send-keys -t \(t) Enter
            rm -f "$f"
            """
        }
        Task {
            let result = await remote.run(script, input: text)
            if !result.ok { flash("Couldn't send that. Check the connection.") }
            await refresh()
        }
    }

    /// Presses Shift+Tab until Claude's mode line shows `mode` (up to 7 presses).
    func setMode(_ mode: ClaudeMode, in w: TmuxWindow) {
        let t = sq(target(w))
        let markers = ClaudeMode.allCases.compactMap(\.marker)
        let check: String
        if let m = mode.marker {
            check = "grep -qi \(sq(m))"
        } else {
            check = "! grep -qiE \(sq(markers.joined(separator: "|")))"
        }
        let script = """
        footer() { tmux capture-pane -p -t \(t) | sed 's/\\xc2\\xa0/ /g' | tail -6; }
        for i in 1 2 3 4 5 6 7; do footer | \(check) && exit 0; tmux send-keys -t \(t) BTab; sleep 0.5; done
        exit 3
        """
        Task {
            let result = await remote.run(script)
            if result.status == 3 { flash("\(mode.title) isn't available in this session.") }
            await refresh()
        }
    }

    /// Runs a Claude slash command that opens a screen (like /usage), reads it, and closes it.
    func captureClaudeScreen(command: String, in w: TmuxWindow) async -> String {
        let t = sq(target(w))
        let script = """
        tmux send-keys -t \(t) -l \(sq(command)) && sleep 0.3 && tmux send-keys -t \(t) Enter && sleep 2.2 \
          && tmux capture-pane -p -t \(t) ; tmux send-keys -t \(t) Escape
        """
        let result = await remote.run(script, timeout: 20)
        let lines = stripANSI(result.stdout).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Keep the part above Claude's input box, trimmed of blank edges.
        let rules = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("───") }
        let body = rules.count >= 2 ? Array(lines[..<rules[rules.count - 2]]) : lines
        return body.suffix(40).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sends tmux key names (Enter, Escape, Up, BTab, C-c…) or, with `literal`, plain characters.
    func send(keys: [String], to w: TmuxWindow, literal: Bool = false) {
        let script = "tmux send-keys -t \(sq(target(w))) \(literal ? "-l " : "")" + keys.map(sq).joined(separator: " ")
        Task {
            _ = await remote.run(script)
            try? await Task.sleep(for: .milliseconds(300))
            await refresh()
        }
    }

    func selectRelative(_ delta: Int) {
        let all = sessions.flatMap(\.windows)
        guard !all.isEmpty else { return }
        let i = all.firstIndex { $0.id == selection } ?? 0
        userSelected(all[(i + delta + all.count) % all.count].id)
    }

    func selectNumber(_ n: Int) {
        let all = sessions.flatMap(\.windows)
        if all.indices.contains(n - 1) { userSelected(all[n - 1].id) }
    }

    func flash(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if toast == message { toast = nil }
        }
    }
}

/// Removes terminal color and style codes, and hidden link markers (OSC 8).
func stripANSI(_ s: String) -> String {
    s.replacingOccurrences(of: "\u{1b}\\][^\u{07}\u{1b}]*(?:\u{07}|\u{1b}\\\\)", with: "", options: .regularExpression)
        .replacingOccurrences(of: "\u{1b}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
}

/// The sounds played when Claude finishes or asks you something. Set in Settings.
enum Sounds {
    enum Event: String { case finish, question }

    static let available = ["Glass", "Ping", "Hero", "Submarine", "Blow", "Bottle", "Frog", "Funk",
                            "Morse", "Pop", "Purr", "Sosumi", "Tink", "Basso"]

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            "sound.finish.on": true, "sound.finish.name": "Glass",
            "sound.question.on": true, "sound.question.name": "Ping",
        ])
    }

    static func play(_ event: Event) {
        let d = UserDefaults.standard
        guard d.bool(forKey: "sound.\(event.rawValue).on"),
              let name = d.string(forKey: "sound.\(event.rawValue).name") else { return }
        preview(name)
    }

    static func preview(_ name: String) {
        NSSound(named: NSSound.Name(name))?.play()
    }
}
