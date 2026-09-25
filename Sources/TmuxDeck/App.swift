import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct TmuxDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var app = AppModel.shared

    /// Menu commands act on the server you're looking at.
    private var model: TmuxModel? { app.activeServer }

    var body: some Scene {
        Window("Tmux Deck", id: "main") {
            RootView()
                .environmentObject(app)
                .frame(minWidth: 820, minHeight: 480)
                .onAppear { app.start() }
        }
        .defaultSize(width: 1400, height: 860)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Claude window") { model?.newWindow(claude: true) }
                    .keyboardShortcut("n")
                Button("New terminal window") { model?.newWindow(claude: false) }
                    .keyboardShortcut("t")
            }
            CommandGroup(after: .sidebar) {
                Button("Choose Theme…") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
                Button("Toggle Full Screen") { AppDelegate.toggleFullScreen() }
                    .keyboardShortcut("f", modifiers: [.command, .control])
            }
            CommandMenu("Tmux") {
                Button("Split right") { model?.split(vertical: false) }
                    .keyboardShortcut("d")
                Button("Split down") { model?.split(vertical: true) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Close other tiles") { LayoutModel.shared.unsplit() }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                Button("Show as terminal") { model?.toggleRawTerminal() }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                Divider()
                Button("Copy all output") { model?.copyOutput() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Divider()
                Button("Previous window") { model?.selectRelative(-1) }
                    .keyboardShortcut("[")
                Button("Next window") { model?.selectRelative(1) }
                    .keyboardShortcut("]")
                ForEach(1..<10) { n in
                    Button("Go to window \(n)") { model?.selectNumber(n) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")))
                }
            }
        }

        Settings {
            TabView {
                SettingsView().tabItem { Label("General", systemImage: "gearshape") }
                ThemeSettings().tabItem { Label("Themes", systemImage: "paintpalette") }
            }
            .frame(width: 560)
        }
    }
}

/// Shows the first-launch screen until a server is added, then the main window
/// for the active server.
struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var themes = ThemeManager.shared

    var body: some View {
        let theme = themes.theme
        Group {
            if let server = app.activeServer {
                ContentView()
                    .environmentObject(server)
            } else {
                AddServerView()
            }
        }
        .environment(\.theme, theme)
        .tint(theme.tint)
        .foregroundStyle(theme.fg ?? Color.primary)
        .preferredColorScheme(theme.isDark.map { $0 ? .dark : .light })
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Make sure the main window can go full screen (green button, ⌃⌘F).
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            (note.object as? NSWindow)?.collectionBehavior.insert(.fullScreenPrimary)
        }
    }

    @MainActor static func toggleFullScreen() {
        let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
        window?.collectionBehavior.insert(.fullScreenPrimary)
        window?.toggleFullScreen(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.stopAll() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct SettingsView: View {
    @AppStorage("fontSize") private var fontSize = 13.0
    @AppStorage("sound.finish.on") private var finishOn = true
    @AppStorage("sound.finish.name") private var finishSound = "Glass"
    @AppStorage("sound.question.on") private var questionOn = true
    @AppStorage("sound.question.name") private var questionSound = "Ping"

    var body: some View {
        Form {
            Section("Sounds") {
                soundRow("When Claude finishes", on: $finishOn, name: $finishSound)
                soundRow("When Claude asks you something", on: $questionOn, name: $questionSound)
            }
            Section("Servers") {
                Text("Add servers with the + button at the bottom of the sidebar. Each server's ••• menu has port forwarding and Remove.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Terminal") {
                Stepper("Font size: \(Int(fontSize)) pt", value: $fontSize, in: 9...24)
                Text("Applies the next time you open the app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }

    private func soundRow(_ label: String, on: Binding<Bool>, name: Binding<String>) -> some View {
        HStack {
            Toggle(label, isOn: on)
            Spacer()
            Picker("", selection: name) {
                ForEach(Sounds.available, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(!on.wrappedValue)
            .onChange(of: name.wrappedValue) { _, new in Sounds.preview(new) }
            Button { Sounds.preview(name.wrappedValue) } label: { Image(systemName: "speaker.wave.2") }
                .buttonStyle(.borderless)
                .help("Play")
        }
    }
}

/// Pick a VS Code theme (built-in, from extensions, or imported), match VS Code, or use System.
struct ThemeSettings: View {
    @ObservedObject private var themes = ThemeManager.shared
    @State private var search = ""
    @State private var importError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search themes", text: $search).textFieldStyle(.roundedBorder)
                Button("Import…", action: importTheme)
                    .help("Import a VS Code theme .json file or a .vsix extension")
                Button { themes.scan() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Look for newly installed themes")
            }
            if let importError { Text(importError).font(.caption).foregroundStyle(.red) }
            List {
                Section {
                    row(title: "System", subtitle: "Plain macOS light and dark", id: "system", preview: nil)
                    row(title: "Match VS Code",
                        subtitle: "Follows VS Code's current theme" + (ThemeManager.vscodeColorTheme().map { " (\($0))" } ?? ""),
                        id: "vscode", preview: nil)
                }
                let filtered = themes.available.filter { search.isEmpty || $0.label.localizedCaseInsensitiveContains(search) || $0.source.localizedCaseInsensitiveContains(search) }
                let light = filtered.filter { !$0.isDark }, dark = filtered.filter(\.isDark)
                if !light.isEmpty {
                    Section("Light") { ForEach(light) { t in row(title: t.label, subtitle: t.source, id: t.id, preview: t) } }
                }
                if !dark.isEmpty {
                    Section("Dark") { ForEach(dark) { t in row(title: t.label, subtitle: t.source, id: t.id, preview: t) } }
                }
            }
            .frame(minHeight: 380)
            Text("\(themes.available.count) themes from VS Code, Cursor, your installed extensions and imports.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private func row(title: String, subtitle: String, id: String, preview: VSCodeThemeRef?) -> some View {
        Button { themes.select(id) } label: {
            HStack(spacing: 10) {
                if let preview { Swatch(ref: preview) } else {
                    Image(systemName: id == "system" ? "macwindow" : "chevron.left.forwardslash.chevron.right")
                        .frame(width: 44, height: 26)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if themes.selection == id { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, UTType(filenameExtension: "vsix") ?? .zip]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            importError = themes.importTheme(from: url)
        }
    }
}

/// A tiny preview: background, a line of text, and the accent.
private struct Swatch: View {
    let ref: VSCodeThemeRef
    @State private var theme: AppTheme?

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: theme?.background ?? .windowBackgroundColor))
            VStack(alignment: .leading, spacing: 3) {
                Capsule().fill(Color(nsColor: theme?.tokenColor("keyword") ?? theme?.accent ?? .gray)).frame(width: 18, height: 3)
                Capsule().fill(Color(nsColor: theme?.foreground ?? .gray)).frame(width: 28, height: 3)
                Capsule().fill(Color(nsColor: theme?.tokenColor("string") ?? .gray)).frame(width: 22, height: 3)
            }
            .padding(.leading, 6)
            RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: theme?.border ?? .separatorColor))
        }
        .frame(width: 44, height: 26)
        .task { theme = ThemeManager.load(ref) }
    }
}
