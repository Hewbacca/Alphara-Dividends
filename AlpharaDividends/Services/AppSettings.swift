import Foundation

/// Lightweight user preferences backed by UserDefaults.
/// (Kept separate from @AppStorage so non-View code — e.g. the background task — can read them.)
enum AppSettings {
    static let backgroundWifiOnlyKey = "backgroundWifiOnly"

    /// When true, the background refresh skips runs that would use cellular data.
    /// Defaults to true. Manual foreground refresh ignores this.
    static var backgroundWifiOnly: Bool {
        get {
            // Default to true when unset.
            if UserDefaults.standard.object(forKey: backgroundWifiOnlyKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: backgroundWifiOnlyKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: backgroundWifiOnlyKey) }
    }

    static let paydayNotificationsEnabledKey = "paydayNotificationsEnabled"

    /// When true, a local notification is pre-scheduled at 8:30 am (device-local time) for
    /// each upcoming pay date, so it fires reliably even if the app is never opened that day.
    /// Defaults to true.
    static var paydayNotificationsEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: paydayNotificationsEnabledKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: paydayNotificationsEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: paydayNotificationsEnabledKey) }
    }
}
