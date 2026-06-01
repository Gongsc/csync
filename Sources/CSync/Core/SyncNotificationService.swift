import Foundation
import UserNotifications

@MainActor
final class SyncNotificationService {
    static let shared = SyncNotificationService()

    private let center = UNUserNotificationCenter.current()
    private var requestedAuthorization = false

    private init() {}

    func requestAuthorizationIfNeeded() {
        guard !requestedAuthorization else { return }
        requestedAuthorization = true

        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifySyncSucceeded(projectName: String) {
        postNotification(
            title: "同步成功",
            body: "\(projectName) 已完成同步"
        )
    }

    func notifySyncFailed(projectName: String, message: String) {
        postNotification(
            title: "同步失败",
            body: "\(projectName): \(message)"
        )
    }

    private func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        center.add(request) { _ in }
    }
}
