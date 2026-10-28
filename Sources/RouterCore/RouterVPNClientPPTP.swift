import Foundation

// VPN › VPN 客户端 › PPTP/L2TP（Advanced_VPNClient_Content.asp 在 iframe 中载入 VPN/vpnc.html），按 Asuswrt-Merlin 3006.102.5：
// 打开时读取与绘制的内容、每 5 秒的状态（check_profile_status 2300–2456）、新增与编辑的校验和提示，以及开关、保存、删除、
// “适用于所有设备”与设备分配发出的 httpApi.nvramSet。普通客户端与 VPN Fusion（isSupport("real_vpn_fusion")）两条分支都照源码。
// 本分支把 WireGuard、Surfshark、NordVPN、CyberGhost 固定为 false（89–103），新增只有 PPTP 和 L2TP（1083–1094）；列表中其他
// 协议的旧条目照样解析、显示、开关和删除。行号均指 VPN/vpnc.html。

// MARK: - Script values

// ToBoolean for a JSON value is `javaScriptTruthy` (RouterParentalShared.swift).

/// `a == b` for the page's text, number or undefined (nil) values: undefined equals only undefined; text and a number
/// compare as numbers.
func javaScriptLooselyEqual(_ a: OrderedJSON?, _ b: OrderedJSON?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case (.string(let x)?, .string(let y)?): return x == y
    case (.string(let x)?, .number(let y)?), (.number(let x)?, .string(let y)?), (.number(let x)?, .number(let y)?):
        guard let left = javaScriptNumber(x), let right = javaScriptNumber(y) else { return false }
        return left == right
    default: return false
    }
}

/// The bytes an nvram_char_to_ascii answer stands for: each %XX as that byte, other characters as their UTF-8 (as
/// DualWANPage.bytes reads them).
func charToAsciiBytes(_ encoded: String) -> [UInt8] {
    let units = Array(encoded.utf8)
    func hex(_ unit: UInt8) -> UInt8? {
        switch unit {
        case 0x30...0x39: unit - 0x30
        case 0x41...0x46: unit - 0x37
        case 0x61...0x66: unit - 0x57
        default: nil
        }
    }
    var bytes: [UInt8] = [], index = 0
    while index < units.count {
        if units[index] == 0x25, index + 2 < units.count, let high = hex(units[index + 1]), let low = hex(units[index + 2]) {
            bytes.append(high << 4 | low); index += 3
        } else {
            bytes.append(units[index]); index += 1
        }
    }
    return bytes
}

/// httpApi.nvramGet (js/httpApi.js 50–104) as this page uses it. The names not read yet (all of them with forceUpdate) go out
/// in one appGet.cgi request, each answered by nvram_get for a browser between quotes (aspNvramText: `"`, `&`, `<`, `>` and
/// bytes outside printable ASCII as "&#" and the number, a backslash as it is). The answer is parsed as JSON: a backslash
/// that starts no JSON escape fails it, every name asked then reads "" and nothing is kept; otherwise the values are kept
/// for later calls (cachedData).
struct NvramGetCache: Sendable, Equatable {
    private(set) var values: [String: String] = [:]
    mutating func get(_ names: [String], force: Bool, encoded: [String: String]) -> [String: String] {
        if force { for name in names { values[name] = nil } }
        let asked = names.filter { values[$0] == nil }
        if !asked.isEmpty {
            let answer = "{\n" + asked.map { "\"\($0)\":\"" + aspNvramText(charToAsciiBytes(encoded[$0] ?? "")) + "\"" }.joined(separator: ",\n") + "\n}\n"
            if let object = try? OrderedJSON(data: Data(answer.utf8)) {
                for name in asked { values[name] = object[name]?.text ?? "" }
            }
        }
        return Dictionary(names.map { ($0, values[$0] ?? "") }, uniquingKeysWith: { first, _ in first })
    }
}

// MARK: - Profiles

/// One profile of vpnc_clientlist as update_vpnc_clientlist_json (3383–3436) builds it (vpnc_profile_attr 180–197, then
/// JSON.parse(JSON.stringify(…))): a field the entry lacks is undefined (nil) and is written back as "undefined".
public struct VPNClientProfile: Sendable, Equatable, Identifiable {
    public var desc: String?
    public var proto: String?
    public var server: String?
    public var username: String?
    public var passwd: String?
    /// vpnc_pptp_options_x_list at the entry's split index + 1, "auto" when missing or empty; undefined after an edit
    /// whose PPTP option list had nothing selected.
    public var pptpOptions: String?
    /// The position among the non-empty entries: the list's order, and vpnc_unit for Fusion.
    public let idx: Int
    /// Fusion: the sixth field is "1". Otherwise whether check_profile_status found the profile connected.
    public var activate = false
    /// Fusion: the seventh field (nil when missing), or get_new_vpnc_index for a new profile; the number 0 otherwise.
    public var vpncIndex: OrderedJSON? = .number("0")
    /// Fusion: get_vpnc_nondef_wan_prof_list gives the profile flag "0"; and whether vpnc_default_wan names it.
    public var defaultWANSupported = false
    public var defaultWANSelected = false
    /// Fusion: the eighth field (nil when missing); "" otherwise.
    public var region: String? = ""
    public var tunnel = "0"
    public var wanIndex = "0"
    public var caller = "Web"
    public var id: Int { idx }

    public init(desc: String?, proto: String?, server: String?, username: String?, passwd: String?, pptpOptions: String?, idx: Int) {
        self.desc = desc; self.proto = proto; self.server = server; self.username = username; self.passwd = passwd
        self.pptpOptions = pptpOptions; self.idx = idx
    }

    /// vpnc_idx as `+` writes it into a text.
    public var vpncIndexText: String { vpncIndex.map(TORSettings.javaScriptString) ?? "undefined" }
    func hasIndex(_ text: String?) -> Bool { javaScriptLooselyEqual(vpncIndex, text.map(OrderedJSON.string)) }
    /// PPTP or L2TP: the protocols this page's settings edit.
    public var editable: Bool { ["pptp", "l2tp"].contains(proto?.lowercased() ?? "") }
    /// The item's title attribute (374): the HTML-encoded name, written as it is.
    public var nameTitle: String { "连接名称: " + (desc.map(TORSettings.htmlEncode) ?? "undefined") }

    /// The profiles of the decoded lists (3402–3434); the default-connection facts only for Fusion.
    static func profiles(_ list: String, options: String, fusion: Bool, defaultSupport: [String: Bool], defaultWAN: String) -> [VPNClientProfile] {
        let optionList = options.components(separatedBy: "<")
        var profiles: [VPNClientProfile] = []
        for (index, value) in list.components(separatedBy: "<").enumerated() where !value.isEmpty {
            let fields = value.components(separatedBy: ">")
            func field(_ at: Int) -> String? { at < fields.count ? fields[at] : nil }
            let option = index + 1 < optionList.count ? optionList[index + 1] : ""
            var profile = VPNClientProfile(desc: fields[0], proto: field(1), server: field(2), username: field(3), passwd: field(4),
                                           pptpOptions: option.isEmpty ? "auto" : option, idx: profiles.count)
            if fusion {
                profile.activate = field(5) == "1"
                profile.vpncIndex = field(6).map(OrderedJSON.string)
                profile.defaultWANSupported = defaultSupport[field(6) ?? "undefined"] ?? false
                profile.defaultWANSelected = field(6) == defaultWAN
                profile.region = field(7)
            }
            profile.tunnel = field(9) ?? "0"
            profile.wanIndex = field(10) ?? "0"
            profile.caller = field(11) ?? "Web"
            profiles.append(profile)
        }
        return profiles
    }

    /// get_vpnc_support_default_wan (3384–3398): "vpnc_idx>flag" between "<"; flag "0" supports the default connection.
    static func defaultSupport(_ list: String) -> [String: Bool] {
        var support: [String: Bool] = [:]
        for pair in list.components(separatedBy: "<") {
            let parts = pair.components(separatedBy: ">")
            support[parts[0]] = parts.count > 1 && parts[1] == "0"
        }
        return support
    }

    /// parse_JSONToStr_vpnc_clientlist (3534–3572): `desc>proto>server>username>passwd>active>vpnc_idx>region>>tunnel>wan_idx>caller`
    /// between "<" (active and vpnc_idx empty without Fusion), and "<" before each PPTP option.
    public static func lists(_ profiles: [VPNClientProfile], fusion: Bool) -> (clientlist: String, options: String) {
        var list = "", options = ""
        for item in profiles {
            if !list.isEmpty { list += "<" }
            list += [item.desc, item.proto, item.server, item.username, item.passwd].map { $0 ?? "undefined" }.joined(separator: ">") + ">"
            list += fusion ? (item.activate ? "1" : "0") : ""
            list += ">" + (fusion ? item.vpncIndexText : "")
            list += ">" + (item.region ?? "undefined") + ">"
            list += ">" + item.tunnel + ">" + item.wanIndex + ">" + item.caller
            options += "<" + (item.pptpOptions ?? "undefined")
        }
        return (list, options)
    }
}

// MARK: - Fusion device rules

/// dhcp_staticlist_json's member for one IP.
public struct VPNClientBinding: Sendable, Equatable {
    public let ip: String
    public var mac: String
    public var dns: String
    public var hostname: String
}

/// One row of vpnc_dev_policy_list (vpnc_dev_policy_attr 198–207) with its DHCP binding's MAC, DNS and host name.
public struct VPNClientRule: Sendable, Equatable {
    public var activate: String
    public var ip: String
    public var destIP = ""
    public var vpncIndex: String
    public var brifname = ""
    public var mac = ""
    public var dns = ""
    public var hostname = ""
    /// The VPN Wi-Fi rules (ig_site2site): br1 is the 2.4 GHz guest network, br2 the 5 GHz one.
    public var wireless: Bool { brifname == "br1" || brifname == "br2" }
}

/// The Fusion device rules as update_vpnc_dev_policy_list_json (3437–3479) reads them, with the texts it read
/// (vpnc_dev_policy_ori_data), which saving compares against.
public struct VPNClientPolicies: Sendable, Equatable {
    /// dhcp_staticlist_json in the order its members were added.
    public var bindings: [VPNClientBinding]
    public var rules: [VPNClientRule]
    public let readDHCP: String
    public let readRules: String

    func binding(_ ip: String) -> VPNClientBinding? { bindings.first { $0.ip == ip } }
    mutating func bind(_ binding: VPNClientBinding) {
        if let at = bindings.firstIndex(where: { $0.ip == binding.ip }) { bindings[at] = binding } else { bindings.append(binding) }
    }
    /// Object.keys(dhcp_staticlist_json): index-like IPs first, then in the order added.
    var orderedBindings: [VPNClientBinding] { JavaScriptKeys.ordered(bindings.map(\.ip)).compactMap(binding) }
    /// The bindings as the page writes dhcp_staticlist (2967–2970, 932–935): "<" before each row.
    public var dhcpList: String { orderedBindings.map { "<" + $0.mac + ">" + $0.ip + ">" + $0.dns + ">" + $0.hostname }.joined() }
    /// parse_JSONToStr_vpnc_dev_policy_list (3573–3593): `enable>sourceIP>destIP>vpnc_idx>brifname` between "<".
    public var ruleList: String { rules.map { [$0.activate, $0.ip, $0.destIP, $0.vpncIndex, $0.brifname].joined(separator: ">") }.joined(separator: "<") }

    /// update_vpnc_dev_policy_list_json from the two nvram_char_to_ascii answers; nil where it throws: a list that
    /// decodeURIComponent rejects (dhcp_staticlist is decoded a second time, 3444), or a VPN Wi-Fi rule with an IP that
    /// has no binding (`.mac` of undefined, 3470). A rule needs four fields and a binding for its IP or br1/br2.
    static func read(dhcp encodedDHCP: String, rules encodedRules: String) -> VPNClientPolicies? {
        guard let dhcp = SiteSurvey.decodeURIComponent(encodedDHCP) else { return nil }
        var parsed = VPNClientPolicies(bindings: [], rules: [], readDHCP: dhcp, readRules: "")
        if !dhcp.isEmpty {
            guard let twice = SiteSurvey.decodeURIComponent(dhcp) else { return nil }
            for row in twice.components(separatedBy: "<").dropFirst() {
                let columns = row.components(separatedBy: ">")
                func column(_ at: Int) -> String? { at < columns.count ? columns[at] : nil }
                parsed.bind(VPNClientBinding(ip: column(1) ?? "undefined", mac: columns[0].uppercased(), dns: column(2) ?? "", hostname: column(3) ?? ""))
            }
        }
        guard let text = SiteSurvey.decodeURIComponent(encodedRules) else { return nil }
        var rules: [VPNClientRule] = []
        for value in text.components(separatedBy: "<") where !value.isEmpty {
            let fields = value.components(separatedBy: ">")
            guard fields.count >= 4 else { continue }
            let brifname = fields.count > 4 ? fields[4] : nil
            guard parsed.binding(fields[1]) != nil || brifname == "br1" || brifname == "br2" else { continue }
            var rule = VPNClientRule(activate: fields[0], ip: fields[1], destIP: fields[2], vpncIndex: fields[3], brifname: brifname ?? "")
            if !fields[1].isEmpty {
                guard let binding = parsed.binding(fields[1]) else { return nil }
                rule.mac = binding.mac; rule.dns = binding.dns; rule.hostname = binding.hostname
            }
            rules.append(rule)
        }
        return VPNClientPolicies(bindings: parsed.bindings, rules: rules, readDHCP: dhcp, readRules: text)
    }

    /// One device of a profile's list (switch mode, Get_Component_Client_List_Item 1284–1389): the rule its switch changes
    /// (the first rule with the device's MAC), the name (nickName, else name) and IP from clientList, or the MAC and the
    /// rule's IP for a device it does not have.
    public struct Device: Sendable, Equatable, Identifiable {
        public let id: Int
        public let rule: Int
        public let name: String
        public let ip: String
        public let on: Bool
    }
    /// The rules of a profile ("0" for 互联网) by inet_network of their IP, the VPN Wi-Fi rules left out (905–917, 2757–2769).
    public func devices(of index: String?, clients: [TORSettings.ClientEntry]) -> [Device] {
        var devices: [Device] = []
        for item in Self.byAddress(rules, \.ip) where javaScriptLooselyEqual(.string(item.vpncIndex), index.map(OrderedJSON.string)) {
            guard let at = rules.firstIndex(where: { $0.mac == item.mac }), !rules[at].wireless else { continue }
            let rule = rules[at]
            let client = clients.first { $0.mac == rule.mac }
            devices.append(Device(id: devices.count, rule: at, name: client.map { $0.nickName.isEmpty ? $0.name : $0.nickName } ?? rule.mac,
                                  ip: client?.ip ?? rule.ip, on: javaScriptLooselyEquals(rule.activate, 1)))
        }
        return devices
    }
    /// The device switch (1345–1356): "1" becomes "0", anything else "1"; only the page's rules change.
    public mutating func toggle(_ rule: Int) {
        guard rules.indices.contains(rule) else { return }
        rules[rule].activate = rules[rule].activate == "1" ? "0" : "1"
    }

    /// One row of the 设备 list (Get_Component_Setting_Client_Policy 1393–1428).
    public struct Choice: Sendable, Equatable, Identifiable {
        public let id: Int
        public let mac: String
        public let ip: String
        public let name: String
        /// A rule for the IP: this profile's (checked) or another's (disabled).
        public let checked: Bool
        public let taken: Bool
    }
    /// clientList by inet_network of the IP (a stable sort), without empty entries, AiMesh nodes and offline devices.
    public func choices(for index: String?, clients: [TORSettings.ClientEntry]) -> [Choice] {
        var choices: [Choice] = []
        for client in Self.byAddress(clients, \.ip) where !client.mac.isEmpty && !client.meshNode && client.ip != "offline" {
            let rule = rules.first { $0.ip == client.ip }
            let mine = rule.map { javaScriptLooselyEqual(.string($0.vpncIndex), index.map(OrderedJSON.string)) } ?? false
            choices.append(Choice(id: choices.count, mac: client.mac, ip: client.ip, name: client.nickName.isEmpty ? client.name : client.nickName,
                                  checked: mine, taken: rule != nil && !mine))
        }
        return choices
    }

    static let bindingLimit = "您的规则已达到最大数量。 手动指定 IP 的 DHCP 列表 (最多限制： 64) 如果您想添加新规则，请删除不使用的规则。"
    /// The device list's 确认 (1432–1522), the checked devices in list order: an IP without a binding gets one with the
    /// device's MAC; 64 bindings or more stop it with the alert. New IPs get a rule ("1", the binding's MAC); this profile's
    /// rules for IPs no longer checked go, its VPN Wi-Fi rules stay. Nothing is sent: 应用 does that.
    public func assigning(_ checked: [Choice], to index: String?) -> Result<VPNClientPolicies, VPNClientAlert> {
        var updated = self
        updated.bindings = orderedBindings
        var chosen: [VPNClientRule] = []
        for choice in checked {
            if updated.binding(choice.ip) == nil { updated.bind(VPNClientBinding(ip: choice.ip, mac: choice.mac.uppercased(), dns: "", hostname: "")) }
            let binding = updated.binding(choice.ip)!
            chosen.append(VPNClientRule(activate: "1", ip: choice.ip, vpncIndex: index ?? "undefined", mac: binding.mac, dns: binding.dns, hostname: binding.hostname))
        }
        if updated.bindings.count >= 64 { return .failure(VPNClientAlert(Self.bindingLimit)) }
        for rule in chosen where !updated.rules.contains(where: { $0.ip == rule.ip }) { updated.rules.append(rule) }
        updated.rules = updated.rules.filter { rule in
            guard javaScriptLooselyEqual(.string(rule.vpncIndex), index.map(OrderedJSON.string)) else { return true }
            return rule.wireless || chosen.contains { $0.ip == rule.ip }
        }
        return .success(updated)
    }

    /// Array.prototype.sort with `inet_network(x.ip)` compared (client_function.js 117–132, the same as validator.js's):
    /// a stable sort, -1 for an empty address and -2 for one that is not four decimal parts below 256.
    static func byAddress<Item>(_ items: [Item], _ ip: KeyPath<Item, String>) -> [Item] {
        items.enumerated().sorted { a, b in
            let x = WebValidator.inetNetwork(a.element[keyPath: ip]), y = WebValidator.inetNetwork(b.element[keyPath: ip])
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
    }
}

/// show_customize_alert's text (252–260).
public struct VPNClientAlert: Error, Sendable, Equatable {
    public let message: String
    init(_ message: String) { self.message = message }
    public static let busy = VPNClientAlert("请稍候")
    public static let deactivateToEdit = VPNClientAlert("编辑例外列表前请先终止设置档。")
    public static let deactivateToDelete = VPNClientAlert("删除例外列表前请先终止设置档。")
    public static let duplicate = VPNClientAlert("此项已纳入列表中。")
    public static let noDefault = VPNClientAlert("无法设置为目标策略的默认连接。")
    public static let keepInternetDefault = VPNClientAlert("请选择另一 VPN 配置文件以取消互联网默认 WAN。")
    /// Not the page's text: its script throws there (a profile without a protocol) and nothing is sent.
    public static let stopped = VPNClientAlert("网页的脚本在这里出错停止（这个配置文件没有协议），没有发送请求。")
    /// Not the page's text: initial() stopped on the list itself (see VPNClientPage.writable), so nothing is written.
    public static let listUnavailable = VPNClientAlert("配置列表没有完整读取（网页的脚本读到这些数据会出错），本页只显示说明，不提供新增、开关、保存、删除或其他写入。")
    /// Not the page's text: what a write was prepared on changed before it was sent (see VPNClientBasis).
    public static let stale = VPNClientAlert("准备这项操作期间页面已经改变（另一项操作完成或重新读取），为免用旧的配置列表覆盖路由器，本次没有发送。请在当前页面上重新操作。")
}

// MARK: - Status

/// What the list shows for a profile: the switch, the status text and the error line below it (2300–2456).
public struct VPNClientStatus: Sendable, Equatable {
    public let on: Bool
    public let text: String
    public let error: String?
    public static let off = VPNClientStatus(on: false, text: "未联机", error: nil)

    /// Fusion (2328–2357): "status>reason>vpnc_idx" of get_vpnc_status; an active profile without an entry shows nothing.
    static func fusion(_ entry: [String]?) -> VPNClientStatus {
        guard let entry else { return VPNClientStatus(on: true, text: "", error: nil) }
        switch entry[0] {
        case "5": return VPNClientStatus(on: true, text: "未联机", error: nil)
        case "0", "4", "6":
            switch entry.count > 1 ? entry[1] : nil {
            case "0": return VPNClientStatus(on: true, text: "正在初始化，请稍候", error: nil)
            case "1", "7": return VPNClientStatus(on: true, text: "连接失败", error: "IP / 路由冲突")
            case "2": return VPNClientStatus(on: true, text: "连接失败", error: "授权失败")
            default: return VPNClientStatus(on: true, text: "其他", error: nil)
            }
        case "1": return VPNClientStatus(on: true, text: "正在连接…", error: nil)
        case "2": return VPNClientStatus(on: true, text: "已联机", error: nil)
        default: return VPNClientStatus(on: true, text: "", error: nil)
        }
    }
    /// PPTP/L2TP without Fusion (2416–2429): vpnc_state_t and vpnc_sbstate_t compared with numbers ("" counts as 0).
    static func pptp(state: String?, sub: String?) -> VPNClientStatus {
        func equals(_ text: String?, _ number: Double) -> Bool { javaScriptLooselyEquals(text, number) }
        if equals(state, 0) || equals(state, 1) || (equals(state, 4) && equals(sub, 0)) { return VPNClientStatus(on: true, text: "正在连接…", error: nil) }
        if equals(state, 2) { return VPNClientStatus(on: true, text: "已联机", error: nil) }
        if equals(state, 4) && equals(sub, 2) { return VPNClientStatus(on: true, text: "连接失败", error: "授权失败") }
        if equals(state, 4) && equals(sub, 7) { return VPNClientStatus(on: true, text: "连接失败", error: "IP / 路由冲突") }
        return VPNClientStatus(on: true, text: "连接失败", error: nil)
    }
    /// An OpenVPN entry without Fusion (2388–2407): vpn_clientN_state, then vpn_clientN_errno.
    static func openVPN(state: String?, errno: String?) -> VPNClientStatus {
        func equals(_ text: String?, _ number: Double) -> Bool { javaScriptLooselyEquals(text, number) }
        if equals(state, 0) { return VPNClientStatus(on: true, text: "未联机", error: nil) }
        if equals(state, 1) { return VPNClientStatus(on: true, text: "正在连接…", error: nil) }
        if equals(state, 2) { return VPNClientStatus(on: true, text: "已联机", error: nil) }
        if equals(errno, 1) || equals(errno, 2) || equals(errno, 3) { return VPNClientStatus(on: true, text: "连接失败", error: "IP / 路由冲突") }
        if equals(errno, 4) || equals(errno, 5) || equals(errno, 6) { return VPNClientStatus(on: true, text: "连接失败", error: "授权失败") }
        if equals(errno, 7) { return VPNClientStatus(on: true, text: "连接失败", error: ".ovpn file error") }
        return VPNClientStatus(on: true, text: "连接失败", error: nil)
    }
}

/// Where initial() stopped, leaving the page as it was drawn so far.
public enum VPNClientStop: Sendable, Equatable {
    /// update_vpnc_clientlist_json threw (a list decodeURIComponent rejects; for Fusion, get_vpnc_nondef_wan_prof_list not
    /// text): the list stays empty and undrawn, no status is read.
    case profiles
    /// update_vpnc_dev_policy_list_json threw (Fusion): nothing is drawn, no status is read.
    case policies
    /// Drawing the list threw at this profile (no protocol: toLowerCase of undefined, 650): the ones before it are drawn,
    /// no status is read.
    case drawing(Int)
    /// check_profile_status threw (get_vpnc_status that decodeURIComponent rejects): the 5-second check never starts.
    case status
}

// MARK: - Basis

/// The configuration a write is built from (VPNClientPage.basis); status texts are not part of it.
public struct VPNClientBasis: Sendable, Equatable {
    let profiles: [VPNClientProfile]
    let defaultWAN: String?
    let policies: VPNClientPolicies?
    let stop: VPNClientStop?
}

// MARK: - Internet (Fusion)

/// httpApi.getWanInfo (js/httpApi.js 824–895) for one WAN.
public struct VPNClientWAN: Sendable, Equatable {
    /// "connected", "disconnected" or "standby".
    public let status: String
    public let statusText: String
    public let ip: String
    public let protoText: String
}

/// The 互联网 item of the list.
public struct VPNClientInternetItem: Sendable, Equatable {
    public let wan: VPNClientWAN
    public let isDefault: Bool
}

/// One status block of the 互联网 card (Get_Component_WAN_Status 831–854).
public struct VPNClientWANBlock: Sendable, Equatable {
    public let title: String
    public let connected: Bool
    public let statusText: String
    public let ipTitle: String
    public let ip: String
    public let proto: String
}

// MARK: - The page

/// VPN/vpnc.html as initial() (4174–4302) leaves it, from what it reads: the profiles, (Fusion) the device rules, the list's
/// switches and status texts, and where its script stopped. The page keeps httpApi's cache of nvram_get answers; a 5-second
/// check (polled) or a fresh read (merging) changes the router's answers, which the page sees where it asks again.
public struct VPNClientPage: Sendable, Equatable {
    /// get_ui_support as the router wrote it: isSupport (168–171) gives the member itself when it is truthy, otherwise 0.
    public let support: OrderedJSON
    /// nvram_char_to_ascii answers, still percent-encoded.
    private(set) var encoded: [String: String]
    /// Hook answers by name; a missing name is undefined.
    private(set) var hooks: [String: OrderedJSON]
    /// `[<% get_operation_mode(); %>][0]` (state.js isSwMode 268–272).
    public let operationMode: String
    /// clientList (genClientList) with, for Fusion, the devices initial() adds from the rules and bindings (4257–4286).
    public private(set) var clients: [TORSettings.ClientEntry]
    public private(set) var profiles: [VPNClientProfile] = []
    /// Fusion: the rules and bindings initial() read.
    public private(set) var policies: VPNClientPolicies?
    public private(set) var stop: VPNClientStop?
    /// What the list shows for each profile, by idx.
    public private(set) var statuses: [Int: VPNClientStatus] = [:]
    /// Fusion: the 互联网 item as the list drew it (Get_Component_Internet_Item 665–706): getWanInfo(0) and whether
    /// vpnc_default_wan is "0".
    public private(set) var internet: VPNClientInternetItem?
    var cache = NvramGetCache()

    public init(support: OrderedJSON, encoded: [String: String], hooks: [String: OrderedJSON], operationMode: String, clients: [TORSettings.ClientEntry]) {
        self.support = support; self.encoded = encoded; self.hooks = hooks; self.operationMode = operationMode; self.clients = clients
        initial()
    }

    // MARK: Capabilities

    func isSupport(_ name: String) -> OrderedJSON { javaScriptTruthy(support[name]) ? support[name]! : .number("0") }
    func supports(_ name: String) -> Bool { javaScriptTruthy(isSupport(name)) }
    public var fusion: Bool { supports("real_vpn_fusion") }
    /// The page's title (4213).
    public var title: String { fusion ? "VPN Fusion" : "VPN 客户端" }
    /// vpnc_maximum (73–75).
    public var maximum: Int { fusion ? 16 : 10 }
    /// vpnc_activate_maximum (72): 2 when isSupport gives 0 or "0", otherwise parseInt of it (NaN for text without digits).
    var activeMaximum: Double {
        let value = isSupport("MaxRule_VPN_FUSION_Conn")
        return javaScriptLooselyEqualsText(value, "0") ? 2 : (SiteSurvey.parseInt(value) ?? .nan)
    }
    /// vpnc_conn_maxi_general_note (79).
    public var activeLimitNote: String { "由于并发活动 VPN 连接数上限最大为 \(javaScriptText(activeMaximum))。请先停用一个现用 VPN 连接后再启用另一个。" }
    /// weekSche_MAX_Num (304, 1013, 4197).
    public var listLimitNote: String { "规则的最大数量为 \(maximum)。" }
    /// support_ig_s2s (105): the VPN Wi-Fi interface, which needs ig_site2site without mtlancfg.
    public var instantGuard: Bool { !supports("mtlancfg") && supports("ig_site2site") }
    /// faq_href (67), the help's VPN Fusion 疑难解答 link (214–217), ui_lang from preferred_lang (state.js 979).
    public var troubleshooting: URL? { AsusSupportLink.faq("167", lang: aspNvramText(charToAsciiBytes(encoded["preferred_lang"] ?? ""))) }
    /// The value nvram_char_to_ascii stands for.
    public func raw(_ name: String) -> String { String(decoding: charToAsciiBytes(encoded[name] ?? ""), as: UTF8.self) }

    mutating func nvramGet(_ names: [String], force: Bool = false) -> [String: String] { cache.get(names, force: force, encoded: encoded) }

    // MARK: initial()

    private mutating func initial() {
        guard let profiles = loadProfiles() else { stop = .profiles; return }
        self.profiles = profiles
        if fusion {
            guard let policies = VPNClientPolicies.read(dhcp: encoded["dhcp_staticlist"] ?? "", rules: encoded["vpnc_dev_policy_list"] ?? "") else {
                stop = .policies; return
            }
            self.policies = policies
            clients = Self.clients(clients, adding: policies)
            for profile in profiles { statuses[profile.idx] = VPNClientStatus(on: profile.activate, text: "未联机", error: nil) }
            let wan = wanInfo(0)
            internet = VPNClientInternetItem(wan: wan, isDefault: nvramGet(["vpnc_default_wan"])["vpnc_default_wan"] == "0")
        } else {
            // Get_Component_Svr_Item (634–661): the switch from comparing with the running client; the status text 未联机.
            for profile in profiles {
                let on: Bool
                if profile.proto == "OpenVPN" || profile.proto == "CyberGhost" {
                    let running = nvramGet(["vpnc_proto", "vpn_clientx_eas"])
                    let unit = javaScriptReplace(running["vpn_clientx_eas"] ?? "", ",", "")
                    on = ["openvpn", "cyberghost"].contains(running["vpnc_proto"] ?? "") && unit == profile.server
                } else {
                    let running = nvramGet(["vpnc_proto", "vpnc_pppoe_username", "vpnc_pppoe_passwd", "vpnc_heartbeat_x"])
                    guard let proto = profile.proto else { stop = .drawing(profile.idx); return }
                    on = proto.lowercased() == (running["vpnc_proto"] ?? "").lowercased() && profile.server == running["vpnc_heartbeat_x"]
                        && profile.username == running["vpnc_pppoe_username"] && profile.passwd == running["vpnc_pppoe_passwd"]
                }
                self.profiles[profile.idx].activate = on
                statuses[profile.idx] = VPNClientStatus(on: on, text: "未联机", error: nil)
            }
        }
        if !checkProfileStatus() { stop = .status }
    }

    /// update_vpnc_clientlist_json (3383–3436): nil where it throws.
    private mutating func loadProfiles() -> [VPNClientProfile]? {
        guard let list = SiteSurvey.decodeURIComponent(encoded["vpnc_clientlist"] ?? ""),
              let options = SiteSurvey.decodeURIComponent(encoded["vpnc_pptp_options_x_list"] ?? "") else { return nil }
        var support: [String: Bool] = [:], defaultWAN = ""
        if fusion {
            guard case .string(let text)? = hooks["get_vpnc_nondef_wan_prof_list"] else { return nil }
            support = VPNClientProfile.defaultSupport(text)
            defaultWAN = nvramGet(["vpnc_default_wan"], force: true)["vpnc_default_wan"] ?? ""
        }
        return VPNClientProfile.profiles(list, options: options, fusion: fusion, defaultSupport: support, defaultWAN: defaultWAN)
    }

    /// initial() (4257–4286): devices of the rules and bindings that clientList does not have are added under their MAC
    /// (named by it); a known device that is offline takes its binding's IP.
    static func clients(_ base: [TORSettings.ClientEntry], adding policies: VPNClientPolicies) -> [TORSettings.ClientEntry] {
        var clients = base
        for rule in policies.rules where !clients.contains(where: { $0.mac == rule.mac }) {
            clients.append(TORSettings.ClientEntry(mac: rule.mac, name: rule.mac, ip: rule.ip, from: "vpnc_dev_policy"))
        }
        for binding in policies.orderedBindings {
            if let at = clients.firstIndex(where: { $0.mac == binding.mac }) {
                if clients[at].ip == "offline" { clients[at].ip = binding.ip }
            } else {
                clients.append(TORSettings.ClientEntry(mac: binding.mac, name: binding.mac, ip: binding.ip, from: "dhcp_staticlist"))
            }
        }
        return clients
    }

    /// check_profile_status (2300–2456); false where it throws.
    @discardableResult
    mutating func checkProfileStatus() -> Bool {
        if fusion {
            let answer = hooks["get_vpnc_status"].map(TORSettings.javaScriptString) ?? "undefined"
            guard let text = SiteSurvey.decodeURIComponent(answer) else { return false }
            let entries = text.components(separatedBy: "<").filter { !$0.isEmpty }.map { $0.components(separatedBy: ">") }
            for profile in profiles {
                guard profile.activate else { statuses[profile.idx] = .off; continue }
                statuses[profile.idx] = .fusion(entries.first { profile.hasIndex($0.count > 2 ? $0[2] : nil) })
            }
            return true
        }
        let running = nvramGet(["vpnc_proto"])["vpnc_proto"] ?? ""
        for index in profiles.indices { profiles[index].activate = false }
        var status = VPNClientStatus.off, connected: Int?
        if running == "openvpn" || running == "cyberghost" {
            let unit = javaScriptReplace(nvramGet(["vpn_clientx_eas"])["vpn_clientx_eas"] ?? "", ",", "")
            let state = nvramGet(["vpn_client\(unit)_state"], force: true)["vpn_client\(unit)_state"]
            let errno = nvramGet(["vpn_client\(unit)_errno"], force: true)["vpn_client\(unit)_errno"]
            status = .openVPN(state: state, errno: errno)
            // The filter reads every profile's proto.toUpperCase(): one without a protocol throws.
            guard profiles.allSatisfy({ $0.proto != nil }) else { return false }
            connected = profiles.first { $0.proto!.uppercased() == running.uppercased() && $0.server == unit }?.idx
        } else if running == "pptp" || running == "l2tp" {
            let client = nvramGet(["vpnc_pppoe_username", "vpnc_pppoe_passwd", "vpnc_heartbeat_x"])
            let state = nvramGet(["vpnc_state_t", "vpnc_sbstate_t"], force: true)
            status = .pptp(state: state["vpnc_state_t"], sub: state["vpnc_sbstate_t"])
            guard profiles.allSatisfy({ $0.proto != nil }) else { return false }
            connected = profiles.first {
                $0.proto!.uppercased() == running.uppercased() && $0.server == client["vpnc_heartbeat_x"]
                    && $0.username == client["vpnc_pppoe_username"] && $0.passwd == client["vpnc_pppoe_passwd"]
            }?.idx
        }
        for profile in profiles { statuses[profile.idx] = .off }
        if running != "disable", let connected {
            profiles[connected].activate = true
            statuses[connected] = status
        }
        return true
    }

    /// The names a check reads again (the forced reads, and the cached ones a failed answer left unread).
    var statusNames: [String] {
        var copy = self
        var names = ["vpnc_proto", "vpnc_pppoe_username", "vpnc_pppoe_passwd", "vpnc_heartbeat_x", "vpn_clientx_eas", "vpnc_state_t", "vpnc_sbstate_t"]
        if ["openvpn", "cyberghost"].contains(copy.nvramGet(["vpnc_proto"])["vpnc_proto"] ?? "") {
            let unit = javaScriptReplace(copy.nvramGet(["vpn_clientx_eas"])["vpn_clientx_eas"] ?? "", ",", "")
            names += ["vpn_client\(unit)_state", "vpn_client\(unit)_errno"]
        }
        return names
    }

    /// The page with fresh router answers; what it has cached stays.
    public func merging(encoded fresh: [String: String] = [:], hooks freshHooks: [String: OrderedJSON?] = [:]) -> VPNClientPage {
        var page = self
        page.encoded.merge(fresh) { _, new in new }
        for (name, value) in freshHooks { page.hooks[name] = value }
        return page
    }

    /// The 5-second check with fresh answers. After a switch without Fusion the page reads the running client again first
    /// (614–617).
    public func polled(encoded fresh: [String: String] = [:], hooks freshHooks: [String: OrderedJSON?] = [:], refreshingClient: Bool) -> VPNClientPage {
        var page = merging(encoded: fresh, hooks: freshHooks)
        guard page.stop == nil else { return page }
        if refreshingClient, !page.fusion {
            _ = page.nvramGet(["vpnc_proto", "vpnc_pppoe_username", "vpnc_pppoe_passwd", "vpnc_heartbeat_x", "vpn_clientx_eas"], force: true)
        }
        page.checkProfileStatus()
        return page
    }

    // MARK: Writes

    /// Whether the page offers writes. Every write rebuilds the whole vpnc_clientlist from what update_vpnc_clientlist_json
    /// read, which empties the list before decoding it (3399–3401): when initial() stopped at the list, the rules or a
    /// profile it could not draw, the web would write an empty or corrupted list. Such data is shown and explained only. A
    /// list read without error that is empty is writable; a stop at the status check (status) leaves writes as they are.
    public var writable: Bool {
        switch stop {
        case nil, .status?: true
        case .profiles?, .policies?, .drawing?: false
        }
    }

    /// What this page's writes are built from: the profiles (active states included), the cached vpnc_default_wan and the
    /// rules. The web prepares and sends a write within one click (the NAT check's nvramGet is synchronous, vpnc.html
    /// 464–510, httpApi.js 74 `async: false`); here a read or a confirmation comes between, so a write prepared on one basis
    /// is only sent while the page still has it.
    public var basis: VPNClientBasis { VPNClientBasis(profiles: profiles, defaultWAN: cache.values["vpnc_default_wan"], policies: policies, stop: stop) }
    public func stillMatches(_ basis: VPNClientBasis) -> Bool { self.basis == basis }

    // MARK: The list

    /// The tags over a profile (Fusion, 335–348): 默认连接, and VPN WiFi for a profile with a br1/br2 rule.
    public func tags(_ profile: VPNClientProfile) -> [String] {
        guard fusion else { return [] }
        var tags: [String] = []
        if profile.defaultWANSelected { tags.append("默认连接") }
        if instantGuard, policies?.rules.contains(where: { $0.wireless && profile.hasIndex($0.vpncIndex) }) == true { tags.append("VPN WiFi") }
        return tags
    }

    // MARK: getWanInfo

    static let protoNames = ["dhcp": "动态 IP", "static": "静态 IP", "pppoe": "PPPoE", "pptp": "PPTP", "l2tp": "L2TP", "pppoa": "PPPoA", "ipoa": "IPoA",
                             "lw4o6": "LW 4over6", "map-e": "MAP-E", "v6plus": "v6plus", "ocnvc": "OCN Virtual Connect", "dslite": "DS-Lite",
                             "v6opt": "IPv6 Option", "usb modem": "USB Modem"]
    static let wanKeys = ["wans_dualwan", "wans_mode", "sw_mode", "link_internet", "lan_ipaddr", "lan_proto", "usb_modem_act_operation", "dsl0_proto",
                          "dslx_transmode"] + [0, 1].flatMap { ["wan\($0)_state_t", "wan\($0)_sbstate_t", "wan\($0)_auxstate_t", "wan\($0)_ipaddr", "wan\($0)_proto"] }

    mutating func wanInfo(_ index: Int) -> VPNClientWAN {
        let wans = nvramGet(["wans_dualwan", "wans_mode"], force: true)
        let dualWAN = supports("dualwan") && !(wans["wans_dualwan"] ?? "").contains("none")
        let active = hooks["get_wan_unit"]
        let activeIsThis: Bool = {
            switch active {
            case .string(let text)?, .number(let text)?: javaScriptLooselyEquals(text, Double(index))
            case .bool(let on)?: (on ? 1 : 0) == index
            default: false
            }
        }()
        var status: String, statusText: String
        if dualWAN, !activeIsThis, ["fo", "fb"].contains(wans["wans_mode"] ?? "") {
            status = "standby"; statusText = "闲置待机"
        } else {
            status = isConnected(index) ? "connected" : "disconnected"; statusText = status == "connected" ? "已联机" : "联机中断"
        }
        var ip = "", protoText = ""
        if status == "connected" {
            let info = nvramGet(["wan\(index)_ipaddr", "wan\(index)_proto"], force: true)
            ip = info["wan\(index)_ipaddr"] ?? ""
            var proto = info["wan\(index)_proto"] ?? ""
            let types = (wans["wans_dualwan"] ?? "").components(separatedBy: " ")
            if supports("usbX"), index < types.count, types[index] == "usb" { proto = "USB Modem" }
            if supports("dsl"), index < types.count, types[index] == "dsl" {
                let dsl = nvramGet(["dsl0_proto", "dslx_transmode"], force: true)
                if dsl["dslx_transmode"] == "atm", ["pppoa", "ipoa"].contains(dsl["dsl0_proto"] ?? "") { proto = dsl["dsl0_proto"] ?? "" }
            }
            if !proto.isEmpty {
                protoText = Self.protoNames[proto.lowercased()] ?? proto
                if supports("gobi"), proto == "USB Modem" {
                    let operation = nvramGet(["usb_modem_act_operation"], force: true)["usb_modem_act_operation"] ?? ""
                    protoText = operation.isEmpty ? "移动宽频" : operation
                }
            }
        }
        return VPNClientWAN(status: status, statusText: statusText, ip: ip, protoText: protoText)
    }
    /// httpApi.isConnected (897–922).
    mutating func isConnected(_ index: Int) -> Bool {
        let mode = nvramGet(["sw_mode"])["sw_mode"] ?? ""
        let wan = nvramGet(["wan\(index)_state_t", "wan\(index)_sbstate_t", "wan\(index)_auxstate_t", "link_internet"], force: true)
        if mode != "1" { return wan["link_internet"] == "2" }
        return wan["link_internet"] == "2" && wan["wan\(index)_state_t"] == "2" && wan["wan\(index)_sbstate_t"] == "0" && wan["wan\(index)_auxstate_t"] == "0"
    }
    /// The 互联网 card's status blocks (856–893): each WAN in router or WISP mode, the LAN address in AP mode.
    mutating func internetBlocks() -> [VPNClientWANBlock] {
        if operationMode == "rt" || operationMode == "wisp" {
            let dualWAN = supports("dualwan") && !(nvramGet(["wans_dualwan"])["wans_dualwan"] ?? "").contains("none")
            return (dualWAN ? [0, 1] : [0]).map { index in
                let wan = wanInfo(index)
                return VPNClientWANBlock(title: dualWAN ? (index == 0 ? "首选 WAN" : "第二 WAN") : "WAN 状态", connected: wan.status == "connected",
                                         statusText: wan.statusText, ipTitle: "外部网络IP", ip: wan.status == "connected" ? wan.ip : "- -. - -. - -. - -",
                                         proto: wan.status == "connected" ? wan.protoText : "- -")
            }
        }
        if operationMode == "ap" {
            let names = ["dhcp": "动态 IP", "static": "静态 IP", "pppoe": "PPPoE", "pptp": "PPTP", "l2tp": "L2TP"]
            let ip = nvramGet(["lan_ipaddr"], force: true)["lan_ipaddr"] ?? ""
            let proto = nvramGet(["lan_proto"], force: true)["lan_proto"] ?? ""
            // connect_proto_array[lan_proto] for a type it does not name is undefined, and .html(undefined) writes nothing.
            return [VPNClientWANBlock(title: "WAN 状态", connected: true, statusText: "AP 模式", ipTitle: "内部网络 IP", ip: ip,
                                      proto: proto.isEmpty ? "- -" : names[proto] ?? "")]
        }
        return []
    }

    // MARK: Editors

    /// get_wl_unit_by_band (4153–4173): wl<unit>.1_ssid for 2.4 and 5 GHz, the unit the band's place in wlnband_list as
    /// nvram_get writes it ("<" as "&#60").
    var ssidNames: [String] { Self.ssidNames(wlnband: encoded["wlnband_list"] ?? "") }

    /// The settings of a new profile (show_popup_edit_new_profile 261–270, set_profile_data's new branch) or of one of the
    /// list's profiles (the item's click 352–372). `newIndex` is get_new_vpnc_index (Fusion).
    public mutating func editor(for idx: Int?, newIndex: OrderedJSON? = nil) -> VPNClientEditor {
        let profile = idx.flatMap { idx in profiles.first { $0.idx == idx } }
        var editor = VPNClientEditor(target: profile.map { .profile($0.idx) } ?? .new, form: VPNClientForm(), title: "添加设置文件")
        if let profile {
            // set_profile_data (2591–2625): the title the protocol (`.html(undefined)` leaves 配置文件, 998), the fields
            // HTML-encoded into the inputs (htmlEncode of undefined leaves the input empty), the type fixed.
            // `_data.proto.toLowerCase()` of undefined (2602) throws after the fields: no 应用 or 删除.
            editor.title = profile.proto ?? "配置文件"
            let type = profile.proto?.lowercased()
            let options = profile.pptpOptions
            editor.form = VPNClientForm(desc: TORSettings.htmlEncode(profile.desc ?? ""), type: VPNClientForm.types.contains(type ?? "") ? type : nil,
                                        pptpOptions: VPNClientForm.pptpOptions.contains { $0.value == options } ? options : nil,
                                        server: TORSettings.htmlEncode(profile.server ?? ""), username: TORSettings.htmlEncode(profile.username ?? ""),
                                        password: TORSettings.htmlEncode(profile.passwd ?? ""))
            if profile.proto == nil { editor.stopped = true; return editor }
            editor.typeFixed = true
            if fusion { editor.defaultSwitch = profile.defaultWANSupported ? (profile.defaultWANSelected ? .on : .off) : .unsupported }
        } else {
            editor.autoEnable = fusion && Double(profiles.filter(\.activate).count) < activeMaximum
        }
        guard fusion else { return editor }
        // set_profile_data (2752–2782): the rules read again; a new profile's container gets get_new_vpnc_index.
        guard let policies = VPNClientPolicies.read(dhcp: encoded["dhcp_staticlist"] ?? "", rules: encoded["vpnc_dev_policy_list"] ?? "") else {
            editor.stopped = true; return editor
        }
        editor.policies = policies
        if let profile {
            editor.index = profile.vpncIndex.map(TORSettings.javaScriptString)
        } else {
            guard let newIndex else { editor.stopped = true; return editor }
            editor.index = TORSettings.javaScriptString(newIndex)
        }
        if instantGuard { editor.wireless = wireless(for: profile, policies: policies) }
        return editor
    }

    /// The 无线接口 choice (1218–1240, 2784–2817): the option the profile's br1/br2 rules make, the guest SSIDs as nvram_get
    /// writes them; locked with “* VPN WiFi 已经在使用中。” when the first VPN Wi-Fi rule is another profile's.
    private mutating func wireless(for profile: VPNClientProfile?, policies: VPNClientPolicies) -> VPNClientEditor.Wireless {
        let names = ssidNames
        let shown = nvramGet(names)
        let decoded = names.map { SiteSurvey.decodeURIComponent(encoded[$0] ?? "") }
        var wireless = VPNClientEditor.Wireless(option: "0", locked: false, hints: [], ssid2G: decoded[0], ssid5G: decoded[1])
        let rules = policies.rules.filter(\.wireless)
        guard let first = rules.first else { return wireless }
        if let profile, profile.hasIndex(first.vpncIndex) {
            var option = 0
            for rule in rules {
                if rule.brifname == "br1" { option += 1; wireless.hints.append(HTMLText.visible("2.4 GHz : " + (shown[names[0]] ?? ""), inside: ["div"])) }
                else { option += 2; wireless.hints.append(HTMLText.visible("5 GHz : " + (shown[names[1]] ?? ""), inside: ["div"])) }
            }
            wireless.option = VPNClientForm.wirelessOptions.contains { $0.value == String(option) } ? String(option) : nil
        } else {
            wireless.locked = true
            wireless.hints = ["* VPN WiFi 已经在使用中。"]
        }
        return wireless
    }

    /// The inputs of an open profile that still hold the HTML-encoded stored value (`.val(htmlEncode(…))`, 2593–2596), so
    /// 应用 writes "&amp;" and the like in place of "&", "<", ">", '"' and "'".
    public func encodedInputs(_ editor: VPNClientEditor) -> [String] {
        guard case .profile(let idx) = editor.target, let profile = profiles.first(where: { $0.idx == idx }) else { return [] }
        let inputs: [(String, String, String?)] = [("连接名称", editor.form.desc, profile.desc), ("虚拟专用网 (VPN) 服务器", editor.form.server, profile.server),
                                                  ("用户名", editor.form.username, profile.username), ("密码", editor.form.password, profile.passwd)]
        return inputs.filter { _, typed, stored in
            guard let stored else { return false }
            let encoded = TORSettings.htmlEncode(stored)
            return encoded != stored && typed == encoded
        }.map(\.0)
    }

    /// After a save the page reads the rules again (update_vpnc_status 3170–3184, 975): an open form keeps its inputs and
    /// works from the rules now stored. 适用于所有设备 shows what was read back, as the list's 默认连接 tag does
    /// (vpnc_default_wan, 3395, 3424; 674–676), not the state the switch was asked for.
    public func refreshed(_ editor: VPNClientEditor) -> VPNClientEditor {
        var editor = editor
        if fusion, editor.policies != nil,
           let fresh = VPNClientPolicies.read(dhcp: encoded["dhcp_staticlist"] ?? "", rules: encoded["vpnc_dev_policy_list"] ?? "") {
            editor.policies = fresh
        }
        switch editor.target {
        case .profile(let idx):
            if fusion, editor.defaultSwitch != nil, let profile = profiles.first(where: { $0.idx == idx }) {
                editor.defaultSwitch = profile.defaultWANSupported ? (profile.defaultWANSelected ? .on : .off) : .unsupported
            }
        case .internet:
            if let internet { editor.defaultSwitch = internet.isDefault ? .on : .off }
        case .new:
            break
        }
        return editor
    }
    /// get_default_reboot_time (showLoading before a reboot, 512, 605, 3117), in seconds.
    public var rebootTime: Int { hooks["get_default_reboot_time"].flatMap { javaScriptNumber(TORSettings.javaScriptString($0)) }.map { Int($0) } ?? 0 }

    /// The 互联网 card (Get_Component_Internet_Info 794–983): the WAN blocks, 适用于所有设备 (on when vpnc_default_wan is
    /// "0"), and the devices of vpnc_idx "0".
    public mutating func internetEditor() -> VPNClientEditor {
        var editor = VPNClientEditor(target: .internet, form: VPNClientForm(), title: "互联网")
        editor.index = "0"
        guard let policies = VPNClientPolicies.read(dhcp: encoded["dhcp_staticlist"] ?? "", rules: encoded["vpnc_dev_policy_list"] ?? "") else {
            editor.stopped = true; return editor
        }
        editor.policies = policies
        editor.blocks = internetBlocks()
        editor.defaultSwitch = nvramGet(["vpnc_default_wan"])["vpnc_default_wan"] == "0" ? .on : .off
        return editor
    }
}

// MARK: - The settings

/// The inputs of the settings (Get_Component_Setting_Profile 1030–1263) as typed, with the selected options' values.
public struct VPNClientForm: Sendable, Equatable {
    /// 连接名称, maxlength 64.
    public var desc = ""
    /// 虚拟专用网 (VPN) 的类型: "pptp" or "l2tp"; nil when the profile's protocol is neither, so no option is selected.
    public var type: String? = "pptp"
    /// PPTP 选项: the selected option's value; nil when the stored one is none of them.
    public var pptpOptions: String? = "auto"
    /// 虚拟专用网 (VPN) 服务器 and 用户名, maxlength 64; 密码, maxlength 128.
    public var server = ""
    public var username = ""
    public var password = ""
    public init(desc: String = "", type: String? = "pptp", pptpOptions: String? = "auto", server: String = "", username: String = "", password: String = "") {
        self.desc = desc; self.type = type; self.pptpOptions = pptpOptions; self.server = server; self.username = username; self.password = password
    }

    public static let types = ["pptp", "l2tp"]
    public static let pptpOptions: [(value: String, title: String)] = [("auto", "自动"), ("-mppc", "无加密"), ("+mppe-40", "MPPE 40"), ("+mppe-128", "MPPE 128")]
    public static let wirelessOptions: [(value: String, title: String)] = [("3", "2.4GHz / 5GHz"), ("1", "2.4GHz"), ("2", "5GHz"), ("0", "无")]

    /// The selected type as the select shows it (`#vpn_type`): "PPTP", "L2TP" or "".
    public var typeTitle: String { type?.uppercased() ?? "" }

    /// validate_blank (3594–3637): what 应用 needs before it reacts.
    public var complete: Bool {
        if desc.isEmpty { return false }
        if ["PPTP", "L2TP"].contains(typeTitle) { return !server.isEmpty && !username.isEmpty && !password.isEmpty }
        return true
    }

    public enum Field: Sendable { case desc, server, username, password }
    public struct Invalid: Error, Sendable, Equatable {
        public let field: Field
        public let message: String
    }
    static let blank = "栏位不能为空白"
    static let nameCharacters = ["*", "+", "|", ":", "?", "<", ">", ",", ".", "/", ";", "[", "]", "\\", "=", "\""]

    /// validate_format (3638–4111) for PPTP and L2TP: the name, then the server (digits and dots: inet_network strictly inside
    /// 1.0.0.0–126.255.255.255 or 128.0.0.0–255.255.255.255, then written back without leading zeros, 3845; anything else
    /// only ASCII 32–126 without "<" or ">"), user name and password (not trimmed). Returns the form as the check left its
    /// inputs (the server stays rewritten when a later field fails), and the first failure.
    public func validated() -> (form: VPNClientForm, invalid: Invalid?) {
        var form = self
        func fail(_ field: Field, _ message: String) -> (form: VPNClientForm, invalid: Invalid?) { (form, Invalid(field: field, message: message)) }
        if desc.isEmpty { return fail(.desc, Self.blank) }
        if let alert = WebValidator.blockChars(desc, Self.nameCharacters) { return fail(.desc, alert) }
        guard ["PPTP", "L2TP"].contains(typeTitle) else { return (form, nil) }
        if server.isEmpty { return fail(.server, Self.blank) }
        let digits = server.replacingOccurrences(of: ".", with: "")
        if digits.isEmpty || !digits.utf16.allSatisfy({ (0x30...0x39).contains($0) }) {
            if let alert = WebValidator.blockChars(server, ["<", ">"]) { return fail(.server, alert) }
        } else {
            let number = WebValidator.inetNetwork(server)
            let legal = (number > 16_777_216 && number < 2_130_706_431) || (number > 2_147_483_648 && number < 4_294_967_295)
            if !legal { return fail(.server, server + " 不是有效的 IP 地址！") }
            form.server = server.components(separatedBy: ".").map { String(Int($0) ?? 0) }.joined(separator: ".")
        }
        if username.isEmpty { return fail(.username, Self.blank) }
        if let alert = WebValidator.blockChars(username, ["<", ">"]) { return fail(.username, alert) }
        if password.isEmpty { return fail(.password, Self.blank) }
        // valid_block_chars lists what it refuses (validator.js), which here would show part of the password.
        if let alert = WebValidator.blockSecretChars(password, ["<", ">"]) { return fail(.password, alert) }
        return (form, nil)
    }
}

/// An open settings form: a new profile (the popup), one of the list's profiles, or the 互联网 card (Fusion).
public struct VPNClientEditor: Sendable, Equatable {
    public enum Target: Sendable, Equatable { case new, profile(Int), internet }
    public let target: Target
    public var form: VPNClientForm
    /// 添加设置文件, the profile's protocol (2592), or 互联网.
    public var title: String
    /// An existing profile's type cannot be changed (2604–2606).
    public var typeFixed = false
    /// auto_enable (2833): Fusion, a new profile, and fewer active profiles than allowed; 应用 reads 应用并开启.
    public var autoEnable = false
    /// The container's vpnc_idx: the profile's, get_new_vpnc_index for a new one, "0" for 互联网 (Fusion).
    public var index: String?
    /// Fusion: the rules and bindings read when the form opened, with its changes.
    public var policies: VPNClientPolicies?
    /// The script threw while filling the form: it shows, but 应用 and 删除 do nothing.
    public var stopped = false
    /// 适用于所有设备 (Fusion): an existing profile's switch, or 互联网's; `unsupported` answers with an alert.
    public enum DefaultSwitch: Sendable, Equatable { case on, off, unsupported }
    public var defaultSwitch: DefaultSwitch?
    /// 无线接口 (Fusion with ig_site2site and no mtlancfg).
    public struct Wireless: Sendable, Equatable {
        public var option: String?
        public var locked: Bool
        public var hints: [String]
        /// The guest SSIDs as nvram_char_to_ascii gave them, decoded (nil where decodeURIComponent throws).
        let ssid2G: String?
        let ssid5G: String?
    }
    public var wireless: Wireless?
    /// 互联网: the WAN blocks.
    public var blocks: [VPNClientWANBlock] = []

    init(target: Target, form: VPNClientForm, title: String) { self.target = target; self.form = form; self.title = title }

    public var applyTitle: String { autoEnable ? "应用并开启" : "应用目前所有设置" }

    /// Choosing a 无线接口 option (1231–1239): the hint lines from the decoded guest SSIDs. A choice whose SSID does not
    /// decode stops with the hint emptied.
    public mutating func chooseWireless(_ option: String) {
        guard var wireless, !wireless.locked else { return }
        wireless.option = option
        wireless.hints = []
        let bits = Int(option) ?? 0
        if bits & 1 != 0 {
            guard let ssid = wireless.ssid2G else { self.wireless = wireless; return }
            wireless.hints.append("2.4 GHz : " + ssid)
        }
        if bits & 2 != 0 {
            guard let ssid = wireless.ssid5G else { self.wireless = wireless; return }
            wireless.hints.append("5 GHz : " + ssid)
        }
        self.wireless = wireless
    }

    /// The profile's devices (or 互联网's), and the 设备 list's rows.
    public func devices(_ page: VPNClientPage) -> [VPNClientPolicies.Device] { policies?.devices(of: index, clients: page.clients) ?? [] }
    public func choices(_ page: VPNClientPage) -> [VPNClientPolicies.Choice] { policies?.choices(for: index, clients: page.clients) ?? [] }
    /// The ＋ of the device list (1269–1281): refused while the profile is active.
    public func canAssign(_ page: VPNClientPage) -> VPNClientAlert? {
        page.profiles.first { $0.hasIndex(index) }?.activate == true ? .deactivateToEdit : nil
    }
}
