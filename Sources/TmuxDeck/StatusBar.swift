import SwiftUI

/// One piece of Claude Code's status line, recognised so it can be shown natively.
struct StatusChip: Identifiable, Hashable {
    enum Kind: String, CaseIterable {
        case location, model, effort, context, usage, mode, activity, hint, other

        var label: String {
            switch self {
            case .location: "Folder or worktree"
            case .model: "Model"
            case .effort: "Effort"
            case .context: "Context used"
            case .usage: "Usage limits (5h, 7d)"
            case .mode: "Permission mode"
            case .activity: "PRs, shells and agents"
            case .hint: "Hints (updates, /clear tips)"
            case .other: "Anything else"
            }
        }

        var defaultOn: Bool { self != .hint }
        var storageKey: String { "statusbar.\(rawValue)" }
    }

    var kind: Kind
    var text: String
    var percent: Double? = nil
    var detail: String? = nil
    var id: String { "\(kind.rawValue):\(text)" }

    /// Splits the lines under Claude's input box into chips.
    static func parse(_ lines: [String]) -> [StatusChip] {
        var chips: [StatusChip] = []
        for line in lines {
            // Columns on the same line are separated by wide gaps.
            let segments = line.components(separatedBy: "   ")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            for segment in segments { chips += parseSegment(segment) }
        }
        var seen = Set<String>()
        return chips.filter { seen.insert($0.id).inserted }
    }

    private static func parseSegment(_ segment: String) -> [StatusChip] {
        if segment.hasPrefix("⏵") || segment.hasPrefix("⏸") {
            return parseModeLine(segment)
        }
        if segment.contains("/clear") || segment.contains("Update installed") || segment.contains("Restart to update")
            || segment == "/rc" || segment.hasPrefix("?") {
            return [StatusChip(kind: .hint, text: segment)]
        }
        var chips: [StatusChip] = []
        var rest = segment
        func take(_ pattern: String, _ make: (Regex<AnyRegexOutput>.Match) -> StatusChip?) {
            guard let re = try? Regex(pattern) else { return }
            while let m = rest.firstMatch(of: re) {
                if let chip = make(m) { chips.append(chip) }
                rest.removeSubrange(m.range)
            }
        }
        func g(_ m: Regex<AnyRegexOutput>.Match, _ i: Int) -> String? { m[i].substring.map(String.init) }

        take(#"\S+@\S+?:(\S+)"#) { m in
            guard let path = g(m, 1) else { return nil }
            if let r = path.range(of: "/worktrees/") {
                return StatusChip(kind: .location, text: String(path[r.upperBound...]), detail: "worktree")
            }
            return StatusChip(kind: .location, text: (path as NSString).lastPathComponent)
        }
        take(#"\[([^\]]+)\]"#) { m in g(m, 1).map { StatusChip(kind: .model, text: $0) } }
        take(#"ctx:\s*(\d+(?:\.\d+)?)%"#) { m in
            g(m, 1).flatMap(Double.init).map { StatusChip(kind: .context, text: "Context", percent: $0) }
        }
        take(#"(\d+[hdw]):\s*(\d+(?:\.\d+)?)%(?:\s*↺\s*(\S+))?"#) { m in
            guard let label = g(m, 1), let pct = g(m, 2).flatMap(Double.init) else { return nil }
            return StatusChip(kind: .usage, text: label, percent: pct, detail: g(m, 3))
        }
        take(#"\b(low|medium|high|xhigh|max)\b"#) { m in g(m, 1).map { StatusChip(kind: .effort, text: $0) } }
        let leftover = rest.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "·|")))
        if !leftover.isEmpty { chips.append(StatusChip(kind: .other, text: leftover)) }
        return chips
    }

    private static func parseModeLine(_ line: String) -> [StatusChip] {
        var parts = line.components(separatedBy: " · ").map { $0.trimmingCharacters(in: .whitespaces) }
        var chips: [StatusChip] = []
        if !parts.isEmpty {
            var mode = parts.removeFirst()
                .replacingOccurrences(of: "⏵⏵", with: "")
                .replacingOccurrences(of: "⏸", with: "")
                .replacingOccurrences(of: #"\(shift\+tab to cycle\)"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if mode.hasSuffix(" on") { mode = String(mode.dropLast(3)) }
            chips.append(StatusChip(kind: .mode, text: mode.prefix(1).uppercased() + mode.dropFirst()))
        }
        for p in parts where !p.isEmpty {
            chips.append(StatusChip(kind: .activity, text: p.replacingOccurrences(of: "← ", with: "")))
        }
        return chips
    }
}

/// Claude Code's status line as native chips under the input box.
struct StatusBar: View {
    @EnvironmentObject private var model: TmuxModel
    let window: TmuxWindow
    @AppStorage("statusbar.version") private var refresh = 0   // bumps when toggles change
    @State private var customizing = false
    @State private var editing = false

    var body: some View {
        let chips = StatusChip.parse(model.statusLines[window.id] ?? []).filter(isShown)
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(chips) { chip in ChipView(chip: chip, window: window) }
                }
            }
            Button { customizing.toggle() } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .help("Choose what the status bar shows")
            .popover(isPresented: $customizing, arrowEdge: .top) {
                StatusBarSettings(refresh: $refresh) {
                    customizing = false
                    editing = true
                }
            }
            .sheet(isPresented: $editing) { StatusLineEditor(window: window) }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .frame(minHeight: 22)
        .id(refresh)
    }

    private func isShown(_ chip: StatusChip) -> Bool {
        let d = UserDefaults.standard
        return d.object(forKey: chip.kind.storageKey) == nil ? chip.kind.defaultOn : d.bool(forKey: chip.kind.storageKey)
    }
}

/// One chip in the status bar. Most chips open a menu or a details popover.
private struct ChipView: View {
    @EnvironmentObject private var model: TmuxModel
    let chip: StatusChip
    let window: TmuxWindow
    @State private var open = false

    var body: some View {
        switch chip.kind {
        case .mode:
            Menu {
                ForEach(ClaudeMode.allCases, id: \.self) { mode in
                    Button { model.setMode(mode, in: window) } label: {
                        if ClaudeMode.from(chip.text) == mode { Label(mode.title, systemImage: "checkmark") } else { Text(mode.title) }
                    }
                }
                Divider()
                Text("Modes that aren't enabled for this session are skipped").font(.caption)
            } label: {
                capsule { Label(chip.text, systemImage: ClaudeMode.from(chip.text).icon) }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(chip.text.lowercased().contains("bypass") ? .orange : .primary)
            .help("Change permission mode")
        case .effort:
            Menu {
                ForEach(["low", "medium", "high", "xhigh", "max"], id: \.self) { level in
                    Button { model.send(text: "/effort \(level)", to: window) } label: {
                        if chip.text == level { Label(level.capitalized, systemImage: "checkmark") } else { Text(level.capitalized) }
                    }
                }
            } label: {
                capsule { Label(chip.text, systemImage: "gauge.with.dots.needle.50percent").foregroundStyle(.secondary) }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Change effort level")
        case .model:
            popoverChip { Label(chip.text, systemImage: "cpu").foregroundStyle(.secondary) } content: {
                ModelPicker(current: chip.text) { id in
                    open = false
                    model.send(text: "/model \(id)", to: window)
                }
            }
            .help("Change model")
        case .context, .usage:
            popoverChip {
                HStack(spacing: 5) {
                    Text(chip.kind == .context ? "Context" : "\(chip.text) usage").foregroundStyle(.secondary)
                    Gauge(value: min((chip.percent ?? 0) / 100, 1)) { EmptyView() }
                        .gaugeStyle(.accessoryLinearCapacity)
                        .tint(color(chip.percent))
                        .frame(width: 46)
                        .scaleEffect(y: 0.8)
                    Text("\(Int(chip.percent ?? 0))%").monospacedDigit()
                    if let reset = chip.detail { Text("resets \(reset)").foregroundStyle(.tertiary) }
                }
            } content: {
                UsageDetails(window: window)
            }
            .help(chip.kind == .context ? "Context and usage details" : "Usage details")
        case .activity where chip.text.contains("agent"):
            popoverChip { Label(chip.text, systemImage: "person.2").foregroundStyle(.secondary) } content: {
                AgentsList { w in open = false; model.userSelected(w.id) }
            }
            .help("Claude sessions on \(model.host)")
        case .activity where chip.text.contains("shell"):
            popoverChip { Label(chip.text, systemImage: "terminal").foregroundStyle(.secondary) } content: {
                if let sid = window.claude?.sessionID {
                    BackgroundShells(store: model.chatStore(for: sid), window: window)
                }
            }
            .help("Background commands Claude started")
        case .activity where chip.text.range(of: #"PR #?\d+"#, options: .regularExpression) != nil:
            PRStatusChip(text: chip.text, window: window)
        default:
            capsule {
                Label(chip.text, systemImage: icon).foregroundStyle(chip.kind == .hint ? .tertiary : .secondary)
                    .lineLimit(1)
            }
        }
    }

    private func capsule<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.secondary.opacity(0.08)))
    }

    private func popoverChip<L: View, C: View>(@ViewBuilder _ label: () -> L, @ViewBuilder content: @escaping () -> C) -> some View {
        Button { open.toggle() } label: { capsule(label) }
            .buttonStyle(.plain)
            .popover(isPresented: $open, arrowEdge: .top) { content() }
    }

    private var icon: String {
        switch chip.kind {
        case .location: chip.detail == "worktree" ? "arrow.triangle.branch" : "folder"
        case .activity: "circle.fill"
        case .hint: "lightbulb"
        default: "info.circle"
        }
    }
}

func color(_ percent: Double?) -> Color {
    let p = percent ?? 0
    return p >= 85 ? .red : p >= 60 ? .orange : .green
}

/// Claude Code's permission modes, in the order Shift+Tab cycles through them.
enum ClaudeMode: CaseIterable {
    case normal, acceptEdits, plan, auto, bypass

    var title: String {
        switch self {
        case .normal: "Default (ask before edits)"
        case .acceptEdits: "Accept edits"
        case .plan: "Plan mode"
        case .auto: "Auto mode"
        case .bypass: "Bypass permissions"
        }
    }

    var icon: String {
        switch self {
        case .bypass: "exclamationmark.shield"
        case .plan: "list.bullet.clipboard"
        case .acceptEdits: "checkmark.shield"
        default: "shield.lefthalf.filled"
        }
    }

    /// Words that identify the mode in Claude's mode line; nil means none of the others is shown.
    var marker: String? {
        switch self {
        case .normal: nil
        case .acceptEdits: "accept edits"
        case .plan: "plan mode"
        case .auto: "auto mode"
        case .bypass: "bypass permissions"
        }
    }

    static func from(_ text: String) -> ClaudeMode {
        let t = text.lowercased()
        return allCases.first { $0.marker.map(t.contains) ?? false } ?? .normal
    }
}

/// Current models first; older ones tucked into a collapsed Legacy section.
struct ModelPicker: View {
    let current: String
    var onPick: (String) -> Void
    @State private var showLegacy = false

    // Model ids as Claude Code 2.1 knows them.
    static let currentModels: [(name: String, id: String)] = [
        ("Opus 5.5", "claude-opus-5-5"),
        ("Opus 5.5 · 1M context", "claude-opus-5-5[1m]"),
        ("Fable 5.1", "claude-fable-5-1"),
        ("Sonnet 5", "claude-sonnet-5"),
        ("Sonnet 5 · 1M context", "claude-sonnet-5[1m]"),
        ("Haiku 4.5", "claude-haiku-4-5"),
    ]

    static let legacyModels: [(name: String, id: String)] = [
        ("Opus 5", "claude-opus-5"),
        ("Opus 5 · 1M context", "claude-opus-5[1m]"),
        ("Fable 5", "claude-fable-5"),
        ("Opus 4.8", "claude-opus-4-8"),
        ("Opus 4.7", "claude-opus-4-7"),
        ("Opus 4.6", "claude-opus-4-6"),
        ("Opus 4.5", "claude-opus-4-5"),
        ("Opus 4.1", "claude-opus-4-1"),
        ("Opus 4", "claude-opus-4-0"),
        ("Sonnet 4.6", "claude-sonnet-4-6"),
        ("Sonnet 4.5", "claude-sonnet-4-5"),
        ("Sonnet 4", "claude-sonnet-4-0"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Model").font(.headline)
            Text("Now: \(current)").font(.caption).foregroundStyle(.secondary)
            Divider()
            ForEach(Self.currentModels, id: \.id) { row($0) }
            DisclosureGroup("Legacy models", isExpanded: $showLegacy) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Self.legacyModels, id: \.id) { row($0) }
                }
                .padding(.top, 4)
            }
            .padding(.top, 4)
            Divider()
            Button("Default (recommended)") { onPick("default") }.buttonStyle(.link)
        }
        .padding(14)
        .frame(width: 280)
    }

    private func row(_ m: (name: String, id: String)) -> some View {
        let selected = matches(m.name)
        return Button { onPick(m.id) } label: {
            HStack {
                Text(m.name)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(m.id)
    }

    /// "Opus 5 (1M context)" in the status line ↔ "Opus 5 · 1M context" here.
    private func matches(_ name: String) -> Bool {
        let a = current.lowercased().replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
        let b = name.lowercased().replacingOccurrences(of: " · ", with: " ")
        return a == b
    }
}

/// Usage gauges from the status line, plus Claude's full /usage screen on request.
struct UsageDetails: View {
    @EnvironmentObject private var model: TmuxModel
    let window: TmuxWindow
    @State private var full: String?
    @State private var loading = false

    var body: some View {
        let chips = StatusChip.parse(model.statusLines[window.id] ?? []).filter { $0.kind == .context || $0.kind == .usage }
        VStack(alignment: .leading, spacing: 10) {
            Text("Usage").font(.headline)
            ForEach(chips) { chip in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(label(chip))
                        Spacer()
                        Text("\(Int(chip.percent ?? 0))%").monospacedDigit()
                    }
                    ProgressView(value: min((chip.percent ?? 0) / 100, 1)).tint(color(chip.percent))
                    if let reset = chip.detail { Text("Resets at \(reset)").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Divider()
            if let full {
                ScrollView {
                    Text(full).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
            }
            HStack {
                Button(full == nil ? "Show all limits (weekly, per model)" : "Refresh") { load() }
                    .disabled(loading || window.state == .claudeWorking)
                if loading { ProgressView().controlSize(.small) }
            }
            if window.state == .claudeWorking {
                Text("Available when Claude isn't working.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    private func label(_ chip: StatusChip) -> String {
        switch chip.kind {
        case .context: return "Context window"
        default:
            switch chip.text {
            case "5h": return "Current 5-hour session"
            case "7d", "1w": return "This week"
            default: return "\(chip.text) limit"
            }
        }
    }

    private func load() {
        loading = true
        Task {
            full = await model.captureClaudeScreen(command: "/usage", in: window)
            loading = false
        }
    }
}

/// Every Claude session on this server, with its status. Click one to jump to it.
struct AgentsList: View {
    @EnvironmentObject private var model: TmuxModel
    var onPick: (TmuxWindow) -> Void

    var body: some View {
        let items = model.sessions.flatMap(\.windows).flatMap { $0.paneItems.isEmpty ? [$0] : $0.paneItems }.filter(\.state.isClaude)
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude sessions on \(model.host)").font(.headline)
            ForEach(items) { w in
                Button { onPick(w) } label: {
                    HStack(spacing: 8) {
                        Circle().fill(dot(w.state)).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.displayTitle(w)).lineLimit(1)
                            Text("\(w.state.label) · \(w.session) · \(w.folder)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private func dot(_ s: WindowState) -> Color {
        switch s {
        case .claudeWorking: .blue
        case .claudeNeedsYou: .orange
        default: .secondary
        }
    }
}

/// Background commands Claude started in this conversation (Bash with run_in_background).
struct BackgroundShells: View {
    @EnvironmentObject private var model: TmuxModel
    @ObservedObject var store: ChatStore
    let window: TmuxWindow
    @State private var tasks: String?
    @State private var loading = false

    var body: some View {
        let shells = store.items.filter { $0.background == true }.suffix(10).reversed()
        VStack(alignment: .leading, spacing: 8) {
            Text("Background commands").font(.headline)
            if shells.isEmpty { Text("None in the loaded part of this chat.").foregroundStyle(.secondary) }
            ForEach(Array(shells)) { item in
                if case .tool(_, let summary, _, _) = item.kind {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(summary).font(.system(size: 11, design: .monospaced)).lineLimit(3).textSelection(.enabled)
                        if let r = item.result {
                            Text(r.split(separator: "\n").prefix(2).joined(separator: " ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Divider()
                }
            }
            if let tasks {
                ScrollView {
                    Text(tasks).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
            HStack {
                Button(tasks == nil ? "Show Claude's task list" : "Refresh") {
                    loading = true
                    Task { tasks = await model.captureClaudeScreen(command: "/tasks", in: window); loading = false }
                }
                .disabled(loading || window.state == .claudeWorking)
                if loading { ProgressView().controlSize(.small) }
            }
            if window.state == .claudeWorking {
                Text("The live list is available when Claude isn't working.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 380)
    }
}

/// "PR #2268" in Claude's mode line, as a live PR chip for the window's repository.
struct PRStatusChip: View {
    @EnvironmentObject private var model: TmuxModel
    let text: String
    let window: TmuxWindow
    @State private var repo: String?

    var body: some View {
        Group {
            if let repo, let n = text.firstMatch(of: try! Regex(#"(\d+)"#))?[1].substring {
                PRChip(url: "https://github.com/\(repo)/pull/\(n)")
            } else {
                Label(text, systemImage: "arrow.triangle.pull").foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.secondary.opacity(0.08)))
            }
        }
        .task(id: window.path) { repo = await model.repository(for: window.path) }
    }
}

private struct StatusBarSettings: View {
    @Binding var refresh: Int
    var onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Show in the status bar").font(.headline)
            ForEach(StatusChip.Kind.allCases, id: \.self) { kind in
                Toggle(kind.label, isOn: Binding(
                    get: {
                        let d = UserDefaults.standard
                        return d.object(forKey: kind.storageKey) == nil ? kind.defaultOn : d.bool(forKey: kind.storageKey)
                    },
                    set: { UserDefaults.standard.set($0, forKey: kind.storageKey); refresh += 1 }
                ))
            }
            Divider()
            Text("The bar mirrors Claude Code's own status line.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 260, alignment: .leading)
            Button("Edit Claude's status line…", action: onEdit)
        }
        .padding(16)
    }
}
