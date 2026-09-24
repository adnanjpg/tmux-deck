import SwiftUI

/// Edits Claude Code's status line on the server: the `statusLine.command` in
/// ~/.claude/settings.json and, when that command runs a script, the script itself.
struct StatusLineEditor: View {
    let window: TmuxWindow
    @Environment(\.dismiss) private var dismiss

    @State private var loading = true
    @State private var command = ""
    @State private var originalCommand = ""
    @State private var scriptPath: String?
    @State private var script = ""
    @State private var originalScript = ""
    @State private var testOutput: String?
    @State private var testing = false
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Claude's status line").font(.title3.weight(.semibold))
            Text("Claude Code runs this command after each message and shows what it prints under the input box. It receives the session's details (model, folder, cost, context) as JSON on stdin.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if loading {
                ProgressView("Reading settings from \(Remote.host)…").frame(maxWidth: .infinity, minHeight: 200)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Command").font(.headline)
                    TextField("bash ~/.claude/statusline.sh", text: $command)
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                }
                if let scriptPath {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Script").font(.headline)
                            Text(scriptPath).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        TextEditor(text: $script)
                            .font(.system(size: 12, design: .monospaced))
                            .autocorrectionDisabled()
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
                            .frame(minHeight: 260)
                    }
                }
                if let testOutput {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Test output").font(.headline)
                            Text("with sample values for context and usage").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(testOutput.isEmpty ? "(printed nothing)" : testOutput)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Test", action: test)
                    .disabled(loading || testing || command.isEmpty)
                    .help("Run your edited version on the server with this session's details, without saving")
                if testing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(loading || saving || !changed)
            }
            Text("Saving keeps a backup of the old version next to it (.bak-tmuxdeck).")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 640)
        .task { await load() }
    }

    private var changed: Bool { command != originalCommand || script != originalScript }

    // MARK: Remote

    private static let loadScript = #"""
import json, os, shlex
p = os.path.expanduser("~/.claude/settings.json")
try: d = json.load(open(p))
except Exception: d = {}
sl = d.get("statusLine") or {}
cmd = sl.get("command", "") if isinstance(sl, dict) else ""
path, text = None, ""
try: parts = shlex.split(cmd)
except Exception: parts = cmd.split()
for tok in parts:
    f = os.path.expanduser(tok)
    if os.path.isfile(f):
        path = f
        text = open(f, errors="replace").read()
        break
print(json.dumps({"command": cmd, "path": path, "script": text}))
"""#

    private func load() async {
        let result = await Remote.run("python3 -", input: Self.loadScript)
        guard result.ok,
              let obj = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any] else {
            error = "Couldn't read ~/.claude/settings.json on \(Remote.host)."
            loading = false
            return
        }
        command = obj["command"] as? String ?? ""
        originalCommand = command
        scriptPath = obj["path"] as? String
        script = obj["script"] as? String ?? ""
        originalScript = script
        loading = false
    }

    /// The JSON Claude Code would pass on stdin, filled in from this session.
    private var sampleInput: String {
        let cwd = window.path
        let info: [String: Any] = [
            "hook_event_name": "Status",
            "session_id": window.claude?.sessionID ?? "",
            "cwd": cwd,
            "model": ["id": "claude-opus-5", "display_name": "Opus 5", "effort": "high"],
            "context_window": ["used_percentage": 42, "total_input_tokens": 84000, "context_window_size": 200000],
            "rate_limits": [
                "five_hour": ["used_percentage": 12, "resets_at": Int(Date().addingTimeInterval(7200).timeIntervalSince1970)],
                "seven_day": ["used_percentage": 30, "resets_at": Int(Date().addingTimeInterval(4 * 86400).timeIntervalSince1970)],
            ],
            "workspace": ["current_dir": cwd, "project_dir": cwd],
            "version": "",
            "output_style": ["name": "default"],
            "cost": ["total_cost_usd": 0, "total_duration_ms": 0, "total_lines_added": 0, "total_lines_removed": 0],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: info)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private func test() {
        testing = true
        error = nil
        Task {
            var run = command
            var setup = ""
            if let scriptPath, script != originalScript {
                // Test the edited script from a temporary copy, leaving the real one untouched.
                let tmp = "$HOME/.cache/tmuxdeck/statusline-test"
                setup = "mkdir -p ~/.cache/tmuxdeck && printf %s \(sq(script)) > \(tmp) && chmod +x \(tmp) && "
                run = command.replacingOccurrences(of: scriptPath, with: tmp)
            }
            let result = await Remote.run(setup + "cd \(sq(window.path)) 2>/dev/null; " + run, input: sampleInput, timeout: 20)
            testOutput = stripANSI(result.stdout).trimmingCharacters(in: .newlines)
            if !result.ok {
                error = "Exited with status \(result.status). " + stripANSI(result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            testing = false
        }
    }

    private func save() {
        saving = true
        error = nil
        Task {
            var steps: [String] = []
            if let scriptPath, script != originalScript {
                steps.append("cp \(sq(scriptPath)) \(sq(scriptPath + ".bak-tmuxdeck")) && printf %s \(sq(script)) > \(sq(scriptPath))")
            }
            if command != originalCommand {
                let py = """
                import json, os, shutil, sys
                p = os.path.expanduser("~/.claude/settings.json")
                d = json.load(open(p)) if os.path.exists(p) else {}
                if os.path.exists(p): shutil.copy(p, p + ".bak-tmuxdeck")
                sl = d.get("statusLine") if isinstance(d.get("statusLine"), dict) else {"type": "command"}
                sl["type"] = "command"
                sl["command"] = sys.argv[1]
                d["statusLine"] = sl
                json.dump(d, open(p, "w"), indent=2)
                """
                steps.append("python3 -c \(sq(py)) \(sq(command))")
            }
            let result = await Remote.run(steps.joined(separator: " && "), timeout: 20)
            saving = false
            if result.ok {
                dismiss()
            } else {
                error = "Couldn't save: " + result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
}
