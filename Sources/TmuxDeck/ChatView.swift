import SwiftUI

/// A Claude window shown as a normal Mac chat: your messages, Claude's replies,
/// and the tools it used. Claude keeps running in tmux; this just reads its log.
struct ChatView: View {
    @EnvironmentObject private var model: TmuxModel
    let window: TmuxWindow
    @ObservedObject var store: ChatStore

    var body: some View {
        VStack(spacing: 0) {
            if !turns.isEmpty { chatHeader }
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(turns) { turn in
                        TurnView(turn: turn, store: store)
                    }
                    ForEach(Array(store.queued.enumerated()), id: \.offset) { _, text in
                        QueuedMessage(text: text)
                    }
                    ForEach(store.sending) { pending in
                        SendingMessage(message: pending)
                    }
                    if let activity = model.activities[window.id] {
                        ActivityView(activity: activity, working: window.state == .claudeWorking)
                    } else if window.state == .claudeWorking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Claude is working…").foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)
                    }
                }
                .frame(maxWidth: 860, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
                Color.clear.frame(height: 1).id("bottom")
            }
            .defaultScrollAnchor(.bottom)
            .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: store.loaded) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .overlay(alignment: .topTrailing) {
                if store.refreshing && store.loaded {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Updating").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .padding(10)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: store.refreshing)
            .overlay {
                if !store.loaded {
                    ProgressView("Loading conversation…")
                } else if store.missing {
                    ContentUnavailableView("Conversation not found", systemImage: "questionmark.bubble",
                                           description: Text("Use the Terminal button to see this window directly."))
                } else if store.items.isEmpty {
                    ContentUnavailableView("New conversation", systemImage: "sparkle",
                                           description: Text("Send Claude a message to get started."))
                }
            }
            }
            Divider()
            VStack(spacing: 0) {
                ComposeBar(window: window)
                    .id(window.id)
                StatusBar(window: window)
            }
            .background(.bar)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: store.sessionID) {
            await store.catchUp()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(window.state == .claudeWorking ? 1 : 2))
                await store.poll()
            }
        }
    }
}

extension ChatView {
    private var turns: [Turn] { Turn.group(store.items) }

    private var chatHeader: some View {
        let ids = turns.flatMap { $0.cardIDs }
        let allCollapsed = !ids.isEmpty && ids.allSatisfy(store.collapsed.contains)
        return HStack(spacing: 10) {
            Text("\(turns.count) \(turns.count == 1 ? "turn" : "turns")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                withAnimation(.snappy) { store.collapsed = Set(ids) }
            } label: {
                Label("Collapse all", systemImage: "rectangle.compress.vertical")
            }
            .disabled(allCollapsed)
            Button {
                withAnimation(.snappy) { store.collapsed = [] }
            } label: {
                Label("Expand all", systemImage: "rectangle.expand.vertical")
            }
            .disabled(store.collapsed.isEmpty)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// One exchange: your message and everything Claude did in reply.
struct Turn: Identifiable {
    var user: ChatItem?
    var replies: [ChatItem] = []

    var id: String { user?.id ?? replies.first?.id ?? UUID().uuidString }
    var replyID: String { "reply-" + id }
    var cardIDs: [String] { (user.map { [$0.id] } ?? []) + (replies.isEmpty ? [] : [replyID]) }

    static func group(_ items: [ChatItem]) -> [Turn] {
        var turns: [Turn] = []
        for item in items {
            if item.startsTurn {
                turns.append(Turn(user: item))
            } else if turns.isEmpty {
                turns.append(Turn(user: nil, replies: [item]))
            } else {
                turns[turns.count - 1].replies.append(item)
            }
        }
        return turns
    }

    /// One-line summary of Claude's reply for the collapsed view: its last message and what it did.
    var replySummary: (text: String, detail: String) {
        var lastText: String?
        var tools = 0, thoughts = 0
        for r in replies {
            switch r.kind {
            case .assistant(let t): lastText = t
            case .tool: tools += 1
            case .thinking: thoughts += 1
            default: break
            }
        }
        let line = lastText.map { t in
            t.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty && !$0.hasPrefix("```") } ?? ""
        } ?? ""
        var parts: [String] = []
        if tools > 0 { parts.append("\(tools) tool \(tools == 1 ? "call" : "calls")") }
        if thoughts > 0 { parts.append("thought \(thoughts)×") }
        return (line.replacingOccurrences(of: "**", with: ""), parts.joined(separator: " · "))
    }
}

extension ChatItem {
    /// Your messages and the commands you run each start a new turn.
    var startsTurn: Bool {
        switch kind {
        case .user, .command: true
        default: false
        }
    }
}

struct TurnView: View {
    let turn: Turn
    @ObservedObject var store: ChatStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let user = turn.user, case .command(let cmd) = user.kind {
                MessageCard(role: .you, collapsed: binding(user.id), summary: cmd, detail: "command") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(cmd, systemImage: cmd.hasPrefix("!") ? "terminal" : "command")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        if let out = user.result, !out.isEmpty {
                            Text(out)
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            if let user = turn.user, case .user(let text) = user.kind {
                MessageCard(role: .you, collapsed: binding(user.id),
                            summary: text.split(separator: "\n").first.map(String.init) ?? text,
                            detail: (user.images ?? 0) > 0 ? "\(user.images!) image\(user.images! == 1 ? "" : "s")" : "") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let n = user.images, n > 0 { ImageBadge(count: n) }
                        if !text.isEmpty {
                            Text(text)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if !turn.replies.isEmpty {
                let summary = turn.replySummary
                MessageCard(role: .claude, collapsed: binding(turn.replyID),
                            summary: summary.text, detail: summary.detail) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(turn.replies) { ChatRow(item: $0) }
                    }
                }
            }
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { store.collapsed.contains(id) },
                set: { if $0 { store.collapsed.insert(id) } else { store.collapsed.remove(id) } })
    }
}

struct MessageCard<Content: View>: View {
    enum Role { case you, claude }
    let role: Role
    @Binding var collapsed: Bool
    let summary: String
    let detail: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy) { collapsed.toggle() }
            } label: {
                HStack(spacing: 8) {
                    avatar
                    Text(role == .you ? "You" : "Claude").fontWeight(.semibold)
                    if collapsed {
                        Text(summary)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if !detail.isEmpty {
                            Text(detail).font(.caption).foregroundStyle(.tertiary).fixedSize()
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Expand" : "Collapse")

            if !collapsed {
                content
                    .padding(.leading, 30)
                    .transition(.opacity)
            }
        }
        .padding(role == .you ? 12 : 0)
        .background {
            if role == .you {
                RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.09))
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.18))
            }
        }
    }

    private var avatar: some View {
        ZStack {
            Circle().fill(role == .you ? Color.accentColor : Color.orange.opacity(0.85))
            Image(systemName: role == .you ? "person.fill" : "sparkle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 22, height: 22)
    }
}

/// Your message the moment you send it, greyed out until Claude's log confirms it.
struct SendingMessage: View {
    let message: PendingMessage

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let slow = context.date.timeIntervalSince(message.sentAt) > 30
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(Color.secondary.opacity(0.35))
                        Image(systemName: "person.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    }
                    .frame(width: 22, height: 22)
                    Text("You").fontWeight(.semibold).foregroundStyle(.secondary)
                    Spacer()
                    if slow {
                        Label("Not confirmed yet — check the terminal view", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    } else {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("Sending").font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    if message.images > 0 { ImageBadge(count: message.images) }
                    if !message.text.isEmpty {
                        Text(message.text).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                .padding(.leading, 30)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.07)))
            .padding(.vertical, 14)
        }
        .transition(.opacity)
    }
}

struct ImageBadge: View {
    let count: Int

    var body: some View {
        Label("\(count) image\(count == 1 ? "" : "s") attached", systemImage: "photo")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Color.secondary.opacity(0.1)))
    }
}

struct QueuedMessage: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "clock").foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text("Queued — Claude will read this next").font(.caption).foregroundStyle(.secondary)
                Text(text).textSelection(.enabled).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .foregroundStyle(.tertiary))
        .padding(.vertical, 10)
    }
}

struct ChatRow: View {
    let item: ChatItem

    var body: some View {
        switch item.kind {
        case .user(let text):
            HStack {
                Spacer(minLength: 80)
                Text(text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(.top, 6)
        case .assistant(let text):
            MarkdownText(text)
        case .tool(let name, let summary, let added, let removed):
            ToolRow(name: name, summary: summary, added: added, removed: removed,
                    result: item.result, isError: item.isError)
        case .thinking(let text):
            ThinkingRow(text: text)
        case .command(let cmd):
            Label(cmd, systemImage: "command").font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
        case .recap(let text):
            VStack(alignment: .leading, spacing: 6) {
                Label("While you were away", systemImage: "clock.arrow.circlepath")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                MarkdownText(text)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        case .note(let text):
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }
}

/// Claude's live status line, like the one under its output in the terminal.
struct ActivityView: View {
    let activity: ClaudeActivity
    let working: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(activity.glyph == "·" || activity.glyph == "*" ? "✻" : activity.glyph)
                    .foregroundStyle(working ? Color.orange : Color.secondary)
                    .symbolEffect(.pulse, isActive: working)
                    .phaseAnimator(working ? [0.35, 1.0] : [1.0]) { v, o in v.opacity(o) } animation: { _ in .easeInOut(duration: 0.8) }
                Text(activity.headline)
                    .foregroundStyle(working ? .primary : .secondary)
                    .textSelection(.enabled)
            }
            .font(working ? .body : .callout)
            if working, !activity.details.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(activity.details.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.callout)
                            .foregroundStyle(line.hasPrefix("☒") || line.hasPrefix("✔") ? .secondary : .primary)
                            .strikethrough(line.hasPrefix("☒"))
                            .lineLimit(2)
                    }
                }
                .padding(.leading, 22)
            }
        }
        .padding(.top, 14)
        .animation(.easeOut(duration: 0.2), value: activity)
    }
}

struct ThinkingRow: View {
    let text: String
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { open.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain").foregroundStyle(.tertiary)
                    Text("Thinking").foregroundStyle(.secondary)
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                Text(text)
                    .font(.callout)
                    .italic()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 22)
            }
        }
    }
}

struct ToolRow: View {
    let name: String
    let summary: String
    let added: Int
    let removed: Int
    let result: String?
    let isError: Bool
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { open.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .foregroundStyle(isError ? .red : .secondary)
                        .frame(width: 16)
                    Text(name).fontWeight(.medium)
                    Text(displaySummary)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if added + removed > 0 {
                        Text("+\(added)").foregroundStyle(.green).font(.caption.monospacedDigit())
                        if removed > 0 {
                            Text("−\(removed)").foregroundStyle(.red).font(.caption.monospacedDigit())
                        }
                    }
                    Spacer(minLength: 0)
                    if result == nil {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: open ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                ScrollView {
                    Text(detail)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 320)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private var displaySummary: String {
        let home = "/home/"
        if summary.hasPrefix(home), let slash = summary.dropFirst(home.count).firstIndex(of: "/") {
            // Show paths relative to the home folder, which is all the same anyway.
            return "~" + summary[slash...]
        }
        return summary.replacingOccurrences(of: "\n", with: " ")
    }

    private var detail: String {
        var text = summary
        if let result, !result.isEmpty { text += "\n\n" + result }
        return text
    }

    private var icon: String {
        switch name {
        case "Bash": "terminal"
        case "Read": "doc.text"
        case "Edit", "MultiEdit": "pencil"
        case "Write": "square.and.pencil"
        case "Grep", "Glob": "magnifyingglass"
        case "WebFetch", "WebSearch": "globe"
        case "Task", "Agent": "person.2"
        case "TodoWrite": "checklist"
        default: "wrench.and.screwdriver"
        }
    }
}

/// Renders Claude's Markdown: paragraphs with inline formatting, headings,
/// and code blocks. Each block is selectable like normal text.
struct MarkdownText: View {
    let blocks: [Block]

    enum Block: Hashable {
        case text(String)
        case heading(String, Int)
        case code(String)
    }

    init(_ source: String) {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        func flush() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !text.isEmpty { blocks.append(.text(text)) }
            paragraph = []
        }
        for line in source.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let c = code { blocks.append(.code(c.joined(separator: "\n"))); code = nil }
                else { flush(); code = [] }
                continue
            }
            if code != nil { code!.append(line); continue }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flush(); continue }
            if let m = line.firstMatch(of: try! Regex(#"^(#{1,4})\s+(.*)$"#)),
               let hashes = m[1].substring, let title = m[2].substring {
                flush(); blocks.append(.heading(String(title), hashes.count)); continue
            }
            paragraph.append(line)
        }
        if let c = code { blocks.append(.code(c.joined(separator: "\n"))) }
        flush()
        self.blocks = blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let s):
                    let prs = Self.prURLs(in: s)
                    // A paragraph that is only PR links becomes chips; otherwise chips go under it.
                    if prs.isEmpty || !Self.isOnlyLinks(s, prs) {
                        Text(Self.inline(s))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !prs.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(prs, id: \.self) { PRChip(url: $0) }
                        }
                    }
                case .heading(let s, let level):
                    Text(Self.inline(s))
                        .font(level <= 2 ? .title3.weight(.semibold) : .headline)
                        .textSelection(.enabled)
                        .padding(.top, 4)
                case .code(let s):
                    ScrollView(.horizontal) {
                        Text(s)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(12)
                    }
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Distinct GitHub PR links in a paragraph, in order.
    static func prURLs(in s: String) -> [String] {
        var seen = Set<String>()
        return s.matches(of: PRStore.urlPattern).map { String(s[$0.range]) }.filter { seen.insert($0).inserted }
    }

    static func isOnlyLinks(_ s: String, _ urls: [String]) -> Bool {
        var rest = s
        for u in urls { rest = rest.replacingOccurrences(of: u, with: "") }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>()[]-*•·,"))).isEmpty
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}
