import AppKit
import SwiftTerm
import SwiftUI

/// ⌘F inside a terminal.
///
/// SwiftTerm has had a search engine all along (`findNext`, `findPrevious`,
/// `searchMatchSummary`); this is the bar that drives it, so the raw tmux terminal and the
/// plain terminals can be searched like anything else.
struct TerminalSearchBar: View {
    @Environment(\.theme) private var theme
    @Environment(\.fonts) private var fonts
    let terminal: TerminalView
    var onClose: () -> Void

    @State private var query = ""
    @State private var index = 0
    @State private var total = 0
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in this terminal", text: $query)
                .textFieldStyle(.plain)
                .font(fonts.callout)
                .focused($focused)
                .onSubmit { step(forward: true) }
                .onChange(of: query) { _, _ in refresh() }
            Text(label)
                .font(fonts.caption.monospacedDigit())
                .foregroundStyle(total == 0 && !query.isEmpty ? .orange : .secondary)
            Button { step(forward: false) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless).disabled(total == 0)
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .help("Previous match (⇧⌘G)")
            Button { step(forward: true) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).disabled(total == 0)
                .keyboardShortcut("g", modifiers: [.command])
                .help("Next match (⌘G)")
            Button(action: close) { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .onExitCommand(perform: close)
        .onAppear { focused = true }
    }

    private var label: String {
        if query.isEmpty { return "" }
        return total == 0 ? "no matches" : "\(index) of \(total)"
    }

    private func refresh() {
        guard !query.isEmpty else {
            terminal.clearSearch()
            index = 0; total = 0
            return
        }
        // Searching from the top each time the query changes, so the count means something.
        _ = terminal.findNext(query)
        let summary = terminal.searchMatchSummary(query)
        index = summary.index
        total = summary.total
    }

    private func step(forward: Bool) {
        guard !query.isEmpty else { return }
        _ = forward ? terminal.findNext(query) : terminal.findPrevious(query)
        let summary = terminal.searchMatchSummary(query)
        index = summary.index
        total = summary.total
    }

    private func close() {
        terminal.clearSearch()
        onClose()
    }
}

extension Notification.Name {
    /// Posted when ⌘F is pressed while a terminal has focus.
    static let findInTerminal = Notification.Name("TmuxDeckFindInTerminal")
}
