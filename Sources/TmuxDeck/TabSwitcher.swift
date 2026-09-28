import AppKit
import SwiftUI

/// One open window/pane/terminal, as shown in the switcher.
struct TabInfo: Identifiable, Equatable {
    var tag: String
    var title: String
    var subtitle: String
    var icon: String
    var stateColor: Color?
    /// The pane to capture a thumbnail from (nil for a plain terminal, read locally instead).
    var paneID: String?
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

/// A section of the switcher: one tmux session on one server, or this Mac's plain terminals.
struct TabGroup: Identifiable {
    var server: String
    var session: String?
    /// nil for the plain-terminals group; otherwise the server's ssh host.
    var host: String?
    var items: [TabInfo]

    var id: String { "\(host ?? "plain")|\(session ?? "")" }
    var label: String { session.map { "\(server)  ›  \($0)" } ?? server }
}

/// A Windows-style task switcher: hold ⌃ and tap ⇥ (or ⇧⇥) to bring up a grid of every
/// open window — grouped by server, then by tmux session — each showing a thumbnail of
/// what's actually on its screen. Release ⌃ to switch, Esc to stay put; arrow keys and
/// clicking work too. The list is captured when it opens, so nothing shuffles mid-cycle.
@MainActor
final class TabSwitcherController: ObservableObject {
    static let shared = TabSwitcherController()

    @Published private(set) var visible = false
    @Published private(set) var groups: [TabGroup] = []
    @Published private(set) var highlightedTag: String?
    /// Where the switch started from — "you are here".
    @Published private(set) var originTag: String?
    /// Each window's screen, as a picture, filled in as the captures come back.
    @Published private(set) var thumbnails: [String: NSImage] = [:]
    @Published private(set) var loadingThumbnails = true

    private var panel: NSPanel?
    private var monitorsInstalled = false
    private var captureTasks: [Task<Void, Never>] = []

    private var flatTags: [String] { groups.flatMap { $0.items.map(\.tag) } }

    // MARK: Cycling

    /// ⌃⇥ / ⌃⇧⇥: open the switcher on the first press, then step through it.
    func advance(_ delta: Int) {
        if !visible {
            let snapshot = AppModel.shared.groupedTabs()
            let flat = snapshot.flatMap { $0.items.map(\.tag) }
            guard flat.count > 1 else {
                if let only = flat.first { LayoutModel.shared.show(only) }
                return
            }
            groups = snapshot
            originTag = LayoutModel.shared.focusedTag
            let current = originTag.flatMap { flat.firstIndex(of: $0) }
            highlightedTag = flat[step(from: current ?? -1, by: delta, count: flat.count)]
            visible = true
            present()
            captureThumbnails()
        } else {
            let tags = flatTags
            guard !tags.isEmpty else { return }
            let current = highlightedTag.flatMap { tags.firstIndex(of: $0) } ?? -1
            highlightedTag = tags[step(from: current, by: delta, count: tags.count)]
        }
    }

    /// ↑ / ↓ while it's open: jump to the next or previous session group.
    func jumpGroup(_ delta: Int) {
        guard visible, !groups.isEmpty,
              let current = groups.firstIndex(where: { $0.items.contains { $0.tag == highlightedTag } })
        else { return }
        highlightedTag = groups[(current + delta + groups.count) % groups.count].items.first?.tag
    }

    func highlight(_ tag: String) { highlightedTag = tag }

    private func step(from index: Int, by delta: Int, count: Int) -> Int {
        let base = index == -1 ? (delta > 0 ? -1 : 0) : index
        return (base + delta + count) % count
    }

    /// ⌃ released (or ↩, or a click): switch to the highlighted window.
    func commit() {
        guard visible, let tag = highlightedTag else { dismiss(); return }
        dismiss()
        LayoutModel.shared.show(tag)
    }

    /// Esc: close the switcher and stay where you were.
    func cancel() { dismiss() }

    private func dismiss() {
        visible = false
        highlightedTag = nil
        originTag = nil
        thumbnails = [:]
        for task in captureTasks { task.cancel() }
        captureTasks = []
        panel?.close()
        panel = nil
    }

    // MARK: Thumbnails

    /// Captures every window's screen: one batched command per server (so ten windows on
    /// one server is still a single round trip), plus a local read for plain terminals.
    private func captureThumbnails() {
        loadingThumbnails = true
        let theme = ThemeManager.shared.theme
        let background = theme.terminalBackground ?? .black
        let foreground = theme.terminalForeground ?? .white

        for group in groups where group.host == nil {
            for item in group.items {
                guard let terminal = PlainTerminalStore.shared.terminal(forTag: item.tag) else { continue }
                let screen = AnsiScreen.parse(terminal.view.visibleScreenText(maxLines: 40))
                if !screen.isEmpty {
                    thumbnails[item.tag] = AnsiScreen.image(screen, background: background, foreground: foreground)
                }
            }
        }

        let byHost = Dictionary(grouping: groups.filter { $0.host != nil }, by: { $0.host! })
        var pending = byHost.count
        if pending == 0 { loadingThumbnails = false }
        for (host, hostGroups) in byHost {
            let items = hostGroups.flatMap(\.items).filter { $0.paneID != nil }
            guard let server = AppModel.shared.server(host), !items.isEmpty else {
                pending -= 1
                if pending <= 0 { loadingThumbnails = false }
                continue
            }
            let panes = items.compactMap(\.paneID)
            let script = "for p in \(panes.joined(separator: " ")); do printf '@@P %s\\n' \"$p\"; "
                + "tmux capture-pane -e -p -t \"$p\" 2>/dev/null; done"
            let task = Task { [weak self] in
                let result = await server.remote.run(script, timeout: 12)
                guard let self, !Task.isCancelled, self.visible else { return }
                let screens = Self.split(result.stdout)
                for item in items {
                    guard let paneID = item.paneID, let text = screens[paneID] else { continue }
                    let screen = AnsiScreen.parse(text)
                    if !screen.isEmpty {
                        self.thumbnails[item.tag] = AnsiScreen.image(screen, background: background, foreground: foreground)
                    }
                }
                pending -= 1
                if pending <= 0 { self.loadingThumbnails = false }
            }
            captureTasks.append(task)
        }
    }

    /// Splits a batched capture back into one screen per pane.
    private static func split(_ output: String) -> [String: String] {
        var screens: [String: String] = [:]
        var pane: String?
        var lines: [String] = []
        func flush() {
            if let pane { screens[pane] = lines.joined(separator: "\n") }
            lines = []
        }
        for line in output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("@@P ") {
                flush()
                pane = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
            } else {
                lines.append(line)
            }
        }
        flush()
        return screens
    }

    // MARK: The panel

    private func present() {
        let hosting = NSHostingView(rootView: TabSwitcherHUD().environmentObject(self))
        let screenFrame = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(screenFrame.width * 0.86, 1240)
        let size = NSSize(width: width, height: min(contentHeight(forWidth: width), screenFrame.height * 0.85))
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.contentView = hosting
        panel.setFrameOrigin(NSPoint(x: screenFrame.midX - size.width / 2,
                                     y: screenFrame.midY - size.height / 2))
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// Roughly how tall the grid wants to be, so the panel hugs its content
    /// instead of always filling most of the screen.
    private func contentHeight(forWidth width: CGFloat) -> CGFloat {
        let columns = max(Int((width - 44 + 14) / (232 + 14)), 1)
        var height: CGFloat = 22 * 2 + 44          // padding + the hint bar
        for group in groups {
            let rows = Int(ceil(Double(group.items.count) / Double(columns)))
            height += 26                            // section header
            height += CGFloat(rows) * (132 + 38) + CGFloat(max(rows - 1, 0)) * 14
            height += 18                            // gap between sections
        }
        return max(height, 260)
    }

    // MARK: Keys

    /// Watches for ⌃ coming back up (switch), Esc (cancel), ↩ and the arrow keys.
    /// Stepping itself rides on the ⌃⇥ / ⌃⇧⇥ menu commands like any other shortcut.
    func installMonitors() {
        guard !monitorsInstalled else { return }
        monitorsInstalled = true
        NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self, self.visible else { return event }
            if event.type == .flagsChanged, !event.modifierFlags.contains(.control) {
                self.commit()
                return event
            }
            if event.type == .keyDown {
                switch event.keyCode {
                case 53: self.cancel(); return nil                    // Esc
                case 36, 76: self.commit(); return nil                // Return
                case 123: self.advance(-1); return nil                // ←
                case 124: self.advance(1); return nil                 // →
                case 126: self.jumpGroup(-1); return nil              // ↑
                case 125: self.jumpGroup(1); return nil               // ↓
                default: break
                }
            }
            return event
        }
    }
}

/// The switcher: a section per server and tmux session, each a grid of window thumbnails,
/// with the one you came from marked and the highlighted one ringed.
private struct TabSwitcherHUD: View {
    @EnvironmentObject private var controller: TabSwitcherController
    @Environment(\.theme) private var theme

    private let thumbWidth: CGFloat = 232
    private let thumbHeight: CGFloat = 132

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(controller.groups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: group.host == nil ? "laptopcomputer" : "server.rack")
                                    .font(.caption)
                                Text(group.label).font(.callout.weight(.semibold))
                                Text("\(group.items.count)")
                                    .font(.caption2.monospacedDigit())
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            }
                            .foregroundStyle(.secondary)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbWidth), spacing: 14, alignment: .top)],
                                      alignment: .leading, spacing: 14) {
                                ForEach(group.items) { item in
                                    card(item).id(item.tag)
                                }
                            }
                        }
                    }
                }
                .padding(22)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: controller.highlightedTag) { _, tag in
                if let tag { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(tag, anchor: .center) } }
            }
        }
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { hint }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(theme.line))
    }

    private var hint: some View {
        Text("⌃⇥ next · ⌃⇧⇥ back · ↑↓ session · ↩ switch · esc cancel")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(.regularMaterial))
            .padding(.bottom, 8)
    }

    private func card(_ item: TabInfo) -> some View {
        let on = item.tag == controller.highlightedTag
        let here = item.tag == controller.originTag
        return VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Rectangle().fill(Color(nsColor: theme.terminalBackground ?? .black))
                if let image = controller.thumbnails[item.tag] {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: thumbWidth, height: thumbHeight, alignment: .topLeading)
                        .clipped()
                } else if controller.loadingThumbnails {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: item.icon).font(.title2).foregroundStyle(.secondary)
                }
            }
            .frame(width: thumbWidth, height: thumbHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(on ? theme.tint : Color.secondary.opacity(0.3), lineWidth: on ? 3 : 1))
            .overlay(alignment: .topTrailing) {
                if here {
                    Text("current")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.regularMaterial))
                        .padding(6)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: item.icon)
                    .font(.caption)
                    .foregroundStyle(item.stateColor ?? .secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.title).font(.callout).lineLimit(1)
                    Text(item.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(width: thumbWidth, alignment: .leading)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 12).fill(on ? theme.tint.opacity(0.16) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { controller.highlight(item.tag); controller.commit() }
    }
}
