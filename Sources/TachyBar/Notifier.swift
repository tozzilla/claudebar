import AppKit
import UserNotifications

/// Wraps user notifications. Only active when running from a real .app bundle —
/// `UNUserNotificationCenter` requires a code-signed bundle, so we no-op when
/// run as a bare binary (dev / `--print`).
final class Notifier {
    private(set) var available = false

    func setup() {
        available = Bundle.main.bundleURL.pathExtension == "app"
    }

    func requestAuthIfNeeded() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
