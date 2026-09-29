import SwiftUI

/// An assistant's window shown as a normal Mac chat: your messages, its replies, and the tools
/// it used. The assistant keeps running in tmux; this just reads its log.
///
/// With no `window` it's a finished conversation opened from history: the same rendering, with
/// nothing you could type into, since there's no process left to type at.
struct ChatView: View {
    @Environment(\.fonts) private var fonts
    @Environment(\.theme) private var theme
    @EnvironmentObject private var model: TmuxModel
    var window: TmuxWindow?
    @ObservedObject var store: ChatStore
    /// How many of the latest turns are rendered; older ones load on request.
    @State private var visibleTurns = 25
    /// Whether the bottom of the chat is on screen, so new messages keep it pinned there.
    @State private var atBottom = true

    var body: some View {
        VStack(spacing: 0) {
            if !turns.isEmpty { chatHeader }
            if let stale = store.stale {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(stale).font(fonts.caption)
                    Spacer(minLength: 4)
                    Button("Try now") { Task { await store.catchUp() } }
                        .buttonStyle(.borderless).font(fonts.caption)
                }
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(Color.orange.opacity(0.12))
                .overlay(alignment: .bottom) { Divider() }
            }
            if store.searching { searchBar }
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let all = turns
                    if all.count > visibleTurns && !store.searching {
                        Button {
                            visibleTurns += 25
                        } label: {
                            Label("Show earlier messages (\(all.count - visibleTurns) more turns)", systemImage: "arrow.up.circle")
                        }
                        .buttonStyle(.borderless)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 8)
                    }
                    ForEach(store.searching ? all : Array(all.suffix(visibleTurns))) { turn in
                        TurnView(turn: turn, store: store)
                    }
                    // A finished conversation's leftover queue records are history, not a queue.
                    if window != nil {
                        ForEach(Array(store.queued.enumerated()), id: \.offset) { _, text in
                            QueuedMessage(text: text)
                        }
                    }
                    if let window {
                        ForEach(store.sending) { pending in
                            SendingMessage(message: pending, window: window, store: store)
                        }
                    }
                    if let window, let activity = model.activities[window.id] {
                        ActivityView(activity: activity, working: window.state == .claudeWorking)
                    } else if window?.state == .claudeWorking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("\(store.assistant.displayName) is working…").foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)
                    }
                }
                .frame(maxWidth: 860, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
                Color.clear.frame(height: 1).id("bottom")
                    .onAppear { atBottom = true }
                    .onDisappear { atBottom = false }
            }
            .defaultScrollAnchor(.bottom)
            .onAppear {
                // Lazy rows settle their heights over a few frames, so land on the bottom more than once.
                for delay in [0.05, 0.25, 0.6, 1.2] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            .onChange(of: store.loaded) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: store.items.count) { _, _ in
                if atBottom { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            .onChange(of: store.sending.count) { _, n in
                if n > 0 { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            .overlay(alignment: .topTrailing) {
                if store.refreshing && store.loaded {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Updating").font(fonts.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .padding(10)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: store.refreshing)
            .overlay {
                if !store.loaded && store.items.isEmpty {
                    ProgressView("Loading conversation…")
                } else if store.items.isEmpty && store.sending.isEmpty {
                    ContentUnavailableView(window == nil ? "Nothing in this conversation" : "New conversation",
                                           systemImage: "sparkle",
                                           description: Text(window == nil
                                                             ? "Its log has no messages left to read."
                                                             : "Send \(store.assistant.displayName) a message to get started."))
                }
            }
            }
            if let window {
                Divider()
                VStack(spacing: 0) {
                    ComposeBar(window: window)
                        .id(window.id)
                    // The chips act by typing Claude's own commands (/model, /effort, Shift+Tab
                    // mode cycling), which mean nothing to Codex — and its screen doesn't carry
                    // Claude's status line to read in the first place.
                    if store.assistant == .claude { StatusBar(window: window) }
                }
                .background(theme.panel)
            }
        }
        .background(theme.bg)
        .onReceive(NotificationCenter.default.publisher(for: .findInChat)) { _ in
            withAnimation(.snappy) { store.searching = true }
        }
        .task(id: store.sessionID) {
            await store.catchUp()
            // A finished conversation isn't going to change, so read it once.
            guard window != nil else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(window?.state == .claudeWorking ? 1 : 2))
                await store.poll()
            }
        }
    }
}

extension ChatView {
    /// While a search is on, only the turns that match it are shown — the point is to find the
    /// exchange, and the transcript is too long to highlight in place usefully.
    private var turns: [Turn] {
        let all = Turn.group(store.items)
        let query = store.search.trimmingCharacters(in: .whitespaces)
        guard store.searching, !query.isEmpty else { return all }
        return all.filter { turn in
            let items = (turn.user.map { [$0] } ?? []) + turn.replies
            return items.contains { ChatStore.haystack($0).localizedCaseInsensitiveContains(query) }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in this conversation", text: $store.search)
                .textFieldStyle(.plain)
                .font(fonts.callout)
                .onSubmit { }
            if !store.search.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("\(turns.count) \(turns.count == 1 ? "turn" : "turns")")
                    .font(fonts.caption).foregroundStyle(.secondary)
            }
            Button {
                withAnimation(.snappy) { store.searching = false }
                store.search = ""
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(theme.panel)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var chatHeader: some View {
        let ids = turns.flatMap { $0.cardIDs }
        let allCollapsed = !ids.isEmpty && ids.allSatisfy(store.collapsed.contains)
        return HStack(spacing: 10) {
            if let window {
                StateBadge(state: window.state, done: model.unseenDone.contains(window.id))
            } else {
                Label("Finished", systemImage: "clock.arrow.circlepath")
                    .font(fonts.caption).foregroundStyle(.secondary)
            }
            Text("\(turns.count) \(turns.count == 1 ? "turn" : "turns")")
                .font(fonts.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                withAnimation(.snappy) { store.searching.toggle() }
                if !store.searching { store.search = "" }
            } label: {
                Label("Find", systemImage: "magnifyingglass")
            }
            .help("Search this conversation (⌘F)")
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
        .background(theme.panel)
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
    @Environment(\.fonts) private var fonts
    let turn: Turn
    @ObservedObject var store: ChatStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let user = turn.user, case .command(let cmd) = user.kind {
                MessageCard(role: .you, collapsed: binding(user.id), summary: cmd, detail: "command") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(cmd, systemImage: cmd.hasPrefix("!") ? "terminal" : "command")
                            .font(fonts.monoBody)
                            .textSelection(.enabled)
                        if let out = user.result, !out.isEmpty {
                            Text(out)
                                .font(fonts.mono)
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
                                .contextMenu { CopyItems(text: text, what: "message") }
                        }
                    }
                }
            }
            if !turn.replies.isEmpty {
                let summary = turn.replySummary
                MessageCard(role: .assistant(store.assistant), collapsed: binding(turn.replyID),
                            summary: summary.text, detail: summary.detail) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(turn.replies) { ChatRow(item: $0) }
                    }
                }
            }
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
        .contextMenu {
            Button("Copy this turn") { Clipboard.put(turn.asText(store.assistant)) }
            Button("Copy the whole conversation") {
                Clipboard.put(Turn.group(store.items).map { $0.asText(store.assistant) }
                    .joined(separator: "\n\n---\n\n"))
            }
        }
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { store.collapsed.contains(id) },
                set: { if $0 { store.collapsed.insert(id) } else { store.collapsed.remove(id) } })
    }
}

struct MessageCard<Content: View>: View {
    @Environment(\.fonts) private var fonts
    @Environment(\.theme) private var theme
    enum Role: Equatable {
        case you
        case assistant(CodingAssistant)
        var isYou: Bool { self == .you }
        var name: String {
            if case .assistant(let a) = self { return a.displayName }
            return "You"
        }
        var glyph: String {
            if case .assistant(let a) = self { return a.systemImage }
            return "person.fill"
        }
    }
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
                    Text(role.name).fontWeight(.semibold)
                    if collapsed {
                        Text(summary)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if !detail.isEmpty {
                            Text(detail).font(fonts.caption).foregroundStyle(.tertiary).fixedSize()
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                        .font(fonts.caption.weight(.semibold))
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
        .padding(role.isYou ? 12 : 0)
        .background {
            if role.isYou {
                RoundedRectangle(cornerRadius: 12).fill(theme.tint.opacity(0.09))
                RoundedRectangle(cornerRadius: 12).strokeBorder(theme.tint.opacity(0.18))
            }
        }
    }

    private var avatar: some View {
        ZStack {
            Circle().fill(role.isYou ? theme.tint : Color.orange.opacity(0.85))
            Image(systemName: role.glyph)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 22, height: 22)
    }
}

/// Your message the moment you send it, greyed out until Claude's log confirms it.
/// If it gets stuck, it says why and offers a fix.
struct SendingMessage: View {
    @Environment(\.fonts) private var fonts
    @EnvironmentObject private var model: TmuxModel
    let message: PendingMessage
    let window: TmuxWindow
    @ObservedObject var store: ChatStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 3)) { context in
            let reason = model.stuckReasons[message.id]
            let slow = context.date.timeIntervalSince(message.sentAt) > 25
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(Color.secondary.opacity(0.35))
                        Image(systemName: "person.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    }
                    .frame(width: 22, height: 22)
                    Text("You").fontWeight(.semibold).foregroundStyle(.secondary)
                    Spacer()
                    if reason == nil && !slow {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("Sending").font(fonts.caption)
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
                if reason != nil || slow {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(reason ?? "Claude hasn't picked this up yet.", systemImage: "exclamationmark.triangle.fill")
                            .font(fonts.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Button("Press Enter") { model.send(keys: ["Enter"], to: window) }
                                .help("Submit whatever is in Claude's input box")
                            Button("Open terminal") { model.showTerminal(for: window) }
                                .help("See exactly what Claude's screen shows")
                            Button("Dismiss") { store.dismissSending(message.id) }
                                .help("Remove this from the chat (doesn't unsend anything)")
                        }
                        .controlSize(.small)
                    }
                    .padding(.leading, 30)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.07)))
            .overlay {
                if reason != nil {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.5))
                }
            }
            .padding(.vertical, 14)
        }
        .transition(.opacity)
    }
}

struct ImageBadge: View {
    @Environment(\.fonts) private var fonts
    let count: Int

    var body: some View {
        Label("\(count) image\(count == 1 ? "" : "s") attached", systemImage: "photo")
            .font(fonts.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Color.secondary.opacity(0.1)))
    }
}

struct QueuedMessage: View {
    @Environment(\.fonts) private var fonts
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "clock").foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text("Queued — Claude will read this next").font(fonts.caption).foregroundStyle(.secondary)
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
    @Environment(\.fonts) private var fonts
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
            Label(cmd, systemImage: "command").font(fonts.mono).foregroundStyle(.secondary)
        case .recap(let text):
            VStack(alignment: .leading, spacing: 6) {
                Label("While you were away", systemImage: "clock.arrow.circlepath")
                    .font(fonts.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                MarkdownText(text)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        case .note(let text):
            Text(text)
                .font(fonts.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }
}

/// Claude's live status line, like the one under its output in the terminal.
struct ActivityView: View {
    @Environment(\.fonts) private var fonts
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
            .font(working ? fonts.body : fonts.callout)
            if working, !activity.details.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(activity.details.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(fonts.callout)
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
    @Environment(\.fonts) private var fonts
    let text: String
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { open.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain").foregroundStyle(.tertiary)
                    Text("Thinking").foregroundStyle(.secondary)
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(fonts.caption).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                Text(text)
                    .font(fonts.callout)
                    .italic()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 22)
            }
        }
    }
}

struct ToolRow: View {
    @Environment(\.fonts) private var fonts
    @Environment(\.theme) private var theme
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
                        .font(fonts.mono)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if added + removed > 0 {
                        Text("+\(added)").foregroundStyle(.green).font(fonts.caption.monospacedDigit())
                        if removed > 0 {
                            Text("−\(removed)").foregroundStyle(.red).font(fonts.caption.monospacedDigit())
                        }
                    }
                    Spacer(minLength: 0)
                    if result == nil {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: open ? "chevron.down" : "chevron.right")
                            .font(fonts.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                ScrollView {
                    Text(detail)
                        .font(fonts.monoCaption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 320)
                .background(theme.code, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.line))
                .overlay(alignment: .topTrailing) { CopyButton(text: detail).padding(6) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.widget, in: RoundedRectangle(cornerRadius: 10))
        .contextMenu {
            Button("Copy what it ran") { Clipboard.put(displaySummary) }
            if result != nil { Button("Copy the output") { Clipboard.put(detail) } }
        }
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

/// A Markdown table: bold header, aligned columns, zebra rows, inline formatting in cells.
struct TableView: View {
    @Environment(\.theme) private var theme
    let header: [String]
    let alignments: [MarkdownText.TableAlignment]
    let rows: [[String]]

    var body: some View {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<columns, id: \.self) { c in
                        cell(c < header.count ? header[c] : "", column: c, bold: true)
                    }
                }
                .background(Color.secondary.opacity(0.12))
                ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(0..<columns, id: \.self) { c in
                            cell(c < row.count ? row[c] : "", column: c, bold: false)
                        }
                    }
                    .background(r % 2 == 1 ? Color.secondary.opacity(0.04) : Color.clear)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.line))
            .padding(.bottom, 2)
        }
    }

    private func cell(_ text: String, column: Int, bold: Bool) -> some View {
        let align = column < alignments.count ? alignments[column] : .leading
        let frameAlign: Alignment = align == .center ? .center : align == .trailing ? .trailing : .leading
        return Text(MarkdownText.inline(text.replacingOccurrences(of: "<br>", with: "\n")))
            .fontWeight(bold ? .semibold : .regular)
            .multilineTextAlignment(align == .center ? .center : align == .trailing ? .trailing : .leading)
            .textSelection(.enabled)
            .frame(minWidth: 60, maxWidth: 420, alignment: frameAlign)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .gridColumnAlignment(align == .center ? .center : align == .trailing ? .trailing : .leading)
    }
}

/// Renders Claude's Markdown: paragraphs with inline formatting, headings,
/// and code blocks. Each block is selectable like normal text.
struct MarkdownText: View {
    @Environment(\.fonts) private var fonts
    @Environment(\.theme) private var theme
    let blocks: [Block]

    enum Block: Hashable {
        case text(String)
        case heading(String, Int)
        case code(String)
        case table(header: [String], alignments: [TableAlignment], rows: [[String]])
    }

    enum TableAlignment: Hashable { case leading, center, trailing }

    private static let separatorPattern = try! Regex(#"^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$"#)

    /// "| a | b |" → ["a", "b"]; pipes inside `code` or escaped as \| are kept.
    static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
        var cells: [String] = [], current = "", inCode = false
        var chars = Array(t)[...]
        while let c = chars.popFirst() {
            if c == "\\", chars.first == "|" { current.append("|"); chars.removeFirst(); continue }
            if c == "`" { inCode.toggle() }
            if c == "|" && !inCode { cells.append(current.trimmingCharacters(in: .whitespaces)); current = ""; continue }
            current.append(c)
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
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
        let lines = source.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            defer { i += 1 }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if let c = code { blocks.append(.code(c.joined(separator: "\n"))); code = nil }
                else { flush(); code = [] }
                continue
            }
            if code != nil { code!.append(line); continue }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flush(); continue }
            // A table: a row of cells, then a |---|:---:| separator, then rows.
            if line.contains("|"), i + 1 < lines.count, lines[i + 1].wholeMatch(of: Self.separatorPattern) != nil {
                flush()
                let header = Self.cells(line)
                let alignments = Self.cells(lines[i + 1]).map { spec -> TableAlignment in
                    let left = spec.hasPrefix(":"), right = spec.hasSuffix(":")
                    return left && right ? .center : right ? .trailing : .leading
                }
                var rows: [[String]] = []
                var j = i + 2
                while j < lines.count, lines[j].contains("|"), !lines[j].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(Self.cells(lines[j]))
                    j += 1
                }
                blocks.append(.table(header: header, alignments: alignments, rows: rows))
                i = j - 1
                continue
            }
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
                case .table(let header, let alignments, let rows):
                    TableView(header: header, alignments: alignments, rows: rows)
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
                        .font(level <= 2 ? fonts.title3 : fonts.headline)
                        .textSelection(.enabled)
                        .padding(.top, 4)
                case .code(let s):
                    ScrollView(.horizontal) {
                        Text(SyntaxHighlighter.highlight(s, theme: theme))
                            .font(fonts.mono)
                            .textSelection(.enabled)
                            .padding(12)
                    }
                    .background(theme.code, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.line))
                    .overlay(alignment: .topTrailing) { CopyButton(text: s).padding(6) }
                    .contextMenu { CopyItems(text: s, what: "code") }
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

// MARK: Copying

enum Clipboard {
    static func put(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The copy entries every piece of chat text gets in its context menu.
struct CopyItems: View {
    let text: String
    let what: String

    var body: some View {
        Button("Copy \(what)") { Clipboard.put(text) }
        Button("Copy as quote") {
            Clipboard.put(text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> " + $0 }.joined(separator: "\n"))
        }
    }
}

/// A copy button that says it worked, for code blocks and tool output.
struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            Clipboard.put(text)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10, weight: .semibold))
                .padding(5)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .foregroundStyle(copied ? Color.green : Color.secondary)
        .help(copied ? "Copied" : "Copy")
    }
}

extension Turn {
    /// The turn as plain text, for the clipboard.
    func asText(_ assistant: CodingAssistant) -> String {
        var out: [String] = []
        if let user {
            switch user.kind {
            case .user(let t): out.append("You:\n" + t)
            case .command(let c): out.append("You ran: " + c)
            default: break
            }
            if let result = user.result, !result.isEmpty { out.append(result) }
        }
        var body: [String] = []
        for reply in replies {
            switch reply.kind {
            case .assistant(let t): body.append(t)
            case .thinking(let t): body.append("(thinking)\n" + t)
            case .tool(let name, let summary, _, _):
                body.append("[\(name)] \(summary)")
                if let result = reply.result, !result.isEmpty { body.append(result) }
            case .note(let t), .recap(let t): body.append(t)
            default: break
            }
        }
        if !body.isEmpty {
            out.append("\(assistant.displayName):\n" + body.joined(separator: "\n\n"))
        }
        return out.joined(separator: "\n\n")
    }
}
