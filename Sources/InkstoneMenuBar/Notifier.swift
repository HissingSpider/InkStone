import Foundation
import UserNotifications

/// Best-effort user notifications.
///
/// Silently no-ops when notification permission was refused: a transcription run
/// succeeding or failing is worth telling the user about, but never worth an
/// error dialog of its own.
enum Notifier {

    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
