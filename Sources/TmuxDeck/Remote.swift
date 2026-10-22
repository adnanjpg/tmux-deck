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
    /// `urgent` is for something you just did (switch a window, send a message, press a key):
    /// it goes ahead of queued background polls and has a slot they can't take. See `RemoteGate`.
    func run(_ script: String, input: String? = nil, timeout: TimeInterval = 15, urgent: Bool = false) async -> Result {
        await run(script, data: input.map { Data($0.utf8) }, timeout: timeout, urgent: urgent)
    }

    /// Uploads `data` into ~/.cache/tmuxdeck on the remote machine and returns its absolute path.
    func upload(_ data: Data, fileName: String) async -> String? {
        let dir = "~/.cache/tmuxdeck"
        // Pasted screenshots were never cleaned up; week-old ones go each time a new one lands.
        let prune = "find \(dir) -maxdepth 1 -name 'screenshot-*.png' -mtime +7 -delete 2>/dev/null; "
        let result = await run("mkdir -p \(dir) && \(prune)cat > \(dir)/\(sq(fileName)) && cd \(dir) && printf '%s/%s' \"$PWD\" \(sq(fileName))",
                               data: data, timeout: 120, urgent: true)
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.ok && path.hasPrefix("/") ? path : nil
    }

    func run(_ script: String, data input: Data?, timeout: TimeInterval = 15, urgent: Bool = false) async -> Result {
        // Several ssh processes racing to create the shared control socket all try to become the
        // master; the losers print "ControlSocket … already exists, disabling multiplexing" and
        // then connect on their own, slowly. The first connection to a host therefore runs alone,
        // and everything else waits for it — after which the socket exists and they just attach.
        if isLocal { return await execute(script, data: input, timeout: timeout) }
        await SSHMaster.shared.ready(host)
        let queued = ContinuousClock.now
        await RemoteGate.shared.acquire(host, urgent: urgent)
        let started = ContinuousClock.now
        let result = await execute(script, data: input, timeout: timeout)
        await RemoteGate.shared.release(host)
        let waited = Perf.ms(queued.duration(to: started)), ran = Perf.ms(started.duration(to: .now))
        if urgent || waited > 500 || ran > 5000 {
            let label = script.split(separator: "\n").first.map { String($0.prefix(50)) } ?? ""
            Perf.log.notice("remote\(urgent ? " (urgent)" : "", privacy: .public) waited \(waited)ms, ran \(ran)ms: \(label, privacy: .public)")
        }
        return result
    }

    func execute(_ script: String, data input: Data?, timeout: TimeInterval) async -> Result {
        // This Mac: a login shell, so Homebrew's tmux and your PATH are there.
        let executable = isLocal ? "/bin/zsh" : "/usr/bin/ssh"
        let args = isLocal ? ["-lc", script] : Self.baseOptions + ["-o", "BatchMode=yes", host, script]
        // On a GCD thread, not the Swift concurrency pool: this blocks for as long as the command
        // runs, and the pool has one thread per core — a handful of slow commands used to starve
        // every other async task in the app.
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.runProcess(executable: executable, args: args,
                                                               input: input, timeout: timeout))
            }
        }
    }

    private static func runProcess(executable: String, args: [String], input: Data?,
                                   timeout: TimeInterval) -> Result {
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


/// Keeps each server's shared SSH connection under sshd's `MaxSessions` (10 by default).
///
/// Every command and every raw terminal is a session on the one multiplexed connection. Past the
/// limit the master refuses (`Session open refused by peer`) and ssh quietly falls back to a
/// brand-new connection — a full handshake, seconds on a slow link — so commands got slower,
/// overlapped more, and snowballed. Sending a message (the send, then faster chat polls) was
/// enough to tip it, and a window switch (`select-window`) then waited ~30 s behind the pile.
///
/// So: background commands share `backgroundLimit` slots; urgent ones (what you just did) jump
/// the queue and may use the remaining slots; open terminals count against the total.
actor RemoteGate {
    static let shared = RemoteGate()

    /// One below sshd's default of 10, so there's slack for something this app doesn't count.
    static let sessionLimit = 9
    static let backgroundLimit = 6

    private struct Waiter {
        let urgent: Bool
        let continuation: CheckedContinuation<Void, Never>
    }
    private var running: [String: Int] = [:]
    private var waiting: [String: [Waiter]] = [:]
    private var interactive: [String: Int] = [:]

    private func canRun(_ host: String, urgent: Bool) -> Bool {
        let total = max(2, Self.sessionLimit - (interactive[host] ?? 0))
        let cap = urgent ? total : min(Self.backgroundLimit, total - 1)
        return (running[host] ?? 0) < max(1, cap)
    }

    func acquire(_ host: String, urgent: Bool) async {
        if (waiting[host] ?? []).isEmpty || urgent, canRun(host, urgent: urgent) {
            running[host, default: 0] += 1
            return
        }
        await withCheckedContinuation { continuation in
            var queue = waiting[host] ?? []
            let waiter = Waiter(urgent: urgent, continuation: continuation)
            if urgent {
                queue.insert(waiter, at: queue.firstIndex { !$0.urgent } ?? queue.count)
            } else {
                queue.append(waiter)
            }
            waiting[host] = queue
        }
    }

    func release(_ host: String) {
        running[host, default: 1] -= 1
        drain(host)
    }

    /// A raw terminal's `ssh -t` holds a session for as long as it's open.
    func terminal(_ host: String, opened: Bool) {
        interactive[host, default: 0] += opened ? 1 : -1
        if interactive[host]! < 0 { interactive[host] = 0 }
        drain(host)
    }

    private func drain(_ host: String) {
        while let next = waiting[host]?.first, canRun(host, urgent: next.urgent) {
            waiting[host]!.removeFirst()
            running[host, default: 0] += 1
            next.continuation.resume()
        }
    }
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
