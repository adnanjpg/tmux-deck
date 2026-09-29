import AppKit
import SwiftUI

/// Pick a finished conversation to reopen, read-only.
struct HistoryView: View {
    @Environment(\.theme) private var theme
    @Environment(\.fonts) private var fonts
    @Environment(\.dismiss) private var dismiss
    let host: String
    @ObservedObject var store: HistoryStore
    @State private var selected: PastConversation?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 720, height: 560)
        .background(theme.bg)
        .task { if store.conversations.isEmpty { await store.load() } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Past conversations").font(.title3.weight(.semibold))
                Spacer()
                if store.loading { ProgressView().controlSize(.small) }
                Button { Task { await store.load() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Reload")
            }
            Text("Everything \(host == Remote.localHost ? "this Mac" : host) still has on disk, newest first. Opening one shows it read-only — the session it belonged to is gone.")
                .font(fonts.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("Search titles, first messages and folders", text: $store.search)
                    .textFieldStyle(.roundedBorder)
                Menu {
                    Button("All folders") { store.onlyThisFolder = nil }
                    Divider()
                    ForEach(store.folders.prefix(30), id: \.self) { folder in
                        Button((folder as NSString).lastPathComponent) { store.onlyThisFolder = folder }
                    }
                } label: {
                    Text(store.onlyThisFolder.map { ($0 as NSString).lastPathComponent } ?? "All folders")
                }
                .fixedSize()
            }
        }
        .padding(16)
    }

    @ViewBuilder private var content: some View {
        if let error = store.error {
            ContentUnavailableView("Can't read the history", systemImage: "clock.badge.xmark",
                                   description: Text(error))
        } else if store.conversations.isEmpty && store.loading {
            ProgressView("Looking for conversations…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.visible.isEmpty {
            ContentUnavailableView("Nothing matches", systemImage: "magnifyingglass",
                                   description: Text("No conversation matches that search."))
        } else {
            List(store.visible, selection: Binding(get: { selected?.id }, set: { id in
                selected = store.visible.first { $0.id == id }
            })) { item in
                row(item)
                    .tag(item.id)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { open(item) }
                    .onTapGesture { selected = item }
            }
            .listStyle(.inset)
        }
    }

    private func row(_ item: PastConversation) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.assistant.systemImage)
                .foregroundStyle(item.assistant == .claude ? Color.orange : Color.accentColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label).lineLimit(1).font(fonts.callout.weight(.medium))
                HStack(spacing: 6) {
                    Text(item.folderName).font(fonts.caption).foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Text(item.ageLabel).font(fonts.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            Text(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
                .font(fonts.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .help(item.preview.isEmpty ? item.path : item.preview)
    }

    private var footer: some View {
        HStack {
            Text("\(store.visible.count) of \(store.conversations.count)")
                .font(fonts.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Open") { if let selected { open(selected) } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil)
        }
        .padding(16)
    }

    private func open(_ item: PastConversation) {
        LayoutModel.shared.show(PastTile.tag(host: host, item))
        dismiss()
    }
}

/// A finished conversation in a tile.
struct PastChatView: View {
    @Environment(\.theme) private var theme
    @Environment(\.fonts) private var fonts
    let host: String
    let assistant: CodingAssistant
    let sessionID: String
    let path: String

    var body: some View {
        ChatView(window: nil, store: store)
            .id(path)
    }

    /// Its own store, kept apart from any live one for the same session so a finished
    /// conversation can't be confused with a running chat.
    private var store: ChatStore {
        PastStores.shared.store(host: host, assistant: assistant, sessionID: sessionID, path: path)
    }
}

@MainActor
final class PastStores {
    static let shared = PastStores()
    private var stores: [String: ChatStore] = [:]

    func store(host: String, assistant: CodingAssistant, sessionID: String, path: String) -> ChatStore {
        let key = host + "\u{1}" + path
        if let existing = stores[key] { return existing }
        let store = ChatStore(sessionID: sessionID, remote: Remote(host: host),
                              assistant: assistant, path: path)
        stores[key] = store
        return store
    }
}
