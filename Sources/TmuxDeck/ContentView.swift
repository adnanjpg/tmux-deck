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

    enum RenameTarget: Identifiable {
        case window(TmuxWindow), session(String)
        var id: String {
            switch self {
            case .window(let w): "w" + w.id
            case .session(let s): "s" + s
            }
        }
    }

    @AppStorage("host") private var host = ""

    var body: some View {
        if host.trimmingCharacters(in: .whitespaces).isEmpty {
            SetupView()
        } else {
            main
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
        .navigationSubtitle(model.selectedWindow.map { "\($0.session) · \(Remote.host)" } ?? Remote.host)
        .toolbar { toolbar }
        .alert(renameTitle, isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                switch renaming {
                case .window(let w): model.rename(w, to: renameText)
                case .session(let s): model.renameSession(s, to: renameText)
                case nil: break
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New session", isPresented: $newSessionPrompt) {
            TextField("Name", text: $renameText)
            Button("Create") { model.newSession(named: renameText) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A tmux session is a group of windows, like a project.")
        }
        .confirmationDialog(
            closing?.isPane == true ? "Close this pane?" : "Close “\(closing.map(model.displayTitle) ?? "")”?",
            isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } })
        ) {
            Button(closing?.isPane == true ? "Close pane" : "Close window", role: .destructive) {
                if let closing { closing.isPane ? model.killPane(closing) : model.close(closing) }
            }
        } message: {
            Text("Anything running in it, including a Claude session, will stop.")
        }
        .confirmationDialog(
            "Close session “\(closingSession ?? "")”?",
            isPresented: Binding(get: { closingSession != nil }, set: { if !$0 { closingSession = nil } })
        ) {
            Button("Close session", role: .destructive) { if let closingSession { model.killSession(closingSession) } }
        } message: {
            Text("All of its windows and everything running in them will stop.")
        }
        .alert("Move to a new session", isPresented: Binding(get: { movingToNewSession != nil },
                                                           set: { if !$0 { movingToNewSession = nil } })) {
            TextField("Session name", text: $renameText)
            Button("Move") { if let w = movingToNewSession { model.moveWindowToNewSession(w, name: renameText) } }
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
        List(selection: Binding(get: { model.selection }, set: { model.userSelected($0) })) {
            ForEach(model.sessions) { session in
                Section {
                    ForEach(session.windows) { window in
                        WindowRow(window: window, title: model.displayTitle(window))
                            .tag(window.id)
                            .contextMenu { windowMenu(window) }
                            .draggable(window.id)
                            .dropDestination(for: String.self) { ids, _ in
                                model.handleDrop(ids, onto: window, session: session.name)
                            }
                        ForEach(window.paneItems) { pane in
                            WindowRow(window: pane, title: model.displayTitle(pane), compact: true)
                                .padding(.leading, 20)
                                .tag(pane.id)
                                .contextMenu { paneMenu(pane) }
                                .draggable(pane.id)
                        }
                    }
                } header: {
                    HStack {
                        Text(session.name)
                        Spacer()
                        Menu {
                            sessionMenu(session.name)
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }
                    .contextMenu { sessionMenu(session.name) }
                    .dropDestination(for: String.self) { ids, _ in
                        model.handleDrop(ids, onto: nil, session: session.name)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { statusBar }
        .overlay {
            if model.sessions.isEmpty {
                if model.connected {
                    ContentUnavailableView {
                        Label("No tmux sessions", systemImage: "rectangle.stack")
                    } actions: {
                        Button("Create session") { renameText = "main"; newSessionPrompt = true }
                    }
                } else {
                    ProgressView("Connecting to \(Remote.host)…")
                }
            }
        }
    }

    @ViewBuilder private func windowMenu(_ window: TmuxWindow) -> some View {
        Button("Rename…") { renameText = window.title; renaming = .window(window) }
        Divider()
        Button("Split right") { model.userSelected(window.id); model.split(vertical: false) }
        Button("Split down") { model.userSelected(window.id); model.split(vertical: true) }
        if window.panes > 1 {
            Button("Even out panes") { model.evenLayout(window) }
        }
        Divider()
        Button("Move up") { model.moveWindow(window, by: -1) }
        Button("Move down") { model.moveWindow(window, by: 1) }
        Menu("Move to session") {
            ForEach(model.sessions.map(\.name).filter { $0 != window.session }, id: \.self) { name in
                Button(name) { model.moveWindow(window, toSession: name) }
            }
            Divider()
            Button("New session…") { renameText = ""; movingToNewSession = window }
        }
        Divider()
        Button("Copy all output") { model.userSelected(window.id); model.copyOutput() }
        Button("Show as terminal") { model.userSelected(window.id); model.toggleRawTerminal() }
        Divider()
        Button("Close window…", role: .destructive) { closing = window }
    }

    @ViewBuilder private func paneMenu(_ pane: TmuxWindow) -> some View {
        Button("Move to its own window") { model.breakPane(pane) }
        Menu("Move into window") {
            ForEach(model.sessions) { session in
                Section(session.name) {
                    ForEach(session.windows.filter { $0.windowID != pane.windowID }) { w in
                        Button(model.displayTitle(w)) { model.joinPane(pane, into: w) }
                    }
                }
            }
        }
        Divider()
        Button("Swap with previous pane") { model.swapPane(pane, previous: true) }
        Button("Swap with next pane") { model.swapPane(pane, previous: false) }
        Button(pane.zoomed ? "Unzoom" : "Zoom (fill the window)") { model.toggleZoom(pane) }
        Divider()
        Button("Copy all output") { model.userSelected(pane.id); model.copyOutput() }
        Divider()
        Button("Close pane…", role: .destructive) { closing = pane }
    }

    @ViewBuilder private func sessionMenu(_ session: String) -> some View {
        Button("New Claude window") { model.newWindow(claude: true, in: session) }
        Button("New terminal window") { model.newWindow(claude: false, in: session) }
        Divider()
        Button("Rename session…") { renameText = session; renaming = .session(session) }
        Button("Close session…", role: .destructive) { closingSession = session }
    }

    private var statusBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.connected ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(model.connected ? "Connected to \(Remote.host)" : "Reconnecting…")
                .lineLimit(1)
            Spacer()
            Button {
                renameText = ""
                newSessionPrompt = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New session")
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
                Button("New session…") { renameText = ""; newSessionPrompt = true }
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
                    Section("Window") { windowMenu(window) }
                    if let pane = w.isPane ? w : window.paneItems.first(where: { $0.paneID == window.paneID }) {
                        Section("Pane") { paneMenu(pane) }
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

/// First launch: ask which machine to connect to.
struct SetupView: View {
    @EnvironmentObject private var model: TmuxModel
    @AppStorage("host") private var host = ""
    @State private var draft = ""
    @State private var checking = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "rectangle.stack").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Connect to your tmux machine").font(.title2.weight(.semibold))
            Text("Enter the SSH host you normally use, like the name after `ssh` in your terminal. It must work without a password prompt (an SSH key or agent).")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            TextField("SSH host", text: $draft, prompt: Text("my-server or user@192.168.1.20"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(connect)
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).frame(maxWidth: 420).multilineTextAlignment(.center)
            }
            Button(action: connect) {
                if checking { ProgressView().controlSize(.small) } else { Text("Connect") }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || checking)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func connect() {
        let candidate = draft.trimmingCharacters(in: .whitespaces)
        guard !candidate.isEmpty else { return }
        checking = true
        error = nil
        UserDefaults.standard.set(candidate, forKey: "host")
        Task {
            let result = await Remote.run("command -v tmux >/dev/null && echo ok || echo notmux", timeout: 20)
            checking = false
            let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.ok && out == "ok" {
                host = candidate
                await model.refresh()
            } else {
                UserDefaults.standard.removeObject(forKey: "host")
                error = out == "notmux" ? "Connected, but tmux isn't installed on that machine."
                    : "Couldn't connect: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        }
    }
}
