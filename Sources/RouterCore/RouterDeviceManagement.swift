import Foundation

public enum DeviceConfiguration {
    static func isMAC(_ value: String) -> Bool { value.range(of: #"^(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$"#, options: .regularExpression) != nil }
    public static func renamed(_ source: String, mac: String, name: String) throws -> String {
        guard isMAC(mac), (1...32).contains(name.utf8.count), !name.contains("<"), !name.contains(">"), !name.containsLineBreak else { throw RouterError.validation("设备名称应为 1–32 字节，且不包含分隔符或换行") }
        var table = try LosslessRuleTable(source, minimumColumns: 4)
        if let index = table.rows.firstIndex(where: { $0[1].caseInsensitiveCompare(mac) == .orderedSame }) { table.rows[index][0] = name }
        else { table.rows.append([name, mac.uppercased(), "0", "0", "", ""]) }
        return table.encoded
    }
    /// The parental-control label only identifies a rule. Its lists are ">"-separated and the router UI keeps
    /// names to 32 bytes, so an unusual or long device name is shortened instead of blocking the pause.
    public static func ruleLabel(_ name: String, mac: String) -> String {
        let removed = CharacterSet(charactersIn: "<>").union(.newlines).union(.controlCharacters)
        var label = String(name.unicodeScalars.filter { !removed.contains($0) }).trimmingCharacters(in: .whitespaces)
        while label.utf8.count > 32 { label.removeLast() }
        return label.isEmpty ? mac.uppercased() : label
    }
}
/// `priorState` is the rule's MULTIFILTER_ENABLE value before the change ("0" off, "1" time schedule,
/// "2" blocked), or nil when the device had no rule. RouterBar keeps it so resuming can restore a schedule.
public struct InternetPauseReceipt: Sendable {
    public var receipt: ApplyReceipt
    public var priorState: String?
}
extension RouterClient {
    public func uiCapabilities() async throws -> [String: String] {
        let data = try await request("appGet.cgi", query: [.init(name: "hook", value: "get_ui_support()")])
        let json = try RouterParser.json(data)
        guard let support = json["get_ui_support"] as? [String: Any] else { throw RouterError.invalidResponse("固件功能列表") }
        return support.compactMapValues { value in if let string = value as? String { return string }; if let number = value as? NSNumber { return number.stringValue }; return nil }
    }
    public func renameDevice(mac: String, name: String) async throws -> ApplyReceipt {
        try acquireMutation(); defer { releaseMutation() }
        let current = try await readSettings(["custom_clientlist"])
        let updated = try DeviceConfiguration.renamed(current["custom_clientlist"] ?? "", mac: mac, name: name)
        _ = try await submitApply(["action_mode": "apply", "custom_clientlist": updated])
        let after = try await readSettings(["custom_clientlist"])
        let success = after["custom_clientlist"] == updated
        return ApplyReceipt(verified: success ? ["custom_clientlist"] : [], unverified: success ? [] : ["custom_clientlist"], message: success ? "已从路由器确认设备名称更新。" : "设备名称保存结果尚未确认。")
    }
    /// Resuming only lifts a pause: it restores `resumeState` ("0" off or "1" schedule) and leaves a rule that is
    /// not currently blocking untouched.
    public func setInternetPaused(mac: String, name: String, paused: Bool, resumeState: String = "0") async throws -> InternetPauseReceipt {
        try acquireMutation(); defer { releaseMutation() }
        guard DeviceConfiguration.isMAC(mac), ["0", "1"].contains(resumeState) else { throw RouterError.validation("设备地址或恢复状态无效") }
        let support = try await uiCapabilities()
        let schedule = support["PC_SCHED_V3"] == "1" ? "MULTIFILTER_MACFILTER_DAYTIME_V2" : "MULTIFILTER_MACFILTER_DAYTIME"
        let keys = ["MULTIFILTER_ALL", "MULTIFILTER_MAC", "MULTIFILTER_ENABLE", "MULTIFILTER_DEVICENAME", schedule]
        let current = try await readSettings(keys)
        func list(_ key: String) -> [String] { let v = current[key] ?? ""; return v.isEmpty ? [] : v.components(separatedBy: ">") }
        var macs = list("MULTIFILTER_MAC"), enabled = list("MULTIFILTER_ENABLE"), names = list("MULTIFILTER_DEVICENAME"), schedules = list(schedule)
        guard macs.count == enabled.count, macs.count == names.count, macs.count == schedules.count else { throw RouterError.validation("现有家长控制规则格式不同，已保留原有设置") }
        if paused, current["MULTIFILTER_ALL"] != "1", enabled.contains(where: { $0 != "0" }) { throw RouterError.validation("当前家长控制总开关关闭。启用会同时恢复已有规则，请先核对家长控制设置。") }
        let index = macs.firstIndex(where: { $0.caseInsensitiveCompare(mac) == .orderedSame })
        let prior = index.map { enabled[$0] }
        func unchanged(_ message: String) -> InternetPauseReceipt { InternetPauseReceipt(receipt: ApplyReceipt(verified: [], unverified: [], message: message), priorState: prior) }
        if let index {
            if paused {
                guard enabled[index] != "2" else { return unchanged("此设备已处于暂停上网状态。") }
                enabled[index] = "2"
            } else {
                guard enabled[index] == "2" else { return unchanged("此设备当前没有被暂停上网，未作修改。") }
                enabled[index] = resumeState
            }
        } else if paused {
            guard macs.count < 64 else { throw RouterError.validation("家长控制设备数量已达上限") }
            macs.append(mac.uppercased()); names.append(DeviceConfiguration.ruleLabel(name, mac: mac)); enabled.append("2"); schedules.append(schedule.hasSuffix("_V2") ? "W03E21000700<W04122000800" : "<")
        } else { return unchanged("此设备没有暂停规则。") }
        var fields = ["action_mode": "apply", "rc_service": "restart_firewall", "MULTIFILTER_MAC": macs.joined(separator: ">"), "MULTIFILTER_ENABLE": enabled.joined(separator: ">"), "MULTIFILTER_DEVICENAME": names.joined(separator: ">"), schedule: schedules.joined(separator: ">")]
        if paused { fields["MULTIFILTER_ALL"] = "1" }
        _ = try await submitApply(fields)
        try await Task.sleep(for: .seconds(2))
        let result = try await readSettings(keys)
        let changes = fields.filter { keys.contains($0.key) }
        let verified = changes.keys.filter { changes[$0] == result[$0] }
        let missing = changes.keys.filter { changes[$0] != result[$0] }
        let done = paused ? "暂停" : resumeState == "1" ? "恢复（并还原原有的上网时间表）" : "恢复"
        return InternetPauseReceipt(receipt: ApplyReceipt(verified: verified, unverified: missing, message: missing.isEmpty ? "已从路由器确认\(done)此设备的互联网访问规则。" : "路由器已响应，访问规则尚未确认一致。"), priorState: prior)
    }
}
