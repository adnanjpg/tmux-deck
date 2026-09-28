import AppKit
import SwiftUI

/// One open window/pane/terminal, as shown in the switcher.
struct TabInfo: Identifiable, Equatable {
    var tag: String
    var title: String
    var subtitle: String
    var icon: String
    var stateColor: Color?
    var id: String { tag }

    static func iconAndColor(for state: WindowState) -> (String, Color?) {
        switch state {
        case .claudeWorking: ("sparkle", .blue)
        case .claudeNeedsYou: ("exclamationmark.bubble.fill", .orange)
        case .claudeReady: ("sparkle", nil)
        case .shell: ("terminal", nil)
        case .running: ("gearshape", nil)
        }
    }
}

/// One column in the switcher: a server (or "This Mac · terminals") and its open tabs.
struct TabGroup: Identifiable {
    var label: String
    var items: [TabInfo]
    var id: String { label }
}

/// A Windows-style Alt-Tab: hold ⌃ and tap ⇥ (or ⇧⇥) to step through every open
/// window grouped by server, in a floating HUD; release ⌃ to switch to whichever
/// is highlighted, or Esc to cancel without switching. The order is captured once
/// when the HUD opens, so it doesn't reshuffle under you while you're cycling.
@MainActor
final class TabSwitcherController: ObservableObject {
    static let shared = TabSwitcherController()

    @Published private(set) var visible = false
    @Published private(set) var groups: [TabGroup] = []
    @Published private(set) var highlightedTag: String?
    /// The tab you were on when the switcher opened — "you are here".
    @Published private(set) var originTag: String?
    /// Screen-text previews, one per tab, fetched lazily as you land on each one.
    @Published private(set) var previews: [String: String] = [:]
    @Published private(set) var previewsLoading: Set<String> = []

    private var panel: NSPanel?
    private var monitorsInstalled = false
    private var previewTasks: [String: Task<Void, Never>] = [:]

    private var flatTags: [String] { groups.flatMap { $0.items.map(\.tag) } }

    /// ⌃⇥ / ⌃⇧⇥: open the HUD on the first press, or step the highlight on the next ones.
    func advance(_ delta: Int) {
        if !visible {
            let snapshot = AppModel.shared.groupedTabs()
            let flat = snapshot.flatMap { $0.items.map(\.tag) }
            guard flat.count > 1 else {
                // Nothing to switch to — just cycle in place if there's exactly one, else no-op.
                if let only = flat.first { LayoutModel.shared.show(only) }
                return
            }
            groups = snapshot
            originTag = LayoutModel.shared.focusedTag
            let current = originTag.flatMap { flat.firstIndex(of: $0) }
            highlightedTag = flat[step(from: current ?? -1, by: delta, count: flat.count)]
            visible = true
            present()
        } else {
            let tags = flatTags
            guard !tags.isEmpty else { return }
            let current = highlightedTag.flatMap { tags.firstIndex(of: $0) } ?? -1
            highlightedTag = tags[step(from: current, by: delta, count: tags.count)]
        }
        loadPreview(for: highlightedTag)
    }

    /// Fetches (and caches for this switcher session) what the highlighted tab's
    /// screen currently shows: a live read for a plain terminal, a quick
    /// `tmux capture-pane` for anything tmux-backed.
    private func loadPreview(for tag: String?) {
        guard let tag, previews[tag] == nil, previewTasks[tag] == nil else { return }
        previewsLoading.insert(tag)
        previewTasks[tag] = Task {
            let text = await Self.fetchPreview(tag: tag)
            self.previews[tag] = text
            self.previewsLoading.remove(tag)
            self.previewTasks[tag] = nil
        }
    }

    private static func fetchPreview(tag: String) async -> String {
        if let t = PlainTerminalStore.shared.terminal(forTag: tag) {
            let text = t.view.visibleScreenText()
            return text.isEmpty ? "(nothing on screen yet)" : text
        }
        guard let (server, window) = TileResolver.resolve(tag) else { return "" }
        let target = window.paneID.isEmpty ? window.windowTarget : window.paneID
        let result = await server.remote.run("tmux capture-pane -p -t \(sq(target)) -S -16", timeout: 8)
        guard result.ok else { return "(couldn't read this window)" }
        let lines = stripANSI(result.stdout).split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let nonEmpty = lines.filter { !$0.isEmpty }
        return nonEmpty.suffix(10).joined(separator: "\n")
    }

    private func step(from index: Int, by delta: Int, count: Int) -> Int {
        let base = index == -1 ? (delta > 0 ? -1 : 0) : index
        return (base + delta + count) % count
    }

    /// ⌃ released while the HUD is up: switch to the highlighted tab.
    func commit() {
        guard visible, let tag = highlightedTag else { dismiss(); return }
        dismiss()
        LayoutModel.shared.show(tag)
    }

    /// Esc while the HUD is up: close it, staying on whatever was already showing.
    func cancel() { dismiss() }

    private func dismiss() {
        visible = false
        highlightedTag = nil
        originTag = nil
        for task in previewTasks.values { task.cancel() }
        previewTasks = [:]
        previews = [:]
        previewsLoading = []
        panel?.close()
        panel = nil
    }

    private func present() {
        let hosting = NSHostingView(rootView: TabSwitcherHUD().environmentObject(self))
        let size = hosting.fittingSize
        let panel = self.panel ?? NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.setContentSize(size)
        panel.contentView = hosting
        if let screen = NSApp.keyWindow?.screen ?? NSScreen.main {
            let f = screen.frame
            panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.midY - size.height / 2))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    // MARK: Key monitoring

    /// Watches for ⌃ being released (commit) or Esc (cancel) while the HUD is showing.
    /// Advancing itself happens through the ⌃⇥ / ⌃⇧⇥ menu commands, same as any shortcut.
    func installMonitors() {
        guard !monitorsInstalled else { return }
        monitorsInstalled = true
        NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self, self.visible else { return event }
            if event.type == .flagsChanged, !event.modifierFlags.contains(.control) {
                self.commit()
                return event
            }
            if event.type == .keyDown, event.keyCode == 53 { // Esc
                self.cancel()
                return nil
            }
            return event
        }
    }
}

/// The floating switcher itself: columns of groups, each a stack of rows, the
/// highlighted one picked out with an accent ring — same idea as Windows' grouped
/// Alt-Tab or GNOME's window switcher.
private struct TabSwitcherHUD: View {
    @EnvironmentObject private var controller: TabSwitcherController
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            HStack(alignment: .top, spacing: 18) {
                ForEach(controller.groups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        VStack(spacing: 3) {
                            ForEach(group.items) { item in
                                row(item)
                            }
                        }
                    }
                    .frame(width: 240, alignment: .leading)
                }
            }
            Divider()
            preview
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(theme.line))
        .fixedSize()
    }

    private func row(_ item: TabInfo) -> some View {
        let on = item.tag == controller.highlightedTag
        let here = item.tag == controller.originTag
        return HStack(spacing: 8) {
            Image(systemName: item.icon)
                .foregroundStyle(item.stateColor ?? .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title).lineLimit(1).font(.callout)
                Text(item.subtitle).lineLimit(1).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if here {
                Text("current")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(on ? theme.tint.opacity(0.18) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(on ? theme.tint : (here ? theme.line : Color.clear), lineWidth: on ? 1.5 : 1))
    }

    /// A live look at whatever the highlighted tab's screen currently shows —
    /// the same idea as the big thumbnail in Windows' Alt-Tab, done as text
    /// since our "windows" are chat and terminal content, not window surfaces.
    @ViewBuilder private var preview: some View {
        let tag = controller.highlightedTag
        let item = controller.groups.flatMap(\.items).first { $0.tag == tag }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let item {
                    Image(systemName: item.icon).foregroundStyle(item.stateColor ?? .secondary)
                    Text(item.title).font(.callout.weight(.semibold)).lineLimit(1)
                }
                Spacer()
                if tag != nil && tag == controller.originTag {
                    Text("current").font(.caption2).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                Text((tag.flatMap { controller.previews[$0] }?.isEmpty == false ? controller.previews[tag!]! : " "))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .textSelection(.disabled)
            }
            .frame(maxHeight: .infinity)
            .overlay {
                if let tag, controller.previewsLoading.contains(tag) {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(10)
        .frame(width: 340, height: 260, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.05)))
    }
}
