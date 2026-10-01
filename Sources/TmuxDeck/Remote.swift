import Foundation

/// Runs commands on one server over SSH.
///
/// Every call shares one multiplexed SSH connection per server (ControlMaster), so
/// sidebar refreshes and button clicks cost a few milliseconds instead of a new
/// handshake. Port forwards from ~/.ssh/config are cleared on this connection;
/// `PortForwarder` runs them separately when you turn them on.
struct Remote: Hashable {
    let host: String

    /// The host name used for this Mac itself: commands run locally, no SSH.
    static let localHost = "local"
    var isLocal: Bool { host == Self.localHost }
    var displayName: String { isLocal ? "This Mac" : host }

    /// How to start an interactive command (the raw terminal view).
    func interactiveCommand(_ script: String) -> (executable: String, args: [String]) {
        isLocal ? ("/bin/zsh", ["-lc", script]) : ("/usr/bin/ssh", interactiveArguments(script))
    }

    static let controlPath = "~/.ssh/tmuxdeck-%C"

    static var baseOptions: [String] {
        [
            "-o", "ClearAllForwardings=yes",
            "-o", "Compression=yes",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlPersist=600",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=10",
        ]
    }

    /// Noise ssh prints that isn't a problem the user can do anything about.
    static func withoutNoise(_ stderr: String) -> String {
        stderr.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("ControlSocket") && !$0.contains("disabling multiplexing") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct Result {
        var status: Int32
        var stdout: String
        var stderr: String
        var ok: Bool { status == 0 }
    }

    /// Runs `script` with the remote login shell and returns its output.
    func run(_ script: String, input: String? = nil, timeout: TimeInterval = 15) async -> Result {
        await run(script, data: input.map { Data($0.utf8) }, timeout: timeout)
    }

    /// Uploads `data` into ~/.cache/tmuxdeck on the remote machine and returns its absolute path.
    func upload(_ data: Data, fileName: String) async -> String? {
        let dir = "~/.cache/tmuxdeck"
        let result = await run("mkdir -p \(dir) && cat > \(dir)/\(sq(fileName)) && cd \(dir) && printf '%s/%s' \"$PWD\" \(sq(fileName))",
                               data: data, timeout: 120)
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.ok && path.hasPrefix("/") ? path : nil
    }

    func run(_ script: String, data input: Data?, timeout: TimeInterval = 15) async -> Result {
        // Several ssh processes racing to create the shared control socket all try to become the
        // master; the losers print "ControlSocket … already exists, disabling multiplexing" and
        // then connect on their own, slowly. The first connection to a host therefore runs alone,
        // and everything else waits for it — after which the socket exists and they just attach.
        if !isLocal { await SSHMaster.shared.ready(host) }
        return await execute(script, data: input, timeout: timeout)
    }

    func execute(_ script: String, data input: Data?, timeout: TimeInterval) async -> Result {
        // This Mac: a login shell, so Homebrew's tmux and your PATH are there.
        let executable = isLocal ? "/bin/zsh" : "/usr/bin/ssh"
        let args = isLocal ? ["-lc", script] : Self.baseOptions + ["-o", "BatchMode=yes", host, script]
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = args
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            let inPipe = input.map { _ in Pipe() }
            process.standardInput = inPipe ?? FileHandle.nullDevice
            do { try process.run() } catch {
                return Result(status: -1, stdout: "", stderr: error.localizedDescription)
            }
            if let inPipe, let input {
                inPipe.fileHandleForWriting.write(input)
                try? inPipe.fileHandleForWriting.close()
            }
            let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timer.cancel()
            return Result(
                status: process.terminationStatus,
                stdout: String(decoding: outData, as: UTF8.self),
                stderr: String(decoding: errData, as: UTF8.self)
            )
        }.value
    }

    /// Arguments for an interactive `ssh -t` that runs `script` on the remote side.
    func interactiveArguments(_ script: String) -> [String] {
        Self.baseOptions + ["-t", host, script]
    }
}

/// Quotes a value for the remote POSIX shell.
func sq(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}


/// Makes sure one — and only one — connection per host is trying to open the shared control
/// socket. Without this, every call made at startup races, and all but one of them give up on
/// multiplexing and open a connection of their own.
actor SSHMaster {
    static let shared = SSHMaster()

    private var opening: [String: Task<Void, Never>] = [:]
    private var opened: Set<String> = []

    func ready(_ host: String) async {
        if opened.contains(host) { return }
        if let existing = opening[host] { await existing.value; return }
        let task = Task {
            let remote = Remote(host: host)
            _ = await remote.openMaster()
        }
        opening[host] = task
        await task.value
        opening[host] = nil
        opened.insert(host)
    }

    /// Called when a connection reports the socket went away, so the next call re-opens it.
    func lost(_ host: String) {
        opened.remove(host)
    }
}

extension Remote {
    /// One cheap connection whose only job is to create the control socket.
    func openMaster() async -> Result {
        await execute("true", data: nil, timeout: 20)
    }
}
