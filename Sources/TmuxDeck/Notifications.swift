import AppKit
import SwiftUI
import UserNotifications

/// Banners, and what they do when you click one.
///
/// A banner carries the tag of the window it's about, so clicking it brings that window up
/// instead of just raising the app. Each kind can be turned off on its own — people want to be
/// told when an assistant is *blocked on them* far more than when it merely finished.
@MainActor
final class Notifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifications()

    static func install() {
        UNUserNotificationCenter.current().delegate = shared
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Whether banners are on for this kind of event. Sounds are configured separately, in
    /// `Sounds`, so you can have one without the other.
    static func enabled(_ event: Sounds.Event) -> Bool {
        UserDefaults.standard.object(forKey: "banner.\(event.rawValue).on") as? Bool ?? true
    }

    static func setEnabled(_ event: Sounds.Event, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: "banner.\(event.rawValue).on")
    }

    // MARK: Muting

    private static func mutedKey(_ host: String) -> String { "mute.server.\(host)" }

    static func serverMuted(_ host: String) -> Bool {
        UserDefaults.standard.bool(forKey: mutedKey(host))
    }

    static func setServerMuted(_ host: String, _ muted: Bool) {
        UserDefaults.standard.set(muted, forKey: mutedKey(host))
    }

    static func windowMuted(host: String, window: String) -> Bool {
        mutedWindows(host).contains(window)
    }

    static func setWindowMuted(host: String, window: String, _ muted: Bool) {
        var all = mutedWindows(host)
        if muted { all.insert(window) } else { all.remove(window) }
        UserDefaults.standard.set(Array(all), forKey: "mute.windows.\(host)")
    }

    private static func mutedWindows(_ host: String) -> Set<String> {
        Set(UserDefaults.standard.array(forKey: "mute.windows.\(host)") as? [String] ?? [])
    }

    static func muted(host: String, window: String) -> Bool {
        serverMuted(host) || windowMuted(host: host, window: window)
    }

    // MARK: Posting

    static func post(_ event: Sounds.Event, title: String, subtitle: String, body: String, tag: String?) {
        guard enabled(event) else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = nil   // Sounds.play handles sound, so it isn't doubled
        if let tag { content.userInfo = ["tag": tag] }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: Clicking one

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let tag = response.notification.request.content.userInfo["tag"] as? String
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if let tag { LayoutModel.shared.show(tag) }
            completionHandler()
        }
    }

    /// Show a banner even while the app is in front — the code only posts one for a window you
    /// aren't looking at, so if it got this far it's worth seeing.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
