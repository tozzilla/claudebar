import Foundation

/// What the menu-bar title leads with.
enum BarMetric: String {
    case session   // current 5-hour session
    case weekly    // highest weekly limit
    case auto      // whichever limit is highest (most binding)
}

/// Thin UserDefaults wrapper for user preferences.
enum Prefs {
    private static let d = UserDefaults.standard

    private enum Key {
        static let barMetric = "barMetric"
        static let notifications = "notificationsEnabled"
        static let alertThreshold = "alertThreshold"
        static let pollInterval = "pollIntervalSeconds"
        static let notified = "notifiedKeys"
    }

    static var barMetric: BarMetric {
        get { BarMetric(rawValue: d.string(forKey: Key.barMetric) ?? "") ?? .session }
        set { d.set(newValue.rawValue, forKey: Key.barMetric) }
    }

    /// Off by default — the user opts in (and grants the system permission).
    static var notificationsEnabled: Bool {
        get { d.bool(forKey: Key.notifications) }
        set { d.set(newValue, forKey: Key.notifications) }
    }

    /// Percentage at which a limit triggers a notification (default 85).
    static var alertThreshold: Int {
        get { let v = d.integer(forKey: Key.alertThreshold); return v == 0 ? 85 : v }
        set { d.set(newValue, forKey: Key.alertThreshold) }
    }

    /// Minimum seconds between network fetches (default 180).
    static var pollInterval: TimeInterval {
        get { let v = d.double(forKey: Key.pollInterval); return v == 0 ? 180 : v }
        set { d.set(newValue, forKey: Key.pollInterval) }
    }

    /// Dedup keys for notifications already sent (capped).
    static var notifiedKeys: [String] {
        get { d.stringArray(forKey: Key.notified) ?? [] }
        set { d.set(Array(newValue.suffix(50)), forKey: Key.notified) }
    }
}
