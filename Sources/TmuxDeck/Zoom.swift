import AppKit
import SwiftUI

/// How big the text is, everywhere you read it: the chat, the console, the terminals.
///
/// SwiftUI's semantic sizes (`.body`, `.caption`…) are fixed on macOS — it ignores
/// `dynamicTypeSize` — so zooming means computing every size from one base. `AppFont`
/// holds those sizes; views take it from the environment instead of naming styles.
@MainActor
final class Zoom: ObservableObject {
    static let shared = Zoom()

    static let defaultSize: Double = 13
    static let range: ClosedRange<Double> = 8...28

    /// The size the window is drawn at. Changing it re-lays out every message, terminal and
    /// row, which is far too much to do once per key repeat — so `set` coalesces a burst of
    /// steps and commits here once the keys stop.
    @Published private(set) var size: Double
    /// The size the user has asked for; `size` catches up a moment later.
    private var pending: Double
    private var commit: DispatchWorkItem?

    private init() {
        let stored = UserDefaults.standard.double(forKey: "fontSize")
        let initial = stored > 0 ? min(max(stored, Self.range.lowerBound), Self.range.upperBound) : Self.defaultSize
        size = initial
        pending = initial
    }

    var percent: Int { Int((size / Self.defaultSize * 100).rounded()) }
    var canZoomIn: Bool { pending < Self.range.upperBound }
    var canZoomOut: Bool { pending > Self.range.lowerBound }

    func zoomIn() { set(pending + 1) }
    func zoomOut() { set(pending - 1) }
    func reset() { set(Self.defaultSize) }

    func set(_ value: Double) {
        let clamped = min(max(value.rounded(), Self.range.lowerBound), Self.range.upperBound)
        guard clamped != pending else { return }
        pending = clamped
        commit?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.apply() }
        }
        commit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func apply() {
        commit = nil
        guard pending != size else { return }
        size = pending
        UserDefaults.standard.set(size, forKey: "fontSize")
        NotificationCenter.default.post(name: .fontSizeChanged, object: nil)
    }

    var font: AppFont { AppFont(base: CGFloat(size)) }
}

extension Notification.Name {
    static let fontSizeChanged = Notification.Name("TmuxDeckFontSizeChanged")
}

/// The app's text sizes, all derived from the one the user picked. The numbers are the
/// macOS defaults they replace, so at 13pt nothing moves.
struct AppFont {
    var base: CGFloat = 13

    private var scale: CGFloat { base / 13 }
    func points(_ standard: CGFloat) -> CGFloat { max(6, (standard * scale).rounded()) }

    var body: Font { .system(size: points(13)) }
    var callout: Font { .system(size: points(12)) }
    var caption: Font { .system(size: points(10)) }
    var caption2: Font { .system(size: points(9)) }
    var headline: Font { .system(size: points(13), weight: .semibold) }
    var title3: Font { .system(size: points(15), weight: .semibold) }
    var title2: Font { .system(size: points(17)) }

    /// A one-off size (icons, badges) that still follows the zoom.
    func size(_ standard: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: points(standard), weight: weight, design: design)
    }

    var mono: Font { .system(size: points(12), design: .monospaced) }
    var monoBody: Font { .system(size: points(13), design: .monospaced) }
    var monoCaption: Font { .system(size: points(10), design: .monospaced) }

    var nsMono: NSFont { .monospacedSystemFont(ofSize: points(12), weight: .regular) }
    var nsBody: NSFont { .systemFont(ofSize: points(13)) }
    var terminal: NSFont { .monospacedSystemFont(ofSize: base, weight: .regular) }
}

private struct AppFontKey: EnvironmentKey {
    static let defaultValue = AppFont()
}

extension EnvironmentValues {
    var fonts: AppFont {
        get { self[AppFontKey.self] }
        set { self[AppFontKey.self] = newValue }
    }
}

extension Zoom {
    /// Whether terminals are currently drawing on a dark background.
    static var terminalIsDark: Bool {
        let theme = ThemeManager.shared.theme
        if let background = theme.terminalBackground?.usingColorSpace(.sRGB) {
            return background.brightnessComponent < 0.5
        }
        return theme.isDark ?? (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }
}
