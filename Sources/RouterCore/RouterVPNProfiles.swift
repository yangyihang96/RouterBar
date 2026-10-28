import Foundation

// Pure value logic for the VPN center. Nothing here performs I/O: callers read settings through the
// existing RouterClient API and pass the raw nvram values in, so every decision below is testable.

// MARK: - Inventory

public enum VPNPurpose: String, CaseIterable, Sendable, Identifiable {
    case outbound, remoteAccess, routing
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .outbound: "连接外部 VPN"
        case .remoteAccess: "远程回家"
        case .routing: "设备分流"
        }
    }
}

public enum VPNProtocolFamily: String, Sendable {
    case openVPN, wireGuard
    public var title: String { self == .openVPN ? "OpenVPN" : "WireGuard" }
}

/// Where a status shown for an instance comes from. WireGuard has no runtime state that the current
/// HTTP interface is known to expose, so only its enable flag is read and it is never reported as up.
public enum VPNStatusSource: Sendable, Equatable {
    case openVPNState
    case enableFlag
}

extension VPNInstance {
    public static let outboundSlots: [VPNInstance] = (1...5).map { .openVPNClient($0) } + (1...5).map { .wireGuardClient($0) }
    public static let serverSlots: [VPNInstance] = [.openVPNServer(1), .openVPNServer(2), .wireGuardServer]
    /// All 13 instances the firmware supports: 5 OpenVPN + 5 WireGuard clients, 2 OpenVPN servers, 1 WireGuard server.
    public static let allSlots: [VPNInstance] = outboundSlots + serverSlots

    public var unit: Int {
        switch self {
        case .openVPNClient(let n), .openVPNServer(let n), .wireGuardClient(let n): n
        case .wireGuardServer: 1
        }
    }
    public var family: VPNProtocolFamily {
        switch self {
        case .openVPNClient, .openVPNServer: .openVPN
        case .wireGuardClient, .wireGuardServer: .wireGuard
        }
    }
    public var isClient: Bool {
        switch self {
        case .openVPNClient, .wireGuardClient: true
        case .openVPNServer, .wireGuardServer: false
        }
    }
    public var purpose: VPNPurpose { isClient ? .outbound : .remoteAccess }
    /// Slot numbers stay visible because VPN Director rules and SDN exits refer to instances by number.
    public var slotLabel: String {
        switch self {
        case .openVPNClient(let n): "OpenVPN 客户端 · 槽位 \(n)"
        case .wireGuardClient(let n): "WireGuard 客户端 · 槽位 \(n)"
        case .openVPNServer(let n): "OpenVPN 服务器 · 槽位 \(n)"
        case .wireGuardServer: "WireGuard 服务器 · wgs1"
        }
    }
    /// Prefix of this instance's indexed nvram names, as used by SettingsCatalog.
    public var settingPrefix: String {
        switch self {
        case .openVPNClient(let n): "vpn_client\(n)_"
        case .openVPNServer(let n): "vpn_server\(n)_"
        case .wireGuardClient(let n): "wgc\(n)_"
        case .wireGuardServer: "wgs1_"
        }
    }
    public var statusSource: VPNStatusSource { family == .openVPN ? .openVPNState : .enableFlag }
    /// vpn_clientN_state / vpn_serverN_state for OpenVPN; the enable flag for WireGuard.
    public var statusKey: String { settingPrefix + (statusSource == .openVPNState ? "state" : "enable") }
    /// Comma-separated auto-start unit lists used by setOpenVPNStartup.
    public var startupListKey: String? {
        switch self {
        case .openVPNClient: "vpn_clientx_eas"
        case .openVPNServer: "vpn_serverx_start"
        case .wireGuardClient, .wireGuardServer: nil
        }
    }
    /// `kind` accepted by RouterClient.setVPNRunning. WireGuard is deliberately excluded: without a
    /// readable tunnel state a start/stop could never be confirmed. Its enable flag is edited as a setting.
    public var runtimeServiceKind: String? {
        switch self {
        case .openVPNClient: "vpnclient"
        case .openVPNServer: "vpnserver"
        case .wireGuardClient, .wireGuardServer: nil
        }
    }
    /// Keys read for one overview card. All are catalog fields of this instance except `statusKey`
    /// for OpenVPN. Secrets (`wgcN_priv`) are only checked for emptiness and never kept in a summary.
    public var overviewKeys: [String] {
        let suffixes: [String]
        switch self {
        case .openVPNClient: suffixes = ["desc", "addr", "port", "proto", "userauth", "username", "enforce", "state"]
        case .wireGuardClient: suffixes = ["enable", "desc", "addr", "priv", "ppub", "ep_addr", "ep_port", "aips", "enforce"]
        case .openVPNServer: suffixes = ["port", "proto", "state"]
        case .wireGuardServer: suffixes = ["enable", "port", "addr"]
        }
        return suffixes.map { settingPrefix + $0 }
    }
}

public enum VPNCenterDestination: Hashable, Sendable, Identifiable {
    case instance(VPNInstance)
    case routing

    public static let routingSectionID = "vpndirector"
    public static let all: [VPNCenterDestination] = VPNInstance.allSlots.map { .instance($0) } + [.routing]

    public init?(sectionID: String) {
        if sectionID == Self.routingSectionID { self = .routing }
        else if let instance = VPNInstance(sectionID: sectionID) { self = .instance(instance) }
        else { return nil }
    }
    /// Search jump: the destination whose catalog section owns `settingKey`.
    public init?(settingKey: String) {
        guard let section = SettingsCatalog.sections.first(where: { $0.category == "VPN" && $0.fields.contains { $0.key == settingKey } }) else { return nil }
        self.init(sectionID: section.id)
    }
    public var id: String { sectionID }
    /// Equal to the SettingsCatalog section id, so NativeSettingsModel can edit it unchanged.
    public var sectionID: String {
        switch self {
        case .instance(let instance): instance.id
        case .routing: Self.routingSectionID
        }
    }
    public var purpose: VPNPurpose {
        switch self {
        case .instance(let instance): instance.purpose
        case .routing: .routing
        }
    }
    public var instance: VPNInstance? { if case .instance(let i) = self { i } else { nil } }
}

// MARK: - Field roles and progressive disclosure

/// A catalog field identified by instance family and the suffix after its indexed prefix
/// (`vpn_client3_addr` → openVPNClient/"addr"). Lets presentation code label fields without mutating them.
public struct VPNFieldRole: Hashable, Sendable {
    public enum Family: String, Sendable { case openVPNClient, openVPNServer, wireGuardClient, wireGuardServer, director }
    public let family: Family
    public let suffix: String

    public init(family: Family, suffix: String) { self.family = family; self.suffix = suffix }

    public init?(key: String) {
        func indexed(_ prefix: String, _ range: ClosedRange<Int>) -> String? {
            guard key.hasPrefix(prefix) else { return nil }
            let rest = key.dropFirst(prefix.count)
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard let n = Int(digits), String(n) == digits, range.contains(n), rest.dropFirst(digits.count).first == "_" else { return nil }
            let suffix = String(rest.dropFirst(digits.count + 1))
            return suffix.isEmpty ? nil : suffix
        }
        if let s = indexed("vpn_client", 1...5) { self.init(family: .openVPNClient, suffix: s) }
        else if let s = indexed("vpn_server", 1...2) { self.init(family: .openVPNServer, suffix: s) }
        else if let s = indexed("wgc", 1...5) { self.init(family: .wireGuardClient, suffix: s) }
        else if key.hasPrefix("wgs1_"), key.count > 5 { self.init(family: .wireGuardServer, suffix: String(key.dropFirst(5))) }
        else if key.hasPrefix("vpndirector_"), key.count > 12 { self.init(family: .director, suffix: String(key.dropFirst(12))) }
        else { return nil }
    }
}

public enum VPNFieldTier: Sendable, Equatable { case primary, advanced }

public enum VPNFieldLayout {
    /// First-screen fields, in display order. Everything else stays reachable in the advanced group.
    public static func primarySuffixes(_ family: VPNFieldRole.Family) -> [String] {
        switch family {
        case .openVPNClient: ["desc", "addr", "port", "proto", "userauth", "username", "password", "enforce"]
        case .wireGuardClient: ["desc", "enable", "ep_addr", "ep_port", "addr", "ppub", "aips", "enforce"]
        case .openVPNServer: ["port", "proto", "igncrt"]
        case .wireGuardServer: ["enable", "port", "addr"]
        case .director: ["rulelist"]
        }
    }
    public static func tier(forKey key: String) -> VPNFieldTier {
        guard let role = VPNFieldRole(key: key) else { return .advanced }
        return primarySuffixes(role.family).contains(role.suffix) ? .primary : .advanced
    }
    /// Splits catalog fields without copying or altering them. Primary keeps the curated order,
    /// advanced keeps catalog order; together they contain every field exactly once.
    public static func partition(_ fields: [SettingField]) -> (primary: [SettingField], advanced: [SettingField]) {
        var primary: [(rank: Int, field: SettingField)] = []
        var advanced: [SettingField] = []
        for field in fields {
            if let role = VPNFieldRole(key: field.key), let rank = primarySuffixes(role.family).firstIndex(of: role.suffix) {
                primary.append((rank, field))
            } else {
                advanced.append(field)
            }
        }
        return (primary.sorted { $0.rank < $1.rank }.map(\.field), advanced)
    }
}

// MARK: - Slot classification

public enum VPNSlotPresence: Sendable, Equatable {
    /// A required key was not returned; nothing is inferred.
    case unread
    /// No connection details found in the fields read. Certificates and unrequested fields are not checked.
    case unused
    /// Some evidence of configuration, but required items are missing (Chinese item names).
    case incomplete(missing: [String])
    /// Required connection fields are present. Certificates are not part of this check.
    case configured
    /// Server slots are fixed services: always listed, status comes from the router.
    case service

    public var foldsIntoAddMenu: Bool { self == .unused }
}

public enum VPNProfileClassifier {
    /// A client with known missing connection fields must be completed before starting it.
    /// This is a presentation preflight, not a claim that certificates or connectivity are valid.
    public static func startBlockReason(for instance: VPNInstance, presence: VPNSlotPresence?) -> String? {
        guard instance.isClient else { return nil }
        switch presence {
        case .configured: return nil
        case .incomplete(let fields): return "启动前请补全：" + fields.joined(separator: "、") + "。"
        case .unused: return "请先填写连接信息或导入配置文件。"
        default: return "请先成功读取此配置，再启动 VPN。"
        }
    }

    /// Conservative classification. Default ports, NAT and firewall toggles are not configuration
    /// evidence. Any nonempty name keeps a slot visible as incomplete; no default name is guessed.
    /// `values` may come from an overview read or from the full catalog section; the OpenVPN state
    /// key is optional evidence (a slot that is not stopped is never folded away).
    public static func presence(of instance: VPNInstance, values: [String: String]) -> VPNSlotPresence {
        let p = instance.settingPrefix
        func value(_ suffix: String) -> String? { values[p + suffix].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }
        func validPort(_ raw: String) -> Bool { Int(raw).map { (1...65535).contains($0) } ?? false }
        switch instance {
        case .openVPNServer, .wireGuardServer:
            return .service
        case .openVPNClient:
            guard let name = value("desc"), let addr = value("addr"), let port = value("port"), let userauth = value("userauth"),
                  let username = value("username"), let enforce = value("enforce") else { return .unread }
            let state = value("state") ?? "0"
            let active = !(state == "0" || state.isEmpty)
            if addr.isEmpty {
                let hasDetails = !name.isEmpty || !username.isEmpty || !(value("password") ?? "").isEmpty || userauth == "1" || enforce == "1" || active
                return hasDetails ? .incomplete(missing: ["服务器地址"]) : .unused
            }
            var missing: [String] = []
            if !validPort(port) { missing.append("服务器端口") }
            if userauth == "1" && username.isEmpty { missing.append("用户名") }
            return missing.isEmpty ? .configured : .incomplete(missing: missing)
        case .wireGuardClient:
            guard let name = value("desc"), let enable = value("enable"), let addr = value("addr"), let priv = value("priv"), let ppub = value("ppub"),
                  let epAddr = value("ep_addr"), let epPort = value("ep_port"), let aips = value("aips"),
                  let enforce = value("enforce") else { return .unread }
            let evidence = [name, addr, priv, ppub, epAddr, value("psk") ?? ""].contains { !$0.isEmpty } || enable == "1" || enforce == "1"
            guard evidence else { return .unused }
            var missing: [String] = []
            if addr.isEmpty { missing.append("隧道地址") }
            if priv.isEmpty { missing.append("私钥") }
            if ppub.isEmpty { missing.append("服务器公钥") }
            if epAddr.isEmpty { missing.append("端点地址") }
            if !validPort(epPort) { missing.append("端点端口") }
            if aips.isEmpty { missing.append("允许的 IP") }
            return missing.isEmpty ? .configured : .incomplete(missing: missing)
        }
    }
}

// MARK: - Summaries

public enum VPNAllowedIPsSummary: Sendable, Equatable {
    case empty
    case allTraffic(includesIPv6: Bool)
    case ranges(Int)

    public init(_ raw: String) {
        let items = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if items.isEmpty { self = .empty }
        else if items.contains("0.0.0.0/0") { self = .allTraffic(includesIPv6: items.contains("::/0")) }
        else { self = .ranges(items.count) }
    }
    public var text: String {
        switch self {
        case .empty: "未设置"
        case .allTraffic(let v6): v6 ? "全部流量（IPv4 与 IPv6）" : "全部 IPv4 流量"
        case .ranges(let n): "\(n) 个网段"
        }
    }
}

public enum VPNStartupList {
    /// Parses "1,3," as written by setOpenVPNStartup. Returns nil for anything else so the UI can refuse to edit it.
    public static func units(_ raw: String, maximum: Int) -> Set<Int>? {
        var result = Set<Int>()
        for piece in raw.split(separator: ",") {
            guard let n = Int(piece.trimmingCharacters(in: .whitespaces)), (1...maximum).contains(n) else { return nil }
            result.insert(n)
        }
        return result
    }
    public static func contains(_ instance: VPNInstance, in raw: String) -> Bool? {
        let maximum: Int
        switch instance {
        case .openVPNClient: maximum = 5
        case .openVPNServer: maximum = 2
        case .wireGuardClient, .wireGuardServer: return nil
        }
        return units(raw, maximum: maximum)?.contains(instance.unit)
    }
}

public enum VPNEndpointText {
    /// "host:port"; IPv6 literals are bracketed. Empty host gives nil.
    public static func make(host: String, port: String) -> String? {
        let host = host.trimmingCharacters(in: .whitespaces), port = port.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return nil }
        guard !port.isEmpty else { return host }
        return (host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host) + ":" + port
    }
    public static func transport(_ proto: String) -> String? {
        switch proto {
        case "": nil
        case "udp", "udp4", "udp6": "UDP"
        case "tcp-client", "tcp-server", "tcp", "tcp4-client", "tcp6-client": "TCP"
        default: proto
        }
    }
}

/// Display data for one card. Holds no secrets: private keys and passwords are reduced to presence checks.
public struct VPNProfileSummary: Sendable, Equatable {
    public let instance: VPNInstance
    public let presence: VPNSlotPresence
    public let name: String
    public let endpoint: String?
    public let transport: String?
    public let tunnelAddress: String?
    public let allowedIPs: VPNAllowedIPsSummary?
    public let killSwitch: Bool?
    public let condition: VPNRuntimeCondition?
    public let autoStart: Bool?

    public init(instance: VPNInstance, values: [String: String], startupList: String? = nil) {
        let p = instance.settingPrefix
        func v(_ suffix: String) -> String { (values[p + suffix] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        func has(_ suffix: String) -> Bool { values[p + suffix] != nil }
        self.instance = instance
        presence = VPNProfileClassifier.presence(of: instance, values: values)
        name = v("desc")
        switch instance {
        case .openVPNClient:
            endpoint = VPNEndpointText.make(host: v("addr"), port: v("port"))
            transport = VPNEndpointText.transport(v("proto"))
            tunnelAddress = nil; allowedIPs = nil
            killSwitch = has("enforce") ? v("enforce") == "1" : nil
        case .wireGuardClient:
            endpoint = VPNEndpointText.make(host: v("ep_addr"), port: v("ep_port"))
            transport = "UDP"
            tunnelAddress = v("addr").isEmpty ? nil : v("addr")
            allowedIPs = has("aips") ? VPNAllowedIPsSummary(v("aips")) : nil
            killSwitch = has("enforce") ? v("enforce") == "1" : nil
        case .openVPNServer:
            endpoint = v("port").isEmpty ? nil : "端口 \(v("port"))"
            transport = VPNEndpointText.transport(v("proto"))
            tunnelAddress = nil; allowedIPs = nil; killSwitch = nil
        case .wireGuardServer:
            endpoint = v("port").isEmpty ? nil : "端口 \(v("port"))"
            transport = "UDP"
            tunnelAddress = v("addr").isEmpty ? nil : v("addr")
            allowedIPs = nil; killSwitch = nil
        }
        condition = values[instance.statusKey].map { VPNRuntimeCondition(raw: $0, source: instance.statusSource) }
        autoStart = startupList.flatMap { VPNStartupList.contains(instance, in: $0) }
    }

    public var displayName: String { name.isEmpty ? instance.title : name }
    /// "vpn.example.com:1194 · UDP"
    public var connectionLine: String? {
        guard let endpoint else { return nil }
        return [endpoint, transport].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - VPN Director references

/// Only the literal interface tokens the catalog documents (OVPN1…OVPN5) are attributed to an instance.
/// Other tokens are listed verbatim by the routing page and never guessed.
public struct VPNDirectorSummary: Sendable, Equatable {
    public struct InterfaceCount: Sendable, Equatable {
        public let name: String
        public var total: Int
        public var enabled: Int
    }
    public let total: Int
    public let enabled: Int
    /// Raw interface column values with their rule counts, in first-seen order.
    public let interfaces: [InterfaceCount]

    public static let columns = 5

    /// Throws when the list does not decode with the catalog's 5 columns; the caller then shows it as unparsed.
    public init(raw: String) throws {
        let rows = try RouterRuleCodec.decode(raw, columns: Self.columns)
        var counts: [InterfaceCount] = []
        for row in rows {
            if !counts.contains(where: { $0.name == row[4] }) { counts.append(InterfaceCount(name: row[4], total: 0, enabled: 0)) }
            guard let index = counts.firstIndex(where: { $0.name == row[4] }) else { continue }
            counts[index].total += 1
            if row[0] == "1" { counts[index].enabled += 1 }
        }
        total = rows.count
        enabled = rows.filter { $0[0] == "1" }.count
        interfaces = counts
    }

    public static func interfaceToken(for instance: VPNInstance) -> String? {
        if case .openVPNClient(let n) = instance { return "OVPN\(n)" }
        return nil
    }
    /// nil when the token for this instance is not documented (WireGuard): the UI then says so instead of showing 0.
    public func references(to instance: VPNInstance) -> (total: Int, enabled: Int)? {
        guard let token = Self.interfaceToken(for: instance) else { return nil }
        let match = interfaces.first { $0.name == token }
        return (match?.total ?? 0, match?.enabled ?? 0)
    }
}

// MARK: - Read state

public struct VPNReadFailure: Error, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// Explicit read state: "never read", "reading", "read at T" and "failed at T" are distinct.
public enum VPNReadState<Value: Sendable & Equatable>: Sendable, Equatable {
    case notRead
    case loading(since: Date)
    case loaded(Value, at: Date)
    case failed(String, at: Date)
    case unsupported(String)

    public var value: Value? { if case .loaded(let v, _) = self { v } else { nil } }
    public var isLoading: Bool { if case .loading = self { true } else { false } }
    public var timestamp: Date? {
        switch self {
        case .loaded(_, let at), .failed(_, let at): at
        case .loading(let since): since
        case .notRead, .unsupported: nil
        }
    }
}

// MARK: - Runtime

public enum VPNRuntimeCondition: Sendable, Equatable {
    // OpenVPN vpn_clientN_state / vpn_serverN_state
    case stopped, connecting, running, error
    // WireGuard enable flag only
    case enabledUnconfirmed, disabled
    case unrecognized(String)

    public init(raw: String, source: VPNStatusSource) {
        let value = raw.trimmingCharacters(in: .whitespaces)
        switch source {
        case .openVPNState:
            switch value {
            case "0": self = .stopped
            case "1": self = .connecting
            case "2": self = .running
            case "-1": self = .error
            default: self = .unrecognized(value)
            }
        case .enableFlag:
            // nvram_get_int() reads an unset value as 0.
            switch value {
            case "1": self = .enabledUnconfirmed
            case "0", "": self = .disabled
            default: self = .unrecognized(value)
            }
        }
    }
}

public enum VPNRuntimeAction: String, Sendable, Equatable, Identifiable {
    case start, stop
    public var id: String { rawValue }
    public var title: String { self == .start ? "启动" : "停止" }
    func reached(_ condition: VPNRuntimeCondition) -> Bool {
        self == .start ? condition == .running : condition == .stopped
    }
}

public struct VPNRuntimeReading: Sendable, Equatable {
    public let condition: VPNRuntimeCondition
    public let rawState: String
    /// Raw startup list (OpenVPN only), passed back unchanged as `before` when saving.
    public let startupList: String?
    /// nil when the list is absent or in a format this app does not edit.
    public let autoStart: Bool?

    /// Fails when the status key (or the startup list for OpenVPN) is missing, so a partial reply is never shown as a state.
    public init(instance: VPNInstance, values: [String: String]) throws {
        guard let raw = values[instance.statusKey] else { throw VPNReadFailure("路由器没有返回 \(instance.statusKey)") }
        var list: String?
        if let key = instance.startupListKey {
            guard let value = values[key] else { throw VPNReadFailure("路由器没有返回 \(key)") }
            list = value
        }
        rawState = raw
        condition = VPNRuntimeCondition(raw: raw, source: instance.statusSource)
        startupList = list
        autoStart = list.flatMap { VPNStartupList.contains(instance, in: $0) }
    }
    public static func keys(for instance: VPNInstance) -> [String] { [instance.statusKey] + (instance.startupListKey.map { [$0] } ?? []) }
}

public enum VPNWriteAvailability: Sendable, Equatable {
    case allowed
    case blocked(String)
    public var isAllowed: Bool { self == .allowed }
    public var reason: String? { if case .blocked(let r) = self { r } else { nil } }
}

public struct VPNRuntimeOperation: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case submitting
        case awaiting(since: Date)
        case confirmed
        case reportedError
        case timedOut
        /// The user stopped waiting. The request was sent and is neither undone nor resent.
        case abandoned
        /// The request may have reached the router, but its result is uncertain.
        case unconfirmed(String)
        case connectionLost
    }
    public let action: VPNRuntimeAction
    public let ticket: VPNRuntimeTracker.Ticket
    public var phase: Phase
    public var lastPollError: String?
    public var isActive: Bool {
        switch phase { case .submitting, .awaiting: true; default: false }
    }
    public var awaitingSince: Date? { if case .awaiting(let d) = phase { d } else { nil } }
}

public enum VPNStatusTone: Sendable, Equatable { case neutral, active, pending, attention, failure }

public struct VPNStatusDescription: Sendable, Equatable {
    public let title: String
    public let detail: String?
    public let tone: VPNStatusTone
    public let at: Date?
    public init(_ title: String, detail: String? = nil, tone: VPNStatusTone, at: Date? = nil) {
        self.title = title; self.detail = detail; self.tone = tone; self.at = at
    }

    public static func condition(_ condition: VPNRuntimeCondition, at: Date?) -> VPNStatusDescription {
        switch condition {
        case .running: .init("运行中", detail: "路由器报告此实例已运行。", tone: .active, at: at)
        case .connecting: .init("正在建立连接", tone: .pending, at: at)
        case .stopped: .init("已停止", tone: .neutral, at: at)
        case .error: .init("路由器报告连接异常", detail: "请检查服务器、账号与证书。", tone: .failure, at: at)
        case .enabledUnconfirmed: .init("已启用 · 连接待确认", detail: "路由器未提供 WireGuard 隧道状态，RouterBar 不推断连接结果。", tone: .pending, at: at)
        case .disabled: .init("未启用", tone: .neutral, at: at)
        case .unrecognized(let raw): .init("未识别的状态值“\(raw)”", detail: "不会据此提供启动或停止操作。", tone: .attention, at: at)
        }
    }

    /// Status for an overview card. Disconnection always wins so a stale read is never shown as current.
    public static func overview(_ state: VPNReadState<VPNProfileSummary>, connected: Bool) -> VPNStatusDescription {
        guard connected else { return .init("未连接路由器 · 状态未知", tone: .neutral) }
        switch state {
        case .notRead: return .init("尚未读取", tone: .neutral)
        case .loading(let since): return .init("正在读取…", tone: .neutral, at: since)
        case .failed(let message, let at): return .init("读取失败", detail: message, tone: .failure, at: at)
        case .unsupported(let message): return .init(message, tone: .neutral)
        case .loaded(let summary, let at):
            switch summary.presence {
            case .unread: return .init("路由器未完整返回此槽位", tone: .attention, at: at)
            case .unused: return .init("尚未填写连接信息", tone: .neutral, at: at)
            case .incomplete(let missing):
                return .init("配置不完整", detail: "缺少：" + missing.joined(separator: "、"), tone: .attention, at: at)
            case .configured, .service:
                guard let runtime = summary.condition else {
                    return .init(summary.presence == .configured ? "已配置 · 运行状态未读取" : "运行状态未读取", tone: .neutral, at: at)
                }
                return .condition(runtime, at: at)
            }
        }
    }
}

/// State machine behind VPNRuntimeView. Every async result carries a ticket; results for an older
/// selection or operation are dropped, so switching instance can never be overwritten by a late reply.
public struct VPNRuntimeTracker: Sendable, Equatable {
    public struct Ticket: Sendable, Equatable {
        public let generation: Int
        public let instance: VPNInstance
    }
    public enum PollDecision: Sendable, Equatable { case keepWaiting, finished, ignored }

    public private(set) var instance: VPNInstance
    public private(set) var reading: VPNReadState<VPNRuntimeReading>
    public private(set) var operation: VPNRuntimeOperation?
    /// Set after any write whose outcome was not confirmed; writes stay blocked until a fresh read succeeds.
    public private(set) var requiresFreshRead = false
    private var generation = 0
    private var readTicket: Ticket?

    public init(instance: VPNInstance) {
        self.instance = instance
        reading = .notRead
    }

    /// Clears everything belonging to the previous instance and invalidates all outstanding tickets.
    public mutating func select(_ instance: VPNInstance) {
        self.instance = instance
        generation += 1
        reading = .notRead
        operation = nil
        requiresFreshRead = false
        readTicket = nil
    }

    // MARK: Reads

    public mutating func beginRead(at date: Date) -> Ticket? {
        guard operation?.isActive != true else { return nil }
        generation += 1
        let ticket = Ticket(generation: generation, instance: instance)
        readTicket = ticket
        reading = .loading(since: date)
        return ticket
    }

    /// Returns false when the result is stale and was dropped.
    @discardableResult
    public mutating func finishRead(_ ticket: Ticket, _ result: Result<VPNRuntimeReading, VPNReadFailure>, at date: Date) -> Bool {
        guard ticket == readTicket, ticket.instance == instance else { return false }
        readTicket = nil
        switch result {
        case .success(let value):
            reading = .loaded(value, at: date)
            requiresFreshRead = false
            if operation?.isActive == false { operation = nil }
        case .failure(let failure):
            reading = .failed(failure.message, at: date)
        }
        return true
    }

    // MARK: Writes

    public var primaryAction: VPNRuntimeAction? {
        guard instance.runtimeServiceKind != nil, case .loaded(let value, _) = reading else { return nil }
        switch value.condition {
        case .stopped, .error: return .start
        case .running, .connecting: return .stop
        case .enabledUnconfirmed, .disabled, .unrecognized: return nil
        }
    }

    public func writeAvailability(connected: Bool, otherOperationRunning: Bool) -> VPNWriteAvailability {
        guard connected else { return .blocked("未连接路由器。") }
        guard instance.runtimeServiceKind != nil else { return .blocked("WireGuard 的启用开关在下方设置中修改。") }
        if operation?.isActive == true { return .blocked("正在等待上一次请求的结果。") }
        if requiresFreshRead { return .blocked("上一次请求的结果尚未确认，请先重新读取状态。") }
        switch reading {
        case .notRead: return .blocked("请先读取当前状态。")
        case .loading: return .blocked("正在读取状态。")
        case .failed: return .blocked("读取失败，无法确认当前状态，已禁止启动或停止。")
        case .unsupported(let message): return .blocked(message)
        case .loaded(let value, _):
            if case .unrecognized = value.condition { return .blocked("路由器返回了未识别的状态，已禁止启动或停止。") }
        }
        if otherOperationRunning { return .blocked("另一项路由器操作正在进行。") }
        return .allowed
    }

    public mutating func beginOperation(_ action: VPNRuntimeAction, connected: Bool, otherOperationRunning: Bool) -> Ticket? {
        guard writeAvailability(connected: connected, otherOperationRunning: otherOperationRunning).isAllowed, primaryAction == action else { return nil }
        generation += 1
        let ticket = Ticket(generation: generation, instance: instance)
        readTicket = nil
        operation = VPNRuntimeOperation(action: action, ticket: ticket, phase: .submitting)
        return ticket
    }

    private func owns(_ ticket: Ticket) -> Bool { operation?.ticket == ticket && ticket.instance == instance }

    public mutating func submissionAccepted(_ ticket: Ticket, at date: Date) {
        guard owns(ticket), operation?.phase == .submitting else { return }
        operation?.phase = .awaiting(since: date)
    }

    public mutating func submissionFailed(_ ticket: Ticket, message: String) {
        guard owns(ticket), operation?.isActive == true else { return }
        operation?.phase = .unconfirmed(message)
        requiresFreshRead = true
    }

    /// The router never took the request (unreachable, signed out or refused), so the last reading still stands.
    public mutating func submissionNotSent(_ ticket: Ticket) {
        guard owns(ticket), operation?.phase == .submitting else { return }
        operation = nil
    }

    public mutating func observe(_ ticket: Ticket, rawState: String, at date: Date) -> PollDecision {
        guard owns(ticket), let operation = self.operation, operation.awaitingSince != nil else { return .ignored }
        // Polls read only the state key; the startup list from the last full read is carried over unchanged.
        var values = [instance.statusKey: rawState]
        if let key = instance.startupListKey, let list = reading.value?.startupList { values[key] = list }
        if let fresh = try? VPNRuntimeReading(instance: instance, values: values) { reading = .loaded(fresh, at: date) }
        let condition = VPNRuntimeCondition(raw: rawState, source: instance.statusSource)
        self.operation?.lastPollError = nil
        if operation.action.reached(condition) { self.operation?.phase = .confirmed; return .finished }
        if condition == .error { self.operation?.phase = .reportedError; return .finished }
        return .keepWaiting
    }

    /// A poll failed; services may be restarting, so waiting continues.
    public mutating func pollFailed(_ ticket: Ticket, message: String) {
        guard owns(ticket), operation?.awaitingSince != nil else { return }
        operation?.lastPollError = message
    }

    public mutating func timedOut(_ ticket: Ticket) {
        guard owns(ticket), operation?.awaitingSince != nil else { return }
        operation?.phase = .timedOut
        requiresFreshRead = true
    }

    public mutating func connectionLost(_ ticket: Ticket) {
        guard owns(ticket), operation?.isActive == true else { return }
        operation?.phase = .connectionLost
        requiresFreshRead = true
    }

    /// Stops waiting only; the request already sent is not undone and must not be resent before a fresh read.
    @discardableResult
    public mutating func stopWaiting(_ ticket: Ticket) -> Bool {
        guard owns(ticket), operation?.awaitingSince != nil else { return false }
        operation?.phase = .abandoned
        requiresFreshRead = true
        return true
    }

    public func status(connected: Bool) -> VPNStatusDescription {
        guard connected else {
            let last = reading.value.map { "上次读取：" + VPNStatusDescription.condition($0.condition, at: nil).title }
            return .init("未连接路由器 · 运行状态未知", detail: last, tone: .neutral)
        }
        if let operation = self.operation {
            let verb = operation.action == .start ? "启动" : "停止"
            switch operation.phase {
            case .submitting:
                return .init("正在发送\(verb)请求", tone: .pending)
            case .awaiting(let since):
                return .init("已请求\(verb) · 等待路由器确认", detail: operation.lastPollError.map { "暂时无法读取：\($0)" }
                             ?? "停止等待不会撤销已发送的请求。", tone: .pending, at: since)
            case .abandoned where requiresFreshRead:
                return .init("已停止等待 · 结果未确认", detail: "\(verb)请求已发送，不会撤销，也不会重复提交。请重新读取状态。", tone: .attention, at: reading.timestamp)
            case .timedOut where requiresFreshRead:
                return .init("\(verb)请求已发送 · 尚未达到目标状态", detail: "请稍后重新读取状态。", tone: .attention, at: reading.timestamp)
            case .unconfirmed(let message) where requiresFreshRead:
                return .init("\(verb)请求结果未确认", detail: message, tone: .attention)
            case .connectionLost where requiresFreshRead:
                return .init("连接中断 · \(verb)结果未确认", detail: "重新连接后请先读取状态。", tone: .attention)
            default:
                break
            }
        }
        switch reading {
        case .notRead: return .init("尚未读取运行状态", tone: .neutral)
        case .loading(let since): return .init("正在读取运行状态…", tone: .neutral, at: since)
        case .failed(let message, let at): return .init("读取失败", detail: message, tone: .failure, at: at)
        case .unsupported(let message): return .init(message, tone: .neutral)
        case .loaded(let value, let at): return .condition(value.condition, at: at)
        }
    }
}

// MARK: - Draft protection

public enum VPNSelectionDecision: Sendable, Equatable {
    case alreadySelected
    case proceed
    case confirmDiscard(changes: Int)
    case blocked(String)
}

public enum VPNSelectionPolicy {
    /// Decides whether the editor may switch to `target`. Unsaved drafts need confirmation; switching
    /// while a save or another router operation is running is refused so a late result cannot land on the wrong instance.
    public static func decide(current: VPNCenterDestination?, target: VPNCenterDestination, pendingChanges: Int,
                              saving: Bool, operationRunning: Bool) -> VPNSelectionDecision {
        if current == target { return .alreadySelected }
        if saving { return .blocked("正在保存当前配置，请等待完成。") }
        if operationRunning { return .blocked("路由器操作进行中，请等待完成后再切换。") }
        return pendingChanges > 0 ? .confirmDiscard(changes: pendingChanges) : .proceed
    }
}

// MARK: - Import placement

public enum VPNImportPlacement: Sendable, Equatable {
    /// Empty client slot: importing a file is the recommended first step.
    case recommended
    /// The slot holds (or may hold) settings: import is a destructive replacement behind a disclosure.
    case replacement
    /// Servers cannot import a client configuration.
    case unavailable

    /// Only a slot freshly read as `.unused` is offered import as a safe addition. Unread, incomplete
    /// and configured slots are all treated as replacements.
    public static func decide(_ instance: VPNInstance, presence: VPNSlotPresence?) -> VPNImportPlacement {
        guard instance.isClient else { return .unavailable }
        return presence == .unused ? .recommended : .replacement
    }
}
