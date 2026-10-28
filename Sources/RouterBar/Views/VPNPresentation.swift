import SwiftUI
import RouterCore

/// Chinese labels, help and status styling for the VPN center.
///
/// Catalog fields are never modified for saving. `displayField(_:)` returns a copy that is only handed to
/// NativeSettingRow / RuleSummary for rendering; NativeSettingsModel.changes keeps using the catalog
/// definitions, so applySettings still matches `definition.fields` exactly.
enum VPNPresentation {
    struct FieldText: Sendable { let label: String; var help: String? = nil; var options: [String: String] = [:] }

    static func text(for key: String) -> FieldText? {
        guard let role = VPNFieldRole(key: key) else { return nil }
        switch role.family {
        case .openVPNClient: return openVPNClient[role.suffix]
        case .openVPNServer: return openVPNServer[role.suffix]
        case .wireGuardClient: return wireGuardClient[role.suffix]
        case .wireGuardServer: return wireGuardServer[role.suffix]
        case .director: return director[role.suffix]
        }
    }
    static func label(for field: SettingField) -> String { text(for: field.key)?.label ?? field.label }
    static func help(for field: SettingField) -> String? { text(for: field.key)?.help ?? field.note }

    /// Display-only copy. Do not pass the result to SettingChange / applySettings.
    static func displayField(_ field: SettingField) -> SettingField {
        guard let text = text(for: field.key) else { return field }
        var copy = field
        copy.label = text.label
        copy.note = text.help ?? field.note
        copy.options = field.options.map { option in
            var localized = option
            localized.label = text.options[option.value] ?? option.label
            return localized
        }
        if field.kind == "rules", field.key == "vpndirector_rulelist" {
            copy.columns = ["启用（0/1）", "说明", "本地 IP / 子网", "远程 IP / 子网", "接口（WAN / OVPN1…）"]
        }
        return copy
    }

    static func time(_ date: Date) -> String { MonitoringDate.time(date) }

    // MARK: Tables

    private static let killSwitchHelp = "隧道中断时，阻止经由此 VPN 分流的设备直接访问互联网。"
    private static let tlsOptions = ["-1": "停用", "2": "双向认证", "0": "入站认证（0）", "1": "出站认证（1）", "3": "加密通道（tls-crypt）", "4": "加密通道 V2（tls-crypt-v2）"]
    private static let compressionOptions = ["-1": "停用", "no": "无", "yes": "LZO", "adaptive": "LZO 自适应"]

    private static let openVPNClient: [String: FieldText] = [
        "desc": .init(label: "名称", help: "用于在 VPN 页面和分流规则中识别此配置。"),
        "proto": .init(label: "传输协议"),
        "addr": .init(label: "服务器地址"),
        "port": .init(label: "服务器端口"),
        "bridge": .init(label: "服务器位于同一子网"),
        "nat": .init(label: "在隧道上创建 NAT"),
        "fw": .init(label: "入站防火墙", help: "开启后阻止从隧道主动发起的入站连接。"),
        "remote": .init(label: "远程端点地址", help: "静态密钥模式使用。"),
        "nm": .init(label: "隧道子网掩码"),
        "adns": .init(label: "接受服务器下发的 DNS", options: ["0": "停用", "1": "宽松", "2": "严格", "3": "独占"]),
        "gw": .init(label: "隧道网关"),
        "enforce": .init(label: "Kill switch", help: killSwitchHelp),
        "crypt": .init(label: "验证模式"),
        "userauth": .init(label: "用户名 / 密码验证"),
        "username": .init(label: "用户名"),
        "password": .init(label: "密码"),
        "useronly": .init(label: "仅用户名 / 密码验证", help: "不使用客户端证书。"),
        "ncp_ciphers": .init(label: "数据加密算法（Data ciphers）"),
        "cipher": .init(label: "旧式加密算法（Cipher）", options: ["default": "默认"]),
        "hmac": .init(label: "TLS 控制通道保护", options: tlsOptions),
        "digest": .init(label: "认证摘要算法"),
        "verb": .init(label: "日志详细程度"),
        "comp": .init(label: "压缩", options: compressionOptions),
        "reneg": .init(label: "TLS 重新协商间隔（秒）"),
        "connretry": .init(label: "连接重试次数"),
        "tlsremote": .init(label: "校验服务器证书名称", options: ["0": "不校验", "1": "Common Name", "2": "Common Name 前缀", "3": "Subject"]),
        "cn": .init(label: "证书名称匹配值", help: "配合“校验服务器证书名称”使用。"),
    ]

    private static let wireGuardClient: [String: FieldText] = [
        "enable": .init(label: "启用此客户端", help: "开启只表示路由器会尝试建立隧道；路由器未提供连接状态。"),
        "desc": .init(label: "名称", help: "用于在 VPN 页面中识别此配置。"),
        "nat": .init(label: "启用 NAT"),
        "fw": .init(label: "入站防火墙", help: "开启后阻止从隧道主动发起的入站连接。"),
        "enforce": .init(label: "Kill switch", help: killSwitchHelp),
        "priv": .init(label: "客户端私钥"),
        "mtu": .init(label: "MTU（可选）"),
        "addr": .init(label: "隧道地址"),
        "dns": .init(label: "DNS 服务器（可选）"),
        "ppub": .init(label: "服务器公钥"),
        "psk": .init(label: "预共享密钥（可选）"),
        "aips": .init(label: "允许的 IP（Allowed IPs）", help: "0.0.0.0/0 表示全部 IPv4 流量。多个网段以逗号分隔。"),
        "ep_addr": .init(label: "端点地址"),
        "ep_port": .init(label: "端点端口"),
        "alive": .init(label: "保活间隔（秒）"),
    ]

    private static let openVPNServer: [String: FieldText] = [
        "port": .init(label: "监听端口"),
        "proto": .init(label: "传输协议", options: ["tcp-server": "TCP"]),
        "if": .init(label: "接口类型"),
        "crypt": .init(label: "验证模式"),
        "dhcp": .init(label: "从 DHCP 分配客户端地址"),
        "local": .init(label: "本地端点地址"),
        "remote": .init(label: "远程端点地址"),
        "sn": .init(label: "VPN 子网"),
        "nm": .init(label: "VPN 子网掩码"),
        "r1": .init(label: "客户端地址池起点"),
        "r2": .init(label: "客户端地址池终点"),
        "ip6": .init(label: "启用 IPv6 服务器模式"),
        "nat6": .init(label: "启用 IPv6 NAT"),
        "local6": .init(label: "IPv6 本地端点地址"),
        "remote6": .init(label: "IPv6 远程端点地址"),
        "sn6": .init(label: "IPv6 VPN 子网"),
        "ncp_ciphers": .init(label: "数据加密算法（Data ciphers）"),
        "comp": .init(label: "压缩", options: compressionOptions),
        "verb": .init(label: "日志详细程度"),
        "pdns": .init(label: "向客户端推送 DNS"),
        "c2c": .init(label: "允许客户端之间互访"),
        "ccd": .init(label: "按客户端单独配置"),
        "ccd_excl": .init(label: "仅允许特定客户端"),
        "hmac": .init(label: "TLS 控制通道保护", options: tlsOptions),
        "igncrt": .init(label: "仅用户名 / 密码验证", help: "客户端无需证书。"),
    ]

    private static let wireGuardServer: [String: FieldText] = [
        "enable": .init(label: "启用 WireGuard 服务器"),
        "dns": .init(label: "允许客户端使用路由器 DNS"),
        "nat6": .init(label: "IPv6 NAT"),
        "psk": .init(label: "使用预共享密钥"),
        "alive": .init(label: "保活间隔（秒）"),
        "addr": .init(label: "服务器隧道地址"),
        "port": .init(label: "监听端口"),
    ]

    private static let director: [String: FieldText] = [
        "rulelist": .init(label: "分流规则", help: "按设备或网段指定经由 WAN 或某个 VPN 客户端出站。"),
    ]
}

extension VPNStatusTone {
    var color: Color {
        switch self {
        case .neutral: .secondary
        case .active: .teal
        case .pending: .blue
        case .attention: .orange
        case .failure: .red
        }
    }
    var symbol: String {
        switch self {
        case .neutral: "circle.dashed"
        case .active: "lock.shield.fill"
        case .pending: "clock.badge.questionmark"
        case .attention: "exclamationmark.triangle.fill"
        case .failure: "xmark.octagon.fill"
        }
    }
    var banner: NoticeBanner.Tone {
        switch self {
        case .neutral, .pending: .information
        case .active: .success
        case .attention: .attention
        case .failure: .error
        }
    }
}

extension VPNInstance {
    var symbol: String {
        switch self {
        case .openVPNClient: "lock.shield"
        case .wireGuardClient: "key.horizontal"
        case .openVPNServer, .wireGuardServer: "house.and.flag"
        }
    }
}

extension VPNCenterDestination {
    var title: String {
        switch self {
        case .instance(let instance): instance.title
        case .routing: "VPN Director 分流规则"
        }
    }
    var symbol: String {
        switch self {
        case .instance(let instance): instance.symbol
        case .routing: "arrow.triangle.branch"
        }
    }
}

/// Compact status line: tone icon, title and, when present, the read time.
struct VPNStatusLabel: View {
    let status: VPNStatusDescription
    var compact = false
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: status.tone.symbol).foregroundStyle(status.tone.color)
            Text(status.title).foregroundStyle(compact ? .secondary : .primary)
            if let at = status.at, !compact { Text("· \(VPNPresentation.time(at))").foregroundStyle(.secondary).monospacedDigit() }
        }
        .font(compact ? .caption : .callout)
        .accessibilityElement(children: .combine)
    }
}
