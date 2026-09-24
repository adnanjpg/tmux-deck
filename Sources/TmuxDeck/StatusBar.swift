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
            .popover(isPresented: $customizing, arrowEdge: .top) { StatusBarSettings(refresh: $refresh) }
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

private struct ChipView: View {
    @EnvironmentObject private var model: TmuxModel
    let chip: StatusChip
    let window: TmuxWindow

    var body: some View {
        Group {
            switch chip.kind {
            case .context, .usage:
                HStack(spacing: 5) {
                    Text(chip.kind == .context ? "Context" : "\(chip.text) usage").foregroundStyle(.secondary)
                    Gauge(value: min((chip.percent ?? 0) / 100, 1)) { EmptyView() }
                        .gaugeStyle(.accessoryLinearCapacity)
                        .tint(color)
                        .frame(width: 46)
                        .scaleEffect(y: 0.8)
                    Text("\(Int(chip.percent ?? 0))%").monospacedDigit()
                    if let reset = chip.detail {
                        Text("resets \(reset)").foregroundStyle(.tertiary)
                    }
                }
                .help(chip.kind == .context ? "How much of the context window is used" : "Plan usage in this \(chip.text) window")
            case .mode:
                Button { model.send(keys: ["BTab"], to: window) } label: {
                    Label(chip.text, systemImage: modeIcon)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(chip.text.lowercased().contains("bypass") ? .orange : .primary)
                .help("Switch permission mode (Shift+Tab)")
            default:
                Label(chip.text, systemImage: icon).foregroundStyle(chip.kind == .hint ? .tertiary : .secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.secondary.opacity(0.08)))
    }

    private var color: Color {
        let p = chip.percent ?? 0
        return p >= 85 ? .red : p >= 60 ? .orange : .green
    }

    private var modeIcon: String {
        let t = chip.text.lowercased()
        if t.contains("bypass") { return "exclamationmark.shield" }
        if t.contains("plan") { return "list.bullet.clipboard" }
        if t.contains("accept") { return "checkmark.shield" }
        return "shield.lefthalf.filled"
    }

    private var icon: String {
        switch chip.kind {
        case .location: chip.detail == "worktree" ? "arrow.triangle.branch" : "folder"
        case .model: "cpu"
        case .effort: "gauge.with.dots.needle.50percent"
        case .activity:
            chip.text.contains("PR") ? "arrow.triangle.pull" : chip.text.contains("agent") ? "person.2" : chip.text.contains("shell") ? "terminal" : "circle.fill"
        case .hint: "lightbulb"
        default: "info.circle"
        }
    }
}

private struct StatusBarSettings: View {
    @Binding var refresh: Int

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
            Text("The bar mirrors Claude Code's own status line. To change what Claude puts in it, edit the statusLine setting in ~/.claude/settings.json on the server.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 260, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }
}
