import Foundation
import Darwin

public struct SettingOption: Codable, Sendable, Hashable, Identifiable {
    public var value: String
    public var label: String
    public var id: String { value }
}
public struct SettingField: Codable, Sendable, Identifiable, Hashable {
    public var key: String
    public var label: String
    public var kind: String
    public var options: [SettingOption] = []
    public var maxLength: Int? = nil
    public var minimum: Int? = nil
    public var maximum: Int? = nil
    public var columns: [String] = []
    public var note: String? = nil
    /// The firmware's rangeAllowZero: 0 (usually "off") is accepted besides minimum...maximum.
    public var allowsZero: Bool? = nil
    public var pattern: String? = nil
    /// Set when the router keeps this value inside a list variable instead of under its own name.
    public var packed: PackedSetting? = nil
    public static func rules(key: String, label: String, columns: [String]) -> SettingField {
        SettingField(key: key, label: label, kind: "rules", columns: columns)
    }
    public var id: String { key }
    /// What the web sends for `value`: validator.range turns an accepted integer into its digits without leading
    /// zeros, and an empty one into "0" (validator.js str2val).
    public func submitted(_ value: String) -> String {
        guard kind == "integer", value.allSatisfy(\.isASCII) else { return value }
        let negative = value.hasPrefix("-")
        let digits = negative ? String(value.dropFirst()) : value
        guard digits.allSatisfy(\.isNumber) else { return value }
        let trimmed = String(digits.drop { $0 == "0" })
        return trimmed.isEmpty ? "0" : (negative ? "-" : "") + trimmed
    }
    /// The nvram variable that holds the value on the router.
    public var storageKey: String { packed?.key ?? key }
    public var isSecret: Bool { kind == "secret" || kind == "secretText" }
    /// The accepted integers as the firmware page states them, e.g. "0 或 10–999".
    public var rangeText: String? {
        guard kind == "integer", let minimum, let maximum else { return nil }
        return (allowsZero == true ? "0 或 " : "") + "\(minimum)–\(maximum)"
    }
    public func validate(_ value: String) throws {
        func invalid(_ detail: String) -> RouterError { .validation("\(label)：\(detail)") }
        guard !value.contains("\u{0}"), value.utf8.count <= 60_000 else { throw invalid("内容过长或包含无效字符") }
        if kind == "readonly" { throw invalid("此项只能在路由器网页中修改") }
        if kind == "timeZone", RouterTimeZones.zone(value) == nil { throw invalid("请从列表中选择时区") }
        if kind == "dstRule" {
            guard let rule = DaylightSavingRule(value) else { throw invalid("格式应为 Mm.w.d/h,Mm.w.d/h") }
            if rule.overlaps { throw invalid("指定的时段不可重叠") }
        }
        if let maxLength, value.utf8.count > maxLength { throw invalid("最多 \(maxLength) 字节") }
        if !options.isEmpty, !options.contains(where: { $0.value == value }) { throw invalid("请选择支持的选项") }
        // validator.range reads an empty field as 0 (Number("") is 0): it passes only where 0 does, and is sent as "0".
        if kind == "integer" {
            guard let n = value.isEmpty ? 0 : Int(value), (allowsZero == true && n == 0) || (n >= (minimum ?? 0) && n <= (maximum ?? Int.max)) else {
                throw invalid(rangeText.map { "请输入 \($0) 之间的整数" } ?? "请输入允许范围内的整数")
            }
        }
        if kind == "ipv4", !value.isEmpty, !Self.isIPv4(value) { throw invalid("请输入有效的 IPv4 地址") }
        if kind == "ipv6", !value.isEmpty, !Self.isIPv6(value) { throw invalid("请输入有效的 IPv6 地址") }
        if kind == "ip", !value.isEmpty, !Self.isIPv4(value), !Self.isIPv6(value) { throw invalid("请输入有效的 IPv4 或 IPv6 地址") }
        if kind == "host", !value.isEmpty, !Self.isIPv4(value), !Self.isIPv6(value), !Self.isHostname(value) { throw invalid("请输入有效的 IP 地址或主机名") }
        // minimum and maximum bound the prefix length, e.g. /16–/29 for the OpenVPN server subnet.
        if kind == "netmask", !value.isEmpty {
            guard let length = Self.prefixLength(ofMask: value), length >= (minimum ?? 0), length <= (maximum ?? 32) else {
                throw invalid(minimum == nil && maximum == nil ? "请输入连续的子网掩码，例如 255.255.255.0" : "请输入 /\(minimum ?? 0) 到 /\(maximum ?? 32) 之间的连续子网掩码")
            }
        }
        if kind == "ipv6Prefix", !value.isEmpty {
            let parts = value.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, Self.isIPv6(String(parts[0])), let length = Int(parts[1]), (0...128).contains(length) else { throw invalid("请输入有效的 IPv6 前缀，例如 2001:db8::/64") }
        }
        if let pattern, !value.isEmpty, value.range(of: pattern, options: .regularExpression) == nil { throw invalid("格式与路由器要求不符") }
        if kind == "mac", !value.isEmpty, value.range(of: #"^(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$"#, options: .regularExpression) == nil { throw invalid("请输入有效的 MAC 地址") }
        if !["multiline", "secretText"].contains(kind), value.containsLineBreak { throw invalid("请勿输入换行符") }
        if key.hasSuffix("_wpa_psk"), !value.isEmpty {
            let hex = value.range(of: #"^[0-9A-Fa-f]{64}$"#, options: .regularExpression) != nil
            guard hex || WirelessSecurityRules.isPassphrase(value) else { throw invalid("无线密码需为 8–63 个 ASCII 字符（首尾不能是空格或双引号），或 64 位十六进制密钥") }
        }
        if key.hasSuffix("_ssid"), value.isEmpty { throw invalid("网络名称不能为空") }
        if kind == "rules" {
            let rows = try RouterRuleCodec.decode(value, columns: columns.count)
            _ = try RouterRuleCodec.encode(rows, columns: columns.count)
            do { try RouterRuleCodec.validateRows(rows, key: key) } catch RouterError.validation(let detail) { throw invalid(detail) }
        }
    }
    static func isIPv4(_ value: String) -> Bool { var address = in_addr(); return inet_pton(AF_INET, value, &address) == 1 }
    static func isIPv6(_ value: String) -> Bool { var address = in6_addr(); return inet_pton(AF_INET6, value, &address) == 1 }
    /// validator.js domainName also accepts underscores inside a label.
    static func isHostname(_ value: String) -> Bool {
        value.utf8.count <= 253 && value.range(of: #"^[A-Za-z0-9](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9])?)*\.?$"#, options: .regularExpression) != nil
    }
    /// The prefix length of a contiguous IPv4 mask (0.0.0.0 is /0), or nil for anything else.
    static func prefixLength(ofMask value: String) -> Int? {
        var address = in_addr()
        guard inet_pton(AF_INET, value, &address) == 1 else { return nil }
        let mask = UInt32(bigEndian: address.s_addr), length = mask.nonzeroBitCount
        return mask == UInt32.max << (32 - length) ? length : nil
    }
}
/// One position of a space-separated list variable. Tools_OtherSettings.asp shows the conntrack timeouts as separate
/// inputs but saves them joined in ct_tcp_timeout ("0 est syn_sent … last_ack 0") and ct_udp_timeout ("unreplied assured").
public struct PackedSetting: Codable, Sendable, Hashable {
    public var key: String
    public var index: Int
    public var count: Int
}
enum SettingPacking {
    /// Values by field key. A list without the expected number of positions reads as empty: it can be shown but not saved.
    static func unpack(_ fields: [SettingField], stored: [String: String]) -> [String: String] {
        var values: [String: String] = [:]
        for field in fields {
            guard let packed = field.packed else { values[field.key] = stored[field.key]; continue }
            guard let list = stored[packed.key] else { continue }
            let parts = positions(list)
            values[field.key] = parts.count == packed.count ? parts[packed.index] : ""
        }
        return values
    }
    /// The list variables with the changed positions replaced; every other position keeps the router's value.
    static func pack(_ changes: [SettingChange], stored: [String: String]) throws -> [String: String] {
        var lists: [String: [String]] = [:]
        for change in changes {
            guard let packed = change.field.packed else { continue }
            var parts = lists[packed.key] ?? positions(stored[packed.key] ?? "")
            guard parts.count == packed.count, parts.indices.contains(packed.index) else {
                throw RouterError.validation("路由器保存的 \(packed.key) 格式与预期不同，暂不能修改“\(change.field.label)”。请在路由器网页中检查。")
            }
            guard !change.after.isEmpty, !change.after.contains(where: \.isWhitespace) else { throw RouterError.validation("\(change.field.label)：不能为空或包含空格") }
            parts[packed.index] = change.after
            lists[packed.key] = parts
        }
        return lists.mapValues { $0.joined(separator: " ") }
    }
    private static func positions(_ list: String) -> [String] { list.split(whereSeparator: \.isWhitespace).map(String.init) }
}
public struct SettingSection: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var category: String
    public var symbol: String
    public var subtitle: String
    public var source: String
    public var service: String
    public var wait: Int
    public var impact: String
    public var fields: [SettingField]
}
public enum SettingsCatalog {
    public static let sections: [SettingSection] = {
        guard let file = Bundle.module.url(forResource: "SettingsCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: file), let sections = try? JSONDecoder().decode([SettingSection].self, from: data) else { return [] }
        return sections
    }()
}

public enum RouterRuleCodec {
    public static func decode(_ value: String, columns: Int) throws -> [[String]] {
        guard !value.isEmpty else { return [] }
        guard value.first == "<", columns > 0 else { throw RouterError.invalidResponse("规则格式；已保留原始设置") }
        return try value.dropFirst().components(separatedBy: "<").map {
            let row = $0.components(separatedBy: ">")
            guard row.count == columns else { throw RouterError.invalidResponse("规则列数与当前固件不同；已保留原始设置") }
            return row
        }
    }
    public static func encode(_ rows: [[String]], columns: Int) throws -> String {
        guard rows.count <= 256 else { throw RouterError.invalidResponse("规则数量过多") }
        return try rows.map { row in
            guard row.count == columns, row.allSatisfy({ !$0.contains("<") && !$0.contains(">") && !$0.containsLineBreak }) else { throw RouterError.invalidResponse("规则内容不能包含分隔符或换行") }
            return "<" + row.joined(separator: ">")
        }.joined()
    }
}

extension RouterRuleCodec {
    /// Row rules the router's own pages enforce before they save a list.
    static func validateRows(_ rows: [[String]], key: String) throws {
        if let index = rows.firstIndex(where: { $0.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }) {
            throw RouterError.validation("第 \(index + 1) 条规则是空的，请填写或删除")
        }
        if key == "vpndirector_rulelist" { try validateVPNDirector(rows) }
    }
    /// Advanced_VPNDirector.asp: enable 0/1, a description of up to 32 characters without < > ' %, local and remote
    /// either empty or IPv4 with an optional /0–32 (validator.ipv4cidr), a listed interface, at most 200 rules and
    /// 7999 characters in total.
    static func validateVPNDirector(_ rows: [[String]]) throws {
        let interfaces = ["WAN"] + (1...5).map { "OVPN\($0)" } + (1...5).map { "WGC\($0)" }
        guard rows.count <= 200 else { throw RouterError.validation("VPN Director 最多 200 条规则") }
        for (index, row) in rows.enumerated() {
            let number = index + 1
            guard ["0", "1"].contains(row[0]) else { throw RouterError.validation("第 \(number) 条规则的启用列只能填 0 或 1") }
            guard row[1].utf16.count <= 32, !row[1].contains(where: { "<>'%".contains($0) }) else {
                throw RouterError.validation("第 \(number) 条规则的说明最多 32 个字符，且不能包含 < > ' %")
            }
            for (column, name) in [(2, "本地"), (3, "远程")] where !row[column].isEmpty && !isIPv4CIDR(row[column]) {
                throw RouterError.validation("第 \(number) 条规则的\(name) IP 需为 IPv4 地址，可带 /0–32 子网，例如 192.168.50.20 或 10.0.0.0/24")
            }
            guard interfaces.contains(row[4]) else { throw RouterError.validation("第 \(number) 条规则的接口需为 WAN、OVPN1–OVPN5 或 WGC1–WGC5") }
        }
        guard try encode(rows, columns: 5).count <= 7999 else { throw RouterError.validation("规则总长度超过路由器上限 7999 个字符，请删减规则或缩短说明") }
    }
    static func isIPv4CIDR(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), SettingField.isIPv4(String(parts[0])) else { return false }
        return parts.count == 1 || parts[1].range(of: #"^(?:[0-9]|[12][0-9]|3[0-2])$"#, options: .regularExpression) != nil
    }
}

/// Combinations the Wi-Fi standards rule out: WPA2 has no GCMP-256, WPA3 has no TKIP, and a WPA2/WPA3 network
/// keeps a cipher WPA2 devices can use.
public enum WirelessSecurityRules {
    /// validator.psk: 8–63 printable ASCII characters that neither start nor end with a space or a double quote.
    static func isPassphrase(_ value: String) -> Bool {
        (8...63).contains(value.utf8.count) && value.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) }
            && !value.hasPrefix(" ") && !value.hasSuffix(" ") && !value.hasPrefix("\"") && !value.hasSuffix("\"")
    }
    static func validate(auth: String, crypto: String, key: String) throws {
        guard !["open", "owe"].contains(auth) else { return }
        if crypto.contains("gcmp256"), auth == "psk2" || (auth == "psk2sae" && !crypto.contains("aes")) {
            throw RouterError.validation("WPA2 设备不支持 GCMP-256，请选择 AES，或改用 WPA3-Personal")
        }
        if crypto.contains("tkip"), auth.contains("sae") { throw RouterError.validation("WPA3 不允许 TKIP 加密，请选择 AES") }
        // Enterprise modes authenticate through RADIUS and carry no passphrase.
        let personal = ["psk", "psk2", "sae", "pskpsk2", "psk2sae"].contains(auth)
        guard !personal || !key.isEmpty else { throw RouterError.validation("所选安全方式需要设置无线密码") }
    }

    // MARK: 无线网络 一般设置, per band (Advanced_Wireless_Content.asp and js/asus.js of 3.0.0.6)

    /// What decides one band's security choices on the page.
    public struct BandContext: Sendable, Equatable {
        /// A 6 GHz radio.
        public var sixGHz: Bool
        /// asus.js beSupport: the router supports Wi-Fi 7 (`isSupport("wifi7")`).
        public var wifi7Router: Bool
        /// asus.js wifi7ModeEnabled: the band's Wi-Fi 7 mode is on (`wlN_11be` is 1).
        public var wifi7Mode: Bool
        public init(sixGHz: Bool, wifi7Router: Bool, wifi7Mode: Bool) {
            self.sixGHz = sixGHz; self.wifi7Router = wifi7Router; self.wifi7Mode = wifi7Mode
        }
    }
    /// The radio unit of a band section: "wifi1", or "wifi2@6 GHz" beyond the reference catalog.
    public static func unit(ofSection id: String) -> Int? {
        guard id.hasPrefix("wifi") else { return nil }
        return Int(id.dropFirst(4).prefix(while: \.isNumber))
    }
    /// Values the page reads besides the section's own fields: the band's Wi-Fi 7 mode.
    public static func contextKeys(sectionID id: String) -> [String] { unit(ofSection: id).map { ["wl\($0)_11be"] } ?? [] }

    /// asus.js authMethod: Enhanced Open only on Wi-Fi 7 routers; a 6 GHz radio offers WPA3 only.
    public static func allowsAuth(_ auth: String, _ context: BandContext) -> Bool {
        if auth == "owe" { return context.wifi7Router }
        if context.sixGHz { return ["sae", "wpa3", "suite-b"].contains(auth) }
        return true
    }
    /// wpaEncryptHandler: the encryption choices for an auth, in page order; nil where the page hides the row.
    /// With Wi-Fi 7 mode on, WPA3-Personal and WPA2/WPA3-Personal use AES + GCMP-256 only.
    public static func cryptoChoices(auth: String, wifi7Mode: Bool) -> [String]? {
        let shown = ["openowe", "owe", "psk", "psk2", "sae", "pskpsk2", "psk2sae", "wpa", "wpa2", "wpa3", "suite-b", "wpawpa2", "wpa2wpa3"]
        guard shown.contains(auth) else { return nil }
        var choices = ["tkip", "aes", "aes+gcmp256", "tkip+aes", "suite-b"]
        if auth != "psk", auth != "wpa" { choices.removeAll { $0 == "tkip" } }
        if auth != "pskpsk2", auth != "wpawpa2" { choices.removeAll { $0 == "tkip+aes" } }
        if auth != "suite-b" { choices.removeAll { $0 == "suite-b" } } else { choices.removeAll { $0 == "aes" } }
        if !wifi7Mode || !auth.contains("sae") { choices.removeAll { $0 == "aes+gcmp256" } } else { choices.removeAll { $0 == "aes" } }
        return choices
    }
    /// mfpHandler: the protected management frame choices for an auth; nil where the page hides the row.
    /// WPA3 and Enhanced Open require it, WPA2/WPA3 offers optional or required, WPA/WPA2 never requires it.
    public static func mfpChoices(auth: String) -> [String]? {
        let shown = ["openowe", "owe", "psk2", "sae", "pskpsk2", "psk2sae", "wpa2", "wpa3", "suite-b", "wpawpa2", "wpa2wpa3"]
        guard shown.contains(auth) else { return nil }
        if ["openowe", "owe", "sae", "wpa3", "suite-b"].contains(auth) { return ["2"] }
        if ["psk2sae", "wpa2wpa3"].contains(auth) { return ["1", "2"] }
        if ["pskpsk2", "wpawpa2"].contains(auth) { return ["0", "1"] }
        return ["0", "1", "2"]
    }
    /// The options the page shows for a field of a band section, given the band's other values; nil where it hides
    /// the row.
    public static func options(for field: SettingField, values: [String: String], unit: Int, context: BandContext) -> [SettingOption]? {
        let auth = values["wl\(unit)_auth_mode_x"] ?? ""
        switch field.key {
        case "wl\(unit)_auth_mode_x":
            return field.options.filter { allowsAuth($0.value, context) }
        case "wl\(unit)_crypto":
            // Only what the section can also save: a choice outside it (TKIP for WPA-Personal, Suite B) is not offered.
            return cryptoChoices(auth: auth, wifi7Mode: context.wifi7Mode).map { choices in
                choices.compactMap { value in field.options.first { $0.value == value } }
            }
        case "wl\(unit)_mfp":
            return mfpChoices(auth: auth).map { choices in field.options.filter { choices.contains($0.value) } }
        default:
            return field.options
        }
    }
    /// The field as the page shows it for the band's current values: nil where the page hides the row, otherwise with
    /// only the choices the section can save, and read-only where none of the page's choices can be saved here (Suite B).
    public static func shownField(_ field: SettingField, values: [String: String], unit: Int, context: BandContext) -> SettingField? {
        guard let options = options(for: field, values: values, unit: unit, context: context) else { return nil }
        var shown = field
        if options.isEmpty, !field.options.isEmpty {
            shown.kind = "readonly"
            shown.note = "当前的安全方式在 App 里没有可保存的选项，这里只显示当前值；可先改用 App 提供的认证方式，或在路由器网页中修改。"
        } else {
            shown.options = options
        }
        return shown
    }
    /// After the auth changes the page renders the choices again, and a value it no longer offers becomes the first
    /// one it does (of those the section can save).
    public static func adjusted(_ values: [String: String], section: SettingSection, context: BandContext) -> [String: String] {
        guard let unit = unit(ofSection: section.id) else { return values }
        var values = values
        for key in ["wl\(unit)_crypto", "wl\(unit)_mfp"] {
            guard let field = section.fields.first(where: { $0.key == key }), let current = values[key],
                  let choices = options(for: field, values: values, unit: unit, context: context)?.map(\.value),
                  let first = choices.first, !choices.contains(current) else { continue }
            values[key] = first
        }
        return values
    }
    /// The band's security as it will be after the save, as the page would allow it.
    static func validateBand(_ values: [String: String], unit: Int, context: BandContext) throws {
        let auth = values["wl\(unit)_auth_mode_x"] ?? ""
        guard allowsAuth(auth, context) else {
            if context.sixGHz { throw RouterError.validation("6 GHz 只能使用 WPA3-Personal" + (context.wifi7Router ? " 或 Enhanced Open（OWE）" : "") + "。") }
            throw RouterError.validation("这台路由器的网页不提供 Enhanced Open（OWE）。")
        }
        if let choices = cryptoChoices(auth: auth, wifi7Mode: context.wifi7Mode), !choices.contains(values["wl\(unit)_crypto"] ?? "") {
            throw RouterError.validation("这一安全方式的加密方式只能是 " + choices.map(cryptoTitle).joined(separator: "、") + (context.wifi7Mode && auth.contains("sae") ? "（Wi-Fi 7 模式已开启）" : "") + "。")
        }
        if let choices = mfpChoices(auth: auth), !choices.contains(values["wl\(unit)_mfp"] ?? "") {
            throw RouterError.validation("这一安全方式的受保护的管理帧只能是 " + choices.map(mfpTitle).joined(separator: "、") + "。")
        }
        let personal = ["psk", "psk2", "sae", "pskpsk2", "psk2sae"].contains(auth)
        guard !personal || !(values["wl\(unit)_wpa_psk"] ?? "").isEmpty else { throw RouterError.validation("所选安全方式需要设置无线密码") }
    }
    static func cryptoTitle(_ value: String) -> String {
        ["tkip": "TKIP", "aes": "AES", "aes+gcmp256": "AES + GCMP-256", "tkip+aes": "TKIP + AES", "suite-b": "Suite B"][value] ?? value
    }
    static func mfpTitle(_ value: String) -> String { ["0": "关闭", "1": "可选", "2": "必须"][value] ?? value }
}

public struct SettingChange: Sendable, Equatable {
    public let field: SettingField
    public let before: String
    public let after: String
    public init(field: SettingField, before: String, after: String) { self.field = field; self.before = before; self.after = after }
}
public struct ApplyReceipt: Sendable {
    public var verified: [String]
    public var unverified: [String]
    public var message: String
    public var isVerified: Bool { unverified.isEmpty }
}

extension RouterClient {
    public func readSettings(_ keys: [String]) async throws -> [String: String] {
        guard keys.count <= 600, keys.allSatisfy({ $0.range(of: #"^[A-Za-z][A-Za-z0-9_.]{0,79}$"#, options: .regularExpression) != nil }) else { throw RouterError.invalidResponse("设置字段") }
        var result: [String: String] = [:]
        let unique = Array(Set(keys)).sorted()
        for batch in Self.settingBatches(unique) {
            let data = try await request("appGet.cgi", query: [.init(name: "hook", value: batch.map { "nvram_char_to_ascii(\($0),\($0))" }.joined(separator: ";"))])
            let object = try RouterParser.json(data)
            for key in batch {
                if let v = object[key] as? String { result[key] = v.removingPercentEncoding ?? v }
                else if let v = object[key] as? NSNumber { result[key] = v.stringValue }
            }
            for key in batch where result[key] == nil {
                let fallback = try await request("appGet.cgi", query: [.init(name: "hook", value: "nvram_get(\(key))")])
                let json = try RouterParser.json(fallback)
                if let value = json[key] as? String { result[key] = value }
            }
            if batch.contains("jffs2_scripts"), result["jffs2_scripts"] == nil {
                let page = try await readManagementDocument("Advanced_System_Content.asp")
                result["jffs2_scripts"] = NativeLegacyScalar.checkedRadio(named: "jffs2_scripts", in: page)
            }
            guard batch.allSatisfy({ result[$0] != nil }) else { throw RouterError.validation("路由器未完整返回设置，暂不允许保存。缺失字段：" + batch.filter { result[$0] == nil }.joined(separator: ", ")) }
        }
        return result
    }
    /// Keys per appGet.cgi request: as many as fit well within httpd's request line (`char line[10000]` in httpd.c on every
    /// firmware line from 384 to 3006), so a page's settings arrive in one or two requests rather than one per six keys.
    static func settingBatches(_ keys: [String], budget: Int = 3000) -> [[String]] {
        var batches: [[String]] = [], current: [String] = [], length = 0
        for key in keys {
            // "nvram_char_to_ascii(key,key)" and the escaped ";" between hooks.
            let cost = 2 * key.utf8.count + 26
            if !current.isEmpty, length + cost > budget { batches.append(current); current = []; length = 0 }
            current.append(key); length += cost
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }
    /// Every field of a section by its own key, with list positions already taken apart, and the values the page
    /// reads to offer its choices (WirelessSecurityRules.contextKeys).
    public func readSettings(section: SettingSection) async throws -> [String: String] {
        let context = WirelessSecurityRules.contextKeys(sectionID: section.id)
        let stored = try await readSettings(section.fields.map(\.storageKey) + context)
        var values = SettingPacking.unpack(section.fields, stored: stored)
        for key in context { values[key] = stored[key] }
        return values
    }

    public func applySettings(section: SettingSection, changes: [SettingChange]) async throws -> ApplyReceipt {
        try acquireMutation(); defer { releaseMutation() }
        if SettingsCompatibility.isModelSpecific(section.id), writeScope.model != RouterProfile.referenceModel {
            throw RouterError.validation(SettingsCompatibility.modelSpecificText)
        }
        let reserved: Set<String> = ["action_mode", "rc_service", "action_script", "current_page", "wan_unit", "wl_unit", "vpn_client_unit", "wgc_unit"]
        guard !changes.contains(where: { reserved.contains($0.field.key) || $0.before == $0.after }) else { throw RouterError.validation("设置请求包含保留字段或没有变化的字段") }
        guard !changes.isEmpty, let definition = SettingsCatalog.section(section.id), definition == section,
              Set(changes.map { $0.field.key }).count == changes.count else { throw RouterError.invalidResponse("设置请求") }
        for change in changes {
            guard definition.fields.contains(change.field) else { throw RouterError.invalidResponse("未支持的设置字段") }
            try change.field.validate(change.after)
        }
        // The per-band Wi-Fi name and security, AP isolation and Wi-Fi 7 mode are on the web's pages only while the main
        // Wi-Fi is not an SDN network (WebMenuCatalog.sectionConditions, fieldConditions): checked on the router itself,
        // whatever the app last read.
        if WebMenuCatalog.condition(ofSection: section.id) == .perBandWireless
            || changes.contains(where: { WebMenuCatalog.condition(ofField: $0.field.key) == .perBandWireless }) {
            let mainfh = try await uiCapabilities()["sdn_mainfh"] ?? ""
            let profiles = (try await readSettings(["sdn_rl"])["sdn_rl"] ?? "").contains(">MAINFH>")
            guard ["", "0"].contains(mainfh), !profiles else {
                throw RouterError.validation("这台路由器的主 Wi-Fi 由“网络”页面管理，路由器网页的这一页不提供这些设置。请在“网络”页面按网络修改。")
            }
        }
        // The professional page offers only Auto when the main Wi-Fi is an SDN network (isSupport("sdn_mainfh")).
        if section.id.hasPrefix("radio"), changes.contains(where: { $0.field.key.hasSuffix("_nmode_x") && $0.after != "0" }),
           let mainfh = try await uiCapabilities()["sdn_mainfh"], !["", "0"].contains(mainfh) {
            throw RouterError.validation("这台路由器的主 Wi-Fi 由“网络”（SDN）管理，路由器网页的无线模式只提供“自动”。")
        }
        var checkedKeys = changes.map { $0.field.storageKey }
        if section.id == "dns" { checkedKeys += ["dnspriv_enable", "dnspriv_rulelist"] }
        // The time zone variables are checked together, so the unchanged ones are read with the changed ones.
        let changedKeys = Set(changes.map { $0.field.key })
        if !changedKeys.isDisjoint(with: RouterTimeZoneRules.keys) { checkedKeys += RouterTimeZoneRules.keys }
        let stored = try await readSettings(checkedKeys)
        let before = stored.merging(SettingPacking.unpack(changes.map(\.field), stored: stored)) { _, value in value }
        guard changes.allSatisfy({ before[$0.field.key] == $0.before }) else { throw RouterError.invalidResponse("设置已被其他操作改变，请重新读取后再保存") }
        var fields = Dictionary(uniqueKeysWithValues: changes.filter { $0.field.packed == nil }.map { ($0.field.key, $0.after) })
        fields.merge(try SettingPacking.pack(changes, stored: stored)) { _, list in list }
        try RouterTimeZoneRules.validate(stored.merging(fields) { _, edited in edited }, changed: changedKeys)
        if section.id == "dns", (fields["dnspriv_enable"] ?? before["dnspriv_enable"]) == "1" {
            let rows = try RouterRuleCodec.decode(fields["dnspriv_rulelist"] ?? before["dnspriv_rulelist"] ?? "", columns: 4)
            guard !rows.isEmpty, rows.allSatisfy({ !$0[0].isEmpty && ($0[1].isEmpty || Int($0[1]).map { (1...65535).contains($0) } == true) }) else {
                throw RouterError.validation("启用加密 DNS 前，请至少填写一个服务器，并检查端口范围。")
            }
        }
        // "wifi1", or "wifi2@6 GHz" for a radio beyond the reference catalog: the band's whole security as it will be,
        // whichever of its values changed (a lone 受保护的管理帧 change included).
        if let unit = WirelessSecurityRules.unit(ofSection: section.id) {
            let keys = ["auth_mode_x", "crypto", "mfp", "wpa_psk"].map { "wl\(unit)_\($0)" }
            if keys.contains(where: { fields[$0] != nil }) {
                let effective = try await readSettings(keys + WirelessSecurityRules.contextKeys(sectionID: section.id)).merging(fields) { _, edited in edited }
                let sixGHz = section.id.contains("@6")
                // Only Enhanced Open and the 6 GHz choices depend on whether the router supports Wi-Fi 7.
                let wifi7Router = effective["wl\(unit)_auth_mode_x"] == "owe" || sixGHz ? !["", "0"].contains(try await uiCapabilities()["wifi7"] ?? "") : false
                try WirelessSecurityRules.validateBand(effective, unit: unit, context: .init(
                    sixGHz: sixGHz, wifi7Router: wifi7Router, wifi7Mode: effective["wl\(unit)_11be"] == "1"))
            }
        }
        var movedTo: String?
        if section.id == "lan" {
            let context = try await readSettings(LANAddressRules.contextKeys)
            let addressChanged = fields["lan_ipaddr"] != nil || fields["lan_netmask"] != nil
            let support = addressChanged ? try await uiCapabilities() : [:]
            fields.merge(try LANAddressRules.dependentFields(changes: fields, context: context, support: support)) { _, dependent in dependent }
            if let ip = fields["lan_ipaddr"], ip != context["lan_ipaddr"] { movedTo = ip }
        }
        if section.id == "dhcp", fields["dhcp_start"] != nil || fields["dhcp_end"] != nil {
            let lan = try await readSettings(["lan_ipaddr", "lan_netmask", "dhcp_start", "dhcp_end"])
            try LANAddressRules.validatePool(start: fields["dhcp_start"] ?? lan["dhcp_start"] ?? "", end: fields["dhcp_end"] ?? lan["dhcp_end"] ?? "",
                                             lanIP: lan["lan_ipaddr"] ?? "", mask: lan["lan_netmask"] ?? "")
        }
        // rc's start_ipv6 (services.c) restores ipv6_prefix_length and ipv6_rtr_addr from their *_s copies in static
        // ("other") mode, and ipv6_prefix and ipv6_prefix_length in 6in4 mode, so Advanced_IPv6_Content.asp saves both.
        let ipv6Keys = ["ipv6_service", "ipv6_prefix", "ipv6_prefix_length", "ipv6_rtr_addr"]
        if section.id == "ipv6", ipv6Keys.contains(where: { fields[$0] != nil }) {
            let current = try await readSettings(ipv6Keys)
            func value(_ key: String) -> String { fields[key] ?? current[key] ?? "" }
            switch value("ipv6_service") {
            case "other": fields["ipv6_prefix_length_s"] = value("ipv6_prefix_length"); fields["ipv6_rtr_addr_s"] = value("ipv6_rtr_addr")
            case "6in4": fields["ipv6_prefix_length_s"] = value("ipv6_prefix_length"); fields["ipv6_prefix_s"] = value("ipv6_prefix")
            default: break
            }
        }
        // Advanced_System_Content.asp sends btn_ez_mode=0 with the Wi-Fi toggle choice, so the button keeps one function.
        if fields["btn_ez_radiotoggle"] == "1" { fields["btn_ez_mode"] = "0" }
        fields["action_mode"] = "apply"
        var service = section.service
        // The system page restarts the firewall on every save (remote access, NTP redirection), httpd only when its
        // protocol or ports change, and dnsmasq when the NTP server is switched on or off.
        let restartsWebServer = ["admin", "ssh", "ntp"].contains(section.id)
            && ["http_enable", "http_lanport", "https_lanport", "misc_httpport_x", "misc_httpsport_x"].contains { fields[$0] != nil }
        if ["admin", "ssh", "ntp"].contains(section.id) {
            service = "restart_time;" + (restartsWebServer ? "restart_httpd;" : "") + "restart_firewall;" + (fields["ntpd_enable"] != nil ? "restart_dnsmasq;" : "")
        }
        if section.id.hasPrefix("wan"), let unit = Int(section.id.dropFirst(3)) { service = "restart_wan_if \(unit)" }
        if section.id.hasPrefix("wgc"), let unit = Int(section.id.dropFirst(3)) {
            fields = Dictionary(uniqueKeysWithValues: fields.map { ($0.key.replacingOccurrences(of: "wgc\(unit)_", with: "wgc_"), $0.value) })
            fields["wgc_unit"] = String(unit); service = "restart_wgc;start_vpnrouting0"
        }
        if section.id == "wgs1" {
            fields = Dictionary(uniqueKeysWithValues: fields.map { ($0.key.replacingOccurrences(of: "wgs1_", with: "wgs_"), $0.value) })
            fields["wgs_unit"] = "1"
        }
        if section.id.hasPrefix("ovpns"), let unit = Int(section.id.dropFirst(5)) {
            let state = try await readSettings(["vpn_server\(unit)_state"])
            if !["1", "2"].contains(state["vpn_server\(unit)_state"] ?? "") { service = "" }
        }
        if section.id.hasPrefix("ovpn"), let unit = Int(section.id.dropFirst(4)) {
            let state = try await readSettings(["vpn_client\(unit)_state"])
            if !["1", "2"].contains(state["vpn_client\(unit)_state"] ?? "") { service = "" }
        }
        if !service.isEmpty { fields["rc_service"] = service }
        // After a move the old address cannot confirm anything; say where to reconnect instead.
        let moved = movedTo.map { "局域网地址将改为 \($0)，DHCP 地址池按路由器规则改为 \(fields["dhcp_start"] ?? "")–\(fields["dhcp_end"] ?? "")。网络重启后，请让这台 Mac 重新连接网络，再在连接设置中改用 http://\($0) 连接并核对结果。" }
        do { _ = try await submitApply(fields) }
        catch RouterError.submissionUncertain(let message) {
            // Restarting httpd ends this very request, so the lost reply is expected rather than alarming.
            let reason = restartsWebServer ? "路由器正在按新设置重启管理网页服务，当前连接会中断。请稍候在连接设置中按新的协议或端口重新连接，再核对结果。" : message
            return ApplyReceipt(verified: [], unverified: changes.map { $0.field.key }, message: moved.map { reason + " " + $0 } ?? reason)
        }
        if let moved { return ApplyReceipt(verified: [], unverified: changes.map { $0.field.key }, message: "路由器已接收设置。" + moved) }
        do {
            try await Task.sleep(for: .seconds(min(max(section.wait, 1), 90)))
            let after = SettingPacking.unpack(changes.map(\.field), stored: try await readSettings(changes.map { $0.field.storageKey }))
            let verified = changes.filter { after[$0.field.key] == $0.after }.map { $0.field.key }
            let unverified = changes.filter { after[$0.field.key] != $0.after }.map { $0.field.key }
            return ApplyReceipt(verified: verified, unverified: unverified, message: unverified.isEmpty ? "已从路由器重新读取，\(verified.count) 项设置已确认保存。" : "路由器已响应，但部分设置与提交值不一致。请重新读取并检查。")
        } catch {
            return ApplyReceipt(verified: [], unverified: changes.map { $0.field.key }, message: "路由器已接收请求，正在重载或重新连接。保存结果仍待重新读取确认。")
        }
    }

    @discardableResult
    func submitApply(_ fields: [String: String]) async throws -> [String: String] {
        try await submitApply(json: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), service: fields["rc_service"])
    }
    /// httpApi.nvramSet (httpApi.js 227–251): encodeURIComponent(JSON.stringify(obj)), the object's members in the page's order.
    @discardableResult
    func submitApply(ordered fields: [(String, String)]) async throws -> [String: String] {
        try await submitApply(members: fields.map { ($0.0, .string($0.1)) })
    }
    /// The same for an object whose members are not all text: a number the page holds stays a number in JSON.stringify.
    @discardableResult
    func submitApply(members: [(String, OrderedJSON)]) async throws -> [String: String] {
        let json = OrderedJSON.object(members).javaScriptJSON
        return try await submitApply(json: Data(json.utf8), service: members.last { $0.0 == "rc_service" }?.1.text)
    }
    private func submitApply(json: Data, service: String?) async throws -> [String: String] {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        guard let body = String(decoding: json, as: UTF8.self).addingPercentEncoding(withAllowedCharacters: allowed)?.data(using: .utf8) else { throw RouterError.invalidResponse("设置编码") }
        let data = try await request("applyapp.cgi", method: "POST", body: body, contentType: "application/x-www-form-urlencoded", timeout: 180)
        // httpd writes the settings before it composes this reply, so a reply it cannot vouch for
        // means "unconfirmed", never "nothing changed".
        guard let object = try? RouterParser.json(data) else {
            throw RouterError.submissionUncertain("路由器的回应无法识别，设置可能已经写入。请重新读取确认，不要重复提交。")
        }
        guard let modified = RouterParser.string(object["modify"]), ["0", "1"].contains(modified) else {
            throw RouterError.submissionUncertain("路由器没有确认接收设置，设置可能已部分写入。请重新读取确认，不要重复提交。")
        }
        if let service, !service.isEmpty, object["run_service"] as? String != service {
            throw RouterError.submissionUncertain("路由器已接收设置，但没有确认重新加载相关服务，新设置可能尚未生效。请重新读取确认，不要重复提交。")
        }
        return object.compactMapValues { $0 as? String }
    }
}

extension StringProtocol {
    /// Swift treats "\r\n" as a single Character, so `contains("\n")` misses it; scalar checks do not.
    var containsLineBreak: Bool { unicodeScalars.contains { CharacterSet.newlines.contains($0) } }
}

/// This firmware omits jffs2_scripts from appGet. Read its server-rendered scalar without a browser.
/// No script runs, no form is posted, and no other page content is retained.
enum NativeLegacyScalar {
    static func checkedRadio(named key: String, in source: String) -> String? {
        guard key == "jffs2_scripts", let regex = try? NSRegularExpression(pattern: #"(?i)<input\b[^>]*>"#) else { return nil }
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            guard let range = Range(match.range, in: source) else { continue }
            let tag = String(source[range])
            guard tag.range(of: #"\bname\s*=\s*["']jffs2_scripts["']"#, options: .regularExpression) != nil,
                  tag.range(of: #"\schecked(?:\s|=|/?>)"#, options: .regularExpression) != nil else { continue }
            return RouterParser.capture(#"\bvalue\s*=\s*["']([01])["']"#, in: tag)
        }
        return nil
    }
}
