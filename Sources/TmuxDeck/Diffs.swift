import AppKit
import SwiftUI

/// One file changed between the branch point and the working tree.
struct DiffFile: Identifiable, Hashable {
    var path: String
    var status: String      // M, A, D, R, ? (untracked)
    var added: Int
    var removed: Int
    var binary: Bool

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }

    var statusLabel: String {
        switch status {
        case "A": "added"
        case "D": "deleted"
        case "R": "renamed"
        case "?": "new"
        default: "changed"
        }
    }

    var statusColor: Color {
        switch status {
        case "A", "?": .green
        case "D": .red
        case "R": .purple
        default: .orange
        }
    }
}

/// A git worktree, as `git worktree list` reports it.
struct Worktree: Identifiable, Hashable {
    var path: String
    var branch: String
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

/// What a repository looks like right now.
struct RepoState: Equatable {
    var root: String
    var branch: String
    var base: String
    var against: String       // the merge-base commit everything is compared with
    var files: [DiffFile]
    var ahead: Int
    var behind: Int
    var dirty: Bool
    var worktrees: [Worktree]

    var totalAdded: Int { files.reduce(0) { $0 + $1.added } }
    var totalRemoved: Int { files.reduce(0) { $0 + $1.removed } }
}

/// Reads a repository's diff against the branch it's meant to land on.
///
/// The comparison is the **working tree against the merge base** with that branch, so it covers
/// what's been committed on this branch and what hasn't been committed yet — which is the thing
/// you want to look at when an agent has been working in a worktree. Untracked files are listed
/// too, since a new file an agent just wrote is a change whether or not it's staged.
@MainActor
final class DiffStore: ObservableObject {
    let remote: Remote
    let path: String

    @Published private(set) var state: RepoState?
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    @Published private(set) var patches: [String: String] = [:]
    @Published var expanded: Set<String> = []
    /// Set to compare against something other than the branch the app picked.
    @Published var baseOverride: String?

    init(remote: Remote, path: String) {
        self.remote = remote
        self.path = path
    }

    func toggle(_ file: DiffFile) {
        if expanded.contains(file.path) {
            expanded.remove(file.path)
        } else {
            expanded.insert(file.path)
            if patches[file.path] == nil { Task { await loadPatch(file) } }
        }
    }

    func expandAll() {
        guard let state else { return }
        expanded = Set(state.files.filter { !$0.binary }.map(\.path))
        for file in state.files where !file.binary && patches[file.path] == nil {
            Task { await loadPatch(file) }
        }
    }

    func collapseAll() { expanded = [] }

    func refresh() async {
        loading = true
        defer { loading = false }
        let base = baseOverride ?? ""
        let result = await remote.run("python3 - repo \(sq(path)) \(sq(base))", input: Self.helper, timeout: 60)
        guard result.ok, let data = result.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            error = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Couldn't read that repository." : result.stderr
            return
        }
        if let message = obj["error"] as? String {
            error = message
            state = nil
            return
        }
        error = nil
        var files: [DiffFile] = []
        for item in obj["files"] as? [[String: Any]] ?? [] {
            files.append(DiffFile(path: item["path"] as? String ?? "",
                                  status: item["status"] as? String ?? "M",
                                  added: item["added"] as? Int ?? 0,
                                  removed: item["removed"] as? Int ?? 0,
                                  binary: item["binary"] as? Bool ?? false))
        }
        var trees: [Worktree] = []
        for item in obj["worktrees"] as? [[String: Any]] ?? [] {
            trees.append(Worktree(path: item["path"] as? String ?? "",
                                  branch: item["branch"] as? String ?? "(detached)"))
        }
        let fresh = RepoState(root: obj["root"] as? String ?? path,
                              branch: obj["branch"] as? String ?? "?",
                              base: obj["base"] as? String ?? "",
                              against: obj["against"] as? String ?? "",
                              files: files,
                              ahead: obj["ahead"] as? Int ?? 0,
                              behind: obj["behind"] as? Int ?? 0,
                              dirty: obj["dirty"] as? Bool ?? false,
                              worktrees: trees)
        if fresh != state {
            // A patch already shown for a file that changed again would be stale.
            if fresh.files != state?.files { patches = [:] }
            state = fresh
        }
    }

    private func loadPatch(_ file: DiffFile) async {
        guard let state else { return }
        let result = await remote.run("python3 - patch \(sq(state.root)) \(sq(state.against)) \(sq(file.path))",
                                      input: Self.helper, timeout: 60)
        guard result.ok, let data = result.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        patches[file.path] = (obj["patch"] as? String) ?? (obj["error"] as? String) ?? ""
    }

    /// `python3 - <repo|patch> <path> [base] [file]`.
    static let helper = #"""
import json, os, subprocess, sys

def out(**d):
    print(json.dumps(d)); sys.exit()

def git(root, *args, limit=None):
    try:
        p = subprocess.run(["git", "-C", root] + list(args), capture_output=True, text=True, timeout=60)
    except Exception as exc:
        return "", str(exc)
    return p.stdout, p.stderr if p.returncode else ""

try:
    mode = sys.argv[1]
    path = os.path.expanduser(sys.argv[2])
except IndexError:
    out(error="bad arguments")

top, err = git(path, "rev-parse", "--show-toplevel")
top = top.strip()
if not top:
    out(error="Not a git repository: %s" % path)

def base_branch():
    """The branch this work is meant to land on."""
    head = git(top, "rev-parse", "--abbrev-ref", "HEAD")[0].strip()
    # What the remote says its default is, when it's been fetched.
    origin = git(top, "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD")[0].strip()
    candidates = []
    if origin:
        candidates.append(origin.replace("refs/remotes/", "", 1))
    for name in ("dev", "develop", "main", "master", "trunk"):
        candidates += ["origin/" + name, name]
    seen = set()
    for c in candidates:
        if c in seen or c == head or c == "origin/" + head:
            continue
        seen.add(c)
        if git(top, "rev-parse", "--verify", "--quiet", c + "^{commit}")[0].strip():
            return c
    return ""

def worktrees():
    raw = git(top, "worktree", "list", "--porcelain")[0]
    items, cur = [], {}
    for line in raw.splitlines():
        if not line.strip():
            if cur: items.append(cur); cur = {}
            continue
        key, _, value = line.partition(" ")
        if key == "worktree": cur["path"] = value
        elif key == "branch": cur["branch"] = value.replace("refs/heads/", "", 1)
        elif key == "detached": cur["branch"] = "(detached)"
        elif key == "bare": cur["branch"] = "(bare)"
    if cur: items.append(cur)
    return items

if mode == "repo":
    head = git(top, "rev-parse", "--abbrev-ref", "HEAD")[0].strip()
    base = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else base_branch()
    against = ""
    if base:
        against = git(top, "merge-base", base, "HEAD")[0].strip() or base
    files = []
    # Working tree against the branch point: committed work on this branch *and*
    # anything not committed yet, which is what you actually want to look at.
    numstat = git(top, "diff", "--numstat", against)[0] if against else git(top, "diff", "--numstat", "HEAD")[0]
    status = {}
    name_status = git(top, "diff", "--name-status", against)[0] if against else git(top, "diff", "--name-status", "HEAD")[0]
    for line in name_status.splitlines():
        parts = line.split("\t")
        if len(parts) >= 2:
            status[parts[-1]] = parts[0][:1]
    for line in numstat.splitlines():
        parts = line.split("\t")
        if len(parts) < 3: continue
        added, removed, name = parts[0], parts[1], parts[2]
        binary = added == "-" or removed == "-"
        files.append({"path": name, "added": 0 if binary else int(added),
                      "removed": 0 if binary else int(removed),
                      "status": status.get(name, "M"), "binary": binary})
    for name in git(top, "ls-files", "--others", "--exclude-standard")[0].splitlines():
        full = os.path.join(top, name)
        try:
            with open(full, "rb") as fh:
                data = fh.read(400_000)
            binary = b"\x00" in data[:8000]
            added = 0 if binary else data.count(b"\n")
        except OSError:
            binary, added = True, 0
        files.append({"path": name, "added": added, "removed": 0, "status": "?", "binary": binary})
    files.sort(key=lambda f: f["path"])
    ahead = behind = 0
    if base:
        counts = git(top, "rev-list", "--left-right", "--count", "%s...HEAD" % base)[0].split()
        if len(counts) == 2: behind, ahead = int(counts[0]), int(counts[1])
    out(root=top, branch=head, base=base, against=against, files=files,
        ahead=ahead, behind=behind, worktrees=worktrees(),
        dirty=bool(git(top, "status", "--porcelain")[0].strip()))

if mode == "patch":
    against = sys.argv[3] if len(sys.argv) > 3 else ""
    name = sys.argv[4] if len(sys.argv) > 4 else ""
    args = ["diff", "--no-color", "--find-renames"]
    if against: args.append(against)
    if name:
        full = os.path.join(top, name)
        tracked = git(top, "ls-files", "--error-unmatch", name)[0].strip()
        if not tracked and os.path.exists(full):
            text = git(top, "diff", "--no-color", "--no-index", "/dev/null", full)[0]
            out(patch=text[:800_000])
        args += ["--", name]
    text = git(top, *args)[0]
    out(patch=text[:800_000])

out(error="unknown mode %s" % mode)
"""#
}

/// The tag that puts a repository's diff in a tile: `diff#<host>#<path>`.
enum DiffTile {
    static func tag(host: String, path: String) -> String { "diff#\(host)#\(path)" }

    static func resolve(_ tag: String) -> (host: String, path: String)? {
        guard tag.hasPrefix("diff#") else { return nil }
        let rest = tag.dropFirst(5)
        guard let hash = rest.firstIndex(of: "#") else { return nil }
        return (String(rest[..<hash]), String(rest[rest.index(after: hash)...]))
    }
}

/// One `DiffStore` per repository path, so switching tiles doesn't re-fetch.
@MainActor
final class DiffStores {
    static let shared = DiffStores()
    private var stores: [String: DiffStore] = [:]

    func store(host: String, path: String) -> DiffStore {
        let key = host + "\u{1}" + path
        if let existing = stores[key] { return existing }
        let store = DiffStore(remote: Remote(host: host), path: path)
        stores[key] = store
        return store
    }
}
