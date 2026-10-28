import Foundation
import Darwin

/// ASUS rule lists have optional trailing and future columns. Never normalize them on unrelated edits.
public struct LosslessRuleTable: Sendable, Equatable {
    public var rows: [[String]]
    public init(_ source: String, minimumColumns: Int = 1) throws {
        guard source.isEmpty || source.hasPrefix("<") else { throw RouterError.validation("网络规则格式未识别，已保留原始设置") }
        rows = source.isEmpty ? [] : source.dropFirst().components(separatedBy: "<").map { $0.components(separatedBy: ">") }
        guard rows.allSatisfy({ $0.count >= minimumColumns }) else { throw RouterError.validation("网络规则列数不足，已停止修改") }
    }
    public var encoded: String { rows.map { "<" + $0.joined(separator: ">") }.joined() }
    mutating func replace(id: String, values: [Int: String], minimum: Int) throws {
        guard let index = rows.firstIndex(where: { $0.first == id }), rows[index].count >= minimum else { throw RouterError.validation("找不到对应的网络规则") }
        for (column, value) in values { try SDNPlanner.validateAtom(value); guard rows[index].indices.contains(column) else { throw RouterError.validation("此固件的字段结构尚未适配") }; rows[index][column] = value }
    }
}
public struct SDNProfile: Sendable, Identifiable, Equatable {
    public let id: String
    public var kind: String
    public var enabled: Bool
    public var ssid: String
    public var password: String
    public var auth: String
    public var crypto: String
    public var reservations: String
    public var hidden: Bool
    public var isolated: Bool
    public var allowRouter: Bool
    public var allowLAN: Bool
    public var vlan: String
    public var address: String
    public var mask: String
    public var dhcp: Bool
    public var start: String
    public var end: String
    public var lease: String
    public var dns: String
    public var vpn: String
    public var killSwitch: Bool
    /// apm/apg `_11be`, the network's WiFi7 模式. MLO 前传 keeps it on (sdn.js 8854, 9147).
    public var wifi7 = false
    /// apm/apg `_mlo`: "2" is MLO 前传（用于客户端）, "1" the MLO backhaul network, "0" off.
    public var mlo = "0"
    /// The network broadcasts Wi-Fi: the first dut_list entry names a band (sdn.js get_wifi_band), or it is the
    /// main or an MLO network. Without a band the page hides every Wi-Fi setting and never writes `_11be`.
    public var hasWiFi = true
    /// The band mask of the first dut_list entry, `cap_wifi_band` (sdn.js 7548–7566): 1 2.4 GHz, 2/4/8 5 GHz,
    /// 16/32/64 6 GHz. It decides which auth selector the page shows (get_elem_attr_wifi_auth()).
    public var bands = 0
    public var isMain: Bool { ["MAINFH", "MAINBH", "LEGACY"].contains(kind) }
    public var canDelete: Bool { !isMain && ["Guest", "Customized", "VPN", "Kids", "Employee"].contains(kind) }
    /// sdn.js is_mlo_fh: MLO 前传 on an MLO, Gaming or main network.
    public var mloFronthaul: Bool { mlo == "2" && ["MLO", "Gaming", "MAINFH"].contains(kind) }
    /// sdn.js check_is_mlo_bh (11842–11846): `_mlo` "1" with a "*" entry in `dut_list`, an MLO backhaul network.
    public var mloBackhaul = false
    /// show_sdn_profilelist() (10420–10431) lists every network but MAINBH and MLO backhaul networks, so the page has no
    /// settings for those, WiFi7 模式 included.
    public var listedOnWebPage: Bool { kind != "MAINBH" && !mloBackhaul }
    /// `_security` holds the four rows the page writes, <3>, <13>, <16> and <96> (sdn.js 9193–9196). The page saves any other
    /// form, such as a single firmware-made <127> row, as these four and rebuilds the device list with it
    /// (get_legacy_dut_list); the app does neither, so it changes auth, encryption and WiFi7 模式 only in this form.
    public var standardSecurity = true
}
public struct SDNSnapshot: Sendable {
    public let values: [String: String]
    public var profiles: [SDNProfile]
    /// ui_support `wifi7`: the SDN page shows WiFi7 模式 only then (sdn.js 6364). Unknown counts as unsupported.
    public var wifi7Supported = false
    public init(values: [String: String]) throws {
        self.values = values
        let sdn = try LosslessRuleTable(values["sdn_rl"] ?? "", minimumColumns: 16)
        let subnet = try LosslessRuleTable(values["subnet_rl"] ?? "", minimumColumns: 13)
        let vlan = try LosslessRuleTable(values["vlan_rl"] ?? "", minimumColumns: 2)
        let access = try LosslessRuleTable(values["sdn_access_rl"] ?? "", minimumColumns: 2)
        profiles = try sdn.rows.filter { $0[0] != "0" }.map { row in
            let prefix = Self.prefix(row)
            let security = try LosslessRuleTable(values[prefix + "security"] ?? "", minimumColumns: 4)
            let sec = security.rows.first { $0[0] == "3" } ?? security.rows.first
            let sub = subnet.rows.first { $0[0] == row[4] }
            let vid = vlan.rows.first { $0[0] == row[3] }?[1] ?? ""
            let mlo = values[prefix + "mlo"] ?? "0"
            let firstDevice = (values[prefix + "dut_list"] ?? "").split(separator: "<").first?.split(separator: ">", omittingEmptySubsequences: false)
            let band = firstDevice.flatMap { $0.count > 1 ? Int($0[1]) : nil } ?? 0
            var profile = SDNProfile(id: row[0], kind: row[1], enabled: row[2] == "1", ssid: values[prefix + "ssid"] ?? "", password: sec?[3] ?? "", auth: sec?[1] ?? "psk2", crypto: sec?[2] ?? "aes", reservations: values["dhcpres" + row[4] + "_rl"] ?? "", hidden: values[prefix + "hide_ssid"] == "1", isolated: values[prefix + "ap_isolate"] == "1", allowRouter: row[15] == "1", allowLAN: access.rows.contains { ($0[0] == "0" && $0[1] == row[0]) || ($0[1] == "0" && $0[0] == row[0]) }, vlan: vid, address: sub?[2] ?? "", mask: sub?[3] ?? "255.255.255.0", dhcp: sub?[4] == "1", start: sub?[5] ?? "", end: sub?[6] ?? "", lease: sub?[7] ?? "86400", dns: sub?[9] ?? ",", vpn: row[6], killSwitch: row[14] == "1")
            profile.mlo = mlo
            profile.mloBackhaul = mlo == "1" && (values[prefix + "dut_list"] ?? "").components(separatedBy: "<").contains { !$0.isEmpty && $0.components(separatedBy: ">")[0] == "*" }
            profile.standardSecurity = security.rows.map { $0[0] } == SDNSecurity.standardBands
            profile.bands = band
            profile.hasWiFi = row[1] == "MAINFH" || ["1", "2"].contains(mlo) || band > 0
            profile.wifi7 = values[prefix + "11be"] == "1" || profile.mloFronthaul
            return profile
        }
    }
    static func prefix(_ row: [String]) -> String { (["MAINFH", "MAINBH"].contains(row[1]) ? "apm" : "apg") + row[5] + "_" }
}
public struct SDNPlan: Sendable {
    public let fields: [String: String]
    public let expected: [String: String]
    public let service: String
    public let summary: String
    public let wait: Int
    /// The save restarts the whole LAN and every radio (restart_net_and_phy), not just this network.
    public var restartsWholeNetwork = false
    /// Every variable the save writes, readable, for the review before it is sent.
    public var changes: [SDNPlanChange] = []
    /// What the user should know beyond the restart: devices that may not reconnect, and why.
    public var warnings: [String] = []
}

/// One variable an SDN save writes, as the review shows it. Passwords never appear.
public struct SDNPlanChange: Sendable, Equatable, Identifiable {
    public let key: String
    public let title: String
    public let before: String
    public let after: String
    public var id: String { key }

    static func describe(_ fields: [String: String], current values: [String: String]) -> [SDNPlanChange] {
        fields.keys.sorted().map { key in
            let suffix = key.range(of: #"^ap[gm]\d+_"#, options: .regularExpression).map { String(key[$0.upperBound...]) }
            let old = values[key], new = fields[key] ?? ""
            switch suffix {
            case "11be": return SDNPlanChange(key: key, title: "WiFi7 模式", before: old.map(onOff) ?? "（无）", after: onOff(new))
            case "security":
                let before = old.map(SDNSecurity.summary) ?? "（无）"
                var after = SDNSecurity.summary(new)
                if let old, SDNSecurity.passwords(old) != SDNSecurity.passwords(new) { after += "（密码已修改）" }
                return SDNPlanChange(key: key, title: "安全设置", before: before, after: after)
            case "ssid": return SDNPlanChange(key: key, title: "网络名称", before: old ?? "（无）", after: new)
            case "enable": return SDNPlanChange(key: key, title: "启用网络", before: old.map(onOff) ?? "（无）", after: onOff(new))
            case "hide_ssid": return SDNPlanChange(key: key, title: "隐藏网络名称", before: old.map(onOff) ?? "（无）", after: onOff(new))
            case "ap_isolate": return SDNPlanChange(key: key, title: "隔离网络内的无线设备", before: old.map(onOff) ?? "（无）", after: onOff(new))
            default:
                let title = key.hasSuffix("_x") ? "删除记录（固件用）" : key.hasPrefix("dhcpres") ? "固定地址分配" : key.hasSuffix("_rl") || key == "radius_list" ? "规则表" : "设置"
                // Rule rows can hold MAC addresses or RADIUS keys, so the review counts them instead of showing them.
                guard (old ?? "").hasPrefix("<") || new.hasPrefix("<") else {
                    return SDNPlanChange(key: key, title: title, before: old.map(plain) ?? "（无）", after: plain(new))
                }
                let before = rows(old ?? ""), after = rows(new), changed = after.filter { !before.contains($0) }.count
                return SDNPlanChange(key: key, title: title, before: old == nil ? "（无）" : "\(before.count) 行",
                                     after: "\(after.count) 行" + (changed > 0 ? "（\(changed) 行有变化）" : ""))
            }
        }
    }
    private static func onOff(_ value: String) -> String { value == "1" ? "开启" : value == "0" ? "关闭" : value }
    private static func plain(_ value: String) -> String { value.isEmpty ? "空" : value.count > 40 ? "已修改" : value }
    private static func rows(_ value: String) -> [String] { value.isEmpty ? [] : Array(value.components(separatedBy: "<").dropFirst()) }
}
/// The SDN page's security choices, from Asuswrt-Merlin 3006.102.5 www/sysdep/FUNCTION/SDN/SDN/sdn.js.
public enum SDNSecurity {
    public static func authLabel(_ auth: String) -> String {
        switch auth {
        case "open": "开放网络"
        case "owe": "开放网络（OWE）"
        case "psk2": "WPA2-Personal"
        case "pskpsk2": "WPA/WPA2-Personal"
        case "psk2sae": "WPA2/WPA3-Personal"
        case "sae": "WPA3-Personal"
        case "wpa2": "WPA2-Enterprise"
        case "wpawpa2": "WPA/WPA2-Enterprise"
        case "wpa2wpa3": "WPA2/WPA3-Enterprise"
        case "wpa3": "WPA3-Enterprise"
        case "suite-b": "WPA3-Enterprise 192-bit"
        default: auth
        }
    }
    public static func cryptoLabel(_ crypto: String) -> String {
        switch crypto {
        case "aes": "AES"
        case "aes+gcmp256": "AES + GCMP-256"
        case "gcmp256": "GCMP-256"
        case "tkip": "TKIP"
        case "tkip+aes": "TKIP + AES"
        case "suite-b": "Suite-B"
        default: crypto
        }
    }
    /// handle_wifi_crypto() encryptionMapping (11885–11981): the 加密 choices for an auth. The page hides the row for an
    /// open network and saves AES (9152–9155).
    public static func cryptoChoices(auth: String, wifi7: Bool) -> [String] {
        switch auth {
        case "pskpsk2", "wpawpa2": ["aes", "tkip+aes"]
        case "psk2sae", "sae", "wpa2wpa3", "wpa3": wifi7 ? ["aes", "aes+gcmp256"] : ["aes"]
        case "suite-b": ["suite-b"]
        default: ["aes"]
        }
    }
    /// The page offers 开放网络 only on the main, Guest and Portal networks; the others have a password only (7440–7442, 7761–7774).
    public static func offersOpen(_ profile: SDNProfile) -> Bool { ["MAINFH", "Guest", "Portal"].contains(profile.kind) }
    /// The band masks of the rows every SDN save writes, in order (sdn.js 5118–5121, 5575–5578, 5876–5879, 9193–9196).
    static let standardBands = ["3", "13", "16", "96"]
    /// Why the app leaves auth, encryption and WiFi7 模式 of a network with other rows to the web page.
    public static let nonstandardNote = "这个网络的安全规则不是网页保存的四行格式。网页修改认证、加密或 WiFi7 模式时，会把安全规则改写成四行并重建设备列表；本应用不做这种改写，这几项请在路由器网页修改。只改密码不受影响。"
    /// MAINBH and MLO backhaul networks: the page lists neither (10420–10431) and removes an MLO backhaul network's
    /// apply and delete buttons (7443–7448), so the app changes nothing on them either.
    public static let unlistedNote = "路由器网页的“网络”页不列出这个回程网络，也不提供修改或删除；本应用同样只显示，不修改。"
    /// The auths the app edits; validateProfile refuses every save of a network with another one.
    static let editableAuths = ["open", "owe", "psk2", "psk2sae", "sae"]
    /// Why the editor leaves this network's auth, encryption and WiFi7 模式 alone; nil when it can change them.
    public static func lockedReason(_ profile: SDNProfile) -> String? {
        if !profile.listedOnWebPage { return unlistedNote }
        if !editableAuths.contains(profile.auth) { return "这个网络使用 \(authLabel(profile.auth))，本应用不修改使用这种认证的网络，请在路由器网页修改。" }
        if !profile.standardSecurity { return nonstandardNote }
        return nil
    }
    /// The PSK choices of the auth selector the page shows for this network (get_elem_attr_wifi_auth(), 11850–11884, as
    /// 8448–8454 calls it): the MLO selector (6888) for MLO 前传, or for bands with 6 GHz and another band; the 6G selector
    /// (6881) for 6 GHz alone; the default selector (6839–6844) otherwise. `_mlo` "1" also gets the MLO choices here.
    static func selectorChoices(_ profile: SDNProfile) -> [String] {
        let sixGHz = profile.bands & 112 != 0
        if ["1", "2"].contains(profile.mlo) || (sixGHz && profile.bands & 15 != 0) { return ["psk2sae", "sae"] }
        if sixGHz { return ["sae"] }
        return ["psk2", "pskpsk2", "psk2sae", "sae"]
    }
    /// get_wifi_band() bands_bit_mapping: the bands of a security row's band mask.
    static func bandTitle(_ mask: String) -> String {
        guard let value = Int(mask) else { return mask }
        let names = [(1, "2.4 GHz"), (2, "5 GHz"), (4, "5 GHz-1"), (8, "5 GHz-2"), (16, "6 GHz"), (32, "6 GHz-1"), (64, "6 GHz-2")].filter { value & $0.0 != 0 }.map(\.1)
        return names.isEmpty ? mask : names.joined(separator: " + ")
    }
    /// The security rows without their passwords.
    static func summary(_ security: String) -> String {
        guard let table = try? LosslessRuleTable(security, minimumColumns: 3), !table.rows.isEmpty else { return security.isEmpty ? "空" : "无法识别" }
        return table.rows.map { "\(bandTitle($0[0]))：\(authLabel($0[1])) · \(cryptoLabel($0[2]))" }.joined(separator: "；")
    }
    static func passwords(_ security: String) -> [String] {
        ((try? LosslessRuleTable(security))?.rows ?? []).map { $0.count > 3 ? $0[3] : "" }
    }
    /// Refuses what the page cannot save once the auth, encryption or WiFi7 模式 changes; `previous` is nil for a new network.
    static func validate(_ profile: SDNProfile, previous: SDNProfile?) throws {
        let wifi7 = profile.wifi7 || profile.mloFronthaul
        if profile.mlo == "1" || profile.mloFronthaul {
            // The MLO selector (6888) has only these two; an open main network stays possible (security_all).
            guard ["psk2sae", "sae"].contains(profile.auth) || (profile.auth == "owe" && offersOpen(profile) && profile.mlo == "2") else {
                throw RouterError.validation("MLO 网络只能使用 WPA2/WPA3-Personal 或 WPA3-Personal。")
            }
        }
        if ["open", "owe"].contains(profile.auth), previous.map({ !["open", "owe"].contains($0.auth) }) ?? true, !offersOpen(profile) {
            throw RouterError.validation("路由器网页只给主网络和访客网络提供开放网络，这个网络只能用密码保护。")
        }
        let selector = selectorChoices(profile)
        if !["open", "owe"].contains(profile.auth), !selector.contains(profile.auth) {
            throw RouterError.validation("按这个网络使用的频段，路由器网页的认证选单只有 \(selector.map(authLabel).joined(separator: "、"))。")
        }
        if wifi7 {
            guard ["psk2sae", "sae", "owe"].contains(profile.auth) else {
                throw RouterError.validation("WiFi7 模式开启时，路由器网页只提供 WPA2/WPA3-Personal、WPA3-Personal，或以 OWE 保存的开放网络。")
            }
        } else if profile.auth == "owe", previous?.auth != "owe" || previous?.wifi7 != profile.wifi7 {
            throw RouterError.validation("WiFi7 模式关闭时，路由器网页把开放网络保存为不加密的 open；OWE 只随 WiFi7 模式一起保存。")
        }
        let choices = cryptoChoices(auth: profile.auth, wifi7: wifi7)
        guard choices.contains(profile.crypto) else {
            throw RouterError.validation("\(authLabel(profile.auth))\(wifi7 ? "" : "在 WiFi7 模式关闭时")只能选择 \(choices.map(cryptoLabel).joined(separator: " 或 ")) 加密。")
        }
    }
}

/// The SDN page's WiFi7 模式 switch and the settings it changes with it (sdn.js, Asuswrt-Merlin 3006.102.5). On a
/// router whose main Wi-Fi is an SDN network (ui_support sdn_mainfh) this is where the web switches Wi-Fi 7: the
/// professional page hides its own wl_11be row there (sysdep/GT-AXE11000 Advanced_WAdvanced_Content.asp:808–810, 1793).
public enum SDNWiFi7 {
    /// WiFi7_wifi_auth_hint as the help icon fills it in (sdn.js 6898).
    public static let authHint = "根据 WiFi 7 标准，无线认证方法应设置为 WPA2/WPA3-Personal, WPA3-Personal 以获得最佳连接性。"
    /// WiFi7_disable_note and AiMesh_Are_U_Sure_Proceed: asked before an auth that cannot keep WiFi7 模式 (6859).
    public static let disableNote = "由于目前已启用 WiFi7 模式，进行此调整将会禁用 WiFi7 模式。 您确定要继续吗？"
    /// WiFi7_mlo_adjust_hint with its "WiFi7 模式/" parts removed, as the switch shows it while MLO 前传 is on (6398–6401).
    public static let mloHint = "由于目前已启用 MLO，因此对这些 WiFi 设置进行任何调整都需要先关闭 MLO。"

    /// The page shows the switch only with ui_support wifi7 (6364), never on an MLO network (8063–8064), only among
    /// the Wi-Fi settings a network without a band hides, and only on the networks it lists (10420–10431).
    public static func isOffered(_ profile: SDNProfile, supported: Bool) -> Bool {
        supported && profile.kind != "MLO" && profile.hasWiFi && profile.listedOnWebPage
    }
    /// Switched on (6369–6396, 6405): an auth that cannot stay on WiFi7 becomes the first WPA3-capable choice of its selector,
    /// an open network is saved as OWE (9152), and the encryption keeps only what handle_wifi_crypto() allows.
    public static func switchedOn(_ profile: SDNProfile) -> SDNProfile {
        var next = profile
        next.wifi7 = true
        if ["open", "owe"].contains(next.auth) { next.auth = "owe"; next.crypto = "aes" }
        else if !["psk2sae", "sae", "wpa2wpa3", "wpa3", "suite-b"].contains(next.auth) { next.auth = ["wpa2", "wpawpa2"].contains(next.auth) ? "wpa2wpa3" : "psk2sae" }
        return fittingCrypto(next)
    }
    /// Switched off (6397–6405): refused while MLO 前传 keeps it on; an open network is saved as open again.
    public static func switchedOff(_ profile: SDNProfile) throws -> SDNProfile {
        guard !profile.mloFronthaul else { throw RouterError.validation(mloHint) }
        var next = profile
        next.wifi7 = false
        if next.auth == "owe" { next.auth = "open"; next.crypto = "aes" }
        return fittingCrypto(next)
    }
    /// The auth choices of this network's selector, 开放网络 first where the page offers it. The default selector's
    /// WPA/WPA2-Personal is left out: the app does not edit networks that use it (validateProfile).
    public static func authChoices(_ profile: SDNProfile) -> [String] {
        (SDNSecurity.offersOpen(profile) ? ["open"] : []) + SDNSecurity.selectorChoices(profile).filter { $0 != "pskpsk2" }
    }
    /// Choosing a WPA2-only auth while WiFi7 模式 is on asks first (6853–6866).
    public static func asksBeforeChoosing(_ auth: String, in profile: SDNProfile) -> Bool {
        profile.wifi7 && !["open", "owe", "psk2sae", "sae"].contains(auth)
    }
    /// The choice made (after the question, if any): WiFi7 模式 goes off with an auth that cannot keep it (6872–6878),
    /// 开放网络 is OWE while it is on, and the encryption follows handle_wifi_crypto().
    public static func choosing(_ auth: String, in profile: SDNProfile) -> SDNProfile {
        var next = profile
        if ["open", "owe"].contains(auth) {
            next.auth = next.wifi7 ? "owe" : "open"; next.crypto = "aes"
        } else {
            next.auth = auth
            if next.wifi7 && !next.mloFronthaul && !["psk2sae", "sae"].contains(auth) { next.wifi7 = false }
        }
        return fittingCrypto(next)
    }
    /// The 加密 choices the page shows for this network now; empty for an open network, whose row it hides.
    public static func cryptoChoices(_ profile: SDNProfile) -> [String] {
        ["open", "owe"].contains(profile.auth) ? [] : SDNSecurity.cryptoChoices(auth: profile.auth, wifi7: profile.wifi7 || profile.mloFronthaul)
    }
    /// A hidden encryption choice becomes the first one shown (handle_wifi_crypto, 11966–11972).
    static func fittingCrypto(_ profile: SDNProfile) -> SDNProfile {
        var next = profile
        let choices = SDNSecurity.cryptoChoices(auth: next.auth, wifi7: next.wifi7 || next.mloFronthaul)
        if !choices.contains(next.crypto) { next.crypto = choices[0] }
        return next
    }
}

public enum SDNPlanner {
    static func validateAtom(_ value: String) throws {
        guard value.utf8.count < 8192, !value.contains("<"), !value.contains(">"), !value.containsLineBreak, !value.contains("\u{0}") else { throw RouterError.validation("网络设置不能包含规则分隔符或换行") }
    }
    static func ip(_ string: String) -> UInt32? {
        var address = in_addr(); guard inet_pton(AF_INET, string, &address) == 1 else { return nil }; return UInt32(bigEndian: address.s_addr)
    }
    static func address(_ ip: UInt32) -> String { [24, 16, 8, 0].map { String((ip >> $0) & 255) }.joined(separator: ".") }
    static func validMask(_ mask: UInt32) -> Bool { mask != 0 && (~mask & (~mask + 1)) == 0 }
    static func overlap(_ a: String, _ am: String, _ b: String, _ bm: String) throws -> Bool {
        guard let av = ip(a), let bv = ip(b), let ma = ip(am), let mb = ip(bm), validMask(ma), validMask(mb) else { throw RouterError.validation("无法确认现有网络地址或掩码，已停止子网修改") }
        let common = ma & mb
        return (av & common) == (bv & common)
    }
    static func validateProfile(_ p: SDNProfile) throws {
        for text in [p.ssid, p.password, p.auth, p.crypto, p.address, p.mask, p.start, p.end, p.dns, p.vlan, p.vpn] { try validateAtom(text) }
        guard (1...32).contains(p.ssid.utf8.count) else { throw RouterError.validation("网络名称需为 1–32 字节") }
        guard SDNSecurity.editableAuths.contains(p.auth) else { throw RouterError.validation("当前安全方式需要专用认证设置，尚不能在此修改") }
        if !["open", "owe"].contains(p.auth) {
            // sdn.js valid_psk (9732–9779): an 8–63 character passphrase, or a 64-digit hexadecimal key.
            guard WirelessSecurityRules.isPassphrase(p.password) || p.password.range(of: "^[0-9A-Fa-f]{64}$", options: .regularExpression) != nil else {
                throw RouterError.validation("无线密码需为 8–63 个 ASCII 字符（首尾不能是空格或双引号），或 64 位十六进制密钥")
            }
        }
        try WirelessSecurityRules.validate(auth: p.auth, crypto: p.crypto, key: p.password)
        if !p.address.isEmpty {
            guard let addr = ip(p.address), let mask = ip(p.mask), validMask(mask) else { throw RouterError.validation("请输入有效的子网地址和连续掩码") }
            guard addr > (addr & mask), addr < ((addr & mask) | ~mask) else { throw RouterError.validation("网关不能是网络地址或广播地址") }
            if p.dhcp {
                guard let first = ip(p.start), let last = ip(p.end), first <= last, (first & mask) == (addr & mask), (last & mask) == (addr & mask), first > (addr & mask), last < ((addr & mask) | ~mask), !(first...last).contains(addr) else { throw RouterError.validation("DHCP 范围必须位于该子网内") }
            }
            guard let lease = Int(p.lease), (120...604800).contains(lease) else { throw RouterError.validation("租约时间应为 120–604800 秒") }
        }
        _ = try RouterRuleCodec.encode(RouterRuleCodec.decode(p.reservations, columns: 4), columns: 4)
        if !p.vlan.isEmpty { guard let vlan = Int(p.vlan), (2...4094).contains(vlan) else { throw RouterError.validation("VLAN ID 应为 2–4094") } }
        guard ["aes", "aes+gcmp256", "gcmp256"].contains(p.crypto) else { throw RouterError.validation("请选择支持的加密方式") }
        for server in p.dns.components(separatedBy: ",") where !server.isEmpty {
            var v6 = in6_addr()
            guard ip(server) != nil || inet_pton(AF_INET6, server, &v6) == 1 else { throw RouterError.validation("DNS 服务器须为有效 IP 地址") }
        }
        guard SDNClientRoute(p.vpn) != nil else { throw RouterError.validation("请选择有效的 VPN 客户端") }
    }
    static func validateReservations(_ profile: SDNProfile) throws {
        guard let addr = ip(profile.address), let mask = ip(profile.mask) else { throw RouterError.validation("子网地址尚未读取") }
        let rows = try RouterRuleCodec.decode(profile.reservations, columns: 4)
        var addresses = Set<String>(), macs = Set<String>()
        for row in rows {
            guard row[0].range(of: #"^(?:[A-Fa-f0-9]{2}:){5}[A-Fa-f0-9]{2}$"#, options: .regularExpression) != nil,
                  let reserved = ip(row[1]), (reserved & mask) == (addr & mask), reserved > (addr & mask), reserved < ((addr & mask) | ~mask), reserved != addr,
                  addresses.insert(row[1]).inserted, macs.insert(row[0].uppercased()).inserted else { throw RouterError.validation("固定地址需唯一、位于该子网中，并使用有效 MAC 地址") }
        }
    }
    public static func newGuest(snapshot: SDNSnapshot) throws -> SDNProfile {
        let occupied = snapshot.profiles.compactMap { ip($0.address) }.map { $0 & 0xffffff00 }
        let main = ip(snapshot.values["lan_ipaddr"] ?? "") ?? 0
        guard let octet = (52...254).first(where: { !occupied.contains(0xc0a80000 | UInt32($0 << 8)) && (main & 0xffffff00) != (0xc0a80000 | UInt32($0 << 8)) }) else { throw RouterError.validation("没有可分配的默认子网") }
        let vlan = try LosslessRuleTable(snapshot.values["vlan_rl"] ?? "", minimumColumns: 2)
        guard let vid = (52...4094).first(where: { number in !vlan.rows.contains { $0[1] == String(number) } }) else { throw RouterError.validation("没有可分配的 VLAN") }
        return SDNProfile(id: "new", kind: "Guest", enabled: true, ssid: "Guest", password: "", auth: "psk2sae", crypto: "aes", reservations: "", hidden: false, isolated: true, allowRouter: false, allowLAN: false, vlan: String(vid), address: "192.168.\(octet).1", mask: "255.255.255.0", dhcp: true, start: "192.168.\(octet).2", end: "192.168.\(octet).254", lease: "86400", dns: ",", vpn: "0", killSwitch: false)
    }
    public static func create(_ profile: SDNProfile, snapshot: SDNSnapshot) throws -> SDNPlan {
        try validateProfile(profile)
        if profile.wifi7 { guard SDNWiFi7.isOffered(profile, supported: snapshot.wifi7Supported) else { throw RouterError.validation("这台路由器的网页没有 WiFi7 模式开关。") } }
        try SDNSecurity.validate(profile, previous: nil)
        guard !profile.address.isEmpty, !profile.vlan.isEmpty else { throw RouterError.validation("新建网络必须设置有效地址和 VLAN") }
        try validateReservations(profile)
        let values = snapshot.values
        var sdn = try LosslessRuleTable(values["sdn_rl"] ?? "", minimumColumns: 16)
        var subnet = try LosslessRuleTable(values["subnet_rl"] ?? "", minimumColumns: 13)
        var vlan = try LosslessRuleTable(values["vlan_rl"] ?? "", minimumColumns: 2)
        var access = try LosslessRuleTable(values["sdn_access_rl"] ?? "", minimumColumns: 2)
        func free(_ occupied: [String], max: Int = 6) throws -> String {
            guard let idx = (1...max).first(where: { !occupied.contains(String($0)) }) else { throw RouterError.validation("网络配置数量已达到当前适配上限") }; return String(idx)
        }
        let bridgeIDs = subnet.rows.compactMap { row -> String? in guard row[1].hasPrefix("br"), let n = Int(row[1].dropFirst(2)), n > 51 else { return nil }; return String(n - 51) }
        let id = try free(sdn.rows.map { $0[0] } + bridgeIDs)
        let subnetID = try free(subnet.rows.map { $0[0] } + sdn.rows.map { $0[4] })
        let vlanID = try free(vlan.rows.map { $0[0] }, max: 64)
        let apgID = try free(sdn.rows.filter { !["MAINFH", "MAINBH"].contains($0[1]) }.map { $0[5] })
        guard !vlan.rows.contains(where: { $0[1] == profile.vlan }) else { throw RouterError.validation("VLAN ID 已被占用") }
        guard profile.mask == "255.255.255.0" else { throw RouterError.validation("新建访客网络目前要求 /24 子网") }
        var existing = subnet.rows.map { ($0[2], $0[3]) } + [(values["lan_ipaddr"] ?? "", values["lan_netmask"] ?? "")]
        for unit in 0...1 { if let ip = values["wan\(unit)_ipaddr"], !ip.isEmpty && ip != "0.0.0.0" { existing.append((ip, values["wan\(unit)_netmask"] ?? "")) } }
        for (address, mask) in existing {
            if try overlap(profile.address, profile.mask, address, mask) { throw RouterError.validation("新网络与现有网络重叠") }
        }
        let mac = values["lan_hwaddr"] ?? ""
        guard mac.range(of: #"^(?:[A-Fa-f0-9]{2}:){5}[A-Fa-f0-9]{2}$"#, options: .regularExpression) != nil else { throw RouterError.validation("尚未读取路由器接口地址") }
        let row = [id,"Guest",profile.enabled ? "1":"0",vlanID,subnetID,apgID,profile.vpn,"0","0","0","0","0","0","0",profile.killSwitch ? "1":"0",profile.allowRouter ? "1":"0","0","0","0","WEB","0","0","0"]
        sdn.rows.append(row)
        subnet.rows.append([subnetID,"br\((Int(id) ?? 0) + 51)",profile.address,profile.mask,profile.dhcp ? "1":"0",profile.start,profile.end,profile.lease,"",profile.dns,"",profile.reservations.isEmpty ? "0":"1",profile.reservations.isEmpty ? "":subnetID,"0","0",id,"1000","2000",",,","0","1",""])
        vlan.rows.append([vlanID,profile.vlan,"0",""])
        if profile.allowLAN { access.rows.append(["0",id]) }
        let security = ["3","13","16","96"].map { band in
            let auth = ["16","96"].contains(band) ? (["open","owe"].contains(profile.auth) ? "owe":"sae") : profile.auth
            return "<\(band)>\(auth)>\(profile.crypto)>\(["open","owe"].contains(profile.auth) ? "":profile.password)>\(id)"
        }.joined()
        let prefix = "apg\(apgID)_"
        var fields = ["sdn_rl":sdn.encoded,"subnet_rl":subnet.encoded,"vlan_rl":vlan.encoded,"radius_list":values["radius_list"] ?? "","sdn_access_rl":access.encoded]
        let ap = ["enable":profile.enabled ? "1":"0","ssid":profile.ssid,"hide_ssid":profile.hidden ? "1":"0","security":security,"bw_limit":"<0>>","timesched":"0","sched":"","expiretime":"","ap_isolate":profile.isolated ? "1":"0","macmode":"disabled","mlo":"0","maclist":"","iot_max_cmpt":"","dut_list":"<\(mac)>3>","11be":profile.wifi7 ? "1":"0"]
        for (key,value) in ap { fields[prefix + key] = value }
        fields["dhcpres\(subnetID)_rl"] = profile.reservations
        var service = "restart_wireless;restart_sdn \(id);"
        if values["qos_enable"] == "1" { service += "restart_qos;restart_firewall;" }
        let expected = Dictionary(uniqueKeysWithValues: ["sdn_rl","subnet_rl","vlan_rl","radius_list","sdn_access_rl","qos_enable","lan_hwaddr","lan_ipaddr","lan_netmask","wan0_ipaddr","wan0_netmask","wan1_ipaddr","wan1_netmask"].map { ($0, values[$0] ?? "") })
        var plan = SDNPlan(fields: fields, expected: expected, service: service, summary: "新增访客网络“\(profile.ssid)”，由当前路由器广播", wait: 20)
        plan.changes = SDNPlanChange.describe(fields, current: values)
        return plan
    }
    public static func delete(_ profile: SDNProfile, snapshot: SDNSnapshot) throws -> SDNPlan {
        guard profile.canDelete else { throw RouterError.validation("主网络或特殊用途网络暂不支持在此删除") }
        guard (snapshot.profiles.first { $0.id == profile.id } ?? profile).listedOnWebPage else { throw RouterError.validation(SDNSecurity.unlistedNote) }
        let v = snapshot.values
        var sdn = try LosslessRuleTable(v["sdn_rl"] ?? "", minimumColumns: 16)
        guard let row = sdn.rows.first(where: { $0[0] == profile.id }), row[11] == "0" else { throw RouterError.validation("门户网络尚未适配删除联动") }
        guard (v["vlan_trunklist"] ?? "").isEmpty else { throw RouterError.validation("端口绑定网络需先解除相应端口映射") }
        let prefix = SDNSnapshot.prefix(row)
        let dut = try LosslessRuleTable(v[prefix + "dut_list"] ?? "", minimumColumns: 2)
        guard !dut.rows.contains(where: { $0.count > 2 && !$0[2].isEmpty }) else { throw RouterError.validation("有线端口绑定尚未适配删除联动") }
        sdn.rows.removeAll { $0[0] == profile.id }
        var fields = ["sdn_rl":sdn.encoded,"sdn_rl_x":"<" + row.joined(separator: ">"),prefix + "enable":"0",prefix + "disabled":"0"]
        for (key,index) in [("vlan_rl",3),("subnet_rl",4)] {
            let reference = index == 0 ? profile.id : row[index]
            var table = try LosslessRuleTable(v[key] ?? "")
            if reference != "0" {
                let removed = table.rows.filter { $0.first == reference }
                if !removed.isEmpty && index != 0 && sdn.rows.contains(where: { $0[index] == reference }) { throw RouterError.validation("网络资源仍被其他配置引用，已停止删除") }
                table.rows.removeAll { $0.first == reference }
                fields[key] = table.encoded
                fields[key + "_x"] = removed.map { "<" + $0.joined(separator: ">") }.joined()
            }
        }
        let ownSecurity = try LosslessRuleTable(v[prefix + "security"] ?? "", minimumColumns: 5)
        let referencedRadius = Set(ownSecurity.rows.map { $0[4] }.filter { $0 != "0" && !$0.isEmpty })
        var otherRadius = Set<String>()
        for other in sdn.rows where other[0] != "0" {
            let security = try LosslessRuleTable(v[SDNSnapshot.prefix(other) + "security"] ?? "", minimumColumns: 5)
            otherRadius.formUnion(security.rows.map { $0[4] })
        }
        var radius = try LosslessRuleTable(v["radius_list"] ?? "", minimumColumns: 1)
        let removedRadius = radius.rows.filter { referencedRadius.contains($0[0]) && !otherRadius.contains($0[0]) }
        radius.rows.removeAll { referencedRadius.contains($0[0]) && !otherRadius.contains($0[0]) }
        fields["radius_list"] = radius.encoded
        fields["radius_list_x"] = removedRadius.map { "<" + $0.joined(separator: ">") }.joined()
        var access = try LosslessRuleTable(v["sdn_access_rl"] ?? "", minimumColumns: 2)
        access.rows.removeAll { $0[0] == profile.id || $0[1] == profile.id }; fields["sdn_access_rl"] = access.encoded
        if row[4] != "0" { fields["dhcpres\(row[4])_rl"] = ""; fields["dot\(row[4])_rl"] = "" }
        var service = "start_sdn_del;restart_wireless;"
        if v["qos_enable"] == "1" { service += "restart_qos;restart_firewall;" }
        let checkedKeys = ["sdn_rl","subnet_rl","vlan_rl","radius_list","sdn_access_rl","qos_enable","vlan_trunklist",prefix + "dut_list"] + v.keys.filter { $0.hasSuffix("_security") }
        let expected = Dictionary(uniqueKeysWithValues: Set(checkedKeys).map { ($0, v[$0] ?? "") })
        var plan = SDNPlan(fields: fields, expected: expected, service: service, summary: "删除网络“\(profile.ssid)”及它独占的子网规则", wait: 20)
        plan.changes = SDNPlanChange.describe(fields, current: v)
        return plan
    }
    public static func edit(_ profile: SDNProfile, snapshot: SDNSnapshot) throws -> SDNPlan {
        guard let original = snapshot.profiles.first(where: { $0.id == profile.id }) else { throw RouterError.validation("网络不存在，请重新读取") }
        guard original.listedOnWebPage else { throw RouterError.validation(SDNSecurity.unlistedNote) }
        if original == profile { throw RouterError.validation("没有需要保存的修改") }
        try validateProfile(profile)
        if original.wifi7 != profile.wifi7 {
            guard SDNWiFi7.isOffered(original, supported: snapshot.wifi7Supported) else { throw RouterError.validation("路由器网页没有为这个网络提供 WiFi7 模式开关。") }
            guard !original.mloFronthaul else { throw RouterError.validation(SDNWiFi7.mloHint) }
        }
        // The page rebuilds every band's auth and encryption from one choice when either or WiFi7 模式 changes (9145–9197).
        let linked = original.auth != profile.auth || original.crypto != profile.crypto || original.wifi7 != profile.wifi7
        if linked {
            guard original.standardSecurity else { throw RouterError.validation(SDNSecurity.nonstandardNote) }
            try SDNSecurity.validate(profile, previous: original)
        }
        let values = snapshot.values
        var sdn = try LosslessRuleTable(values["sdn_rl"] ?? "", minimumColumns: 16)
        guard let row = sdn.rows.first(where: { $0[0] == profile.id }) else { throw RouterError.validation("找不到网络索引") }
        if row[3] != "0" && profile.vlan.isEmpty || row[4] != "0" && profile.address.isEmpty { throw RouterError.validation("独立网络的地址与 VLAN 不能为空") }
        if row[11] != "0" { throw RouterError.validation("门户网络包含认证联动，当前原生适配尚未覆盖") }
        if profile.isMain && !profile.enabled { throw RouterError.validation("主网络必须保持启用") }
        let prefix = SDNSnapshot.prefix(row)
        var fields: [String: String] = [:]
        var sdnEdits: [Int: String] = [:]
        if original.enabled != profile.enabled { sdnEdits[2] = profile.enabled ? "1" : "0"; fields[prefix + "enable"] = profile.enabled ? "1" : "0" }
        if original.vpn != profile.vpn { sdnEdits[6] = profile.vpn; sdnEdits[7] = "0" }
        if original.killSwitch != profile.killSwitch { sdnEdits[14] = profile.killSwitch ? "1" : "0" }
        if original.allowRouter != profile.allowRouter { sdnEdits[15] = profile.allowRouter ? "1" : "0" }
        if !sdnEdits.isEmpty { try sdn.replace(id: profile.id, values: sdnEdits, minimum: 16); fields["sdn_rl"] = sdn.encoded }
        if original.ssid != profile.ssid { fields[prefix + "ssid"] = profile.ssid }
        if original.hidden != profile.hidden { fields[prefix + "hide_ssid"] = profile.hidden ? "1" : "0" }
        if original.isolated != profile.isolated { fields[prefix + "ap_isolate"] = profile.isolated ? "1" : "0" }
        if original.wifi7 != profile.wifi7 { fields[prefix + "11be"] = profile.wifi7 ? "1" : "0" }
        if linked || original.password != profile.password {
            var security = try LosslessRuleTable(values[prefix + "security"] ?? "", minimumColumns: 5)
            guard !security.rows.isEmpty else { throw RouterError.validation("网络安全规则尚未读取") }
            let open = ["open", "owe"].contains(profile.auth)
            for index in security.rows.indices {
                // 6 GHz always uses SAE, or OWE for an open network (9146, 9151–9156, 9190, 9195–9196).
                let band6 = ["16", "96"].contains(security.rows[index][0])
                if linked {
                    security.rows[index][1] = band6 ? (open ? "owe" : "sae") : profile.auth
                    security.rows[index][2] = profile.crypto
                }
                security.rows[index][3] = open ? "" : profile.password
            }
            if security.encoded != values[prefix + "security"] { fields[prefix + "security"] = security.encoded }
        }
        var subnet = try LosslessRuleTable(values["subnet_rl"] ?? "", minimumColumns: 13)
        let pairs: [(Int, String, String)] = [(2, original.address, profile.address), (3, original.mask, profile.mask), (4, original.dhcp ? "1" : "0", profile.dhcp ? "1" : "0"), (5, original.start, profile.start), (6, original.end, profile.end), (7, original.lease, profile.lease), (9, original.dns, profile.dns)]
        var subEdits = Dictionary(uniqueKeysWithValues: pairs.filter { $0.1 != $0.2 }.map { ($0.0, $0.2) })
        if original.reservations != profile.reservations {
            try validateReservations(profile)
            fields["dhcpres\(row[4])_rl"] = profile.reservations
            subEdits[11] = profile.reservations.isEmpty ? "0":"1"; subEdits[12] = profile.reservations.isEmpty ? "":row[4]
        }
        if !subEdits.isEmpty {
            guard !sdn.rows.contains(where: { $0[0] != profile.id && $0[4] == row[4] }) else { throw RouterError.validation("此子网被其他网络共用，已停止单独修改") }
            if original.address != profile.address || original.mask != profile.mask {
                var existing = subnet.rows.filter { $0[0] != row[4] }.map { ($0[2],$0[3]) } + [(values["lan_ipaddr"] ?? "",values["lan_netmask"] ?? "")]
                for unit in 0...1 { if let ip = values["wan\(unit)_ipaddr"], !ip.isEmpty && ip != "0.0.0.0" { existing.append((ip, values["wan\(unit)_netmask"] ?? "")) } }
                for (address, mask) in existing { if try overlap(profile.address, profile.mask, address, mask) { throw RouterError.validation("修改后的子网与已有网络或 WAN 地址重叠") } }
                try validateReservations(profile)
            }
            guard row[4] != "0" else { throw RouterError.validation("此网络共用主局域网，请在局域网设置中修改地址") }
            try subnet.replace(id: row[4], values: subEdits, minimum: 13); fields["subnet_rl"] = subnet.encoded
        }
        if original.vlan != profile.vlan {
            guard !sdn.rows.contains(where: { $0[0] != profile.id && $0[3] == row[3] }) else { throw RouterError.validation("此 VLAN 被其他网络共用，已停止单独修改") }
            guard row[3] != "0" else { throw RouterError.validation("此网络共用主局域网，没有独立 VLAN") }
            var vlan = try LosslessRuleTable(values["vlan_rl"] ?? "", minimumColumns: 2)
            guard !vlan.rows.contains(where: { $0[0] != row[3] && $0[1] == profile.vlan }) else { throw RouterError.validation("VLAN ID 已被其他网络使用") }
            try vlan.replace(id: row[3], values: [1: profile.vlan], minimum: 2); fields["vlan_rl"] = vlan.encoded
            if !(values["vlan_trunklist"] ?? "").isEmpty { throw RouterError.validation("该网络有交换机端口绑定，VLAN 变更需同时适配端口映射") }
        }
        if original.allowLAN != profile.allowLAN {
            var access = try LosslessRuleTable(values["sdn_access_rl"] ?? "", minimumColumns: 2)
            access.rows.removeAll { ($0[0] == "0" && $0[1] == profile.id) || ($0[1] == "0" && $0[0] == profile.id) }
            if profile.allowLAN { access.rows.append(["0", profile.id]) }
            fields["sdn_access_rl"] = access.encoded
        }
        if fields.keys.contains(where: { $0.hasPrefix(prefix) }), sdn.rows.contains(where: { $0[0] != profile.id && $0[0] != "0" && SDNSnapshot.prefix($0) == prefix }) { throw RouterError.validation("这项无线配置被其他网络共用，已停止单独修改") }
        let dut = try LosslessRuleTable(values[prefix + "dut_list"] ?? "", minimumColumns: 2)
        let ports = dut.rows.contains { $0.count > 2 && !$0[2].isEmpty }
        // Port bindings and VLAN trunks need the full LAN restart the web page uses, which takes as long either way.
        let wholeNetwork = ports || !(values["vlan_trunklist"] ?? "").isEmpty
        var service = wholeNetwork ? "restart_net_and_phy;" : "restart_wireless;restart_sdn \(profile.id);"
        if values["qos_enable"] == "1" { service += "restart_qos;restart_firewall;" }
        guard !fields.isEmpty else { throw RouterError.validation("没有需要保存的修改") }
        let expected = Dictionary(uniqueKeysWithValues: Set(Array(fields.keys) + ["sdn_rl", "vlan_rl", "subnet_rl", "vlan_trunklist", prefix + "security", prefix + "dut_list", prefix + "11be", prefix + "mlo", "qos_enable", "dhcpres\(row[4])_rl", "lan_ipaddr", "lan_netmask"]).map { ($0, values[$0] ?? "") })
        var plan = SDNPlan(fields: fields, expected: expected, service: service, summary: "保存网络“\(profile.ssid)”的 \(fields.count) 项修改", wait: wholeNetwork ? 35 : 15, restartsWholeNetwork: wholeNetwork)
        plan.changes = SDNPlanChange.describe(fields, current: values)
        plan.warnings = warnings(from: original, to: profile)
        return plan
    }
    /// What a save can do to connected devices beyond the restart itself.
    static func warnings(from original: SDNProfile?, to profile: SDNProfile) -> [String] {
        var result: [String] = []
        if let original, original.wifi7 != profile.wifi7 {
            result.append("切换 WiFi7 模式会重新启动这个网络的 Wi-Fi，连接它的设备都会断开，再重新连接。")
        }
        if original.map({ $0.auth != profile.auth || $0.crypto != profile.crypto }) ?? false {
            result.append("认证或加密方式改变后，不支持新方式的设备可能连不上，例如只支持 WPA2 的设备连不上 WPA3-Personal 或 OWE 网络，较旧的设备可能不支持 GCMP-256。")
        }
        if let original, original.password != profile.password, !["open", "owe"].contains(profile.auth) {
            result.append("密码修改后，所有设备需要输入新密码重新连接。")
        }
        return result
    }
}

extension RouterClient {
    public func sdnSnapshot() async throws -> SDNSnapshot {
        var values = try await readSettings(["sdn_rl", "subnet_rl", "vlan_rl", "radius_list", "sdn_access_rl", "vlan_trunklist", "qos_enable", "qos_type", "mld_enable", "lan_ipaddr", "lan_netmask", "lan_hwaddr", "wan0_ipaddr", "wan0_netmask", "wan1_ipaddr", "wan1_netmask"])
        let table = try LosslessRuleTable(values["sdn_rl"] ?? "", minimumColumns: 16)
        let suffixes = ["enable", "ssid", "hide_ssid", "security", "bw_limit", "timesched", "sched", "expiretime", "ap_isolate", "macmode", "mlo", "maclist", "iot_max_cmpt", "dut_list", "11be", "disabled"]
        let keys = table.rows.filter { $0[0] != "0" }.flatMap { row in suffixes.map { SDNSnapshot.prefix(row) + $0 } + (row[4] == "0" ? [] : ["dhcpres\(row[4])_rl"]) }
        values.merge(try await readSettings(keys)) { _, latest in latest }
        var snapshot = try SDNSnapshot(values: values)
        // state.js fills ui_support from the same get_ui_support(); without it the switch stays hidden.
        if let support = try? await uiCapabilities() { snapshot.wifi7Supported = !["", "0"].contains(support["wifi7"] ?? "") }
        return snapshot
    }
    public func applySDN(_ plan: SDNPlan) async throws -> ApplyReceipt {
        try acquireMutation(); defer { releaseMutation() }
        let current = try await readSettings(Array(plan.expected.keys))
        guard current == plan.expected else { throw RouterError.validation("网络配置已被其他操作改变，请重新读取后再保存") }
        var fields = plan.fields; fields["action_mode"] = "apply"; fields["rc_service"] = plan.service
        do { _ = try await submitApply(fields) }
        catch RouterError.submissionUncertain(let message) { return ApplyReceipt(verified: [], unverified: Array(plan.fields.keys), message: message) }
        do {
            try await Task.sleep(for: .seconds(plan.wait))
            let persistent = plan.fields.filter { !["sdn_rl_x", "vlan_rl_x", "subnet_rl_x", "radius_list_x"].contains($0.key) }
            let after = try await readSettings(Array(persistent.keys))
            let confirmed = persistent.keys.filter { after[$0] == plan.fields[$0] }
            let remaining = persistent.keys.filter { after[$0] != plan.fields[$0] }
            return ApplyReceipt(verified: confirmed, unverified: remaining, message: remaining.isEmpty ? "已从路由器重新读取，网络修改已确认保存。" : "路由器已响应，部分网络设置尚未确认一致。")
        } catch { return ApplyReceipt(verified: [], unverified: Array(plan.fields.keys), message: "请求已接收，等待网络恢复后重新读取确认。") }
    }
}
