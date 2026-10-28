import Foundation

// 外部网络(WAN) › 双线路（Advanced_WANPort_Content.asp），按 Asuswrt-Merlin 3006.102.5 在 RT-BE88U（dualwan、NEW_PHYMAP、autowan、
// usb_bk、lacp、wanbonding、mtlancfg）上打开时读取的内容、页面脚本对表单的联动，以及“应用本页面设置”按网页脚本构造并发送的
// 同一张表单（start_apply.htm，action_mode=apply_new，reboot）。开关、下拉、勾选和确认都只改本页的表单；只有发送表单会写入路由器。

// MARK: - Page script helpers

/// What `<% nvram_get(name); %>` writes for a browser (ej_nvram_get, web.c 1274–1336): printable ASCII other than `"`, `&`,
/// `<` and `>` as it is (a backslash too), every other byte as "&#" and its decimal value, without ";". char is unsigned on
/// the router's ARM CPU, so bytes above 127 are written as 128–255.
func aspNvramText(_ bytes: [UInt8]) -> String {
    var text = ""
    for byte in bytes {
        if byte == 0x5C || ((0x20...0x7E).contains(byte) && ![0x22, 0x26, 0x3C, 0x3E].contains(byte)) {
            text.unicodeScalars.append(Unicode.Scalar(byte))
        } else {
            text += "&#\(byte)"
        }
    }
    return text
}

/// String.prototype.replace with a text pattern: the first match (every match for replaceAll), the replacement read for
/// "$$", "$&", "$`" and "$'"; compared by UTF-16 code units.
func javaScriptReplace(_ text: String, _ pattern: String, _ replacement: String, all: Bool = false) -> String {
    let units = Array(text.utf16), match = Array(pattern.utf16), with = Array(replacement.utf16)
    guard !match.isEmpty else { return text }
    var out: [UInt16] = [], index = 0, done = false
    while index < units.count {
        if !done, index + match.count <= units.count, Array(units[index..<index + match.count]) == match {
            var position = 0
            while position < with.count {
                if with[position] == 0x24, position + 1 < with.count {
                    switch with[position + 1] {
                    case 0x24: out.append(0x24); position += 2; continue
                    case 0x26: out += match; position += 2; continue
                    case 0x60: out += units[..<index]; position += 2; continue
                    case 0x27: out += units[(index + match.count)...]; position += 2; continue
                    default: break
                    }
                }
                out.append(with[position]); position += 1
            }
            index += match.count
            done = !all
        } else {
            out.append(units[index]); index += 1
        }
    }
    return String(decoding: out, as: UTF16.self)
}

/// String.prototype.substr(start, length) on UTF-16 code units, for a start at or after 0.
func javaScriptSubstr(_ text: String, _ start: Int, _ length: Int) -> String {
    let units = Array(text.utf16)
    guard start < units.count else { return "" }
    return String(decoding: units[start..<min(units.count, start + length)], as: UTF16.self)
}

/// Array.prototype.splice(start, deleteCount, ...items) with JavaScript's handling of a negative start.
func javaScriptSplice(_ array: inout [String], _ start: Int, _ deleteCount: Int, _ items: [String] = []) {
    let begin = start < 0 ? max(array.count + start, 0) : min(start, array.count)
    let count = min(max(deleteCount, 0), array.count - begin)
    array.replaceSubrange(begin..<begin + count, with: items)
}

/// `value == text` in JavaScript for a JSON value and a text: text compares as text, numbers and booleans as numbers,
/// an array as the text it turns into; null, objects and a missing value never equal a number-like text.
func javaScriptLooselyEqualsText(_ value: OrderedJSON?, _ text: String) -> Bool {
    switch value {
    case .string(let string)?: string == text
    case .number(let number)?: javaScriptNumber(number).map { $0 == javaScriptNumber(text) } ?? false
    case .bool(let on)?: javaScriptNumber(text) == (on ? 1 : 0)
    case .array?: TORSettings.javaScriptString(value!) == text
    default: false
    }
}

// MARK: - The page as it opens

/// What Advanced_WANPort_Content.asp reads when it opens on this router, and what follows from it.
public struct DualWANPage: Sendable, Equatable {
    /// The variables the page and state.js read (in script text, in attribute values or with nvram_match), kept as
    /// nvram_char_to_ascii wrote them, still percent-encoded, so each of the page's contexts can be derived exactly.
    static let keys = [
        // state.js: based_modelid, ttc, ui_lang, wans_dualwan_orig, wlc_band (dualWAN_support), orig_bond_wan.
        "productid", "territory_code", "preferred_lang", "wans_dualwan", "wlc_band", "bond_wan",
        // The page's variables (83–129).
        "wans_cap", "switch_stb_x", "wandog_fb_count", "wandog_maxfail", "wans_mode", "wans_standby", "dns_probe_timeout",
        "qos_enable", "qos_type", "lacp_enabled", "wans_lanport", "wanports_bond", "iptv_port_settings", "autowan_enable",
        "switch_wantag", "wan_proto", "wan0_enable", "wan1_enable", "HwId", "lan_trunk_type",
        // The form (2031–2060), appendModeOption (1555–1590) and the rows (2231–2375).
        "firmver", "wl_ssid", "wan_unit", "wans_extwan", "wans_lb_ratio", "dns_probe", "wandog_enable", "wan0_routing_isp_enable",
        "wan0_routing_isp", "wan1_routing_isp_enable", "wan1_routing_isp", "wans_usb_bk_act", "wans_usb_bk", "wans_routing_enable",
        "wandog_interval", "dns_probe_host", "wandog_target",
        // initial() (291), updatDNSListOnline (1882) and get_vlan_portlist (134–186).
        "wans_routing_rulelist", "extendno", "label_mac", "vlan_trunk_rl",
        // js/table/tableValidator.js (5), which table.js loads for the rule list.
        "wan0_proto"
    ]
    /// Values the page's scripts embed between quotes (or, for wans_lanport, without them at 347–373): a quote or a
    /// backslash in one would stop the whole script (state.js, the page, or tableValidator.js for wan0_proto).
    static let scriptKeys = ["wan0_proto", "productid", "territory_code", "preferred_lang", "wans_dualwan", "wlc_band", "bond_wan", "wans_cap",
                             "switch_stb_x", "wandog_fb_count", "wandog_maxfail", "wan0_enable", "wan1_enable", "wans_mode", "wans_standby",
                             "qos_enable", "qos_type", "lacp_enabled", "wans_lanport", "wanports_bond", "iptv_port_settings", "autowan_enable",
                             "switch_wantag", "wan_proto", "HwId", "wan_unit", "lan_trunk_type", "wandog_enable", "wans_lb_ratio",
                             "wan0_routing_isp_enable", "wan1_routing_isp_enable", "wans_routing_enable", "wan0_routing_isp", "wan1_routing_isp",
                             "wandog_interval"]
    /// Hidden inputs whose value attribute is `<% nvram_get(name); %>` (2038–2060).
    static let attributeKeys = ["preferred_lang", "firmver", "wl_ssid", "wan_unit", "wans_extwan", "wans_dualwan", "wans_lanport",
                                "wans_lb_ratio", "dns_probe", "wandog_enable", "wan0_routing_isp_enable", "wan0_routing_isp", "wan1_routing_isp",
                                "wan0_enable", "wan1_enable", "switch_wantag", "switch_stb_x", "lacp_enabled", "bond_wan", "wans_usb_bk_act"]

    /// nvram_char_to_ascii answers by name.
    public let encoded: [String: String]
    public let support: [String: String]
    /// httpApi.hookGet("get_ethernet_wan_list", true) (124): ej_get_ethernet_wan_list (web.c 40226–40656); nil when the
    /// read failed.
    public let ethernetList: OrderedJSON?
    /// get_default_reboot_time() (web.c 42278–42293), the form's action_wait.
    public let rebootTime: String
    /// `<% bwdpi_engine_status(); %>` in state.js (4416–4425; web.c 32699–32716).
    public let dpiStatus: OrderedJSON?
    /// get_lan_hwaddr() (web.c 38454–38462) and get_port_status.cgi?node_mac= for it (get_lanport_list 189–230).
    public let lanMAC: String
    public let portStatus: OrderedJSON?
    /// /ajax/DNS_List.json on the router (updatDNSListOnline 1881–1900). The page then asks the ASUS site for a newer list;
    /// the app keeps the router's.
    public let dnsList: OrderedJSON?

    public init(encoded: [String: String], support: [String: String], ethernetList: OrderedJSON?, rebootTime: String,
                dpiStatus: OrderedJSON?, lanMAC: String, portStatus: OrderedJSON?, dnsList: OrderedJSON?) {
        self.encoded = encoded; self.support = support; self.ethernetList = ethernetList; self.rebootTime = rebootTime
        self.dpiStatus = dpiStatus; self.lanMAC = lanMAC; self.portStatus = portStatus; self.dnsList = dnsList
    }

    // MARK: Values in the page's contexts

    /// The stored bytes: each %XX of the answer as a byte, other characters as their UTF-8.
    func bytes(_ key: String) -> [UInt8] {
        let units = Array((encoded[key] ?? "").utf8)
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
    /// The stored value as text.
    public func raw(_ key: String) -> String { String(decoding: bytes(key), as: UTF8.self) }
    /// The text `'<% nvram_get(key); %>'` gives a script (the escapes are not undone there).
    func js(_ key: String) -> String { aspNvramText(bytes(key)) }
    /// `value="<% nvram_get(key); %>"` as the browser reads it: the escapes decoded as character references.
    func attribute(_ key: String) -> String { HTMLText.decode(js(key), inAttribute: true) }
    /// nvram_match(key, value, …): the stored bytes equal the value.
    func matches(_ key: String, _ value: String) -> Bool { bytes(key) == Array(value.utf8) }
    /// isSupport (state.js 481–486).
    func supports(_ name: String) -> Bool { !["", "0"].contains(support[name] ?? "") }

    /// ZVMODELVZ in the dictionary texts.
    public var model: String { raw("productid") }
    /// based_modelid (state.js 278).
    var basedModel: String { js("productid") }
    /// ui_lang (state.js 979), which the two FAQ links carry (121–122).
    public var language: String { js("preferred_lang") }
    /// is_CN (state.js 310).
    public var isCN: Bool { ["CN", "CT", "GD", "TC"].contains { js("territory_code").contains($0) } }
    /// dualWAN_support (state.js 565): the dualwan capability unless the router is a wireless client (wlc_band).
    var dualWANSupported: Bool { js("wlc_band") == "" && supports("dualwan") }
    /// wan_bonding_support, lacp_support, usb_bk_support (state.js 748, 753; 126).
    public var wanBonding: Bool { supports("wanbonding") }
    var lacp: Bool { supports("lacp") }
    public var usbBackupSupported: Bool { supports("usb_bk") }
    /// check_bwdpi_engine_status (state.js 4416–4425): bwdpi and DpiEngine == 1.
    var dpiEngineOn: Bool { supports("bwdpi") && javaScriptLooselyEqualsText(dpiStatus?["DpiEngine"], "1") }
    /// dns_probe_timeout_threshold (102): parseInt(dns_probe_timeout) + 2 when the value is above 0, otherwise 3.
    var intervalMinimum: Double {
        let text = js("dns_probe_timeout")
        guard let value = javaScriptNumber(text), value > 0, let number = SiteSurvey.parseInt(.string(text)) else { return 3 }
        return number + 2
    }
    /// `eval("<% get_default_reboot_time(); %>")` (1242).
    public var rebootWait: String { javaScriptNumber(rebootTime).map(javaScriptText) ?? rebootTime }
    /// get_bonding_ports(based_modelid) (state.js 757–784) for a router not named there.
    var bondingPorts: [(value: String, text: String)] { lacp ? [("1", "LAN1"), ("2", "LAN2")] : [] }
    public var dualWANFAQ: URL? { AsusSupportLink.faq("129", lang: language) }
    public var detectionFAQ: URL? { AsusSupportLink.faq("130", lang: language) }

    // MARK: Ethernet WAN list

    /// One member of get_ethernet_wan_list: the name the list shows, the variables applyRule copies into the form and,
    /// for a LAN port that can be a WAN, its wans_lanport.
    public struct EthernetWAN: Sendable, Equatable {
        public let key: String
        public let name: String
        public let extraSettings: [Setting]
        let hasExtraSettings: Bool
        public let lanPort: String?
        public struct Setting: Sendable, Equatable { public let name: String; public let value: String }
        func extra(_ name: String) -> String? { extraSettings.first { $0.name == name }?.value }
    }
    /// The members in Object.keys order, or nil when the answer is not an object of objects whose fields are text or
    /// numbers (the page's code would read it in ways the app does not follow).
    public var ethernetWANs: [EthernetWAN]? {
        guard case .object(let members)? = ethernetList else { return nil }
        func scalar(_ value: OrderedJSON) -> String? {
            switch value {
            case .string, .number, .bool, .null: TORSettings.javaScriptString(value)
            default: nil
            }
        }
        var wans: [EthernetWAN] = []
        for key in JavaScriptKeys.ordered(Self.uniqueKeys(members)) {
            guard let entry = members.last(where: { $0.0 == key })?.1, case .object(let fields) = entry else { return nil }
            var name = ""
            if let value = entry["wan_name"] { guard let text = scalar(value) else { return nil }; name = text }
            var settings: [EthernetWAN.Setting] = [], hasExtra = false
            if let extra = entry["extra_settings"] {
                guard case .object(let pairs) = extra else { return nil }
                hasExtra = true
                for name in JavaScriptKeys.ordered(Self.uniqueKeys(pairs)) {
                    guard let value = pairs.last(where: { $0.0 == name })?.1, let text = scalar(value) else { return nil }
                    settings.append(.init(name: name, value: text))
                }
            }
            var lanPort: String?
            if fields.contains(where: { $0.0 == "wans_lanport" }) {
                guard let value = entry["wans_lanport"], let text = scalar(value) else { return nil }
                lanPort = text
            }
            wans.append(EthernetWAN(key: key, name: name, extraSettings: settings, hasExtraSettings: hasExtra, lanPort: lanPort))
        }
        return wans
    }
    static func uniqueKeys(_ members: [(String, OrderedJSON)]) -> [String] {
        members.map(\.0).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }
    func ethernet(_ key: String) -> EthernetWAN? { ethernetWANs?.first { $0.key == key } }
    /// The names of every extra_settings member, which get_ethwan_setting reads (431–456).
    static func extraKeys(_ list: OrderedJSON?) -> [String] {
        guard case .object(let members)? = list else { return [] }
        var names: [String] = []
        for (_, entry) in members { for (name, _) in entry["extra_settings"]?.members ?? [] where !names.contains(name) { names.append(name) } }
        return RouterClient.readableKeys(names)
    }

    /// wans_caps after initial() (247–258): with a non-empty list, "wan" is replaced by the list's keys in place.
    var caps: String {
        var caps = js("wans_cap")
        if let wans = ethernetWANs, !wans.isEmpty, caps.contains("wan") {
            var items = caps.components(separatedBy: " ")
            var index = items.firstIndex(of: "wan") ?? -1
            javaScriptSplice(&items, index, 1)
            for wan in wans { javaScriptSplice(&items, index, 0, [wan.key]); index += 1 }
            caps = items.joined(separator: ",").replacingOccurrences(of: ",", with: " ")
        }
        return caps
    }

    // MARK: LAN ports, ping targets, VLAN ports, routing rules

    public struct Option: Sendable, Equatable { public let text: String; public let value: String }

    /// lanport_list (get_lanport_list 189–230): the node's L ports that are not WAN/LAN ports (cap bit 9) and not flagged
    /// (flag & 2), named by ui_display or by speed, valued by the second character of their label. Empty when the answer
    /// is not there or set_cap_support throws before the callback. The app waits for the answer; the page uses what it
    /// has 500 ms after initial() (262).
    public var lanPorts: [Option] {
        guard case .object? = portStatus?["port_info"], case .object(let members)? = portStatus?["port_info"]?[lanMAC] else { return [] }
        guard members.allSatisfy({ if case .object = $0.1 { true } else { false } }) else { return [] }
        var ports: [Option] = []
        for key in JavaScriptKeys.ordered(Self.uniqueKeys(members)) {
            guard let port = members.last(where: { $0.0 == key })?.1, javaScriptSubstr(key, 0, 1) == "L" else { continue }
            let index = javaScriptSubstr(key, 1, 1)
            // set_cap_support (httpApi.js 1646–1655) writes cap_support.WANLAN from cap bit 9, unless the port already has a
            // cap_support that is not an object, where the write is lost and WANLAN reads undefined.
            let cap = javaScriptInt32(SiteSurvey.parseInt(port["cap"]) ?? .nan)
            switch port["cap_support"] {
            case nil, .null?, .object?, .array?: if cap & (1 << 9) > 0 { continue }
            default: break
            }
            if javaScriptInt32(SiteSurvey.parseInt(port["flag"]) ?? .nan) & 2 == 2 { continue }
            // `ui_display.length` on null throws: the ports pushed before stay.
            if port["ui_display"] == .null { return ports }
            let text: String
            switch port["ui_display"] {
            case .string(let display)? where display.utf16.count > 0: text = display
            case .array(let display)? where !display.isEmpty: text = TORSettings.javaScriptString(.array(display))
            default:
                let numbered = (SiteSurvey.parseInt(.string(index)) ?? 0) > 0
                if javaScriptLooselyEqualsText(port["max_rate"], "2500") { text = numbered ? "2.5G LAN" + index : "2.5G LAN" }
                else if javaScriptLooselyEqualsText(port["max_rate"], "10000") { text = numbered ? "10G LAN" + index : "10G LAN" }
                else { text = "LAN Port " + index }
            }
            ports.append(Option(text: text, value: index))
        }
        return ports
    }

    /// One entry of the Ping 目标 list (create_DNSlist_view 1848–1878): `DNSService (ServiceIP1)`, which fills the target.
    public struct PingTarget: Sendable, Equatable, Identifiable {
        public let id: Int
        public let label: String
        public let address: String
        /// The address sits in `onclick="setPingTarget('…')"`; one with a quote, backslash, ampersand or line break
        /// would not reach the field as written.
        public let selectable: Bool
    }
    /// The entries whose ping_target is "CN" (on a China territory code) or "Yes"; none when an entry is null (the page's
    /// loop throws).
    public var pingTargets: [PingTarget] {
        let services: [OrderedJSON]
        switch dnsList {
        case .array(let items)?: services = items
        case .object(let members)?:
            services = JavaScriptKeys.ordered(Self.uniqueKeys(members)).compactMap { key in members.last { $0.0 == key }?.1 }
        default: return []
        }
        if services.contains(.null) { return [] }
        let wanted = isCN ? "CN" : "Yes"
        func text(_ value: OrderedJSON?) -> String { value.map(TORSettings.javaScriptString) ?? "undefined" }
        return services.filter { $0["ping_target"] == .string(wanted) }.enumerated().map { index, service in
            let address = text(service["ServiceIP1"]), name = text(service["DNSService"])
            return PingTarget(id: index, label: HTMLText.visible(name + " <strong>(" + address + ")</strong>", inside: ["div"]), address: address,
                              selectable: !address.contains(where: { "'\\\"&\n\r".contains($0) }))
        }
    }

    /// apgN_enable for N below MaxRule_SDN − 1 (6 without it), which get_vlan_portlist reads (134–186).
    static func apgKeys(_ support: [String: String]) -> [String] {
        let value = support["MaxRule_SDN"] ?? ""
        let count = ["", "0"].contains(value) ? 6.0 : (SiteSurvey.parseInt(.string(value)).map { $0 - 1 } ?? 0)
        return count > 0 ? (0..<Int(min(count, 64))).map { "apg\($0)_enable" } : []
    }
    /// apgN_dut_list of the enabled networks.
    static func dutKeys(_ encoded: [String: String], support: [String: String]) -> [String] {
        let page = DualWANPage(encoded: encoded, support: support, ethernetList: nil, rebootTime: "", dpiStatus: nil, lanMAC: "", portStatus: nil, dnsList: nil)
        return apgKeys(support).filter { page.js($0) == "1" }.map { $0.replacingOccurrences(of: "enable", with: "dut_list") }
    }
    /// vlan_port_list (get_vlan_portlist 134–186): the second character of each port of this router's entries in the
    /// enabled networks' dut lists, and the first field of each vlan_trunk_rl rule; nil where the function throws (a list
    /// decodeURIComponent rejects, or this router's entry without a third field).
    var vlanPorts: (access: [String], trunk: [String])? {
        let label = js("label_mac")
        var access: [String] = []
        for key in Self.dutKeys(encoded, support: support) {
            guard let list = SiteSurvey.decodeURIComponent(encoded[key] ?? "") else { return nil }
            guard !list.isEmpty else { continue }
            for entry in list.components(separatedBy: "<") where !entry.isEmpty {
                let info = entry.components(separatedBy: ">")
                guard info[0] == label else { continue }
                guard info.count > 2 else { return nil }
                if !info[2].isEmpty { access += info[2].components(separatedBy: ",").map { javaScriptSubstr($0, 1, 1) } }
            }
        }
        guard let trunk = SiteSurvey.decodeURIComponent(encoded["vlan_trunk_rl"] ?? "") else { return nil }
        return (access, trunk.components(separatedBy: "<").filter { !$0.isEmpty }.map { $0.components(separatedBy: ">")[0] })
    }

    /// wans_routing_rulelist_array (parseNvramToArray 289–304); nil when decodeURIComponent throws, which stops initial().
    var routingRules: [[String]]? {
        guard let list = SiteSurvey.decodeURIComponent(encoded["wans_routing_rulelist"] ?? "") else { return nil }
        return list.components(separatedBy: "<").filter { !$0.isEmpty }.map { $0.components(separatedBy: ">") }
    }

    // MARK: What the app does not run

    /// Models the page treats differently (initial 236–390, addWANOption 1284–1306, applyRule 702–728, 909–911, 1111–1141,
    /// 1222–1230, 1243) and capabilities whose branches the app does not follow.
    static let otherModels: Set<String> = ["RT-AX89U", "GT-AXY16000", "RT-AC87U", "TUF-AX3000_V2", "RT-N19", "PL-AX56_XP4", "RT-AC95U", "RT-AX95Q",
                                           "XT8PRO", "BT12", "BT10", "BQ16", "BQ16_PRO", "XT8_V2", "RT-AXE95Q", "ET8PRO", "ET8_V2", "RT-AX82_XD6",
                                           "RT-AX82_XD6S", "XD4S", "RT-AX53U", "XD6_V2", "RT-AX59U", "RT-AX52", "GT-AC5300", "RT-AC88Q", "BRT-AC828",
                                           "RT-AD7200", "XT12", "ET12", "TUF-AX4200", "TUF-AX6000", "GT-AX6000", "DSL-AC68U", "DSL-N55U", "DSL-N55U-B",
                                           "DSL-AC68R", "GT-BE98", "GT-BE98_PRO", "GT-BE96", "GT-BE19000", "GT-BE19000AI", "GT-BE96_AI"]
    /// Names of the page's form controls other than its hidden inputs, which an extra_settings member would change.
    static let controlNames: Set<String> = ["detect_interval", "detect_count", "wans_primary", "wans_lanport1", "wans_second", "wans_lanport2",
                                            "wans_usb_bk", "wans_standby", "wans_lb_ratio_0", "wans_lb_ratio_1", "wans_isp_unit", "wan0_isp_country",
                                            "wan0_isp_list", "wan1_isp_country", "wan1_isp_list", "wandog_interval", "wandog_maxfail", "wandog_fb_count",
                                            "dns_probe_chk", "wandog_enable_chk", "dns_probe_host", "wandog_target", "wans_routing_enable"]

    /// Why the app shows this page without letting it apply: the page's script would not run, would take a branch the app
    /// does not follow, or would send a hidden value other than the one stored.
    public var problems: [String] {
        var problems: [String] = []
        if Self.otherModels.contains(basedModel) || basedModel.hasPrefix("4G-") {
            problems.append("网页对 \(model) 走机型专用分支，本应用没有实现。")
        }
        for (name, label) in [("gobi", "内置移动网络（gobi）"), ("dsl", "DSL")] where supports(name) {
            problems.append("这台路由器支持\(label)，网页会走相应分支，本应用没有实现。")
        }
        if !supports("NEW_PHYMAP") { problems.append("这台路由器没有 NEW_PHYMAP，网页走另一种初始化顺序和端口列表，本应用没有实现。") }
        for key in Self.scriptKeys where js(key).contains("'") || js(key).contains("\\") {
            problems.append("\(key) 的值含有引号或反斜杠，网页的脚本无法运行。")
        }
        if js("wans_lanport").contains(where: { !("0"..."9").contains($0) }) {
            problems.append("wans_lanport 的值（\(raw("wans_lanport"))）不是数字，网页脚本第 347–373 行无法解析。")
        }
        if rebootTime.range(of: #"^(0|[1-9][0-9]*)$"#, options: .regularExpression) == nil {
            problems.append("路由器没有给出有效的默认重启时间（get_default_reboot_time）。")
        }
        if let wans = ethernetWANs {
            for wan in wans {
                for setting in wan.extraSettings where Self.controlNames.contains(setting.name) {
                    problems.append("以太网 WAN 列表的附加设置 \(setting.name) 会改动页面上的控件，本应用没有实现。")
                }
            }
        } else {
            problems.append("没有读到有效的以太网 WAN 列表（get_ethernet_wan_list），网页的端口选项无法确定。")
        }
        for key in Self.attributeKeys where attribute(key) != raw(key) {
            problems.append("隐藏字段 \(key) 在网页中会按 HTML 实体解码成“\(attribute(key))”提交，与路由器保存的“\(raw(key))”不同；本应用不发送这样的请求。")
        }
        return problems
    }
}

// MARK: - Form controls

/// A <select>: its options, the selected one (none after value was set to a value no option has) and disabled.
public struct DualWANSelect: Sendable, Equatable {
    public internal(set) var options: [DualWANPage.Option] = []
    public internal(set) var selected: Int?
    public internal(set) var disabled = false
    /// select.value: the selected option's value, "" when none is selected.
    public var value: String { selected.map { options[$0].value } ?? "" }
    var selectedValue: String? { selected.map { options[$0].value } }
    /// select.value = v: the first option with that value, or none.
    mutating func setValue(_ value: String) { selected = options.firstIndex { $0.value == value } }
    /// After options were inserted or removed, a single select without a selected option selects its first one.
    mutating func settle() { if selected == nil, !options.isEmpty { selected = 0 } }
    /// free_options (state.js 2817–2825).
    mutating func removeAll() { options = []; selected = nil }
    /// `options[index] = new Option(…)` (HTMLOptionsCollection's setter): appended (after blank options when the index is
    /// past the end by more than one), or in place of the option at the index.
    mutating func put(_ option: DualWANPage.Option, at index: Int) {
        let gap = index - options.count
        if gap >= 0 {
            options += Array(repeating: DualWANPage.Option(text: "", value: ""), count: max(gap - 1, 0)) + [option]
        } else {
            if selected == index { selected = nil }
            options[index] = option
        }
        settle()
    }
    /// `$("#id option[value='v']").remove()`.
    mutating func remove(value: String) {
        let kept = options.indices.filter { options[$0].value != value }
        guard kept.count != options.count else { return }
        selected = selected.flatMap { kept.firstIndex(of: $0) }
        options = kept.map { options[$0] }
        settle()
    }
    /// `$('<option>', {…, selected}).prependTo(select)`: an option inserted as selected becomes the selected one.
    mutating func prepend(_ option: DualWANPage.Option, selected chosen: Bool) {
        options.insert(option, at: 0)
        selected = chosen ? 0 : selected.map { $0 + 1 }
        settle()
    }
    /// option.selected = true.
    mutating func choose(_ index: Int) { if options.indices.contains(index) { selected = index } }
}

/// A text input or hidden input: its value and whether it is disabled (not submitted).
public struct DualWANField: Sendable, Equatable {
    public internal(set) var name: String
    public internal(set) var value: String
    public internal(set) var disabled: Bool
}

/// A radio group: the checked radio's value and whether the group is disabled.
public struct DualWANRadio: Sendable, Equatable {
    public internal(set) var checked: String?
    public internal(set) var disabled = false
}

// MARK: - Applying

/// The confirm() questions applyRule asks.
public enum DualWANQuestion: Sendable, Equatable {
    /// Dual WAN while IPTV is on (734–745).
    case iptvForDualWAN
    /// A single WAN that is not the default WAN while IPTV is on (956–969).
    case iptvForPort
    /// Load balance while the DPI engine runs (914–924).
    case dpi
    /// WAN 自动检测 with WAN aggregation, LACP or IPTV on (1048–1095).
    case autoDetect
    /// The LAN port taken as a WAN is a LACP bonding port (1143–1165).
    case portConflict
    /// The WAN types changed with Adaptive/traditional QoS on (1234–1240).
    case qos
    /// The service is reboot (1255–1260).
    case reboot
}

/// Where 应用本页面设置 stops.
public enum DualWANOutcome: Sendable, Equatable {
    /// The page asks; the answer is passed to the next `applying` call.
    case confirm(String, DualWANQuestion)
    /// A confirm() was answered 取消.
    case cancelled
    /// An alert(); nothing is sent.
    case alert(String)
    /// The page's script throws here; nothing is sent.
    case stopped(String)
    /// The hot standby panel (detect_time_confirm) opens; its 是 and 否 both submit.
    case hotStandby
    case submit(DualWANSubmission)
}

/// The form `form` (2031–2401) as the browser submits it to start_apply.htm.
public struct DualWANSubmission: Sendable, Equatable {
    public struct Field: Sendable, Equatable { public let name: String; public let value: String }
    public let fields: [Field]
    public func value(_ name: String) -> String? { fields.first { $0.name == name }?.value }
    public var actionScript: String { value("action_script") ?? "" }
    /// What httpd keeps of the form: validate_apply (web.c 4284–4330) writes the names of router_defaults
    /// (shared/defaults.c) and, through validate_instance, their wanN_ instances (wan_enable). The rest of the form
    /// (wans_primary, wans_second, wans_lanport1/2, wans_lb_ratio_0/1, wans_isp_unit, the check boxes' _chk, detect_*) only
    /// builds these; wl_ssid, preferred_lang and wan_unit go with the form but are not this page's settings.
    static let keptNames: Set<String> = ["wans_dualwan", "wans_mode", "wans_lb_ratio", "wans_lanport", "wans_standby", "wans_usb_bk",
                                         "wans_usb_bk_act", "wans_extwan", "wans_routing_enable", "wans_routing_rulelist", "wandog_enable",
                                         "wandog_target", "wandog_interval", "wandog_maxfail", "wandog_delay", "wandog_fb_count", "dns_probe",
                                         "dns_probe_host", "dns_probe_content", "bond_wan", "lacp_enabled", "switch_stb_x", "switch_wantag",
                                         "wan_ifname_x", "autowan_enable"]
    static func kept(_ name: String) -> Bool {
        keptNames.contains(name) || name.range(of: #"^wan[0-9]+_enable$"#, options: .regularExpression) != nil
    }
    /// action_wait: the default reboot time.
    public var wait: Int { Int(value("action_wait") ?? "") ?? 0 }
    public var reboots: Bool { actionScript.contains("reboot") }
    public var disablesDPI: Bool { actionScript.hasPrefix("dpi_disable") }
}

// MARK: - Routing rules

/// The 路由规则 list's text fields: tableValidator.dualWanRoutingRules (js/table/tableValidator.js 412–546) with the list's
/// rule checks (tableRuleDuplicateValidation / tableRuleValidation.dualWANRoutingRules, 819–871), as show_wans_rules sets
/// them up (1680–1754): maxlength 18, at most 64 rules.
public enum DualWANRuleField {
    public static let maxLength = 18
    public static let maximum = 64
    public static let placeholder = "请输入 IP 地址或 IP 地址/网络掩码或全部。"
    /// The WAN 模块 options in for-in order of {"<#dualwan_primary#>": "0", "<#dualwan_secondary#>": "1"}.
    public static let units = [DualWANPage.Option(text: "首选 WAN", value: "0"), DualWANPage.Option(text: "第二 WAN", value: "1")]

    /// keyPress (413–476) for a key typed at the end of `value`: digits (after three characters without a dot, and with
    /// fewer than three dots, a "." is added first), "." (not after a dot or a third one), "/" (after three dots), a, A, l
    /// and L. Returns the text the input holds before the key's character goes in, or nil when the key is refused.
    public static func typing(_ character: Character, after value: String) -> String? {
        let units = Array(value.utf16), dot: UInt16 = 0x2E
        let dots = units.filter { $0 == dot }.count
        func at(_ index: Int) -> UInt16? { units.indices.contains(index) ? units[index] : nil }
        switch character {
        case "0"..."9":
            if dots < 3, units.count >= 3, at(units.count - 3) != dot, at(units.count - 2) != dot, at(units.count - 1) != dot { return value + "." }
            return value
        case ".": return at(units.count - 1) == dot || dots == 3 ? nil : value
        case "/": return dots < 3 ? nil : value
        case "a", "A", "l", "L": return value
        default: return nil
        }
    }

    /// What an edit does to the field as the browser and keyPress let it (WebValidator.edit): a key typed goes through
    /// `typing`, which may add a dot at the end first (maxlength 18 stops the character, not the dot); deleting is free and
    /// a paste keeps what fits in 18. The page checks nothing more until the field is left. `replaced` is the part of
    /// `old` the edit replaced, as the text field reported it.
    public static func edited(_ old: String, _ new: String, key: Character?, replaced: Range<Int>? = nil) -> String {
        WebValidator.edit(old, new, typed: key, maxLength: maxLength, replaced: replaced) { typing($1, after: $0) }
    }

    /// blur (477–545): the value is trimmed ($.trim) and lower-cased first; blank gives "栏位不能为空白"; "all" passes; an
    /// address /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/ with every part below 256 passes strictly between 0.0.0.0 and 255.255.255.255,
    /// alone or with one "/" and a mask parseInt reads as a number that is not 0 and not above 32 (so a negative one passes
    /// too), and is written back from its number (leading zeros gone, the mask as parseInt read it). Returns the field's new
    /// value and its hint (nil when it passes).
    public static func leave(_ value: String) -> (value: String, hint: String?) {
        let text = javaScriptTrim(value).lowercased()
        if text.isEmpty { return (text, "栏位不能为空白") }
        if text == "all" { return (text, nil) }
        let invalid = text + " 不是有效的 IP 地址！"
        guard text.contains("/") else {
            guard let address = address(text) else { return (text, invalid) }
            return (address, nil)
        }
        let parts = text.components(separatedBy: "/")
        guard parts.count <= 2 else { return (text, invalid) }
        guard let address = address(parts[0]) else { return (text, invalid) }
        // `mask_tmp == "" || isNaN(mask_tmp)`, then `mask_tmp == 0 || mask_tmp > 32`.
        guard let mask = SiteSurvey.parseInt(.string(parts[1])), mask != 0, mask <= 32 else { return (text, invalid) }
        return (address + "/" + javaScriptText(mask), nil)
    }
    /// tableValid_ipAddrToIPDecimal (97–109) inside the range check and tableValid_decimalToIPAddr (111–118): the address
    /// written from its parts, nil when it is not one or is 0.0.0.0 or 255.255.255.255.
    static func address(_ text: String) -> String? {
        let parts = text.components(separatedBy: ".")
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy { (0x30...0x39).contains($0.value) } }) else { return nil }
        let numbers = parts.map { Double($0) ?? .infinity }
        guard numbers.allSatisfy({ $0 < 256 }) else { return nil }
        let value = numbers.reduce(0) { $0 * 256 + $1 }
        guard value > 0, value < 4_294_967_295 else { return nil }
        return numbers.map { String(Int($0)) }.joined(separator: ".")
    }
    /// tableRuleDuplicateValidation.dualWANRoutingRules (819–835): the rule without its third field, joined as
    /// Array.toString joins, equals another rule's.
    static func duplicates(_ rule: [String], _ rows: [[String]]) -> Bool {
        func key(_ row: [String]) -> String { (row.count > 2 ? Array(row[..<2] + row[3...]) : row).joined(separator: ",") }
        return rows.contains { key($0) == key(rule) }
    }
    /// tableRuleValidation.dualWANRoutingRules (863–870): the same source and destination; a rule without three fields
    /// returns undefined, which the panel alerts as "undefined" and an edit shows as an empty hint.
    static func ruleAlert(_ rule: [String]) -> String? {
        guard rule.count == 3 else { return "" }
        return rule[0] == rule[1] ? "Source IP and Destination IP can not be ALL at the same time" : nil
    }
}

/// The create panel (genCreateRule, table.js 504–649): 来源 IP and 目的 IP with their hints, and WAN 模块.
public struct DualWANRulePanel: Sendable, Equatable {
    public var source = ""
    public var destination = ""
    /// The list's value; the first option, 首选 WAN, to start with.
    public var unit = "0"
    public internal(set) var sourceHint: String?
    public internal(set) var destinationHint: String?
    public init() {}
    /// Leaving a text field (0 来源 IP, 1 目的 IP): the blur check rewrites it and sets or clears its hint.
    public mutating func leave(_ field: Int) {
        if field == 0 { (source, sourceHint) = DualWANRuleField.leave(source) } else { (destination, destinationHint) = DualWANRuleField.leave(destination) }
    }
}

/// A rule row in edit mode: the inputs as they are and their hints. The row cannot leave edit mode while a hint shows
/// (registerBodyEvent, table.js 1088–1112), and 新增 does nothing then (440–442).
public struct DualWANRuleEdit: Sendable, Equatable {
    public let row: Int
    public var values: [String]
    public internal(set) var hints: [Int: String] = [:]
    public var canFinish: Bool { hints.isEmpty }
}

public enum DualWANRuleOutcome: Sendable, Equatable {
    /// The rule was added and the panel closes.
    case done
    /// A field shows a hint; the panel stays.
    case hint
    /// alert(); the panel stays.
    case alert(String)
}

// MARK: - The page as it runs

/// The page's script state and form after initial() (and its 500 ms timer), changed by the controls as the page's
/// handlers change them. Mutations an apply makes before it stops (an alert, a confirm answered 取消) stay, as they do on
/// the page.
public struct DualWANForm: Sendable, Equatable {
    public let page: DualWANPage
    // Page variables.
    /// curState (111), which the switch shows.
    public private(set) var curState: String
    /// wans_flag (85, 234): 1 while the form is in dual WAN mode.
    public private(set) var wansFlag: Int
    /// wans_dualwan_array (state.js 946–947), changed by the switch and by applyRule.
    var dualwanArray: [String]
    let caps: String
    /// initial() threw at decodeURIComponent (291–303): no DNS list, no autowan_enable input, no aggregation note.
    public let initialStopped: Bool
    /// wans_routing_rulelist_array.
    public private(set) var rules: [[String]]

    // The form's controls in document order.
    /// The hidden inputs 2032–2060.
    var inputs: [DualWANField]
    public var detectInterval = ""
    public internal(set) var detectCount = DualWANSelect()
    public internal(set) var primary = DualWANSelect()
    public internal(set) var lanport1 = DualWANSelect()
    public internal(set) var second = DualWANSelect()
    public internal(set) var lanport2 = DualWANSelect()
    /// wans_usb_bk: the checked radio.
    public internal(set) var usbBackup: String?
    /// The hidden wans_mode (2240).
    public internal(set) var wansMode = ""
    /// wans_mode_option, which has no name and is not submitted.
    public internal(set) var modeSelect = DualWANSelect()
    public internal(set) var standby = DualWANSelect()
    public internal(set) var ratio0 = DualWANField(name: "wans_lb_ratio_0", value: "", disabled: false)
    public internal(set) var ratio1 = DualWANField(name: "wans_lb_ratio_1", value: "", disabled: false)
    public internal(set) var ispUnit = DualWANRadio()
    public internal(set) var wan0Country = DualWANSelect()
    public internal(set) var wan0List = DualWANSelect()
    public internal(set) var wan1Country = DualWANSelect()
    public internal(set) var wan1List = DualWANSelect()
    public var interval = ""
    public var maxfail = ""
    /// wandog_fb_count exists once form_show(1) has run (672–674).
    public internal(set) var fbCount: String?
    public internal(set) var dnsProbeChecked: Bool
    public internal(set) var pingChecked: Bool
    public internal(set) var dnsProbeHost: DualWANField
    public internal(set) var wandogTarget: DualWANField
    public internal(set) var routingEnable = DualWANRadio()
    /// Inputs added at the end of the form (to every form of the page): autowan_enable (378–384) and extra_settings
    /// members (applyRule).
    public internal(set) var appended: [DualWANSubmission.Field] = []

    // What shows.
    public private(set) var aggregationNoteShown = false
    public private(set) var primaryRowShown = false
    public private(set) var secondRowShown = false
    public private(set) var lanport1Shown = true
    public private(set) var lanport2Shown = true
    public private(set) var usbTetheringShown = false
    /// usb_tethering_hint instead of the 是/否 radios.
    public private(set) var usbTetheringHint = false
    public private(set) var modeRowShown = false
    public private(set) var fbSpanShown = false
    public private(set) var fbChecked = false
    public private(set) var lbNoteShown = false
    public private(set) var ratioRowShown = false
    public private(set) var fbCountRowShown = true
    /// 故障转移触发条件 with dualwan_failover_desc, or Internet 连接诊断 with dualwan_failover_disconnect (1645–1656).
    public private(set) var failoverWording = false
    public private(set) var dnsProbeHostShown = true
    public private(set) var wandogTargetShown = true
    public private(set) var routingTableShown = true
    public private(set) var routingRulesShown = true
    /// The detect_time_confirm panel and its detection time (str_detect_time).
    public private(set) var standbyPanelShown = false
    public private(set) var standbyDetectionTime = ""

    /// initial() (232–392) on a NEW_PHYMAP router, then its 500 ms timer (262–276).
    public init(page: DualWANPage) {
        self.page = page
        let dualwan = page.js("wans_dualwan")
        dualwanArray = dualwan.components(separatedBy: " ")
        curState = dualwanArray.count < 2 || dualwanArray[1] != "none" ? "1" : "0"
        wansFlag = dualwan.contains("none") || !page.dualWANSupported ? 0 : 1
        caps = page.caps
        func hidden(_ name: String, _ value: String, disabled: Bool = false) -> DualWANField { DualWANField(name: name, value: value, disabled: disabled) }
        inputs = [hidden("current_page", "Advanced_WANPort_Content.asp"), hidden("next_page", "Advanced_WANPort_Content.asp"), hidden("modified", "0"),
                  hidden("action_mode", "apply_new"), hidden("action_wait", page.rebootTime), hidden("action_script", "reboot"),
                  hidden("preferred_lang", page.attribute("preferred_lang")), hidden("firmver", page.attribute("firmver")),
                  hidden("wl_ssid", page.attribute("wl_ssid")), hidden("wan_unit", page.attribute("wan_unit")),
                  hidden("wans_extwan", page.attribute("wans_extwan")), hidden("wans_dualwan", page.attribute("wans_dualwan")),
                  hidden("wans_lanport", page.attribute("wans_lanport")), hidden("wans_lb_ratio", page.attribute("wans_lb_ratio")),
                  hidden("dns_probe", page.attribute("dns_probe")), hidden("dns_probe_content", "*"), hidden("wandog_enable", page.attribute("wandog_enable")),
                  hidden("wan0_routing_isp_enable", page.attribute("wan0_routing_isp_enable")), hidden("wan0_routing_isp", page.attribute("wan0_routing_isp")),
                  // 2051: wan1_routing_isp_enable starts with wan0's value.
                  hidden("wan1_routing_isp_enable", page.attribute("wan0_routing_isp_enable")), hidden("wan1_routing_isp", page.attribute("wan1_routing_isp")),
                  hidden("wans_routing_rulelist", ""), hidden("wan0_enable", page.attribute("wan0_enable")), hidden("wan1_enable", page.attribute("wan1_enable")),
                  hidden("switch_wantag", page.attribute("switch_wantag"), disabled: true), hidden("switch_stb_x", page.attribute("switch_stb_x"), disabled: true),
                  hidden("lacp_enabled", page.attribute("lacp_enabled"), disabled: true), hidden("bond_wan", page.attribute("bond_wan"), disabled: true),
                  hidden("wans_usb_bk_act", page.attribute("wans_usb_bk_act"), disabled: true)]
        // The LAN port lists as written (2207–2223), nvram_match choosing the option.
        let ports = (1...4).map { DualWANPage.Option(text: "LAN Port \($0)", value: "\($0)") }
        lanport1 = DualWANSelect(options: ports, selected: ports.firstIndex { page.matches("wans_lanport", $0.value) } ?? 0)
        lanport2 = lanport1
        usbBackup = page.matches("wans_usb_bk", "1") ? "1" : page.matches("wans_usb_bk", "0") ? "0" : nil
        modeSelect = DualWANSelect(options: [.init(text: "故障转移", value: "fo"), .init(text: "负载均衡", value: "lb")],
                                   selected: page.matches("wans_mode", "lb") ? 1 : 0)
        standby = DualWANSelect(options: [.init(text: "启用", value: "1"), .init(text: "停用", value: "0")],
                                selected: page.matches("wans_standby", "0") ? 1 : 0)
        dnsProbeChecked = page.matches("dns_probe", "1")
        pingChecked = page.matches("wandog_enable", "1")
        dnsProbeHost = DualWANField(name: "dns_probe_host", value: Self.textValue(page.attribute("dns_probe_host")), disabled: false)
        wandogTarget = DualWANField(name: "wandog_target", value: Self.textValue(page.attribute("wandog_target")), disabled: false)
        routingEnable.checked = page.matches("wans_routing_enable", "1") ? "1" : page.matches("wans_routing_enable", "0") ? "0" : nil

        // initial(), after the timer was set: the hidden wans_mode (286), the rule list (289–304), which can throw, and
        // what follows it (306–391).
        wansMode = page.js("wans_mode")
        let parsed = page.routingRules
        rules = parsed ?? []
        initialStopped = parsed == nil
        if !initialStopped {
            if page.supports("autowan") { appended.append(.init(name: "autowan_enable", value: page.js("autowan_enable"))) }
            aggregationNoteShown = page.wanBonding
        }
        // The timer.
        addWANOption(primary: true, caps.components(separatedBy: " "))
        addWANOption(primary: false, caps.components(separatedBy: " "))
        formShow(wansFlag)
        let lanPorts = page.lanPorts
        if !lanPorts.isEmpty {
            for index in [1, 2] {
                var select = DualWANSelect()
                for port in lanPorts {
                    select.put(port, at: select.options.count)
                    if page.js("wans_lanport") == port.value { select.choose(select.options.count - 1) }
                }
                if index == 1 { lanport1 = select } else { lanport2 = select }
            }
        } else {
            primary.remove(value: "lan"); second.remove(value: "lan")
        }
    }

    /// A text input's value sanitization: line breaks removed.
    static func textValue(_ text: String) -> String { String(text.unicodeScalars.filter { $0 != "\n" && $0 != "\r" }.map(Character.init)) }

    subscript(input name: String) -> String {
        get { inputs.first { $0.name == name }?.value ?? "" }
        set { if let index = inputs.firstIndex(where: { $0.name == name }) { inputs[index].value = newValue } }
    }
    mutating func enable(_ name: String, _ value: String) {
        guard let index = inputs.firstIndex(where: { $0.name == name }) else { return }
        inputs[index].disabled = false; inputs[index].value = value
    }
    mutating func disable(_ names: String...) {
        for name in names { if let index = inputs.firstIndex(where: { $0.name == name }) { inputs[index].disabled = true } }
    }
    /// The value the form would post for a hidden input, nil while it is disabled.
    public func hidden(_ name: String) -> String? { inputs.first { $0.name == name && !$0.disabled }?.value }

    // MARK: Helpers of the page

    var ethernet: [DualWANPage.EthernetWAN] { page.ethernetWANs ?? [] }
    func isEthWAN(_ value: String) -> Bool { ethernet.contains { $0.key == value } }
    /// get_ethwan_setting (431–456): the first member whose extra settings all equal the router's values.
    func ethwanSetting() -> String {
        for wan in ethernet where wan.extraSettings.allSatisfy({ page.js($0.name) == $0.value }) { return wan.key }
        return ""
    }
    /// is_special_lan (458–482).
    func isSpecialLAN(_ port: String) -> String {
        for wan in ethernet {
            if let lanPort = wan.lanPort {
                if lanPort == port { return wan.key }
            } else if wan.hasExtraSettings, let ifname = wan.extra("wan_ifname_x"), javaScriptSubstr(ifname, 3, 1) == port {
                return wan.key
            }
        }
        return ""
    }
    /// is_default_wan (500–513); nil where `eth_wan_list[value].hasOwnProperty` throws (a value the list does not have).
    func isDefaultWAN(_ value: String) -> Bool? {
        if value == "auto" || value == "usb" { return false }
        guard !ethernet.isEmpty else { return true }
        guard let wan = page.ethernet(value) else { return nil }
        return wan.lanPort == nil
    }
    /// get_default_wan (515–530).
    func defaultWAN() -> String { ethernet.first { $0.lanPort == nil }?.key ?? "wan" }

    /// The first of `candidates` (dsl, wan, wan2, sfp+, usb, lan in the page's order) that wans_caps names.
    func firstInCaps(_ candidates: [String]) -> String? { candidates.first { caps.contains($0) } }

    /// addWANOption (1268–1317).
    mutating func addWANOption(primary isPrimary: Bool, _ items: [String]) {
        var items = items
        var select = isPrimary ? primary : second
        select.removeAll()
        if items.contains("wan"), !items.contains("wan2"), dualwanArray.count > 1, dualwanArray[1] == "none", isPrimary, curState == "0" {
            var index = 0
            while index < items.count { if items[index] == "lan" { items.remove(at: index) }; index += 1 }
        }
        for (index, item) in items.enumerated() where !item.isEmpty {
            var name = item.uppercased()
            if name == "LAN", ["DSL-N55U", "DSL-N55U-B", "DSL-AC68U", "DSL-AC68R"].contains(page.model) { name = "Ethernet WAN" }
            else if name == "LAN" { name = "Ethernet LAN" }
            else if name == "USB", page.basedModel.hasPrefix("4G-") { name = "移动宽频" }
            else if name == "LAN2" { name = "2.5G WAN" }
            else if let wan = page.ethernet(item) { name = wan.name }
            select.put(.init(text: name, value: item), at: index)
        }
        if isPrimary { primary = select } else { second = select }
        if page.supports("NEW_PHYMAP"), page.lanPorts.isEmpty { primary.remove(value: "lan"); second.remove(value: "lan") }
    }

    /// form_show (532–698).
    mutating func formShow(_ mode: Int, changePrimary: String? = nil) {
        let wanValue = changePrimary ?? ethwanSetting()
        let first = dualwanArray[0], secondType = dualwanArray.count > 1 ? dualwanArray[1] : nil
        if mode == 0 {
            second.disabled = true; secondRowShown = false
            ratio0.disabled = true; ratio1.disabled = true; ratioRowShown = false
            ispUnit.disabled = true
            wan0Country.disabled = true; wan0List.disabled = true; wan1Country.disabled = true; wan1List.disabled = true
            routingEnable.checked = "0"; routingEnable.disabled = true
            routingRulesShown = false
            primary.setValue(first == "wan" && wanValue != "" ? wanValue : first)
            appendLANOption1()
            modeRowShown = false; fbCountRowShown = false; routingTableShown = false
            standby.disabled = true
            showWatchdogTable()
            if page.usbBackupSupported { usbTetheringShown = true; usbTetheringHint = first == "usb" }
            if page.supports("autowan"), page.js("switch_wantag") == "none", page.js("switch_stb_x") == "0",
               !page.wanBonding || page.js("bond_wan") == "0", !page.lacp || page.js("lacp_enabled") == "0",
               ["dhcp", "pppoe"].contains(page.js("wan_proto")), !primary.options.contains(where: { $0.value == "auto" }) {
                primary.prepend(.init(text: "WAN 自动检测", value: "auto"), selected: page.js("autowan_enable") == "1")
            }
            primaryRowShown = true
        } else {
            if first == "wan", wanValue != "" {
                primary.setValue(wanValue)
            } else if first == "lan" {
                let special = isSpecialLAN(self[input: "wans_lanport"])
                primary.setValue(special != "" ? special : "lan")
            } else {
                primary.setValue(first)
            }
            if secondType == "none" {
                if first == "dsl" {
                    second.setValue(firstInCaps(["wan", "wan2", "sfp+", "usb"]) ?? "lan")
                } else if first == "wan" {
                    if let found = firstInCaps(["wan2", "sfp+", "usb"]) {
                        second.setValue(found)
                    } else if page.supports("NEW_PHYMAP"), page.lanPorts.isEmpty {
                        if let other = ethernet.first(where: { $0.key != primary.value }) { second.setValue(other.key) }
                    } else {
                        second.setValue("lan")
                    }
                } else if first == "lan", self[input: "wans_lanport"] == "5" {
                    second.setValue(caps.contains("usb") ? "usb" : "lan")
                } else if caps.contains("wan") {
                    second.setValue("wan")
                }
            } else if let secondType {
                if secondType == "wan", wanValue != "" {
                    second.setValue(wanValue)
                } else if secondType == "lan" {
                    let special = isSpecialLAN(self[input: "wans_lanport"])
                    second.setValue(special != "" ? special : "lan")
                } else {
                    second.setValue(secondType)
                }
            } else {
                // wans_dualwan_array[1] is undefined: `value = undefined` names no option.
                second.setValue("undefined")
            }
            appendLANOption1(); appendLANOption2()
            // 672–674: the input is (re)made from its value attribute.
            fbCount = Self.textValue(page.attribute("wandog_fb_count"))
            appendModeOption(modeSelect.value)
            modeRowShown = true
            if page.usbBackupSupported { usbTetheringShown = false }
            primaryRowShown = true; secondRowShown = true
        }
    }

    /// appendLANoption1 / appendLANoption2 (1532–1552).
    mutating func appendLANOption1() {
        if primary.value == "lan" { if primary.options.contains(where: { $0.value == "lan" }) { lanport1Shown = true } } else { lanport1Shown = false }
    }
    mutating func appendLANOption2() {
        if second.value == "lan" { if second.options.contains(where: { $0.value == "lan" }) { lanport2Shown = true } } else { lanport2Shown = false }
    }

    static let countries = ["None", "China"]
    static let countryISPs = [[""], ["edu", "telecom", "mobile", "unicom"]]

    /// appendModeOption (1554–1632).
    mutating func appendModeOption(_ mode: String) {
        if mode == "lb" {
            lbNoteShown = true
            ratio0.disabled = false; ratio1.disabled = false; ratioRowShown = true
            let ratio = page.js("wans_lb_ratio").components(separatedBy: ":")
            ratio0.value = Self.textValue(ratio[0]); ratio1.value = ratio.count > 1 ? Self.textValue(ratio[1]) : "undefined"
            ispUnit.disabled = false
            let isp0 = page.js("wan0_routing_isp_enable"), isp1 = page.js("wan1_routing_isp_enable")
            if javaScriptLooselyEquals(isp0, 1), javaScriptLooselyEquals(isp1, 0) { ispUnit.checked = "1"; changeISPUnit(1) }
            else if javaScriptLooselyEquals(isp0, 0), javaScriptLooselyEquals(isp1, 1) { ispUnit.checked = "2"; changeISPUnit(2) }
            else { ispUnit.checked = "0"; changeISPUnit(0) }
            loadISPCountry()
            appendCountry(wan0: true); appendCountry(wan0: false)
            routingEnable.disabled = false
            if javaScriptLooselyEquals(page.js("wans_routing_enable"), 1) { routingEnable.checked = "1"; routingRulesShown = true }
            else { routingEnable.checked = "0"; routingRulesShown = false }
            fbCountRowShown = false; routingTableShown = true; fbSpanShown = false
            wansMode = "lb"
        } else {
            lbNoteShown = false
            ratio0.disabled = true; ratio1.disabled = true; ratioRowShown = false
            ispUnit.disabled = true
            wan0Country.disabled = true; wan0List.disabled = true; wan1Country.disabled = true; wan1List.disabled = true
            routingEnable.checked = "0"; routingEnable.disabled = true
            routingRulesShown = false; routingTableShown = false; fbSpanShown = true
            if wansMode == "fb" { fbChecked = true; fbCountRowShown = true; wansMode = "fb" }
            else { fbChecked = false; fbCountRowShown = false; wansMode = "fo" }
        }
        showWatchdogTable()
    }

    /// show_watchdog_table (1634–1657): both inputs are made again from their value attributes, so what was typed goes.
    mutating func showWatchdogTable() {
        interval = Self.textValue(page.attribute("wandog_interval"))
        maxfail = Self.textValue(page.attribute("wandog_maxfail"))
        failoverWording = wansFlag != 0 && (wansMode == "fo" || wansMode == "fb")
        appendMonitorOption()
    }
    /// appendMonitorOption (1659–1678) for both check boxes.
    mutating func appendMonitorOption() {
        dnsProbeHost.disabled = !dnsProbeChecked; dnsProbeHostShown = dnsProbeChecked
        wandogTarget.disabled = !pingChecked; wandogTargetShown = pingChecked
    }

    /// change_isp_unit (1772–1798).
    mutating func changeISPUnit(_ unit: Int) {
        wan0Country.disabled = false; wan1Country.disabled = false
        switch unit {
        case 1:
            self[input: "wan0_routing_isp_enable"] = "1"; self[input: "wan1_routing_isp_enable"] = "0"
            wan0Country.disabled = false; wan0List.disabled = false; wan1Country.disabled = true; wan1List.disabled = true
        case 2:
            self[input: "wan0_routing_isp_enable"] = "0"; self[input: "wan1_routing_isp_enable"] = "1"
            wan0Country.disabled = true; wan0List.disabled = true; wan1Country.disabled = false; wan1List.disabled = false
        default:
            self[input: "wan0_routing_isp_enable"] = "0"; self[input: "wan1_routing_isp_enable"] = "0"
            wan0Country.disabled = true; wan0List.disabled = true; wan1Country.disabled = true; wan1List.disabled = true
        }
    }
    /// Load_ISP_country (1800–1815).
    mutating func loadISPCountry() {
        let isp0 = page.js("wan0_routing_isp"), isp1 = page.js("wan1_routing_isp")
        for (index, country) in Self.countries.enumerated() {
            wan0Country.put(.init(text: country, value: "\(index)"), at: index)
            if country.lowercased() == isp0.components(separatedBy: "_")[0] { wan0Country.choose(index) }
            wan1Country.put(.init(text: country, value: "\(index)"), at: index)
            if country.lowercased() == isp1.components(separatedBy: "_")[0] { wan1Country.choose(index) }
        }
        if isp0 == "" { wan0Country.choose(0) }
        if isp1 == "" { wan1Country.choose(0) }
    }
    /// appendcountry (1817–1845).
    mutating func appendCountry(wan0: Bool) {
        let country = wan0 ? wan0Country : wan1Country
        guard !javaScriptLooselyEquals(country.value, 0), let index = Int(country.value), Self.countryISPs.indices.contains(index) else { return }
        var list = wan0 ? wan0List : wan1List
        let stored = page.js(wan0 ? "wan0_routing_isp" : "wan1_routing_isp").components(separatedBy: "_")
        for (position, isp) in Self.countryISPs[index].enumerated() {
            list.put(.init(text: isp, value: "\(position)"), at: position)
            if stored.count > 1, isp == stored[1] { list.choose(position) }
        }
        if wan0 { wan0List = list } else { wan1List = list }
    }

    /// changeWANProto (1319–1530), after the select took the new value.
    mutating func changeWANProto(primary isPrimary: Bool) {
        if wansFlag == 1 {
            if primary.value == second.value {
                let value = isPrimary ? primary.value : second.value
                func setOther(_ choice: String?) { if let choice { if isPrimary { second.setValue(choice) } else { primary.setValue(choice) } } }
                func otherEthernet() -> String? { ethernet.first { $0.key != value }?.key }
                let phymapWithoutLAN = page.supports("NEW_PHYMAP") && page.lanPorts.isEmpty
                switch value {
                case "dsl": setOther(firstInCaps(["wan", "wan2", "sfp+", "usb"]) ?? "lan")
                case _ where value == "wan" || isEthWAN(value):
                    if let found = firstInCaps(["dsl", "wan2", "sfp+", "usb"]) { setOther(found) }
                    else if phymapWithoutLAN { setOther(otherEthernet()) }
                    // 1440–1441: for the second WAN the page sets the second WAN itself to lan.
                    else { second.setValue("lan") }
                case "wan2": setOther(firstInCaps(["dsl", "wan", "sfp+", "usb"]) ?? "lan")
                case "sfp+": setOther(firstInCaps(["dsl", "wan", "wan2", "usb"]) ?? "lan")
                case "usb":
                    if isPrimary { setOther(firstInCaps(["dsl", "wan", "wan2", "sfp+", "lan"])) }
                    else { setOther(firstInCaps(["dsl", "wan", "wan2", "sfp+"]) ?? "lan") }
                case "lan2":
                    if isPrimary {
                        setOther(firstInCaps(["usb"]))
                    } else {
                        // 1481–1489: wans_second is filled again, set to lan2, and the primary WAN follows.
                        addWANOption(primary: false, caps.components(separatedBy: " "))
                        second.setValue("lan2")
                        setOther(firstInCaps(["wan", "usb"]))
                    }
                default:
                    setOther(firstInCaps(isPrimary ? ["dsl", "wan", "wan2", "sfp+", "usb"] : ["dsl", "wan", "wan2", "sfp+"]))
                }
            }
            appendLANOption1(); appendLANOption2()
        } else {
            appendLANOption1()
            if page.usbBackupSupported { usbTetheringShown = true; usbTetheringHint = primary.value == "usb" }
        }
    }

    // MARK: What the controls do

    /// The switch's on callback (2127–2154): the question it asks first, if any.
    public var switchOnQuestion: String? {
        page.wanBonding && page.js("bond_wan") == "1" ? "已启用路由器的 WAN Aggregation 功能，启用双 WAN 将会关闭 WAN Aggregation。确认继续吗？" : nil
    }
    /// Whether the on callback reads nvram_default_get(wans_mode): unless wans_caps has wan2 and no sfp+ (2140–2143).
    public var switchOnReadsDefaultMode: Bool { !(caps.contains("wan2") && !caps.contains("sfp+")) }
    /// The on callback after its question was answered 确定 (or there was none); `defaultMode` is the router's default
    /// wans_mode ("" when the read failed).
    public mutating func switchOn(defaultMode: String) {
        if switchOnQuestion != nil { enable("bond_wan", "0") }
        curState = "1"; wansFlag = 1
        second.disabled = false; secondRowShown = true
        wansMode = switchOnReadsDefaultMode ? defaultMode : "lb"
        if page.supports("autowan") { setAppended("autowan_enable", "0") }
        addWANOption(primary: true, caps.components(separatedBy: " "))
        formShow(wansFlag)
    }

    /// The switch's off callback (2155–2196): the question it asks when the primary WAN is a LAN port.
    public var switchOffQuestion: String? {
        guard caps.contains("wan"), dualwanArray[0] == "lan" else { return nil }
        var current = dualwanArray[0].uppercased() + " Port " + page.js("wans_lanport")
        let special = isSpecialLAN(self[input: "wans_lanport"])
        if special != "", let wan = page.ethernet(special) { current = wan.name }
        guard let defaultName = page.ethernet(defaultWAN())?.name else { return nil }
        let hint = "当前的主要 WAN 是 %1$@。禁用双 WAN 将更改主要 WAN 为 \"%2$@\"，您确定要这样做吗？"
        return javaScriptReplace(javaScriptReplace(hint, "%1$@", current), "%2$@", defaultName, all: true)
    }
    /// The off callback throws before its question when get_default_wan names a WAN the list does not have
    /// (`eth_wan_list[default_wan].wan_name`, 2166): the switch stays on and nothing changes.
    public var switchOffStops: Bool { caps.contains("wan") && dualwanArray[0] == "lan" && page.ethernet(defaultWAN()) == nil }
    /// The off callback after its question was answered 确定 (or there was none); `usbBackupActive` is wans_usb_bk_act as
    /// read then.
    public mutating func switchOff(defaultMode: String, usbBackupActive: String) {
        var defaultValue: String?
        if caps.contains("wan"), dualwanArray[0] == "lan" { dualwanArray[0] = "wan"; defaultValue = defaultWAN() }
        curState = "0"; wansFlag = 0
        if dualwanArray.count > 1 { dualwanArray[1] = "none" } else { dualwanArray.append("none") }
        self[input: "wans_dualwan"] = dualwanArray.joined(separator: " ")
        wansMode = defaultMode
        addWANOption(primary: true, caps.components(separatedBy: " "))
        formShow(wansFlag, changePrimary: defaultValue)
        if page.wanBonding { enable("bond_wan", page.js("bond_wan")) }
        if page.usbBackupSupported {
            if usbBackupActive == "1" { usbBackup = "0" }
            enable("wans_usb_bk_act", "0")
        }
    }

    /// A choice in 首选 WAN or 第二 WAN, then changeWANProto.
    public mutating func choose(primary isPrimary: Bool, index: Int) {
        if isPrimary { primary.choose(index) } else { second.choose(index) }
        changeWANProto(primary: isPrimary)
    }
    public mutating func chooseLANPort(primary isPrimary: Bool, index: Int) {
        if isPrimary { lanport1.choose(index) } else { lanport2.choose(index) }
    }
    public mutating func setUSBBackup(_ value: String) { usbBackup = value }
    /// wans_mode_option's onchange (2241).
    public mutating func chooseMode(_ mode: String) {
        modeSelect.setValue(mode)
        appendModeOption(mode)
    }
    /// fb_checkbox's onclick (2247–2252).
    public mutating func setFailback(_ on: Bool) {
        fbChecked = on; wansMode = on ? "fb" : "fo"; fbCountRowShown = on
    }
    public mutating func setRatio(first: Bool, _ value: String) { if first { ratio0.value = value } else { ratio1.value = value } }
    public mutating func setFailbackCount(_ value: String) { if fbCount != nil { fbCount = value } }
    /// The two check boxes' onclick (2332–2333).
    public mutating func setDNSProbe(_ on: Bool) { dnsProbeChecked = on; appendMonitorOption() }
    public mutating func setPing(_ on: Bool) { pingChecked = on; appendMonitorOption() }
    public mutating func setDNSProbeHost(_ value: String) { dnsProbeHost.value = value }
    public mutating func setPingTarget(_ value: String) { wandogTarget.value = value }
    /// wans_routing_enable's onclick, enable_lb_rules (1927–1934).
    public mutating func setRoutingEnabled(_ value: String) { routingEnable.checked = value; routingRulesShown = value == "1" }
    /// The Ping 目标 list: create_DNSlist_view runs once, a second after initial() (308); nothing when initial() stopped
    /// before updatDNSListOnline.
    public var pingTargets: [DualWANPage.PingTarget] { initialStopped ? [] : page.pingTargets }
    /// The rule list's 删除 (genDataRawDel, table.js 1349–1372), which needs no check and draws the list again (ending an edit).
    public mutating func deleteRule(at index: Int) { if rules.indices.contains(index) { rules.remove(at: index) } }
    /// The list's 新增 checks the count first (table.js 443–446): `data_num >= maximum` alerts.
    public var ruleLimitReached: Bool { rules.count >= DualWANRuleField.maximum }
    /// The alert 新增 shows instead of the create panel, nil when the panel opens.
    public var ruleAddAlert: String? { ruleLimitReached ? "本表仅允许 \(DualWANRuleField.maximum) 项目！" : nil }

    /// The create panel's 确认 (table.js 586–640). The text fields go in order: a blank one gets its blur check (the
    /// "栏位不能为空白" hint) and ends the loop; then any hint keeps the panel open; then the duplicate check (source and
    /// destination as the list's other rules have them) and the rule check alert; otherwise the trimmed values are added.
    public mutating func addRule(_ panel: inout DualWANRulePanel) -> DualWANRuleOutcome {
        var values: [String] = []
        for field in 0..<2 {
            let text = field == 0 ? panel.source : panel.destination
            if javaScriptTrim(text).isEmpty { panel.leave(field); break }
            values.append(javaScriptTrim(text))
        }
        if values.count == 2 { values.append(javaScriptTrim(panel.unit)) }
        if panel.sourceHint != nil || panel.destinationHint != nil { return .hint }
        if DualWANRuleField.duplicates(values, rules) { return .alert("此项已纳入列表中。") }
        if let alert = DualWANRuleField.ruleAlert(values) { return .alert(alert) }
        rules.append(values)
        return .done
    }

    /// A row put in edit mode by a click on one of its cells (table.js 1154–1172): the inputs hold the row's values.
    public func editRule(at row: Int) -> DualWANRuleEdit? {
        guard rules.indices.contains(row) else { return nil }
        return DualWANRuleEdit(row: row, values: Array(rules[row].prefix(3)))
    }
    /// Leaving a text input of the row in edit mode (genEditRuleText's blur, table.js 1221–1255): the blur check, then the
    /// duplicate check against the other rows and the rule check, each shown as the input's hint; when all pass the value
    /// goes into the list at once.
    public mutating func leaveRuleEdit(_ edit: inout DualWANRuleEdit, column: Int) {
        guard rules.indices.contains(edit.row), edit.values.indices.contains(column), column < 2 else { return }
        let (value, hint) = DualWANRuleField.leave(edit.values[column])
        edit.values[column] = value
        edit.hints[column] = hint
        guard hint == nil else { return }
        var current = rules[edit.row]
        current[column] = value
        var others = rules
        others.remove(at: edit.row)
        if DualWANRuleField.duplicates(current, others) { edit.hints[column] = "此项已纳入列表中。"; return }
        // `showHintMsg($(this), undefined)` for a row without three fields leaves an empty hint.
        if let alert = DualWANRuleField.ruleAlert(current) { edit.hints[column] = alert; return }
        rules[edit.row][column] = value
    }
    /// A choice in the row's WAN 模块 list (genEditRuleSelect's change, table.js 1283–1323): the duplicate alert, if any;
    /// otherwise the value goes into the list.
    public mutating func changeRuleUnit(_ edit: inout DualWANRuleEdit, _ value: String) -> String? {
        guard rules.indices.contains(edit.row), rules[edit.row].count > 2, edit.values.count > 2 else { return nil }
        edit.values[2] = value
        var current = rules[edit.row]
        current[2] = value
        var others = rules
        others.remove(at: edit.row)
        if DualWANRuleField.duplicates(current, others) { return "此项已纳入列表中。" }
        rules[edit.row][2] = value
        return nil
    }

    /// `$("input[name='autowan_enable']").attr("value", v)` on this form's input, if it has one.
    mutating func setAppended(_ name: String, _ value: String) {
        for index in appended.indices where appended[index].name == name { appended[index] = .init(name: name, value: value) }
    }

    /// Inputs show_banner puts in the forms of TopBanner (state.js 1048–1141), which come before this page's form, and
    /// other named elements: getElementsByName(name)[0] is not this form's input.
    static let namesBeforeForm: Set<String> = ["next_page", "current_page", "action_mode", "action_script", "action_wait", "wl_unit", "wl_subunit",
                                               "le_restart_httpd", "preferred_lang", "flag", "wan_unit", "sim_order", "disk", "protocol", "mode",
                                               "fb_experience", "noti_notif_Flag", "wan_enable", "modem_enable", "dslx_link_enable", "rc_service",
                                               "dblog_enable", "current_pgae", "qos_enable", "form", "hidden_frame", "TargetList_Block_PC"]
    /// The extra_settings loop (807–822 and its copies): an existing element named so takes the value (the first one in
    /// the document, which for a name every form has is a banner form's), otherwise a hidden input is added to every form.
    mutating func applyExtraSettings(_ wan: DualWANPage.EthernetWAN) {
        for setting in wan.extraSettings {
            if Self.namesBeforeForm.contains(setting.name) || appended.contains(where: { $0.name == setting.name }) { continue }
            if inputs.contains(where: { $0.name == setting.name }) { self[input: setting.name] = setting.value; continue }
            if setting.name == "wans_mode" { wansMode = setting.value; continue }
            appended.append(.init(name: setting.name, value: setting.value))
        }
    }

    // MARK: 应用本页面设置

    /// applyRule (700–1262) on a copy of this form, with the confirm() questions answered in order by `answers`; when the
    /// answers run out at a question, the question is returned and the copy is not meant to be kept.
    public func applying(_ answers: [Bool]) -> (form: DualWANForm, outcome: DualWANOutcome) {
        var form = self
        var queue = answers[...]
        let outcome = form.applyRule(&queue)
        return (form, outcome)
    }

    static let portConflictHint = "将 %1$@ 配置为 %2$@ 将停用 \"%3$@\" 功能，您确定要继续吗？"

    mutating func applyRule(_ answers: inout ArraySlice<Bool>) -> DualWANOutcome {
        let iptvOn = page.js("switch_stb_x") != "0" || page.js("switch_wantag") != "none"
        // 702–730 are for RT-AC88Q, BRT-AC828 and RT-AD7200.
        if wansFlag == 1 {
            if iptvOn {
                let text = "为确保没有冲突，当您启用 双线路 时，IPTV 将被停用。您确定要继续吗？"
                guard let yes = answers.popFirst() else { return .confirm(text, .iptvForDualWAN) }
                guard yes else { return .cancelled }
                enable("switch_wantag", "none"); enable("switch_stb_x", "0")
            }
            self[input: "wans_extwan"] = "0"
            let first = primary.value, other = second.value
            if first == "lan2" {
                if other == "wan" { self[input: "wans_dualwan"] = "lan wan"; self[input: "wans_lanport"] = "5"; self[input: "wans_extwan"] = "0" }
                else { self[input: "wans_dualwan"] = "wan " + other; self[input: "wans_extwan"] = "1" }
            } else if other == "lan2" {
                if first == "wan" { self[input: "wans_dualwan"] = "wan lan"; self[input: "wans_lanport"] = "5"; self[input: "wans_extwan"] = "0" }
                else { self[input: "wans_dualwan"] = first + " wan"; self[input: "wans_extwan"] = "1" }
            } else {
                var firstType = first, otherType = other
                let firstWAN = isEthWAN(first) ? page.ethernet(first) : nil, otherWAN = isEthWAN(other) ? page.ethernet(other) : nil
                func lanPort(_ wan: DualWANPage.EthernetWAN) {
                    let ifname = wan.extra("wan_ifname_x") ?? ""
                    if let port = wan.lanPort { self[input: "wans_lanport"] = port } else if ifname != "" { self[input: "wans_lanport"] = javaScriptSubstr(ifname, 3, 1) }
                }
                if let firstWAN, let otherWAN {
                    if firstWAN.extra("wans_extwan") == "0" {
                        firstType = "wan"; otherType = "lan"; lanPort(otherWAN)
                    } else if otherWAN.extra("wans_extwan") == "0" {
                        otherType = "wan"; firstType = "lan"; lanPort(firstWAN)
                    } else if firstWAN.lanPort != nil {
                        firstType = "lan"; lanPort(firstWAN)
                        otherType = "wan"; applyExtraSettings(otherWAN)
                    } else {
                        firstType = "wan"; applyExtraSettings(firstWAN)
                        otherType = "lan"; lanPort(otherWAN)
                    }
                } else if let firstWAN {
                    applyExtraSettings(firstWAN); firstType = "wan"
                } else if let otherWAN {
                    applyExtraSettings(otherWAN); otherType = "wan"
                }
                self[input: "wans_dualwan"] = firstType + " " + otherType
            }
            let dualwan = self[input: "wans_dualwan"]
            if !page.supports("dsl"), page.basedModel != "BRT-AC828", dualwan == "usb lan" || dualwan == "lan usb", ethernet.count <= 1 {
                return .alert("WAN port should be selected in Dual WAN.")
            }
            self[input: "wan_unit"] = page.js("wan_unit")
            if wansMode == "lb" {
                if let alert = WebValidator.range(&ratio0.value, 1, 9) { return .alert(alert) }
                if let alert = WebValidator.range(&ratio1.value, 1, 9) { return .alert(alert) }
                if page.js("wans_mode") != "lb", page.dpiEngineOn {
                    let text = "如果您开启负载均衡选项，AiProtection 网络神盾 将被禁用。您确定要处理吗？"
                    guard let yes = answers.popFirst() else { return .confirm(text, .dpi) }
                    guard yes else { return .cancelled }
                    self[input: "action_script"] = "dpi_disable;reboot;"
                }
                self[input: "wans_lb_ratio"] = ratio0.value + ":" + ratio1.value
                guard let isp0 = Self.routingISP(wan0Country, wan0List), let isp1 = Self.routingISP(wan1Country, wan1List) else {
                    return .stopped("负载均衡的 ISP 列表没有选项，网页脚本在这里出错。")
                }
                self[input: "wan0_routing_isp"] = isp0
                self[input: "wan1_routing_isp"] = isp1
                saveTable()
            } else {
                disable("wans_lb_ratio", "wan0_routing_isp_enable", "wan0_routing_isp", "wan1_routing_isp_enable", "wan1_routing_isp", "wans_routing_rulelist")
            }
        } else {
            wansMode = "fo"
            disable("wans_lb_ratio", "wan0_routing_isp_enable", "wan0_routing_isp", "wan1_routing_isp_enable", "wan1_routing_isp", "wans_routing_rulelist")
            let first = primary.value
            guard let isDefault = isDefaultWAN(first) else { return .stopped("首选 WAN 不在以太网 WAN 列表中，网页脚本在这里出错（is_default_wan）。") }
            if !isDefault, iptvOn {
                let name = primary.selected.map { Self.optionText(primary.options[$0].text) } ?? ""
                let text = javaScriptReplace(javaScriptReplace(javaScriptReplace(Self.portConflictHint, "%1$@", "\"" + name + "\""), "%2$@", "外部网络(WAN)"), "%3$@", "IPTV")
                guard let yes = answers.popFirst() else { return .confirm(text, .iptvForPort) }
                guard yes else { return .cancelled }
                enable("switch_stb_x", "0"); enable("switch_wantag", "none")
            }
            if let wan = isEthWAN(first) ? page.ethernet(first) : nil {
                applyExtraSettings(wan)
                self[input: "wans_dualwan"] = "wan none"
            } else if first == "lan2" {
                self[input: "wans_dualwan"] = "wan none"; self[input: "wans_extwan"] = "1"
            } else {
                self[input: "wans_dualwan"] = first + " none"; self[input: "wans_extwan"] = "0"
            }
            self[input: "wan_unit"] = "0"
            self[input: "wandog_enable"] = "0"
            if page.supports("autowan") { setAppended("autowan_enable", primary.selectedValue != "auto" ? "0" : "1") }
        }
        if page.supports("autowan") { self[input: "wans_dualwan"] = javaScriptReplace(self[input: "wans_dualwan"], "auto", "wan") }
        if pingChecked {
            if wandogTarget.value.isEmpty || javaScriptTrim(wandogTarget.value).isEmpty { return .alert("栏位不能为空白") }
            if let alert = DualWANForm.hostAlert(wandogTarget.value) { return .alert(alert) }
            self[input: "wandog_enable"] = "1"
        } else {
            self[input: "wandog_enable"] = "0"
        }
        self[input: "dns_probe"] = dnsProbeChecked ? "1" : "0"
        if let alert = WebValidator.range(&interval, page.intervalMinimum, 99) { return .alert(alert) }
        if primary.value == "lan" { self[input: "wans_lanport"] = lanport1.value }
        else if second.value == "lan" { self[input: "wans_lanport"] = lanport2.value }
        else if ethernet.count <= 1 { disable("wans_lanport") }

        // Function Conflict Check (1043–1095).
        var conflictFunction = "", conflictPorts = ""
        let lacpOn = page.lacp && page.js("lacp_enabled") == "1"
        if page.supports("autowan"), primary.selectedValue == "auto" {
            if page.wanBonding, page.js("bond_wan") == "1" { conflictFunction = "WAN 聚合" }
            if lacpOn { conflictFunction = conflictFunction.isEmpty ? "绑定/链路聚合" : conflictFunction + ", 绑定/链路聚合" }
            if iptvOn { conflictFunction = conflictFunction.isEmpty ? "IPTV" : conflictFunction + ", IPTV" }
            if !conflictFunction.isEmpty {
                let text = javaScriptReplace(javaScriptReplace("为确保没有冲突，当您启用 %1$@ 时，%2$@ 将被停用。您确定要继续吗？", "%1$@", "WAN 自动检测"), "%2$@", conflictFunction)
                guard let yes = answers.popFirst() else { return .confirm(text, .autoDetect) }
                guard yes else { return .cancelled }
                if page.wanBonding { enable("bond_wan", "0") }
                if page.lacp { enable("lacp_enabled", "0") }
                enable("switch_wantag", "none"); enable("switch_stb_x", "0")
            }
        }
        // LACP Port Conflict Check (1097–1109).
        if lacpOn, self[input: "wans_dualwan"].contains("lan") {
            let port = self[input: "wans_lanport"]
            conflictPorts = ""
            for setting in page.bondingPorts where port == setting.value { conflictFunction = "绑定/链路聚合"; conflictPorts = setting.text.uppercased() }
        }
        // 1111–1141 are for the GT-BE series.
        if !conflictFunction.isEmpty, !conflictPorts.isEmpty {
            let text = javaScriptReplace(javaScriptReplace(javaScriptReplace(Self.portConflictHint, "%1$@", conflictPorts), "%2$@", "外部网络(WAN)"), "%3$@", conflictFunction)
            guard let yes = answers.popFirst() else { return .confirm(text, .portConflict) }
            guard yes else { return .cancelled }
            if conflictFunction.contains("绑定/链路聚合") { enable("lacp_enabled", "0") }
            if conflictFunction.contains("IPTV") { enable("switch_stb_x", "0"); enable("switch_wantag", "none") }
        }
        // VLAN Port Check (1168–1208).
        if page.supports("mtlancfg") {
            guard let vlan = page.vlanPorts else { return .stopped("网络（SDN）的端口列表无法解析，网页脚本在这里出错（get_vlan_portlist）。") }
            if self[input: "wans_dualwan"].contains("lan") {
                let port = self[input: "wans_lanport"]
                if vlan.access.contains(port) || vlan.trunk.contains(port) { return .alert("WAN 和 VLAN 不能被配置为同一个端口。") }
            }
        }
        dualwanArray = self[input: "wans_dualwan"].components(separatedBy: " ")
        if dualwanArray.count > 1, dualwanArray[1] == "none" { self[input: "wan_unit"] = "0" }
        if dualwanArray.firstIndex(of: "usb") == 0, self[input: "wan0_enable"] == "0" { self[input: "wan0_enable"] = "1" }
        if dualwanArray.firstIndex(of: "usb") == 1, self[input: "wan1_enable"] == "0" { self[input: "wan1_enable"] = "1" }
        // 1222–1230 are for RT-AX89U and GT-AXY16000.
        if page.js("wans_dualwan") != self[input: "wans_dualwan"], javaScriptLooselyEquals(page.js("qos_enable"), 1) {
            let type = page.js("qos_type")
            if javaScriptLooselyEquals(type, 1) || javaScriptLooselyEquals(type, 0) || javaScriptLooselyEquals(type, 3) {
                guard let yes = answers.popFirst() else { return .confirm("应用设置后，请在 QoS 页面中仔细检查您的下载/上传带宽配置。", .qos) }
                guard yes else { return .cancelled }
            }
        }
        self[input: "action_wait"] = page.rebootWait
        if standby.value == "1", standby.value != page.js("wans_standby") {
            standbyPanelShown = true
            detectInterval = "2"
            addOptionCount()
            _ = updateStandbyTime()
            return .hotStandby
        }
        if self[input: "action_script"] == "reboot" {
            guard let yes = answers.popFirst() else {
                return .confirm("重启路由器可能会使所有已联网的路由器中断网络连接。重启后，所有设备将会重新进行网络连接，确认继续？", .reboot)
            }
            guard yes else { return .cancelled }
        }
        return .submit(submission)
    }

    /// An option's text (HTMLOptionElement.text): ASCII white space stripped and collapsed.
    static func optionText(_ text: String) -> String {
        text.split(whereSeparator: { [" ", "\t", "\n", "\u{0C}", "\r"].contains($0) }).joined(separator: " ")
    }
    /// wanN_routing_isp (926–938): "None" for the first country, otherwise "china_<isp>"; nil where options[0] is undefined.
    static func routingISP(_ country: DualWANSelect, _ list: DualWANSelect) -> String? {
        guard !country.options.isEmpty else { return nil }
        guard let index = Int(country.value), countries.indices.contains(index) else { return country.selected == 0 ? "undefined" : nil }
        if country.selected == 0 { return countries[index] }
        let isps = countryISPs[index]
        let isp = Int(list.value).flatMap { isps.indices.contains($0) ? isps[$0] : nil } ?? "undefined"
        return countries[index].lowercased() + "_" + isp
    }
    /// save_table (1756–1770).
    mutating func saveTable() {
        self[input: "wans_routing_rulelist"] = rules.filter { !$0.isEmpty }.map { "<" + $0.joined(separator: ">") }.joined()
    }

    /// validator.isValidHost (validator.js 962–981): the alert, or nil for a host either pattern accepts.
    static func hostAlert(_ value: String) -> String? {
        // `new RegExp` works on UTF-16 code units, so a surrogate stands for one character `.` matches alone.
        let units = value.utf16.map { (0xD800...0xDFFF).contains($0) ? 0xFFFD : $0 }
        let text = String(decoding: units, as: UTF16.self)
        let range = NSRange(location: 0, length: (text as NSString).length)
        if hostPatterns.allSatisfy({ $0.firstMatch(in: text, range: range) == nil }) {
            return value + " \n" + "不是有效的 IP 地址！\n这不符合完全限定域名（FQDN）规则。"
        }
        return nil
    }
    /// The two patterns as JavaScript reads them: the first from a string literal, where "\." is just ".", so between the
    /// octets and before the top-level domain any character but a line terminator matches; the second with \b and \d as
    /// JavaScript defines them (ASCII word characters and digits). ^ and $ are the ends of the text.
    static let hostPatterns: [NSRegularExpression] = {
        let any = #"[^\n\r\x{2028}\x{2029}]"#
        let first = "(25[0-5]|2[0-4][0-9]|[0-1]{1}[0-9]{2}|[1-9]{1}[0-9]{1}|[1-9])"
        let middle = "(25[0-5]|2[0-4][0-9]|[0-1]{1}[0-9]{2}|[1-9]{1}[0-9]{1}|[1-9]|0)"
        let last = "(25[0-5]|2[0-4][0-9]|[0-1]{1}[0-9]{2}|[1-9]{1}[0-9]{1}|[0-9])"
        let host = #"\A([a-zA-Z0-9.\-]+(:[a-zA-Z0-9.\&amp;%\$\-]+)*@)*("# + first + any + middle + any + middle + any + last
            + #"|([a-zA-Z0-9\-]+"# + any + #")*[a-zA-Z0-9\-]+"# + any + "(com|edu|gov|int|mil|net|org|biz|arpa|info|name|pro|aero|coop|museum|[a-zA-Z]{2}))\\z"
        let b = "(?:(?<=[A-Za-z0-9_])(?![A-Za-z0-9_])|(?<![A-Za-z0-9_])(?=[A-Za-z0-9_]))"
        let octet = "((25[0-5])|(1[0-9]{2})|(2[0-4][0-9])|([0-9]{1,2}))"
        let v4 = "((" + b + octet + b + #")\.){3}("# + b + octet + b + ")"
        let h = "[0-9A-Fa-f]{1,4}"
        let alternatives = ["((\(h):){7}\(h))", "((\(h):){6}:\(h))", "((\(h):){5}:(\(h):)?\(h))", "((\(h):){4}:(\(h):){0,2}\(h))",
                            "((\(h):){3}:(\(h):){0,3}\(h))", "((\(h):){2}:(\(h):){0,4}\(h))", "((\(h):){6}" + v4 + ")",
                            "((\(h):){0,5}:" + v4 + ")", "(::(\(h):){0,5}" + v4 + ")", "(\(h)::(\(h):){0,5}\(h))", "(::(\(h):){0,6}\(h))",
                            "((\(h):){1,7}:)"]
        let ipv6 = "\\A(" + alternatives.joined(separator: "|") + ")\\z"
        return [try! NSRegularExpression(pattern: host), try! NSRegularExpression(pattern: ipv6)]
    }()

    // MARK: Hot standby panel (2061–2094)

    /// add_option_count(detect_interval, detect_count, 5) (1937–1964): values 1–99, shown as count × interval.
    mutating func addOptionCount() {
        detectCount.removeAll()
        let step = SiteSurvey.parseInt(.string(detectInterval)) ?? .nan
        for count in 1...99 {
            detectCount.put(.init(text: javaScriptText(Double(count) * step), value: "\(count)"), at: detectCount.options.count)
            if count == 5 { detectCount.choose(count - 1) }
        }
    }
    /// update_str_time (2001–2009), on leaving the interval field and on choosing a count: the alert, if any.
    public mutating func updateStandbyTime() -> String? {
        if let alert = WebValidator.numberRange(&detectInterval, 1, 9) { return alert }
        let interval = SiteSurvey.parseInt(.string(detectInterval)) ?? .nan, count = SiteSurvey.parseInt(.string(detectCount.value)) ?? .nan
        standbyDetectionTime = javaScriptText(interval * count)
        return nil
    }
    public mutating func chooseDetectCount(_ index: Int) { detectCount.choose(index) }
    /// 是 (change_detect_settings 2011–2017) copies the two values into the watchdog fields; 否 (remain_origins 2019–2023)
    /// does not. Both submit the form, without the reboot question.
    public mutating func answerStandby(changing: Bool) -> DualWANSubmission {
        standbyPanelShown = false
        if changing { interval = detectInterval; maxfail = detectCount.value }
        return submission
    }

    // MARK: The submitted form

    /// The form's successful controls in document order: enabled, named, and (for check boxes, radios and selects)
    /// checked or selected.
    public var submission: DualWANSubmission {
        typealias Field = DualWANSubmission.Field
        var fields = inputs.filter { !$0.disabled }.map { Field(name: $0.name, value: $0.value) }
        fields.append(Field(name: "detect_interval", value: detectInterval))
        if let value = detectCount.selectedValue { fields.append(Field(name: "detect_count", value: value)) }
        if let value = primary.selectedValue { fields.append(Field(name: "wans_primary", value: value)) }
        if let value = lanport1.selectedValue { fields.append(Field(name: "wans_lanport1", value: value)) }
        if !second.disabled, let value = second.selectedValue { fields.append(Field(name: "wans_second", value: value)) }
        if let value = lanport2.selectedValue { fields.append(Field(name: "wans_lanport2", value: value)) }
        if let usbBackup { fields.append(Field(name: "wans_usb_bk", value: usbBackup)) }
        fields.append(Field(name: "wans_mode", value: wansMode))
        if !standby.disabled, let value = standby.selectedValue { fields.append(Field(name: "wans_standby", value: value)) }
        for ratio in [ratio0, ratio1] where !ratio.disabled { fields.append(Field(name: ratio.name, value: ratio.value)) }
        if !ispUnit.disabled, let unit = ispUnit.checked { fields.append(Field(name: "wans_isp_unit", value: unit)) }
        for (name, select) in [("wan0_isp_country", wan0Country), ("wan0_isp_list", wan0List), ("wan1_isp_country", wan1Country), ("wan1_isp_list", wan1List)]
        where !select.disabled {
            if let value = select.selectedValue { fields.append(Field(name: name, value: value)) }
        }
        fields.append(Field(name: "wandog_interval", value: interval))
        fields.append(Field(name: "wandog_maxfail", value: maxfail))
        if let fbCount { fields.append(Field(name: "wandog_fb_count", value: fbCount)) }
        if dnsProbeChecked { fields.append(Field(name: "dns_probe_chk", value: "")) }
        if pingChecked { fields.append(Field(name: "wandog_enable_chk", value: "")) }
        for field in [dnsProbeHost, wandogTarget] where !field.disabled { fields.append(Field(name: field.name, value: field.value)) }
        if !routingEnable.disabled, let value = routingEnable.checked { fields.append(Field(name: "wans_routing_enable", value: value)) }
        return DualWANSubmission(fields: fields + appended)
    }
}

// MARK: - Reading and sending

/// What start_apply.htm answered (update_variables, web.c 5954–6100): done_committing() when a variable changed, after
/// which the service runs; no_changes_and_no_committing() when nothing changed, and then apply_new runs no service.
public enum DualWANApplyResult: Sendable, Equatable {
    case restarting
    case unchanged
    case unconfirmed
}

extension RouterClient {
    /// nvram_char_to_ascii(name,name) as the router writes it, still percent-encoded, six names to a request.
    func readEncodedSettings(_ keys: [String]) async throws -> [String: String] {
        let unique = Array(Set(keys)).sorted()
        guard unique.count <= 600, unique.allSatisfy({ $0.range(of: #"^[A-Za-z][A-Za-z0-9_.]{0,79}$"#, options: .regularExpression) != nil }) else {
            throw RouterError.invalidResponse("设置字段")
        }
        var result: [String: String] = [:]
        for start in stride(from: 0, to: unique.count, by: 6) {
            let batch = Array(unique[start..<min(start + 6, unique.count)])
            let object = try RouterParser.json(try await request("appGet.cgi", query: [.init(name: "hook", value: batch.map { "nvram_char_to_ascii(\($0),\($0))" }.joined(separator: ";"))]))
            for key in batch {
                if let value = object[key] as? String { result[key] = value }
                else if let value = object[key] as? NSNumber { result[key] = value.stringValue }
            }
            guard batch.allSatisfy({ result[$0] != nil }) else {
                throw RouterError.validation("路由器未完整返回设置，暂不允许保存。缺失字段：" + batch.filter { result[$0] == nil }.joined(separator: ", "))
            }
        }
        return result
    }

    /// Everything the page reads when it opens, with get_vlan_portlist's reads, which the page makes on 应用本页面设置.
    public func dualWANPage() async throws -> DualWANPage {
        let support = try await uiCapabilities()
        let ethernet = try await optionalHook("get_ethernet_wan_list")
        var encoded = try await readEncodedSettings(DualWANPage.keys + DualWANPage.extraKeys(ethernet) + DualWANPage.apgKeys(support))
        let dutKeys = DualWANPage.dutKeys(encoded, support: support)
        if !dutKeys.isEmpty { encoded.merge(try await readEncodedSettings(dutKeys)) { _, new in new } }
        let reboot = try await optionalHook("get_default_reboot_time").map(TORSettings.javaScriptString) ?? ""
        let dpi = try await optionalHook("bwdpi_engine_status")
        var mac = "", status: OrderedJSON?
        if !["", "0"].contains(support["NEW_PHYMAP"] ?? "") {
            // `(hookGet('get_lan_hwaddr')) ? hookGet('get_lan_hwaddr') : ''` (192).
            mac = try await optionalHook("get_lan_hwaddr").map(TORSettings.javaScriptString) ?? ""
            if !mac.isEmpty, let text = try await optionalDataPage(.portStatus, [("node_mac", mac)]) { status = try? OrderedJSON(data: Data(text.utf8)) }
        }
        var dns: OrderedJSON?
        do {
            let version = (encoded["extendno"] ?? "").removingPercentEncoding ?? encoded["extendno"] ?? ""
            let data = try await request("ajax/DNS_List.json", query: [.init(name: "v", value: version)], timeout: 30)
            dns = try? OrderedJSON(data: data)
        } catch RouterError.authenticationRequired {
            throw RouterError.authenticationRequired
        } catch is CancellationError {
            throw CancellationError()
        } catch {}
        return DualWANPage(encoded: encoded, support: support, ethernetList: ethernet, rebootTime: reboot, dpiStatus: dpi,
                           lanMAC: mac, portStatus: status, dnsList: dns)
    }

    /// httpApi.nvramDefaultGet(["wans_mode"]).wans_mode (2143, 2179): nvram_default_get, "" when the request fails.
    public func dualWANDefaultMode() async throws -> String {
        do {
            return try OrderedJSON(data: try await request("appGet.cgi", query: [.init(name: "hook", value: "nvram_default_get(wans_mode)")]))["wans_mode"]?.text ?? ""
        } catch RouterError.authenticationRequired {
            throw RouterError.authenticationRequired
        } catch is CancellationError {
            throw CancellationError()
        } catch { return "" }
    }

    /// httpApi.nvramGet(["wans_usb_bk_act"], true).wans_usb_bk_act (2189), "" when the request fails.
    public func dualWANUSBBackupActive() async throws -> String {
        do {
            let encoded = try await readEncodedSettings(["wans_usb_bk_act"])
            return DualWANPage(encoded: encoded, support: [:], ethernetList: nil, rebootTime: "", dpiStatus: nil, lanMAC: "", portStatus: nil, dnsList: nil)
                .js("wans_usb_bk_act")
        } catch RouterError.authenticationRequired {
            throw RouterError.authenticationRequired
        } catch is CancellationError {
            throw CancellationError()
        } catch { return "" }
    }

    /// Once the router has applied the form: the variables of it that httpd keeps (see DualWANSubmission.kept), the first
    /// of a name as httpd takes it, read back and compared.
    public func checkDualWAN(_ submission: DualWANSubmission) async throws -> ApplyReceipt {
        var sent: [String: String] = [:]
        for field in submission.fields where DualWANSubmission.kept(field.name) && sent[field.name] == nil {
            sent[field.name] = field.value
        }
        let keys = sent.keys.sorted()
        let after = try await readSettings(keys)
        let unverified = keys.filter { after[$0]?.replacingOccurrences(of: "&#60", with: "<").replacingOccurrences(of: "&#62", with: ">") != sent[$0] }
        return ApplyReceipt(verified: keys.filter { !unverified.contains($0) }, unverified: unverified,
                            message: unverified.isEmpty ? "已从路由器重新读取，双线路设置与提交的一致。" : "路由器已恢复，但这些设置与提交值不一致：" + unverified.joined(separator: "、") + "。请重新读取并检查。")
    }

    /// document.form.submit() (1258, 1261, 2016, 2022): the form to start_apply.htm. With a change the router runs the
    /// service, which restarts it; checkDualWAN reads the values once it is back.
    public func submitDualWAN(_ submission: DualWANSubmission) async throws -> DualWANApplyResult {
        try acquireMutation(); defer { releaseMutation() }
        let body = RouterAuthentication.orderedForm(submission.fields.map { ($0.name, $0.value) }, .formSubmission)
        let data = try await request("start_apply.htm", method: "POST", body: body, contentType: "application/x-www-form-urlencoded", timeout: 60)
        let text = String(decoding: data, as: UTF8.self)
        if text.contains("<script>no_changes_and_no_committing();</script>") { return .unchanged }
        if text.contains("<script>done_committing();</script>") { return .restarting }
        return .unconfirmed
    }
}
