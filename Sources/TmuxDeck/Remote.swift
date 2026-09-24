import Foundation

/// Runs commands on the work machine over SSH.
///
/// Every call shares one multiplexed SSH connection (ControlMaster), so sidebar
/// refreshes and button clicks cost a few milliseconds instead of a new handshake.
/// Port forwards from ~/.ssh/config are cleared so the app never fights your
/// normal SSH session for local ports.
enum Remote {
    static var host: String {
        UserDefaults.standard.string(forKey: "host")?.trimmingCharacters(in: .whitespaces) ?? ""
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

    struct Result {
        var status: Int32
        var stdout: String
        var stderr: String
        var ok: Bool { status == 0 }
    }

    /// Runs `script` with the remote login shell and returns its output.
    static func run(_ script: String, input: String? = nil, timeout: TimeInterval = 15) async -> Result {
        await run(script, data: input.map { Data($0.utf8) }, timeout: timeout)
    }

    /// Uploads `data` into ~/.cache/tmuxdeck on the remote machine and returns its absolute path.
    static func upload(_ data: Data, fileName: String) async -> String? {
        let dir = "~/.cache/tmuxdeck"
        let result = await run("mkdir -p \(dir) && cat > \(dir)/\(sq(fileName)) && cd \(dir) && printf '%s/%s' \"$PWD\" \(sq(fileName))",
                               data: data, timeout: 120)
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.ok && path.hasPrefix("/") ? path : nil
    }

    static func run(_ script: String, data input: Data?, timeout: TimeInterval = 15) async -> Result {
        let args = baseOptions + ["-o", "BatchMode=yes", host, script]
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
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
    static func interactiveArguments(_ script: String) -> [String] {
        baseOptions + ["-t", host, script]
    }
}

/// Quotes a value for the remote POSIX shell.
func sq(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
