import SwiftUI

/// A Claude window shown as a normal Mac chat: your messages, Claude's replies,
/// and the tools it used. Claude keeps running in tmux; this just reads its log.
struct ChatView: View {
    @EnvironmentObject private var model: TmuxModel
    let window: TmuxWindow
    @ObservedObject var store: ChatStore

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(store.items) { item in
                        ChatRow(item: item)
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
            }
            .defaultScrollAnchor(.bottom)
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
            Divider()
            ComposeBar(window: window)
                .id(window.id)
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
        .padding(.top, 4)
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
                    Text(Self.inline(s))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
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

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}
