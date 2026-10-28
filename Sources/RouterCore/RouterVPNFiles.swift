import Foundation
import CryptoKit

/// VPN instances addressed explicitly by unit. Every request below carries the unit itself;
/// nothing depends on the router's web-selected `vpn_client_unit` / `vpn_server_unit`.
public enum VPNInstance: Hashable, Sendable, Identifiable {
    case openVPNClient(Int)   // ovpn1…5   — firmware-web.c OVPN_CLIENT_MAX
    case openVPNServer(Int)   // ovpns1…2  — firmware-web.c OVPN_SERVER_MAX
    case wireGuardClient(Int) // wgc1…5
    case wireGuardServer      // wgs1      — ej_get_wgsc_parameter clamps wgs_unit to 1

    public init?(sectionID: String) {
        func unit(_ prefix: String, _ range: ClosedRange<Int>) -> Int? {
            guard sectionID.hasPrefix(prefix), let n = Int(sectionID.dropFirst(prefix.count)),
                  String(n) == sectionID.dropFirst(prefix.count), range.contains(n) else { return nil }
            return n
        }
        if let n = unit("ovpns", 1...2) { self = .openVPNServer(n) }
        else if let n = unit("ovpn", 1...5) { self = .openVPNClient(n) }
        else if let n = unit("wgc", 1...5) { self = .wireGuardClient(n) }
        else if sectionID == "wgs1" { self = .wireGuardServer }
        else { return nil }
    }
    public var id: String {
        switch self {
        case .openVPNClient(let n): "ovpn\(n)"
        case .openVPNServer(let n): "ovpns\(n)"
        case .wireGuardClient(let n): "wgc\(n)"
        case .wireGuardServer: "wgs1"
        }
    }
    public var title: String {
        switch self {
        case .openVPNClient(let n): "OpenVPN 客户端 \(n)"
        case .openVPNServer(let n): "OpenVPN 服务器 \(n)"
        case .wireGuardClient(let n): "WireGuard 客户端 \(n)"
        case .wireGuardServer: "WireGuard 服务器"
        }
    }
    /// Key fields accepted by validate_instance for vpn_crt_client_/vpn_crt_server_.
    public var keyFields: [OpenVPNKeyField] {
        switch self {
        case .openVPNClient: [.ca, .crt, .key, .staticKey, .crl, .extra]
        case .openVPNServer: [.ca, .crt, .key, .dh, .crl, .staticKey, .extra]
        case .wireGuardClient, .wireGuardServer: []
        }
    }
    var keyPrefix: String? {
        switch self {
        case .openVPNClient(let n): "vpn_crt_client\(n)_"
        case .openVPNServer(let n): "vpn_crt_server\(n)_"
        default: nil
        }
    }
}

public enum OpenVPNKeyField: String, CaseIterable, Sendable, Identifiable {
    case ca, crt, key, staticKey = "static", crl, dh, extra
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .ca: "CA 证书"
        case .crt: "证书"
        case .key: "私钥"
        case .staticKey: "静态密钥（TLS Auth / Crypt）"
        case .crl: "证书吊销列表"
        case .dh: "Diffie-Hellman 参数"
        case .extra: "附加证书链"
        }
    }
    public var isSecret: Bool { self == .key || self == .staticKey }
}

public enum VPNFileImportOutcome: Sendable, Equatable {
    case complete
    case incomplete(state: String)
    case rejected
    case unconfirmed(String)
    public var message: String {
        switch self {
        case .complete: "路由器已解析并保存该配置文件（上传状态已更新为 0）。"
        case .incomplete(let state): "路由器已导入配置，但仍报告缺少证书或密钥（状态位 \(state)）。请在下方证书编辑中补全后再启用。"
        case .rejected: "路由器无法解析该配置文件，已报告导入错误。该实例原有设置可能已被清空，请重新检查。"
        case .unconfirmed(let detail): detail
        }
    }
}

public struct VPNKeyReceipt: Sendable, Equatable {
    public var verified: Bool
    public var message: String
}

public struct WireGuardPeerExport: Sendable {
    public var data: Data
    public var suggestedName: String
    public var note: String
}

public enum VPNFileRules {
    /// get_ovpn_key() reads into char buf[8000]; longer keys cannot be read back intact.
    public static let maxKeyBytes = 7_999
    public static let maxConfigBytes = 1_000_000

    public static func validateKey(_ text: String, field: OpenVPNKeyField) throws {
        guard text.utf8.count <= maxKeyBytes else { throw RouterError.validation("\(field.label)：最多 \(maxKeyBytes) 字节") }
        guard text.unicodeScalars.allSatisfy({ $0 == "\n" || $0 == "\r" || $0 == "\t" || (0x20...0x7E).contains($0.value) }) else {
            throw RouterError.validation("\(field.label)：只能包含 ASCII 文本（PEM 格式）")
        }
        if [.ca, .crt, .crl, .extra, .dh].contains(field), !text.isEmpty, !text.contains("-----BEGIN ") {
            throw RouterError.validation("\(field.label)：请粘贴 PEM 格式内容（以 -----BEGIN 开头）")
        }
    }

    /// Reads a user-chosen configuration as a snapshot, refusing non-regular files and binary data.
    public static func readConfiguration(_ url: URL, wireGuard: Bool) throws -> String { try configurationSnapshot(url, wireGuard: wireGuard).text }
    /// The text for validation plus a hash of the exact bytes. Decoding drops a UTF-8 byte-order mark,
    /// so a hash of the decoded text would never match the uploaded file.
    static func configurationSnapshot(_ url: URL, wireGuard: Bool) throws -> (text: String, sha256: String) {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw RouterError.validation("请选择普通文件") }
        guard let size = values.fileSize, size > 0, size <= maxConfigBytes else { throw RouterError.validation("配置文件为空或超过 1 MB") }
        let ext = url.pathExtension.lowercased()
        guard (wireGuard ? ["conf"] : ["ovpn", "conf"]).contains(ext) else {
            throw RouterError.validation(wireGuard ? "请选择 WireGuard .conf 文件" : "请选择 OpenVPN .ovpn 或 .conf 文件")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= maxConfigBytes, !data.contains(0), let text = String(data: data, encoding: .utf8) else { throw RouterError.validation("配置文件不是文本文件") }
        try validateConfiguration(text, wireGuard: wireGuard)
        return (text, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    static func validateConfiguration(_ text: String, wireGuard: Bool) throws {
        if wireGuard {
            guard text.range(of: #"(?im)^\s*\[Interface\]\s*$"#, options: .regularExpression) != nil,
                  text.range(of: #"(?im)^\s*\[Peer\]\s*$"#, options: .regularExpression) != nil else {
                throw RouterError.validation("WireGuard 配置需要包含 [Interface] 与 [Peer] 段")
            }
        } else {
            guard text.range(of: #"(?im)^\s*remote\s+\S+"#, options: .regularExpression) != nil else {
                throw RouterError.validation("OpenVPN 配置中没有 remote 服务器地址")
            }
        }
    }

    /// Decodes _get_vpn_crt_value() output. That handler writes "&#%d" with no terminating ';'
    /// for non-printable bytes and for `" & < >`; only those codes can follow "&#", so the longest
    /// digit prefix in that set is chosen ("&#101" is "\n" + "1", because 'e' is never escaped).
    /// Signed-char builds print high bytes as negative numbers.
    public static func decodeKeyEntities(_ text: String) throws -> String {
        let escaped = Set(0...31).union([34, 38, 60, 62, 127])
        let input = Array(text.utf8)
        var output: [UInt8] = []; output.reserveCapacity(input.count)
        var i = 0
        while i < input.count {
            guard input[i] == UInt8(ascii: "&") else { output.append(input[i]); i += 1; continue }
            guard i + 1 < input.count, input[i + 1] == UInt8(ascii: "#") else { throw RouterError.invalidResponse("证书内容编码") }
            var j = i + 2
            let negative = j < input.count && input[j] == UInt8(ascii: "-")
            if negative { j += 1 }
            var digits = ""
            while j < input.count, digits.count < 3, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(input[j]) {
                digits.append(Character(UnicodeScalar(input[j]))); j += 1
            }
            var chosen: (byte: UInt8, length: Int)?
            for length in stride(from: digits.count, through: 1, by: -1) {
                guard let value = Int(digits.prefix(length)) else { continue }
                if negative, (1...128).contains(value) { chosen = (UInt8(256 - value), length); break }
                if !negative, escaped.contains(value) { chosen = (UInt8(value), length); break }
            }
            guard let chosen else { throw RouterError.invalidResponse("证书内容编码") }
            output.append(chosen.byte)
            i += 2 + (negative ? 1 : 0) + chosen.length
        }
        guard let decoded = String(bytes: output, encoding: .utf8) else { throw RouterError.invalidResponse("证书内容编码") }
        return decoded
    }

    /// Parses appGet.cgi?hook=vpn_crt_client() / vpn_crt_server(): {"vpn_crt_client":{"<name>":["…"],…,"end":[""]}}.
    /// Only the exact indexed names for the requested unit are accepted; anything else fails closed.
    static func parseKeyMaterial(_ object: [String: Any], instance: VPNInstance) throws -> [OpenVPNKeyField: String] {
        guard let prefix = instance.keyPrefix else { throw RouterError.validation("该实例没有 OpenVPN 证书") }
        let hook = prefix.hasPrefix("vpn_crt_client") ? "vpn_crt_client" : "vpn_crt_server"
        guard let table = object[hook] as? [String: Any] else { throw RouterError.invalidResponse("OpenVPN 证书列表") }
        var result: [OpenVPNKeyField: String] = [:]
        for field in instance.keyFields {
            guard let entry = table[prefix + field.rawValue] as? [Any], let raw = entry.first as? String else {
                throw RouterError.invalidResponse("OpenVPN 证书字段 \(prefix + field.rawValue)")
            }
            result[field] = try decodeKeyEntities(raw)
        }
        return result
    }
}

extension RouterClient {
    // MARK: OpenVPN certificates and keys

    public func vpnKeyMaterial(_ instance: VPNInstance) async throws -> [OpenVPNKeyField: String] {
        guard let prefix = instance.keyPrefix else { throw RouterError.validation("该实例没有 OpenVPN 证书") }
        let hook = prefix.hasPrefix("vpn_crt_client") ? "vpn_crt_client()" : "vpn_crt_server()"
        let data = try await request("appGet.cgi", query: [.init(name: "hook", value: hook)])
        return try VPNFileRules.parseKeyMaterial(try RouterParser.json(data), instance: instance)
    }

    /// Posts the indexed name (vpn_crt_client3_ca). validate_instance() maps it to set_ovpn_key() for
    /// that unit only, so the web-selected unit is never read or changed.
    public func saveVPNKey(_ instance: VPNInstance, field: OpenVPNKeyField, before: String, after: String) async throws -> VPNKeyReceipt {
        try await saveVPNKey(instance, field: field, before: before, after: after, settle: .seconds(3))
    }
    func saveVPNKey(_ instance: VPNInstance, field: OpenVPNKeyField, before: String, after: String, settle: Duration) async throws -> VPNKeyReceipt {
        try acquireMutation(); defer { releaseMutation() }
        guard let prefix = instance.keyPrefix, instance.keyFields.contains(field) else { throw RouterError.validation("该实例不支持此证书字段") }
        guard before != after else { throw RouterError.validation("内容没有变化") }
        try VPNFileRules.validateKey(after, field: field)
        let current = try await vpnKeyMaterial(instance)
        guard current[field] == before else { throw RouterError.validation("证书已被其他操作改变，请重新读取后再保存") }
        var fields = ["action_mode": "apply", prefix + field.rawValue: after]
        let stateKey: String
        let service: String
        switch instance {
        case .openVPNClient(let n): stateKey = "vpn_client\(n)_state"; service = "restart_vpnclient\(n)"
        case .openVPNServer(let n): stateKey = "vpn_server\(n)_state"; service = "restart_vpnserver\(n)"
        default: throw RouterError.validation("该实例没有 OpenVPN 证书")
        }
        let state = try await readSettings([stateKey])
        if ["1", "2"].contains(state[stateKey] ?? "") { fields["rc_service"] = service }
        do { try await submitApply(fields) }
        catch RouterError.submissionUncertain(let message) { return VPNKeyReceipt(verified: false, message: message) }
        do {
            try await Task.sleep(for: settle)
            let readback = try await vpnKeyMaterial(instance)[field] ?? ""
            if readback == after { return VPNKeyReceipt(verified: true, message: "已从路由器重新读取，\(field.label)已确认保存。") }
            func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
            if trimmed(readback) == trimmed(after) { return VPNKeyReceipt(verified: true, message: "已确认保存；路由器调整了首尾空白。") }
            return VPNKeyReceipt(verified: false, message: "路由器已响应，但重新读取的\(field.label)与提交内容不一致。请重新读取并检查。")
        } catch {
            return VPNKeyReceipt(verified: false, message: "路由器已接收请求，但暂时无法重新读取证书。保存结果仍待确认。")
        }
    }

    // MARK: Configuration file import

    /// vpnupload.cgi: do_vpnupload_post stores every pre-file field via nvram_set(), so only the two
    /// fields the firmware form sends are included. do_vpnupload_cgi resets the client unit, parses the
    /// file synchronously and records vpn_upload_state ("err" or a missing-part bitmask); its body is empty.
    public func importOpenVPNClientConfiguration(unit: Int, file: URL) async throws -> VPNFileImportOutcome {
        guard (1...5).contains(unit) else { throw RouterError.validation("OpenVPN 客户端编号无效") }
        return try await importConfiguration(path: "vpnupload.cgi", file: file, wireGuard: false,
                                             fields: ["vpn_upload_type": "ovpn", "vpn_upload_unit": String(unit)],
                                             stateKey: "vpn_upload_state", echo: ["vpn_upload_type": "ovpn", "vpn_upload_unit": String(unit)])
    }

    /// upload_wgc_config.cgi: only wgc_upload_unit is read before the "file" part; the result of
    /// read_wgc_config_file() is stored in wgc_upload_state ("err" or a non-negative code).
    public func importWireGuardClientConfiguration(unit: Int, file: URL) async throws -> VPNFileImportOutcome {
        guard (1...5).contains(unit) else { throw RouterError.validation("WireGuard 客户端编号无效") }
        return try await importConfiguration(path: "upload_wgc_config.cgi", file: file, wireGuard: true,
                                             fields: ["wgc_upload_unit": String(unit)],
                                             stateKey: "wgc_upload_state", echo: ["wgc_upload_unit": String(unit)])
    }

    private func importConfiguration(path: String, file: URL, wireGuard: Bool, fields: [String: String],
                                     stateKey: String, echo: [String: String]) async throws -> VPNFileImportOutcome {
        try acquireMutation(); defer { releaseMutation() }
        let snapshot = try VPNFileRules.configurationSnapshot(file, wireGuard: wireGuard)
        let before = try await readSettings([stateKey])[stateKey] ?? ""
        let multipart = try MultipartUpload.create(file: file, field: "file", fields: fields)
        defer { try? FileManager.default.removeItem(at: multipart.file) }
        // The upload is a snapshot; refuse if the file changed after validation.
        guard multipart.sha256 == snapshot.sha256 else { throw RouterError.validation("配置文件在确认后发生变化，操作已取消") }
        // upload() reports a router it never reached as `.network`; anything after sending is unconfirmed.
        do { _ = try await upload(path, multipart: multipart) { _ in } }
        catch RouterError.submissionUncertain {
            return .unconfirmed("上传过程中连接中断，路由器是否已替换该实例配置尚未确认。请重新读取，不要重复上传。")
        }
        let after: [String: String]
        do { after = try await readSettings([stateKey] + echo.keys.sorted()) }
        catch RouterError.authenticationRequired { throw RouterError.authenticationRequired }
        catch { return .unconfirmed("路由器已接收上传，但无法读取导入状态。请重新读取该实例设置确认。") }
        return Self.importOutcome(before: before, after: after, stateKey: stateKey, echo: echo)
    }

    static func importOutcome(before: String, after: [String: String], stateKey: String, echo: [String: String]) -> VPNFileImportOutcome {
        guard echo.allSatisfy({ after[$0.key] == $0.value }) else {
            return .unconfirmed("路由器记录的上传目标与本次请求不一致（可能有其他会话同时上传）。请重新读取并检查。")
        }
        let state = after[stateKey] ?? ""
        if state == "err" {
            return before == "err" ? .unconfirmed("路由器上传状态在导入前后均为错误，无法确认本次导入结果。请检查文件后重试。") : .rejected
        }
        guard let bits = Int(state), bits >= 0 else { return .unconfirmed("路由器返回了无法识别的导入状态：\(state)") }
        if state == before {
            return .unconfirmed("导入状态与上传前相同（\(state)），无法区分本次结果与旧状态。请重新读取该实例设置确认。")
        }
        return bits == 0 ? .complete : .incomplete(state: state)
    }

    // MARK: WireGuard server peer export

    /// Peers whose wgs1_c{n}_enable is "1". WG_SERVER_CLIENT_MAX is not defined in the supplied
    /// source; 1…10 is probed and each export re-checks the router before downloading.
    public func wireGuardServerPeers() async throws -> [Int] {
        let keys = (1...10).map { "wgs1_c\($0)_enable" }
        let values = try await readSettings(keys)
        return (1...10).filter { values["wgs1_c\($0)_enable"] == "1" }
    }

    /// wgs_client.conf is served from /etc/wg/server{wgs_unit}_client{wgsc_unit}.conf. The units are set
    /// with the firmware's own chg_wgs_unit / chg_wgsc_unit actions, verified before and after the
    /// download, and then restored to the previous selection.
    public func exportWireGuardServerPeer(_ peer: Int) async throws -> WireGuardPeerExport {
        try acquireMutation(); defer { releaseMutation() }
        guard (1...10).contains(peer) else { throw RouterError.validation("WireGuard 客户端编号无效") }
        let enableKey = "wgs1_c\(peer)_enable"
        let previous = try await readSettings([enableKey, "wgs_unit", "wgsc_unit"])
        guard previous[enableKey] == "1" else { throw RouterError.validation("该 WireGuard 客户端未启用，路由器不会生成配置文件") }
        let page = "Advanced_WireguardServer_Content.asp"
        var switched: [(mode: String, key: String, old: String)] = []
        func selectionMatches() async throws -> Bool {
            let now = try await readSettings(["wgs_unit", "wgsc_unit"])
            return now["wgs_unit"] == "1" && now["wgsc_unit"] == String(peer)
        }
        let data: Data
        do {
            for (mode, key, value) in [("chg_wgs_unit", "wgs_unit", "1"), ("chg_wgsc_unit", "wgsc_unit", String(peer))] where previous[key] != value {
                switched.append((mode, key, previous[key] ?? ""))
                _ = try await sendNativeAction(["action_mode": mode, key: value, "current_page": page])
            }
            guard try await selectionMatches() else { throw RouterError.validation("路由器未切换到所选 WireGuard 客户端，已取消导出") }
            data = try await request("wgs_client.conf", timeout: 30)
            guard try await selectionMatches() else { throw RouterError.validation("导出期间路由器所选客户端被其他会话改变，已丢弃下载内容") }
        } catch {
            _ = await restoreSelection(switched, page: page)
            throw error
        }
        let restored = await restoreSelection(switched, page: page)
        let text = String(decoding: data, as: UTF8.self)
        guard !data.isEmpty, data.count < 64_000, !text.lowercased().contains("<html") else {
            throw RouterError.invalidResponse("WireGuard 客户端配置（路由器未生成该文件）")
        }
        try VPNFileRules.validateConfiguration(text, wireGuard: true)
        let note = switched.isEmpty ? "" : (restored ? "已请求恢复原来的客户端选择。" : "配置已导出，但原来的客户端选择状态尚未恢复。")
        return WireGuardPeerExport(data: data, suggestedName: "wgs1_client\(peer).conf", note: note)
    }

    private func restoreSelection(_ switched: [(mode: String, key: String, old: String)], page: String) async -> Bool {
        var ok = true
        for item in switched.reversed() {
            guard let value = Int(item.old), value >= 1 else { continue }
            do { _ = try await sendNativeAction(["action_mode": item.mode, item.key: String(value), "current_page": page]) }
            catch { ok = false }
        }
        return ok
    }
}

extension RouterClient {
    /// Actual RT-BE88U page generates client<vpn_server_unit>.ovpn, so the unit is in the filename.
    /// No web-selected server is modified. A running server must have generated the export first.
    public func exportOpenVPNServerConfiguration(unit: Int) async throws -> Data {
        guard (1...2).contains(unit) else { throw RouterError.validation("OpenVPN 服务器编号无效") }
        let stateKey = "vpn_server\(unit)_state"
        let before = try await readSettings([stateKey])
        guard before[stateKey] == "2" else { throw RouterError.validation("请先启动该 OpenVPN 服务器并等待初始化完成，再导出客户端配置") }
        let data = try await request("client\(unit).ovpn", timeout: 30)
        guard data.count > 10, data.count <= VPNFileRules.maxConfigBytes, let text = String(data: data, encoding: .utf8), !text.lowercased().contains("<html") else { throw RouterError.invalidResponse("OpenVPN 客户端配置") }
        try VPNFileRules.validateConfiguration(text, wireGuard: false)
        return data
    }
}

extension RouterClient {
    public func openVPNStartupList(_ instance: VPNInstance) async throws -> String {
        let key: String
        switch instance { case .openVPNClient: key = "vpn_clientx_eas"; case .openVPNServer: key = "vpn_serverx_start"; default: throw RouterError.validation("此项目只适用于 OpenVPN") }
        return try await readSettings([key])[key] ?? ""
    }
    public func setOpenVPNStartup(_ instance: VPNInstance, before: String, enabled: Bool) async throws -> Bool {
        try acquireMutation(); defer { releaseMutation() }
        let key: String, unit: Int, maximum: Int
        switch instance {
        case .openVPNClient(let n): key = "vpn_clientx_eas"; unit = n; maximum = 5
        case .openVPNServer(let n): key = "vpn_serverx_start"; unit = n; maximum = 2
        default: throw RouterError.validation("此项目只适用于 OpenVPN")
        }
        guard (1...maximum).contains(unit) else { throw RouterError.validation("VPN 实例编号无效") }
        let current = try await readSettings([key])[key] ?? ""
        guard current == before else { throw RouterError.validation("自动启动设置已改变，请重新读取") }
        let pieces = current.split(separator: ",").map(String.init)
        guard pieces.allSatisfy({ Int($0).map { (1...maximum).contains($0) } ?? false }) else { throw RouterError.validation("自动启动列表格式尚未适配") }
        var units = Set(pieces.compactMap(Int.init)); if enabled { units.insert(unit) } else { units.remove(unit) }
        let value = units.sorted().map(String.init).joined(separator: ",") + (units.isEmpty ? "" : ",")
        _ = try await submitApply(["action_mode":"apply", key:value])
        return try await readSettings([key])[key] == value
    }
}
