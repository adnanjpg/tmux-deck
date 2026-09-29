import AppKit
import SwiftUI

/// A conversation that already happened, found on disk rather than in a live tmux pane.
struct PastConversation: Identifiable, Hashable {
    var assistant: CodingAssistant
    var sessionID: String
    var path: String
    var folder: String
    var title: String
    var preview: String
    var modified: Date
    var size: Int

    var id: String { path }
    var folderName: String {
        let last = (folder as NSString).lastPathComponent
        return last.isEmpty ? folder : last
    }

    /// What to call it: its own title if it has one, else the first thing you said.
    var label: String {
        if !title.isEmpty { return title }
        let line = preview.split(separator: "\n").first.map(String.init) ?? preview
        return line.isEmpty ? "Untitled conversation" : String(line.prefix(80))
    }

    var ageLabel: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: modified, relativeTo: Date())
    }
}

/// Lists the conversations a server has on disk, for both CLIs.
///
/// Claude Code keeps one JSONL per session under ~/.claude/projects; Codex keeps one rollout per
/// thread under ~/.codex/sessions, of which only the ones with no parent are conversations (the
/// rest are its subagents). Titles come from the log itself, so this needs no index.
@MainActor
final class HistoryStore: ObservableObject {
    let remote: Remote

    @Published private(set) var conversations: [PastConversation] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published var search = ""
    @Published var onlyThisFolder: String?

    init(remote: Remote) { self.remote = remote }

    var visible: [PastConversation] {
        var items = conversations
        if let folder = onlyThisFolder {
            items = items.filter { $0.folder == folder }
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.label.localizedCaseInsensitiveContains(query)
                || $0.preview.localizedCaseInsensitiveContains(query)
                || $0.folder.localizedCaseInsensitiveContains(query)
        }
    }

    /// The folders these conversations happened in, most recent first.
    var folders: [String] {
        var seen = Set<String>()
        return conversations.compactMap { item in
            guard !item.folder.isEmpty, seen.insert(item.folder).inserted else { return nil }
            return item.folder
        }
    }

    func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let result = await remote.run("python3 -", input: Self.helper, timeout: 120)
        guard result.ok, let data = result.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            error = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Couldn't read the conversation history." : result.stderr
            return
        }
        error = nil
        var items: [PastConversation] = []
        for raw in obj["sessions"] as? [[String: Any]] ?? [] {
            guard let assistant = CodingAssistant(rawValue: raw["assistant"] as? String ?? "") else { continue }
            items.append(PastConversation(assistant: assistant,
                                          sessionID: raw["id"] as? String ?? "",
                                          path: raw["path"] as? String ?? "",
                                          folder: raw["cwd"] as? String ?? "",
                                          title: raw["title"] as? String ?? "",
                                          preview: raw["preview"] as? String ?? "",
                                          modified: Date(timeIntervalSince1970: raw["modified"] as? Double ?? 0),
                                          size: raw["size"] as? Int ?? 0))
        }
        conversations = items
    }

    static let helper = #"""
import json, os, glob, re, sys

LIMIT = 400

def head_and_tail(path, head_bytes=400_000, tail_bytes=200_000):
    size = os.path.getsize(path)
    with open(path, "rb") as fh:
        head = fh.read(min(size, head_bytes))
        if size > head_bytes + tail_bytes:
            fh.seek(size - tail_bytes)
            tail = fh.read()
        else:
            tail = b""
    return head, tail, size

def lines(blob):
    for raw in blob.splitlines():
        raw = raw.strip()
        if not raw.startswith(b"{"):
            continue
        try:
            yield json.loads(raw)
        except Exception:
            continue

def claude_sessions():
    out = []
    for path in glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl")):
        try:
            size = os.path.getsize(path)
            if size < 200:
                continue
            mtime = os.path.getmtime(path)
        except OSError:
            continue
        sid = os.path.basename(path)[:-6]
        head, tail, _ = head_and_tail(path)
        title, cwd, first = "", "", ""
        for d in lines(head):
            if not cwd and isinstance(d.get("cwd"), str):
                cwd = d["cwd"]
            if d.get("type") in ("custom-title", "ai-title"):
                title = d.get("title") or d.get("content") or title
            if not first and d.get("type") == "user" and not d.get("isMeta"):
                msg = (d.get("message") or {}).get("content")
                if isinstance(msg, str):
                    first = msg
                elif isinstance(msg, list):
                    for part in msg:
                        if isinstance(part, dict) and part.get("type") == "text":
                            first = part.get("text", ""); break
            if title and cwd and first:
                break
        # A title written later in a long conversation is the one that stuck.
        for d in lines(tail):
            if d.get("type") in ("custom-title", "ai-title"):
                title = d.get("title") or d.get("content") or title
        first = re.sub(r"<[^>]+>", " ", first or "").strip()
        out.append({"assistant": "claude", "id": sid, "path": path, "cwd": cwd,
                    "title": (title or "").strip(), "preview": first[:160],
                    "modified": mtime, "size": size})
    return out

def codex_sessions():
    out = []
    for path in glob.glob(os.path.expanduser("~/.codex/sessions/*/*/*/rollout-*.jsonl")):
        try:
            size = os.path.getsize(path)
            if size < 200:
                continue
            mtime = os.path.getmtime(path)
        except OSError:
            continue
        head, tail, _ = head_and_tail(path, head_bytes=200_000)
        meta = None
        first = ""
        for d in lines(head):
            if meta is None and d.get("type") == "session_meta":
                meta = d.get("payload") or {}
            if not first:
                p = d.get("payload") or {}
                if p.get("type") == "user_message":
                    first = p.get("message") or ""
                elif p.get("type") == "item_completed":
                    item = p.get("item") or {}
                    if item.get("type") == "UserMessage":
                        first = "\n".join(c.get("text", "") for c in item.get("content") or []
                                          if isinstance(c, dict))
            if meta is not None and first:
                break
        if meta is None:
            continue
        # Subagents and guardian reviews get their own rollout; only the conversation is history.
        if meta.get("parent_thread_id") or meta.get("parent_id"):
            continue
        if (meta.get("thread_source") or "user") != "user":
            continue
        out.append({"assistant": "codex", "id": meta.get("session_id") or meta.get("id") or "",
                    "path": path, "cwd": meta.get("cwd") or "", "title": "",
                    "preview": (first or "").strip()[:160], "modified": mtime, "size": size})
    return out

which = sys.argv[1] if len(sys.argv) > 1 else "all"
items = []
if which in ("all", "claude"):
    items += claude_sessions()
if which in ("all", "codex"):
    items += codex_sessions()
items.sort(key=lambda s: s["modified"], reverse=True)
print(json.dumps({"sessions": items[:LIMIT]}))
"""#
}

extension Notification.Name {
    static let openHistory = Notification.Name("TmuxDeckOpenHistory")
    static let findInChat = Notification.Name("TmuxDeckFindInChat")
}

@MainActor
final class HistoryStores {
    static let shared = HistoryStores()
    private var stores: [String: HistoryStore] = [:]

    func store(for host: String) -> HistoryStore {
        if let existing = stores[host] { return existing }
        let store = HistoryStore(remote: Remote(host: host))
        stores[host] = store
        return store
    }
}

/// The tag that puts a finished conversation in a tile:
/// `past#<host>#<claude|codex>#<session id>#<path>`.
enum PastTile {
    static func tag(host: String, _ item: PastConversation) -> String {
        "past#\(host)#\(item.assistant.rawValue)#\(item.sessionID)#\(item.path)"
    }

    static func resolve(_ tag: String) -> (host: String, assistant: CodingAssistant, id: String, path: String)? {
        guard tag.hasPrefix("past#") else { return nil }
        let parts = tag.dropFirst(5).split(separator: "#", maxSplits: 3).map(String.init)
        guard parts.count == 4, let assistant = CodingAssistant(rawValue: parts[1]) else { return nil }
        return (parts[0], assistant, parts[2], parts[3])
    }
}
