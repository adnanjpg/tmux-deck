import Foundation

/// One entry in the conversation view.
struct ChatItem: Identifiable, Equatable, Codable {
    enum Kind: Equatable, Codable {
        case user(String)
        case assistant(String)
        case tool(name: String, summary: String, added: Int, removed: Int)
        case note(String)
        case thinking(String)
    }
    var id: String
    var kind: Kind
    var result: String?
    var isError = false
}

/// Follows a Claude Code conversation by reading its log on the work machine.
/// The first read takes the last few MB; after that only new lines are fetched.
/// What's been read is kept on disk, so reopening a chat (or the app) is instant.
@MainActor
final class ChatStore: ObservableObject {
    let sessionID: String
    @Published private(set) var items: [ChatItem] = []
    @Published private(set) var loaded = false
    @Published private(set) var missing = false
    /// True while catching up after you open the chat.
    @Published private(set) var refreshing = false
    /// Messages you sent while Claude was busy that it hasn't read yet.
    @Published private(set) var queued: [String] = []
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

    init(sessionID: String) {
        self.sessionID = sessionID
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
            .appendingPathComponent("TmuxDeck/chats-v3", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(sessionID).json")
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
        let result = await Remote.run("python3 - \(sq(sessionID)) \(offset)", input: Self.reader, timeout: 30)
        guard result.ok else { return }
        var fresh: [ChatItem] = []
        var working = items
        var queue = queued
        for line in result.stdout.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let k = obj["k"] as? String else { continue }
            let id = obj["id"] as? String ?? UUID().uuidString
            let text = obj["t"] as? String ?? ""
            switch k {
            case "end":
                offset = obj["off"] as? Int ?? offset
            case "missing":
                missing = true
            case "reset":
                working = []; toolIndex = [:]; queue = []
            case "q+": queue.append(text)
            case "q-": if !queue.isEmpty { queue.removeFirst() }
            case "qx":
                if let i = queue.firstIndex(of: text) { queue.remove(at: i) } else if !queue.isEmpty { queue.removeFirst() }
            case "user": fresh.append(ChatItem(id: id, kind: .user(text)))
            case "text": fresh.append(ChatItem(id: id, kind: .assistant(text)))
            case "note": fresh.append(ChatItem(id: id, kind: .note(text)))
            case "thinking": fresh.append(ChatItem(id: id, kind: .thinking(text)))
            case "tool":
                fresh.append(ChatItem(id: id, kind: .tool(name: obj["name"] as? String ?? "Tool",
                                                          summary: obj["s"] as? String ?? "",
                                                          added: obj["add"] as? Int ?? 0,
                                                          removed: obj["rem"] as? Int ?? 0)))
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
        working.append(contentsOf: fresh)
        if working.count > Self.maxItems { working.removeFirst(working.count - Self.maxItems) }
        if working != items {
            items = working
            rebuildToolIndex()
        }
        if queue != queued { queued = queue }
        loaded = true
        if offset != startOffset { save() }
    }

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
for raw in data[:end].splitlines():
    try: d = json.loads(raw)
    except Exception: continue
    if d.get("isSidechain") or d.get("isMeta"): continue
    t = d.get("type")
    uid = d.get("uuid", "")
    msg = d.get("message") or {}
    content = msg.get("content")
    if t == "attachment":
        a = d.get("attachment") or {}
        if a.get("type") == "queued_command" and isinstance(a.get("prompt"), str) and a["prompt"].strip():
            emit(k="user", id=uid, t=cut(a["prompt"].strip(), 20000))
        continue
    if t == "queue-operation":
        op = d.get("operation")
        if op == "enqueue" and isinstance(d.get("content"), str):
            emit(k="q+", t=d["content"])
        elif op == "dequeue":
            emit(k="q-")
        elif op == "remove":
            emit(k="qx", t=d.get("content") if isinstance(d.get("content"), str) else "")
        continue
    if t == "user":
        if isinstance(content, str):
            content = [{"type": "text", "text": content}]
        for i, part in enumerate(content or []):
            if not isinstance(part, dict): continue
            if part.get("type") == "tool_result":
                emit(k="result", **{"for": part.get("tool_use_id", "")}, t=cut(result_text(part.get("content")), 4000), err=bool(part.get("is_error")))
            elif part.get("type") == "text":
                text = part.get("text", "").strip()
                if text.startswith("<bash-input>"):
                    emit(k="user", id=f"{uid}-{i}", t="! " + text.replace("<bash-input>", "").replace("</bash-input>", "").strip())
                    continue
                if not text or text.startswith(HIDDEN): continue
                if text.startswith("[Request interrupted"):
                    emit(k="note", id=f"{uid}-{i}", t="You stopped Claude")
                else:
                    emit(k="user", id=f"{uid}-{i}", t=cut(text, 20000))
            elif part.get("type") == "image":
                emit(k="user", id=f"{uid}-{i}", t="[image]")
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
                     s=cut(summary(part.get("name"), inp), 400), add=add, rem=rem)

if off == 0:
    keep = ("result", "q+", "q-", "qx")
    out = [o for o in out if o["k"] not in keep][-600:] + [o for o in out if o["k"] in keep]
for o in out: print(json.dumps(o))
print(json.dumps({"k": "end", "off": new_off}))
"""#
}
