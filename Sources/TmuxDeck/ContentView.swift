import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: TmuxModel
    @State private var renaming: RenameTarget?
    @State private var renameText = ""
    @State private var closing: TmuxWindow?
    @State private var closingSession: String?
    @State private var newSessionPrompt = false
    @State private var movingToNewSession: TmuxWindow?
    @State private var addingServer = false
    /// The server a menu action applies to (it may not be the one on screen).
    @State private var target: TmuxModel?
    @EnvironmentObject private var app: AppModel

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

    var body: some View {
        main
            .sheet(isPresented: $addingServer) { AddServerView(sheet: true) }
    }

    private var main: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            detail
        }
        .navigationTitle(model.selectedWindow.map(model.displayTitle) ?? "Tmux Deck")
        .navigationSubtitle(model.selectedWindow.map { "\($0.session) · \(model.host)" } ?? model.host)
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
            Button(closing?.isPane == true ? "Close pane" : "Close window", role: .destructive) {
                if let closing { closing.isPane ? acting.killPane(closing) : acting.close(closing) }
            }
        } message: {
            Text("Anything running in it, including a Claude session, will stop.")
        }
        .confirmationDialog(
            "Close session “\(closingSession ?? "")”?",
            isPresented: Binding(get: { closingSession != nil }, set: { if !$0 { closingSession = nil } })
        ) {
            Button("Close session", role: .destructive) { if let closingSession { acting.killSession(closingSession) } }
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
        List(selection: Binding(get: { app.selectionTag }, set: { app.select(tag: $0) })) {
            ForEach(app.servers) { server in
                Section {
                    serverRows(server)
                } header: {
                    ServerHeader(server: server, forwarder: app.forwarders[server.host] ?? PortForwarder(host: server.host),
                                 showName: app.servers.count > 1 || !server.connected,
                                 onNewSession: { target = server; renameText = ""; newSessionPrompt = true },
                                 onRemove: { app.removeServer(server.host) })
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { statusBar }
    }

    @ViewBuilder private func serverRows(_ server: TmuxModel) -> some View {
        let tag = { (id: String) in "\(server.host)#\(id)" }
        if server.sessions.isEmpty {
            if server.connected {
                Button("Create a session") { target = server; renameText = "main"; newSessionPrompt = true }
                    .buttonStyle(.link)
                    .selectionDisabled()
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(server.lastError.map { _ in "Can't connect — retrying" } ?? "Connecting…").foregroundStyle(.secondary)
                }
                .help(server.lastError ?? "")
                .selectionDisabled()
            }
        }
        ForEach(server.sessions) { session in
            HStack {
                Text(session.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
            ForEach(session.windows) { window in
                WindowRow(window: window, title: server.displayTitle(window))
                    .tag(tag(window.id))
                    .contextMenu { windowMenu(window, server) }
                    .draggable(window.id)
                    .dropDestination(for: String.self) { ids, _ in
                        server.handleDrop(ids, onto: window, session: session.name)
                    }
                ForEach(window.paneItems) { pane in
                    WindowRow(window: pane, title: server.displayTitle(pane), compact: true)
                        .padding(.leading, 20)
                        .tag(tag(pane.id))
                        .contextMenu { paneMenu(pane, server) }
                        .draggable(pane.id)
                }
            }
        }
    }

    @ViewBuilder private func windowMenu(_ window: TmuxWindow, _ m: TmuxModel) -> some View {
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
        Button("New Claude window") { m.newWindow(claude: true, in: session) }
        Button("New terminal window") { m.newWindow(claude: false, in: session) }
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
                 : model.connected ? "Connected to \(model.host)" : "Reconnecting…")
                .lineLimit(1)
            Spacer()
            Menu {
                Button("Add server…") { addingServer = true }
                Button("New session on \(model.host)…") { target = model; renameText = ""; newSessionPrompt = true }
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

    @ViewBuilder private var detail: some View {
        if let window = model.selectedWindow {
            Group {
                if model.rawTerminal.contains(window.id) || window.state.isRunningProgram {
                    TerminalPane(controller: model.controller(for: window.session), window: window)
                        .id(window.session)
                } else if let claude = window.claude {
                    ChatView(window: window, store: model.chatStore(for: claude.sessionID))
                        .id(claude.sessionID)
                } else if window.state.isClaude {
                    ProgressView("Starting Claude…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ConsoleView(window: window)
                        .id(window.id)
                }
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
        } else {
            ContentUnavailableView("Pick a window", systemImage: "sidebar.left",
                                   description: Text("Choose a window from the sidebar."))
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("New Claude window") { model.newWindow(claude: true) }
                Button("New terminal window") { model.newWindow(claude: false) }
                Divider()
                Button("New session…") { target = model; renameText = ""; newSessionPrompt = true }
                Button("Add server…") { addingServer = true }
            } label: {
                Label("New", systemImage: "plus")
            } primaryAction: {
                model.newWindow(claude: true)
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
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts = [window.state.label]
        if title != window.folder { parts.append(window.folder) }
        if !compact && window.panes > 1 { parts.append("\(window.panes) panes") }
        if compact && window.zoomed { parts.append("zoomed") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var icon: some View {
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
                error = out == "notmux" ? "Connected, but tmux isn't installed on that machine."
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
    @State private var showingPorts = false
    @State private var confirmRemove = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(server.connected ? Color.green : Color.orange).frame(width: 7, height: 7)
            Text(server.host).font(.headline).foregroundStyle(.primary)
            if forwarder.enabled {
                let f = forwarder
                Button { showingPorts.toggle() } label: {
                    Label("\(f.activePorts.count)", systemImage: "arrow.left.arrow.right")
                        .font(.caption)
                        .foregroundStyle(f.running ? (f.busyPorts.isEmpty ? Color.green : Color.orange) : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help("Port forwarding")
                .popover(isPresented: $showingPorts) { PortsView(forwarder: f) }
            }
            Spacer()
            Menu {
                Button("New session…", action: onNewSession)
                do {
                    let f = forwarder
                    Divider()
                    Toggle("Port forwarding", isOn: Binding(get: { f.enabled }, set: { f.setEnabled($0) }))
                        .disabled(f.ports.isEmpty)
                    if f.enabled { Button("Show forwarded ports…") { showingPorts = true } }
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
        .confirmationDialog("Remove \(server.host)?", isPresented: $confirmRemove) {
            Button("Remove server", role: .destructive, action: onRemove)
        } message: {
            Text("This only disconnects the app. Your tmux sessions keep running on the server.")
        }
    }
}

struct PortsView: View {
    @ObservedObject var forwarder: PortForwarder

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Port forwarding · \(forwarder.host)").font(.headline)
            Text(forwarder.running
                 ? "\(forwarder.activePorts.count) of \(forwarder.ports.count) ports forwarded to this Mac."
                 : "Connecting… (retries every 5 seconds)")
                .font(.callout).foregroundStyle(.secondary)
            if !forwarder.busyPorts.isEmpty {
                Text("\(forwarder.busyPorts.count) ports are already used on this Mac, probably by another SSH session such as VS Code. They'll work once that session closes and forwarding reconnects.")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let e = forwarder.lastError { Text(e).font(.caption).foregroundStyle(.red) }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(forwarder.ports, id: \.self) { port in
                        let busy = forwarder.busyPorts.contains(port)
                        HStack(spacing: 4) {
                            Circle().fill(busy ? Color.orange : (forwarder.running ? Color.green : Color.secondary)).frame(width: 6, height: 6)
                            Text("\(port)").font(.caption.monospacedDigit())
                        }
                        .help(busy ? "Already in use on this Mac" : "localhost:\(port) → \(forwarder.host)")
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .padding(16)
        .frame(width: 340)
    }
}
