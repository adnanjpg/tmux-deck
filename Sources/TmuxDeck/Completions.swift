import AppKit
import SwiftUI

/// Something you can complete in the message box: a slash command, or a skill you can ask for.
struct Completion: Identifiable, Hashable {
    enum Kind: String { case command, skill, file }

    var kind: Kind
    var name: String
    var detail: String
    /// Where it came from — "built in", "personal", "project", "plugin".
    var source: String

    var id: String { kind.rawValue + ":" + name }
    var typed: String {
        switch kind {
        case .command: "/" + name
        case .file: "@" + name
        case .skill: name
        }
    }
    var glyph: String {
        switch kind {
        case .command: "chevron.right.square"
        case .file: "doc"
        case .skill: "sparkles"
        }
    }
}

/// The slash commands and skills available to one assistant, in one folder, on one machine.
///
/// The built-in commands are a list here; everything else is found on disk, which is where a
/// CLI keeps the ones you added — `~/.claude/commands`, `.claude/skills`, plugin commands,
/// `~/.codex/prompts`, `~/.codex/skills` — including the project's own.
@MainActor
final class CommandCatalog: ObservableObject {
    let remote: Remote
    let assistant: CodingAssistant
    let folder: String

    @Published private(set) var entries: [Completion] = []
    private var loaded = false
    private var loading = false

    init(remote: Remote, assistant: CodingAssistant, folder: String) {
        self.remote = remote
        self.assistant = assistant
        self.folder = folder
        entries = Self.builtIn(assistant)
    }

    /// Entries matching what's been typed after the prefix, best first.
    func matches(_ query: String, kind: Completion.Kind?) -> [Completion] {
        let q = query.lowercased()
        let pool = kind.map { k in entries.filter { $0.kind == k } } ?? entries
        guard !q.isEmpty else {
            return Array(pool.sorted { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) }.prefix(60))
        }
        // Prefix matches first, then anything containing it, then a description match.
        var prefix: [Completion] = [], contains: [Completion] = [], described: [Completion] = []
        for e in pool {
            let name = e.name.lowercased()
            if name.hasPrefix(q) { prefix.append(e) }
            else if name.contains(q) { contains.append(e) }
            else if e.detail.lowercased().contains(q) { described.append(e) }
        }
        let byName = { (a: Completion, b: Completion) in a.name.count < b.name.count }
        return Array((prefix.sorted(by: byName) + contains.sorted(by: byName) + described).prefix(60))
    }

    func loadIfNeeded() {
        guard !loaded, !loading else { return }
        loading = true
        Task {
            defer { loading = false }
            let result = await remote.run("python3 - \(sq(assistant.rawValue)) \(sq(folder))",
                                          input: Self.helper, timeout: 30)
            guard result.ok, let data = result.stdout.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = obj["entries"] as? [[String: Any]] else { return }
            var all = Self.builtIn(assistant)
            var seen = Set(all.map(\.id))
            for item in raw {
                let entry = Completion(kind: Completion.Kind(rawValue: item["kind"] as? String ?? "") ?? .command,
                                       name: item["name"] as? String ?? "",
                                       detail: item["desc"] as? String ?? "",
                                       source: item["source"] as? String ?? "")
                guard !entry.name.isEmpty, seen.insert(entry.id).inserted else { continue }
                all.append(entry)
            }
            entries = all
            loaded = true
        }
    }

    /// The commands each CLI ships with.
    ///
    /// A list rather than something discovered, because neither CLI will tell you: they're only
    /// in the `/` popup its own TUI draws. It can drift with a new release — anything found on
    /// disk wins, and a command missing from here still works if you type it.
    static func builtIn(_ assistant: CodingAssistant) -> [Completion] {
        let claude: [(String, String)] = [
            ("add-dir", "Add another folder to the session"),
            ("agents", "Manage subagents"),
            ("clear", "Start a new conversation"),
            ("compact", "Summarise the conversation to free up context"),
            ("config", "Settings"),
            ("context", "Show what's using the context window"),
            ("cost", "Token usage and cost for this session"),
            ("doctor", "Check the installation"),
            ("effort", "Set the reasoning effort"),
            ("exit", "Quit"),
            ("export", "Export the conversation"),
            ("help", "List the commands"),
            ("hooks", "Manage hooks"),
            ("init", "Write a CLAUDE.md for this project"),
            ("install-github-app", "Set up the GitHub app"),
            ("login", "Sign in"),
            ("logout", "Sign out"),
            ("mcp", "Manage MCP servers"),
            ("memory", "Edit memory files"),
            ("model", "Change the model"),
            ("output-style", "Change the output style"),
            ("permissions", "Manage permissions"),
            ("pr-comments", "Read the comments on a pull request"),
            ("release-notes", "What changed in this version"),
            ("rename", "Rename this conversation"),
            ("resume", "Reopen an earlier conversation"),
            ("review", "Review a pull request"),
            ("rewind", "Go back to an earlier point"),
            ("security-review", "Review the changes for security problems"),
            ("skills", "List the skills available"),
            ("status", "Session status"),
            ("statusline", "Configure the status line"),
            ("tasks", "Background tasks"),
            ("todos", "Show the to-do list"),
            ("usage", "Plan usage and limits"),
            ("vim", "Vim keys in the input"),
        ]
        let codex: [(String, String)] = [
            ("approvals", "Change what needs your approval"),
            ("clear", "Start a new conversation"),
            ("compact", "Summarise the conversation to free up context"),
            ("diff", "Show the working tree diff"),
            ("init", "Write an AGENTS.md for this project"),
            ("logout", "Sign out"),
            ("mcp", "Manage MCP servers"),
            ("mention", "Mention a file"),
            ("model", "Change the model"),
            ("new", "Start a new session"),
            ("plan", "Switch to plan mode"),
            ("quit", "Quit"),
            ("resume", "Reopen an earlier session"),
            ("review", "Review the changes"),
            ("skills", "List the skills available"),
            ("status", "Session status"),
            ("undo", "Undo the last turn"),
        ]
        return (assistant == .claude ? claude : codex).map {
            Completion(kind: .command, name: $0.0, detail: $0.1, source: "built in")
        }
    }

    static let helper = #"""
import json, os, re, sys, glob

assistant = sys.argv[1] if len(sys.argv) > 1 else "claude"
cwd = os.path.expanduser(sys.argv[2]) if len(sys.argv) > 2 else os.path.expanduser("~")

def frontmatter(path):
    """name/description from a SKILL.md's YAML header, without a YAML parser."""
    name = desc = ""
    try:
        with open(path, "r", errors="replace") as fh:
            if fh.readline().strip() != "---":
                return "", ""
            key = None
            for _ in range(40):
                line = fh.readline()
                if not line or line.strip() == "---":
                    break
                m = re.match(r"^(\w[\w-]*):\s*(.*)$", line)
                if m:
                    key, value = m.group(1), m.group(2).strip().strip('"\'')
                    if key == "name": name = value
                    elif key == "description": desc = value
                elif key == "description" and line.startswith((" ", "\t")):
                    desc += " " + line.strip()
    except OSError:
        return "", ""
    return name, desc

def command_file(path):
    """A command is its filename; its description is the frontmatter or the first line."""
    name = os.path.basename(path)[:-3]
    _, desc = frontmatter(path)
    if not desc:
        try:
            with open(path, "r", errors="replace") as fh:
                for line in fh:
                    line = line.strip()
                    if line and not line.startswith(("---", "#")):
                        desc = line[:160]; break
        except OSError:
            pass
    return name, desc

found = {}
def add(kind, name, desc, source):
    name = (name or "").strip()
    if not name or name in found:
        return
    found[name] = {"kind": kind, "name": name, "desc": (desc or "").strip()[:200], "source": source}

if assistant == "claude":
    for pattern, source in [(os.path.join(cwd, ".claude/commands/**/*.md"), "project"),
                            (os.path.expanduser("~/.claude/commands/**/*.md"), "personal")]:
        for f in sorted(glob.glob(pattern, recursive=True)):
            n, d = command_file(f); add("command", n, d, source)
    # Plugins keep several cached revisions of the same command; one entry is enough.
    for f in sorted(glob.glob(os.path.expanduser("~/.claude/plugins/cache/*/*/*/commands/**/*.md"), recursive=True)):
        n, d = command_file(f); add("command", n, d, "plugin")
    for pattern, source in [(os.path.join(cwd, ".claude/skills/**/SKILL.md"), "project"),
                            (os.path.expanduser("~/.claude/skills/**/SKILL.md"), "personal")]:
        for f in sorted(glob.glob(pattern, recursive=True)):
            n, d = frontmatter(f)
            add("skill", n or os.path.basename(os.path.dirname(f)), d, source)
else:
    for pattern, source in [(os.path.join(cwd, ".codex/prompts/**/*.md"), "project"),
                            (os.path.expanduser("~/.codex/prompts/**/*.md"), "personal")]:
        for f in sorted(glob.glob(pattern, recursive=True)):
            n, d = command_file(f); add("command", n, d, source)
    for pattern, source in [(os.path.join(cwd, ".codex/skills/*/SKILL.md"), "project"),
                            (os.path.expanduser("~/.codex/skills/*/SKILL.md"), "personal"),
                            (os.path.expanduser("~/.codex/skills/.system/*/SKILL.md"), "built in")]:
        for f in sorted(glob.glob(pattern)):
            n, d = frontmatter(f)
            add("skill", n or os.path.basename(os.path.dirname(f)), d, source)

print(json.dumps({"entries": list(found.values())}))
"""#
}

@MainActor
final class CommandCatalogs {
    static let shared = CommandCatalogs()
    private var catalogs: [String: CommandCatalog] = [:]

    func catalog(host: String, assistant: CodingAssistant, folder: String) -> CommandCatalog {
        let key = [host, assistant.rawValue, folder].joined(separator: "\u{1}")
        if let existing = catalogs[key] { return existing }
        let catalog = CommandCatalog(remote: Remote(host: host), assistant: assistant, folder: folder)
        catalogs[key] = catalog
        return catalog
    }
}

/// What the message box is completing right now, worked out from the text and the caret.
struct CompletionContext: Equatable {
    /// The character that opened it: "/" for commands and skills, "@" for a file path.
    var prefix: Character
    /// What's been typed after it.
    var query: String
    /// The range of `<prefix><query>` in the text, so accepting can replace it.
    var range: Range<String.Index>

    /// A "/" only opens the list at the very start of a message — a slash command has to be the
    /// whole message, and mid-sentence slashes are just punctuation (and file paths).
    static func find(in text: String, caret: String.Index) -> CompletionContext? {
        var start = caret
        while start > text.startIndex {
            let before = text.index(before: start)
            let ch = text[before]
            if ch == "/" || ch == "@" {
                let token = String(text[text.index(after: before)..<caret])
                guard !token.contains(" "), !token.contains("\n") else { return nil }
                if ch == "/" && before != text.startIndex { return nil }
                return CompletionContext(prefix: ch, query: token, range: before..<caret)
            }
            if ch == " " || ch == "\n" { return nil }
            start = before
        }
        return nil
    }
}

/// The list that appears over the message box when you type "/" or "@".
struct CompletionList: View {
    @Environment(\.theme) private var theme
    @Environment(\.fonts) private var fonts
    let items: [Completion]
    let selected: Int
    var onPick: (Completion) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        row(item, chosen: i == selected)
                            .id(i)
                            .contentShape(Rectangle())
                            .onTapGesture { onPick(item) }
                    }
                }
            }
            .onChange(of: selected) { _, i in
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(i, anchor: .center) }
            }
        }
        .frame(maxHeight: 260)
        .background(theme.panel)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.line))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }

    private func row(_ item: Completion, chosen: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: item.glyph)
                .font(fonts.caption)
                .foregroundStyle(item.kind == .command ? Color.accentColor : Color.orange)
                .frame(width: 14)
            Text(item.typed)
                .font(fonts.callout.monospaced().weight(.medium))
                .lineLimit(1)
            Text(item.detail)
                .font(fonts.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Text(item.source)
                .font(fonts.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(chosen ? Color.accentColor.opacity(0.18) : .clear)
    }
}


/// Completes "@path" against the files in one folder.
///
/// It asks the server rather than reusing the Files panel's tree: the panel is rooted wherever
/// you last browsed, and a mention should match anywhere under the folder the window is working
/// in. The search is debounced and capped, and honours .gitignore where the folder is a git
/// repository, because a mention of something in node_modules is never what you meant.
@MainActor
final class FileFinder: ObservableObject {
    let remote: Remote
    let folder: String

    @Published private(set) var results: [Completion] = []
    private var task: Task<Void, Never>?
    private var lastQuery = ""

    init(remote: Remote, folder: String) {
        self.remote = remote
        self.folder = folder
    }

    func matches(_ query: String) -> [Completion] {
        results
    }

    func search(_ query: String) {
        guard query != lastQuery else { return }
        lastQuery = query
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled, let self else { return }
            let result = await self.remote.run(
                "python3 - \(sq(self.folder)) \(sq(query))", input: Self.helper, timeout: 20)
            guard !Task.isCancelled, result.ok,
                  let data = result.stdout.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let paths = obj["paths"] as? [String] else { return }
            self.results = paths.map {
                Completion(kind: .file, name: $0,
                           detail: ($0 as NSString).deletingLastPathComponent,
                           source: "file")
            }
        }
    }

    static let helper = #"""
import json, os, subprocess, sys

folder = os.path.expanduser(sys.argv[1])
query = (sys.argv[2] if len(sys.argv) > 2 else "").lower()

def tracked():
    """git ls-files where we can: it already knows what to ignore."""
    try:
        p = subprocess.run(["git", "-C", folder, "ls-files", "--cached", "--others",
                            "--exclude-standard"], capture_output=True, text=True, timeout=20)
        if p.returncode == 0 and p.stdout.strip():
            return p.stdout.splitlines()
    except Exception:
        pass
    return None

def walked():
    out = []
    skip = {".git", "node_modules", "venv", ".venv", "__pycache__", "dist", "build", ".next",
            "target", ".gradle", "Pods", ".mypy_cache", ".pytest_cache"}
    for root, dirs, files in os.walk(folder):
        dirs[:] = [d for d in dirs if d not in skip and not d.startswith(".")]
        for name in files:
            out.append(os.path.relpath(os.path.join(root, name), folder))
            if len(out) > 20000:
                return out
    return out

paths = tracked()
if paths is None:
    paths = walked()

if query:
    exact = [p for p in paths if os.path.basename(p).lower().startswith(query)]
    part = [p for p in paths if p.lower().find(query) >= 0 and p not in exact]
    paths = exact + part
paths.sort(key=lambda p: (len(p.split("/")), len(p)))
print(json.dumps({"paths": paths[:40]}))
"""#
}

@MainActor
final class FileFinders {
    static let shared = FileFinders()
    private var finders: [String: FileFinder] = [:]

    func finder(host: String, folder: String) -> FileFinder {
        let key = host + "\u{1}" + folder
        if let existing = finders[key] { return existing }
        let finder = FileFinder(remote: Remote(host: host), folder: folder)
        finders[key] = finder
        return finder
    }
}
