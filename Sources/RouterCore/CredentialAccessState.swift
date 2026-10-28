import Foundation
import Security

public enum CredentialAccessState: Sendable, Equatable {
    case idle, reading(Date), authorizing(Date), saving(Date), notFound, interactionRequired, canceled, corrupted, failed(Int32)
    public var isWaiting: Bool { switch self { case .reading, .authorizing, .saving: true; default: false } }
    public var canStopWaiting: Bool { switch self { case .reading, .authorizing: true; default: false } }
    public var since: Date? { switch self { case .reading(let date), .authorizing(let date), .saving(let date): date; default: nil } }
    public var message: String? {
        switch self {
        case .idle: nil
        case .reading: "正在读取钥匙串中的已保存登录。如果 macOS 弹出钥匙串对话框（可能在其他显示器上或被窗口遮挡），请选择“始终允许”或“允许”；也可以直接输入路由器密码。"
        case .authorizing: "正在等待 macOS 钥匙串授权。请查看系统对话框，它可能被其他窗口遮挡或显示在其他显示器上。"
        case .saving: "已连接路由器，正在将登录信息保存到 macOS 钥匙串。"
        case .notFound: "这台路由器还没有已保存的登录信息。请输入管理员账号和密码。"
        case .interactionRequired: "macOS 需要验证钥匙串访问权限。点击“恢复已保存登录”完成授权。"
        case .canceled: "已停止等待。可以手动输入密码；如系统对话框仍在，请自行关闭。"
        case .corrupted: "已保存的登录信息无法读取。请手动输入正确的账号和密码。"
        case .failed: "钥匙串暂时不可用。可以手动连接，本次会话不需要保存密码。"
        }
    }
    public static func from(status: Int32) -> Self {
        switch status {
        case errSecSuccess: .idle
        case errSecItemNotFound: .notFound
        case errSecInteractionNotAllowed, errSecAuthFailed: .interactionRequired
        case errSecUserCanceled: .canceled
        default: .failed(status)
        }
    }
}

/// Main-actor-owned token gate: a canceled or superseded keychain read cannot reconnect later.
public struct CredentialAccessFlow: Sendable {
    public private(set) var state: CredentialAccessState = .idle
    private var requestID: UUID?
    public init() {}
    public mutating func begin(_ state: CredentialAccessState) -> UUID {
        let token = UUID(); requestID = token; self.state = state; return token
    }
    @discardableResult public mutating func finish(_ token: UUID, state: CredentialAccessState) -> Bool {
        guard requestID == token else { return false }; requestID = nil; self.state = state; return true
    }
    public mutating func cancel() { requestID = nil; state = .canceled }
    public mutating func reset() { requestID = nil; state = .idle }
}
