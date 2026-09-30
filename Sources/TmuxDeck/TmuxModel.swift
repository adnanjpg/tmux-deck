import AppKit
import Foundation
import UserNotifications

/// Coding CLIs that Tmux Deck can start in a tmux or plain-terminal window.
/// Claude has an additional native chat renderer; Codex stays in its own TUI.
enum CodingAssistant: String, CaseIterable {
    case claude
    case codex

    init?(command: String) {
        self.init(rawValue: command.lowercased())
    }

    var command: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    var systemImage: String {
        switch self {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        }
    }
}

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
    var codex: CodexSessionInfo?
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

    var assistant: CodingAssistant? {
        if claude != nil { return .claude }
        if codex != nil { return .codex }
        return CodingAssistant(command: command)
    }

    static func == (a: TmuxWindow, b: TmuxWindow) -> Bool {
        a.id == b.id && a.name == b.name && a.index == b.index && a.command == b.command
            && a.panes == b.panes && a.path == b.path && a.state == b.state && a.claude == b.claude
            && a.codex == b.codex
            && a.paneID == b.paneID && a.zoomed == b.zoomed && a.paneItems == b.paneItems
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// What Claude Code records about a running session in ~/.claude/sessions/<pid>.json.
/// A running Codex session, matched to its pane. Codex keeps no per-process record the way
/// Claude Code does, so the rollout file is found by folder and recency (see `codexFinder`).
struct CodexSessionInfo: Hashable {
    var sessionID: String
    var path: String
    /// Codex's own running summary of what the session is for (`thread_goal_updated`), which is
    /// the closest thing it has to Claude Code's conversation title.
    var title: String?
}

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
    /// What to call this server in the UI ("This Mac" for the local machine).
    var displayName: String { remote.displayName }
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
    /// The question text above those choices (e.g. "Do you want to make this edit to X?").
    @Published var promptQuestions: [String: String] = [:]
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
    /// The host answered, but there's no tmux server running on it.
    @Published private(set) var noTmuxServer = false
    /// Tools this server is missing. python3 is the one that matters: without it there's no
    /// chat view at all, and before this the failure was silent.
    @Published private(set) var missingTools: [String] = []
    /// Unsent text in each window's message box.
    /// Unsent text per window, kept across quits — losing a half-written message because you
    /// closed the app is the kind of small betrayal you remember.
    var drafts: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "drafts.\(host)") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "drafts.\(host)") }
    }

    private(set) var needsYouCount = 0
    private var lastClaude: [String: (ClaudeSessionInfo, Date)] = [:]
    private var lastStatus: [String: ([String], Date)] = [:]
    /// Claude windows that finished while you weren't looking at them ("Done" until opened).
    @Published var unseenDone: Set<String> = []
    /// Why a sent message looks stuck, by pending message id (shown on the message).
    @Published var stuckReasons: [UUID: String] = [:]
    private var autoEnter: [UUID: (count: Int, last: Date)] = [:]
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

    /// How long to wait before the next poll. Two seconds while the server answers; after a
    /// failure it backs off, because a dead host was otherwise being hit every two seconds with
    /// a connection that takes fifteen to time out — several in flight at once, forever.
    private var pollDelay: Double = 2
    private static let maxPollDelay: Double = 30

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let delay = await MainActor.run { self?.pollDelay ?? 2 }
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    /// Poll now, whatever the backoff is — for the Retry button.
    func retryNow() {
        pollDelay = 2
        Task { await refresh() }
    }

    // MARK: Refresh

    private static let sep = ":::"

    private static let pollScript: String = {
        let fields = ["session_name", "window_id", "window_index", "window_name",
                      "pane_current_command", "window_panes", "window_active", "pane_current_path",
                      "pane_id", "pane_index", "pane_active", "window_zoomed_flag"]
        let format = fields.map { "#{\($0)}" }.joined(separator: sep)
        return """
        tmux list-sessions -F '#{session_name} #{session_attached} #{session_group_size}' 2>/dev/null \
          | awk '$1 ~ /^\(viewSessionPrefix)/ && $2 == 0 && $3 > 1 {print $1}' \
          | while read -r s; do tmux kill-session -t "=$s"; done
        tmux list-panes -a -F \(sq(format)) 2>/dev/null || echo @@NOSERVER
        for f in ~/.claude/sessions/*.json; do
          [ -f "$f" ] || continue
          kill -0 "$(basename "$f" .json)" 2>/dev/null || continue
          printf '@@SES '; tr -d '\\n' < "$f"; echo
        done
        claude_panes=$(for f in ~/.claude/sessions/*.json; do [ -f "$f" ] && kill -0 "$(basename "$f" .json)" 2>/dev/null && grep -o '"tmux":"[^"]*"' "$f" | grep -o '%[0-9]*'; done)
        for w in $( (tmux list-panes -a -f '#{m:*claude*,#{pane_current_command}}' -F '#{pane_id}' 2>/dev/null; echo "$claude_panes") | grep . | sort -u); do
          printf '@@CAP %s\\n' "$w"
          tmux capture-pane -e -p -t "$w" 2>/dev/null | tail -30
        done
        codex_panes=$(tmux list-panes -a -f '#{m:*codex*,#{pane_current_command}}' -F '#{pane_id} #{pane_pid} #{pane_current_path}' 2>/dev/null)
        if [ -n "$codex_panes" ]; then
          for w in $(printf '%s\\n' "$codex_panes" | awk '{print $1}' | sort -u); do
            printf '@@CAP %s\\n' "$w"
            tmux capture-pane -e -p -t "$w" 2>/dev/null | tail -30
          done
          printf '%s\\n' "$codex_panes" | python3 -c \(sq(codexFinderScript)) 2>/dev/null
        fi
        """
    }()

    /// Runs on the work machine, reading "<pane> <pane pid> <folder>" lines and printing
    /// "@@CODEX <pane> <session id> <rollout path>" for each pane it can place.
    static let codexFinderScript = #"""
import json, os, glob, re, subprocess, sys, time

panes, seen_panes = [], set()
for line in sys.stdin.read().splitlines():
    f = line.split(" ", 2)
    # list-panes -a also lists the app's grouped view sessions, so the same pane repeats.
    if len(f) == 3 and f[0] not in seen_panes:
        seen_panes.add(f[0]); panes.append(f)
if not panes: sys.exit()

# pid -> ppid, so the codex process under each pane's shell can be found.
ps = subprocess.run(["ps", "-axo", "pid=,ppid=,comm="], capture_output=True, text=True).stdout
children, names = {}, {}
for line in ps.splitlines():
    f = line.split(None, 2)
    if len(f) < 3: continue
    try: pid, ppid = int(f[0]), int(f[1])
    except ValueError: continue
    children.setdefault(ppid, []).append(pid)
    names[pid] = os.path.basename(f[2].strip())

def find_codex(root):
    stack, seen = [root], set()
    while stack:
        pid = stack.pop()
        if pid in seen: continue
        seen.add(pid)
        if names.get(pid, "").startswith("codex") and pid != root: return pid
        stack += children.get(pid, [])
    return None

def started(pid):
    out = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    try: return time.mktime(time.strptime(out, "%a %b %d %H:%M:%S %Y"))
    except ValueError: return 0

STAMP = re.compile(r"rollout-(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2})-")
def created(path):
    """Rollout file names carry the local time the session started."""
    m = STAMP.search(os.path.basename(path))
    if not m: return 0
    try: return time.mktime(time.strptime(m.group(1), "%Y-%m-%dT%H-%M-%S"))
    except ValueError: return 0

rollouts = glob.glob(os.path.expanduser("~/.codex/sessions/*/*/*/rollout-*.jsonl"))
meta = {}
for path in sorted(rollouts, key=os.path.getmtime, reverse=True)[:400]:
    try:
        with open(path, "rb") as fh:
            head = json.loads(fh.readline().decode("utf-8", "replace"))
    except Exception:
        continue
    if head.get("type") != "session_meta": continue
    p = head.get("payload") or {}
    # Codex writes a rollout per thread, including the subagents and guardian reviews it
    # spawns — all in the same folder, often written more recently than the conversation
    # itself. Only the thread the user is typing into is the one to show.
    if p.get("parent_thread_id") or p.get("parent_id"): continue
    if (p.get("thread_source") or "user") != "user": continue
    if not isinstance(p.get("source", "cli"), str): continue
    meta[path] = (p.get("cwd") or "", p.get("session_id") or p.get("id") or "", os.path.getmtime(path))

def goal_of(path):
    """A name for the conversation.

    Some Codex versions keep a running one-line objective for the thread
    (`thread_goal_updated`, written as the session goes, so near the end of the file). Newer
    ones don't, and then the first thing the user asked for is the best label available — the
    same thing the history browser shows."""
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            head = fh.read(min(size, 300_000))
            if size > 700_000:
                fh.seek(size - 400_000)
                tail = fh.read()
            else:
                tail = b""
    except OSError:
        return ""
    goal = ""
    for raw in head.splitlines() + tail.splitlines():
        if b'"thread_goal_updated"' not in raw:
            continue
        try:
            p = (json.loads(raw).get("payload") or {})
        except Exception:
            continue
        text = ((p.get("goal") or {}).get("objective") or "").strip()
        if text:
            goal = text
    if not goal:
        for raw in head.splitlines():
            if b'"user_message"' not in raw and b'"UserMessage"' not in raw:
                continue
            try:
                p = (json.loads(raw).get("payload") or {})
            except Exception:
                continue
            if p.get("type") == "user_message":
                goal = (p.get("message") or "").strip()
            elif p.get("type") == "item_completed":
                item = p.get("item") or {}
                if item.get("type") == "UserMessage":
                    goal = "\n".join(c.get("text", "") for c in item.get("content") or []
                                     if isinstance(c, dict)).strip()
            if goal:
                break
    if not goal:
        return ""
    for line in goal.splitlines():
        line = line.strip()
        if not line:
            continue
        # A whole opening sentence makes an unwieldy window title; keep it to a label.
        if len(line) > 52:
            cut = line[:52]
            space = cut.rfind(" ")
            line = (cut[:space] if space > 24 else cut).rstrip(" ,.;:") + "…"
        return "\t" + line
    return ""

taken = set()
for pane, pid, path in panes:
    codex = find_codex(int(pid))
    if not codex: continue
    since = started(codex) - 5
    best, best_score = None, None
    for f, (cwd, sid, mtime) in meta.items():
        if f in taken or cwd != path or mtime < since: continue
        # The rollout made when this process started is the right one; a resumed session
        # keeps an older name, so fall back to whichever has been written most recently.
        gap = abs(created(f) - since)
        score = (0, gap) if gap <= 180 else (1, -mtime)
        if best_score is None or score < best_score: best, best_score = f, score
    if best:
        taken.add(best)
        print("@@CODEX %s %s %s" % (pane, meta[best][1], best + goal_of(best)))
"""#

    func refresh() async {
        let result = await remote.run(Self.pollScript)
        guard result.ok else {
            connected = false
            lastError = Self.describe(result)
            pollDelay = min(pollDelay * 1.6, Self.maxPollDelay)
            return
        }
        connected = true
        lastError = nil
        pollDelay = 2
        // tmux isn't running over there, which is a different problem from the host being down.
        if result.stdout.contains("@@NOSERVER") && !result.stdout.contains(Self.sep) {
            noTmuxServer = true
        } else {
            noTmuxServer = false
        }
        apply(result.stdout)
    }

    private var toolsChecked = false

    /// What's installed over there. Checked once per connection, not every poll.
    ///
    /// Through a **login shell**: `ssh host 'command -v claude'` misses anything a shell only
    /// puts on PATH when it logs in (nvm, a version manager, ~/.local/bin), which made this
    /// claim tools were missing that plainly weren't. Anything visibly running is trusted over
    /// the check, since a window running `codex` settles the question.
    private func checkTools() async {
        guard !toolsChecked else { return }
        toolsChecked = true
        let probe = "for t in python3 claude codex gh; do command -v $t >/dev/null 2>&1 || echo $t; done"
        let result = await remote.run("\"$SHELL\" -lc \(sq(probe)) 2>/dev/null")
        guard result.ok else { toolsChecked = false; return }
        let running = Set(sessions.flatMap(\.windows).flatMap { [$0] + $0.paneItems }.map(\.command))
        let missing = result.stdout.split(separator: "\n").map(String.init)
            .filter { tool in !running.contains { $0.contains(tool) } }
        if missing != missingTools { missingTools = missing }
    }

    /// Turns ssh's stderr into something worth showing, and says what kind of failure it is.
    static func describe(_ result: Remote.Result) -> String {
        let text = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower.contains("permission denied") || lower.contains("publickey") {
            return "SSH refused the key. Check your ~/.ssh/config and agent."
        }
        if lower.contains("could not resolve") || lower.contains("name or service not known") {
            return "Can't resolve that host name."
        }
        if lower.contains("connection refused") { return "Nothing is listening for SSH on that host." }
        if lower.contains("operation timed out") || lower.contains("connection timed out") {
            return "The host didn't answer in time."
        }
        if lower.contains("no route to host") || lower.contains("network is unreachable") {
            return "No route to that host — is the VPN up?"
        }
        return text.isEmpty ? "The connection failed." : text
    }

    private func apply(_ output: String) {
        var captures: [String: [String]] = [:]
        var rows: [[String]] = []
        var currentCapture: String?
        var claudeByPane: [String: (info: ClaudeSessionInfo, updated: Double)] = [:]
        var codexByPane: [String: CodexSessionInfo] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("@@CODEX ") {
                let f = line.dropFirst(8).split(separator: " ", maxSplits: 2).map(String.init)
                if f.count == 3 {
                    let tab = f[2].split(separator: "\t", maxSplits: 1).map(String.init)
                    codexByPane[f[0]] = CodexSessionInfo(sessionID: f[1], path: tab[0],
                                                        title: tab.count > 1 ? tab[1] : nil)
                }
                currentCapture = nil
                continue
            }
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
            // Claude's own session record is the source of truth: while Claude runs a
            // build or script, that program is briefly the pane's foreground command,
            // and the window must not flip away from the chat. A record that's missing
            // for one refresh (file mid-write) is bridged for 20 seconds.
            var claudeInfo = claudeByPane[paneID]?.info
            let isShell = ["bash", "zsh", "sh", "fish"].contains(command)
            if let info = claudeInfo {
                lastClaude[paneID] = (info, Date())
            } else if let last = lastClaude[paneID], Date().timeIntervalSince(last.1) < 20 || !isShell {
                // A record that's missing for one refresh (the file is mid-write) is bridged
                // for 20 seconds. Beyond that, keep the chat as long as the pane isn't back
                // at a shell prompt: Claude exiting leaves a shell, anything else is Claude
                // running a build in the foreground, and the view must not flip away.
                claudeInfo = last.0
            } else {
                lastClaude[paneID] = nil
            }
            let isClaude = claudeInfo != nil || command.contains("claude")
            // Codex is bridged the same way as Claude: the rollout can take a moment to appear,
            // and a pane that's running codex shouldn't flip to a raw terminal while it does.
            var codexInfo = codexByPane[paneID]
            if let info = codexInfo {
                lastCodex[paneID] = (info, Date())
            } else if let last = lastCodex[paneID], !isShell, Date().timeIntervalSince(last.1) < 600 {
                codexInfo = last.0
            } else if isShell {
                lastCodex[paneID] = nil
            }
            let state: WindowState
            if isClaude {
                let plain = raw.map(stripANSI).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                state = Self.claudeState(Array(plain.suffix(12)), info: claudeInfo)
            } else if codexInfo != nil || command.contains("codex") {
                state = Self.codexState(raw.map(stripANSI))
            } else if isShell {
                state = .shell
            } else {
                state = .running(command)
            }
            var pane = TmuxWindow(session: session, windowID: f[1], index: Int(f[2]) ?? 0,
                                  name: f[3], command: command, panes: Int(f[5]) ?? 1, path: f[7],
                                  state: state, claude: claudeInfo, codex: codexInfo)
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
                        ?? panes.first(where: { $0.codex != nil })
                        ?? panes.first(where: { activePane.contains($0.paneID) }) ?? panes.first else { continue }
                var window = primary
                window.isPane = false
                window.paneItems = panes.count > 1 ? panes : []
                bySession[session, default: []].append(window)
            }
        }

        var options: [String: [PromptOption]] = [:]
        var questions: [String: String] = [:]
        var newSuggestions: [String: String] = [:]
        var newActivities: [String: ClaudeActivity] = [:]
        var newStatusLines: [String: [String]] = [:]
        let allItems = bySession.values.joined().flatMap { [$0] + $0.paneItems }
        for w in allItems where w.state.isClaude {
            let raw = captures[w.paneID] ?? []
            if let activity = Self.activity(raw) { newActivities[w.id] = activity }
            let footer = w.assistant == .codex ? Self.codexFooter(raw) : Self.footer(raw)
            if let footer { newStatusLines[w.id] = footer }
            if w.state == .claudeNeedsYou {
                let plainTail = raw.suffix(45).map(stripANSI)
                options[w.id] = Self.promptOptions(plainTail)
                questions[w.id] = Self.promptQuestion(plainTail)
            } else if let suggestion = Self.suggestion(raw) {
                newSuggestions[w.id] = suggestion
            }
        }
        if options != promptOptions { promptOptions = options }
        if questions != promptQuestions { promptQuestions = questions }
        if newSuggestions != suggestions { suggestions = newSuggestions }
        if newActivities != activities { activities = newActivities }
        recoverStuckMessages(allItems, captures: captures)
        // Keep the last good status line for a minute when a read finds none (Claude's
        // screen mid-redraw, or a menu covering it), so the chips don't flicker away.
        let now = Date()
        for (id, lines) in newStatusLines { lastStatus[id] = (lines, now) }
        for (id, last) in lastStatus where newStatusLines[id] == nil && now.timeIntervalSince(last.1) < 60 {
            if allItems.contains(where: { $0.id == id }) { newStatusLines[id] = last.0 }
        }
        if newStatusLines != statusLines { statusLines = newStatusLines }
        let claudeIDs = allItems.compactMap(\.claude?.sessionID)
        fetchMissingTitles(claudeIDs)
        prefetchChats(claudeIDs)
        prefetchCodexChats(allItems.compactMap(\.codex))

        let newSessions = order.map { TmuxSession(name: $0, windows: bySession[$0]!.sorted { $0.index < $1.index }) }
        if newSessions != sessions {
            sessions = newSessions
            saveSnapshot()
        }

        notifyStateChanges()
        followTmuxSelection(viewActive)
        Task { await checkTools() }
        pruneTerminals(liveTiles: Set(LayoutModel.shared.root.leaves.map(\.id)))

        if selection == nil || selectedWindow == nil {
            selection = sessions.first?.windows.first?.id
        }
    }

    /// Reads a Codex screen. Codex keeps no status file, so the footer is the only signal:
    /// it shows "Working (…  esc to interrupt)" while a turn runs, and an approval prompt
    /// when it needs an answer.
    static func codexState(_ lines: [String]) -> WindowState {
        let tail = lines.suffix(14).joined(separator: "\n")
        if tail.contains("Allow command") || tail.contains("approve") || tail.contains("[y/n]")
            || tail.contains("Yes, and don't ask") || tail.contains("❯ 1.") {
            return .claudeNeedsYou
        }
        if tail.contains("esc to interrupt") || tail.contains("Esc to interrupt") { return .claudeWorking }
        return .claudeReady
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

    /// If a message you sent is still sitting in Claude's input box, press Enter again
    /// (up to 3 times, 4 seconds apart). If Claude's agent list has focus, Enter would
    /// go there instead, so say so rather than pressing it.
    private func recoverStuckMessages(_ items: [TmuxWindow], captures: [String: [String]]) {
        var reasons: [UUID: String] = [:]
        for w in items where w.state.isClaude {
            guard let sid = w.claude?.sessionID, let store = chatStores[sid], !store.sending.isEmpty else { continue }
            let raw = captures[w.paneID] ?? []
            let typed = Self.typedInput(raw)
            let agentList = Self.agentListOpen(raw)
            for p in store.sending where Date().timeIntervalSince(p.sentAt) > 6 {
                guard Self.input(typed, holds: p.text) else { continue }
                if agentList {
                    reasons[p.id] = "Claude's agent list has focus, so Enter can't reach your message. Open the terminal view and press Esc, then Enter."
                    continue
                }
                let a = autoEnter[p.id] ?? (0, .distantPast)
                if a.count < 3 {
                    if Date().timeIntervalSince(a.last) > 4 {
                        autoEnter[p.id] = (a.count + 1, Date())
                        Task { _ = await remote.run("tmux send-keys -t \(sq(w.paneID)) Enter") }
                    }
                } else {
                    reasons[p.id] = "Your message is still in Claude's input box."
                }
            }
        }
        if reasons != stuckReasons { stuckReasons = reasons }
    }

    static func input(_ typed: String, holds sent: String) -> Bool {
        func norm(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let needle = String(norm(sent).prefix(20))
        let hay = norm(typed)
        return !needle.isEmpty && (hay.contains(needle) || hay.contains("[Pasted text"))
    }

    /// What's typed (not Claude's dim suggestion) in Claude's input box.
    static func typedInput(_ rawLines: [String]) -> String {
        guard let line = rawLines.last(where: { stripANSI($0).trimmingCharacters(in: .whitespaces).hasPrefix("❯") }),
              let prompt = line.range(of: "❯") else { return "" }
        var dim = false, text = ""
        var i = prompt.upperBound
        while i < line.endIndex {
            if line[i] == "\u{1b}", let end = line[i...].firstIndex(where: { $0.isLetter }) {
                if line[end] == "m" {
                    let params = line[line.index(after: i)..<end].dropFirst().split(separator: ";").map(String.init)
                    if params.isEmpty || params.contains("0") || params.contains("22") { dim = false }
                    if params.contains("2") { dim = true }
                }
                i = line.index(after: end)
                continue
            }
            if !dim { text.append(line[i]) }
            i = line.index(after: i)
        }
        return text.replacingOccurrences(of: "\u{a0}", with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Claude shows its agent list ("● main", "◯ general-purpose …") under the status line when it has focus.
    static func agentListOpen(_ rawLines: [String]) -> Bool {
        (footer(rawLines) ?? []).contains { $0.range(of: #"^\s*[●◯]\s"#, options: .regularExpression) != nil }
    }

    func showTerminal(for w: TmuxWindow) {
        rawTerminal.insert(w.id)
    }

    /// The lines below Claude's input box: its status line, mode line and hints.
    /// Codex's status line. It doesn't draw Claude's `───` rules around its input box, so the
    /// footer can't be found the same way: it's the last line under the `›` prompt, and it's the
    /// one carrying `·`-separated fields.
    static func codexFooter(_ rawLines: [String]) -> [String]? {
        let lines = rawLines.map(stripANSI)
            .map { $0.replacingOccurrences(of: "\u{00a0}", with: " ") }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let line = lines.last(where: { $0.contains("·") && $0.contains("%") })
                ?? lines.last(where: { $0.contains("·") }) else { return nil }
        return [line]
    }

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
    func fetchMissingTitles(_ ids: [String]) {
        let due = ids.filter { Date().timeIntervalSince(titleFetched[$0] ?? .distantPast) > 60 }
        guard !due.isEmpty else { return }
        for id in due { titleFetched[id] = Date() }
        let script = due.map { id in
            "f=$(ls ~/.claude/projects/*/\(id).jsonl 2>/dev/null | head -1); [ -n \"$f\" ] && printf '%s\\t' \(id) && { grep -a '\"type\":\"custom-title\"' \"$f\" | tail -1; grep -a '\"type\":\"ai-title\"' \"$f\" | tail -1; } | head -1"
        }.joined(separator: "; ")
        Task {
            let result = await remote.run(script)
            for line in result.stdout.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 1)
                guard parts.count == 2,
                      let obj = try? JSONSerialization.jsonObject(with: Data(parts[1].utf8)) as? [String: Any],
                      let title = (obj["customTitle"] ?? obj["aiTitle"]) as? String else { continue }
                titles[String(parts[0])] = title
            }
        }
    }

    /// Pulls numbered choices like "❯ 1. Yes" out of a Claude permission prompt.
    /// The text just above a numbered choice list: the question being asked.
    static func promptQuestion(_ lines: [String]) -> String? {
        let option = try! Regex(#"^[\s│|]*(?:❯\s*)?\d\.\s+"#)
        guard let first = lines.firstIndex(where: { $0.firstMatch(of: option) != nil }) else { return nil }
        var collected: [String] = []
        var i = first - 1
        while i >= 0, collected.count < 3 {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "│|╭╮╰╯ "))
            if t.isEmpty || t.hasPrefix("─") || t.hasPrefix("━") {
                if !collected.isEmpty { break }
            } else {
                collected.insert(t, at: 0)
            }
            i -= 1
        }
        let q = collected.joined(separator: " ")
        return q.isEmpty ? nil : q
    }

    /// Picks a choice by its number, then types `text` (for "Type something" answers) and submits.
    func answer(key: String, text: String, in w: TmuxWindow) {
        let t = sq(target(w))
        Task {
            _ = await remote.run("tmux send-keys -t \(t) \(sq(key)) && sleep 0.4 && tmux send-keys -t \(t) -l \(sq(text)) && sleep 0.2 && tmux send-keys -t \(t) Enter")
            try? await Task.sleep(for: .milliseconds(300))
            await refresh()
        }
    }

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
    private var lastCodex: [String: (CodexSessionInfo, Date)] = [:]

    /// The terminal of the focused tile, when that tile is showing `session`. Only the tile
    /// you're looking at should be able to drag the sidebar selection around.
    private func focusedController(for session: String) -> TerminalController? {
        terminals[LayoutModel.shared.focused + "\u{1}" + session]
    }

    /// If you switch windows from inside the raw terminal (a tmux shortcut or
    /// `tmux select-window`), move the sidebar selection to match. Only reacts
    /// when tmux's window actually changed, and only while the raw terminal is
    /// on screen, so the chat view never gets pulled to another window.
    private func followTmuxSelection(_ viewActive: [String: String]) {
        defer { lastViewActive = viewActive }
        guard Date().timeIntervalSince(lastUserSelection) > 3, let current = selectedWindow,
              rawTerminal.contains(current.id) || current.state.isRunningProgram,
              let controller = focusedController(for: current.session), controller.alive,
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
            guard !Notifications.muted(host: host, window: w.id) else { continue }
            finished = finished || isFinish
            asking = asking || isQuestion
            if w.state == .claudeWorking { unseenDone.remove(w.id) }
            // Banners and "Done" only for chats you aren't looking at; the sound plays either way.
            let onScreen = appActive && LayoutModel.shared.root.leaves.contains { $0.tag == "\(host)#\(w.id)" }
            if onScreen { continue }
            if isFinish { unseenDone.insert(w.id) }
            let name = w.assistant?.displayName ?? "Claude"
            if isFinish {
                notify(.finish, "\(name) finished", "\(w.session) › \(displayTitle(w)) is ready for you.", window: w.id)
            } else if isQuestion {
                notify(.question, "\(name) needs your answer", "\(w.session) › \(displayTitle(w)) is waiting for you.", window: w.id)
            }
        }
        if asking { Sounds.play(.question) } else if finished { Sounds.play(.finish) }
    }

    private func notify(_ event: Sounds.Event, _ title: String, _ body: String, window: String) {
        Notifications.post(event, title: title, subtitle: host, body: body,
                           tag: "\(host)#\(window)")
    }

    /// Tells you when something went wrong that you'd otherwise only catch by looking.
    func notifyProblem(_ title: String, _ body: String) {
        flash(title)
        Notifications.post(.problem, title: title, subtitle: host, body: body, tag: nil)
    }

    /// Claude's conversation title if it has one, then a name you gave the window, then the folder.
    func displayTitle(_ w: TmuxWindow) -> String {
        let base = baseTitle(w)
        guard !w.isPane, let siblings = sessions.first(where: { $0.name == w.session })?.windows,
              siblings.filter({ !$0.isPane && baseTitle($0) == base }).count > 1 else { return base }
        return "\(base) (\(w.index))"
    }

    private func baseTitle(_ w: TmuxWindow) -> String {
        // A tmux window the user renamed wins; otherwise the assistant's own title for the
        // conversation, which is far more useful than "codex" or the folder name.
        let automatic = w.isPane || w.name == w.command
        if let id = w.claude?.sessionID, let title = titles[id], automatic { return title }
        if let title = w.codex?.title, !title.isEmpty, automatic { return title }
        if w.isPane {
            if let assistant = w.assistant { return "\(assistant.displayName) · \(w.folder)" }
            return "\(w.command) · \(w.folder)"
        }
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

    /// Codex transcripts are found by file, and the file can move (a resumed session keeps
    /// its id but the app may learn the path later), so the store is re-made if it changes.
    func chatStore(codex: CodexSessionInfo) -> ChatStore {
        let key = "codex:" + codex.sessionID
        if let store = chatStores[key], store.transcriptPath == codex.path { return store }
        let store = ChatStore(sessionID: codex.sessionID, remote: remote, assistant: .codex, path: codex.path)
        chatStores[key] = store
        return store
    }

    /// Quietly loads every conversation in the background, one at a time,
    /// so even chats you haven't opened yet appear immediately.
    private func prefetchCodexChats(_ sessions: [CodexSessionInfo]) {
        let pending = sessions.filter { prefetched.insert("codex:" + $0.sessionID).inserted }
        guard !pending.isEmpty else { return }
        Task(priority: .background) {
            for info in pending { await chatStore(codex: info).poll() }
        }
    }

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
        guard var id = ids.first, !id.hasPrefix("tile:") else { return false }
        if let hash = id.firstIndex(of: "#") {
            guard id[..<hash] == host else { return false }   // windows can't move between servers
            id = String(id[id.index(after: hash)...])
        }
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

    /// A window or pane by its sidebar id.
    func item(_ id: String) -> TmuxWindow? {
        for w in sessions.lazy.flatMap(\.windows) {
            if w.id == id { return w }
            if let p = w.paneItems.first(where: { $0.id == id }) { return p }
        }
        return nil
    }

    // MARK: Restoring lost sessions

    /// A window the app has seen on this server, kept so it can be recreated if
    /// tmux loses it (a crash, a reboot, a killed server).
    struct SavedWindow: Codable, Hashable, Identifiable {
        var session: String
        var order: Int
        var name: String
        var path: String
        var command: String
        var claudeSessionID: String?
        var codexSessionID: String?
        var id: String { claudeSessionID ?? codexSessionID ?? "\(session)|\(order)|\(path)" }
        var isClaude: Bool { claudeSessionID != nil }
        var assistant: CodingAssistant? {
            if claudeSessionID != nil { return .claude }
            if codexSessionID != nil { return .codex }
            return CodingAssistant(command: command)
        }
    }

    private var snapshotKey: String { "snapshot.\(host)" }

    private func saveSnapshot() {
        guard !sessions.isEmpty else { return }
        let saved = sessions.flatMap { s in
            s.windows.flatMap { w in w.paneItems.isEmpty ? [w] : w.paneItems }.map { w in
                SavedWindow(session: w.session, order: w.index * 100 + w.paneIndex, name: w.name, path: w.path,
                            command: w.command, claudeSessionID: w.claude?.sessionID,
                            codexSessionID: w.codex?.sessionID)
            }
        }
        if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: snapshotKey) }
    }

    /// Windows that existed before and don't now: from the app's own record, plus
    /// the session files Claude Code leaves behind (they note the tmux session and folder).
    func restoreCandidates() async -> [SavedWindow] {
        var candidates: [SavedWindow] = []
        if let data = UserDefaults.standard.data(forKey: snapshotKey),
           let saved = try? JSONDecoder().decode([SavedWindow].self, from: data) {
            candidates = saved
        }
        let script = #"""
        import json, glob, os, time
        for f in glob.glob(os.path.expanduser("~/.claude/sessions/*.json")):
            try: d = json.load(open(f))
            except Exception: continue
            try:
                os.kill(int(os.path.basename(f)[:-5]), 0); continue   # still running
            except Exception: pass
            if (d.get("updatedAt") or 0) / 1000 < time.time() - 7 * 86400: continue
            print(json.dumps({"tmux": d.get("tmux") or "", "id": d.get("sessionId"), "cwd": d.get("cwd") or ""}))
        """#
        let result = await remote.run("python3 -", input: script)
        for line in result.stdout.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = obj["id"] as? String, let tmuxTarget = obj["tmux"] as? String,
                  let colon = tmuxTarget.firstIndex(of: ":"),
                  !candidates.contains(where: { $0.claudeSessionID == id }) else { continue }
            let session = String(tmuxTarget[..<colon])
            let windowNumber = Int(tmuxTarget[colon...].drop { !$0.isNumber }.prefix { $0.isNumber }) ?? 0
            candidates.append(SavedWindow(session: session, order: 100_000 + windowNumber, name: "claude",
                                          path: obj["cwd"] as? String ?? "~", command: "claude",
                                          claudeSessionID: id, codexSessionID: nil))
        }
        // Leave out what's already running.
        let live = sessions.flatMap(\.windows).flatMap { [$0] + $0.paneItems }
        let liveClaude = Set(live.compactMap(\.claude?.sessionID))
        let liveCodex = Set(live.compactMap(\.codex?.sessionID))
        let liveSessions = Set(sessions.map(\.name))
        let missing = candidates.filter { c in
            if let id = c.claudeSessionID { return !liveClaude.contains(id) }
            if let id = c.codexSessionID { return !liveCodex.contains(id) }
            return !liveSessions.contains(c.session)
        }
        fetchMissingTitles(missing.compactMap(\.claudeSessionID))
        return missing.sorted { ($0.session, $0.order) < ($1.session, $1.order) }
    }

    /// Recreates windows: each in its folder, in its tmux session (created if needed).
    /// Claude and Codex windows resume their conversation where the app knows its id;
    /// shells just open in their folder.
    func restore(_ windows: [SavedWindow]) {
        var script = ""
        var seen: [String] = []
        for w in windows {
            let s = sq(w.session), dir = sq(w.path)
            if !seen.contains(w.session) {
                seen.append(w.session)
                script += """
                if tmux has-session -t \(sq("=" + w.session)) 2>/dev/null; then id=$(tmux new-window -d -P -F '#{window_id}' -t \(sq(w.session + ":")) -c \(dir)); \
                else tmux new-session -d -s \(s) -c \(dir) && id=$(tmux list-windows -t \(sq("=" + w.session)) -F '#{window_id}' | head -1); fi

                """
            } else {
                script += "id=$(tmux new-window -d -P -F '#{window_id}' -t \(sq(w.session + ":")) -c \(dir))\n"
            }
            if let cid = w.claudeSessionID {
                script += "tmux send-keys -t \"$id\" \(sq("claude --resume " + cid)) Enter\n"
            } else if let cid = w.codexSessionID {
                // Codex resumes by session id too; without it you'd get a blank session in the
                // right folder and lose the conversation.
                script += "tmux send-keys -t \"$id\" \(sq("codex resume " + cid)) Enter\n"
            } else if w.assistant == .codex {
                script += "tmux send-keys -t \"$id\" codex Enter\n"
            }
        }
        Task {
            let result = await remote.run(script, timeout: 60)
            flash(result.ok ? "Restored \(windows.count) window\(windows.count == 1 ? "" : "s")" : "Restore failed: \(result.stderr.prefix(120))")
            await refresh()
        }
    }

    func window(containing pane: TmuxWindow) -> TmuxWindow? {
        sessions.lazy.flatMap(\.windows).first { $0.session == pane.session && $0.windowID == pane.windowID }
    }

    func toggleRawTerminal() {
        // The focused tile might be a plain terminal, which has its own raw/chat switch.
        if let tag = LayoutModel.shared.focusedTag,
           let t = PlainTerminalStore.shared.terminal(forTag: tag) {
            if t.assistant != nil { PlainTerminalStore.shared.toggleRaw(t) }
            return
        }
        guard let w = selectedWindow else { return }
        if rawTerminal.contains(w.id) { rawTerminal.remove(w.id) } else { rawTerminal.insert(w.id) }
    }

    // MARK: Terminals

    /// The raw terminal for one tile.
    ///
    /// A terminal is a live SSH connection attached to its own grouped view session, and a
    /// view session has exactly one current window — so a controller can only ever show one
    /// window at a time. Keying them by tile (rather than by tmux session) is what lets two
    /// tiles sit side by side on two windows of the same session; they share the SSH
    /// connection, so the extra cost is one tmux client each.
    func controller(forTile tile: String, session: String) -> TerminalController {
        let key = tile + "\u{1}" + session
        if let existing = terminals[key] { return existing }
        let controller = TerminalController(session: session, remote: remote)
        terminals[key] = controller
        return controller
    }

    /// Any live view session for `session`, for commands that should land where you're looking.
    private func viewSession(for session: String) -> String? {
        terminals.values.first { $0.session == session && $0.alive }?.viewSession
            ?? terminals.values.first { $0.session == session }?.viewSession
    }

    /// Drops the terminals of tiles that are no longer on screen. Called from the poll loop:
    /// `onDisappear` also fires while SwiftUI is re-laying out, which would tear down a
    /// terminal that's about to come straight back.
    private func pruneTerminals(liveTiles: Set<String>) {
        for (key, controller) in terminals {
            guard let tile = key.split(separator: "\u{1}").first.map(String.init),
                  !liveTiles.contains(tile) else { continue }
            controller.releaseZoom()
            controller.stop()
            terminals.removeValue(forKey: key)
        }
    }

    func userSelected(_ id: TmuxWindow.ID?) {
        lastUserSelection = Date()
        if let id { unseenDone.remove(id) }
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
        let view = viewSession(for: w.session) ?? w.session
        return "\(view):\(w.windowID)"
    }

    func newWindow(assistant: CodingAssistant?, in session: String? = nil) {
        let sessionName = session ?? selectedWindow?.session ?? sessions.first?.name ?? "main"
        // Target the view session so the new window opens in the folder you're looking at.
        let targetSession = viewSession(for: sessionName) ?? sessionName
        let launch = assistant.map { "tmux send-keys -t \"$id\" \(sq($0.command)) Enter" } ?? ":"
        let script: String
        if sessions.contains(where: { $0.name == sessionName }) {
            script = """
            id=$(tmux new-window -d -P -F '#{window_id}' -c '#{pane_current_path}' -t \(sq(targetSession + ":"))) && \(launch) && echo "$id"
            """
        } else {
            script = """
            id=$(tmux new-session -d -s \(sq(sessionName)) -P -F '#{window_id}') && \(launch) && echo "$id"
            """
        }
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
        // automatic-rename is on by default and would put the command's name back; turning it
        // off for this window is what makes a name you chose stick.
        Task {
            _ = await tmux("tmux rename-window -t \(sq(w.windowTarget)) \(sq(name))"
                + " \\; set-window-option -t \(sq(w.windowTarget)) automatic-rename off")
        }
    }

    // MARK: Pinning

    private var pinKey: String { "pinned.\(host)" }

    var pinned: Set<String> {
        get { Set(UserDefaults.standard.array(forKey: pinKey) as? [String] ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: pinKey) }
    }

    func isPinned(_ w: TmuxWindow) -> Bool { pinned.contains(w.id) }

    func togglePinned(_ w: TmuxWindow) {
        var all = pinned
        if all.contains(w.id) { all.remove(w.id) } else { all.insert(w.id) }
        pinned = all
        objectWillChange.send()
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
            if result.ok {
                for (key, controller) in terminals where controller.session == session {
                    controller.session = name
                    terminals.removeValue(forKey: key)
                    let tile = key.split(separator: "\u{1}").first.map(String.init) ?? key
                    terminals[tile + "\u{1}" + name] = controller
                }
                if let sel = selection, sel.hasPrefix(session + "|") {
                    selection = name + sel.dropFirst(session.count)
                }
            }
        }
    }

    func killSession(_ session: String) {
        for (key, controller) in terminals where controller.session == session {
            controller.stop()
            terminals.removeValue(forKey: key)
        }
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
        if let id = w.claude?.sessionID {
            chatStore(for: id).addSending(text, images: images.count)
        } else if let codex = w.codex {
            chatStore(codex: codex).addSending(text, images: images.count)
        }
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
        // The message is uploaded first, then pasted and submitted by a background job on
        // the server (setsid nohup), so a dropped connection can't leave it half-sent.
        let inner: String
        if w.assistant == .codex {
            // Codex's composer marks its input line with "›". Same problem as Claude: an
            // Enter that lands while it's still taking in the paste is dropped, so wait for
            // the text to show up and press Enter until the line clears.
            inner = """
            f="$1"
            \(imagePaste)tmux load-buffer -b deck-compose "$f" && tmux paste-buffer -p -d -b deck-compose -t \(t) || exit 1
            first=$(head -n1 "$f" | sed 's/^[[:space:]]*//' | cut -c1-20)
            inbox() { tmux capture-pane -p -t \(t) | perl -pe 's/\\xc2\\xa0/ /g' | grep '›' | tail -1; }
            waiting() { l=$(inbox); case "$l" in *"$first"*|*"Pasted"*) return 0;; *) return 1;; esac; }
            for i in 1 2 3 4 5 6 7 8 9 10; do waiting && break; sleep 0.2; done
            sleep 0.3
            for i in 1 2 3 4; do tmux send-keys -t \(t) Enter; sleep 1; waiting || break; done
            rm -f "$f" "$0"
            """
        } else if w.state.isClaude {
            // Claude Code can swallow an Enter that arrives while it's still taking in a
            // paste, and for /commands the first Enter only picks the autocomplete entry.
            // So: wait until the text shows in Claude's input line, press Enter, and keep
            // pressing (up to 4 times) until the input line no longer holds it.
            // Claude's prompt is "❯" plus a no-break space, normalised here with sed.
            inner = """
            f="$1"
            \(imagePaste)tmux load-buffer -b deck-compose "$f" && tmux paste-buffer -p -d -b deck-compose -t \(t) || exit 1
            first=$(head -n1 "$f" | sed 's/^[[:space:]]*//' | cut -c1-20)
            inbox() { tmux capture-pane -p -t \(t) | perl -pe 's/\\xc2\\xa0/ /g' | grep '^❯' | tail -1 | cut -c4-; }
            waiting() { l=$(inbox); case "$l" in *"$first"*|*"[Pasted text"*) return 0;; *) return 1;; esac; }
            for i in 1 2 3 4 5 6 7 8 9 10; do waiting && break; sleep 0.2; done
            sleep 0.3
            for i in 1 2 3 4; do tmux send-keys -t \(t) Enter; sleep 1; waiting || break; done
            rm -f "$f" "$0"
            """
        } else {
            inner = """
            f="$1"
            \(imagePaste)tmux load-buffer -b deck-compose "$f" && tmux paste-buffer -p -d -b deck-compose -t \(t) && sleep 0.2 && tmux send-keys -t \(t) Enter
            rm -f "$f" "$0"
            """
        }
        let script = """
        f=$(mktemp) && cat > "$f" && s=$(mktemp) && cat > "$s" <<'DECK_SEND_EOF'
        \(inner)
        DECK_SEND_EOF
        if command -v setsid >/dev/null 2>&1; then setsid nohup bash "$s" "$f" >/dev/null 2>&1 </dev/null &
        else nohup bash "$s" "$f" >/dev/null 2>&1 </dev/null & fi
        """
        Task {
            let result = await remote.run(script, input: text)
            if !result.ok {
                notifyProblem("Your message didn't send",
                              "\(displayTitle(w)) — \(Self.describe(result))")
            }
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
        footer() { tmux capture-pane -p -t \(t) | perl -pe 's/\\xc2\\xa0/ /g' | tail -6; }
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
    ///
    /// Typing the command opens Claude's autocomplete, and Enter runs it — but the screen can
    /// take a while to draw on a slow link. Waiting a fixed couple of seconds captured the
    /// autocomplete menu instead and then pressed Escape, so the command looked like it had
    /// simply been cancelled. So: press Enter, then wait until the command has left the input
    /// line and the screen has settled, for up to ten seconds.
    func captureClaudeScreen(command: String, in w: TmuxWindow) async -> String {
        let t = sq(target(w))
        let script = """
        screen() { tmux capture-pane -p -t \(t) | perl -pe 's/\\xc2\\xa0/ /g'; }
        typed() { screen | grep '^❯' | tail -1 | grep -qF \(sq(command)); }
        tmux send-keys -t \(t) -l \(sq(command)) || exit 1
        sleep 0.4
        tmux send-keys -t \(t) Enter
        for i in $(seq 1 25); do sleep 0.4; typed || break; done
        # Let the screen finish drawing: capture until two reads in a row agree.
        prev=""
        for i in 1 2 3 4 5 6 7 8; do
          now=$(screen)
          [ -n "$prev" ] && [ "$now" = "$prev" ] && break
          prev="$now"
          sleep 0.4
        done
        printf '%s\\n' "$prev"
        tmux send-keys -t \(t) Escape
        """
        let result = await remote.run(script, timeout: 30)
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

    /// Opens the diff for the folder of whatever window is focused.
    func showChangesForFocused() {
        let layout = LayoutModel.shared
        guard let tag = layout.focusedTag, let (server, window) = TileResolver.resolve(tag),
              window.path.hasPrefix("/") else {
            flash("Pick a window in a repository first.")
            return
        }
        layout.drop(tag: DiffTile.tag(host: server.host, path: window.path),
                    onto: layout.focused, zone: .right)
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
    enum Event: String, CaseIterable {
        case finish, question, problem

        var title: String {
            switch self {
            case .finish: "An assistant finished"
            case .question: "An assistant needs your answer"
            case .problem: "Something went wrong"
            }
        }
    }

    static let available = ["Glass", "Ping", "Hero", "Submarine", "Blow", "Bottle", "Frog", "Funk",
                            "Morse", "Pop", "Purr", "Sosumi", "Tink", "Basso"]

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            "sound.finish.on": true, "sound.finish.name": "Glass",
            "sound.question.on": true, "sound.question.name": "Ping",
            "sound.problem.on": false, "sound.problem.name": "Basso",
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
