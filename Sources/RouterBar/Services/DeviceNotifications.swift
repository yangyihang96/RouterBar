import Foundation
import UserNotifications

@MainActor
final class DeviceNotifications: ObservableObject {
    @Published private(set) var status = "尚未开启系统通知"
    @Published private(set) var authorized = false
    @Published private(set) var requesting = false
    @Published private(set) var error: String?
    private let center = UNUserNotificationCenter.current()
    func refresh() async {
        let settings = await center.notificationSettings()
        authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        if authorized { error = nil }
        switch settings.authorizationStatus {
        case .authorized, .provisional: status = "系统通知已允许"
        case .denied: status = "系统通知已关闭，可在系统设置中允许"
        default: status = "尚未开启系统通知"
        }
    }
    func authorize() async {
        guard !requesting else { return }
        requesting = true; status = "等待完成 macOS 通知授权"
        defer { requesting = false }
        do { _ = try await center.requestAuthorization(options: [.alert, .sound]); error = nil }
        catch { self.error = "通知授权未完成：" + error.localizedDescription }
        await refresh()
    }
    /// `stillDue` is asked again after the settings have been read: the device may have come back, been unwatched or
    /// monitoring paused while waiting, and then nothing is sent.
    func send(name: String, eventID: String, test: Bool = false, stillDue: () -> Bool = { true }) async -> Bool {
        await refresh()
        guard authorized, stillDue() else { return false }
        let content = UNMutableNotificationContent()
        content.title = test ? "路由器面板 · 测试通知" : "\(String(name.prefix(60))) 已离线"
        content.body = test ? "通知已启用。关注的设备连续离线 3 分钟后，会在这里提醒你。" : "连续 3 分钟未在路由器的在线列表中发现这台设备。打开设备历史查看详情。"
        content.sound = .default
        do {
            try await center.add(UNNotificationRequest(identifier: eventID, content: content, trigger: nil))
            error = nil; return true
        } catch { self.error = "通知发送失败：" + error.localizedDescription; return false }
    }
}
