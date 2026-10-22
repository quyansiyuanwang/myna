import Foundation
import UserNotifications
import AppKit

/// 后台会话完成时的系统通知。
///
/// 前台会话不打扰；只有**其它会话**在后台跑完才发通知，点击通知切回该会话。
/// 未获得通知权限时静默降级（不影响其它功能），并在「设置 → 诊断」中展示状态。
@MainActor
final class NotificationBridge: NSObject {
    static let shared = NotificationBridge()

    /// 点击通知后的跳转动作（由 AppDelegate 注入：切会话 + 打开面板）。
    private var onOpenConversation: ((UUID) -> Void)?
    private var configured = false

    /// 在应用启动时调用一次：注册代理并注入跳转动作。
    func configure(onOpenConversation: @escaping (UUID) -> Void) {
        guard !configured else { return }
        configured = true
        self.onOpenConversation = onOpenConversation
        UNUserNotificationCenter.current().delegate = self
    }

    /// 是否已获得通知权限（1 = 已授权）。
    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// 按需请求通知权限；已决定过则直接返回。
    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        switch status {
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .authorized, .provisional:
            return true
        default:
            return false
        }
    }

    /// 发送一条「后台会话完成」通知。未授权时什么也不做。
    func postBackgroundCompletion(conversationID: UUID, title: String, body: String) {
        // CLI 可执行文件没有 bundle，UserNotifications 在这里会抛 ObjC 异常；
        // 自动化自检（concurrency-check 等）会走到这条路径。
        guard Bundle.main.bundleIdentifier != nil else { return }
        Task {
            var status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            // 首次真正需要时才询问权限（避免启动即弹框）；用户拒绝后不再反复询问。
            if status == .notDetermined {
                _ = await requestAuthorizationIfNeeded()
                status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            }
            guard status == .authorized || status == .provisional else { return }

            let content = UNMutableNotificationContent()
            content.title = title.isEmpty ? "对话已完成" : title
            content.body = Self.preview(of: body)
            content.sound = .default
            content.userInfo = ["conversationID": conversationID.uuidString]

            let request = UNNotificationRequest(
                identifier: "myna.done.\(conversationID.uuidString).\(Int(Date().timeIntervalSince1970))",
                content: content,
                trigger: nil // 立即送达
            )
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    /// 通知正文只保留一段可读预览。
    static func preview(of text: String, limit: Int = 120) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit)) + "…"
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationBridge: UNUserNotificationCenterDelegate {
    /// 点击通知：切到对应会话并呼出面板。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let raw = response.notification.request.content.userInfo["conversationID"] as? String
        guard let raw, let id = UUID(uuidString: raw) else { return }
        await MainActor.run {
            self.onOpenConversation?(id)
        }
    }

    /// 应用在前台时也把通知显示出来（后台会话完成往往用户正在看别的会话）。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
