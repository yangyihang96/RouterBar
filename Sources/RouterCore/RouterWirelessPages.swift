import Foundation

// 无线 › WPS, WDS, 漫游阻止列表 and MLO, and Smart Connect 规则 (Asuswrt-Merlin 3006.102.5 www/Advanced_WWPS_Content.asp,
// Advanced_WMode_Content.asp, Advanced_Roaming_Block_Content.asp, Advanced_Smart_Connect.asp and
// sysdep/FUNCTION/SDN/MLO.asp with SDN/mlo.html): what each page shows when it opens. Only reads. Not offered: WPS
// pairing (button or PIN), switching or resetting WPS, the WDS page's automatic AP scan, the MLO switch, and every save.

/// The radios as the web names them, from `wlnband_list`: one entry per wl unit, e.g. "2g1<5g1".
public struct WirelessBands: Sendable, Equatable {
    public struct Band: Sendable, Equatable, Identifiable {
        public let unit: Int
        /// "2g1", "5g1", "5g2", "6g1", …
        public let code: String
        /// wl_nband_title: "2.4 GHz", "5 GHz", or "5 GHz-1" and "5 GHz-2" when there are two.
        public let title: String
        public var id: Int { unit }
    }
    public let bands: [Band]

    /// state.js wl_nband_title (349–387). A unit is the entry's position in the list, as get_wl_unit_by_band finds it.
    public init(list: String) {
        let codes = list.components(separatedBy: "<").map { $0.lowercased() }
        func type(_ code: String) -> String { code.hasPrefix("60g") ? "60g" : String(code.prefix(2)) }
        let counts = Dictionary(codes.map { (type($0), 1) }, uniquingKeysWith: +)
        var bands: [Band] = []
        for (unit, code) in codes.enumerated() {
            let kind = type(code)
            guard let frequency = ["2g": "2.4", "5g": "5", "6g": "6", "60g": "60"][kind] else { continue }
            let number = code.dropFirst(kind.count)
            bands.append(Band(unit: unit, code: code, title: (counts[kind] ?? 0) > 1 ? "\(frequency) GHz-\(number)" : "\(frequency) GHz"))
        }
        self.bands = bands
    }
    /// get_wl_unit_by_band (state.js 458–478): "2G", "5G" and "6G" stand for the first band of their kind.
    public func unit(of name: String) -> Int? {
        let wanted = (["2G": "2G1", "5G": "5G1", "6G": "6G1"][name.uppercased()] ?? name.uppercased()).lowercased()
        return bands.first { $0.code == wanted }?.unit
    }
    public func band(unit: Int) -> Band? { bands.first { $0.unit == unit } }
    /// The bands in the order the web lists them (bandName, state.js 2352): 2.4, 5, 5-2, 6, 6-2 GHz. 60 GHz is not among them.
    public var listed: [Band] { ["2G", "5G1", "5G2", "6G1", "6G2"].compactMap { unit(of: $0).flatMap(band(unit:)) } }
    /// wl_info (state.js 389–440).
    var twoFiveGHz: Bool { bands.filter { $0.code.hasPrefix("5g") }.count == 2 }
    var sixGHz: Bool { bands.contains { $0.code.hasPrefix("6g") } }
}

extension RouterClient {
    /// Online devices per network as update_SDN_ClientList() counts them for the MLO and 网络 pages (sdn.js 11292–11307),
    /// by get_clientlist's `sdn_idx`. The page first asks the router to refresh its list (httpApi.updateClientList); the
    /// app only reads the current one.
    public func sdnOnlineCounts() async throws -> [String: Int] {
        try SDNClientCount.parse(try await request("appGet.cgi", query: [.init(name: "hook", value: "get_clientlist()")]))
    }
}

enum SDNClientCount {
    static func parse(_ data: Data) throws -> [String: Int] {
        guard let clients = try RouterParser.json(data)["get_clientlist"] as? [String: Any] else { throw RouterError.invalidResponse("设备列表") }
        var counts: [String: Int] = [:]
        for case let client as [String: Any] in clients.values {
            guard let index = RouterParser.string(client["sdn_idx"]), RouterParser.string(client["isOnline"]) == "1" else { continue }
            counts[index, default: 0] += 1
        }
        return counts
    }
}

/// JavaScript's parseInt: the leading digits after optional white space and a sign; nil where it gives NaN. Without a
/// radix a "0x" prefix reads as hexadecimal, as in JavaScript. It reads code points the way JavaScript reads code units:
/// white space is ECMAScript's (WhiteSpace and LineTerminator: tab, line feed, vertical tab, form feed, carriage return,
/// U+FEFF, U+2028, U+2029 and the Zs space separators), and the number ends at the first code point that is not a digit,
/// a combining mark included.
func javaScriptInteger(_ text: String, radix: Int? = nil) -> Int? {
    var rest = text.unicodeScalars.drop { [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0xFEFF, 0x2028, 0x2029].contains($0.value) || $0.properties.generalCategory == .spaceSeparator }
    var sign = 1
    if let first = rest.first, first == "-" || first == "+" { sign = first == "-" ? -1 : 1; rest = rest.dropFirst() }
    var base = radix ?? 10
    if radix == nil || radix == 16, rest.first == "0", let x = rest.dropFirst().first, x == "x" || x == "X" { base = 16; rest = rest.dropFirst(2) }
    let digits = rest.prefix { $0.isASCII && Int(String($0), radix: base) != nil }.prefix(15)
    return Int(String(String.UnicodeScalarView(digits)), radix: base).map { $0 * sign }
}

/// `text == number` in JavaScript, which the pages use to compare band numbers: spaces around a number are ignored and
/// an empty or blank text counts as 0; a missing value (undefined) matches nothing.
func javaScriptEquals(_ text: String?, _ number: Int) -> Bool {
    guard let text else { return false }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? number == 0 : Double(trimmed) == Double(number)
}

// MARK: - WPS

/// reject_wps() (Advanced_WWPS_Content.asp 56–58): auth modes WPS does not work with, WEP included.
func wpsRejects(auth: String, wep: String) -> Bool {
    (auth == "open" && wep != "0") || ["shared", "psk", "wpa", "wpa2", "wpawpa2", "radius"].contains(auth)
}

/// What the WPS page reads once when it opens (its nvramGet 34 and hidden inputs 872–888) and the capabilities it checks:
/// `5G`, `wps_multiband` and `lyra_hide`.
public struct WPSConfiguration: Sendable, Equatable {
    let values: [String: String]
    let flags: Set<String>
    /// The `wl_` values are those of the band the page opens on (see `interfacePrefix`): where `values` has that band's
    /// own value, it stands in for the `wl_` one. The router copies a band's value whenever the name exists, even when it
    /// is empty, but a read gives "" for an empty and for a missing name alike, so only non-empty values stand in.
    public init(values: [String: String], support: [String: String]) {
        var values = values
        if let prefix = Self.interfacePrefix(unit: values["wl_unit"], subunit: values["wl_subunit"]) {
            for name in Self.copied { if let value = values[prefix + name], !value.isEmpty { values["wl_" + name] = value } }
        }
        self.values = values
        flags = Set(["5G", "wps_multiband", "lyra_hide"].filter { !["", "0"].contains(support[$0] ?? "") })
    }
    /// The bands' auth modes are read for units 0–3: the page's WPA3 note asks for them by band (2g1_, 5g1_, 5g2_).
    /// `productid` picks the page's model branches (show_wsc_status 474–476, 539–544; show_wsc_status2 678–685).
    static let keys = ["wps_enable", "wps_band_x", "wps_multiband", "wps_dualband", "wl_closed", "wlnband_list", "wl0_radio", "wl1_radio",
                       "wl_auth_mode_x", "wl_wep_x", "wl0_wep_x", "wl1_wep_x", "wl_unit", "wl_subunit", "productid"] + (0...3).map { "wl\($0)_auth_mode_x" }
    /// The `wl_` values the page shows or checks: `wl_closed` (initial 167–170), `wl_auth_mode_x` and `wl_wep_x`
    /// (InitializeTimer 368–380).
    static let copied = ["closed", "auth_mode_x", "wep_x"]
    /// Opening the page first copies the values of the band in `wl_unit` over the `wl_` ones, `wl<unit>.<subunit>_` when
    /// `wl_subunit` is neither -1 nor 0 (<% wl_get_parameter(); %> 27; httpd/web.c ej_wl_get_parameter 2802–2816,
    /// copy_index_to_unindex 3259–3297), so the page shows that band's values even where the `wl_` copies are old. The
    /// app reads the band's values instead of having the router copy them. nil where `wl_unit` is -1, which copies nothing.
    static func interfacePrefix(unit: String?, subunit: String?) -> String? {
        // nvram_get_int reads both with atoi; shared/defaults.c sets them to "0" and "-1" (75–76).
        let unit = javaScriptInteger(unit ?? "", radix: 10) ?? 0, subunit = javaScriptInteger(subunit ?? "", radix: 10) ?? 0
        guard unit != -1 else { return nil }
        return subunit == -1 || subunit == 0 ? "wl\(unit)_" : "wl\(unit).\(subunit)_"
    }
    var multiband: Bool { flags.contains("wps_multiband") }
    /// InitializeTimer (368–380): the page keeps reading WPS_info.xml only while the auth modes allow WPS; otherwise it
    /// reads it once.
    public var pollsStatus: Bool {
        multiband ? !(wpsRejects(auth: values["wl0_auth_mode_x"] ?? "", wep: values["wl0_wep_x"] ?? "")
                      || wpsRejects(auth: values["wl1_auth_mode_x"] ?? "", wep: values["wl1_wep_x"] ?? ""))
                  : !wpsRejects(auth: values["wl_auth_mode_x"] ?? "", wep: values["wl_wep_x"] ?? "")
    }
}

/// WPS_info.xml, which the page reads about every four seconds while it is open (updateWPS 407–411, StartTheTimer
/// 389–405). It lists one band's items as `wps_info`, or each band's as `wps_info0` and `wps_info1` on routers with
/// `wps_multiband` (refresh_wpsinfo 418–451). Only the items the page shows are kept: the others include the network name
/// and key.
public struct WPSInfo: Sendable, Equatable {
    public struct Items: Sendable, Equatable {
        /// [0] 连线状态, e.g. "Idle" or "Start WPS Process".
        public var state: String?
        /// [1] "Yes" or "No".
        public var configured: String?
        /// [7] 访问点 PIN 码.
        public var pin: String?
        /// [11] the band's auth mode, which reject_wps() checks.
        public var authMode: String?
        /// [12] the band: 0 2.4 GHz, 1 5 GHz, 2 5 GHz-2.
        public var band: String?
        public init(state: String? = nil, configured: String? = nil, pin: String? = nil, authMode: String? = nil, band: String? = nil) {
            self.state = state; self.configured = configured; self.pin = pin; self.authMode = authMode; self.band = band
        }
    }
    public let tags: [String: Items]
    public init(tags: [String: Items]) { self.tags = tags }
    public init(xml: String) throws {
        // The page gives up without a <wps> element (refresh_wpsinfo 421–429).
        guard xml.range(of: #"<wps[\s>/]"#, options: .regularExpression) != nil else { throw RouterError.invalidResponse("WPS 状态") }
        var values: [String: [String?]] = [:]
        // An empty element has no text node, so the page reads undefined there, nil here.
        for match in RouterParser.captures(#"<(wps_info\d?)(?:\s*/>|\s*>([^<]*)</\1\s*>)"#, in: xml) {
            values[match[0], default: []].append(match[1].isEmpty ? nil : Self.decoded(match[1]))
        }
        tags = values.mapValues { items in
            func item(_ index: Int) -> String? { items.indices.contains(index) ? items[index] : nil }
            return Items(state: item(0), configured: item(1), pin: item(7), authMode: item(11), band: item(12))
        }
    }
    static func decoded(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'")] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// The WPS page as it looks once WPS_info.xml has been read: initial() (77–172), then show_wsc_status() (453–606) or, for
/// both bands at once, show_wsc_status2() (608–729).
public struct WPSStatus: Sendable, Equatable {
    public struct BandTitle: Sendable, Equatable {
        public let title: String
        /// Struck through: the page's way of saying WPS does not work on this band.
        public let struck: Bool
        public init(_ title: String, struck: Bool = false) { self.title = title; self.struck = struck }
    }
    /// A link in a notice. The page's links choose the band (saving `wl_unit`) and open 专业设置 or 一般设置; the app opens
    /// the same page at that band without saving anything.
    public struct BandLink: Sendable, Equatable {
        /// The band's name after the link text, or "" where the page shows only the link text.
        public let title: String
        public let unit: Int?
    }
    public enum Notice: Sendable, Equatable {
        /// "* 开启 WiFi 以设置 WPS。" with 前往设置 links to 专业设置 (_change_wl_advanced_unit_status 748–752).
        case wifiOff([BandLink])
        /// The WPS 2.0 note: the band's auth does not allow WPS (reject_wps), with 一般设置 links (_change_wl_unit_status 742–746).
        case authRejected([BandLink])
    }
    /// 启用 WPS (`wps_enable` "1").
    public var enabled = false
    /// 当前频率; nil where the router has no 5 GHz band and the page hides the row (initial 79–80).
    public var bands: [BandTitle]?
    public var notice: Notice?
    /// 连线状态; nil while the page hides the row.
    public var state: String?
    /// The page shows its progress image while a state is "Start WPS Process".
    public var inProgress = false
    /// 配置: 已启用 / 未启用 for one band, Yes / No for each of two; nil while the page leaves it empty.
    public var configured: String?
    /// 访问点 PIN 码; nil while the page hides the row.
    public var pin: String?
    /// "WPA3-Personal 不支持 WPS。" (initial 121–126, 141–149). It sits in the WPS 方法 row, which the page shows only while
    /// WPS is on and the band is usable (show_wsc_status 525–555, show_wsc_status2 643–697).
    public var wpa3Unsupported = false
    /// "注： 若 SSID 被隐藏则无法使用 WPS 功能。" while `wl_closed` is 1 (initial 167–170).
    public var hiddenSSID = false

    public init(configuration: WPSConfiguration, info: WPSInfo) {
        let values = configuration.values, flags = configuration.flags
        let bandList = WirelessBands(list: values["wlnband_list"] ?? "")
        let multibandSupport = configuration.multiband
        let wpsEnable = values["wps_enable"] ?? "", wpsBand = values["wps_band_x"] ?? ""
        // get_band_str (60–75).
        func title(_ band: String?) -> String {
            if javaScriptEquals(band, 0) { return "2.4 GHz" }
            if javaScriptEquals(band, 1) { return bandList.twoFiveGHz && !bandList.sixGHz ? "5 GHz-1" : "5 GHz" }
            return javaScriptEquals(band, 2) ? "5 GHz-2" : ""
        }
        // The page asks for `2g1_auth_mode_x` and the like; httpd reads them as `wl<position in wlnband_list>_`
        // (ej_nvram_get → wl_nband_to_wlx, libwebapi/webapi.c 621–647), the same unit get_wl_unit_by_band finds.
        func auth(_ band: String) -> String { bandList.unit(of: band).flatMap { values["wl\($0)_auth_mode_x"] } ?? "" }
        let wpa3 = ["sae", "wpa3", "suite-b"]
        var wpa3Note = false
        enabled = wpsEnable == "1"
        hiddenSSID = values["wl_closed"].map { !$0.trimmingCharacters(in: .whitespaces).isEmpty && javaScriptEquals($0, 1) } ?? false
        var titles: [BandTitle] = []
        if flags.contains("5G") {
            if !multibandSupport || values["wps_multiband"] == "0" {
                titles = [BandTitle(title(wpsBand))]
                // Only these titles have a band prefix (99–119): a lone "5 GHz" reads no auth mode and shows no note.
                if let prefix = ["2.4 GHz": "2g1", "5 GHz-1": "5g1", "5 GHz-2": "5g2"][title(wpsBand)], wpa3.contains(auth(prefix)) { wpa3Note = true }
            }
            if (multibandSupport && values["wps_multiband"] == "1") || values["wps_dualband"] == "1" {
                titles = [BandTitle(title("0"), struck: wpsRejects(auth: values["wl0_auth_mode_x"] ?? "", wep: values["wl0_wep_x"] ?? "")),
                          BandTitle(title("1"), struck: wpsRejects(auth: values["wl1_auth_mode_x"] ?? "", wep: values["wl1_wep_x"] ?? ""))]
                if wpa3.contains(auth("2g1")) || wpa3.contains(auth("5g1")) { wpa3Note = true }
            }
        }
        let wifiOn = [values["wl0_radio"] == "1", values["wl1_radio"] == "1"]
        let model = values["productid"] ?? ""
        // RT-AC55U and RT-AC55UHP add the switched-off band to 连线状态 (show_wsc_status 539–544, show_wsc_status2 678–685).
        let radioNote = ["RT-AC55U", "RT-AC55UHP"].contains(model)
        var methodRowShown = false
        if multibandSupport && values["wps_multiband"] != "0" {
            let items = [info.tags["wps_info0"] ?? .init(), info.tags["wps_info1"] ?? .init()]
            let rejected = [wpsRejects(auth: items[0].authMode ?? "", wep: values["wl0_wep_x"] ?? ""),
                            wpsRejects(auth: items[1].authMode ?? "", wep: values["wl1_wep_x"] ?? "")]
            let names = items.map { title($0.band) }
            if wpsEnable != "1" { titles = (0...1).map { BandTitle(names[$0], struck: rejected[$0]) } }
            var hidden = false
            if wifiOn.contains(false) {
                notice = .wifiOff((0...1).filter { !wifiOn[$0] }.map { BandLink(title: names[$0], unit: $0) })
                hidden = !wifiOn.contains(true)
            } else if rejected.contains(true) {
                notice = .authRejected((0...1).filter { rejected[$0] }.map { BandLink(title: names[$0], unit: $0) })
                hidden = !rejected.contains(false)
            }
            if !hidden {
                let notes = radioNote ? [values["wl0_radio"] == "0" ? " (2.4G is disabled)" : "", values["wl1_radio"] == "0" ? " (5G is disabled)" : ""] : ["", ""]
                state = wpsEnable == "0" ? "未启用 / 未启用" : "\(items[0].state ?? "")\(notes[0]) / \(items[1].state ?? "")\(notes[1])"
                pin = items[0].pin
                inProgress = items.contains { $0.state == "Start WPS Process" }
                configured = items.map { $0.configured == "No" ? "No" : "Yes" }.joined(separator: " / ")
                methodRowShown = true
            }
        } else {
            let items = info.tags[multibandSupport ? (wpsBand == "0" ? "wps_info0" : "wps_info1") : "wps_info"] ?? .init()
            var onFive = false
            // RT-AC87U and RT-AC87R keep the title initial() gave and check the 2.4 GHz switch (show_wsc_status 474–476).
            if ["RT-AC87U", "RT-AC87R"].contains(model) {}
            else if javaScriptEquals(items.band, 0) { titles = [BandTitle("2.4 GHz")] }
            else if javaScriptEquals(items.band, 1) { titles = [BandTitle(bandList.twoFiveGHz ? "5 GHz-1" : "5 GHz")]; onFive = true }
            else if javaScriptEquals(items.band, 2) { titles = [BandTitle("5 GHz-2")]; onFive = true }
            let link = [BandLink(title: "", unit: items.band.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) })]
            if !wifiOn[onFive ? 1 : 0] { notice = .wifiOff(link) }
            else if wpsRejects(auth: items.authMode ?? "", wep: values[wpsBand == "0" ? "wl0_wep_x" : "wl1_wep_x"] ?? "") { notice = .authRejected(link) }
            if notice != nil {
                if multibandSupport { titles = titles.map { BandTitle($0.title, struck: true) } }
            } else {
                let note = !radioNote ? "" : wpsBand == "0" && values["wl0_radio"] == "0" ? " (2.4G is disabled)"
                    : wpsBand == "1" && values["wl1_radio"] == "0" ? " (5G is disabled)" : ""
                state = wpsEnable == "0" ? "未启用" : (items.state ?? "") + note
                pin = items.pin
                inProgress = items.state == "Start WPS Process"
                configured = items.configured == "No" ? "未启用" : "已启用"
                methodRowShown = true
            }
        }
        // refresh_wpsinfo 449–450.
        if flags.contains("lyra_hide") { pin = nil }
        bands = flags.contains("5G") ? titles : nil
        wpa3Unsupported = wpa3Note && methodRowShown && wpsEnable != "0"
    }
}

extension RouterClient {
    public func wpsConfiguration() async throws -> WPSConfiguration {
        var values = try await readSettings(WPSConfiguration.keys)
        if let prefix = WPSConfiguration.interfacePrefix(unit: values["wl_unit"], subunit: values["wl_subunit"]) {
            values.merge(try await readSettings(WPSConfiguration.copied.map { prefix + $0 })) { _, new in new }
        }
        return WPSConfiguration(values: values, support: try await uiCapabilities())
    }
    public func wpsInfo() async throws -> WPSInfo { try WPSInfo(xml: try await readDataPage(.wpsStatus)) }
}

// MARK: - WDS

/// 无线 › WDS (Advanced_WMode_Content.asp, 无线桥接). The page lists the radios' MAC addresses, then the settings of the band
/// in `wl_unit`; choosing another band there saves `wl_unit` (change_wl_unit), so the app shows every band instead and
/// saves nothing. It also never starts the AP scan that initial() schedules (135, wds_scan 251–269).
public struct WDSSettings: Sendable, Equatable {
    public struct MACRow: Sendable, Equatable, Identifiable {
        /// "2.4 GHz MAC", "5 GHz MAC", "5 GHz-1 MAC", "5 GHz-2 MAC" or "6 GHz MAC" (initial 110–123).
        public let title: String
        /// `wl0_hwaddr` to `wl2_hwaddr`: the address to enter on the other access point.
        public let mac: String
        public var id: String { title }
    }
    public struct Radio: Sendable, Equatable, Identifiable {
        public let band: WirelessBands.Band
        /// `wlN_mode_x` (AP 模式): "0" AP Only, "1" WDS Only, "2" Hybrid; "2" where the page offers only Hybrid.
        public let mode: String
        /// RT-AC87U hides AP 模式 on its second band (initial 77–80).
        public let showsMode: Bool
        /// `wlN_wdsapply_x` (连接列表中的访问点).
        public let connectListed: String
        /// `wlN_wdslist` (远程基地台列表, at most 4).
        public let remoteAPs: [String]
        /// wl_bwch_hint() (362–371): the 自动频道带宽 and 自动频道 notes.
        public let autoBandwidth: Bool
        public let autoChannel: Bool
        /// In repeater or media bridge mode the band that connects upstream shows "目前的运作模式不支持此页面。" instead of
        /// its settings (initial 83–91).
        public let unavailable: Bool
        /// Ralink routers fix 连接列表中的访问点 to 是 in WDS Only (change_wireless_bridge, general.js 249–251).
        let rawifi: Bool
        public var id: Int { band.unit }

        public var modeTitle: String { ["0": "AP Only", "1": "WDS Only", "2": "Hybrid"][mode] ?? "未识别的值 \(mode.isEmpty ? "（空）" : mode)" }
        /// AP Only checks 否 and greys the choice out (change_wireless_bridge, general.js 245–255).
        public var connectListedTitle: String {
            if mode == "0" { return "否" }
            if mode == "1" && rawifi { return "是" }
            return ["1": "是", "0": "否"][connectListed] ?? "未选择"
        }
        public var connectListedFixed: Bool { mode == "0" || (mode == "1" && rawifi) }
    }
    public let macs: [MACRow]
    /// 频段 is hidden on routers without 5 GHz (initial 110–113); the app then shows the one band without its name.
    public let showsBand: Bool
    /// In the order of the page's 频段 choices (regen_band, state.js 4385–4398).
    public let radios: [Radio]
    /// `wl_unit`: the band the web page opens on.
    public let currentUnit: Int?

    public init(values: [String: String], support: [String: String]) {
        func on(_ name: String) -> Bool { !["", "0"].contains(support[name] ?? "") }
        let bands = WirelessBands(list: values["wlnband_list"] ?? "")
        let fiveGHz = on("5G"), wl6 = on("wl6")
        var macs = [MACRow(title: "2.4 GHz MAC", mac: values["wl0_hwaddr"] ?? "")]
        if fiveGHz { macs.append(MACRow(title: Self.thirdMACRow(bands) ? "5 GHz-1 MAC" : "5 GHz MAC", mac: values["wl1_hwaddr"] ?? "")) }
        if Self.thirdMACRow(bands) { macs.append(MACRow(title: bands.sixGHz ? "6 GHz MAC" : "5 GHz-2 MAC", mac: values["wl2_hwaddr"] ?? "")) }
        self.macs = macs
        showsBand = fiveGHz
        let mode = Self.switchMode(values["sw_mode"] ?? "", psta: values["wlc_psta"] ?? "")
        let repeater = javaScriptEquals(mode, 2) || javaScriptEquals(mode, 4)
        let model = values["productid"] ?? ""
        radios = bands.listed.enumerated().map { index, band in
            func value(_ name: String) -> String { values["wl\(band.unit)_\(name)"] ?? "" }
            // initial() 72–80: Lantiq routers offer only Hybrid; RT-AC87U uses Hybrid on the second band of 频段 and hides
            // AP 模式 there.
            let secondOnAC87U = model == "RT-AC87U" && index == 1
            // show_wl_wdslist (138–155) lists the entries after the first "<".
            return Radio(band: band, mode: on("lantiq") || secondOnAC87U ? "2" : value("mode_x"), showsMode: !secondOnAC87U,
                         connectListed: value("wdsapply_x"), remoteAPs: Array(value("wdslist").components(separatedBy: "<").dropFirst()),
                         autoBandwidth: value("bw") == (wl6 ? "0" : "1"), autoChannel: wl6 ? value("chanspec") == "0" : value("channel") == "0",
                         unavailable: repeater && "\(band.unit)" == values["wlc_band"], rawifi: on("rawifi"))
        }
        currentUnit = values["wl_unit"].flatMap { Int($0) }
    }
    /// The operation mode as state.js counts it (254–265): 媒体桥接 (4) where `wlc_psta` is 1 in repeater or AP mode or 3 in
    /// AP mode, 中继 (2) where it is 2 in AP mode; otherwise `sw_mode` itself.
    static func switchMode(_ swMode: String, psta: String) -> String {
        if ((javaScriptEquals(swMode, 2) || javaScriptEquals(swMode, 3)) && javaScriptEquals(psta, 1)) || (javaScriptEquals(swMode, 3) && javaScriptEquals(psta, 3)) { return "4" }
        return javaScriptEquals(swMode, 3) && javaScriptEquals(psta, 2) ? "2" : swMode
    }
    /// The third MAC row, for a second 5 GHz band or a 6 GHz band (initial 115–123).
    static func thirdMACRow(_ bands: WirelessBands) -> Bool { bands.twoFiveGHz || bands.sixGHz }
    static func keys(bands: WirelessBands, support: [String: String]) -> [String] {
        let wl6 = !["", "0"].contains(support["wl6"] ?? "")
        var keys = ["sw_mode", "wlc_psta", "wlc_band", "wl_unit", "productid", "wl0_hwaddr", "wl1_hwaddr"]
        if thirdMACRow(bands) { keys.append("wl2_hwaddr") }
        for band in bands.listed {
            keys += ["mode_x", "wdsapply_x", "wdslist", "bw", wl6 ? "chanspec" : "channel"].map { "wl\(band.unit)_\($0)" }
        }
        return keys
    }
}

extension RouterClient {
    public func wdsSettings() async throws -> WDSSettings {
        let support = try await uiCapabilities()
        var values = try await readSettings(["wlnband_list"])
        values.merge(try await readSettings(WDSSettings.keys(bands: WirelessBands(list: values["wlnband_list"] ?? ""), support: support))) { _, new in new }
        return WDSSettings(values: values, support: support)
    }
}

// MARK: - 漫游阻止列表

/// 无线 › 漫游阻止列表 (Advanced_Roaming_Block_Content.asp): devices kept from roaming between AiMesh nodes. The page reads
/// `wl0_rast_static_client` (initial 42–53) and saves the list to every band (applyRule 169–249).
public struct RoamingBlockList: Sendable, Equatable {
    /// `rast_static_cli_enable` (启用漫游阻止列表, 352–353).
    public let enable: String
    /// Upper case, in the router's order (show_wl_maclist_x 55–127); the page keeps each entry once (initial 46–48).
    public let macs: [String]
    public var enabled: Bool { enable == "1" }
    /// The page shows the list only while 是 is chosen (enable_roaming_block 296–306).
    public var enableTitle: String { ["1": "是", "0": "否"][enable] ?? "未选择" }
    public init(values: [String: String]) {
        enable = values["rast_static_cli_enable"] ?? ""
        var seen = Set<String>()
        macs = (values["wl0_rast_static_client"] ?? "").components(separatedBy: "<").dropFirst().filter { seen.insert($0).inserted }.map { $0.uppercased() }
    }
    static let keys = ["rast_static_cli_enable", "wl0_rast_static_client"]
}

extension RouterClient {
    public func roamingBlockList() async throws -> RoamingBlockList { RoamingBlockList(values: try await readSettings(RoamingBlockList.keys)) }
}

// MARK: - Smart Connect 规则

/// 网络工具 › Smart Connect 规则 (Advanced_Smart_Connect.asp): the rules Smart Connect uses to move devices between bands,
/// one column per band in the order 2.4, 5, 5-2, 6, 6-2 GHz (bandList 58–63), as the page fills its fields when it opens
/// (65–111, initial 130–150).
public struct SmartConnectRules: Sendable, Equatable {
    /// The page's 功能 choices.
    public enum Capability: String, Sendable {
        case all = "0", acAx = "1", abgn = "2", ax = "3", abgnac = "4"
        public var title: String {
            switch self {
            case .all: "全部"; case .acAx: "802.11ac/ax only"; case .abgn: "802.11a/b/g/n"; case .ax: "802.11ax only"; case .abgnac: "802.11a/b/g/n/ac"
            }
        }
        /// The first of these flag bits that is set picks the choice; none leaves 全部.
        static func from(_ flags: Int?, _ order: [(Int, Capability)]) -> Capability {
            order.first { SmartConnectRules.bit(flags, $0.0) }?.1 ?? .all
        }
    }
    public struct Column: Sendable, Equatable, Identifiable {
        public let band: WirelessBands.Band
        /// isSmartConnectSelifBand() (152–179): needs `smart_connect_v2` and the band's bit in `smart_connect_selif_x`;
        /// otherwise every row of the column shows "- -".
        public let active: Bool
        /// `wlN_bsd_steering_policy`: [0] 带宽使用量 %, [3] RSSI dBm, [4] and [5] PHY Mbps, [6] flags in hex.
        public let steering: [String]
        /// `bsd_sta_select_policy` of the band's (main network's) sub-interface: [1] RSSI dBm, [2] and [3] PHY Mbps, [10] flags.
        public let station: [String]
        /// `wlN_bsd_if_qualify_policy`: [0] 带宽使用量 %, [1] flags.
        public let qualify: [String]
        /// 目标频段 in order (genIfSelectBand 531–575): a band's title, "none", or "" for an empty choice.
        public let targets: [String]
        /// 启用负载平衡: steering flag bit 6 (genSteerLoadBalance 191–219).
        public let loadBalance: Bool
        /// RSSI 大于 when flag bit 1 is set, 小于 when not; nil where the flags have fewer than two binary digits and the page
        /// leaves the choice blank (genStreerRSSI 240–268, genStaRSSI 350–377).
        public let steeringRSSIGreater: Bool?
        public let stationRSSIGreater: Bool?
        /// genSteerCapability (308–348): flag bits 11, 10, 3, 2.
        public let steeringCapability: Capability
        /// genStaCapability (417–457): flag bits 15, 14, 3, 2 of the column whose number is this band's wl unit (443).
        public let stationCapability: Capability
        /// genIfQualityaCapability (478–518): flag bits 11, 10, 2, 1.
        public let qualifyCapability: Capability
        public var id: Int { band.unit }

        /// A field as the page puts it in its text box or label; "undefined" where the policy is too short.
        public static func field(_ fields: [String], _ index: Int) -> String { fields.indices.contains(index) ? fields[index] : "undefined" }
    }
    public let columns: [Column]
    /// `bsd_bounce_detect` (弹回检测, genBounceDetect 577–606): [0] 窗口时间 s, [1] 计数, [2] 停留时间 s.
    public let bounceDetect: [String]

    /// `subunit` is the main network's sub-interface number on `sdn_mainfh` routers and nil elsewhere.
    public init(values: [String: String], smartConnectV2: Bool, subunit: String?) {
        let bands = WirelessBands(list: values["wlnband_list"] ?? "")
        let suffix = subunit.map { ".\($0)" } ?? ""
        let names = ["2G", "5G1", "5G2", "6G1", "6G2"]
        let present = names.filter { bands.unit(of: $0) != nil }
        let units = present.compactMap { bands.unit(of: $0) }
        let selif = javaScriptInteger(values["smart_connect_selif_x"] ?? "")
        func split(_ key: String) -> [String] { (values[key] ?? "").components(separatedBy: " ") }
        func hex(_ fields: [String], _ index: Int) -> Int? { fields.indices.contains(index) ? javaScriptInteger(fields[index], radix: 16) : nil }
        let active = present.map { name in smartConnectV2 && Self.bit(selif, names.firstIndex(of: name) ?? 0) }
        // The 目标频段 choices are the active bands' sub-interfaces (if_name_array 520–529).
        let interfaces: [(name: String, title: String)?] = present.indices.map { index in
            active[index] ? ("wl\(units[index])\(suffix)", bands.band(unit: units[index])?.title ?? "") : nil
        }
        let stationFlags = units.map { hex(split("wl\($0)\(suffix)_bsd_sta_select_policy"), 10) }
        columns = present.indices.compactMap { index in
            let unit = units[index]
            guard let band = bands.band(unit: unit) else { return nil }
            let steering = split("wl\(unit)_bsd_steering_policy"), station = split("wl\(unit)\(suffix)_bsd_sta_select_policy")
            let qualify = split("wl\(unit)_bsd_if_qualify_policy"), selected = split("wl\(unit)\(suffix)_bsd_if_select_policy")
            let others = interfaces.indices.filter { $0 != index }.compactMap { interfaces[$0] }
            // One choice per other band; the first has no "none" and shows its first entry when nothing matches.
            let targets: [String] = interfaces.indices.dropFirst().map { position in
                let stored = selected.indices.contains(position - 1) ? selected[position - 1] : nil
                if let match = others.first(where: { $0.name == stored }) { return match.title }
                return position == 1 ? others.first?.title ?? "" : "none"
            }
            let steeringFlags = hex(steering, 6), qualifyFlags = hex(qualify, 1)
            return Column(band: band, active: active[index], steering: steering, station: station, qualify: qualify, targets: targets,
                          loadBalance: Self.bit(steeringFlags, 6), steeringRSSIGreater: Self.comparator(steeringFlags),
                          stationRSSIGreater: Self.comparator(stationFlags[index]),
                          steeringCapability: .from(steeringFlags, [(11, .ax), (10, .abgnac), (3, .acAx), (2, .abgn)]),
                          stationCapability: .from(stationFlags.indices.contains(unit) ? stationFlags[unit] : nil, [(15, .ax), (14, .abgnac), (3, .acAx), (2, .abgn)]),
                          qualifyCapability: .from(qualifyFlags, [(11, .ax), (10, .abgnac), (2, .acAx), (1, .abgn)]))
        }
        bounceDetect = split("bsd_bounce_detect")
    }
    static func bit(_ value: Int?, _ index: Int) -> Bool { value.map { $0 >= 0 && ($0 >> index) & 1 == 1 } ?? false }
    static func comparator(_ flags: Int?) -> Bool? {
        guard let flags, flags >= 2 else { return nil }
        return bit(flags, 1)
    }
}

extension RouterClient {
    public func smartConnectRules() async throws -> SmartConnectRules {
        let support = try await uiCapabilities()
        func on(_ name: String) -> Bool { !["", "0"].contains(support[name] ?? "") }
        var values = try await readSettings(["wlnband_list", "sdn_rl", "ap_wifi_rl", "bsd_bounce_detect", "smart_connect_selif_x"])
        let subunit = on("sdn_mainfh") ? SmartConnectSubunit.mainFronthaul(sdnRL: values["sdn_rl"] ?? "", apWifiRL: values["ap_wifi_rl"] ?? "") : nil
        let suffix = subunit.map { ".\($0)" } ?? ""
        let units = WirelessBands(list: values["wlnband_list"] ?? "").listed.map(\.unit)
        let keys = units.flatMap { ["wl\($0)_bsd_steering_policy", "wl\($0)_bsd_if_qualify_policy", "wl\($0)\(suffix)_bsd_sta_select_policy", "wl\($0)\(suffix)_bsd_if_select_policy"] }
        if !keys.isEmpty { values.merge(try await readSettings(keys)) { _, new in new } }
        return SmartConnectRules(values: values, smartConnectV2: on("smart_connect_v2"), subunit: subunit)
    }
}

/// The station and target rules Smart Connect keeps per sub-interface; on a router whose main Wi-Fi is an SDN network
/// (`sdn_mainfh`) the page reads those of the main network's (Advanced_Smart_Connect.asp getMainFhSubunit, 48–56).
public enum SmartConnectSubunit {
    /// The main network's index from `sdn_rl`, then its sub-interface number from `ap_wifi_rl`; "1" when that is not a number.
    public static func mainFronthaul(sdnRL: String, apWifiRL: String) -> String {
        let main = sdnRL.components(separatedBy: ">MAINFH")[0].components(separatedBy: "<").last ?? ""
        let subunit = apWifiRL.components(separatedBy: ">" + main)[0].components(separatedBy: ".").last ?? ""
        return Double(subunit).map(\.isFinite) == true ? subunit : "1"
    }
}

// MARK: - MLO

/// 无线 › MLO (sysdep/FUNCTION/SDN/MLO.asp, which shows SDN/mlo.html): the MLO switch, 回程频段 where the router offers it,
/// and the MLO networks (show_mlo_profilelist, mlo.js 1–96). Turning MLO on or off reboots the router or restarts its
/// wireless and changes other settings (mlo.html 104–264); the app only shows the switch.
public struct MLOOverview: Sendable, Equatable {
    /// A network as the page's list shows it (Get_Component_Profile_Item, sdn.js 529–763).
    public struct Network: Sendable, Equatable, Identifiable {
        public let id: String
        public let ssid: String
        /// `_mlo` "1": the MLO backhaul network; "2": MLO 前传 for clients.
        public let backhaul: Bool
        /// The network's switch in `sdn_rl`.
        public let enabled: Bool
        /// `_disabled` "1": the page greys the network out and leaves out its switch (553–555, 752–754), and its settings
        /// say the network has to be made again: "Due to system optimization, this network has to be reconfigured."
        /// (7439, 7455–7459).
        public let needsReconfiguring: Bool
        /// 客户端数量 (759–761).
        public let onlineDevices: Int
        /// VLAN ID: the `vlan_rl` entry of the network's VLAN index (init_sdn_all_list 10937–10942; shown 756–758).
        public let vlanID: String?
        /// 有线连接 where the first `dut_list` entry names no band; the page then shows no Wi-Fi icons (get_conn_type 846–871).
        public let wired: Bool
        /// 无线连接（离线）: the network's schedule has its Wi-Fi off now (`apg_wifi_sched_on` "0", 10890, 11075–11080).
        public let scheduledOff: Bool
        /// The WiFi7 icon: ui_support `wifi7` and get_apg_wifi7_onoff "1" (10897), which is the network's `_11be` read as a
        /// number (httpd/web.c 42246–42282).
        public let wifi7: Bool
        /// The MLO icon's lock: the first `_security` entry's auth is not open, owe or openowe (828–834).
        public let secured: Bool
        /// The VPN 客户端 and 虚拟专用网 (VPN) 服务器 tags: `sdn_rl` columns 6 and 7 other than "0"; a row too short to have
        /// them shows the tag too, as `undefined != "0"` does (558–563).
        public let vpnClient: Bool
        public let vpnServer: Bool
        /// The 剩余时间 tag of a network that is on and has an access time (`_timesched` "2", 564–582); nil without it.
        public let accessTime: AccessTime?
        /// The Free WiFi and 留言板 tags: the network's portal (`sdn_rl` column 11, 11087) is type 2 or 4 and the router
        /// offers that type (get_cp_type_support 11847–11849; 584–589).
        public let freeWiFi: Bool
        public let messageBoard: Bool
    }
    /// The 剩余时间 tag: the end of the access time against the router's clock when the page was read. The page counts
    /// it down once a second and reads its list again when it reaches 0 (mlo.js 79–96).
    public struct AccessTime: Sendable, Equatable {
        /// The end, seconds since 1970: `parseInt` of the ten characters after "T0" in the second `_expiretime` entry,
        /// which is "T1<start>Z,T0<end>Z" (js/weekSchedule/schedule_ui.js 47–60, 323–340); nil where that is NaN.
        public let end: Int?
        /// utctimestamp when the page was read (httpd/web.c 2441–2454); 0 where it is not a number, as on the page (565–566).
        public let routerTime: Int
        /// Seconds left `elapsed` seconds after the read, never below 0 (570; mlo.js 84–86).
        public func remaining(after elapsed: Int) -> Int {
            end.map { max($0 - routerTime - elapsed, 0) } ?? 0
        }
        /// Only a tag with time left when the page drew it counts down (`access_time`, 577; mlo.js 80).
        public var counts: Bool { remaining(after: 0) > 0 }
        /// HH:MM:SS as secondsToHMS writes it (sdn.js 13518–13536): each part padded to two digits and cut to its last two,
        /// so from 100 hours on the hours lose their first digit. The page's own hour field takes two digits
        /// (schedule_ui.js 1003), so it cannot set that much.
        public func text(after elapsed: Int) -> String {
            let left = remaining(after: elapsed)
            return [left / 3600, left % 3600 / 60, left % 60].map { String(("00" + String($0)).suffix(2)) }.joined(separator: ":")
        }
    }
    /// `mld_enable` (mlo.html 268–271).
    public let enabled: Bool
    /// 回程频段, shown only with ui_support `mlo_bh_band` (278–380); nil otherwise.
    public let backhaulBands: String?
    /// 无线网络设置 › 前往设置, hidden on `sdn_mwl` routers (93–95).
    public let showsWirelessSettings: Bool
    /// Backhaul networks first, the last one listed first, as the page lists them (mlo.js 13–22).
    public let networks: [Network]
    /// Seconds from the read until the first tag that counts down reaches 0, when the page reads its list again
    /// (mlo.js 89–92); nil without such a tag.
    public var readsAgainAfter: Int? { networks.compactMap(\.accessTime).filter(\.counts).map { $0.remaining(after: 0) }.min() }

    /// `meshBands` is `meshBandTotal` of the AiMesh main router; `scheduleOn` is `apg_wifi_sched_on`, e.g. "apg2": "0";
    /// `routerTime` is utctimestamp, and `operationMode` is get_operation_mode, e.g. "rt".
    public init(values: [String: String], support: [String: String], online: [String: Int], meshBands: Int = 0, scheduleOn: [String: String] = [:],
                routerTime: Int = 0, operationMode: String = "") {
        func on(_ name: String) -> Bool { !["", "0"].contains(support[name] ?? "") }
        enabled = values["mld_enable"] == "1"
        showsWirelessSettings = !on("sdn_mwl")
        if on("mlo_bh_band") {
            let options = on("mlo") ? Self.backhaulOptions(bandTotal: meshBands) : []
            let value = values["mlo_bh_band"] ?? ""
            // An empty value shows the first choice; a value with no choice leaves the menu blank (368–375).
            backhaulBands = value.isEmpty ? options.first?.title ?? "" : options.first { $0.value == value }?.title ?? "未识别的值 \(value)"
        } else {
            backhaulBands = nil
        }
        // parse_StrToJSON_vlan_rl_list (sdn.js 11103–11118): index and VLAN ID per entry.
        let vlans = (values["vlan_rl"] ?? "").components(separatedBy: "<").filter { !$0.isEmpty }.map { $0.components(separatedBy: ">") }
        let portals = Self.portalTypes(values["cp_type_rl"] ?? "", support: support, operationMode: operationMode)
        var backhaul: [Network] = [], fronthaul: [Network] = []
        for row in Self.rows(values["sdn_rl"] ?? "") {
            let prefix = SDNSnapshot.prefix(row), mlo = values[prefix + "mlo"] ?? ""
            guard ["1", "2"].contains(mlo) else { continue }
            let vlan = vlans.first { $0[0] == row[3] }
            // The first dut_list entry: its second field is the band mask, 0 where it is not a number (get_conn_type 846–855).
            let firstDevice = (values[prefix + "dut_list"] ?? "").components(separatedBy: "<").first { !$0.isEmpty }?.components(separatedBy: ">")
            let band = firstDevice.flatMap { $0.count > 1 ? javaScriptInteger($0[1]) : nil } ?? 0
            // The first `_security` entry's auth (`<band>auth>…`); without an entry the icon stays locked.
            let securityEntries = (values[prefix + "security"] ?? "").components(separatedBy: "<")
            let firstSecurity = securityEntries.count > 1 && !securityEntries[1].isEmpty ? securityEntries[1].components(separatedBy: ">") : nil
            // A network without a schedule entry counts as on (wifi_sched_on, 11075–11080).
            let schedule = scheduleOn["apg" + row[5]] ?? ""
            let timed = row[2] == "1" && values[prefix + "timesched"] == "2"
            let portal = row.count > 11 ? row[11] : nil
            let network = Network(id: row[0], ssid: values[prefix + "ssid"] ?? "", backhaul: mlo == "1", enabled: row[2] == "1",
                                  needsReconfiguring: values[prefix + "disabled"] == "1", onlineDevices: online[row[0]] ?? 0,
                                  vlanID: vlan.map { $0.count > 1 ? $0[1] : "" }, wired: firstDevice != nil && band == 0,
                                  scheduledOff: schedule == "0",
                                  wifi7: on("wifi7") && javaScriptInteger(values[prefix + "11be"] ?? "", radix: 10) == 1,
                                  secured: !["open", "owe", "openowe"].contains(firstSecurity.flatMap { $0.count > 1 ? $0[1] : nil } ?? ""),
                                  vpnClient: (row.count > 6 ? row[6] : nil) != "0", vpnServer: (row.count > 7 ? row[7] : nil) != "0",
                                  accessTime: timed ? Self.accessTime(values[prefix + "expiretime"] ?? "", routerTime: routerTime) : nil,
                                  freeWiFi: portal == "2" && portals.contains("2"), messageBoard: portal == "4" && portals.contains("4"))
            if network.backhaul { backhaul.insert(network, at: 0) } else { fronthaul.append(network) }
        }
        networks = backhaul + fronthaul
    }
    /// The `sdn_rl` rows the list can show: type MLO, idx other than 0, and an apg index above 0, without which the page
    /// reads no settings for the row (get_apg_rl_list 11232–11262; mlo.js 4–11). Each row is read on its own, as
    /// init_sdn_all_list does (10913–10920, set_sdn_profile 11067–11099), so a short or broken row leaves out only itself.
    static func rows(_ sdnRL: String) -> [[String]] {
        sdnRL.components(separatedBy: "<").filter { !$0.isEmpty }.map { $0.components(separatedBy: ">") }
            .filter { $0.count > 5 && $0[0] != "0" && $0[1] == "MLO" && (javaScriptInteger($0[5]) ?? 0) > 0 }
    }
    /// The 剩余时间 tag needs a second `_expiretime` entry 13 characters long, counted in UTF-16 units as the page counts
    /// them (567–569); otherwise the page shows no tag.
    static func accessTime(_ expireTime: String, routerTime: Int) -> AccessTime? {
        let entries = expireTime.components(separatedBy: ",")
        guard entries.count > 1 else { return nil }
        let units = Array(entries[1].utf16)
        guard units.count == 13 else { return nil }
        return AccessTime(end: javaScriptInteger(String(decoding: units[2..<12], as: UTF16.self)), routerTime: routerTime)
    }
    /// Of the two portal types the page shows as tags, Free WiFi (2) and 留言板 (4), the ones the router's model offers
    /// (cp_text_map, sdn.js 339–348): both need ui_support captivePortal and cp_freewifi without SMART_HOME_MASTER_UI,
    /// and 留言板 also no BUSINESS (isSupport, state.js 481–486).
    static func offeredPortalTypes(_ support: [String: String]) -> Set<String> {
        func on(_ name: String) -> Bool { !["", "0"].contains(support[name] ?? "") }
        guard !on("SMART_HOME_MASTER_UI"), on("captivePortal"), on("cp_freewifi") else { return [] }
        return on("BUSINESS") ? ["2"] : ["2", "4"]
    }
    /// The portal types the page knows, of the offered ones: each `cp_type_rl` entry is "<cp_idx>type" (cp_type_rl_json,
    /// sdn.js 326–372). The page builds the list only in router and WISP mode (isSwMode, state.js 268–272:
    /// get_operation_mode "rt" or "wisp", httpd/web.c 42325–42389).
    static func portalTypes(_ cpTypeRL: String, support: [String: String], operationMode: String) -> Set<String> {
        let offered = ["rt", "wisp"].contains(operationMode) ? offeredPortalTypes(support) : []
        return Set(cpTypeRL.components(separatedBy: "<").compactMap { entry in
            let fields = entry.components(separatedBy: ">")
            return fields.count > 1 && offered.contains(fields[1]) ? fields[1] : nil
        })
    }
    /// mlo_bh_band_mapping (mlo.html 342–357), chosen by the bands the AiMesh main router reports, added up.
    static func backhaulOptions(bandTotal: Int) -> [(value: String, title: String)] {
        switch bandTotal {
        case 1 + 4 + 8 + 16: [("28", "5GHz-1, 5GHz-2 and 6GHz (默认)"), ("25", "2GHz, 5GHz and 6GHz")]
        case 1 + 2 + 32 + 64: [("98", "5GHz, 6GHz-1 and 6GHz-2 (默认)"), ("35", "2GHz, 5GHz and 6GHz")]
        default: []
        }
    }
    /// The bands of the AiMesh main router (the first get_cfg_clientlist entry) added up, as init_aimesh_wifi_mlo_info
    /// adds them (sdn.js 12577–12620) with httpApi.aimesh_get_node_wifi_band (js/httpApi.js 2142–2189): the `band` of
    /// each capability 26 `wifi_band` entry (1 2.4 GHz, 2 5 GHz, 4/8 5 GHz-1/-2, 16 6 GHz, 32/64 6 GHz-1/-2); without
    /// such entries, the first guest network of each band (aimesh_get_node_capability 1923–2094: capability 6 2.4 GHz,
    /// 7 5 GHz, 8 5 GHz-2, 24 6 GHz, 34 6 GHz-2, bit 0). 0 without that entry, so the page offers no 回程频段.
    static func meshBandTotal(_ node: Any?) -> Int {
        guard let node = node as? [String: Any], let capability = node["capability"] as? [String: Any] else { return 0 }
        let wifiBand = (capability["26"] as? [String: Any])?["wifi_band"]
        let entries: [Any] = (wifiBand as? [Any]) ?? ((wifiBand as? [String: Any]).map { Array($0.values) } ?? [])
        if !entries.isEmpty {
            return entries.reduce(0) { sum, entry in sum + ((entry as? [String: Any]).flatMap { RouterParser.string($0["band"]) }.flatMap { javaScriptInteger($0) } ?? 0) }
        }
        func first(_ key: String) -> Bool { javaScriptInt32(capability[key]) & 1 == 1 }
        var total = first("6") ? 1 : 0
        if first("7") { total += first("8") ? 4 + 8 : 2 }
        if first("24") { total += first("34") ? 32 + 64 : 16 }
        return total
    }
}

/// A JSON value as JavaScript's `&` reads it (ToInt32): numbers and numeric text truncated to 32 bits, anything else 0.
func javaScriptInt32(_ value: Any?) -> Int {
    let number: Double?
    switch value {
    case let value as NSNumber: number = value.doubleValue
    case let value as String:
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        number = trimmed.isEmpty ? 0 : Double(trimmed)
    default: number = nil
    }
    guard let number, number.isFinite, abs(number) < 9.0e18 else { return 0 }
    return Int(Int32(truncatingIfNeeded: Int64(number.rounded(.towardZero))))
}

extension RouterClient {
    public func mloOverview() async throws -> MLOOverview {
        let support = try await uiCapabilities()
        func on(_ name: String) -> Bool { !["", "0"].contains(support[name] ?? "") }
        var values = try await readSettings(["sdn_rl", "vlan_rl", "mld_enable", "mlo_bh_band"])
        let rows = MLOOverview.rows(values["sdn_rl"] ?? "")
        let keys = rows.flatMap { row in ["ssid", "mlo", "disabled", "11be", "security", "dut_list", "timesched", "expiretime"].map { SDNSnapshot.prefix(row) + $0 } }
        if !keys.isEmpty { values.merge(try await readSettings(keys)) { _, new in new } }
        // The rows the list shows, MLO backhaul ("1") or fronthaul ("2"); what follows is read only for them.
        let shown = rows.filter { ["1", "2"].contains(values[SDNSnapshot.prefix($0) + "mlo"] ?? "") }
        // Like the page, which gets "" when a hook fails: no 回程频段 choices, and Wi-Fi counted as on.
        let meshBands = on("mlo_bh_band") && on("mlo") ? MLOOverview.meshBandTotal((try await optionalAnyHook("get_cfg_clientlist") as? [Any])?.first) : 0
        var schedule: [String: String] = [:]
        if !shown.isEmpty, let object = try await optionalAnyHook("apg_wifi_sched_on") as? [String: Any] {
            schedule = object.compactMapValues { RouterParser.string($0) }
        }
        // The operation mode, only for a network whose portal is a type the model offers, and the portal types, only in
        // the modes where the page knows them (MLOOverview.portalTypes). The page has the mode in state.js from the
        // start, so a failed read here fails the page.
        let offered = MLOOverview.offeredPortalTypes(support)
        let operationMode = shown.contains { $0.count > 11 && offered.contains($0[11]) } ? RouterParser.string(try await hook("get_operation_mode")) ?? "" : ""
        if ["rt", "wisp"].contains(operationMode) { values.merge(try await readSettings(["cp_type_rl"])) { _, new in new } }
        let online = shown.isEmpty ? [:] : try await sdnOnlineCounts()
        // The router's clock, read only for a network that is on and has an access time, and last, so that the countdown
        // starts close to it; the page counts a failed read as 0 (sdn.js 564–566).
        var routerTime = 0
        if shown.contains(where: { $0[2] == "1" && values[SDNSnapshot.prefix($0) + "timesched"] == "2" }) {
            routerTime = (try await optionalAnyHook("utctimestamp")).flatMap { RouterParser.string($0) }.flatMap { javaScriptInteger($0) } ?? 0
        }
        return MLOOverview(values: values, support: support, online: online, meshBands: meshBands, scheduleOn: schedule,
                           routerTime: routerTime, operationMode: operationMode)
    }
    /// One appGet.cgi hook without arguments, as httpApi.hookGet asks for it (js/httpApi.js 412–437); only reads.
    func hook(_ name: String) async throws -> Any? {
        try RouterParser.json(try await request("appGet.cgi", query: [.init(name: "hook", value: "\(name)()")]))[name]
    }
}
