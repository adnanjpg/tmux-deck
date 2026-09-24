import AppKit
import SwiftUI

@main
struct TmuxDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = TmuxModel()

    var body: some Scene {
        Window("Tmux Deck", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 480)
                .onAppear { model.start() }
        }
        .defaultSize(width: 1400, height: 860)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Claude window") { model.newWindow(claude: true) }
                    .keyboardShortcut("n")
                Button("New terminal window") { model.newWindow(claude: false) }
                    .keyboardShortcut("t")
            }
            CommandMenu("Tmux") {
                Button("Split right") { model.split(vertical: false) }
                    .keyboardShortcut("d")
                Button("Split down") { model.split(vertical: true) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Show as terminal") { model.toggleRawTerminal() }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                Divider()
                Button("Copy all output") { model.copyOutput() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Divider()
                Button("Previous window") { model.selectRelative(-1) }
                    .keyboardShortcut("[")
                Button("Next window") { model.selectRelative(1) }
                    .keyboardShortcut("]")
                ForEach(1..<10) { n in
                    Button("Go to window \(n)") { model.selectNumber(n) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")))
                }
            }
        }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct SettingsView: View {
    @AppStorage("host") private var host = ""
    @AppStorage("fontSize") private var fontSize = 13.0

    var body: some View {
        Form {
            TextField("SSH host", text: $host, prompt: Text("my-server"))
            Text("A host name from ~/.ssh/config, or user@address.")
                .font(.caption).foregroundStyle(.secondary)
            Stepper("Font size: \(Int(fontSize)) pt", value: $fontSize, in: 9...24)
            Text("Changes apply the next time you open the app.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 380)
    }
}
