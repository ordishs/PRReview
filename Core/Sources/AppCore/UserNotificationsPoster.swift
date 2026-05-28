import Foundation
import UserNotifications

public actor UserNotificationsPoster: NotificationPosting {
    public init() {}

    public func postReviewReady(reviewID: String, title: String, body: String) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .denied:
            return
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return }
        case .authorized, .provisional, .ephemeral:
            break
        @unknown default:
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "review-ready-\(reviewID)",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }
}
