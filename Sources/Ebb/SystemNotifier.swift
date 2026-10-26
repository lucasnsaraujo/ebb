import EbbCore
import UserNotifications

/// Alerts through Notification Center. Only the live app makes one: a snapshot or demo
/// never touches UserNotifications, so it can never ask for permission.
struct SystemNotifier: Notifier {
    init() {
        UNUserNotificationCenter.current().delegate = BannerPresenter.shared
    }

    func isAuthorized() async -> Bool? {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: nil
        case .denied: false
        default: true
        }
    }

    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func post(_ alert: PoolAlert) async {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: alert.id, content: content, trigger: nil))
    }
}

/// For a run outside an app bundle (`swift run`), where UserNotifications can't work.
struct SilentNotifier: Notifier {
    func isAuthorized() async -> Bool? { false }
    func requestAuthorization() async -> Bool { false }
    func post(_ alert: PoolAlert) async {}
}

/// Shows Ebb's alerts while its panel is open too, when the app counts as active.
private final class BannerPresenter: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = BannerPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}

/// Settings → General → Notifications.
enum AlertSettings {
    static let isEnabledKey = "sendsPoolAlerts"

    /// On unless turned off; permission is still asked only when the first alert is due.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: isEnabledKey) as? Bool ?? true
    }
}
