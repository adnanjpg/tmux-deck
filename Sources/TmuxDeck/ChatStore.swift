import Foundation

/// One entry in the conversation view.
struct ChatItem: Identifiable, Equatable, Codable {
    enum Kind: Equatable, Codable {
        case user(String)
        case assistant(String)
        case tool(name: String, summary: String, added: Int, removed: Int)
        case note(String)
        case thinking(String)
        case command(String)   // a /command or ! shell command you ran; its output goes in `result`
        case recap(String)     // Claude's "while you were away" summary
    }
    var id: String
    var kind: Kind
    var result: String?
    var isError = false
    var images: Int? = nil
    var background: Bool? = nil
    /// For AskUserQuestion: the questions Claude asked, with options and descriptions.
    var questions: [AskQuestion]? = nil
}

struct AskQuestion: Codable, Equatable, Hashable {
    struct Option: Codable, Equatable, Hashable {
        var label: String
        var description: String?
    }
    var question: String
    var header: String?
    var multiSelect: Bool?
    var options: [Option]
}

struct PendingMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    var images = 0
    let sentAt = Date()
}

/// Normalises a message for matching: collapses whitespace and drops image paths,
/// "[Image #1]" placeholders and the "!" of shell commands.
private func normalized(_ s: String) -> String {
    s.split(whereSeparator: \.isWhitespace)
        .filter { !$0.contains("/.cache/tmuxdeck/") }
        .joined(separator: " ")
        .replacingOccurrences(of: #"\[Image #\d+\]"#, with: "", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: "! ").union(.whitespaces))
}

/// True when `sent` shows up in `logged`. Claude Code can merge several queued
/// messages into one, so this checks containment rather than equality.
private func arrived(_ sent: String, in logged: String) -> Bool {
    let needle = String(normalized(sent).prefix(50))
    guard !needle.isEmpty else { return false }
    return normalized(logged).contains(needle)
}

/// Follows a Claude Code conversation by reading its log on the work machine.
/// The first read takes the last few MB; after that only new lines are fetched.
/// What's been read is kept on disk, so reopening a chat (or the app) is instant.
@MainActor
final class ChatStore: ObservableObject {
    let sessionID: String
    /// Which CLI wrote the transcript. Claude Code is found by session id under
    /// ~/.claude/projects; Codex writes one rollout file per session, so it carries a path.
    let assistant: CodingAssistant
    private let path: String
    var transcriptPath: String { path }
    @Published private(set) var items: [ChatItem] = []
    @Published private(set) var loaded = false
    @Published private(set) var missing = false
    /// True while catching up after you open the chat.
    @Published private(set) var refreshing = false
    /// Messages you sent while Claude was busy that it hasn't read yet.
    @Published private(set) var queued: [String] = []
    /// Messages you just sent that haven't shown up in Claude's log yet.
    @Published private(set) var sending: [PendingMessage] = []
    /// Message ids you've collapsed in this chat.
    @Published var collapsed: Set<String> = []

    private var offset = 0
    private var toolIndex: [String: Int] = [:]
    private var busy = false
    private static let maxItems = 1500

    private struct Snapshot: Codable {
        var offset: Int
        var items: [ChatItem]
        var queued: [String]?
    }

    private let remote: Remote

    init(sessionID: String, remote: Remote, assistant: CodingAssistant = .claude, path: String = "") {
        self.sessionID = sessionID
        self.remote = remote
        self.assistant = assistant
        self.path = path
        if let data = try? Data(contentsOf: cacheURL),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            items = snapshot.items
            offset = snapshot.offset
            queued = snapshot.queued ?? []
            loaded = true
            rebuildToolIndex()
        }
    }

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TmuxDeck/chats-v10", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(assistant.rawValue)-\(sessionID).json")
    }

    private func rebuildToolIndex() {
        toolIndex = [:]
        for (i, item) in items.enumerated() {
            if case .tool = item.kind { toolIndex[item.id] = i }
        }
    }

    private func save() {
        let snapshot = Snapshot(offset: offset, items: items, queued: queued)
        let url = cacheURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }

    /// Shows a message right away, greyed out, until the log confirms it.
    func addSending(_ text: String, images: Int = 0) {
        // Slash commands (/clear, /compact…) aren't chat messages, so they'd never be confirmed.
        if images == 0 && text.trimmingCharacters(in: .whitespaces).hasPrefix("/") { return }
        sending.append(PendingMessage(text: text, images: images))
    }

    /// The question Claude is waiting on, if its last AskUserQuestion has no answer yet.
    var pendingQuestions: [AskQuestion]? {
        guard let item = items.last(where: { $0.questions != nil }), item.result == nil else { return nil }
        return item.questions
    }

    func dismissSending(_ id: UUID) {
        sending.removeAll { $0.id == id }
    }

    /// Fetches what's new since you last looked, showing the small refresh spinner.
    func catchUp() async {
        refreshing = true
        await poll()
        refreshing = false
    }

    func poll() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let startOffset = offset
        guard assistant == .claude || !path.isEmpty else { return }
        let argument = assistant == .claude ? sessionID : path
        let script = assistant == .claude ? Self.reader : Self.codexReader
        let result = await remote.run("python3 - \(sq(argument)) \(offset)", input: script, timeout: 30)
        guard result.ok else { return }
        var fresh: [ChatItem] = []
        var working = items
        var queue = queued
        var enqueued: [String] = []
        for line in result.stdout.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let k = obj["k"] as? String else { continue }
            let id = obj["id"] as? String ?? UUID().uuidString
            let text = obj["t"] as? String ?? ""
            switch k {
            case "end":
                offset = obj["off"] as? Int ?? offset
                missing = false
            case "missing":
                // A brand-new session has no log until its first message.
                missing = true
            case "reset":
                working = []; toolIndex = [:]; queue = []
            case "q+": queue.append(text); enqueued.append(text)
            case "q-": if !queue.isEmpty { queue.removeFirst() }
            case "qx":
                if let i = queue.firstIndex(of: text) { queue.remove(at: i) } else if !queue.isEmpty { queue.removeFirst() }
            case "user": fresh.append(ChatItem(id: id, kind: .user(text), images: obj["img"] as? Int))
            case "text": fresh.append(ChatItem(id: id, kind: .assistant(text)))
            case "note": fresh.append(ChatItem(id: id, kind: .note(text)))
            case "thinking": fresh.append(ChatItem(id: id, kind: .thinking(text)))
            case "cmd": fresh.append(ChatItem(id: id, kind: .command(text)))
            case "recap": fresh.append(ChatItem(id: id, kind: .recap(text)))
            case "cmdout":
                // Output belongs to the latest command that doesn't have any yet.
                func isOpenCommand(_ item: ChatItem) -> Bool {
                    if case .command = item.kind { return item.result == nil } else { return false }
                }
                if let i = fresh.lastIndex(where: isOpenCommand) {
                    fresh[i].result = text
                } else if let i = working.lastIndex(where: isOpenCommand), i >= working.count - 5 {
                    working[i].result = text
                } else {
                    fresh.append(ChatItem(id: id, kind: .note(text)))
                }
            case "tool":
                fresh.append(ChatItem(id: id, kind: .tool(name: obj["name"] as? String ?? "Tool",
                                                          summary: obj["s"] as? String ?? "",
                                                          added: obj["add"] as? Int ?? 0,
                                                          removed: obj["rem"] as? Int ?? 0),
                                      background: (obj["bg"] as? Bool) == true ? true : nil,
                                      questions: (obj["q"] as? String).flatMap { try? JSONDecoder().decode([AskQuestion].self, from: Data($0.utf8)) }))
            case "result":
                let target = obj["for"] as? String ?? ""
                if let i = fresh.lastIndex(where: { $0.id == target }) {
                    fresh[i].result = text; fresh[i].isError = obj["err"] as? Bool ?? false
                } else if let i = toolIndex[target], working.indices.contains(i) {
                    working[i].result = text; working[i].isError = obj["err"] as? Bool ?? false
                }
            default: break
            }
        }
        var known = Set(working.map(\.id))
        fresh = fresh.filter { known.insert($0.id).inserted }
        working.append(contentsOf: fresh)
        if working.count > Self.maxItems { working.removeFirst(working.count - Self.maxItems) }
        if working != items {
            items = working
            rebuildToolIndex()
        }
        if queue != queued { queued = queue }
        // A sent message is confirmed once it appears as a message or in Claude's queue.
        if !sending.isEmpty {
            let freshUsers = fresh.filter(\.startsTurn)
            let logged = freshUsers.compactMap { item -> String? in
                switch item.kind {
                case .user(let t), .command(let t): return t
                default: return nil
                }
            } + enqueued + queue
            let imagesArrived = freshUsers.contains { ($0.images ?? 0) > 0 }
            let remaining = sending.filter { p in
                if normalized(p.text).isEmpty { return !(p.images > 0 && imagesArrived) }
                return !logged.contains { arrived(p.text, in: $0) }
            }
            if remaining != sending { sending = remaining }
        }
        loaded = true
        if offset != startOffset { save() }
    }

    /// Runs on the work machine: `python3 - <rollout path> <byte offset>`.
    ///
    /// Codex writes one JSONL rollout per session under ~/.codex/sessions/YYYY/MM/DD/. The
    /// records are a mix of `event_msg` (what the TUI showed) and `response_item` (what went
    /// to the model); the TUI events are the readable ones, so they win where both exist.
    static let codexReader = #"""
import json, sys, os, re
path, off = sys.argv[1], int(sys.argv[2])
if not os.path.exists(path):
    print(json.dumps({"k": "missing"})); sys.exit()
size = os.path.getsize(path)
out = []
def emit(**d): out.append(d)
if off > size:
    off = 0
    emit(k="reset")
start = off
if off == 0 and size > 4_000_000:
    start = size - 4_000_000
with open(path, "rb") as fh:
    # Newer Codex records every visible item as an `item_completed` event, which is richer
    # and already de-duplicated; older ones only have the raw model exchange. Which shape a
    # file uses is fixed when the session starts, so it's decided once from the head.
    head = fh.read(200_000)
    items_format = b'"item_completed"' in head
    fh.seek(start)
    data = fh.read()
if start != off:
    nl = data.find(b"\n")
    start += nl + 1
    data = data[nl + 1:]
end = data.rfind(b"\n") + 1
new_off = start + end

def cut(s, n):
    s = s if isinstance(s, str) else json.dumps(s)
    return s if len(s) <= n else s[:n] + "\n…"

def text_of(content):
    """Content is a list of {type: …, text: …} in every Codex shape."""
    if isinstance(content, str): return content
    if isinstance(content, list):
        return "\n".join(c.get("text", "") for c in content if isinstance(c, dict) and c.get("text"))
    return ""

def first_line(s):
    for line in s.splitlines():
        if line.strip(): return line.strip()
    return ""

# Codex wraps tool output in a "Script completed / Wall time … / Output:" header, and the
# exec tool returns one JSON object per chunk with the real text under "output".
def unwrap(body):
    head = first_line(body)
    codes = [int(m) for m in re.findall(r"Process exited with code (\d+)", body)]
    failed = head.startswith("Script failed") or any(c != 0 for c in codes)
    idx = body.find("Output:\n")
    if head.startswith(("Script completed", "Script failed", "Chunk ID:", "Wall time")) and idx >= 0:
        body = body[idx + len("Output:\n"):]
    chunks, plain = [], []
    for line in body.splitlines():
        stripped = line.strip()
        if stripped.startswith("{") and stripped.endswith("}"):
            try:
                obj = json.loads(stripped)
            except Exception:
                plain.append(line); continue
            if isinstance(obj, dict) and "output" in obj:
                if obj.get("exit_code") not in (0, None): failed = True
                if obj["output"]: chunks.append(str(obj["output"]))
                continue
            plain.append(line)
        else:
            plain.append(line)
    text = "\n".join(chunks) if chunks else "\n".join(plain)
    return text.strip(), failed

# A custom_tool_call's input is JavaScript calling tools.exec_command({cmd: "…"}); the
# command is the readable part. The key is quoted in some versions and bare in others.
def script_summary(src):
    m = re.search(r'"?cmd"?\s*:\s*"((?:[^"\\]|\\.)*)"', src or "")
    if m:
        try: return json.loads('"%s"' % m.group(1))
        except Exception: return m.group(1)
    return (src or "").strip()

def exec_summary(name, arguments):
    try: args = json.loads(arguments) if isinstance(arguments, str) else (arguments or {})
    except Exception: args = {}
    if isinstance(args, dict):
        for key in ("cmd", "command", "query", "path", "file_path", "input", "pattern"):
            v = args.get(key)
            if isinstance(v, str) and v.strip(): return v.strip()
            if isinstance(v, list) and v: return " ".join(str(x) for x in v)
    return name

NAMES = {"exec": "Shell", "exec_command": "Shell", "shell": "Shell", "wait": "Wait",
         "apply_patch": "Edit", "update_plan": "Plan", "view_image": "Image",
         "request_user_input": "Question", "web_search": "Search"}

def file_change(item, stamp):
    changes = item.get("changes") or {}
    added = sum((ch.get("content") or "").count("\n") for ch in changes.values() if isinstance(ch, dict))
    files = list(changes)
    label = os.path.basename(files[0]) if len(files) == 1 else "%d files" % len(files)
    ident = "patch-" + (item.get("id") or stamp)
    emit(k="tool", id=ident, name="Edit", s=cut(label, 400), add=added, rem=0)
    detail = "\n".join("%s %s" % ({"add": "A", "delete": "D"}.get((ch or {}).get("type"), "M"), f)
                       for f, ch in changes.items())
    emit(k="result", **{"for": ident}, t=cut(detail or "Applied", 4000))

def command_execution(item, stamp):
    parsed = item.get("parsed_cmd") or []
    line = ""
    if parsed and isinstance(parsed[0], dict): line = parsed[0].get("cmd") or ""
    if not line:
        cmd = item.get("command")
        line = cmd[-1] if isinstance(cmd, list) and cmd else (cmd or "")
    ident = "t-" + (item.get("id") or stamp)
    emit(k="tool", id=ident, name="Shell", s=cut(line, 400), add=0, rem=0)
    body = item.get("formatted_output") or item.get("aggregated_output") \
        or ((item.get("stdout") or "") + (item.get("stderr") or ""))
    code = item.get("exit_code")
    failed = (code not in (0, None)) or item.get("status") in ("failed", "error")
    emit(k="result", **{"for": ident}, t=cut((body or "").strip() or "(no output)", 4000), err=failed)

def extension(item, stamp):
    ident = "t-" + (item.get("id") or stamp)
    kind = item.get("kind") or "Extension"
    name = "Search" if "search" in kind else kind
    emit(k="tool", id=ident, name=name, s=cut(item.get("query") or kind, 400), add=0, rem=0)
    results = item.get("results") or []
    lines = []
    for r in results:
        if not isinstance(r, dict): continue
        lines.append("%s — %s" % (r.get("title") or r.get("domain") or "", r.get("url") or ""))
    if lines: emit(k="result", **{"for": ident}, t=cut("\n".join(lines), 4000))

pending_calls = {}    # call_id -> emitted item id
said = set()          # assistant text already shown, so the model-facing copy isn't repeated
last_user = None      # a compaction replays the last user message; show it once

for raw in data[:end].splitlines():
    try: d = json.loads(raw)
    except Exception: continue
    t = d.get("type")
    p = d.get("payload")
    if not isinstance(p, dict): continue
    pt = p.get("type")
    stamp = d.get("timestamp", "")

    if t == "event_msg" and pt == "item_completed":
        item = p.get("item") or {}
        kind = item.get("type")
        ident = item.get("id") or stamp
        if kind == "UserMessage":
            body = text_of(item.get("content"))
            if body.strip() and body.strip() != last_user:
                last_user = body.strip()
                emit(k="user", id="u-" + ident, t=cut(body, 20000))
        elif kind == "AgentMessage":
            body = text_of(item.get("content"))
            if body.strip():
                said.add(body.strip())
                emit(k="text", id="a-" + ident, t=body)
        elif kind == "Reasoning":
            body = "\n\n".join(x for x in (item.get("summary_text") or []) if isinstance(x, str) and x.strip())
            if body.strip(): emit(k="thinking", id="r-" + ident, t=cut(body, 6000))
        elif kind == "CommandExecution":
            command_execution(item, stamp)
        elif kind == "FileChange":
            file_change(item, stamp)
        elif kind == "Extension":
            extension(item, stamp)
        elif kind == "Error":
            body = item.get("message") or text_of(item.get("content"))
            if body.strip(): emit(k="note", id="e-" + ident, t=cut(body, 600))
        elif kind:
            emit(k="tool", id="t-" + ident, name=NAMES.get(kind, kind),
                 s=cut(item.get("query") or item.get("name") or "", 400), add=0, rem=0)
        continue

    if items_format and t == "response_item":
        continue   # the same content, in the model's own wire format

    if t in ("session_meta", "compacted", "world_state", "turn_context", "token_usage_record"):
        continue

    if t == "event_msg":
        if pt == "user_message":
            msg = p.get("message") or ""
            if msg.strip() and msg.strip() != last_user:
                last_user = msg.strip()
                emit(k="user", id="u-" + stamp, t=cut(msg, 20000),
                     img=len(p.get("images") or []) + len(p.get("local_images") or []))
        elif pt == "agent_message":
            msg = p.get("message") or ""
            if msg.strip():
                said.add(msg.strip())
                emit(k="text", id="a-" + stamp, t=msg)
        elif pt == "context_compacted":
            emit(k="note", id="c-" + stamp, t="Conversation compacted to free up context")
        elif pt == "turn_aborted":
            emit(k="note", id="x-" + stamp, t="You stopped Codex" if p.get("reason") == "interrupted" else "Turn stopped")
        elif pt == "task_complete" and isinstance(p.get("error"), dict):
            msg = (p["error"].get("message") or "").strip()
            if msg: emit(k="note", id="e-" + stamp, t=cut(msg, 600))
        elif pt == "patch_apply_end" and not items_format:
            cid = p.get("call_id") or ""
            item = {"id": cid or stamp, "changes": p.get("changes") or {}}
            file_change(item, stamp)
        elif pt == "web_search_end" and not items_format:
            emit(k="tool", id="ws-" + (p.get("call_id") or stamp), name="Search",
                 s=cut(p.get("query") or "", 400), add=0, rem=0)
        continue

    if t != "response_item": continue

    if pt == "message":
        # Only the assistant's own prose; developer and user roles are the harness's
        # prompts, and the user's own text already arrived as a user_message event.
        if p.get("role") == "assistant":
            body = text_of(p.get("content"))
            if body.strip() and body.strip() not in said:
                said.add(body.strip())
                emit(k="text", id="m-" + (p.get("id") or stamp), t=body)
    elif pt == "reasoning":
        parts = [s.get("text", "") for s in (p.get("summary") or []) if isinstance(s, dict)]
        body = "\n\n".join(x for x in parts if x.strip())
        if body.strip(): emit(k="thinking", id="r-" + (p.get("id") or stamp), t=cut(body, 6000))
    elif pt in ("function_call", "custom_tool_call"):
        cid = p.get("call_id") or p.get("id") or stamp
        name = p.get("name") or "Tool"
        body = script_summary(p.get("input")) if pt == "custom_tool_call" else exec_summary(name, p.get("arguments"))
        ident = "t-" + cid
        pending_calls[cid] = ident
        emit(k="tool", id=ident, name=NAMES.get(name, name), s=cut(body, 400), add=0, rem=0)
    elif pt in ("function_call_output", "custom_tool_call_output"):
        cid = p.get("call_id") or ""
        body, err = unwrap(text_of(p.get("output")))
        emit(k="result", **{"for": pending_calls.get(cid, "t-" + cid)}, t=cut(body or "(no output)", 4000), err=err)
    elif pt == "web_search_call":
        action = p.get("action") or {}
        emit(k="tool", id="t-" + (p.get("call_id") or p.get("id") or stamp), name="Search",
             s=cut(action.get("query") or "", 400), add=0, rem=0)

if off == 0:
    keep = ("result",)
    out = [o for o in out if o["k"] not in keep][-600:] + [o for o in out if o["k"] in keep]
for o in out: print(json.dumps(o))
print(json.dumps({"k": "end", "off": new_off}))
"""#

    /// Runs on the work machine: `python3 - <session id> <byte offset>`.
    static let reader = #"""
import json, sys, os, glob
sid, off = sys.argv[1], int(sys.argv[2])
files = glob.glob(os.path.expanduser("~/.claude/projects/*/%s.jsonl" % sid))
if not files:
    print(json.dumps({"k": "missing"})); sys.exit()
path = max(files, key=os.path.getmtime)
size = os.path.getsize(path)
out = []
def emit(**d): out.append(d)
if off > size:
    off = 0
    emit(k="reset")
start = off
if off == 0 and size > 4_000_000:
    start = size - 4_000_000
with open(path, "rb") as fh:
    fh.seek(start)
    data = fh.read()
if start != off:
    nl = data.find(b"\n")
    start += nl + 1
    data = data[nl + 1:]
end = data.rfind(b"\n") + 1
new_off = start + end

def cut(s, n):
    s = s if isinstance(s, str) else json.dumps(s)
    return s if len(s) <= n else s[:n] + "\n…"

def summary(name, inp):
    if not isinstance(inp, dict): return ""
    for key in ("command", "file_path", "pattern", "description", "url", "query", "prompt", "path"):
        if isinstance(inp.get(key), str):
            return inp[key]
    for v in inp.values():
        if isinstance(v, str): return v
    return ""

def result_text(c):
    if isinstance(c, str): return c
    if isinstance(c, list):
        return "\n".join(x.get("text", "[image]" if x.get("type") == "image" else "") for x in c if isinstance(x, dict))
    return ""

HIDDEN = ("<command-", "<local-command", "<system-reminder", "Caveat:", "<bash-", "<user-memory", "<task-notification")
import re
PASTE_TAG = re.compile(r"</?pasted_content[^>]*>")
def tag(name, s):
    m = re.search(r"<%s>(.*?)</%s>" % (name, name), s, re.S)
    return m.group(1) if m else None

def clean(text):
    # Claude Code wraps pasted text in <pasted_content id="…"> tags; show just the text.
    return PASTE_TAG.sub("", text).strip()
for raw in data[:end].splitlines():
    try: d = json.loads(raw)
    except Exception: continue
    if d.get("isSidechain"): continue
    t = d.get("type")
    uid = d.get("uuid", "")
    if t == "continued-in":
        emit(k="note", id="cont-" + str(d.get("continuedInSessionId")), t="This conversation continues in another session")
        continue
    if t == "system":
        st, c = d.get("subtype"), d.get("content") or ""
        if st == "local_command" and ("<command-name>" in c or "<command-message>" in c):
            name = (tag("command-name", c) or tag("command-message", c) or "").strip()
            args = (tag("command-args", c) or "").strip()
            if not name.startswith("/"): name = "/" + name
            emit(k="cmd", id=uid, t=(name + (" " + args if args else "")).strip())
        elif st == "local_command":
            printed = tag("local-command-stdout", c) or tag("local-command-stderr", c)
            if printed and printed.strip(): emit(k="cmdout", t=cut(printed.strip(), 4000))
        elif st == "compact_boundary":
            emit(k="note", id=uid, t="Conversation compacted to free up context")
        elif st == "away_summary" and c.strip():
            emit(k="recap", id=uid, t=cut(c.strip(), 4000))
        elif d.get("level") in ("error", "warning") and c.strip():
            emit(k="note", id=uid, t=cut(clean(c.strip()), 600))
        continue
    meta = d.get("isMeta")
    msg = d.get("message") or {}
    content = msg.get("content")
    if t == "attachment":
        a = d.get("attachment") or {}
        p = a.get("prompt")
        if a.get("type") == "queued_command" and isinstance(p, str) and p.strip() and not p.strip().startswith(HIDDEN):
            emit(k="user", id=uid, t=cut(clean(p), 20000))
        continue
    if t == "queue-operation":
        op = d.get("operation")
        c = d.get("content")
        if isinstance(c, str) and c.strip().startswith(HIDDEN):
            continue   # Claude's own background notices, not your messages
        if op == "enqueue" and isinstance(c, str):
            emit(k="q+", t=clean(c))
        elif op == "dequeue":
            emit(k="q-")
        elif op == "remove":
            emit(k="qx", t=clean(c) if isinstance(c, str) else "")
        continue
    if t == "user":
        if isinstance(content, str):
            content = [{"type": "text", "text": content}]
        texts, images = [], 0
        for i, part in enumerate(content or []):
            if not isinstance(part, dict): continue
            if part.get("type") == "tool_result":
                emit(k="result", **{"for": part.get("tool_use_id", "")}, t=cut(result_text(part.get("content")), 4000), err=bool(part.get("is_error")))
            elif part.get("type") == "text":
                text = part.get("text", "").strip()
                if text.startswith(("<command-name>", "<command-message>")):
                    name = (tag("command-name", text) or tag("command-message", text) or "").strip()
                    args = (tag("command-args", text) or "").strip()
                    if not name.startswith("/"): name = "/" + name
                    emit(k="cmd", id=f"{uid}-{i}", t=(name + (" " + args if args else "")).strip())
                elif text.startswith(("<local-command-stdout>", "<local-command-stderr>")):
                    printed = (tag("local-command-stdout", text) or "") + (tag("local-command-stderr", text) or "")
                    if printed.strip(): emit(k="cmdout", t=cut(printed.strip(), 4000))
                elif text.startswith("<bash-input>"):
                    emit(k="cmd", id=f"{uid}-{i}", t="! " + (tag("bash-input", text) or "").strip())
                elif text.startswith(("<bash-stdout>", "<bash-stderr>")):
                    printed = (tag("bash-stdout", text) or "") + (tag("bash-stderr", text) or "")
                    emit(k="cmdout", t=cut(printed.strip() or "(no output)", 4000))
                elif text.startswith("<task-notification>"):
                    summ = tag("summary", text) or tag("status", text) or "update"
                    emit(k="note", id=f"{uid}-{i}", t="Background task: " + clean(summ).strip())
                elif meta or not text or text.startswith(HIDDEN):
                    continue
                elif text.startswith("[Request interrupted"):
                    emit(k="note", id=f"{uid}-{i}", t="You stopped Claude")
                elif text.startswith("This session is being continued from a previous conversation"):
                    emit(k="note", id=f"{uid}-{i}", t="Earlier conversation was compacted to free up context")
                else:
                    texts.append(clean(text))
            elif part.get("type") == "image" and not meta:
                images += 1
        if texts or images:
            emit(k="user", id=uid, t=cut("\n\n".join(texts), 20000), img=images)
    elif t == "assistant":
        for i, part in enumerate(content or []):
            if not isinstance(part, dict): continue
            if part.get("type") == "text" and part.get("text", "").strip():
                emit(k="text", id=f"{uid}-{i}", t=part["text"])
            elif part.get("type") == "thinking" and (part.get("thinking") or "").strip():
                emit(k="thinking", id=f"{uid}-{i}", t=cut(part["thinking"], 6000))
            elif part.get("type") == "tool_use":
                inp = part.get("input") or {}
                add = rem = 0
                if isinstance(inp, dict) and isinstance(inp.get("new_string"), str):
                    add = inp["new_string"].count("\n") + 1
                    rem = (inp.get("old_string") or "").count("\n") + 1
                elif isinstance(inp, dict) and isinstance(inp.get("content"), str):
                    add = inp["content"].count("\n") + 1
                emit(k="tool", id=part.get("id", f"{uid}-{i}"), name=part.get("name", "Tool"),
                     s=cut(summary(part.get("name"), inp), 400), add=add, rem=rem,
                     bg=bool(isinstance(inp, dict) and inp.get("run_in_background")),
                     q=json.dumps(inp.get("questions")) if part.get("name") == "AskUserQuestion" and isinstance(inp, dict) else None)

if off == 0:
    keep = ("result", "q+", "q-", "qx")
    out = [o for o in out if o["k"] not in keep][-600:] + [o for o in out if o["k"] in keep]
for o in out: print(json.dumps(o))
print(json.dumps({"k": "end", "off": new_off}))
"""#
}
