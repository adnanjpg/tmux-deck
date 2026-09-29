import AppKit
import SwiftUI

/// Everything this worktree changes, against the branch it's meant to land on.
struct DiffView: View {
    @Environment(\.theme) private var theme
    @Environment(\.fonts) private var fonts
    let host: String
    let path: String
    @ObservedObject var store: DiffStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(theme.bg)
        .task(id: path) {
            await store.refresh()
            // Agents are writing to this tree while you look at it.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                await store.refresh()
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.trianglehead.branch").foregroundStyle(.secondary)
                Text(store.state?.branch ?? "…")
                    .font(fonts.callout.weight(.semibold)).lineLimit(1)
                if let state = store.state, !state.base.isEmpty {
                    Text("→").foregroundStyle(.tertiary)
                    baseMenu(state)
                }
                Spacer(minLength: 8)
                if store.loading { ProgressView().controlSize(.small) }
                worktreeMenu
                Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Reload")
            }
            HStack(spacing: 10) {
                if let state = store.state {
                    Text(summary(state)).font(fonts.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if !state.files.isEmpty {
                        Button(store.expanded.isEmpty ? "Expand all" : "Collapse all") {
                            store.expanded.isEmpty ? store.expandAll() : store.collapseAll()
                        }
                        .buttonStyle(.borderless).font(fonts.caption)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.panel)
    }

    private func summary(_ state: RepoState) -> String {
        var parts: [String] = []
        if state.files.isEmpty {
            parts.append(state.base.isEmpty ? "Nothing uncommitted" : "No changes against \(state.base)")
        } else {
            parts.append("\(state.files.count) file\(state.files.count == 1 ? "" : "s")")
            parts.append("+\(state.totalAdded) −\(state.totalRemoved)")
        }
        if state.ahead > 0 { parts.append("\(state.ahead) ahead") }
        if state.behind > 0 { parts.append("\(state.behind) behind") }
        if state.dirty { parts.append("uncommitted work included") }
        return parts.joined(separator: " · ")
    }

    private func baseMenu(_ state: RepoState) -> some View {
        Menu {
            Button("\(state.base) (picked automatically)") { store.baseOverride = nil; Task { await store.refresh() } }
            Divider()
            ForEach(["origin/dev", "origin/develop", "origin/main", "origin/master", "dev", "develop", "main", "master"], id: \.self) { name in
                Button(name) { store.baseOverride = name; Task { await store.refresh() } }
            }
        } label: {
            Text(state.base).font(fonts.callout).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Compare against a different branch")
    }

    @ViewBuilder private var worktreeMenu: some View {
        if let state = store.state, state.worktrees.count > 1 {
            Menu {
                Text("\(state.worktrees.count) worktrees")
                Divider()
                ForEach(state.worktrees) { tree in
                    Button {
                        LayoutModel.shared.show(DiffTile.tag(host: host, path: tree.path))
                    } label: {
                        Text(tree.path == state.root ? "✓ \(tree.branch)" : tree.branch)
                    }
                }
            } label: {
                Label("\(state.worktrees.count)", systemImage: "square.stack.3d.up")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Other worktrees of this repository")
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let error = store.error {
            ContentUnavailableView {
                Label("No diff to show", systemImage: "arrow.trianglehead.branch")
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { Task { await store.refresh() } }
            }
        } else if let state = store.state, state.files.isEmpty {
            ContentUnavailableView("Nothing changed here", systemImage: "checkmark.circle",
                                   description: Text(state.base.isEmpty
                                                     ? "The working tree matches the last commit."
                                                     : "This worktree matches \(state.base)."))
        } else if store.state == nil {
            ProgressView("Reading the repository…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                    ForEach(store.state?.files ?? []) { file in
                        fileRow(file)
                        if store.expanded.contains(file.path) {
                            patchBody(file)
                        }
                        Divider()
                    }
                }
                .padding(.bottom, 20)
            }
        }
    }

    private func fileRow(_ file: DiffFile) -> some View {
        HStack(spacing: 8) {
            Button { store.toggle(file) } label: {
                HStack(spacing: 8) {
                    Image(systemName: store.expanded.contains(file.path) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary).frame(width: 10)
                    Text(file.status).font(fonts.caption.monospaced().weight(.bold))
                        .foregroundStyle(file.statusColor).frame(width: 12)
                    Text(file.name).font(fonts.callout.weight(.medium)).lineLimit(1)
                    if !file.folder.isEmpty {
                        Text(file.folder).font(fonts.caption).foregroundStyle(.tertiary)
                            .lineLimit(1).truncationMode(.head)
                    }
                    Spacer(minLength: 8)
                    if file.binary {
                        Text("binary").font(fonts.caption2).foregroundStyle(.tertiary)
                    } else {
                        if file.added > 0 { Text("+\(file.added)").font(fonts.caption.monospacedDigit()).foregroundStyle(.green) }
                        if file.removed > 0 { Text("−\(file.removed)").font(fonts.caption.monospacedDigit()).foregroundStyle(.red) }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(file.binary)

            Button {
                let full = (store.state?.root ?? path) + "/" + file.path
                LayoutModel.shared.drop(tag: FileTile.tag(host: host, path: full),
                                        onto: LayoutModel.shared.focused, zone: .right)
            } label: {
                Image(systemName: "doc.text")
            }
            .buttonStyle(.borderless)
            .help("Open this file")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contextMenu {
            Button("Copy path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path, forType: .string)
            }
            if let patch = store.patches[file.path] {
                Button("Copy this diff") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(patch, forType: .string)
                }
            }
        }
    }

    @ViewBuilder private func patchBody(_ file: DiffFile) -> some View {
        if let patch = store.patches[file.path] {
            PatchText(patch: patch, font: fonts.nsMono)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Reading the diff…").font(fonts.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 34).padding(.bottom, 8)
        }
    }
}

/// A unified diff, coloured by line: additions green, removals red, hunk headers dim.
struct PatchText: View {
    @Environment(\.theme) private var theme
    let patch: String
    let font: NSFont

    var body: some View {
        let lines = patch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if !skip(line) {
                    Text(line.isEmpty ? " " : line)
                        .font(Font(font))
                        .foregroundStyle(color(line))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 0.5)
                        .background(background(line))
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: theme.terminalBackground ?? theme.background))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// git's own preamble is noise once the file is already named in the row above it.
    private func skip(_ line: String) -> Bool {
        line.hasPrefix("diff --git ") || line.hasPrefix("index ")
            || line.hasPrefix("--- ") || line.hasPrefix("+++ ")
            || line.hasPrefix("new file mode") || line.hasPrefix("deleted file mode")
            || line.hasPrefix("similarity index") || line.hasPrefix("rename from") || line.hasPrefix("rename to")
    }

    private func color(_ line: String) -> Color {
        if line.hasPrefix("@@") { return .secondary }
        if line.hasPrefix("+") { return .green }
        if line.hasPrefix("-") { return .red }
        return Color(nsColor: theme.terminalForeground ?? theme.foreground ?? .textColor)
    }

    private func background(_ line: String) -> Color {
        if line.hasPrefix("@@") { return Color.secondary.opacity(0.10) }
        if line.hasPrefix("+") { return Color.green.opacity(0.12) }
        if line.hasPrefix("-") { return Color.red.opacity(0.12) }
        return .clear
    }
}
