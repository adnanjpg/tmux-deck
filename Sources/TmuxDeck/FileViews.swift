import AppKit
import SwiftUI

// MARK: The browser

/// The Files panel: a tree of the open window's folder on its server, rooted wherever you point it.
struct FilePanel: View {
    @Environment(\.theme) private var theme
    @Environment(\.fonts) private var fonts
    @EnvironmentObject private var app: AppModel
    @ObservedObject var tree: FileTree
    @State private var newFolder = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let error = tree.failed[tree.root] {
                unavailable(error)
            } else {
                List(tree.rows, id: \.id) { row in
                    switch row.kind {
                    case .file(let file):
                        FileRow(file: file, depth: row.depth,
                                isExpanded: tree.expanded.contains(file.path),
                                isLocal: tree.remote.isLocal, host: tree.remote.host,
                                onOpen: { f in
                                    if f.isDirectory { tree.toggle(f) }
                                    else { LayoutModel.shared.show(FileTile.tag(host: tree.remote.host, path: f.path)) }
                                },
                                onSetRoot: { tree.setRoot($0.path) })
                        .equatable()
                    case .loading:
                        HStack {
                            ProgressView().controlSize(.mini)
                            Text("Loading…").font(fonts.caption).foregroundStyle(.secondary)
                        }
                        .padding(.leading, CGFloat(row.depth) * 12 + 18)
                    case .message(let text):
                        Text(text).font(fonts.caption).foregroundStyle(.orange)
                            .padding(.leading, CGFloat(row.depth) * 12 + 18)
                    }
                }
                .listStyle(.sidebar)
                .environment(\.defaultMinListRowHeight, 22)
            }
        }
        .background(theme.panel)
        .task(id: tree.root) { await tree.load(tree.root) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button { tree.goBack() } label: { Image(systemName: "chevron.backward") }
                    .buttonStyle(.borderless)
                    .disabled(!tree.canGoBack)
                    .help("Back to the folder you were in")
                Button { tree.goUp() } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(.borderless)
                    .help("Up one folder")
                Text("Files").font(fonts.headline)
                Spacer()
                if tree.expandingAll { ProgressView().controlSize(.mini) }
                Button { tree.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Reload")
                Menu {
                    Button("Expand all") { Task { await tree.expandAll() } }
                        .disabled(tree.expandingAll)
                    Button("Collapse all") { tree.collapseAll() }
                        .disabled(tree.expanded.isEmpty)
                    Divider()
                    Toggle("Show hidden files", isOn: $tree.showHidden)
                    Divider()
                    if let project = tree.projectRoot {
                        Button("Go to \((project as NSString).lastPathComponent)") { tree.goToProject() }
                            .disabled(tree.atProjectRoot)
                    }
                    Button("Go to home") { tree.setRoot("~") }
                    Button("Go to /") { tree.setRoot("/") }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            breadcrumb
            if tree.truncated {
                Text("Showing the first 250 folders — open the rest as you need them.")
                    .font(fonts.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                TextField("Filter", text: $tree.filter)
                    .textFieldStyle(.roundedBorder)
                    .font(fonts.callout)
                // The two that are worth a click rather than a trip through the menu.
                Button { Task { await tree.expandAll() } } label: {
                    Image(systemName: "rectangle.expand.vertical")
                }
                .buttonStyle(.borderless)
                .disabled(tree.expandingAll)
                .help("Expand all (four levels, up to 250 folders)")
                Button { tree.collapseAll() } label: {
                    Image(systemName: "rectangle.compress.vertical")
                }
                .buttonStyle(.borderless)
                .disabled(tree.expanded.isEmpty)
                .help("Collapse all")
            }
            if let project = tree.projectRoot, !tree.atProjectRoot {
                Button {
                    tree.goToProject()
                } label: {
                    Label("Back to \((project as NSString).lastPathComponent)",
                          systemImage: "arrow.uturn.backward")
                        .font(fonts.caption)
                }
                .buttonStyle(.borderless)
                .help(project)
            }
        }
        .padding(10)
    }

    /// Each folder in the current root, clickable to move the tree up to it.
    private var breadcrumb: some View {
        let parts = tree.root.split(separator: "/").map(String.init)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                Button("/") { tree.setRoot("/") }.buttonStyle(.plain).foregroundStyle(.secondary)
                ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                    Text("/").foregroundStyle(.tertiary)
                    Button(part) { tree.setRoot("/" + parts[0...i].joined(separator: "/")) }
                        .buttonStyle(.plain)
                        .foregroundStyle(i == parts.count - 1 ? Color.primary : .secondary)
                }
            }
            .font(fonts.caption.monospaced())
            .lineLimit(1)
        }
        .frame(height: 16)
    }

    @ViewBuilder private func unavailable(_ error: String) -> some View {
        ContentUnavailableView {
            Label("Can't open that folder", systemImage: "folder.badge.questionmark")
        } description: {
            Text(error)
        } actions: {
            Button("Go to home") { tree.setRoot("~") }
        }
    }

}

/// One line of the tree.
///
/// It deliberately does **not** observe the `FileTree`. With a few hundred folders open there are
/// well over a thousand of these on screen, and any published change — a folder finishing loading,
/// the rows being rebuilt — would invalidate every one of them. It takes plain values and a couple
/// of closures instead, so a row only re-renders when its own inputs change.
private struct FileRow: View, Equatable {
    @Environment(\.fonts) private var fonts
    let file: RemoteFile
    let depth: Int
    let isExpanded: Bool
    let isLocal: Bool
    let host: String
    let onOpen: (RemoteFile) -> Void
    let onSetRoot: (RemoteFile) -> Void

    static func == (a: FileRow, b: FileRow) -> Bool {
        a.file == b.file && a.depth == b.depth && a.isExpanded == b.isExpanded
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 5) {
                if file.isDirectory {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                } else {
                    Spacer().frame(width: 10)
                }
                Image(systemName: file.icon)
                    .foregroundStyle(file.isDirectory ? Color.accentColor : .secondary)
                    .frame(width: 14)
                Text(file.name)
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(file.isHidden ? .secondary : .primary)
                Spacer(minLength: 4)
                if !file.isDirectory {
                    Text(file.sizeLabel).font(fonts.caption2).foregroundStyle(.tertiary)
                }
            }
            .font(fonts.callout)
            .padding(.leading, CGFloat(depth) * 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if file.isDirectory {
                Button("Open as root") { onSetRoot(file) }
            } else {
                Button("Open") { open() }
                Button("Open to the right") {
                    LayoutModel.shared.drop(tag: tag, onto: LayoutModel.shared.focused, zone: .right)
                }
                Button("Open below") {
                    LayoutModel.shared.drop(tag: tag, onto: LayoutModel.shared.focused, zone: .bottom)
                }
            }
            Divider()
            Button("Copy path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path, forType: .string)
            }
            if isLocal {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
                }
            }
        }
    }

    private var tag: String { FileTile.tag(host: host, path: file.path) }

    private func open() { onOpen(file) }
}

// MARK: The viewer / editor

/// A remote file in a tile: read it, edit it, save it back.
struct FileEditorView: View {
    @Environment(\.theme) private var theme
    @Environment(\.fonts) private var fonts
    let host: String
    let path: String

    @State private var text = ""
    @State private var original = ""
    @State private var digest = ""
    @State private var state: Load = .loading
    @State private var message: String?
    @State private var saving = false
    @State private var conflict = false

    private enum Load { case loading, ready, failed(String) }

    private var tree: FileTree { FileBrowsers.shared.tree(for: host) }
    private var dirty: Bool { text != original }
    private var name: String { (path as NSString).lastPathComponent }

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider()
            switch state {
            case .loading:
                ProgressView("Opening \(name)…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let error):
                ContentUnavailableView {
                    Label("Can't open this file", systemImage: "doc.questionmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { Task { await load() } }
                }
            case .ready:
                CodeEditor(text: $text, theme: theme, font: fonts.nsMono)
                    .background(Color(nsColor: theme.terminalBackground ?? theme.background))
            }
        }
        .background(theme.bg)
        .task(id: path) { await load() }
        .confirmationDialog("This file changed on the server", isPresented: $conflict) {
            Button("Cancel", role: .cancel) { conflict = false }
                .keyboardShortcut(.cancelAction)
                .keyboardShortcut(.defaultAction)
            Button("Reload and lose my changes", role: .destructive) { Task { await load() } }
            Button("Overwrite it", role: .destructive) { Task { await save(force: true) } }
                .keyboardShortcut(.init("\r"), modifiers: [.command])
        } message: {
            Text("Something else wrote to \(name) since you opened it — probably the assistant working in this folder.")
        }
    }

    private var bar: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(name).font(fonts.callout.weight(.semibold)).lineLimit(1)
                    if dirty { Circle().fill(Color.orange).frame(width: 6, height: 6) }
                }
                Text(folderLabel).font(fonts.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 8)
            if let message {
                Text(message).font(fonts.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if saving { ProgressView().controlSize(.small) }
            Button("Reload") { Task { await load() } }
                .disabled(saving)
                .help(dirty ? "Throw away your changes and read the file again" : "Read the file again")
            Button("Save") { Task { await save() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(!dirty || saving)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.panel)
    }

    private var folderLabel: String {
        let folder = (path as NSString).deletingLastPathComponent
        return host == Remote.localHost ? folder : "\(host) · \(folder)"
    }

    private func load() async {
        conflict = false
        if case .ready = state {} else { state = .loading }
        switch await tree.read(path) {
        case .success(let file):
            text = file.text
            original = file.text
            digest = file.digest
            state = .ready
            flash(nil)
        case .failure(let error):
            state = .failed(error.message)
        }
    }

    private func save(force: Bool = false) async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        conflict = false
        switch await tree.write(path, text: text, expecting: force ? "" : digest) {
        case .success(let newDigest):
            digest = newDigest
            original = text
            flash("Saved")
        case .failure(let error):
            if error.message.contains("changed on the server") {
                conflict = true
            } else {
                flash(error.message)
            }
        }
    }

    private func flash(_ text: String?) {
        message = text
        guard text != nil else { return }
        Task {
            try? await Task.sleep(for: .seconds(3))
            if message == text { message = nil }
        }
    }
}

/// An editable text view with the theme's colours and lazy syntax highlighting.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    let theme: AppTheme
    let font: NSFont

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let tv = ClickThroughTextView()
        tv.delegate = context.coordinator
        tv.isEditable = true
        tv.isSelectable = true
        tv.isRichText = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.textContainerInset = NSSize(width: 12, height: 12)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = tv
        context.coordinator.textView = tv
        apply(to: tv, context: context, full: true)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView else { return }
        let replace = tv.string != text
        if replace { tv.string = text }
        apply(to: tv, context: context, full: replace)
    }

    private func apply(to tv: NSTextView, context: Context, full: Bool) {
        tv.font = font
        tv.backgroundColor = theme.terminalBackground ?? theme.background
        tv.textColor = theme.terminalForeground ?? theme.foreground ?? .textColor
        tv.insertionPointColor = theme.terminalCursor ?? theme.accent
        tv.selectedTextAttributes = [.backgroundColor: theme.terminalSelection ?? .selectedTextBackgroundColor]
        if full { context.coordinator.highlight() }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        weak var textView: NSTextView?
        private var pending: Task<Void, Never>?

        init(_ parent: CodeEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            // Re-colouring on every keystroke is far too slow on a big file; settle first.
            pending?.cancel()
            pending = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                self?.highlight()
            }
        }

        /// Paints the theme's token colours onto the text storage, keeping the selection.
        func highlight() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let code = storage.string
            guard code.count < 400_000 else { return }   // too big to be worth it
            let colored = NSAttributedString(SyntaxHighlighter.highlight(code, theme: parent.theme))
            let selected = tv.selectedRanges
            storage.beginEditing()
            storage.setAttributes([.font: parent.font,
                                   .foregroundColor: parent.theme.terminalForeground ?? parent.theme.foreground ?? .textColor],
                                  range: NSRange(location: 0, length: storage.length))
            colored.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: colored.length)) { value, range, _ in
                guard let color = value as? NSColor, range.upperBound <= storage.length else { return }
                storage.addAttribute(.foregroundColor, value: color, range: range)
            }
            storage.endEditing()
            tv.selectedRanges = selected
        }
    }
}


/// Keeps the Files panel pointed at whatever window you're looking at: its server, and its
/// folder the first time you open the panel for that server.
struct FilePanelHost: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var layout = LayoutModel.shared
    @State private var rooted: Set<String> = []

    var body: some View {
        let host = currentHost
        let tree = FileBrowsers.shared.tree(for: host)
        FilePanel(tree: tree)
            .id(host)
            .onAppear { follow(tree) }
            .onChange(of: layout.focusedTag) { _, _ in follow(tree) }
            // The sidebar may not have resolved the window yet on the first appearance; try a
            // few more times rather than polling forever, which rebuilt the panel every second.
            .task(id: host) {
                for _ in 0..<10 {
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                    follow(tree)
                    if rooted.contains(host) { return }
                }
            }
    }

    private var currentHost: String {
        if let tag = layout.focusedTag {
            if let file = FileTile.resolve(tag) { return file.host }
            if tag.hasPrefix("plain#") { return Remote.localHost }
            if let (server, _) = TileResolver.resolve(tag) { return server.host }
        }
        return app.activeServer?.host ?? Remote.localHost
    }

    /// Opens at the folder of the window you're looking at — the whole point is to browse what
    /// the assistant is working on. Only the first time for a given server, so moving around the
    /// tree afterwards isn't undone every time the focus changes. Until a window can be resolved
    /// (the sidebar may still be loading) this keeps trying.
    private func follow(_ tree: FileTree) {
        guard let tag = layout.focusedTag, let (_, window) = TileResolver.resolve(tag),
              window.path.hasPrefix("/") else {
            if !rooted.contains(tree.remote.host) { Task { await tree.load(tree.root) } }
            return
        }
        // Always keep "back to the project" pointing at the window you're looking at, even
        // once you've wandered off to ~ or /.
        if tree.projectRoot != window.path { tree.projectRoot = window.path }
        guard rooted.insert(tree.remote.host).inserted else { return }
        tree.setRoot(window.path, remember: false)
    }
}
