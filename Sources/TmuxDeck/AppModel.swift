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
    /// Used when you only have plain terminals (no tmux servers) so the window still has a model.
    lazy var localStandIn = TmuxModel(host: Remote.localHost)

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
        TabSwitcherController.shared.installMonitors()
        Notifications.install()
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
        // Plain terminals aren't tmux servers; nothing to select server-side.
        guard let tag, !tag.hasPrefix("plain#"), let hash = tag.firstIndex(of: "#") else { return }
        let host = String(tag[..<hash])
        let id = String(tag[tag.index(after: hash)...])
        activate(host)
        server(host)?.userSelected(id)
    }

    // MARK: Tab switching (⌃⇥ / ⌃⇧⇥ — see TabSwitcher.swift)

    /// Every open window, grouped the way the sidebar groups them: this Mac's plain
    /// terminals first, then one section per tmux session per server. Panes aren't
    /// listed separately — one entry per window, the same granularity as a browser tab.
    func groupedTabs() -> [TabGroup] {
        var groups: [TabGroup] = []
        let plainTerminals = PlainTerminalStore.shared.terminals
        if !plainTerminals.isEmpty {
            groups.append(TabGroup(server: "This Mac · terminals", session: nil, host: nil,
                                   items: plainTerminals.map { t in
                TabInfo(tag: t.tag, title: t.title,
                        subtitle: t.running ? (t.kind == .claude ? "Claude" : "Terminal") : "Ended",
                        icon: t.kind == .claude ? "sparkle" : "terminal", stateColor: nil, paneID: nil)
            }))
        }
        for server in servers {
            for session in server.sessions {
                let items = session.windows.map { w -> TabInfo in
                    let (icon, color) = TabInfo.iconAndColor(for: w.state)
                    return TabInfo(tag: "\(server.host)#\(w.id)", title: server.displayTitle(w),
                                   subtitle: w.state.label, icon: icon, stateColor: color,
                                   paneID: w.paneID.isEmpty ? nil : w.paneID)
                }
                if !items.isEmpty {
                    groups.append(TabGroup(server: server.displayName, session: session.name,
                                           host: server.host, items: items))
                }
            }
        }
        return groups
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

/// One forwarded port: `localhost:<local>` on this Mac reaches `<remoteHost>:<remotePort>`
/// as seen from the server.
struct ForwardRule: Identifiable, Hashable, Codable {
    var local: Int
    var host: String = "localhost"
    var remote: Int
    /// True when the rule comes from a LocalForward line in ~/.ssh/config rather than the app.
    var fromConfig = false

    var id: Int { local }
    var summary: String { "localhost:\(local) → \(host):\(remote)" }
}

/// Runs a server's port forwards in a separate background SSH connection that reconnects
/// if it drops.
///
/// The rules start as the host's LocalForward lines from ~/.ssh/config, and the app can add,
/// remove and switch off individual ones. Every rule is passed explicitly as `-L` with
/// `ClearAllForwardings=yes`, so what's running is exactly the list shown in the UI — ssh
/// won't quietly re-add the config's own forwards on top.
@MainActor
final class PortForwarder: ObservableObject {
    let host: String
    @Published private(set) var enabled: Bool
    @Published private(set) var rules: [ForwardRule] = []
    @Published private(set) var disabled: Set<Int> = []
    @Published private(set) var busyPorts: Set<Int> = []
    @Published private(set) var listening: Set<Int> = []
    @Published private(set) var running = false
    @Published private(set) var lastError: String?
    var onChange: (() -> Void)?

    private var process: Process?
    private var restartTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    private var customKey: String { "forward.rules.\(host)" }
    private var disabledKey: String { "forward.off.\(host)" }

    init(host: String) {
        self.host = host
        self.enabled = UserDefaults.standard.bool(forKey: "forward.\(host)")
        self.disabled = Set(UserDefaults.standard.array(forKey: disabledKey) as? [Int] ?? [])
        reloadRules()
    }

    /// Config rules plus the app's own; a rule added in the app wins on the same local port.
    private func reloadRules() {
        var byPort: [Int: ForwardRule] = [:]
        for r in Self.configuredRules(host) { byPort[r.local] = r }
        for r in custom { byPort[r.local] = r }
        rules = byPort.values.sorted { $0.local < $1.local }
    }

    private var custom: [ForwardRule] {
        get {
            guard let data = UserDefaults.standard.data(forKey: customKey) else { return [] }
            return (try? JSONDecoder().decode([ForwardRule].self, from: data)) ?? []
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: customKey)
        }
    }

    var activeRules: [ForwardRule] { rules.filter { !disabled.contains($0.local) } }
    /// Ports that are forwarded right now: switched on, bound, and not taken by something else.
    var forwardedPorts: [Int] { activeRules.map(\.local).filter { !busyPorts.contains($0) && listening.contains($0) } }

    // MARK: Editing

    func add(local: Int, host remoteHost: String, remote: Int) {
        let name = remoteHost.trimmingCharacters(in: .whitespaces)
        let rule = ForwardRule(local: local, host: name.isEmpty ? "localhost" : name, remote: remote)
        custom = custom.filter { $0.local != local } + [rule]
        disabled.remove(local)
        saveDisabled()
        reloadRules()
        restart()
    }

    /// Removes a rule the app added. A rule from ~/.ssh/config is switched off instead —
    /// the app doesn't edit the user's SSH config.
    func remove(_ rule: ForwardRule) {
        if custom.contains(where: { $0.local == rule.local }) {
            custom = custom.filter { $0.local != rule.local }
        }
        reloadRules()
        if rules.contains(where: { $0.local == rule.local }) {
            setEnabled(rule, false)
        } else {
            restart()
        }
    }

    func setEnabled(_ rule: ForwardRule, _ on: Bool) {
        if on { disabled.remove(rule.local) } else { disabled.insert(rule.local) }
        saveDisabled()
        restart()
    }

    private func saveDisabled() {
        UserDefaults.standard.set(Array(disabled), forKey: disabledKey)
    }

    func refreshFromConfig() {
        reloadRules()
        restart()
    }

    private func restart() {
        guard enabled else { onChange?(); return }
        terminate()
        start()
    }

    // MARK: Running

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: "forward.\(host)")
        on ? start() : stop()
    }

    func start() {
        guard enabled, process == nil, !activeRules.isEmpty else { onChange?(); return }
        busyPorts = []
        listening = []
        lastError = nil
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-N", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=no",
                       "-o", "ClearAllForwardings=yes",
                       "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
                       "-o", "ControlMaster=no", "-o", "ControlPath=none"]
            + activeRules.flatMap { ["-L", "\($0.local):\($0.host):\($0.remote)"] }
            + [host]
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
            watchListeners(pid: p.processIdentifier)
        } catch {
            lastError = error.localizedDescription
        }
        onChange?()
    }

    func stop() {
        restartTask?.cancel()
        restartTask = nil
        pollTask?.cancel()
        pollTask = nil
        terminate()
        running = false
        busyPorts = []
        listening = []
        onChange?()
    }

    func terminate() {
        pollTask?.cancel()
        pollTask = nil
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
    }

    /// ssh only complains about a port it *couldn't* bind, so the ports that did bind are
    /// found by asking the OS which ones this ssh process is listening on.
    private func watchListeners(pid: Int32) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let ports = await Self.listeningPorts(pid: pid)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.process?.processIdentifier == pid else { return }
                    if ports != self.listening { self.listening = ports; self.onChange?() }
                }
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private static func listeningPorts(pid: Int32) async -> Set<Int> {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            p.arguments = ["-a", "-p", "\(pid)", "-nP", "-iTCP", "-sTCP:LISTEN", "-Fn"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return [] }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            var ports: Set<Int> = []
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.hasPrefix("n") {
                if let port = Int(line.split(separator: ":").last ?? "") { ports.insert(port) }
            }
            return ports
        }.value
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
        pollTask?.cancel()
        pollTask = nil
        listening = []
        onChange?()
        guard enabled else { return }
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.start()
        }
    }

    /// The host's LocalForward rules, as ssh itself resolves them
    /// ("localforward 3000 [localhost]:3000").
    static func configuredRules(_ host: String) -> [ForwardRule] {
        if host == Remote.localHost || host.isEmpty { return [] }
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
            guard parts.count >= 3, parts[0] == "localforward",
                  let local = Int(parts[1].split(separator: ":").last ?? "") else { return nil }
            // "[localhost]:3000", or "host:3000" without the brackets.
            let target = parts[2]
            guard let colon = target.lastIndex(of: ":"), let remote = Int(target[target.index(after: colon)...]) else { return nil }
            let name = target[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            return ForwardRule(local: local, host: name.isEmpty ? "localhost" : name, remote: remote, fromConfig: true)
        }
    }

    static func configuredPorts(_ host: String) -> [Int] { configuredRules(host).map(\.local) }
}
