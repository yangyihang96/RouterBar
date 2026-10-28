import Foundation

// 网络设置向导的 httpApi 读取（缓存与强制读取照 js/httpApi.js）、plugins.js 的 isSupport 与各项判断，以及向导用到的
// validator 检查。读取只发 GET；会启动服务的 start_force_autodet() 由页面记作待确认的副作用，不在这里发送。

// MARK: - httpApi reads

extension QISWizard {
    /// httpApi.nvramGet (httpApi.js 50–104): names already read come from the cache (unless `force`), the others are asked in
    /// one request and answered as nvram_get writes them for a browser.
    mutating func nvramGet(_ keys: [String], force: Bool = false, _ client: RouterClient) async throws -> [String: String] {
        let wanted = force ? keys : keys.filter { http.nvram.values[$0] == nil }
        if !wanted.isEmpty { try await fetchEncoded(wanted, client) }
        return http.nvram.get(keys, force: force, encoded: http.encoded)
    }
    /// One nvramGet value.
    mutating func nvram(_ key: String, force: Bool = false, _ client: RouterClient) async throws -> String {
        try await nvramGet([key], force: force, client)[key] ?? ""
    }
    /// httpApi.nvramGetWanByUnit (216–225): the wan<unit>_ names, read with forceUpdate, answered under their wan_ names.
    mutating func nvramGetWanByUnit(_ keys: [String], _ client: RouterClient) async throws -> [String: String] {
        let unit = sys.ethWanIf
        let named = keys.map { javaScriptReplace($0, "wan_", "wan\(unit)_") }
        let values = try await nvramGet(named, force: true, client)
        var result: [String: String] = [:]
        for name in named { result[javaScriptReplace(name, String(unit), "")] = values[name] ?? "" }
        return result
    }
    /// httpApi.nvramCharToAscii (160–214) followed by decodeURIComponent, as the pages use it; nil when the bytes are not UTF-8
    /// (decodeURIComponent throws URIError).
    mutating func charToAscii(_ key: String, _ client: RouterClient) async throws -> String? {
        if http.encoded[key] == nil { try await fetchEncoded([key], client) }
        return String(bytes: charToAsciiBytes(http.encoded[key] ?? ""), encoding: .utf8)
    }
    mutating func fetchEncoded(_ keys: [String], _ client: RouterClient) async throws {
        let readable = RouterClient.readableKeys(keys)
        if !readable.isEmpty { http.encoded.merge(try await client.readEncodedSettings(readable)) { _, new in new } }
        for key in keys where !readable.contains(key) { http.encoded[key] = "" }
    }
    /// httpApi.hookGet (412–452): the member of the answer, "" when the request fails.
    mutating func hookGet(_ name: String, force: Bool = false, _ client: RouterClient) async throws -> OrderedJSON? {
        if !force, let cached = http.hooks[name] { return cached }
        let value = try await client.pageHook(name)
        http.hooks[name] = value ?? .null
        return value
    }
    /// httpApi.nvramDefaultGet (106–158).
    mutating func nvramDefaultGet(_ keys: [String], _ client: RouterClient) async throws -> [String: String] {
        let wanted = keys.filter { http.defaults[$0] == nil }
        if !wanted.isEmpty { http.defaults.merge(try await client.qisDefaults(wanted)) { _, new in new } }
        return Dictionary(keys.map { ($0, http.defaults[$0] ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    /// postDataModel.insert (plugins.js 1914–1932): members with a value are set in order, those with "" are read with
    /// nvramGet; the walk stops at the first name qisPostData already has. The values read are added cached names first,
    /// then the others in the order asked (nvramGet's retData).
    mutating func insert(_ object: [(String, OrderedJSON)], _ client: RouterClient) async throws {
        var query: [String] = []
        for (name, value) in object {
            if post.has(name) { break }
            if value == .string("") { query.append(name) } else { post.set(name, value) }
        }
        guard !query.isEmpty else { return }
        let cached = query.filter { http.nvram.values[$0] != nil }
        // The administrator password is never read: the page overwrites it before anything is sent (apply.login 227–236).
        let readable = query.filter { $0 != "http_passwd" }
        var values = try await nvramGet(readable, client)
        values["http_passwd"] = ""
        for name in cached + query.filter({ !cached.contains($0) }) { post.set(name, values[name] ?? "") }
    }

    /// `$(".hint").remove()` (hasBlank, plugins.js 745–753): every hint goes.
    mutating func clearHints() { hints = [:]; wirelessHints = [:] }
    /// hasBlank: a hint under every empty input; true when there is one.
    mutating func hasBlank(_ fields: [QISFieldID]) -> Bool {
        clearHints()
        for field in fields where form.value(field).isEmpty { hints[field] = QISText.fieldBlank }
        return !hints.isEmpty
    }
}

// MARK: - isSupport (plugins.js 2045–2143)

extension QISWizard {
    var ui: UISupport { http.ui }
    /// `ui_support[name] > 0 || productid.search(name) !== -1`, the default branch.
    private func listed(_ name: String) -> Bool {
        javaScriptAbove(ui.value(name), .number("0")) || javaScriptSearch(sys.productid, name)
    }
    /// isSupport as the wizard's plugins.js defines it.
    func isSupport(_ name: String) -> Bool {
        switch name {
        case "ForceBWDPI", "QISBWDPI", "boostkey", "GUNDAM_UI": return false
        case "VPNCLIENT": return !["US", "CA", "TW", "CN", "CT", "GD", "TC"].contains { isSku($0) }
        case "IPTV": return !(isSupport("noiptv") || ["US", "CN", "CT", "GD", "TC", "CA", "U2", "TW"].contains { isSku($0) })
        case "ENABLE_IPv6": return ["CN", "GD", "TC"].contains { isSku($0) }
        case "SMARTCONNECT":
            return ["smart_connect_v2", "smart_connect", "bandstr"].contains { javaScriptLooselyEqual(ui.object?[$0], .string("1")) }
                || javaScriptLooselyEqual(ui.object?["smart_connect"], .string("2"))
        case "amas_bdl":
            return isSupport("prelink") && javaScriptAtLeast(ui.object?["amas_bdl"] ?? .null, .number("1")) && !(http.nvram.values["amas_bdlkey"] ?? "").isEmpty
        case "FRONTHAUL_NETWORK": return javaScriptTruthy(ui.object?["amas_fronthaul_network"])
        case "MB_mode_concurrep": return false
        case "MLO_CLIENT": return javaScriptTruthy(ui.object?["mloclient"])
        case "concurrep":
            return javaScriptTruthy(ui.object?["concurrep"]) && !javaScriptLooselyEqual(post["mlo_rp"], .number("1")) && !javaScriptLooselyEqual(post["mlo_mb"], .number("1"))
        case "SDN_Scenario":
            return isSupport("mtlancfg") && isSupport("BUSINESS") && !isSupport("mlo") && sys.isDefault && !sys.productid.contains("EBG") && isSwMode("RT")
        case "apMode_detwan": return sys.productid == "EBA63"
        case "mloSetup": return sys.mloSetup && (isSwMode("RT") || isSwMode("AP"))
        case "mainfhSetup": return isSupport("sdn_mwl") && (isSwMode("RT") || isSwMode("AP"))
        case "SiteManager": return false
        default: return listed(name)
        }
    }
    /// isSupport("MaxRule_SDN"): `ui_support["MaxRule_SDN"] || false`, then `== "0" ? 6 : parseInt(…) - 1` (plugins.js 2840).
    var sdnMaximum: Int {
        let value = ui.object?["MaxRule_SDN"]
        let raw: OrderedJSON = javaScriptTruthy(value) ? value! : .bool(false)
        if javaScriptLooselyEqual(raw, .string("0")) || raw == .bool(false) { return 6 }
        let number = javaScriptParseInt(TORSettings.javaScriptString(raw))
        return number.isNaN ? 0 : (number - 1).clampedInt
    }
    /// isSku (2160–2162): territory_code.search(pattern).
    func isSku(_ pattern: String) -> Bool { javaScriptSearch(sys.territoryCode, pattern) }
    func isSwMode(_ mode: String) -> Bool { mode.lowercased() == sys.opMode.lowercased() }
    func isOriginSwMode(_ mode: String) -> Bool { mode.lowercased() == sys.originOpMode.lowercased() }
    func isSwModeChanged() -> Bool { sys.opMode.lowercased() != sys.originOpMode.lowercased() }
    /// Object.keys(systemVariable.eth_wan_list).length.
    var ethWanCount: Int { sys.ethWanList.members.count }

    /// get_wl_unit_by_band (plugins.js 401–421): the band's index in wlnband_list (upper-cased), "" when it has none.
    func wlUnit(_ band: String) -> String {
        let map = ["2G": "2G1", "5G": "5G1", "6G": "6G1"]
        let upper = band.uppercased()
        let list = javaScriptSplit((http.nvram.values["wlnband_list"] ?? "").uppercased(), "&#60")
        return list.firstIndex(of: map[upper] ?? upper).map(String.init) ?? ""
    }
    /// get_band_by_wl_unit (2800–2803).
    func band(ofUnit unit: Int) -> String? {
        let list = javaScriptSplit(http.nvram.values["wlnband_list"] ?? "", "&#60")
        return unit >= 0 && unit < list.count ? list[unit] : nil
    }
    /// getAllWlArray (163–209): the bands of wlnband_list sorted by their number, with title and SSID suffix.
    var allWlArray: [(title: String, unit: String, suffix: String)] {
        var bands = javaScriptSplit(http.nvram.values["wlnband_list"] ?? "", "&#60")
        func mapping(_ key: String) -> (String, String)? {
            switch key {
            case "2g1": ("2.4 GHz", "")
            case "5g1": bands.contains("5g2") ? ("5 GHz-1", "_5G-1") : ("5 GHz", "_5G")
            case "5g2": ("5 GHz-2", "_5G-2")
            case "6g1": bands.contains("6g2") ? ("6 GHz-1", "_6G-1") : ("6 GHz", "_6G")
            case "6g2": ("6 GHz-2", "_6G-2")
            case "60g": ("60 GHz", "_60G")
            default: nil
            }
        }
        // parseFloat of "2g1" is 2; Array.prototype.sort is stable.
        bands = bands.enumerated().sorted { a, b in
            let x = javaScriptParseFloat(a.element), y = javaScriptParseFloat(b.element)
            if x.isNaN || y.isNaN || x == y { return a.offset < b.offset }
            return x < y
        }.map(\.element)
        var result = bands.compactMap { key in mapping(key).map { (title: $0.0, unit: wlUnit(key.uppercased()), suffix: $0.1) } }
        if isSupport("amas_bdl"), !isSupport("prelink_mssid"), isSwMode("RT") || isSwMode("AP") {
            let unit = javaScriptParseInt(TORSettings.javaScriptString(ui.value("prelink_unit")))
            // parseInt gives a whole number; compared as one before it becomes an index.
            if !unit.isNaN, unit >= 0, unit < Double(result.count) { result.remove(at: Int(unit)) }
        }
        return result
    }
    /// The #wireless_checkbox label getAllWlArray writes (plugins.js 196–197): `Separate 2.4 GHz, 5 GHz`.
    public var separateLabel: String { "Separate " + allWlArray.map(\.title).joined(separator: ", ") }
    /// getScArray (99–143).
    func scArray(_ mode: String) -> (inputs: [(title: String, unit: String)], value: OrderedJSON) {
        switch mode {
        case "SC_2g5g":
            let inputs: [(String, String)]
            if isSupport("quadband") {
                inputs = wlUnit("5G2") != "" ? [("2.4 GHz / 5 GHz-1 / 5 GHz-2", wlUnit("2G")), ("6 GHz", wlUnit("6G"))]
                    : [("2.4 GHz / 5 GHz", wlUnit("2G")), ("6 GHz-1", wlUnit("6G1")), ("6 GHz-2", wlUnit("6G2"))]
            } else {
                inputs = [("2.4 GHz / 5 GHz", wlUnit("2G")), ("6 GHz", wlUnit("6G"))]
            }
            return (inputs.map { (title: $0.0, unit: $0.1) }, .number(isSupport("smart_connect_v2") ? "1" : "3"))
        case "SC_5g5g": return ([(title: "2.4 GHz", unit: wlUnit("2G")), (title: "5 GHz", unit: wlUnit("5G"))], .number("2"))
        case "SC_dwb_mode": return ([(title: "2.4 GHz / 5 GHz-1", unit: wlUnit("2G")), (title: "5 GHz-2", unit: wlUnit("5G2"))], .number("1"))
        default: return ([(title: "", unit: wlUnit("2G"))], .number("1"))
        }
    }
    /// getSelifValue (145–161).
    func selifValue(_ mode: String) -> Int {
        var value = 0
        if wlUnit("2G") != "" { value += 1 }
        if wlUnit("5G1") != "" { value += 2 }
        if wlUnit("5G2") != "" { value += 4 }
        if mode == "SC_all" {
            if wlUnit("6G1") != "" { value += 8 }
            if wlUnit("6G2") != "" { value += 16 }
        } else if mode == "SC_5g5g", wlUnit("2G") != "" { value -= 1 }
        return value
    }

    /// isWANChanged (plugins.js 1948–1968).
    func isWANChanged() -> Bool {
        var changed = false
        if post.has("wan_proto"), post.text("wan_proto") != sys.originWanType { changed = true }
        if post.has("wan_dnsenable_x"), post.text("wan_dnsenable_x") != sys.wanDnsenable { changed = true }
        if post.has("wan_pppoe_username"), post.text("wan_pppoe_username") != sys.originPppUsername { changed = true }
        if post.has("wan_pppoe_passwd"), post.text("wan_pppoe_passwd") != sys.originPppPassword { changed = true }
        return changed
    }
    /// updateOriginWan (1943–1946).
    mutating func updateOriginWan() {
        if post.has("wan_proto") { sys.originWanType = post.text("wan_proto") }
        if post.has("wan_dnsenable_x") { sys.wanDnsenable = post.text("wan_dnsenable_x") }
    }
    /// isWANLANChange (1970–2002).
    func isWANLANChange() -> Bool {
        var changed = false
        if isSupport("2p5G_LWAN"), post.has("wans_extwan"), post.text("wans_extwan") != sys.originWansExtwan { changed = true }
        if isSupport("10G_LWAN") || isSupport("10GS_LWAN"), post.has("wans_dualwan"), post.text("wans_dualwan") != sys.originWansDualwan { changed = true }
        if isSupport("autowan"), post.has("autowan_enable"), post.text("autowan_enable") != sys.originAutoWAN { changed = true }
        if ethWanCount > 1 {
            for (_, wan) in sys.ethWanList.members {
                for (key, _) in wan["extra_settings"]?.members ?? [] where post.has(key) && post.text(key) != (sys.extra[key] ?? "undefined") { changed = true }
            }
        }
        return changed
    }
    /// hadPlugged (plugins.js 767–770): show_usb_path, cached, joined and searched.
    mutating func hadPlugged(_ device: String, _ client: RouterClient) async throws -> Bool {
        let list = try await hookGet("show_usb_path", client)
        let joined: String
        switch list {
        case .array(let items)?: joined = TORSettings.javaScriptString(.array(items))
        case nil, .null?, .bool(false)?: joined = ""
        case .string(let text)? where text.isEmpty: joined = ""
        default: return false
        }
        return javaScriptSearch(joined, device)
    }
}

/// String.prototype.search with a text pattern, which becomes a RegExp; -1 (false) when the pattern does not compile.
func javaScriptSearch(_ text: String, _ pattern: String) -> Bool {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
    return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
}

/// parseFloat: the longest leading decimal number after white space; NaN without one.
func javaScriptParseFloat(_ text: String) -> Double {
    let body = javaScriptTrim(text)
    guard let match = body.range(of: #"^[+-]?(Infinity|[0-9]+(\.[0-9]*)?([eE][+-]?[0-9]+)?|\.[0-9]+([eE][+-]?[0-9]+)?)"#, options: .regularExpression) else { return .nan }
    return javaScriptNumber(String(body[match])) ?? .nan
}

// MARK: - WAN detection (httpApi.js 524–677)

extension QISWizard {
    static let detwanKeys = ["wan0_state_t", "wan0_sbstate_t", "wan0_auxstate_t", "autodet_state", "autodet_auxstate", "wan0_proto",
                             "link_internet", "x_Setting", "usb_modem_act_sim", "link_wan", "wans_dualwan", "wan1_state_t", "wan1_sbstate_t", "wan1_auxstate_t"]
    /// httpApi.detwanGetRet: the WAN type the detection reports. Where the page calls startAutoDet() itself the start is noted
    /// as a side effect for the app to confirm.
    mutating func detwanGetRet(_ client: RouterClient) async throws -> (type: String, conflict: Bool) {
        let info = try await nvramGet(Self.detwanKeys, force: true, client)
        let tcode = try await nvram("territory_code", force: true, client)
        func v(_ key: String) -> String { info[key] ?? "" }
        var type = "CHECKING"
        var conflict = v("wan0_state_t") == "4" && v("wan0_sbstate_t") == "4"
        // The local hadPlugged reads show_usb_path again (forceUpdate) each time.
        func plugged() async throws -> Bool {
            let list = try await hookGet("show_usb_path", force: true, client)
            if case .array(let items)? = list { return javaScriptSearch(TORSettings.javaScriptString(.array(items)), "modem") }
            return false
        }
        let pppoe = v("autodet_state") == "6" || v("autodet_auxstate") == "6"
        // `tcode.search("CA")` without "== -1" (557): only CA at the start makes it false.
        let iptvSupport = !javaScriptSearch(tcode, "TW") && !javaScriptSearch(tcode, "US") && !javaScriptSearch(tcode, "U2")
            && javaScriptSearchIndex(tcode, "CA") != 0 && !javaScriptSearch(tcode, "CN") && !javaScriptSearch(tcode, "CT")
            && !javaScriptSearch(tcode, "GD") && !javaScriptSearch(tcode, "TC") && !isSupport("noiptv")
        if v("link_wan") == "" {
            type = "CHECKING"
        } else if v("link_wan") == "0", isSupport("gobi") ? true : !(try await plugged()) {
            type = "NOWAN"
        } else if v("wan0_state_t") == "2", v("wan0_sbstate_t") == "0" {
            if v("link_internet") == "2" {
                let choosePPPoE = pppoe && v("x_Setting") == "0" && javaScriptSearch(tcode, "JP")
                let specialISP = !pppoe && v("x_Setting") == "0" && iptvSupport
                type = choosePPPoE ? "PPPoE" : specialISP ? "DHCPSPECIALISP" : "CONNECTED"
            } else {
                type = pppoe ? "PPPoE" : "DHCP"
            }
        } else if isSupport("usb_bk"), v("wans_dualwan") == "wan usb", v("link_internet") == "2", v("wan1_state_t") == "2", v("wan1_sbstate_t") == "0" {
            type = "CONNECTED"
        } else if pppoe {
            type = "PPPoE"
        } else if !isSupport("gobi"), try await plugged() {
            type = "MODEM"
        } else if v("autodet_state") == "3" || v("autodet_state") == "5" {
            type = "RESETMODEM"
        } else if v("autodet_state") == "4" {
            if v("wan0_auxstate_t") != "1" {
                effects.append(.autoDetect)
                type = "CHECKING"; conflict = false
                sys.detRetryCnt = 10
            } else {
                type = "NOWAN"
            }
        } else if v("wan0_state_t") == "4", v("wan0_sbstate_t") == "4" {
            type = iptvSupport ? "DHCPSPECIALISP" : "CONNECTED"
            conflict = true
        } else {
            type = "CHECKING"
            if let count = sys.detRetryCnt, count > 0 {
                sys.detRetryCnt = count - 1
            } else {
                effects.append(.autoDetect)
                conflict = false
                sys.detRetryCnt = 10
            }
        }
        return (type, conflict)
    }
    /// httpApi.isConnected (911–921) for WAN unit 0.
    mutating func isConnected(_ client: RouterClient) async throws -> Bool {
        let mode = try await nvram("sw_mode", client)
        let info = try await nvramGet(["wan0_state_t", "wan0_sbstate_t", "wan0_auxstate_t", "link_internet"], force: true, client)
        if mode != "1" { return info["link_internet"] == "2" }
        return info["link_internet"] == "2" && info["wan0_state_t"] == "2" && info["wan0_sbstate_t"] == "0" && info["wan0_auxstate_t"] == "0"
    }
    /// httpApi.isPppAuthFail (895–909): once true it stays checked and reads false afterwards.
    mutating func isPppAuthFail(_ client: RouterClient) async throws -> Bool {
        if sys.pppAuthFailChecked { return false }
        let info = try await nvramGet(["wan0_state_t", "wan0_sbstate_t", "wan0_auxstate_t", "wan0_proto", "sw_mode"], force: true, client)
        let failed = info["sw_mode"] == "1" && info["wan0_proto"] == "pppoe" && info["wan0_state_t"] == "4" && info["wan0_sbstate_t"] == "2" && info["wan0_auxstate_t"] == "0"
        sys.pppAuthFailChecked = failed
        return failed
    }
}

/// The index String.prototype.search returns, -1 without a match (UTF-16 offset).
func javaScriptSearchIndex(_ text: String, _ pattern: String) -> Int {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return -1 }
    return match.range.location
}

// MARK: - Checks

/// The validator checks the wizard calls: plugins.js overrides hostNameString, invalidChar, KRSkuPwd and valid_block_chars;
/// stringSSID, ssidCheck, psk, psk_KR, string and hex are validator.js's. A nil answer accepts; otherwise the text of the hint
/// or alert.
public enum QISCheck {
    /// validator.hostNameString (plugins.js 2306–2318): `^[a-zA-Z0-9][a-zA-Z0-9\-\_]+$`; JS_short_username below 2 characters.
    static func hostName(_ text: String) -> String? {
        // JavaScript's `$` ends the text; ICU's would also stop before a final line break, so `\z`.
        if text.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9_-]+\z"#, options: .regularExpression) != nil { return nil }
        return text.utf16.count < 2 ? QISText.shortUsername : QISText.validHostname
    }
    /// Whether a UTF-16 unit is outside " " to "~" (charAt compared as text); with `allowSpace` false the space is refused too.
    static func hasOutsidePrintable(_ text: String, allowSpace: Bool = true) -> Bool {
        text.utf16.contains { allowSpace ? ($0 < 0x20 || $0 > 0x7E) : ($0 <= 0x20 || $0 > 0x7E) }
    }
    // The checks below only ever see passwords (the admin password, the Wi-Fi key, the IoT key). Each refuses what the page
    // refuses, but where the page names the characters it refused (`"<#JS_validstr2#> '" + invalid_char + "' !"`), the
    // answer is QISText.passwordCharacters, which does not repeat any of the input.

    /// validator.invalidChar (plugins.js 2320–2351); the characters the page lists at 2346 are not repeated.
    static func invalidChar(_ text: String) -> String? {
        if text.hasPrefix("\"") { return QISText.validStr1 + " [\"]" }
        if text.hasSuffix("\"") { return QISText.validStr3 + " [\"]" }
        return hasOutsidePrintable(text) ? QISText.passwordCharacters : nil
    }
    /// validator.KRSkuPwd (2353–2380); the characters the page lists at 2376 are not repeated.
    static func krPassword(_ text: String) -> String? {
        var reason: String?
        if text.range(of: "[A-Za-z]", options: .regularExpression) == nil || text.range(of: "[0-9]", options: .regularExpression) == nil
            || text.utf16.count < 10 || text.range(of: specialClass, options: .regularExpression) == nil
            || text.range(of: ##"([A-Za-z0-9!"#$%&'()*+,\-./:;<=>?@\[\\\]^_`{|}~])\1"##, options: .regularExpression) != nil {
            reason = QISText.loginPolicy
        }
        if hasOutsidePrintable(text) { reason = QISText.passwordCharacters }
        return reason
    }
    /// validator.valid_block_chars (2382–2413): ASCII 32–126 first (the characters the page lists at 2398 are not
    /// repeated), then the listed characters.
    static func blockChars(_ text: String, _ keywords: [String]) -> String? {
        if text.utf16.contains(where: { $0 < 32 || $0 > 126 }) { return QISText.passwordCharacters }
        if !text.isEmpty, keywords.contains(where: { javaScriptContains(text, $0) }) { return keywords.joined(separator: ",") + " " + QISText.invalidChars }
        return nil
    }
    /// isWeakString (plugins.js 2203–2257): a run of the alphabet, digits, symbols or keyboard rows (or reversed), a common
    /// password, or one character repeated. `flag` is "httpd_password" or "wpa_key".
    static func isWeak(_ password: String, _ flag: String) -> Bool {
        let alphas = "abcdefghijklmnopqrstuvwxyz", numerics = "01234567890", symbols = "~!@#$%^&*()_+"
        let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
        let common5 = ["123123", "abc123", "letmein", "master", "qazwsx", "admin"]
        let common8 = ["adminpassword", "loginpassword", "passw0rd", "password", "useradmin", "userpassword"]
        func run(_ term: String) -> Bool { javaScriptContains(term, password) || javaScriptContains(String(term.reversed()), password) }
        var count = 0
        if flag == "httpd_password" {
            count += [alphas, numerics, symbols, rows[0], rows[1], rows[2]].filter(run).count
            count += common5.filter { $0 == password }.count + common8.filter { $0 == password }.count
        } else if flag == "wpa_key" {
            count += [alphas, numerics, symbols, rows[0], rows[1]].filter(run).count
            count += common8.filter { $0 == password }.count
        }
        let units = Array(password.utf16)
        if units.allSatisfy({ $0 == units.first }) { count += 1 }
        return count > 0
    }
    /// validator.lengthInUtf8 (validator.js 1845–1849); nil where encodeURI throws (a lone surrogate).
    static func utf8Length(_ text: String) -> Int? {
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let unit = units[index]
            if (0xD800...0xDBFF).contains(unit) {
                guard index + 1 < units.count, (0xDC00...0xDFFF).contains(units[index + 1]) else { return nil }
                index += 2; continue
            }
            if (0xDC00...0xDFFF).contains(unit) { return nil }
            index += 1
        }
        return text.utf8.count
    }
    /// validator.stringSSID (2004–2049): the alert, and whether it clears the input.
    static func ssid(_ text: String, utf8SSID: Bool) -> (alert: String, clears: Bool)? {
        if text.isEmpty { return (QISText.fieldBlank, false) }
        guard let length = utf8Length(text) else { return nil }
        if length > 32 { return (QISText.maxSSID, true) }
        let units = Array(text.utf16)
        var notSpace = 0
        for i in 0..<length {
            // charCodeAt past the end is NaN, which is not 32.
            let code: UInt16? = i < units.count ? units[i] : nil
            if !utf8SSID, let code, code < 32 || code > 126 {
                return (QISText.validSSID1 + " " + String(decoding: [code], as: UTF16.self) + " " + QISText.validSSID2, true)
            }
            if code != 32 { notSpace += 1 }
        }
        if notSpace == 0 { return (QISText.fieldBlank, false) }
        return nil
    }
    /// validator.ssidCheck (2051–…), on key up: the hint under the SSID input.
    static func ssidHint(_ text: String, utf8SSID: Bool) -> String? {
        guard let length = utf8Length(text) else { return nil }
        var hint: String?
        if length > 32 { hint = QISText.maxSSID }
        let units = Array(text.utf16)
        if !utf8SSID {
            for i in 0..<length where i < units.count && (units[i] < 32 || units[i] > 126) {
                hint = QISText.validSSID1 + " " + String(decoding: [units[i]], as: UTF16.self) + " " + QISText.validSSID2
            }
        }
        return hint
    }
    /// validator.psk (1640–1681): the alerts in order, none when accepted. A bad character makes validator.string alert
    /// first, then psk its own.
    static func psk(_ text: String) -> [String] {
        let length = text.utf16.count
        if length < 8 || length > 64 { return [QISText.pskInvalid] }
        if length != javaScriptTrim(text).utf16.count { return [QISText.pskWhiteSpace] }
        if length <= 63, let alert = string(text) { return [alert, QISText.pskInvalid] }
        if length == 64, text.range(of: "[^a-fA-F0-9]", options: .regularExpression) != nil { return [QISText.pskInvalid] }
        return []
    }
    static let specialClass = ##"[!"#$%&'()*+,\-./:;<=>?@\[\\\]^_`{|}~]"##
    /// validator.psk_KR (1683–1725) with validator.string_KR (1897–1944): the alerts, and whether the input is cleared. The
    /// characters the page lists (1716, 1938) are not repeated.
    static func pskKR(_ text: String) -> (alerts: [String], clears: Bool) {
        let length = text.utf16.count
        if text.range(of: "[A-Za-z]", options: .regularExpression) == nil || text.range(of: "[0-9]", options: .regularExpression) == nil
            || length < 8 || length > 63 || text.range(of: specialClass, options: .regularExpression) == nil {
            return ([QISText.pskKR + " " + QISText.validPWD], true)
        }
        if length != javaScriptTrim(text).utf16.count { return ([QISText.pskWhiteSpace], false) }
        var stringKR: String?
        if length < 10 || text.range(of: ##"([A-Za-z0-9!"#$%&'()*+,\-./:;<=>?@\[\\\]^_`{|}~])\1"##, options: .regularExpression) != nil {
            stringKR = QISText.loginPolicy
        } else if text.hasPrefix("\"") {
            stringKR = QISText.validStr1 + " [\"]"
        } else if text.hasSuffix("\"") {
            stringKR = QISText.validStr3 + " [\"]"
        } else if hasOutsidePrintable(text, allowSpace: false) {
            stringKR = QISText.passwordCharactersNoSpace
        }
        if let stringKR { return ([stringKR, QISText.pskInvalid], false) }
        if hasOutsidePrintable(text, allowSpace: false) { return ([QISText.passwordCharactersNoSpace], true) }
        return ([], false)
    }
    /// validator.string (1858–1895); the characters the page lists at 1882 are not repeated.
    static func string(_ text: String) -> String? { invalidChar(text) }

    /// validator.isIPAddr on key press (validator.js 545–590): digits (with a "." first added after three digits not
    /// separated by one, while fewer than three dots), a "." unless one ends the value or three are there; other keys refused.
    public static func ipAddressKeyPress(_ value: String, _ key: Character) -> String? {
        let units = Array(value.utf16), dot = UInt16(UInt8(ascii: "."))
        let dots = units.filter { $0 == dot }.count
        if ("0"..."9").contains(key) {
            if dots < 3, units.count >= 3, units[units.count - 3] != dot, units[units.count - 2] != dot, units[units.count - 1] != dot { return value + "." }
            return value
        }
        if key == "." {
            if units.last == dot || dots == 3 { return nil }
            return value
        }
        return nil
    }
}
