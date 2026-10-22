import SwiftUI

/// Edits Claude Code's status line on the server: the `statusLine.command` in
/// ~/.claude/settings.json and, when that command runs a script, the script itself.
struct StatusLineEditor: View {
    @Environment(\.fonts) private var fonts
    let window: TmuxWindow
    @Environment(TmuxModel.self) private var model
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
            Text("Claude's status line").font(fonts.title3.weight(.semibold))
            Text("Claude Code runs this command after each message and shows what it prints under the input box. It receives the session's details (model, folder, cost, context) as JSON on stdin.")
                .font(fonts.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if loading {
                ProgressView("Reading settings from \(model.displayName)…").frame(maxWidth: .infinity, minHeight: 200)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Command").font(fonts.headline)
                    TextField("bash ~/.claude/statusline.sh", text: $command)
                        .font(fonts.monoBody)
                        .textFieldStyle(.roundedBorder)
                }
                if let scriptPath {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Script").font(fonts.headline)
                            Text(scriptPath).font(fonts.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        TextEditor(text: $script)
                            .font(fonts.size(12, design: .monospaced))
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
                            Text("Test output").font(fonts.headline)
                            Text("with sample values for context and usage").font(fonts.caption).foregroundStyle(.secondary)
                        }
                        Text(testOutput.isEmpty ? "(printed nothing)" : testOutput)
                            .font(fonts.size(12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            if let error {
                Text(error).font(fonts.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
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
                .font(fonts.caption).foregroundStyle(.tertiary)
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
        let result = await model.remote.run("python3 -", input: Self.loadScript)
        guard result.ok,
              let obj = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any] else {
            error = "Couldn't read ~/.claude/settings.json on \(model.host)."
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
            // The temporary copy goes away afterwards, whatever the test did.
            let cleanup = setup.isEmpty ? "" : "; st=$?; rm -f \"$HOME/.cache/tmuxdeck/statusline-test\"; exit $st"
            let result = await model.remote.run(setup + "cd \(sq(window.path)) 2>/dev/null; " + run + cleanup, input: sampleInput, timeout: 20)
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
            // Both files belong to Claude Code and are read while it runs, so each is written
            // to a temp file next to it and swapped in whole, keeping its mode; the previous
            // version is kept as a dated backup (the last five of them).
            let py = """
            import json, os, shutil, sys, tempfile, time

            def backup(p):
                stamp = time.strftime("%Y%m%d-%H%M%S")
                shutil.copy2(p, "%s.bak-tmuxdeck-%s" % (p, stamp))
                d, base = os.path.dirname(p) or ".", os.path.basename(p) + ".bak-tmuxdeck-"
                old = sorted(f for f in os.listdir(d) if f.startswith(base))
                for f in old[:-5]: os.unlink(os.path.join(d, f))

            def write(p, text, default_mode):
                p = os.path.realpath(os.path.expanduser(p))
                mode = os.stat(p).st_mode & 0o7777 if os.path.exists(p) else default_mode
                if os.path.exists(p): backup(p)
                fd, tmp = tempfile.mkstemp(prefix=".tmuxdeck-", dir=os.path.dirname(p))
                with os.fdopen(fd, "w") as fh: fh.write(text)
                os.chmod(tmp, mode)
                os.replace(tmp, p)

            script_path, command = sys.argv[1], sys.argv[2]
            if script_path:
                write(script_path, sys.stdin.read(), 0o755)
            if command:
                p = os.path.expanduser("~/.claude/settings.json")
                d = json.load(open(p)) if os.path.exists(p) else {}
                sl = d.get("statusLine") if isinstance(d.get("statusLine"), dict) else {"type": "command"}
                sl["type"] = "command"
                sl["command"] = command
                d["statusLine"] = sl
                write(p, json.dumps(d, indent=2) + "\\n", 0o644)
            """
            let scriptToWrite = (scriptPath != nil && script != originalScript) ? scriptPath! : ""
            let commandToWrite = command != originalCommand ? command : ""
            let result = await model.remote.run("python3 -c \(sq(py)) \(sq(scriptToWrite)) \(sq(commandToWrite))",
                                                input: script, timeout: 20)
            saving = false
            if result.ok {
                dismiss()
            } else {
                error = "Couldn't save: " + result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
}
