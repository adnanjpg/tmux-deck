import AppKit
import SwiftUI

/// Notices when `./build-app.sh` has installed a newer build while this one is
/// still running (the app never restarts itself), and offers a one-click relaunch.
/// Without this, "did you rebuild it?" has no visible answer — the window just
/// keeps showing whatever was running before.
@MainActor
final class UpdateWatcher: ObservableObject {
    static let shared = UpdateWatcher()

    @Published var updateAvailable = false
    private let executableURL = Bundle.main.executableURL
    private let launchedModDate: Date?
    private var timer: Timer?

    private init() {
        launchedModDate = Self.modDate(executableURL)
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    private func check() {
        guard let launchedModDate, let current = Self.modDate(executableURL) else { return }
        if current != launchedModDate { updateAvailable = true }
    }

    private static func modDate(_ url: URL?) -> Date? {
        guard let url else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Launches a fresh copy of the app and quits this one.
    func relaunch() {
        guard let bundleURL = Bundle.main.bundleURL as URL? else { NSApp.terminate(nil); return }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}

/// A slim banner offering to relaunch into the newer build.
struct UpdateBanner: View {
    @ObservedObject private var watcher = UpdateWatcher.shared

    var body: some View {
        if watcher.updateAvailable {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("A newer build has been installed — this window is still running the old one.")
                Spacer(minLength: 8)
                Button("Relaunch") { watcher.relaunch() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Later") { watcher.updateAvailable = false }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.15))
            .overlay(alignment: .bottom) { Divider() }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
