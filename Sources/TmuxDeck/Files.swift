import AppKit
import SwiftUI

/// Why a file operation didn't work, in words meant for the person reading them.
struct FileError: Error, Equatable {
    var message: String
    init(_ message: String) { self.message = message }
}

/// One entry in a remote folder.
struct RemoteFile: Identifiable, Hashable {
    var name: String
    var path: String
    var isDirectory: Bool
    var size: Int
    var modified: Double
    var isLink: Bool

    var id: String { path }
    var isHidden: Bool { name.hasPrefix(".") }

    var sizeLabel: String {
        guard !isDirectory else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    var icon: String {
        if isDirectory { return "folder" }
        switch (path as NSString).pathExtension.lowercased() {
        case "swift", "py", "js", "ts", "tsx", "jsx", "rb", "go", "rs", "java", "kt", "c", "h", "cpp", "cs", "sh", "zsh":
            return "chevron.left.forwardslash.chevron.right"
        case "md", "txt", "rst", "adoc": return "doc.text"
        case "json", "yaml", "yml", "toml", "ini", "cfg", "conf", "plist", "xml": return "list.bullet.rectangle"
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "pdf": return "photo"
        case "zip", "gz", "tar", "tgz", "bz2", "xz", "7z": return "shippingbox"
        default: return "doc"
        }
    }

    /// Files the viewer won't try to open as text.
    var isProbablyBinary: Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic", "pdf", "zip", "gz", "tar", "tgz", "bz2", "xz",
         "7z", "so", "dylib", "a", "o", "class", "jar", "wasm", "bin", "exe", "dmg", "sqlite", "db",
         "mp4", "mov", "mp3", "wav", "ico", "ttf", "otf", "woff", "woff2"]
            .contains((path as NSString).pathExtension.lowercased())
    }
}

/// Browses one server's filesystem over the same SSH connection everything else uses.
///
/// Folders are listed on demand and cached, so expanding a tree doesn't re-walk it. The listing,
/// reading and writing all go through one small Python program (already a dependency for the chat
/// view) rather than a pile of shell quoting.
@MainActor
final class FileTree: ObservableObject {
    let remote: Remote

    @Published private(set) var children: [String: [RemoteFile]] = [:]
    @Published private(set) var loading: Set<String> = []
    @Published private(set) var failed: [String: String] = [:]
    @Published var expanded: Set<String> = []
    @Published var root: String = "~"
    @Published var showHidden = false
    @Published var filter = ""
    /// The folder the window this panel is following is working in. Wandering off to ~ or / is
    /// easy; this is what gets you back.
    @Published var projectRoot: String?
    @Published private(set) var expandingAll = false

    /// Roots you've been at, so Back works like a browser's.
    private var history: [String] = []
    var canGoBack: Bool { !history.isEmpty }

    init(remote: Remote) { self.remote = remote }

    func entries(_ path: String) -> [RemoteFile] {
        let all = children[path] ?? []
        let visible = showHidden ? all : all.filter { !$0.isHidden }
        guard !filter.isEmpty else { return visible }
        return visible.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    func toggle(_ file: RemoteFile) {
        guard file.isDirectory else { return }
        if expanded.contains(file.path) {
            expanded.remove(file.path)
        } else {
            expanded.insert(file.path)
            Task { await load(file.path) }
        }
    }

    /// Moves the tree's root, keeping anything already listed.
    func setRoot(_ path: String, remember: Bool = true) {
        guard path != root else { return }
        if remember {
            history.append(root)
            if history.count > 50 { history.removeFirst() }
        }
        root = path
        expanded = []
        Task { await load(path, force: true) }
    }

    func goBack() {
        guard let previous = history.popLast() else { return }
        setRoot(previous, remember: false)
    }

    /// Up one folder, which the breadcrumb can't do once you're at the top of it.
    func goUp() {
        let parent = (root as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != root else { return }
        setRoot(parent)
    }

    func goToProject() {
        guard let projectRoot else { return }
        setRoot(projectRoot)
    }

    var atProjectRoot: Bool { projectRoot == root }

    // MARK: Expanding

    func collapseAll() {
        expanded = []
    }

    /// Expands the tree, listing folders as it goes.
    ///
    /// Bounded on purpose: a project with `node_modules` or a virtualenv in it has tens of
    /// thousands of folders, and walking all of them over SSH would take minutes and be useless
    /// to look at. It goes four levels deep and stops after 250 folders, leaving the rest to be
    /// opened by hand.
    func expandAll() async {
        guard !expandingAll else { return }
        expandingAll = true
        defer { expandingAll = false }
        var opened: Set<String> = []
        var level = [root]
        for _ in 0..<4 {
            await load(level)
            var next: [String] = []
            for folder in level {
                for file in children[folder] ?? [] where file.isDirectory && !file.isLink {
                    if !showHidden && file.isHidden { continue }
                    guard opened.count < 250 else { break }
                    opened.insert(file.path)
                    next.append(file.path)
                }
            }
            expanded = opened
            if next.isEmpty || opened.count >= 250 { break }
            level = next
        }
        expanded = opened
    }

    func refresh() {
        let open = [root] + Array(expanded)
        Task { for path in open { await load(path, force: true) } }
    }

    /// Lists several folders in one round trip. Anything already known is skipped unless forced.
    func load(_ paths: [String], force: Bool = false) async {
        let wanted = paths.filter { force || children[$0] == nil }
            .filter { !loading.contains($0) }
        guard !wanted.isEmpty else { return }
        if wanted.count == 1 { await load(wanted[0], force: force); return }
        loading.formUnion(wanted)
        defer { loading.subtract(wanted) }
        let args = wanted.map(sq).joined(separator: " ")
        let result = await remote.run("python3 - list \(args)", input: Self.helper, timeout: 60)
        guard result.ok, let data = result.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let folders = obj["folders"] as? [[String: Any]] else { return }
        for folder in folders {
            let asked = folder["asked"] as? String ?? folder["path"] as? String ?? ""
            if let error = folder["error"] as? String {
                failed[asked] = error
                continue
            }
            failed[asked] = nil
            store(folder, asked: asked)
        }
    }

    func load(_ path: String, force: Bool = false) async {
        if !force, children[path] != nil { return }
        guard !loading.contains(path) else { return }
        loading.insert(path)
        defer { loading.remove(path) }
        let result = await remote.run("python3 - list \(sq(path))", input: Self.helper, timeout: 20)
        guard result.ok,
              let data = result.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            failed[path] = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Couldn't read that folder." : result.stderr
            return
        }
        if let error = obj["error"] as? String {
            failed[path] = error
            return
        }
        failed[path] = nil
        store(obj, asked: path)
    }

    private func store(_ obj: [String: Any], asked path: String) {
        let real = obj["path"] as? String ?? path
        let raw = obj["items"] as? [[String: Any]] ?? []
        var items: [RemoteFile] = []
        items.reserveCapacity(raw.count)
        for item in raw {
            let name = item["n"] as? String ?? "?"
            let full = (real as NSString).appendingPathComponent(name)
            items.append(RemoteFile(name: name,
                                    path: full,
                                    isDirectory: item["d"] as? Bool ?? false,
                                    size: item["s"] as? Int ?? 0,
                                    modified: item["m"] as? Double ?? 0,
                                    isLink: item["l"] as? Bool ?? false))
        }
        items.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        children[path] = items
        if real != path {
            children[real] = items
            if root == path { root = real }
        }
    }

    /// Reads a file. Returns its text and a digest used to detect edits made elsewhere.
    func read(_ path: String) async -> Result<(text: String, digest: String), FileError> {
        let result = await remote.run("python3 - read \(sq(path))", input: Self.helper, timeout: 60)
        guard result.ok, let data = result.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(FileError(message.isEmpty ? "Couldn't read that file." : message))
        }
        if let error = obj["error"] as? String { return .failure(FileError(error)) }
        return .success((obj["text"] as? String ?? "", obj["digest"] as? String ?? ""))
    }

    /// Writes a file, but only if it still matches `expecting` — someone else (or the assistant)
    /// may have changed it since it was read, and silently clobbering that would be the worst
    /// possible behaviour for a tool that sits next to a coding agent.
    func write(_ path: String, text: String, expecting digest: String) async -> Result<String, FileError> {
        let result = await remote.run("python3 - write \(sq(path)) \(sq(digest))",
                                      input: Self.helper + "\n#--BODY--\n" + text, timeout: 60)
        guard result.ok, let data = result.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(FileError(message.isEmpty ? "Couldn't save that file." : message))
        }
        if let error = obj["error"] as? String { return .failure(FileError(error)) }
        return .success(obj["digest"] as? String ?? "")
    }

    /// `python3 - <list|read|write> <path> [digest]`, with the new contents after a `#--BODY--`
    /// line on stdin for a write (the program itself arrives on stdin, so they share it).
    static let helper = #"""
import hashlib, json, os, sys

MAX = 4_000_000

def out(**d):
    print(json.dumps(d))
    sys.exit()

def digest_of(data):
    return hashlib.sha256(data).hexdigest()

try:
    mode = sys.argv[1]
    path = os.path.expanduser(sys.argv[2])
except IndexError:
    out(error="bad arguments")

def listing(target, asked=None):
    asked = asked if asked is not None else target
    if not os.path.isdir(target):
        return {"asked": asked, "path": target, "error": "Not a folder: %s" % target}
    items = []
    try:
        for e in os.scandir(target):
            try:
                st = e.stat(follow_symlinks=False)
            except OSError:
                continue
            items.append({"n": e.name, "d": e.is_dir(), "s": st.st_size,
                          "m": st.st_mtime, "l": e.is_symlink()})
    except PermissionError:
        return {"asked": asked, "path": target, "error": "No permission to read %s" % target}
    except OSError as exc:
        return {"asked": asked, "path": target, "error": str(exc)}
    return {"asked": asked, "path": os.path.realpath(target), "items": items}

if mode == "list":
    # Several folders in one go: expanding a tree over SSH one round trip per folder is
    # unusable on a slow link.
    # The caller keys its cache by the string it asked for, so echo that back rather than the
    # expanded path — "~" and "/home/you" must not become two entries.
    asked = sys.argv[2:]
    if len(asked) == 1:
        result = listing(os.path.expanduser(asked[0]), asked[0])
        if "error" in result:
            out(error=result["error"])
        out(path=result["path"], items=result["items"])
    out(folders=[listing(os.path.expanduser(a), a) for a in asked])

if mode == "read":
    if not os.path.isfile(path):
        out(error="Not a file: %s" % path)
    size = os.path.getsize(path)
    if size > MAX:
        out(error="That file is %.1f MB; too big to open here." % (size / 1_000_000))
    with open(path, "rb") as fh:
        data = fh.read()
    if b"\x00" in data[:8000]:
        out(error="That looks like a binary file.")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        out(error="That file isn't UTF-8 text.")
    out(text=text, digest=digest_of(data))

if mode == "write":
    expected = sys.argv[3] if len(sys.argv) > 3 else ""
    body = sys.stdin.read()
    marker = "\n#--BODY--\n"
    i = body.find(marker)
    if i < 0:
        out(error="nothing to write")
    text = body[i + len(marker):]
    if os.path.exists(path):
        with open(path, "rb") as fh:
            current = fh.read()
        if expected and digest_of(current) != expected:
            out(error="This file changed on the server since you opened it. Reload to see the new version.")
    data = text.encode("utf-8")
    tmp = path + ".tmxdeck.tmp"
    try:
        with open(tmp, "wb") as fh:
            fh.write(data)
        if os.path.exists(path):
            os.chmod(tmp, os.stat(path).st_mode & 0o7777)
        os.replace(tmp, path)
    except OSError as exc:
        try: os.unlink(tmp)
        except OSError: pass
        out(error=str(exc))
    out(digest=digest_of(data))

out(error="unknown mode %s" % mode)
"""#
}

/// One `FileTree` per server.
@MainActor
final class FileBrowsers {
    static let shared = FileBrowsers()
    private var trees: [String: FileTree] = [:]

    func tree(for host: String) -> FileTree {
        if let existing = trees[host] { return existing }
        let tree = FileTree(remote: Remote(host: host))
        trees[host] = tree
        return tree
    }
}

/// The tag that puts a file in a tile: `file#<host>#<path>`.
enum FileTile {
    static func tag(host: String, path: String) -> String { "file#\(host)#\(path)" }

    static func resolve(_ tag: String) -> (host: String, path: String)? {
        guard tag.hasPrefix("file#") else { return nil }
        let rest = tag.dropFirst(5)
        guard let hash = rest.firstIndex(of: "#") else { return nil }
        return (String(rest[..<hash]), String(rest[rest.index(after: hash)...]))
    }
}
