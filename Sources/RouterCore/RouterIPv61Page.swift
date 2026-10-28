import Foundation

// 1.13：外部网络 › IPv6 › 第二 WAN（Advanced_IPv61_Content.asp，双线路开启时显示），按 Asuswrt-Merlin tag 3006.102.5。页面读取的
// 变量与能力；表单按网页的 showInputfield / showInputfield2 显示与启用（这一页的 inputCtrl 停用控件时连同所在行一起隐藏，停用的
// 控件不提交）；validForm 的检查与改写；applyRule 组合后提交到 start_apply.htm 的表单。行号均指该页。

// MARK: - The page

/// 外部网络 › IPv6 › 第二 WAN (Advanced_IPv61_Content.asp): what the page reads when it opens. The form is IPv61Form.
public struct IPv61Page: Sendable, Equatable {
    /// The page's `<% nvram_get %>` (26–40, 131–141, 942, 986–1307), wans_dualwan (state.js 945) and enable_ftp (the page's
    /// httpApi.nvramGet, 52). wan_unit and the _s copies (996, 1000–1002) are not on the page; they are read to show what the
    /// form's fixed wan_unit=0 and applyRule's copies change. While the router renders the page, wan_get_parameter() (24)
    /// copies wanN_ variables to wan_; the app reads with appGet and does not ask for the page, so that does not happen.
    static let keys = ["wan1_proto", "wan1_ipaddr", "ipv6_unit", "enable_ftp", "wans_dualwan", "wans_lanport", "productid", "preferred_lang",
                       "firmver", "wan_unit", "ipv61_service", "ipv61_ifdev", "ipv61_dhcp_pd", "ipv61_accept_defrtr", "ipv61_tun_v4end", "ipv61_relay",
                       "ipv61_6rd_dhcp", "ipv61_6rd_prefix", "ipv61_6rd_prefixlen", "ipv61_6rd_router", "ipv61_6rd_ip4size", "ipv61_tun_addr",
                       "ipv61_tun_addrlen", "ipv61_tun_peer", "ipv61_tun_mtu", "ipv61_tun_ttl", "ipv61_ipaddr", "ipv61_prefix_len_wan",
                       "ipv61_gateway", "ipv61_rtr_addr", "ipv61_prefix_length", "ipv61_prefix", "ipv61_autoconf_type", "ipv61_dhcp_start",
                       "ipv61_dhcp_end", "ipv61_dhcp_lifetime", "ipv61_dnsenable", "ipv61_dns1", "ipv61_dns2", "ipv61_dns3", "ipv61_radvd",
                       "ipv61_prefix_length_s", "ipv61_rtr_addr_s", "ipv61_prefix_s"]
    public let values: [String: String]
    /// isSupport("ipv6pt") (state.js 601): Passthrough and FLET'S IPv6 service are offered (initial 58–61).
    public let passthrough: Bool

    public init(values: [String: String], passthrough: Bool) { self.values = values; self.passthrough = passthrough }

    /// The form as initial() (55–79) leaves it.
    public var form: IPv61Form { IPv61Form(self) }
    /// ZVMODELVZ in the dictionary texts.
    public var model: String { values["productid"] ?? "" }
    /// faq_href (53).
    public var faqURL: URL {
        let lang = (values["preferred_lang"] ?? "").addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return URL(string: "https://nw-dlcdnet.asus.com/support/forward.html?model=&type=Faq&lang=\(lang)&kw=&num=108")!
    }
}

/// update_IPv6state.asp, which update_info (885–901) reads every 1.5 seconds while the connection type is the saved one:
/// the second WAN's prefix, prefix length and LAN address as the router holds them.
public struct IPv61State: Sendable, Equatable {
    public let prefix: String
    public let prefixLength: String
    public let rtrAddr: String
    public init(prefix: String, prefixLength: String, rtrAddr: String) { self.prefix = prefix; self.prefixLength = prefixLength; self.rtrAddr = rtrAddr }

    /// The text between the quotes of `state_ipv61_… = "…";`, as the script string holds it.
    init?(script: String) {
        func value(_ name: String) -> String? { RouterParser.capture(#"(?m)^\s*"# + name + #"\s*=\s*"([^"]*)";"#, in: script) }
        guard let prefix = value("state_ipv61_prefix"), let length = value("state_ipv61_prefix_length"), let address = value("state_ipv61_rtr_addr") else { return nil }
        self.init(prefix: prefix, prefixLength: length, rtrAddr: address)
    }
}

// MARK: - The form

/// The page's form `form` (985–1345): every control in document order with its value, checked and disabled state; the
/// tables, rows and spans the page shows or hides. The page's functions keep their names here so they can be read next
/// to the page.
public struct IPv61Form: Sendable, Equatable {
    public enum Table: Sendable, CaseIterable { case basic, wan, lan, dns, autoConfig }
    public enum Span: Sendable, Hashable { case ipaddr, prefixLength, prefix }
    public struct Option: Sendable, Hashable { public let value: String; public let label: String }

    public struct Control: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case hidden, text, readonly, select, radio }
        public let name: String
        public let kind: Kind
        /// A hidden, text or read-only input's value; a radio's value attribute.
        public internal(set) var value: String
        public internal(set) var options: [Option] = []
        /// The selected option of a select, nil when none is.
        public internal(set) var selected: Int?
        public internal(set) var checked = false
        public internal(set) var disabled = false
        /// The table row it sits in; nil for the hidden inputs.
        public let row: String?
        public let maxLength: Int?
        /// A radio's text.
        public let label: String
        /// `.value` as the page reads it: a select's selected option value, "" when none is selected.
        public var current: String { kind == .select ? selected.map { options[$0].value } ?? "" : value }
    }

    public private(set) var controls: [Control]
    var rowDisplay: [String: Bool]
    var tableDisplay: [Table: Bool]
    public private(set) var spans: [Span: String]
    /// ipv61_proto_orig (27): the saved connection type, the legacy static6 read as other (63–66).
    public private(set) var protoOrig: String
    let nvram: [String: String]
    let passthrough: Bool

    init(_ page: IPv61Page) {
        nvram = page.values; passthrough = page.passthrough
        let v = { (key: String) in page.values[key] ?? "" }
        func hidden(_ name: String, _ value: String, disabled: Bool = false) -> Control {
            Control(name: name, kind: .hidden, value: value, disabled: disabled, row: nil, maxLength: nil, label: "")
        }
        func input(_ name: String, _ maxLength: Int, _ value: String? = nil, kind: Control.Kind = .text, row: String? = nil) -> Control {
            Control(name: name, kind: kind, value: value ?? v(name), row: row ?? name, maxLength: maxLength, label: "")
        }
        // nvram_match(…, "selected") marks the saved option; without one the first is selected.
        func choice(_ name: String, _ options: [Option], saved: String) -> Control {
            Control(name: name, kind: .select, value: "", options: options, selected: options.firstIndex { $0.value == saved } ?? 0,
                    row: name, maxLength: nil, label: "")
        }
        func radios(_ name: String, _ choices: [(String, String)], saved: String) -> [Control] {
            choices.map { Control(name: name, kind: .radio, value: $0.0, checked: saved == $0.0, row: name, maxLength: nil, label: $0.1) }
        }
        let onOff = [("1", "启用"), ("0", "关闭")]
        let wan = Self.wanSelection(page.values)
        controls = [
            hidden("productid", v("productid")), hidden("current_page", "Advanced_IPv61_Content.asp"), hidden("next_page", "Advanced_IPv61_Content.asp"),
            hidden("group_id", ""), hidden("modified", "0"), hidden("action_mode", "apply_new"), hidden("action_script", "restart_net"),
            hidden("action_wait", "30"), hidden("preferred_lang", v("preferred_lang")), hidden("firmver", v("firmver")), hidden("wan_unit", "0"),
            hidden("ipv61_ifdev", ""), hidden("ipv61_dhcp_start", v("ipv61_dhcp_start"), disabled: true),
            // 999 fills ipv61_dhcp_end with ipv61_dhcp_start; it stays disabled unless applyRule sets it.
            hidden("ipv61_dhcp_end", v("ipv61_dhcp_start"), disabled: true),
            hidden("ipv61_prefix_length_s", ""), hidden("ipv61_rtr_addr_s", ""), hidden("ipv61_prefix_s", ""), hidden("ipv61_radvd", v("ipv61_radvd")),
            hidden("ipv61_accept_defrtr", v("ipv61_accept_defrtr"), disabled: true),
            Control(name: "wan_selection", kind: .select, value: "", options: wan.options, selected: wan.selected, row: "wan_selection",
                    maxLength: nil, label: ""),
            choice("ipv61_service", Self.services, saved: v("ipv61_service")),
            choice("ipv61_ifdev_select", [Option(value: "ppp", label: "PPP"), Option(value: "eth", label: "以太网")], saved: v("ipv61_ifdev"))
        ]
        controls += radios("ipv61_dhcp_pd", onOff, saved: v("ipv61_dhcp_pd")) + radios("_ipv61_accept_defrtr", onOff, saved: v("ipv61_accept_defrtr"))
        controls += [input("ipv61_tun_v4end", 15), input("ipv61_relay", 15)] + radios("ipv61_6rd_dhcp", onOff, saved: v("ipv61_6rd_dhcp"))
        controls += [input("ipv61_6rd_prefix", 39), input("ipv61_6rd_prefixlen", 3), input("ipv61_6rd_router", 15), input("ipv61_6rd_ip4size", 2),
                     input("ipv61_tun_addr", 39), input("ipv61_tun_addrlen", 3), input("ipv61_tun_peer", 39), input("ipv61_tun_mtu", 4),
                     input("ipv61_tun_ttl", 3), input("ipv61_ipaddr", 39), input("ipv61_prefix_len_wan", 3), input("ipv61_gateway", 39),
                     input("ipv61_rtr_addr", 39), input("ipv61_prefix_length", 3), input("ipv61_prefix", 39)]
        controls += radios("ipv61_autoconf_type", [("0", "Stateless"), ("1", "Stateful")], saved: v("ipv61_autoconf_type"))
        // The pool rows (1250–1266): a read-only prefix, "::" and the part the user types.
        controls += [input("ipv61_prefix_span_for_start", 19, "", kind: .readonly, row: "ipv61_dhcp_start_start"), input("ipv61_dhcp_start_start", 4, ""),
                     input("ipv61_prefix_span_for_end", 19, "", kind: .readonly, row: "ipv61_dhcp_end_end"), input("ipv61_dhcp_end_end", 4, ""),
                     input("ipv61_dhcp_lifetime", 6)]
        controls += radios("ipv61_dnsenable", onOff, saved: v("ipv61_dnsenable"))
        controls += [input("ipv61_dns1", 39), input("ipv61_dns2", 39), input("ipv61_dns3", 39)] + radios("_ipv61_radvd", onOff, saved: v("ipv61_radvd"))
        // Rows the page writes with style="display:none" (1075–1164, 1204, 1284–1304); the others show.
        let hiddenRows = ["ipv61_dhcp_pd", "_ipv61_accept_defrtr", "ipv61_tun_v4end", "ipv61_relay", "ipv61_6rd_dhcp", "ipv61_6rd_prefix",
                          "ipv61_6rd_prefixlen", "ipv61_6rd_router", "ipv61_6rd_ip4size", "ipv61_tun_addr", "ipv61_tun_addrlen", "ipv61_tun_peer",
                          "ipv61_tun_mtu", "ipv61_tun_ttl", "ipv61_rtr_addr", "ipv61_dnsenable", "ipv61_dns1", "ipv61_dns2", "ipv61_dns3"]
        rowDisplay = Dictionary(uniqueKeysWithValues: hiddenRows.map { ($0, false) })
        // auto_config is written hidden (1314).
        tableDisplay = [.basic: true, .wan: true, .lan: true, .dns: true, .autoConfig: false]
        spans = [.ipaddr: "", .prefixLength: "", .prefix: ""]
        protoOrig = v("ipv61_service")
        initial()
    }

    /// The connection types (1050–1061) with their CN.dict names.
    static let services = [Option(value: "disabled", label: "关闭"), Option(value: "dhcp6", label: "Native"), Option(value: "other", label: "静态 IPv6"),
                           Option(value: "ipv6pt", label: "Passthrough"), Option(value: "flets", label: "FLET'S IPv6 service"),
                           Option(value: "6to4", label: "Tunnel 6to4"), Option(value: "6in4", label: "Tunnel 6in4"), Option(value: "6rd", label: "Tunnel 6rd")]

    /// genWANSoption (933–961) after initial()'s `selectedIndex = parseInt(ipv6_unit)`: an option per type of wans_dualwan but
    /// USB, valued by its index (an index left out stays a blank option, as the browser pads the list); the selection is
    /// parseInt(ipv6_unit) (NaN counts as 0), none when the list has no such option.
    static func wanSelection(_ values: [String: String]) -> (options: [Option], selected: Int?) {
        let model = values["productid"] ?? ""
        var options: [Option] = []
        func put(_ index: Int, _ label: String) {
            while options.count < index { options.append(Option(value: "", label: "")) }
            let option = Option(value: String(index), label: label)
            if index < options.count { options[index] = option } else { options.append(option) }
        }
        for (index, type) in (values["wans_dualwan"] ?? "").components(separatedBy: " ").enumerated() {
            var name = type.uppercased()
            if name != "USB" {
                if name == "LAN", ["DSL-N55U", "DSL-N55U-B", "DSL-AC68U", "DSL-AC68R"].contains(model) { name = "Ethernet WAN" }
                else if name == "LAN" { name = "LAN Port " + (values["wans_lanport"] ?? "") }
                put(index, name)
            }
            if ["GT-AXY16000", "RT-AX89U"].contains(model) {
                if name == "WAN2" { put(index, "10G base-T") } else if name == "SFP+" { put(index, "10G SFP+") }
            } else if ["TUF-AX4200", "TUF-AX6000"].contains(model) {
                if name == "WAN" { put(index, "2.5G WAN") } else if name == "LAN Port 5" { put(index, "2.5G LAN") }
            }
        }
        let index = javaScriptInteger(values["ipv6_unit"] ?? "") ?? 0
        return (options, options.indices.contains(index) ? index : nil)
    }

    // MARK: Controls as the page addresses them

    func index(_ name: String, _ nth: Int = 0) -> Int {
        var seen = 0
        for (offset, control) in controls.enumerated() where control.name == name {
            if seen == nth { return offset }
            seen += 1
        }
        preconditionFailure("no control \(name)[\(nth)]")
    }
    public func control(_ name: String, _ nth: Int = 0) -> Control { controls[index(name, nth)] }
    public func radios(_ name: String) -> [Control] { controls.filter { $0.name == name } }
    public func value(_ name: String) -> String { control(name).current }
    mutating func set(_ name: String, _ value: String) { controls[index(name)].value = value }
    func checked(_ name: String, _ nth: Int) -> Bool { control(name, nth).checked }
    /// Checking a radio unchecks the others of its group.
    mutating func check(_ name: String, _ nth: Int) {
        let target = index(name, nth)
        for offset in controls.indices where controls[offset].name == name { controls[offset].checked = offset == target }
    }
    /// RadioNodeList.value: the first checked radio's value, "" when none is checked.
    func radioValue(_ name: String) -> String { radios(name).first { $0.checked }?.value ?? "" }
    /// select.value = value: the first option with that value, none when there is none.
    mutating func select(_ name: String, value: String) {
        let at = index(name)
        controls[at].selected = controls[at].options.firstIndex { $0.value == value }
    }
    /// inputCtrl (state.js 2853–2914) on this page (2904): sets disabled and shows or hides the control's row with it.
    mutating func inputCtrl(_ name: String, _ nth: Int, _ on: Bool) {
        let at = index(name, nth)
        controls[at].disabled = !on
        if let row = controls[at].row { rowDisplay[row] = on }
    }
    mutating func inputCtrl(_ name: String, _ on: Bool) { inputCtrl(name, 0, on) }
    mutating func enable(_ name: String) { controls[index(name)].disabled = false }
    func nv(_ key: String) -> String { nvram[key] ?? "" }
    var pppWAN: Bool { ["l2tp", "pptp", "pppoe"].contains(nv("wan1_proto")) }

    // MARK: What the view shows

    public func isShown(_ table: Table) -> Bool { tableDisplay[table] ?? false }
    /// A row shows while its table does and its own display is not none.
    public func isShown(_ row: Row) -> Bool { isShown(row.table) && rowDisplay[row.id] != false }
    public func text(_ span: Span) -> String { spans[span] ?? "" }
    /// The page polls update_IPv6state.asp while the selected type is the saved one (showInfo 903–916).
    public var updatesState: Bool { value("ipv61_service") == protoOrig }

    // MARK: What the user does

    /// The connection type select's onchange (1050): showInputfield with the new type.
    public mutating func chooseService(_ service: String) {
        guard value("ipv61_service") != service else { return }
        select("ipv61_service", value: service)
        showInputfield(service)
    }
    /// The interface select's onchange (1068).
    public mutating func chooseInterface(_ value: String) {
        guard self.value("ipv61_ifdev_select") != value else { return }
        select("ipv61_ifdev_select", value: value)
        showInputfield2("ipv61_ifdev", value)
    }
    /// A radio click: it is checked, then its onclick runs (1078–1079, 1107–1108, 1246–1247, 1287–1288).
    public mutating func click(_ name: String, _ nth: Int) {
        guard !control(name, nth).disabled else { return }
        check(name, nth)
        let value = control(name, nth).value
        if ["ipv61_dhcp_pd", "ipv61_6rd_dhcp", "ipv61_autoconf_type", "ipv61_dnsenable"].contains(name) { showInputfield2(name, value) }
    }
    /// An edit of a text field as a browser takes it (WebValidator.edit): maxlength holds what is typed or pasted to the
    /// limit; a key typed into the lease time goes through validator.isNumber (onkeypress, 1271), and pasted text stays as
    /// it is for validForm. `key` is the character of the key press that made the edit, nil for anything else; `replaced`
    /// is the part of the old value the edit replaced, as the text field reported it.
    public mutating func type(_ name: String, _ text: String, key: Character? = nil, replaced: Range<Int>? = nil) {
        let at = index(name)
        guard controls[at].kind == .text, !controls[at].disabled else { return }
        controls[at].value = WebValidator.edit(controls[at].value, text, typed: key, maxLength: controls[at].maxLength,
                                               replaced: replaced, keyPress: WebValidator.numberKeyPress(name == "ipv61_dhcp_lifetime"))
    }
    /// ipv61_rtr_addr's onBlur (1207).
    public mutating func blurLANAddress() {
        showInputfield2("ipv61_autoconf_type", checked("ipv61_autoconf_type", 1) ? "1" : "0")
    }

    // MARK: The page's functions

    /// initial() (55–79) after the controls are rendered: Passthrough and FLET'S go without ipv6pt support, static6 is
    /// shown as other, and the fields follow the saved type. The WAN selection is set in init (genWANSoption).
    mutating func initial() {
        if !passthrough {
            let at = index("ipv61_service")
            let kept = controls[at].current
            controls[at].options.removeAll { ["ipv6pt", "flets"].contains($0.value) }
            // Removing the selected option selects the first (the selectedness setting algorithm).
            controls[at].selected = controls[at].options.firstIndex { $0.value == kept } ?? 0
        }
        if protoOrig == "static6" { protoOrig = "other"; select("ipv61_service", value: "other") }
        showInputfield(protoOrig)
    }

    /// showInputfield (81–463).
    mutating func showInputfield(_ v: String) {
        let tunnels = ["ipv61_tun_addr", "ipv61_tun_addrlen", "ipv61_tun_peer"]
        let sixrd = ["ipv61_6rd_prefix", "ipv61_6rd_prefixlen", "ipv61_6rd_router", "ipv61_6rd_ip4size"]
        let wanFields = ["ipv61_ipaddr", "ipv61_prefix_len_wan", "ipv61_gateway"]
        let pool = ["ipv61_dhcp_start_start", "ipv61_dhcp_end_end", "ipv61_dhcp_lifetime"]
        func off(_ names: [String]) { for name in names { inputCtrl(name, false) } }
        func radiosCtrl(_ name: String, _ on: Bool) { inputCtrl(name, 0, on); inputCtrl(name, 1, on) }
        if v == "dhcp6" {
            if pppWAN {
                inputCtrl("ipv61_ifdev_select", true)
                showInputfield2("ipv61_ifdev", value("ipv61_ifdev_select"))
            } else {
                inputCtrl("ipv61_ifdev_select", false)
                showInputfield2("ipv61_ifdev", "0")
            }
            radiosCtrl("ipv61_dhcp_pd", true)
            off(["ipv61_tun_v4end", "ipv61_relay"]); radiosCtrl("ipv61_6rd_dhcp", false); off(sixrd)
            off(tunnels + ["ipv61_tun_mtu", "ipv61_tun_ttl"])
            tableDisplay[.wan] = false
            off(wanFields)
            tableDisplay[.lan] = true
            off(["ipv61_prefix", "ipv61_prefix_length"])
            rowDisplay["ipv61_prefix_r"] = true; rowDisplay["ipv61_prefix_length_r"] = true
            radiosCtrl("ipv61_autoconf_type", true)
            if v != protoOrig {
                check("ipv61_autoconf_type", 0)
                showInputfield2("ipv61_autoconf_type", "0")
                set("ipv61_prefix", ""); set("ipv61_prefix_length", ""); set("ipv61_rtr_addr", "")
                spans[.prefix] = ""; spans[.prefixLength] = ""; spans[.ipaddr] = ""
            } else {
                // '<% nvram_get("ipv61_autoconf_type"); %>' == 0 compares as numbers ("" is 0).
                check("ipv61_autoconf_type", javaScriptLooselyEquals(nv("ipv61_autoconf_type"), 0) ? 0 : 1)
                showInputfield2("ipv61_autoconf_type", nv("ipv61_autoconf_type"))
                set("ipv61_prefix", nv("ipv61_prefix")); set("ipv61_prefix_length", nv("ipv61_prefix_length")); set("ipv61_rtr_addr", nv("ipv61_rtr_addr"))
                spans[.prefix] = nv("ipv61_prefix"); spans[.prefixLength] = nv("ipv61_prefix_length"); spans[.ipaddr] = nv("ipv61_rtr_addr")
            }
            showInputfield2("ipv61_dhcp_pd", checked("ipv61_dhcp_pd", 1) ? "0" : "1")
            tableDisplay[.dns] = true
            radiosCtrl("ipv61_dnsenable", true)
            showInputfield2("ipv61_dnsenable", checked("ipv61_dnsenable", 1) ? "0" : "1")
            tableDisplay[.autoConfig] = true
        } else if passthrough && (v == "ipv6pt" || v == "flets") {
            inputCtrl("ipv61_ifdev_select", pppWAN && v == "ipv6pt")
            radiosCtrl("ipv61_dhcp_pd", false)
            showInputfield2("ipv61_ifdev", "0")
            off(["ipv61_tun_v4end", "ipv61_relay"]); radiosCtrl("ipv61_6rd_dhcp", false); off(sixrd)
            off(tunnels + ["ipv61_tun_mtu", "ipv61_tun_ttl"])
            tableDisplay[.wan] = false
            off(wanFields)
            tableDisplay[.lan] = false
            off(["ipv61_prefix", "ipv61_prefix_length"])
            rowDisplay["ipv61_prefix_r"] = false; rowDisplay["ipv61_prefix_length_r"] = false
            radiosCtrl("ipv61_autoconf_type", false)
            off(pool)
            rowDisplay["ipv61_ipaddr_r"] = false
            tableDisplay[.dns] = true
            radiosCtrl("ipv61_dnsenable", true)
            showInputfield2("ipv61_dnsenable", checked("ipv61_dnsenable", 1) ? "0" : "1")
            tableDisplay[.autoConfig] = false
        } else if v == "6to4" {
            inputCtrl("ipv61_ifdev_select", false)
            radiosCtrl("ipv61_dhcp_pd", false)
            showInputfield2("ipv61_ifdev", "0")
            inputCtrl("ipv61_tun_v4end", false); inputCtrl("ipv61_relay", true)
            radiosCtrl("ipv61_6rd_dhcp", false); off(sixrd); off(tunnels)
            inputCtrl("ipv61_tun_mtu", true); inputCtrl("ipv61_tun_ttl", true)
            tableDisplay[.wan] = false
            off(wanFields)
            tableDisplay[.lan] = true
            off(["ipv61_prefix", "ipv61_prefix_length"])
            rowDisplay["ipv61_prefix_r"] = true; rowDisplay["ipv61_prefix_length_r"] = true
            spans[.prefix] = "2002:" + Self.calcIP6(nv("wan1_ipaddr")) + "::"
            spans[.prefixLength] = "48"
            inputCtrl("ipv61_rtr_addr", false)
            radiosCtrl("ipv61_autoconf_type", false)
            off(pool)
            rowDisplay["ipv61_ipaddr_r"] = true
            spans[.ipaddr] = v != protoOrig ? "" : nv("ipv61_rtr_addr")
            tableDisplay[.dns] = true
            radiosCtrl("ipv61_dnsenable", false)
            showInputfield2("ipv61_dnsenable", "0")
            tableDisplay[.autoConfig] = true
        } else if v == "6in4" {
            inputCtrl("ipv61_ifdev_select", false)
            radiosCtrl("ipv61_dhcp_pd", false)
            showInputfield2("ipv61_ifdev", "0")
            inputCtrl("ipv61_tun_v4end", true); inputCtrl("ipv61_relay", false)
            radiosCtrl("ipv61_6rd_dhcp", false); off(sixrd)
            for name in tunnels + ["ipv61_tun_mtu", "ipv61_tun_ttl"] { inputCtrl(name, true) }
            tableDisplay[.wan] = false
            off(wanFields)
            tableDisplay[.lan] = true
            inputCtrl("ipv61_prefix", true); inputCtrl("ipv61_prefix_length", true)
            rowDisplay["ipv61_prefix_r"] = false; rowDisplay["ipv61_prefix_length_r"] = false
            inputCtrl("ipv61_rtr_addr", false)
            radiosCtrl("ipv61_autoconf_type", false)
            off(pool)
            rowDisplay["ipv61_ipaddr_r"] = true
            if v != protoOrig {
                set("ipv61_prefix", ""); set("ipv61_prefix_length", "")
                spans[.ipaddr] = ""
            } else {
                spans[.ipaddr] = nv("ipv61_rtr_addr")
            }
            tableDisplay[.dns] = true
            radiosCtrl("ipv61_dnsenable", false)
            showInputfield2("ipv61_dnsenable", "0")
            tableDisplay[.autoConfig] = true
        } else if v == "6rd" {
            inputCtrl("ipv61_ifdev_select", false)
            radiosCtrl("ipv61_dhcp_pd", false)
            showInputfield2("ipv61_ifdev", "0")
            inputCtrl("ipv61_tun_v4end", false); inputCtrl("ipv61_relay", false)
            radiosCtrl("ipv61_6rd_dhcp", true)
            for name in sixrd { inputCtrl(name, checked("ipv61_6rd_dhcp", 1)) }
            off(tunnels)
            inputCtrl("ipv61_tun_mtu", true); inputCtrl("ipv61_tun_ttl", true)
            tableDisplay[.wan] = false
            off(wanFields)
            tableDisplay[.lan] = true
            off(["ipv61_prefix", "ipv61_prefix_length"])
            rowDisplay["ipv61_prefix_r"] = true; rowDisplay["ipv61_prefix_length_r"] = true
            inputCtrl("ipv61_rtr_addr", false)
            radiosCtrl("ipv61_autoconf_type", false)
            off(pool)
            rowDisplay["ipv61_ipaddr_r"] = true
            showInputfield2("ipv61_6rd_dhcp", checked("ipv61_6rd_dhcp", 1) ? "0" : "1")
            tableDisplay[.dns] = true
            radiosCtrl("ipv61_dnsenable", false)
            showInputfield2("ipv61_dnsenable", "0")
            tableDisplay[.autoConfig] = true
        } else if v == "other" {
            inputCtrl("ipv61_ifdev_select", pppWAN)
            radiosCtrl("ipv61_dhcp_pd", false)
            showInputfield2("ipv61_ifdev", "0")
            off(["ipv61_tun_v4end", "ipv61_relay"]); radiosCtrl("ipv61_6rd_dhcp", false); off(sixrd)
            off(tunnels + ["ipv61_tun_mtu", "ipv61_tun_ttl"])
            tableDisplay[.wan] = true
            for name in wanFields { inputCtrl(name, true) }
            if v != protoOrig { for name in wanFields { set(name, "") } }
            tableDisplay[.lan] = true
            rowDisplay["ipv61_prefix_r"] = true; rowDisplay["ipv61_prefix_length_r"] = false
            inputCtrl("ipv61_prefix", false); inputCtrl("ipv61_prefix_length", true); inputCtrl("ipv61_rtr_addr", true)
            radiosCtrl("ipv61_autoconf_type", true)
            if v != protoOrig {
                check("ipv61_autoconf_type", 0)
                showInputfield2("ipv61_autoconf_type", "0")
                spans[.prefix] = ""
                set("ipv61_prefix_length", ""); set("ipv61_rtr_addr", "")
            } else {
                check("ipv61_autoconf_type", javaScriptLooselyEquals(nv("ipv61_autoconf_type"), 0) ? 0 : 1)
                showInputfield2("ipv61_autoconf_type", nv("ipv61_autoconf_type"))
                spans[.prefix] = nv("ipv61_prefix")
                set("ipv61_prefix_length", nv("ipv61_prefix_length")); set("ipv61_rtr_addr", nv("ipv61_rtr_addr"))
            }
            rowDisplay["ipv61_ipaddr_r"] = false
            tableDisplay[.dns] = true
            radiosCtrl("ipv61_dnsenable", false)
            showInputfield2("ipv61_dnsenable", "0")
            tableDisplay[.autoConfig] = true
        } else {
            // disabled, and every type the page has no branch for.
            inputCtrl("ipv61_ifdev_select", false)
            radiosCtrl("ipv61_dhcp_pd", false)
            showInputfield2("ipv61_ifdev", "0")
            off(["ipv61_tun_v4end", "ipv61_relay"]); radiosCtrl("ipv61_6rd_dhcp", false); off(sixrd)
            off(tunnels + ["ipv61_tun_mtu", "ipv61_tun_ttl"])
            tableDisplay[.wan] = false
            off(wanFields)
            tableDisplay[.lan] = false
            off(["ipv61_prefix", "ipv61_prefix_length"])
            rowDisplay["ipv61_prefix_r"] = false; rowDisplay["ipv61_prefix_length_r"] = false
            inputCtrl("ipv61_rtr_addr", false)
            radiosCtrl("ipv61_autoconf_type", false)
            off(pool)
            rowDisplay["ipv61_ipaddr_r"] = false
            tableDisplay[.dns] = false
            radiosCtrl("ipv61_dnsenable", false)
            showInputfield2("ipv61_dnsenable", "1")
            tableDisplay[.autoConfig] = false
        }
        // update_info (457–461) is the view's polling, while updatesState holds.
    }

    /// showInputfield2 (466–572). v is the value the page passes; its number 0 is "0" here.
    mutating func showInputfield2(_ s: String, _ v: String) {
        let enable = v == "0"
        switch s {
        case "ipv61_6rd_dhcp":
            for name in ["ipv61_6rd_prefix", "ipv61_6rd_prefixlen", "ipv61_6rd_router", "ipv61_6rd_ip4size"] { inputCtrl(name, enable) }
            if v != nv("ipv61_6rd_dhcp") || value("ipv61_service") != protoOrig {
                spans[.prefix] = ""; spans[.prefixLength] = ""; spans[.ipaddr] = ""
            } else {
                spans[.prefix] = nv("ipv61_prefix"); spans[.prefixLength] = nv("ipv61_prefix_length"); spans[.ipaddr] = nv("ipv61_rtr_addr")
            }
        case "ipv61_dnsenable":
            for name in ["ipv61_dns1", "ipv61_dns2", "ipv61_dns3"] { inputCtrl(name, enable) }
        case "ipv61_dhcp_pd":
            inputCtrl("ipv61_rtr_addr", enable)
            inputCtrl("ipv61_prefix_length", enable)
            // Both branches leave ipv61_prefix_len_wan enabled (inputCtrl(…, enable) and inputCtrl(…, !enable)).
            inputCtrl("ipv61_prefix_len_wan", true)
            tableDisplay[.wan] = !enable
            rowDisplay["ipv61_ipaddr_r"] = !enable; rowDisplay["ipv61_prefix_length_r"] = !enable
            if !enable { spans[.prefixLength] = "" }
            showInputfield2("ipv61_autoconf_type", checked("ipv61_autoconf_type", 0) ? "0" : "1")
        case "ipv61_autoconf_type":
            let delegated = checked("ipv61_dhcp_pd", 0)
            var prefix = Self.getIPv6Split(delegated ? text(.ipaddr) : value("ipv61_rtr_addr")) + "::"
            if prefix == "::" { prefix = "" }
            spans[.prefix] = prefix
            for name in ["ipv61_dhcp_start_start", "ipv61_dhcp_end_end", "ipv61_dhcp_lifetime"] { inputCtrl(name, !enable) }
            let startOrig = nv("ipv61_dhcp_start"), endOrig = nv("ipv61_dhcp_end")
            func fill(from address: String) {
                let split = address != "" ? Self.getIPv6Split(address) : ""
                set("ipv61_prefix_span_for_start", split); set("ipv61_prefix_span_for_end", split)
                if startOrig != "", endOrig != "" {
                    set("ipv61_dhcp_start_start", Self.part(startOrig, 1)); set("ipv61_dhcp_end_end", Self.part(endOrig, 1))
                } else {
                    set("ipv61_dhcp_start_start", "1000"); set("ipv61_dhcp_end_end", "2000")
                }
            }
            if !delegated || value("ipv61_service") == "other" {
                fill(from: value("ipv61_rtr_addr"))
            } else if !checked("ipv61_dhcp_pd", 1) {
                fill(from: text(.ipaddr))
            }
            // The third branch (561–566) needs both DHCP-PD radios checked, which a radio group never has.
        case "ipv61_ifdev":
            let on = value("ipv61_service") == "dhcp6" && v == "ppp"
            inputCtrl("_ipv61_accept_defrtr", 0, on); inputCtrl("_ipv61_accept_defrtr", 1, on)
        default:
            break
        }
    }

    /// showInfo (903–916) with update_IPv6state.asp's values: the spans whose rows show take them while the selected type
    /// is the saved one.
    public mutating func showInfo(_ state: IPv61State) {
        guard updatesState else { return }
        if rowDisplay["ipv61_prefix_r"] != false { spans[.prefix] = state.prefix }
        if rowDisplay["ipv61_prefix_length_r"] != false { spans[.prefixLength] = state.prefixLength }
        if rowDisplay["ipv61_ipaddr_r"] != false { spans[.ipaddr] = state.rtrAddr }
    }

    /// `text.split("::")[n]`: "undefined" when there is no such part, as the page then writes.
    static func part(_ text: String, _ n: Int) -> String {
        let parts = text.components(separatedBy: "::")
        return n < parts.count ? parts[n] : "undefined"
    }

    /// GetIPv6_split (624–648): the part before "::" (the first four groups when it has more than four); without "::" the
    /// first four groups ("undefined" for a missing one); "" without any colon.
    static func getIPv6Split(_ address: String) -> String {
        let halves = address.components(separatedBy: "::"), groups = address.components(separatedBy: ":")
        func firstFour() -> String { (0..<4).map { $0 < groups.count ? groups[$0] : "undefined" }.joined(separator: ":") }
        if halves.count > 1 { return halves[0].components(separatedBy: ":").count > 4 ? firstFour() : halves[0] }
        return groups.count > 1 ? firstFour() : ""
    }

    /// calcIP6 (662–681): the IPv4 address's four parts (parseInt) as two-digit hex, "NaN" for one that is not a number.
    static func calcIP6(_ ip: String) -> String {
        let octets = ip.components(separatedBy: ".")
        let hex = (0..<4).map { i -> String in
            guard let number = SiteSurvey.parseInt(i < octets.count ? .string(octets[i]) : nil) else { return "NaN" }
            let text = abs(number) < 9.2e18 ? String(Int64(number), radix: 16) : javaScriptText(number)
            return number < 16 ? "0" + text : text
        }
        return hex[0] + hex[1] + ":" + hex[2] + hex[3]
    }

    // MARK: 应用本页面设置

    /// Where validForm stops: the page's alert and the field it focuses.
    public struct Stop: Error, Equatable {
        public let alert: String
        public let field: String
    }

    /// applyRule (803–882): validForm on the form itself (its rewrites and cleared fields stay, as on the page), then the
    /// form applyRule submits.
    public mutating func apply() -> Result<Submission, Stop> {
        if let stop = validForm() { return .failure(stop) }
        var form = self
        form.applyRule()
        return .success(Submission(fields: form.entries(), service: form.value("ipv61_service")))
    }

    // Validators bound to a field: the check's alert and the field it focuses.
    private mutating func range(_ name: String, _ minimum: Double, _ maximum: Double) -> Stop? {
        var value = self.value(name)
        defer { set(name, value) }
        return WebValidator.range(&value, minimum, maximum).map { Stop(alert: $0, field: name) }
    }
    private mutating func rangeAllowZero(_ name: String, _ minimum: Double, _ maximum: Double, _ fallback: String) -> Stop? {
        var value = self.value(name)
        defer { set(name, value) }
        return WebValidator.rangeAllowZero(&value, minimum, maximum, default: fallback).map { Stop(alert: $0, field: name) }
    }
    private mutating func ipRange(_ name: String) -> Stop? {
        var value = self.value(name)
        defer { set(name, value) }
        return WebValidator.ipRange(&value).map { Stop(alert: $0, field: name) }
    }
    private func legalIPv6(_ name: String) -> Stop? { WebValidator.isLegalIPv6(value(name)).map { Stop(alert: $0, field: name) } }
    /// validIPv6_dhcp (650–659): one to four hex digits.
    private func validIPv6DHCP(_ name: String) -> Stop? {
        let text = value(name)
        let ok = (1...4).contains(text.utf16.count) && text.unicodeScalars.allSatisfy { $0.isASCII && $0.properties.isASCIIHexDigit }
        return ok ? nil : Stop(alert: text + " 不是有效的 IP 地址！", field: name)
    }
    private mutating func validIP(_ name: String) -> Stop? {
        var value = self.value(name)
        defer { set(name, value) }
        return Self.validIP(&value).map { Stop(alert: $0, field: name) }
    }
    /// valid_IP (578–622) with flag "": strictly inside 1.0.0.0–126.255.255.255 or 128.0.0.0–255.255.255.255 (general.js
    /// inet_network), then written without leading zeros (ipFilterZero); anything else is cleared.
    static func validIP(_ value: inout String) -> String? {
        let number = WebValidator.inetNetwork(value)
        if (number > 16_777_216 && number < 2_130_706_431) || (number > 2_147_483_648 && number < 4_294_967_295) {
            value = value.components(separatedBy: ".").map { String(Int($0) ?? 0) }.joined(separator: ".")
            return nil
        }
        let alert = value + " 不是有效的 IP 地址！"
        value = ""
        return alert
    }
    /// The Stateful pool (704–720, 735–751): both parts hex, the start not above the end, then the lease time.
    private mutating func checkPool() -> Stop? {
        if let stop = validIPv6DHCP("ipv61_dhcp_start_start") ?? validIPv6DHCP("ipv61_dhcp_end_end") { return stop }
        let start = value("ipv61_dhcp_start_start")
        if (Int(start, radix: 16) ?? 0) > (Int(value("ipv61_dhcp_end_end"), radix: 16) ?? 0) {
            return Stop(alert: "此设置值须高于 " + start, field: "ipv61_dhcp_end_end")
        }
        return range("ipv61_dhcp_lifetime", 120, 604_800)
    }

    /// validForm (683–800); the checks run in the page's order and the first failure stops it.
    mutating func validForm() -> Stop? {
        let service = value("ipv61_service")
        // Stateful autoconfiguration takes 16 of the 128 bits (695, 725).
        let lanLimit: Double = checked("ipv61_autoconf_type", 1) ? 112 : 126
        if service == "other" {
            if let stop = legalIPv6("ipv61_ipaddr") ?? range("ipv61_prefix_len_wan", 3, 128) { return stop }
            if value("ipv61_gateway") != "", let stop = legalIPv6("ipv61_gateway") { return stop }
            if let stop = range("ipv61_prefix_length", 3, lanLimit) ?? legalIPv6("ipv61_rtr_addr") { return stop }
            if checked("ipv61_autoconf_type", 1), let stop = checkPool() { return stop }
        } else if service == "dhcp6" {
            if checked("ipv61_dhcp_pd", 1), let stop = range("ipv61_prefix_length", 3, lanLimit) ?? legalIPv6("ipv61_rtr_addr") { return stop }
            if checked("ipv61_autoconf_type", 1), let stop = checkPool() { return stop }
        } else if ["6to4", "6in4", "6rd"].contains(service) {
            if let stop = rangeAllowZero("ipv61_tun_mtu", 1280, 1480, "0") ?? rangeAllowZero("ipv61_tun_ttl", 0, 255, "255") { return stop }
        }
        let manualDNS = checked("ipv61_dnsenable", 1)
        if (service == "dhcp6" && manualDNS) || (passthrough && ["ipv6pt", "flets"].contains(service) && manualDNS)
            || ["other", "6to4", "6in4", "6rd"].contains(service) {
            for name in ["ipv61_dns1", "ipv61_dns2", "ipv61_dns3"] where value(name) != "" {
                if let stop = legalIPv6(name) { return stop }
            }
        }
        if service == "6to4", let stop = validIP("ipv61_relay") { return stop }
        if service == "6in4" {
            if let stop = ipRange("ipv61_tun_v4end") ?? legalIPv6("ipv61_tun_addr") ?? range("ipv61_tun_addrlen", 3, 128) { return stop }
            if value("ipv61_tun_peer") != "", let stop = legalIPv6("ipv61_tun_peer") { return stop }
            if let stop = range("ipv61_prefix_length", 3, 126) ?? legalIPv6("ipv61_prefix") { return stop }
        }
        if service == "6rd" && checked("ipv61_6rd_dhcp", 1) {
            if let stop = ipRange("ipv61_6rd_router") ?? range("ipv61_6rd_ip4size", 0, 32) { return stop }
            if let stop = legalIPv6("ipv61_6rd_prefix") { return stop }
            // 126 − (32 − ipv61_6rd_ip4size), the size as range left it, in JavaScript arithmetic.
            let limit = 126 - (32 - (javaScriptNumber(value("ipv61_6rd_ip4size")) ?? .nan))
            if let stop = range("ipv61_6rd_prefixlen", 3, limit) { return stop }
        }
        return nil
    }

    /// applyRule's changes to the form after validForm (806–874).
    mutating func applyRule() {
        let service = value("ipv61_service")
        func fillPool() {
            enable("ipv61_dhcp_start")
            set("ipv61_dhcp_start", value("ipv61_prefix_span_for_start") + "::" + value("ipv61_dhcp_start_start"))
            enable("ipv61_dhcp_end")
            set("ipv61_dhcp_end", value("ipv61_prefix_span_for_end") + "::" + value("ipv61_dhcp_end_end"))
        }
        if service == "dhcp6" {
            if checked("ipv61_dhcp_pd", 1) { enable("ipv61_prefix_length"); enable("ipv61_prefix") }
            enable("ipv61_accept_defrtr")
            set("ipv61_accept_defrtr", checked("_ipv61_accept_defrtr", 0) ? "1" : "0")
            if checked("ipv61_autoconf_type", 1) { fillPool() }
        }
        if passthrough && service == "flets" {
            inputCtrl("ipv61_ifdev_select", true)
            set("ipv61_ifdev", "eth")
        } else if control("ipv61_ifdev_select").disabled {
            set("ipv61_ifdev", "ppp")
        } else {
            set("ipv61_ifdev", value("ipv61_ifdev_select"))
        }
        if service != "other" && (service != "dhcp6" && radioValue("ipv61_dhcp_pd") != "0") { set("ipv61_rtr_addr", "") }
        if service == "other" {
            set("ipv61_prefix_length_s", value("ipv61_prefix_length")); set("ipv61_rtr_addr_s", value("ipv61_rtr_addr"))
            if checked("ipv61_autoconf_type", 1) { fillPool() }
        }
        if service == "6in4" { set("ipv61_prefix_length_s", value("ipv61_prefix_length")); set("ipv61_prefix_s", value("ipv61_prefix")) }
        set("ipv61_radvd", checked("_ipv61_radvd", 0) ? "1" : "0")
        // enable_ftp_orig == 1 (872–874).
        if javaScriptLooselyEquals(nv("enable_ftp"), 1) { set("action_script", value("action_script") + ";restart_ftpd") }
    }

    /// The form data set: enabled, named controls in document order; a radio only when checked, a select its selected
    /// option (none when nothing is selected).
    func entries() -> [(String, String)] {
        controls.compactMap { control in
            guard !control.disabled, !control.name.isEmpty else { return nil }
            switch control.kind {
            case .radio: return control.checked ? (control.name, control.value) : nil
            case .select: return control.selected.map { (control.name, control.options[$0].value) }
            case .hidden, .text, .readonly: return (control.name, control.value)
            }
        }
    }

    /// What 应用本页面设置 sends: the form to start_apply.htm with action_mode apply_new and action_wait 30.
    public struct Submission: Sendable, Equatable {
        public let fields: [(String, String)]
        /// ipv61_service as submitted.
        public let service: String
        public static func == (a: Submission, b: Submission) -> Bool { a.fields.elementsEqual(b.fields, by: { $0 == $1 }) && a.service == b.service }

        /// action_script: restart_net, with ;restart_ftpd when FTP is on.
        public var script: String { field("action_script") ?? "" }
        public var wait: Int { Int(field("action_wait") ?? "") ?? 30 }
        func field(_ name: String) -> String? { fields.first { $0.0 == name }?.1 }

        /// The page's own controls and the fields start_apply.htm reads; httpd keeps only router_defaults names.
        static let pageFields: Set<String> = ["productid", "current_page", "next_page", "group_id", "modified", "action_mode", "action_script",
                                              "action_wait", "preferred_lang", "firmver", "wan_selection", "ipv61_ifdev_select", "_ipv61_accept_defrtr",
                                              "ipv61_prefix_span_for_start", "ipv61_dhcp_start_start", "ipv61_prefix_span_for_end",
                                              "ipv61_dhcp_end_end", "_ipv61_radvd"]
        /// The router variables the form sets, in form order.
        public var settings: [(String, String)] { fields.filter { !Self.pageFields.contains($0.0) } }
        /// Variables whose value differs from what the page read.
        public func changes(from values: [String: String]) -> [(key: String, before: String, after: String)] {
            settings.filter { values[$0.0] != $0.1 }.map { (key: $0.0, before: values[$0.0] ?? "", after: $0.1) }
        }
        /// The hidden fields applyRule fills from other controls, and the form's fixed wan_unit.
        static let linked: Set<String> = ["ipv61_ifdev", "ipv61_radvd", "ipv61_accept_defrtr", "ipv61_dhcp_start", "ipv61_dhcp_end",
                                          "ipv61_prefix_length_s", "ipv61_rtr_addr_s", "ipv61_prefix_s", "wan_unit"]
        /// What restart_net sets again itself (rc/services.c start_ipv6 3396–3465): the prefix in every mode; the prefix
        /// length and LAN address too, except in static mode (copied back from the _s copies) and Native without DHCP-PD.
        public func setByRouter(original: [String: String]) -> Set<String> {
            let pd = field("ipv61_dhcp_pd") ?? original["ipv61_dhcp_pd"] ?? ""
            if service == "other" || (service == "dhcp6" && (javaScriptInteger(pd) ?? 0) == 0) { return ["ipv61_prefix"] }
            return ["ipv61_prefix", "ipv61_prefix_length", "ipv61_rtr_addr"]
        }
        /// Read back after the wait: the changed and the linked variables, without those restart_net sets itself.
        public func readBack(original: [String: String]) -> [String] {
            let changed = Set(changes(from: original).map(\.key)), router = setByRouter(original: original)
            return settings.map(\.0).filter { (changed.contains($0) || Self.linked.contains($0)) && !router.contains($0) }
        }
    }

    // MARK: Layout

    /// A table row (th and its cell): the row id the page shows and hides, the label (CN.dict) and what the cell holds.
    public struct Row: Sendable, Identifiable {
        public enum Content: Sendable, Equatable {
            case select(String), radios(String), text(String), span(Span)
            /// The read-only prefix, "::" and the typed part (1250–1266).
            case pool(String, String)
        }
        public let id: String
        public let table: Table
        public let label: String
        public let content: Content
    }
    public struct Section: Sendable, Identifiable {
        public let table: Table
        public let title: String
        public let rows: [Row]
        public var id: Table { table }
    }
    /// The page's four tables and the auto configuration table (1034–1327), labels from CN.dict.
    public static let layout: [Section] = {
        func section(_ table: Table, _ title: String, _ rows: [(String, String, Row.Content)]) -> Section {
            Section(table: table, title: title, rows: rows.map { Row(id: $0.0, table: table, label: $0.1, content: $0.2) })
        }
        return [
            section(.basic, "基本设置", [
                ("wan_selection", "WAN 选择", .select("wan_selection")), ("ipv61_service", "联机类型", .select("ipv61_service")),
                ("ipv61_ifdev_select", "接口", .select("ipv61_ifdev_select")), ("ipv61_dhcp_pd", "DHCP-PD", .radios("ipv61_dhcp_pd")),
                ("_ipv61_accept_defrtr", "Accept Default Route", .radios("_ipv61_accept_defrtr")),
                ("ipv61_tun_v4end", "服务器 IPv4 地址", .text("ipv61_tun_v4end")), ("ipv61_relay", "IPv4 任播中繼", .text("ipv61_relay")),
                ("ipv61_6rd_dhcp", "DHCP 选项", .radios("ipv61_6rd_dhcp")), ("ipv61_6rd_prefix", "IPv6 前缀", .text("ipv61_6rd_prefix")),
                ("ipv61_6rd_prefixlen", "IPv6 前缀长度", .text("ipv61_6rd_prefixlen")), ("ipv61_6rd_router", "IPv4 边界路由器", .text("ipv61_6rd_router")),
                ("ipv61_6rd_ip4size", "IPv4 路由器掩码长度", .text("ipv61_6rd_ip4size")), ("ipv61_tun_addr", "用户端 IPv6 地址", .text("ipv61_tun_addr")),
                ("ipv61_tun_addrlen", "IPv6 前缀长度", .text("ipv61_tun_addrlen")), ("ipv61_tun_peer", "服务器 IPv6 地址", .text("ipv61_tun_peer")),
                ("ipv61_tun_mtu", "通道 MTU", .text("ipv61_tun_mtu")), ("ipv61_tun_ttl", "通道 TTL", .text("ipv61_tun_ttl"))
            ]),
            section(.wan, "IPv6 外部网络设置", [
                ("ipv61_ipaddr", "外部网络 IPv6 地址", .text("ipv61_ipaddr")), ("ipv61_prefix_len_wan", "外部网络前缀长度", .text("ipv61_prefix_len_wan")),
                ("ipv61_gateway", "外部网络 IPv6 网关", .text("ipv61_gateway"))
            ]),
            section(.lan, "IPv6 内部网络设置", [
                ("ipv61_rtr_addr", "内部网络 IPv6 地址", .text("ipv61_rtr_addr")), ("ipv61_ipaddr_r", "内部网络 IPv6 地址", .span(.ipaddr)),
                ("ipv61_prefix_length", "内部网络前缀长度", .text("ipv61_prefix_length")),
                ("ipv61_prefix_length_r", "内部网络前缀长度", .span(.prefixLength)),
                ("ipv61_prefix", "内部网络 IPv6 前缀", .text("ipv61_prefix")), ("ipv61_prefix_r", "内部网络 IPv6 前缀", .span(.prefix)),
                ("ipv61_autoconf_type", "自动配置设置", .radios("ipv61_autoconf_type")),
                ("ipv61_dhcp_start_start", "IP 池起始地址", .pool("ipv61_prefix_span_for_start", "ipv61_dhcp_start_start")),
                ("ipv61_dhcp_end_end", "IP 池结束地址", .pool("ipv61_prefix_span_for_end", "ipv61_dhcp_end_end")),
                ("ipv61_dhcp_lifetime", "租约时间", .text("ipv61_dhcp_lifetime"))
            ]),
            section(.dns, "IPv6 DNS 设置", [
                ("ipv61_dnsenable", "自动接上 DNS 服务器", .radios("ipv61_dnsenable")), ("ipv61_dns1", "IPv6 DNS 服务器 1", .text("ipv61_dns1")),
                ("ipv61_dns2", "IPv6 DNS 服务器 2", .text("ipv61_dns2")), ("ipv61_dns3", "IPv6 DNS 服务器 3", .text("ipv61_dns3"))
            ]),
            section(.autoConfig, "自动配置设置", [("_ipv61_radvd", "是否启动路由广播", .radios("_ipv61_radvd"))])
        ]
    }()
    /// A variable's row label, for the confirmation; the hidden fields applyRule fills are named after their controls.
    public static func label(of key: String) -> String? {
        let hidden = ["ipv61_ifdev": "接口", "ipv61_radvd": "是否启动路由广播", "ipv61_accept_defrtr": "Accept Default Route",
                      "ipv61_dhcp_start": "IP 池起始地址", "ipv61_dhcp_end": "IP 池结束地址", "ipv61_prefix_length_s": "内部网络前缀长度（副本）",
                      "ipv61_rtr_addr_s": "内部网络 IPv6 地址（副本）", "ipv61_prefix_s": "内部网络 IPv6 前缀（副本）"]
        return hidden[key] ?? layout.flatMap(\.rows).first { row in
            switch row.content {
            case .select(let name), .radios(let name), .text(let name): name == key
            default: false
            }
        }?.label
    }
}

// MARK: - Reading and saving

extension RouterClient {
    public func ipv61Page() async throws -> IPv61Page {
        let values = try await readSettings(IPv61Page.keys)
        let support = try await uiCapabilities()
        return IPv61Page(values: values, passthrough: !["", "0"].contains(support["ipv6pt"] ?? ""))
    }

    /// update_info (885–901): update_IPv6state.asp.
    /// update_IPv6state.asp with the page's timeout of 1.5 seconds (892).
    public func ipv61State() async throws -> IPv61State {
        guard let state = IPv61State(script: try await readManagementDocument("update_IPv6state.asp", timeout: 1.5)) else { throw RouterError.invalidResponse("IPv6 状态") }
        return state
    }

    /// The form to start_apply.htm (submitted 1.5 seconds after showLoading, 876–880). httpd's validate_apply answers
    /// no_changes_and_no_committing when nothing differs and then runs no service (web.c 5954–5962); otherwise, after the
    /// form's action_wait, the changed and linked variables are read back.
    public func submitIPv61(_ submission: IPv61Form.Submission, page: IPv61Page) async throws -> ApplyReceipt {
        try await submitIPv61(submission, page: page, waiting: .seconds(max(submission.wait, 1)))
    }
    /// The same with the wait given (tests).
    func submitIPv61(_ submission: IPv61Form.Submission, page: IPv61Page, waiting: Duration) async throws -> ApplyReceipt {
        try acquireMutation(); defer { releaseMutation() }
        let reply = try await request("start_apply.htm", method: "POST", body: RouterAuthentication.orderedForm(submission.fields, .formSubmission),
                                      contentType: "application/x-www-form-urlencoded", timeout: 60)
        let unchanged = String(decoding: reply, as: UTF8.self).contains("<script>no_changes_and_no_committing();</script>")
        let keys = submission.readBack(original: page.values)
        let sent = Dictionary(submission.fields, uniquingKeysWith: { _, last in last })
        let skipped = submission.settings.contains { submission.setByRouter(original: page.values).contains($0.0) }
        let note = skipped ? "前缀等由路由器在重启网络时重新设置的项目不核对。" : ""
        do {
            if !unchanged { try await Task.sleep(for: waiting) }
            let after = try await readSettings(keys)
            let unverified = keys.filter { after[$0] != sent[$0] }
            let result = unverified.isEmpty ? "已从路由器重新读取，第二 WAN 的 IPv6 设置已保存。" : "路由器已响应，但部分设置与提交值不一致。请重新读取并检查。"
            return ApplyReceipt(verified: keys.filter { !unverified.contains($0) }, unverified: unverified,
                                message: (unchanged ? "路由器回应没有需要保存的变更，没有重新启动网络。" : "") + result + note)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ApplyReceipt(verified: [], unverified: keys, message: unchanged ? "路由器回应没有需要保存的变更，但重新读取没有完成。请重新读取确认。"
                                                                               : "路由器已接收设置，正在重新启动网络。保存结果仍待重新读取确认。")
        }
    }
}
