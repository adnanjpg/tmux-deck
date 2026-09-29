import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var model: TmuxModel
    @State private var renaming: RenameTarget?
    @State private var renameText = ""
    @State private var closing: TmuxWindow?
    @State private var closingSession: String?
    @State private var newSessionPrompt = false
    @State private var movingToNewSession: TmuxWindow?
    @State private var addingServer = false
    @State private var restoring: TmuxModel?
    @State private var browsingHistory: TmuxModel?
    @ObservedObject private var plain = PlainTerminalStore.shared
    @State private var renamingPlain: PlainTerminal?
    @AppStorage("showPRs") private var showPRs = false
    @AppStorage("showFiles") private var showFiles = false
    /// Collapsed sidebar groups: "host" for a server, "host#session" for a session.
    @AppStorage("collapsedGroups") private var collapsedStore = ""

    private var collapsed: Set<String> { Set(collapsedStore.split(separator: "\n").map(String.init)) }

    private func isExpanded(_ key: String) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(key) }, set: { setExpanded(key, $0) })
    }

    private func setExpanded(_ key: String, _ expanded: Bool) {
        var c = collapsed
        if expanded { c.remove(key) } else { c.insert(key) }
        collapsedStore = c.sorted().joined(separator: "\n")
    }
    /// The server a menu action applies to (it may not be the one on screen).
    @State private var target: TmuxModel?
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var layout = LayoutModel.shared

    enum RenameTarget: Identifiable {
        case window(TmuxWindow), session(String)
        var id: String {
            switch self {
            case .window(let w): "w" + w.id
            case .session(let s): "s" + s
            }
        }
    }

    private var acting: TmuxModel { target ?? model }

    /// Opens the diff for the folder of whatever window is focused.
    private func showChanges() {
        guard let tag = layout.focusedTag, let (server, window) = TileResolver.resolve(tag),
              window.path.hasPrefix("/") else {
            model.flash("Pick a window in a repository first.")
            return
        }
        layout.drop(tag: DiffTile.tag(host: server.host, path: window.path),
                    onto: layout.focused, zone: .right)
    }

    var body: some View {
        main
            .inspector(isPresented: $showPRs) {
                PRPanelHost().inspectorColumnWidth(min: 280, ideal: 340, max: 520)
            }
            .inspector(isPresented: $showFiles) {
                FilePanelHost().inspectorColumnWidth(min: 240, ideal: 320, max: 560)
            }
            .sheet(isPresented: $addingServer) { AddServerView(sheet: true) }
            .sheet(item: $restoring) { server in RestoreView(server: server) }
            .sheet(item: $browsingHistory) { server in
                HistoryView(host: server.host, store: HistoryStores.shared.store(for: server.host))
            }
            .onReceive(NotificationCenter.default.publisher(for: .openHistory)) { _ in
                // ⇧⌘O: the server of whatever tile is focused, else the active one.
                if let tag = layout.focusedTag, let (server, _) = TileResolver.resolve(tag) {
                    browsingHistory = server
                } else {
                    browsingHistory = app.activeServer
                }
            }
            .alert("Rename terminal", isPresented: Binding(get: { renamingPlain != nil }, set: { if !$0 { renamingPlain = nil } })) {
                TextField("Name", text: $renameText)
                Button("Rename") { if let t = renamingPlain { plain.rename(t, to: renameText) } }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(
                layout.confirmClose?.title ?? "",
                isPresented: Binding(get: { layout.confirmClose != nil }, set: { if !$0 { layout.confirmClose = nil } })
            ) {
                Button("Cancel", role: .cancel) { layout.confirmClose = nil }
                    .keyboardShortcut(.cancelAction)
                    .keyboardShortcut(.defaultAction)
                Button(layout.confirmClose?.actionLabel ?? "Close", role: .destructive) { layout.performConfirmedClose() }
                    .keyboardShortcut(.init("\r"), modifiers: [.command])
            } message: {
                Text(layout.confirmClose?.message ?? "")
            }
    }

    private var main: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            detail
        }
        .navigationTitle(model.selectedWindow.map(model.displayTitle) ?? "Tmux Deck")
        .navigationSubtitle(model.selectedWindow.map { w in
            (w.state.isClaude ? "\(w.state.label) · " : "") + "\(w.session) · \(model.displayName)"
        } ?? model.displayName)
        .toolbar { toolbar }
        .alert(renameTitle, isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                switch renaming {
                case .window(let w): acting.rename(w, to: renameText)
                case .session(let s): acting.renameSession(s, to: renameText)
                case nil: break
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New session", isPresented: $newSessionPrompt) {
            TextField("Name", text: $renameText)
            Button("Create") { acting.newSession(named: renameText) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A tmux session is a group of windows, like a project.")
        }
        .confirmationDialog(
            closing?.isPane == true ? "Close this pane?" : "Close “\(closing.map(acting.displayTitle) ?? "")”?",
            isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } })
        ) {
            Button("Cancel", role: .cancel) { closing = nil }
                .keyboardShortcut(.cancelAction)
                .keyboardShortcut(.defaultAction)
            Button(closing?.isPane == true ? "Close pane" : "Close window", role: .destructive) {
                if let closing { closing.isPane ? acting.killPane(closing) : acting.close(closing) }
            }
            .keyboardShortcut(.init("\r"), modifiers: [.command])
        } message: {
            Text("Anything running in it, including a Claude session, will stop.")
        }
        .confirmationDialog(
            "Close session “\(closingSession ?? "")”?",
            isPresented: Binding(get: { closingSession != nil }, set: { if !$0 { closingSession = nil } })
        ) {
            Button("Cancel", role: .cancel) { closingSession = nil }
                .keyboardShortcut(.cancelAction)
                .keyboardShortcut(.defaultAction)
            Button("Close session", role: .destructive) { if let closingSession { acting.killSession(closingSession) } }
                .keyboardShortcut(.init("\r"), modifiers: [.command])
        } message: {
            Text("All of its windows and everything running in them will stop.")
        }
        .alert("Move to a new session", isPresented: Binding(get: { movingToNewSession != nil },
                                                           set: { if !$0 { movingToNewSession = nil } })) {
            TextField("Session name", text: $renameText)
            Button("Move") { if let w = movingToNewSession { acting.moveWindowToNewSession(w, name: renameText) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var renameTitle: String {
        switch renaming {
        case .window: "Rename window"
        case .session: "Rename session"
        case nil: ""
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: Binding(get: { layout.focusedTag ?? app.selectionTag },
                                set: { if let t = $0 { layout.show(t) } })) {
            if plain.enabled || !plain.terminals.isEmpty {
                Section(isExpanded: isExpanded("plain")) {
                    ForEach(plain.terminals) { t in
                        PlainTerminalRow(terminal: t)
                            .tag(t.tag)
                            .draggable(t.tag)
                            .contextMenu {
                                Button("Open to the right") { layout.drop(tag: t.tag, onto: layout.focused, zone: .right) }
                                Button("Open below") { layout.drop(tag: t.tag, onto: layout.focused, zone: .bottom) }
                                if t.assistant != nil {
                                    Button(plain.rawTerminals.contains(t.id) ? "Show as chat" : "Show as terminal") {
                                        plain.toggleRaw(t)
                                    }
                                }
                                Divider()
                                Button("Rename…") { renameText = t.title; renamingPlain = t }
                                Divider()
                                Button("Close terminal", role: .destructive) { layout.confirmClose = .plainTerminal(t, tag: t.tag) }
                            }
                    }
                    if plain.terminals.isEmpty {
                        Button("New terminal") { openPlain(.shell) }.buttonStyle(.link).selectionDisabled()
                    }
                } header: {
                    HStack {
                        Image(systemName: "laptopcomputer").foregroundStyle(.secondary)
                        Text("This Mac · terminals").font(.headline).foregroundStyle(.primary)
                        Spacer()
                        Menu {
                            Button("New terminal") { openPlain(.shell) }
                            Button("New Claude") { openPlain(.claude) }
                            Button("New Codex") { openPlain(.codex) }
                            Divider()
                            Button("Hide this section") { plain.enabled = false }
                                .disabled(!plain.terminals.isEmpty)
                        } label: { Image(systemName: "plus.circle") }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("New plain terminal on this Mac (no tmux)")
                    }
                }
            }
            ForEach(app.servers) { server in
                Section(isExpanded: isExpanded(server.host)) {
                    serverRows(server)
                } header: {
                    ServerHeader(server: server, forwarder: app.forwarders[server.host] ?? PortForwarder(host: server.host),
                                 showName: app.servers.count > 1 || !server.connected,
                                 onNewSession: { target = server; renameText = ""; newSessionPrompt = true },
                                 onRemove: { app.removeServer(server.host) },
                                 onRestore: { restoring = server },
                                 onHistory: { browsingHistory = server },
                                 onCollapseSessions: { collapse in
                                     for sess in server.sessions { setExpanded("\(server.host)#\(sess.name)", !collapse) }
                                 })
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(theme.sidebar == nil ? .automatic : .hidden)
        .background { if let s = theme.sidebar { Color(nsColor: s) } }
        .safeAreaInset(edge: .bottom) { statusBar }
    }

    @ViewBuilder private func serverRows(_ server: TmuxModel) -> some View {
        let tag = { (id: String) in "\(server.host)#\(id)" }
        if server.sessions.isEmpty {
            if server.connected {
                VStack(alignment: .leading, spacing: 6) {
                    if server.noTmuxServer {
                        Text("Connected, but tmux isn't running there yet.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Restore previous sessions…") { restoring = server }
                        .buttonStyle(.link)
                    Button("Past conversations…") { browsingHistory = server }
                        .buttonStyle(.link)
                    Button("Create a session") { target = server; renameText = "main"; newSessionPrompt = true }
                        .buttonStyle(.link)
                }
                .selectionDisabled()
            } else {
                // Say what actually went wrong, rather than hiding it in a tooltip.
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(server.lastError == nil ? "Connecting…" : "Can't connect")
                            .foregroundStyle(.secondary)
                    }
                    if let error = server.lastError {
                        Text(error)
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Try now") { server.retryNow() }
                            .buttonStyle(.link).font(.caption)
                    }
                }
                .selectionDisabled()
            }
        }
        ForEach(server.sessions) { session in
            let key = "\(server.host)#\(session.name)"
            let open = !collapsed.contains(key)
            HStack(spacing: 5) {
                Button {
                    withAnimation(.snappy) { setExpanded(key, !open) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .frame(width: 10)
                        Text(session.name).font(.caption.weight(.semibold))
                        if !open { collapsedSummary(session) }
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(open ? "Collapse" : "Expand")
                Spacer()
                Menu {
                    sessionMenu(session.name, server)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.top, 6)
            .selectionDisabled()
            .contextMenu { sessionMenu(session.name, server) }
            .dropDestination(for: String.self) { ids, _ in
                server.handleDrop(ids, onto: nil, session: session.name)
            }
            ForEach(open ? session.windows : []) { window in
                WindowRow(window: window, title: server.displayTitle(window), done: server.unseenDone.contains(window.id))
                    .tag(tag(window.id))
                    .contextMenu { windowMenu(window, server) }
                    .draggable("\(server.host)#\(window.id)")
                    .dropDestination(for: String.self) { ids, _ in
                        server.handleDrop(ids, onto: window, session: session.name)
                    }
                ForEach(window.paneItems) { pane in
                    WindowRow(window: pane, title: server.displayTitle(pane), compact: true)
                        .padding(.leading, 20)
                        .tag(tag(pane.id))
                        .contextMenu { paneMenu(pane, server) }
                        .draggable("\(server.host)#\(pane.id)")
                }
            }
        }
    }

    /// Opens a new plain terminal (or Claude) on this Mac and shows it.
    private func openPlain(_ kind: PlainTerminal.Kind) {
        let t = plain.new(kind)
        layout.show(t.tag)
    }

    /// What a collapsed session still tells you: how many windows, and whether any need you.
    @ViewBuilder private func collapsedSummary(_ session: TmuxSession) -> some View {
        let states = session.windows.flatMap { [$0] + $0.paneItems }.map(\.state)
        Text("\(session.windows.count)").font(.caption2.monospacedDigit())
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
        if states.contains(.claudeNeedsYou) {
            Circle().fill(.orange).frame(width: 6, height: 6).help("A Claude window needs your answer")
        } else if states.contains(.claudeWorking) {
            Circle().fill(.blue).frame(width: 6, height: 6).help("Claude is working in this session")
        }
    }

    @ViewBuilder private func windowMenu(_ window: TmuxWindow, _ m: TmuxModel) -> some View {
        Button("Open to the right") { layout.drop(tag: "\(m.host)#\(window.id)", onto: layout.focused, zone: .right) }
        Button("Open below") { layout.drop(tag: "\(m.host)#\(window.id)", onto: layout.focused, zone: .bottom) }
        Button("Show changes") {
            layout.drop(tag: DiffTile.tag(host: m.host, path: window.path), onto: layout.focused, zone: .right)
        }
        Toggle("Notify me about this window", isOn: Binding(
            get: { !Notifications.windowMuted(host: m.host, window: window.id) },
            set: { Notifications.setWindowMuted(host: m.host, window: window.id, !$0) }))
        Divider()
        Button("Rename…") { target = m; renameText = window.title; renaming = .window(window) }
        Divider()
        Button("Split right") { m.userSelected(window.id); m.split(vertical: false) }
        Button("Split down") { m.userSelected(window.id); m.split(vertical: true) }
        if window.panes > 1 {
            Button("Even out panes") { m.evenLayout(window) }
        }
        Divider()
        Button("Move up") { m.moveWindow(window, by: -1) }
        Button("Move down") { m.moveWindow(window, by: 1) }
        Menu("Move to session") {
            ForEach(m.sessions.map(\.name).filter { $0 != window.session }, id: \.self) { name in
                Button(name) { m.moveWindow(window, toSession: name) }
            }
            Divider()
            Button("New session…") { target = m; renameText = ""; movingToNewSession = window }
        }
        Divider()
        Button("Copy all output") { m.userSelected(window.id); m.copyOutput() }
        Button("Show as terminal") { m.userSelected(window.id); m.toggleRawTerminal() }
        Divider()
        Button("Close window…", role: .destructive) { target = m; closing = window }
    }

    @ViewBuilder private func paneMenu(_ pane: TmuxWindow, _ m: TmuxModel) -> some View {
        Button("Open to the right") { layout.drop(tag: "\(m.host)#\(pane.id)", onto: layout.focused, zone: .right) }
        Button("Open below") { layout.drop(tag: "\(m.host)#\(pane.id)", onto: layout.focused, zone: .bottom) }
        Divider()
        Button("Move to its own window") { m.breakPane(pane) }
        Menu("Move into window") {
            ForEach(m.sessions) { session in
                Section(session.name) {
                    ForEach(session.windows.filter { $0.windowID != pane.windowID }) { w in
                        Button(m.displayTitle(w)) { m.joinPane(pane, into: w) }
                    }
                }
            }
        }
        Divider()
        Button("Swap with previous pane") { m.swapPane(pane, previous: true) }
        Button("Swap with next pane") { m.swapPane(pane, previous: false) }
        Button(pane.zoomed ? "Unzoom" : "Zoom (fill the window)") { m.toggleZoom(pane) }
        Divider()
        Button("Copy all output") { m.userSelected(pane.id); m.copyOutput() }
        Divider()
        Button("Close pane…", role: .destructive) { target = m; closing = pane }
    }

    @ViewBuilder private func sessionMenu(_ session: String, _ m: TmuxModel) -> some View {
        Button("New Claude window") { m.newWindow(assistant: .claude, in: session) }
        Button("New Codex window") { m.newWindow(assistant: .codex, in: session) }
        Button("New terminal window") { m.newWindow(assistant: nil, in: session) }
        Divider()
        Button("Rename session…") { target = m; renameText = session; renaming = .session(session) }
        Button("Close session…", role: .destructive) { target = m; closingSession = session }
    }

    private var statusBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.connected ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(app.servers.count > 1 ? "\(app.servers.filter(\.connected).count) of \(app.servers.count) servers connected"
                 : model.connected ? "Connected to \(model.displayName)" : "Reconnecting…")
                .lineLimit(1)
            Spacer()
            Menu {
                Button("Add server…") { addingServer = true }
                Button("New Mac terminal (no tmux)") { openPlain(.shell) }
                Button("New Claude on this Mac (no tmux)") { openPlain(.claude) }
                Button("New Codex on this Mac (no tmux)") { openPlain(.codex) }
                Button("New session on \(model.displayName)…") { target = model; renameText = ""; newSessionPrompt = true }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add a server or a session")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .help(model.lastError ?? "")
    }

    // MARK: Detail

    private var detail: some View {
        SplitLayoutView(layout: layout) { leafID, tag in
            tileContent(leafID: leafID, tag: tag)
        }
        .overlay(alignment: .top) {
            if let toast = model.toast {
                Text(toast)
                    .font(.callout)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: model.toast)
        .onAppear {
            if layout.focusedTag == nil, let t = app.selectionTag { layout.show(t) } else { layout.syncSelection() }
        }
        .onChange(of: app.selectionTag) { _, t in
            // First launch: fill the empty tile once a server has a window selected.
            if layout.focusedTag == nil, let t { layout.show(t) }
        }
    }

    @ViewBuilder private func tileContent(leafID: String, tag: String?) -> some View {
        if let tag, let file = FileTile.resolve(tag) {
            FileEditorView(host: file.host, path: file.path).id(tag)
        } else if let tag, let past = PastTile.resolve(tag) {
            PastChatView(host: past.host, assistant: past.assistant,
                         sessionID: past.id, path: past.path)
                .id(tag)
        } else if let tag, let diff = DiffTile.resolve(tag) {
            DiffView(host: diff.host, path: diff.path,
                     store: DiffStores.shared.store(host: diff.host, path: diff.path))
                .id(tag)
        } else if let tag, tag.hasPrefix("plain#") {
            if let t = plain.terminal(forTag: tag) {
                PlainTerminalView(terminal: t).id(t.id)
            } else {
                ContentUnavailableView("Terminal closed", systemImage: "xmark.rectangle")
            }
        } else if let tag, let (server, window) = TileResolver.resolve(tag) {
            windowContent(server: server, window: window, tile: leafID)
                .environmentObject(server)
        } else if let tag, let hash = tag.firstIndex(of: "#"),
                  let server = app.server(String(tag[..<hash])), !server.connected {
            ProgressView("Connecting to \(server.displayName)…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if tag != nil {
            ContentUnavailableView {
                Label("Window closed", systemImage: "xmark.rectangle")
            } description: {
                Text("That window no longer exists. Pick another from the sidebar.")
            } actions: {
                if layout.isSplit { Button("Close tile") { layout.close(leafID) } }
            }
        } else {
            ContentUnavailableView("Pick a window", systemImage: "sidebar.left",
                                   description: Text("Choose a window from the sidebar, or drag one here."))
        }
    }

    @ViewBuilder private func windowContent(server: TmuxModel, window: TmuxWindow, tile: String) -> some View {
        if server.rawTerminal.contains(window.id) || window.state.isRunningProgram {
            // Each tile gets its own terminal, so two windows of one tmux session can sit
            // side by side. Keyed by tile and session: pointing a tile at another session
            // needs a fresh connection, pointing it at another window doesn't.
            TerminalPane(controller: server.controller(forTile: tile, session: window.session), window: window)
                .id(tile + "|" + window.session)
        } else if let claude = window.claude {
            ChatView(window: window, store: server.chatStore(for: claude.sessionID))
                .id(claude.sessionID)
        } else if let codex = window.codex {
            ChatView(window: window, store: server.chatStore(codex: codex))
                .id(codex.sessionID)
        } else if window.state.isClaude {
            ProgressView(window.command.contains("codex") ? "Starting Codex…" : "Starting Claude…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ConsoleView(window: window)
                .id(window.id)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("New Claude window") { model.newWindow(assistant: .claude) }
                Button("New Codex window") { model.newWindow(assistant: .codex) }
                Button("New terminal window") { model.newWindow(assistant: nil) }
                Divider()
                Button("New session…") { target = model; renameText = ""; newSessionPrompt = true }
                Button("Add server…") { addingServer = true }
            } label: {
                Label("New", systemImage: "plus")
            } primaryAction: {
                model.newWindow(assistant: .claude)
            }
            .help("New Claude window (⌘N)")

            Button { model.split(vertical: false) } label: {
                Label("Split right", systemImage: "rectangle.split.2x1")
            }
            .help("Split right (⌘D)")
            Button { model.split(vertical: true) } label: {
                Label("Split down", systemImage: "rectangle.split.1x2")
            }
            .help("Split down (⇧⌘D)")
            Menu {
                if let w = model.selectedWindow {
                    let window = w.isPane ? (model.window(containing: w) ?? w) : w
                    Section("Window") { windowMenu(window, model) }
                    if let pane = w.isPane ? w : window.paneItems.first(where: { $0.paneID == window.paneID }) {
                        Section("Pane") { paneMenu(pane, model) }
                    }
                }
            } label: {
                Label("Window and pane actions", systemImage: "rectangle.3.group")
            }
            .help("Move, split, break out and close windows and panes")

            Toggle(isOn: $showFiles) {
                Label("Files", systemImage: "folder")
            }
            .help("Browse files on this server (⇧⌘E)")

            Button { showChanges() } label: {
                Label("Changes", systemImage: "plusminus")
            }
            .help("What this window's worktree changes, against its base branch (⇧⌘G)")

            Toggle(isOn: $showPRs) {
                Label("Pull requests", systemImage: "arrow.triangle.pull")
            }
            .help("Show your GitHub pull requests (⇧⌘P)")
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Toggle(isOn: Binding(
                get: { model.selectedWindow.map { model.rawTerminal.contains($0.id) } ?? false },
                set: { _ in model.toggleRawTerminal() }
            )) {
                Label("Terminal", systemImage: "apple.terminal")
            }
            .help("Show this window as a raw terminal (⌥⌘T)")
            Button { model.copyOutput() } label: {
                Label("Copy output", systemImage: "doc.on.doc")
            }
            .help("Copy everything in this window (⇧⌘C)")
        }
    }
}

struct WindowRow: View {
    let window: TmuxWindow
    let title: String
    var compact = false
    var done = false

    var body: some View {
        HStack(spacing: 8) {
            icon
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(subtitleColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            StateBadge(state: window.state, done: done, compact: true)
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts = [window.assistant == .codex && !window.state.isClaude ? "Codex" : window.state.label]
        if title != window.folder { parts.append(window.folder) }
        if !compact && window.panes > 1 { parts.append("\(window.panes) panes") }
        if compact && window.zoomed { parts.append("zoomed") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var icon: some View {
        if window.assistant == .codex {
            switch window.state {
            case .claudeWorking:
                Image(systemName: CodingAssistant.codex.systemImage).foregroundStyle(.blue).symbolEffect(.pulse)
            case .claudeNeedsYou:
                Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.orange)
            default:
                Image(systemName: CodingAssistant.codex.systemImage).foregroundStyle(.secondary)
            }
        } else {
            switch window.state {
            case .claudeWorking:
                Image(systemName: "sparkle").foregroundStyle(.blue).symbolEffect(.pulse)
            case .claudeNeedsYou:
                Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.orange)
            case .claudeReady:
                Image(systemName: "sparkle").foregroundStyle(.secondary)
            case .shell:
                Image(systemName: "terminal").foregroundStyle(.secondary)
            case .running:
                Image(systemName: "gearshape").foregroundStyle(.secondary)
            }
        }
    }

    private var subtitleColor: Color {
        switch window.state {
        case .claudeNeedsYou: .orange
        case .claudeWorking: .blue
        default: .secondary
        }
    }
}

/// Adding a server: pick a host from ~/.ssh/config or type one. Also the first-launch screen.
struct AddServerView: View {
    var sheet = false
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var checking = false
    @State private var error: String?
    @State private var forward = false
    private let configured = AppModel.configuredHosts()

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "server.rack").font(.system(size: 40)).foregroundStyle(.secondary)
            Text(sheet ? "Add a server" : "Connect to your tmux machine").font(.title2.weight(.semibold))
            Text("Pick a host from your SSH config or type one. It must connect without a password prompt (an SSH key or agent).")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            if !app.servers.contains(where: { $0.host == Remote.localHost }) {
                Button { draft = Remote.localHost; connect() } label: {
                    Label("This Mac — tmux sessions, no SSH", systemImage: "laptopcomputer")
                        .frame(maxWidth: 300)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .help("Run tmux and Claude sessions on this Mac")
                Text("or a server over SSH:").font(.caption).foregroundStyle(.secondary)
            }
            if !PlainTerminalStore.shared.enabled {
                Button {
                    let t = PlainTerminalStore.shared.new(.shell)
                    LayoutModel.shared.show(t.tag)
                    if sheet { dismiss() }
                } label: {
                    Label("This Mac — plain terminals, no tmux", systemImage: "terminal")
                        .frame(maxWidth: 300)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help("Normal terminals running directly in the app, like Terminal.app tabs")
            }
            let available = configured.filter { h in !app.servers.contains { $0.host == h } }
            if !available.isEmpty {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
                        ForEach(available, id: \.self) { host in
                            Button { draft = host } label: {
                                Label(host, systemImage: "server.rack")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.bordered)
                            .tint(draft == host ? .accentColor : nil)
                        }
                    }
                }
                .frame(maxWidth: 440, maxHeight: 150)
            }
            TextField("SSH host", text: $draft, prompt: Text("my-server or user@192.168.1.20"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(connect)
            Toggle("Run the port forwards from my SSH config for this server", isOn: $forward)
                .disabled(PortForwarder.configuredPorts(draft.trimmingCharacters(in: .whitespaces)).isEmpty)
                .help("Uses the LocalForward lines in ~/.ssh/config for this host")
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).frame(maxWidth: 420).multilineTextAlignment(.center)
            }
            HStack {
                if sheet { Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction) }
                Button(action: connect) {
                    if checking { ProgressView().controlSize(.small) } else { Text("Connect") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || checking)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: sheet ? 520 : nil)
    }

    private func connect() {
        let candidate = draft.trimmingCharacters(in: .whitespaces)
        guard !candidate.isEmpty else { return }
        checking = true
        error = nil
        Task {
            let result = await Remote(host: candidate).run("command -v tmux >/dev/null && echo ok || echo notmux", timeout: 20)
            checking = false
            let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.ok && out == "ok" {
                app.addServer(candidate)
                if forward { app.forwarders[candidate]?.setEnabled(true) }
                if sheet { dismiss() }
            } else {
                error = out == "notmux"
                    ? (candidate == Remote.localHost ? "tmux isn't installed on this Mac. Install it with: brew install tmux"
                                                     : "Connected, but tmux isn't installed on that machine.")
                    : "Couldn't connect: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        }
    }
}

/// A server's heading in the sidebar: its name, connection, port forwarding and menu.
struct ServerHeader: View {
    @ObservedObject var server: TmuxModel
    @ObservedObject var forwarder: PortForwarder
    let showName: Bool
    var onNewSession: () -> Void
    var onRemove: () -> Void
    var onRestore: () -> Void = {}
    var onHistory: () -> Void = {}
    var onCollapseSessions: (Bool) -> Void = { _ in }
    @State private var showingPorts = false
    @State private var confirmRemove = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(server.connected ? Color.green : Color.orange).frame(width: 7, height: 7)
            Text(server.displayName).font(.headline).foregroundStyle(.primary)
            if !forwarder.rules.isEmpty || forwarder.enabled {
                let f = forwarder
                Button { showingPorts.toggle() } label: {
                    Label(f.enabled ? "\(f.forwardedPorts.count)/\(f.activeRules.count)" : "\(f.rules.count)",
                          systemImage: "arrow.left.arrow.right")
                        .font(.caption)
                        .foregroundStyle(!f.enabled ? Color.secondary
                                         : f.running && f.busyPorts.isEmpty ? Color.green : Color.orange)
                }
                .buttonStyle(.borderless)
                .help(f.enabled ? "\(f.forwardedPorts.count) ports forwarded" : "Port forwarding is off")
                .popover(isPresented: $showingPorts) { PortsView(forwarder: f) }
            }
            Spacer()
            Menu {
                Button("New session…", action: onNewSession)
                Button("Past conversations…", action: onHistory)
                Button("Restore previous windows…", action: onRestore)
                Toggle("Notify me about this server", isOn: Binding(
                    get: { !Notifications.serverMuted(server.host) },
                    set: { Notifications.setServerMuted(server.host, !$0) }))
                Button("Collapse all sessions") { withAnimation(.snappy) { onCollapseSessions(true) } }
                Button("Expand all sessions") { withAnimation(.snappy) { onCollapseSessions(false) } }
                do {
                    let f = forwarder
                    Divider()
                    Toggle("Port forwarding", isOn: Binding(get: { f.enabled }, set: { f.setEnabled($0) }))
                    Button("Forwarded ports…") { showingPorts = true }
                }
                Divider()
                Button("Remove server…", role: .destructive) { confirmRemove = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 2)
        .confirmationDialog("Remove \(server.displayName)?", isPresented: $confirmRemove) {
            Button("Cancel", role: .cancel) { confirmRemove = false }
                .keyboardShortcut(.cancelAction)
                .keyboardShortcut(.defaultAction)
            Button("Remove server", role: .destructive, action: onRemove)
                .keyboardShortcut(.init("\r"), modifiers: [.command])
        } message: {
            Text("This only disconnects the app. Your tmux sessions keep running on the server.")
        }
    }
}

/// The ports forwarded for one server: what's running, and adding or switching off rules.
struct PortsView: View {
    @ObservedObject var forwarder: PortForwarder
    @State private var newLocal = ""
    @State private var newHost = "localhost"
    @State private var newRemote = ""
    @State private var addError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Ports · \(forwarder.host)").font(.headline)
                Spacer()
                Toggle("", isOn: Binding(get: { forwarder.enabled }, set: { forwarder.setEnabled($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help("Forward these ports to this Mac")
            }
            Text(status).font(.callout).foregroundStyle(.secondary)
                .lineLimit(3, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)
            Text(forwarder.lastError ?? " ").font(.caption).foregroundStyle(.red)
                .lineLimit(1)

            ScrollView {
                if forwarder.rules.isEmpty {
                    Text("No forwards yet. Add one below, or put LocalForward lines in ~/.ssh/config for \(forwarder.host).")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(forwarder.rules) { rule in
                            row(rule)
                            Divider()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Add a port").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    TextField("3000", text: $newLocal).frame(width: 58)
                        .help("Port on this Mac")
                    Text("→").foregroundStyle(.secondary)
                    TextField("localhost", text: $newHost).frame(width: 96)
                        .help("Host as seen from \(forwarder.host)")
                    Text(":").foregroundStyle(.secondary)
                    TextField("3000", text: $newRemote).frame(width: 58)
                        .help("Port on that host")
                    Button("Add", action: add)
                        .keyboardShortcut(.defaultAction)
                        .disabled(Int(newLocal.trimmingCharacters(in: .whitespaces)) == nil)
                }
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospacedDigit())
                Text(addError ?? " ").font(.caption).foregroundStyle(.red).lineLimit(1)
            }
        }
        .padding(16)
        // A fixed size: a popover that grows or shrinks re-lays out its scroll view, which
        // sends the list back to the top while you're reading it.
        .frame(width: 420, height: 480)
    }

    private var status: String {
        guard forwarder.enabled else {
            return "Forwarding is off. \(forwarder.rules.count) rules ready."
        }
        guard forwarder.running else { return "Connecting… (retries every 5 seconds)" }
        var text = "\(forwarder.forwardedPorts.count) of \(forwarder.activeRules.count) ports reach \(forwarder.host)."
        if !forwarder.busyPorts.isEmpty {
            text += " \(forwarder.busyPorts.count) are already used on this Mac, probably by another SSH session such as VS Code; they'll bind once that closes."
        }
        return text
    }

    @ViewBuilder private func row(_ rule: ForwardRule) -> some View {
        let off = forwarder.disabled.contains(rule.local)
        let busy = forwarder.busyPorts.contains(rule.local)
        let live = forwarder.listening.contains(rule.local)
        HStack(spacing: 8) {
            Circle()
                .fill(off ? Color.secondary.opacity(0.4)
                      : busy ? Color.orange
                      : live ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
            Text("\(rule.local)").font(.callout.monospacedDigit().weight(.medium))
                .frame(width: 52, alignment: .leading)
            Text("→ \(rule.host):\(rule.remote)")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if rule.fromConfig {
                Text("config").font(.caption2).foregroundStyle(.tertiary)
                    .help("From a LocalForward line in ~/.ssh/config")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("http://localhost:\(rule.local)", forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help("Copy http://localhost:\(rule.local)")
            Toggle("", isOn: Binding(get: { !off }, set: { forwarder.setEnabled(rule, $0) }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
            if !rule.fromConfig {
                Button(role: .destructive) { forwarder.remove(rule) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Remove this forward")
            }
        }
        .padding(.vertical, 5)
        .help(busy ? "Port \(rule.local) is already in use on this Mac" : rule.summary)
    }

    private func add() {
        addError = nil
        guard let local = Int(newLocal.trimmingCharacters(in: .whitespaces)), (1...65535).contains(local) else {
            addError = "Enter a local port between 1 and 65535."; return
        }
        let remote = Int(newRemote.trimmingCharacters(in: .whitespaces)) ?? local
        guard (1...65535).contains(remote) else { addError = "Enter a remote port between 1 and 65535."; return }
        forwarder.add(local: local, host: newHost, remote: remote)
        newLocal = ""; newRemote = ""
    }
}

/// Pick which lost windows to bring back.
struct RestoreView: View {
    @ObservedObject var server: TmuxModel
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [TmuxModel.SavedWindow]?
    @State private var chosen: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Restore windows on \(server.displayName)").font(.title3.weight(.semibold))
            Text("Windows that existed before and aren't running now. Claude windows resume their conversation in their original folder; shells open in their folder.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let candidates {
                if candidates.isEmpty {
                    ContentUnavailableView("Nothing to restore", systemImage: "checkmark.circle",
                                           description: Text("Every window the app knows about is running."))
                        .frame(minHeight: 160)
                } else {
                    List {
                        ForEach(Dictionary(grouping: candidates, by: \.session).keys.sorted(), id: \.self) { session in
                            Section("Session \(session)") {
                                ForEach(candidates.filter { $0.session == session }) { c in
                                    Toggle(isOn: Binding(get: { chosen.contains(c.id) },
                                                         set: { if $0 { chosen.insert(c.id) } else { chosen.remove(c.id) } })) {
                                        HStack(spacing: 8) {
                                            Image(systemName: c.isClaude ? "sparkle" : "terminal").foregroundStyle(.secondary).frame(width: 16)
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(title(c)).lineLimit(1)
                                                Text("\(c.isClaude ? "Claude conversation" : c.command) · \((c.path as NSString).lastPathComponent)")
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .frame(minHeight: 240)
                }
            } else {
                ProgressView("Looking for windows to restore…").frame(maxWidth: .infinity, minHeight: 160)
            }
            HStack {
                if let candidates, !candidates.isEmpty {
                    Button(chosen.count == candidates.count ? "Select none" : "Select all") {
                        chosen = chosen.count == candidates.count ? [] : Set(candidates.map(\.id))
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Restore \(chosen.count) window\(chosen.count == 1 ? "" : "s")") {
                    server.restore((candidates ?? []).filter { chosen.contains($0.id) })
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task {
            let found = await server.restoreCandidates()
            candidates = found
            chosen = Set(found.map(\.id))
        }
    }

    private func title(_ c: TmuxModel.SavedWindow) -> String {
        if let id = c.claudeSessionID, let t = server.titles[id] { return t }
        if c.isClaude { return "Claude · \(c.claudeSessionID!.prefix(8))" }
        return c.name
    }
}

/// Working / Needs you / Done, as a small coloured pill (or just the symbol when compact).
struct StateBadge: View {
    let state: WindowState
    var done = false
    var compact = false

    var body: some View {
        switch state {
        case .claudeWorking:
            pill(color: .blue) {
                ProgressView().controlSize(.mini).tint(.blue)
                if !compact { Text("Working") }
            }
            .help("Claude is working")
        case .claudeNeedsYou:
            pill(color: .orange) {
                Image(systemName: "exclamationmark.bubble.fill")
                if !compact { Text("Needs you") }
            }
            .help("Claude is waiting for your answer")
        case .claudeReady where done:
            pill(color: .green) {
                Image(systemName: "checkmark.circle.fill")
                Text("Done")
            }
            .help("Claude finished while you were away")
        case .claudeReady where !compact:
            pill(color: .secondary) { Text("Ready") }
        default:
            EmptyView()
        }
    }

    private func pill<C: View>(color: Color, @ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 4) { c() }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}
