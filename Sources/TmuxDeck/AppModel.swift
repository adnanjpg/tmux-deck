import AppKit
import Combine
import Foundation
import UserNotifications

/// All connected servers. Each server has its own `TmuxModel`; the one you're
/// looking at is the active server, and the menus and toolbar act on it.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var servers: [TmuxModel] = []
    @Published var activeHost: String?
    @Published private(set) var forwarders: [String: PortForwarder] = [:]

    private var observers: [String: AnyCancellable] = [:]

    var activeServer: TmuxModel? {
        servers.first { $0.host == activeHost } ?? servers.first
    }

    private init() {
        Sounds.registerDefaults()
        let d = UserDefaults.standard
        var hosts = d.stringArray(forKey: "hosts") ?? []
        if hosts.isEmpty, let old = d.string(forKey: "host"), !old.isEmpty { hosts = [old] }   // earlier single-server setting
        for host in hosts { attach(host) }
        activeHost = d.string(forKey: "activeHost").flatMap { h in hosts.contains(h) ? h : nil } ?? hosts.first
    }

    func start() {
        MacKeys.install()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        for s in servers { s.start() }
        for f in forwarders.values where f.enabled { f.start() }
    }

    // MARK: Servers

    func addServer(_ host: String) {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        if !servers.contains(where: { $0.host == host }) {
            attach(host)
            servers.last?.start()
            save()
        }
        activate(host)
    }

    func removeServer(_ host: String) {
        forwarders[host]?.stop()
        forwarders[host] = nil
        observers[host] = nil
        servers.first { $0.host == host }?.stop()
        servers.removeAll { $0.host == host }
        if activeHost == host { activeHost = servers.first?.host }
        save()
        updateBadge()
    }

    func activate(_ host: String) {
        activeHost = host
        UserDefaults.standard.set(host, forKey: "activeHost")
    }

    func server(_ host: String) -> TmuxModel? { servers.first { $0.host == host } }

    private func attach(_ host: String) {
        let model = TmuxModel(host: host)
        model.onRefresh = { [weak self] in self?.updateBadge() }
        // Re-render the sidebar when any server changes, not just the active one.
        observers[host] = model.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        servers.append(model)
        let forwarder = PortForwarder(host: host)
        forwarder.onChange = { [weak self] in self?.objectWillChange.send() }
        forwarders[host] = forwarder
    }

    private func save() {
        UserDefaults.standard.set(servers.map(\.host), forKey: "hosts")
    }

    private func updateBadge() {
        let total = servers.reduce(0) { $0 + $1.needsYouCount }
        NSApp.dockTile.badgeLabel = total > 0 ? "\(total)" : nil
    }

    func stopAll() {
        for f in forwarders.values { f.terminate() }
    }

    // MARK: Selection across servers

    /// Sidebar tags are "host#item id" so one list can hold every server.
    var selectionTag: String? {
        guard let s = activeServer, let sel = s.selection else { return nil }
        return "\(s.host)#\(sel)"
    }

    func select(tag: String?) {
        guard let tag, let hash = tag.firstIndex(of: "#") else { return }
        let host = String(tag[..<hash])
        let id = String(tag[tag.index(after: hash)...])
        activate(host)
        server(host)?.userSelected(id)
    }

    /// Host names from ~/.ssh/config, for the Add server list.
    static func configuredHosts() -> [String] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var hosts: [String] = []
        for line in text.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(whereSeparator: \.isWhitespace)
            guard parts.first?.lowercased() == "host" else { continue }
            for name in parts.dropFirst() where !name.contains("*") && !name.contains("?") && !name.hasPrefix("!") && !name.lowercased().contains("github") {
                if !hosts.contains(String(name)) { hosts.append(String(name)) }
            }
        }
        return hosts
    }
}

/// Runs the LocalForward rules from ~/.ssh/config for one server, in a separate
/// background SSH connection that reconnects if it drops.
@MainActor
final class PortForwarder: ObservableObject {
    let host: String
    @Published private(set) var enabled: Bool
    @Published private(set) var ports: [Int] = []
    @Published private(set) var busyPorts: Set<Int> = []
    @Published private(set) var running = false
    @Published private(set) var lastError: String?
    var onChange: (() -> Void)?

    private var process: Process?
    private var restartTask: Task<Void, Never>?

    init(host: String) {
        self.host = host
        self.enabled = UserDefaults.standard.bool(forKey: "forward.\(host)")
        self.ports = Self.configuredPorts(host)
    }

    var activePorts: [Int] { ports.filter { !busyPorts.contains($0) } }

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: "forward.\(host)")
        on ? start() : stop()
    }

    func start() {
        guard enabled, process == nil else { return }
        ports = Self.configuredPorts(host)
        busyPorts = []
        lastError = nil
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-N", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=no",
                       "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
                       "-o", "ControlMaster=no", "-o", "ControlPath=none", host]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard !text.isEmpty else { return }
            Task { @MainActor in self?.parse(text) }
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.terminated() }
        }
        do {
            try p.run()
            process = p
            running = true
        } catch {
            lastError = error.localizedDescription
        }
        onChange?()
    }

    func stop() {
        restartTask?.cancel()
        restartTask = nil
        terminate()
        running = false
        busyPorts = []
        onChange?()
    }

    func terminate() {
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
    }

    private func parse(_ text: String) {
        // "bind [127.0.0.1]:1433: Address already in use" / "cannot listen to port: 1433"
        let re = try! Regex(#"(?:\]:|port: )(\d+)"#)
        for line in text.split(separator: "\n") {
            if line.contains("Address already in use") || line.contains("cannot listen") {
                if let m = line.firstMatch(of: re), let s = m[1].substring, let port = Int(s) { busyPorts.insert(port) }
            } else if line.localizedCaseInsensitiveContains("denied") || line.contains("Could not resolve") || line.contains("timed out") {
                lastError = String(line)
            }
        }
        onChange?()
    }

    private func terminated() {
        process = nil
        running = false
        onChange?()
        guard enabled else { return }
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.start()
        }
    }

    /// Local ports from the host's LocalForward rules, as ssh resolves them.
    static func configuredPorts(_ host: String) -> [Int] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-G", host]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ")
            guard parts.count >= 2, parts[0] == "localforward" else { return nil }
            return Int(parts[1].split(separator: ":").last ?? "")
        }
    }
}
