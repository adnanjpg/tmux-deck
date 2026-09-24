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
            Section("Connection") {
                TextField("SSH host", text: $host, prompt: Text("my-server"))
                Text("A host name from ~/.ssh/config, or user@address.")
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
