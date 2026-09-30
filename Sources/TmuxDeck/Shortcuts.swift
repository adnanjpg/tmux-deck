import SwiftUI

/// ⌘/ — the shortcut list, which until now existed only in the README.
struct ShortcutsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.fonts) private var fonts
    @Environment(\.dismiss) private var dismiss

    private struct Group: Identifiable {
        var title: String
        var items: [(String, String)]
        var id: String { title }
    }

    private let groups: [Group] = [
        Group(title: "Windows", items: [
            ("New Claude window", "⌘N"),
            ("New Codex window", "⌥⌘N"),
            ("New terminal window", "⌘T"),
            ("New Mac terminal (no tmux)", "⇧⌘T"),
            ("Close what's focused", "⌘W"),
            ("Previous / next window", "⌘[  ⌘]"),
            ("Go to window 1–9", "⌘1 … ⌘9"),
            ("Switch windows (hold ⌃)", "⌃⇥  ⌃⇧⇥"),
        ]),
        Group(title: "Layout", items: [
            ("Split right / down", "⌘D  ⇧⌘D"),
            ("Back to one tile", "⇧⌘U"),
            ("Show as terminal / chat", "⌥⌘T"),
            ("Full screen", "⌃⌘F"),
        ]),
        Group(title: "Panels", items: [
            ("Files", "⇧⌘E"),
            ("Changes against the base branch", "⇧⌘G"),
            ("Past conversations", "⇧⌘O"),
            ("Pull requests", "⇧⌘P"),
            ("Find — in the chat, a terminal or the console", "⌘F"),
            ("Next / previous match in a terminal", "⌘G  ⇧⌘G"),
        ]),
        Group(title: "Reading", items: [
            ("Bigger / smaller / normal text", "⌘+  ⌘−  ⌘0"),
            ("Copy all output", "⇧⌘C"),
            ("Save the file you're editing", "⌘S"),
        ]),
        Group(title: "In the message box", items: [
            ("Send", "↩"),
            ("New line", "⇧↩"),
            ("Take Claude's suggestion", "⇥"),
            ("Change mode", "⇧⇥"),
            ("Stop", "Esc"),
            ("Interrupt", "⌃C"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard shortcuts").font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading),
                                    GridItem(.flexible(), alignment: .topLeading)],
                          alignment: .leading, spacing: 20) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.title).font(fonts.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(group.items, id: \.0) { item in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(item.0).font(fonts.callout)
                                    Spacer(minLength: 12)
                                    Text(item.1)
                                        .font(fonts.callout.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 620, height: 520)
        .background(theme.bg)
    }
}
