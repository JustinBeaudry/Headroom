import Foundation
import UserNotifications
import HeadroomCore

/// Native macOS notification delivery via UNUserNotificationCenter.
/// Safely no-ops if invoked outside a bundled `.app` (e.g. `swift run HeadroomApp`).
@MainActor
public final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    private var authorized = false
    private let isBundledApp: Bool

    public override init() {
        self.isBundledApp = Bundle.main.bundleIdentifier != nil
        super.init()
        if isBundledApp {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    public func requestAuthorizationIfAvailable() async {
        guard isBundledApp else { return }
        let center = UNUserNotificationCenter.current()
        do {
            authorized = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            authorized = false
        }
    }

    public func deliver(_ alerts: [HeadroomAlert]) {
        guard isBundledApp, !alerts.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        for alert in alerts {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: alert.id,
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }

    public func notifyUpdateAvailable(_ release: ReleaseInfo) {
        guard isBundledApp else { return }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = "Headroom \(release.tagName) is available"
        content.body = release.summaryHighlight
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "headroom-update-\(release.tagName)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }
}
