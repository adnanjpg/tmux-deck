import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: Layout tree

enum SplitAxis: String, Codable {
    case horizontal   // side by side
    case vertical     // one above the other
}

/// The main area as a tree of splits. Leaves show one window, identified by its
/// sidebar tag ("host#item id"); leaf ids stay stable so tiles keep their state
/// and animate when the layout changes.
indirect enum LayoutNode: Codable, Equatable {
    case leaf(id: String, tag: String?)
    case split(id: String, axis: SplitAxis, first: LayoutNode, second: LayoutNode, ratio: Double)

    var id: String {
        switch self {
        case .leaf(let id, _), .split(let id, _, _, _, _): id
        }
    }

    var leaves: [(id: String, tag: String?)] {
        switch self {
        case .leaf(let id, let tag): [(id, tag)]
        case .split(_, _, let a, let b, _): a.leaves + b.leaves
        }
    }

    func mapLeaf(_ leafID: String, _ f: (LayoutNode) -> LayoutNode) -> LayoutNode {
        switch self {
        case .leaf(let id, _): return id == leafID ? f(self) : self
        case .split(let id, let axis, let a, let b, let r):
            return .split(id: id, axis: axis, first: a.mapLeaf(leafID, f), second: b.mapLeaf(leafID, f), ratio: r)
        }
    }

    /// Removes a leaf; its sibling takes the parent split's place.
    func removing(_ leafID: String) -> LayoutNode? {
        switch self {
        case .leaf(let id, _): return id == leafID ? nil : self
        case .split(let id, let axis, let a, let b, let r):
            let na = a.removing(leafID), nb = b.removing(leafID)
            if let na, let nb { return .split(id: id, axis: axis, first: na, second: nb, ratio: r) }
            return na ?? nb
        }
    }

    func settingRatio(_ splitID: String, _ ratio: Double) -> LayoutNode {
        switch self {
        case .leaf: return self
        case .split(let id, let axis, let a, let b, let r):
            return .split(id: id, axis: axis, first: a.settingRatio(splitID, ratio), second: b.settingRatio(splitID, ratio),
                          ratio: id == splitID ? ratio : r)
        }
    }

    /// Frames for every leaf, and the dividers between them, inside `rect`.
    func layout(in rect: CGRect, gap: CGFloat,
                into leaves: inout [String: CGRect], dividers: inout [LayoutDivider]) {
        switch self {
        case .leaf(let id, _):
            leaves[id] = rect
        case .split(let id, let axis, let a, let b, let r):
            if axis == .horizontal {
                let w = rect.width - gap
                let aw = (w * r).rounded()
                let ra = CGRect(x: rect.minX, y: rect.minY, width: aw, height: rect.height)
                let rb = CGRect(x: rect.minX + aw + gap, y: rect.minY, width: w - aw, height: rect.height)
                dividers.append(LayoutDivider(splitID: id, axis: axis, parent: rect,
                                              rect: CGRect(x: ra.maxX, y: rect.minY, width: gap, height: rect.height)))
                a.layout(in: ra, gap: gap, into: &leaves, dividers: &dividers)
                b.layout(in: rb, gap: gap, into: &leaves, dividers: &dividers)
            } else {
                let h = rect.height - gap
                let ah = (h * r).rounded()
                let ra = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: ah)
                let rb = CGRect(x: rect.minX, y: rect.minY + ah + gap, width: rect.width, height: h - ah)
                dividers.append(LayoutDivider(splitID: id, axis: axis, parent: rect,
                                              rect: CGRect(x: rect.minX, y: ra.maxY, width: rect.width, height: gap)))
                a.layout(in: ra, gap: gap, into: &leaves, dividers: &dividers)
                b.layout(in: rb, gap: gap, into: &leaves, dividers: &dividers)
            }
        }
    }
}

struct LayoutDivider: Identifiable {
    let splitID: String
    let axis: SplitAxis
    let parent: CGRect
    let rect: CGRect
    var id: String { splitID }
}

enum DropZone: Equatable {
    case left, right, top, bottom, center

    var label: String {
        switch self {
        case .left: "Split left"
        case .right: "Split right"
        case .top: "Split above"
        case .bottom: "Split below"
        case .center: "Replace"
        }
    }

    /// Where the highlight goes inside a tile of `size`.
    func rect(in size: CGSize) -> CGRect {
        let full = CGRect(origin: .zero, size: size)
        switch self {
        case .left: return CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
        case .right: return CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
        case .top: return CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
        case .bottom: return CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
        case .center: return full.insetBy(dx: 10, dy: 10)
        }
    }

    /// Edges win when the pointer is within 28% of them; otherwise it's a replace.
    static func at(_ p: CGPoint, in size: CGSize) -> DropZone {
        guard size.width > 0, size.height > 0 else { return .center }
        let fx = p.x / size.width, fy = p.y / size.height
        let edges: [(DropZone, CGFloat)] = [(.left, fx), (.right, 1 - fx), (.top, fy), (.bottom, 1 - fy)]
        let nearest = edges.min { $0.1 < $1.1 }!
        return nearest.1 < 0.28 ? nearest.0 : .center
    }
}

// MARK: Layout state

@MainActor
final class LayoutModel: ObservableObject {
    static let shared = LayoutModel()
    static let maxTiles = 6
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.84)

    @Published private(set) var root: LayoutNode
    @Published private(set) var focused: String
    /// Tile frames in window coordinates, for focusing a tile on click.
    var tileFrames: [String: CGRect] = [:]
    private var clickMonitor: Any?

    private init() {
        if let data = UserDefaults.standard.data(forKey: "layout"),
           let node = try? JSONDecoder().decode(LayoutNode.self, from: data), !node.leaves.isEmpty {
            root = node
            focused = UserDefaults.standard.string(forKey: "layout.focused").flatMap { f in
                node.leaves.contains { $0.id == f } ? f : nil
            } ?? node.leaves[0].id
        } else {
            let id = UUID().uuidString
            root = .leaf(id: id, tag: nil)
            focused = id
        }
    }

    var isSplit: Bool { root.leaves.count > 1 }
    var focusedTag: String? { root.leaves.first { $0.id == focused }?.tag }

    private func save() {
        if let data = try? JSONEncoder().encode(root) { UserDefaults.standard.set(data, forKey: "layout") }
        UserDefaults.standard.set(focused, forKey: "layout.focused")
    }

    private func commit(_ node: LayoutNode, focus: String? = nil, animated: Bool = true) {
        let apply = {
            self.root = node
            if let focus { self.focused = focus }
            if !node.leaves.contains(where: { $0.id == self.focused }) { self.focused = node.leaves[0].id }
        }
        if animated { withAnimation(Self.spring, apply) } else { apply() }
        save()
        syncSelection()
    }

    /// Keeps the sidebar, toolbar and menus pointed at the focused tile's window.
    func syncSelection() {
        if let tag = focusedTag { AppModel.shared.select(tag: tag) }
    }

    func focus(_ leafID: String) {
        guard leafID != focused, root.leaves.contains(where: { $0.id == leafID }) else { return }
        focused = leafID
        save()
        syncSelection()
    }

    /// Sidebar click: jump to the window if it's already in a tile; otherwise open it
    /// on its own, closing the split (splits are made by dragging or "Open to the right").
    func show(_ tag: String) {
        if let existing = root.leaves.first(where: { $0.tag == tag }) {
            focus(existing.id)
            return
        }
        commit(.leaf(id: focused, tag: tag), focus: focused, animated: isSplit)
    }

    /// Drops a window (sidebar tag) onto a tile.
    func drop(tag: String, onto target: String, zone: DropZone) {
        var tree = root
        // A window appears once: if it's already in another tile, it moves.
        if let existing = tree.leaves.first(where: { $0.tag == tag }) {
            if existing.id == target {
                if zone == .center { return }
                // Splitting a tile with itself: move it to that edge of an empty neighbour isn't useful.
                return
            }
            if zone == .center {
                // Swap: the target shows this window, the old tile closes.
                tree = tree.removing(existing.id) ?? tree
            } else {
                tree = tree.removing(existing.id) ?? tree
            }
        }
        guard tree.leaves.contains(where: { $0.id == target }) else { return }
        if zone == .center {
            commit(tree.mapLeaf(target) { _ in .leaf(id: target, tag: tag) }, focus: target)
            return
        }
        guard tree.leaves.count < Self.maxTiles else {
            AppModel.shared.activeServer?.flash("Up to \(Self.maxTiles) tiles at once")
            return
        }
        let newLeaf = LayoutNode.leaf(id: UUID().uuidString, tag: tag)
        commit(Self.split(tree, at: target, with: newLeaf, zone: zone), focus: newLeaf.id)
    }

    /// Moves an existing tile next to (or in place of) another.
    func move(tile source: String, onto target: String, zone: DropZone) {
        guard source != target, let moving = root.leaves.first(where: { $0.id == source }) else { return }
        if zone == .center {
            // Swap the two tiles' windows.
            let targetTag = root.leaves.first { $0.id == target }?.tag
            let swapped = root
                .mapLeaf(target) { _ in .leaf(id: target, tag: moving.tag) }
                .mapLeaf(source) { _ in .leaf(id: source, tag: targetTag) }
            commit(swapped, focus: target)
            return
        }
        guard let without = root.removing(source) else { return }
        commit(Self.split(without, at: target, with: .leaf(id: source, tag: moving.tag), zone: zone), focus: source)
    }

    private static func split(_ tree: LayoutNode, at target: String, with newLeaf: LayoutNode, zone: DropZone) -> LayoutNode {
        tree.mapLeaf(target) { existing in
            let axis: SplitAxis = (zone == .left || zone == .right) ? .horizontal : .vertical
            let newFirst = zone == .left || zone == .top
            return .split(id: UUID().uuidString, axis: axis,
                          first: newFirst ? newLeaf : existing,
                          second: newFirst ? existing : newLeaf, ratio: 0.5)
        }
    }

    func close(_ leafID: String) {
        guard isSplit, let tree = root.removing(leafID) else { return }
        commit(tree)
    }

    /// Keeps only this tile.
    func maximize(_ leafID: String) {
        guard let leaf = root.leaves.first(where: { $0.id == leafID }) else { return }
        commit(.leaf(id: leaf.id, tag: leaf.tag), focus: leaf.id)
    }

    func unsplit() { maximize(focused) }

    func setRatio(_ splitID: String, _ ratio: Double) {
        root = root.settingRatio(splitID, min(max(ratio, 0.15), 0.85))
    }

    func finishResize() { save() }

    /// Clicking anywhere inside a tile (text views and terminals included) focuses it.
    func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, self.isSplit, let window = event.window, let content = window.contentView else { return event }
            let p = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
            if let hit = self.tileFrames.first(where: { $0.value.contains(p) })?.key { self.focus(hit) }
            return event
        }
    }
}

// MARK: Views

/// The main area: one or more tiles, with dividers you can drag.
struct SplitLayoutView<Tile: View>: View {
    @ObservedObject var layout: LayoutModel
    @ViewBuilder var tile: (_ leafID: String, _ tag: String?) -> Tile

    private let gap: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let (frames, dividers) = compute(geo.size)
            ZStack(alignment: .topLeading) {
                ForEach(layout.root.leaves, id: \.id) { leaf in
                    let f = frames[leaf.id] ?? .zero
                    TileContainer(layout: layout, leafID: leaf.id, tag: leaf.tag) {
                        tile(leaf.id, leaf.tag)
                    }
                    .frame(width: max(f.width, 0), height: max(f.height, 0))
                    .offset(x: f.minX, y: f.minY)
                    .transition(.asymmetric(insertion: .scale(scale: 0.94).combined(with: .opacity),
                                            removal: .scale(scale: 0.94).combined(with: .opacity)))
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear { layout.tileFrames[leaf.id] = g.frame(in: .global) }
                            .onChange(of: g.frame(in: .global)) { _, new in layout.tileFrames[leaf.id] = new }
                    })
                }
                ForEach(dividers) { d in
                    DividerHandle(divider: d, layout: layout)
                }
            }
            .padding(layout.isSplit ? gap : 0)
            .coordinateSpace(name: "layout")
        }
        .onAppear { layout.installClickMonitor() }
        .onChange(of: layout.root.leaves.map(\.id)) { _, ids in
            layout.tileFrames = layout.tileFrames.filter { ids.contains($0.key) }
        }
    }

    private func compute(_ size: CGSize) -> ([String: CGRect], [LayoutDivider]) {
        var frames: [String: CGRect] = [:]
        var dividers: [LayoutDivider] = []
        let inset = layout.isSplit ? gap * 2 : 0
        layout.root.layout(in: CGRect(x: 0, y: 0, width: size.width - inset, height: size.height - inset),
                           gap: gap, into: &frames, dividers: &dividers)
        return (frames, dividers)
    }
}

private struct DividerHandle: View {
    let divider: LayoutDivider
    @ObservedObject var layout: LayoutModel
    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        let horizontal = divider.axis == .horizontal
        ZStack {
            Capsule()
                .fill(Color.accentColor.opacity(dragging ? 0.9 : hovering ? 0.5 : 0))
                .frame(width: horizontal ? 3 : 36, height: horizontal ? 36 : 3)
            Rectangle().fill(Color.clear)
        }
        .frame(width: horizontal ? divider.rect.width + 6 : divider.rect.width,
               height: horizontal ? divider.rect.height : divider.rect.height + 6)
        .contentShape(Rectangle())
        .offset(x: divider.rect.minX - (horizontal ? 3 : 0), y: divider.rect.minY - (horizontal ? 0 : 3))
        .onHover { inside in
            hovering = inside
            if inside { (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named("layout"))
                .onChanged { v in
                    dragging = true
                    let p = divider.parent
                    let ratio = horizontal ? (v.location.x - p.minX) / p.width : (v.location.y - p.minY) / p.height
                    layout.setRatio(divider.splitID, ratio)
                }
                .onEnded { _ in dragging = false; layout.finishResize() }
        )
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help("Drag to resize")
    }
}

/// A tile: its title bar (when split), the window, focus ring and drop zones.
private struct TileContainer<Content: View>: View {
    @ObservedObject var layout: LayoutModel
    @EnvironmentObject private var app: AppModel
    let leafID: String
    let tag: String?
    @ViewBuilder var content: Content
    @State private var zone: DropZone?
    @State private var size: CGSize = .zero

    var body: some View {
        let split = layout.isSplit
        let focused = layout.focused == leafID
        VStack(spacing: 0) {
            if split { TileHeader(layout: layout, leafID: leafID, tag: tag, focused: focused) }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: split ? 10 : 0))
        .overlay {
            if split {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(focused ? Color.accentColor.opacity(0.75) : Color(nsColor: .separatorColor),
                                  lineWidth: focused ? 2 : 1)
            }
        }
        .shadow(color: .black.opacity(split && focused ? 0.12 : 0), radius: 8, y: 2)
        .overlay(alignment: .topLeading) {
            if let zone {
                let r = zone.rect(in: size)
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(0.16))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 2))
                    .overlay {
                        Label(zone.label, systemImage: icon(zone))
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .frame(width: r.width - 8, height: r.height - 8)
                    .offset(x: r.minX + 4, y: r.minY + 4)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: zone)
        .background(GeometryReader { g in
            Color.clear.onAppear { size = g.size }.onChange(of: g.size) { _, s in size = s }
        })
        .onDrop(of: [.utf8PlainText, .plainText], delegate: TileDrop(layout: layout, leafID: leafID, size: size, zone: $zone))
    }

    private func icon(_ z: DropZone) -> String {
        switch z {
        case .left: "rectangle.lefthalf.inset.filled"
        case .right: "rectangle.righthalf.inset.filled"
        case .top: "rectangle.tophalf.inset.filled"
        case .bottom: "rectangle.bottomhalf.inset.filled"
        case .center: "arrow.left.arrow.right"
        }
    }
}

private struct TileHeader: View {
    @ObservedObject var layout: LayoutModel
    @EnvironmentObject private var app: AppModel
    let leafID: String
    let tag: String?
    let focused: Bool

    var body: some View {
        let resolved = tag.flatMap(TileResolver.resolve)
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .help("Drag to move this tile")
            if let (server, window) = resolved {
                Text(server.displayTitle(window))
                    .font(.callout.weight(focused ? .semibold : .regular))
                    .lineLimit(1)
                Text(app.servers.count > 1 ? "\(server.host) · \(window.session)" : window.session)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if window.state == .claudeWorking {
                    ProgressView().controlSize(.mini)
                } else if window.state == .claudeNeedsYou {
                    Circle().fill(.orange).frame(width: 7, height: 7)
                }
            } else {
                Text(tag == nil ? "Empty" : "Window closed").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button { layout.maximize(leafID) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .buttonStyle(.borderless)
                .help("Keep only this tile")
            Button { layout.close(leafID) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Close this tile")
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(focused ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05))
        .overlay(alignment: .bottom) { Divider() }
        .contentShape(Rectangle())
        .onTapGesture { layout.focus(leafID) }
        .draggable("tile:\(leafID)") {
            Label(resolved.map { $0.0.displayTitle($0.1) } ?? "Tile", systemImage: "rectangle.on.rectangle")
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .contextMenu {
            Button("Keep only this tile") { layout.maximize(leafID) }
            Button("Close tile") { layout.close(leafID) }
        }
    }
}

private struct TileDrop: DropDelegate {
    let layout: LayoutModel
    let leafID: String
    let size: CGSize
    @Binding var zone: DropZone?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.utf8PlainText, .plainText])
    }

    func dropEntered(info: DropInfo) { zone = DropZone.at(info.location, in: size) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let z = DropZone.at(info.location, in: size)
        if z != zone { zone = z }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { zone = nil }

    func performDrop(info: DropInfo) -> Bool {
        let z = zone ?? .center
        zone = nil
        guard let provider = info.itemProviders(for: [.utf8PlainText, .plainText]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let payload = obj as? String else { return }
            Task { @MainActor in
                if payload.hasPrefix("tile:") {
                    layout.move(tile: String(payload.dropFirst(5)), onto: leafID, zone: z)
                } else if payload.contains("#") {
                    layout.drop(tag: payload, onto: leafID, zone: z)
                }
            }
        }
        return true
    }
}

/// Finds the server and window behind a sidebar tag.
enum TileResolver {
    @MainActor
    static func resolve(_ tag: String) -> (TmuxModel, TmuxWindow)? {
        guard let hash = tag.firstIndex(of: "#"),
              let server = AppModel.shared.server(String(tag[..<hash])) else { return nil }
        let id = String(tag[tag.index(after: hash)...])
        guard let window = server.item(id) else { return nil }
        return (server, window)
    }
}
