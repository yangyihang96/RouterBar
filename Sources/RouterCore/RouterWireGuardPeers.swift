import Foundation
import Darwin

public struct WireGuardPeer: Sendable, Equatable, Identifiable {
    public let unit: Int
    public var enabled: Bool
    public var name: String
    public var address: String
    public var serverAllowedIPs: String
    public var clientAllowedIPs: String
    public var id: Int { unit }
    var prefix: String { "wgs1_c\(unit)_" }
    var fields: [String: String] { [prefix + "enable":enabled ? "1":"0", prefix + "name":name, prefix + "addr":address, prefix + "aips":serverAllowedIPs, prefix + "caips":clientAllowedIPs] }
}
public enum IPRangeValidation {
    public static func validate(_ value: String) throws {
        let ranges = value.split(separator: ",", omittingEmptySubsequences: false)
        guard !ranges.isEmpty, ranges.count <= 64 else { throw RouterError.validation("请填写有效的 IP 地址范围") }
        for raw in ranges {
            let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: "/", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count) else { throw RouterError.validation("IP 地址范围格式错误") }
            var v4 = in_addr(), v6 = in6_addr()
            let maxBits: Int
            if inet_pton(AF_INET, String(parts[0]), &v4) == 1 { maxBits = 32 }
            else if inet_pton(AF_INET6, String(parts[0]), &v6) == 1 { maxBits = 128 }
            else { throw RouterError.validation("请输入有效的 IPv4 或 IPv6 地址") }
            if parts.count == 2 { guard let bits = Int(parts[1]), (0...maxBits).contains(bits) else { throw RouterError.validation("子网前缀长度无效") } }
        }
    }
}
extension RouterClient {
    public func wireGuardPeerConfigurations() async throws -> [WireGuardPeer] {
        let suffixes = ["enable","name","addr","aips","caips"]
        let values = try await readSettings((1...10).flatMap { n in suffixes.map { "wgs1_c\(n)_" + $0 } })
        return (1...10).map { n in
            let prefix = "wgs1_c\(n)_"
            return WireGuardPeer(unit: n, enabled: values[prefix + "enable"] == "1", name: values[prefix + "name"] ?? "", address: values[prefix + "addr"] ?? "", serverAllowedIPs: values[prefix + "aips"] ?? "", clientAllowedIPs: values[prefix + "caips"] ?? "")
        }
    }
    public func saveWireGuardPeer(before: WireGuardPeer, after: WireGuardPeer) async throws -> ApplyReceipt {
        try acquireMutation(); defer { releaseMutation() }
        guard before.unit == after.unit, (1...10).contains(after.unit), before != after else { throw RouterError.validation("客户端没有有效的修改") }
        guard after.name.utf8.count <= 32, !after.name.containsLineBreak, !after.name.contains("<"), !after.name.contains(">") else { throw RouterError.validation("客户端名称格式无效") }
        if after.enabled {
            try IPRangeValidation.validate(after.address)
            try IPRangeValidation.validate(after.serverAllowedIPs)
            try IPRangeValidation.validate(after.clientAllowedIPs)
        }
        let current = try await readSettings(Array(before.fields.keys))
        // An unconfigured slot uses empty values; normalize only the enable flag for its comparison.
        for (key, value) in before.fields {
            let actual = key.hasSuffix("_enable") && current[key] == "" ? "0" : current[key]
            guard actual == value else { throw RouterError.validation("客户端配置已被其他操作改变，请重新读取") }
        }
        var fields = Dictionary(uniqueKeysWithValues: after.fields.map { ($0.key.replacingOccurrences(of: after.prefix, with: "wgsc_"), $0.value) })
        fields["wgs_unit"] = "1"; fields["wgsc_unit"] = String(after.unit); fields["action_mode"] = "apply"; fields["rc_service"] = "restart_wgs;restart_dnsmasq"
        do { _ = try await submitApply(fields) }
        catch RouterError.submissionUncertain(let reason) { return ApplyReceipt(verified: [], unverified: Array(after.fields.keys), message: reason) }
        do {
            try await Task.sleep(for: .seconds(3))
            let readback = try await readSettings(Array(after.fields.keys))
            let verified = after.fields.keys.filter { readback[$0] == after.fields[$0] }
            let pending = after.fields.keys.filter { readback[$0] != after.fields[$0] }
            return ApplyReceipt(verified: verified, unverified: pending, message: pending.isEmpty ? "已从路由器确认客户端配置保存。开启服务器后可导出连接配置。" : "客户端配置已提交，部分值尚未确认。")
        } catch { return ApplyReceipt(verified: [], unverified: Array(after.fields.keys), message: "客户端配置已提交，请等待服务器恢复后重新读取。") }
    }
}
