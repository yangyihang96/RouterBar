import Foundation
import CryptoKit

// 网络设置向导的无线页（goTo.Wireless / apply.wireless / abort.wireless）、物联网网络页（SDN_IoT），以及最终提交
// （apply.submitQIS、getRestartService / setRestartService、configApmVariables）。行号见 RouterQISWizard.swift 的说明。

// MARK: - Wireless

extension QISWizard {
    /// goTo.Wireless (handler.js 4146–4422) for RT and AP.
    mutating func goToWireless(_ c: RouterClient) async throws {
        try await insert(QISObject.general, c)
        sys.bandSteeringShown = false
        if !isSupport("noWiFi") {
            if isSupport("SMARTCONNECT") {
                if isSupport("smart_connect_v2") { sys.selifInObject = try await nvram("smart_connect_selif_x", c) }
                try await insert(smartConnectObject, c)
                try await setSeparate(true, c)
                form.sync = true
                if isSwMode("RT") || isSwMode("AP") || isSwMode("WISP") {
                    sys.bandSteeringShown = true
                    if sys.isDefault {
                        if !isSupport("separate_ssid") { try await setSeparate(false, c) }
                    } else if try await nvram("smart_connect_x", c) != "0" {
                        try await setSeparate(false, c)
                    }
                }
                post.set("smart_connect_x", form.separate ? .string("0") : scArray(sys.scMode).value)
                if isSupport("smart_connect_v2") {
                    post.set("smart_connect_selif_x", javaScriptLooselyEqual(post["smart_connect_x"], .string("1"))
                             ? .number(String(selifValue(sys.scMode))) : .string(try await nvram("smart_connect_selif_x", c)))
                }
                try await setupFronthaulNetwork(post["smart_connect_x"], c)
            } else {
                form.sync = true
            }
            if form.wireless == nil {
                let smart = post.has("smart_connect_x") && !form.separate
                try await generateWireless(smart ? scArray(sys.scMode).inputs : allWlArray.map { (title: $0.title, unit: $0.unit) }, c)
                form.sync = form.wireless?.count != 1
                sys.wirelessHandlerBound = true
            }
            // An empty password input adds every band's wirelessObj (4318–4327).
            if form.wireless?.contains(where: { $0.key.isEmpty }) == true {
                for band in allWlArray { try await insert(QISObject.wireless(band.unit), c) }
            }
            if isSwModeChanged() { for band in allWlArray { try await insert(QISObject.wireless(band.unit), c) } }
        }
        loadPage(.wireless)
    }
    /// smartConnectObj (qisData.js 157–159) with the selif member goTo.Wireless may have added.
    var smartConnectObject: [(String, OrderedJSON)] {
        [("smart_connect_x", .string("1"))] + (sys.selifInObject.map { [("smart_connect_selif_x", .string($0))] } ?? [])
    }
    /// `$("#wireless_checkbox").enableCheckBox(on).change()`: the handler runs once it is bound.
    mutating func setSeparate(_ on: Bool, _ c: RouterClient) async throws {
        form.separate = on
        if sys.wirelessHandlerBound { try await wirelessCheckboxChanged(on, c) }
    }
    /// The #wireless_checkbox change handler (4269–4306).
    mutating func wirelessCheckboxChanged(_ on: Bool, _ c: RouterClient) async throws {
        let list: [(title: String, unit: String)]
        if on {
            list = allWlArray.map { (title: $0.title, unit: $0.unit) }
            post.set("smart_connect_x", "0")
            if isSupport("smart_connect_v2") { post.set("smart_connect_selif_x", try await nvram("smart_connect_selif_x", c)) }
            try await setupFronthaulNetwork(post["smart_connect_x"], c)
        } else {
            let sc = scArray(sys.scMode)
            list = sc.inputs
            post.set("smart_connect_x", sc.value)
            if isSupport("smart_connect_v2") {
                post.set("smart_connect_selif_x", javaScriptLooselyEqual(sc.value, .string("1")) ? .number(String(selifValue(sys.scMode)))
                         : .string(try await nvram("smart_connect_selif_x", c)))
            }
            try await setupFronthaulNetwork(post["smart_connect_x"], c)
        }
        try await generateWireless(list, c)
        form.sync = form.wireless?.count != 1
    }
    /// setupFronthaulNetwork (plugins.js 1677–1713).
    mutating func setupFronthaulNetwork(_ smartConnect: OrderedJSON?, _ c: RouterClient) async throws {
        guard isSupport("FRONTHAUL_NETWORK") else { return }
        _ = try await nvram("dwb_mode", c)
        try await insert(QISObject.fronthaul, c)
        let mode = javaScriptParseInt(smartConnect.map(TORSettings.javaScriptString) ?? "")
        if [0, 2, 3].contains(mode) { post.set("fh_ap_enabled", "0") }
        else if mode == 1 { post.set("fh_ap_enabled", try await nvramDefaultGet(["fh_ap_enabled"], c)["fh_ap_enabled"] ?? "") }
        switch javaScriptParseInt(post.text("fh_ap_enabled")) {
        case 0: post.set("acs_unii4", isSupport("amas_bdl") ? "1" : "0")
        case 1, 2: post.set("acs_unii4", "0")
        default: break
        }
        if mode == 0 { post.remove("acs_unii4") }
    }
    /// Get_Component_WirelessInput (plugins.js 955–1097): each band's SSID and key as nvram_char_to_ascii gives them, or the
    /// main fronthaul network's on sdn_mainfh routers (an SSID not found there leaves the inputs empty); decodeURIComponent
    /// is applied to whichever it is.
    mutating func generateWireless(_ list: [(title: String, unit: String)], _ c: RouterClient) async throws {
        let main = isSupport("sdn_mainfh") && !sys.isDefault ? try await mainFronthaulInfo(c) : nil
        var inputs: [QISWirelessInput] = []
        for band in list {
            var ssid = try await encodedValue("wl\(band.unit)_ssid", c), key = try await encodedValue("wl\(band.unit)_wpa_psk", c)
            _ = try await encodedValue("wl\(band.unit)_auth_mode_x", c)
            if let main {
                let value: Int
                switch self.band(ofUnit: Int(band.unit) ?? -1) {
                case "2g1": value = 1
                case "5g": value = 2
                case "5g1": value = wlUnit("5g2") == "" ? 2 : 4
                case "5g2": value = 8
                case "6g": value = 16
                case "6g1": value = wlUnit("6g2") == "" ? 16 : 32
                case "6g2": value = 64
                default: value = 0
                }
                if let found = main.first(where: { $0.band & value != 0 }) { ssid = found.ssid; key = found.psk } else { ssid = ""; key = "" }
            }
            guard let decodedSSID = ssid.removingPercentEncoding, let decodedKey = key.removingPercentEncoding else {
                throw RouterError.validation("网页在这里调用 decodeURIComponent 时出错（URIError），无线页不会显示。请在浏览器中打开网页向导核对。")
            }
            inputs.append(QISWirelessInput(unit: band.unit, title: band.title, ssid: decodedSSID, key: decodedKey))
        }
        form.wireless = inputs
        wirelessHints = [:]
    }
    /// The nvram_char_to_ascii answer as the page keeps it (still percent-encoded).
    mutating func encodedValue(_ key: String, _ c: RouterClient) async throws -> String {
        if http.encoded[key] == nil { try await fetchEncoded([key], c) }
        return http.encoded[key] ?? ""
    }
    /// get_sdn_main_fh_info (plugins.js 3072–3101): the MAINFH networks' SSID, key and band bits, decoded.
    mutating func mainFronthaulInfo(_ c: RouterClient) async throws -> [(ssid: String, psk: String, band: Int)] {
        var result: [(ssid: String, psk: String, band: Int)] = []
        if isSupport("mainfhSetup") {
            for item in javaScriptSplit(try await charToAscii("sdn_rl", c) ?? "", "<") where javaScriptContains(item, "MAINFH") && !item.isEmpty {
                let fields = javaScriptSplit(item, ">")
                let index = fields.count > 5 ? fields[5] : "undefined"
                let ssid = try await charToAscii("apm\(index)_ssid", c) ?? ""
                let security = javaScriptSplit(try await charToAscii("apm\(index)_security", c) ?? "", "<")
                let dut = javaScriptSplit(try await charToAscii("apm\(index)_dut_list", c) ?? "", "<")
                var psk = "", band = 0
                if security.count > 1, !security[1].isEmpty {
                    let parts = javaScriptSplit(security[1], ">")
                    psk = parts.count > 3 ? parts[3] : "undefined"
                }
                if dut.count > 1, !dut[1].isEmpty {
                    let parts = javaScriptSplit(dut[1], ">")
                    let number = javaScriptParseInt(parts.count > 1 ? parts[1] : "")
                    band = number.isNaN ? 0 : number.clampedInt
                }
                result.append((ssid, psk, band))
            }
        }
        // The fallback entry's band is "", whose bits are 0.
        return result.isEmpty ? [("", "", 0)] : result
    }
    /// The SSID check rc_support decides (validator.js 2005–2006).
    var utf8SSID: Bool { javaScriptSplit(http.nvram.values["rc_support"] ?? "", " ").contains("utf8_ssid") }

    /// Typing in a wireless input: its own keyup (4190–4201, 4231–4246), the `.wlInput` keyup that copies the 2.4 GHz values to
    /// the other bands while the hidden sync box is on (4170–4187), the SSID hint (validator.ssidCheck), and change (4188–4196).
    public mutating func editWireless(_ unit: String, ssid: Bool, _ value: String) {
        guard var inputs = form.wireless, let at = inputs.firstIndex(where: { $0.unit == unit }) else { return }
        form.changePending = true
        if ssid { inputs[at].ssid = value } else { inputs[at].key = value }
        let base = wlUnit("2G"), id = (ssid ? "wireless_ssid_" : "wireless_key_") + unit
        if !javaScriptContains(id, base) { form.sync = false }
        if form.sync, javaScriptContains(id, "_" + base) {
            let bands = allWlArray
            for band in bands.dropFirst() {
                guard let target = inputs.firstIndex(where: { $0.unit == band.unit }) else { continue }
                if ssid { inputs[target].ssid = value + (value.utf16.count < 27 ? band.suffix : "") } else { inputs[target].key = value }
            }
        }
        form.wireless = inputs
        if ssid { wirelessHints["ssid:" + unit] = QISCheck.ssidHint(value, utf8SSID: utf8SSID) }
    }

    /// wirelessValidator (1215–1243): nil when the band passes.
    mutating func validateWireless(_ unit: String) throws -> Bool {
        if sys.productid.contains("EBG") { return true }
        guard var inputs = form.wireless, let at = inputs.firstIndex(where: { $0.unit == unit }) else { return true }
        clearHints()
        if inputs[at].ssid.isEmpty { wirelessHints["ssid:" + unit] = QISText.fieldBlank }
        if inputs[at].key.isEmpty { wirelessHints["key:" + unit] = QISText.fieldBlank }
        if !wirelessHints.isEmpty { return false }
        if let problem = QISCheck.ssid(inputs[at].ssid, utf8SSID: utf8SSID) {
            alerts.append(problem.alert)
            if problem.clears { inputs[at].ssid = ""; form.wireless = inputs }
            return false
        }
        if isSku("KR") {
            let problem = QISCheck.pskKR(inputs[at].key)
            if !problem.alerts.isEmpty {
                alerts += problem.alerts
                if problem.clears { inputs[at].key = ""; form.wireless = inputs }
                return false
            }
        } else {
            let problems = QISCheck.psk(inputs[at].key)
            if !problems.isEmpty { alerts += problems; return false }
        }
        if isSupport("mainfhSetup"), let reason = QISCheck.blockChars(inputs[at].key, ["<", ">"]) { wirelessHints["key:" + unit] = reason; return false }
        if QISCheck.isWeak(inputs[at].key, "wpa_key"), try !confirm("weak-wpa-" + unit, QISText.commonPassword) {
            wirelessHints["key:" + unit] = QISText.usePasswordHarder; return false
        }
        return true
    }

    /// apply.wireless (1214–1352).
    mutating func applyWireless(_ c: RouterClient) async throws {
        let baseUnit = wlUnit("2G").isEmpty ? "0" : wlUnit("2G")
        let base = form.wireless?.first { $0.unit == baseUnit }
        for band in 0..<sys.wirelessBand {
            let unit = String(band), prefix = "wl\(band)_"
            let input = form.wireless?.first { $0.unit == unit }
            let sixGHz = Int(wlUnit("6G1")) == band || Int(wlUnit("6G2")) == band
            if isSupport("mlo") {
                if input != nil, try !validateWireless(unit) { return }
                let current = form.wireless?.first { $0.unit == unit }
                post.set(prefix + "ssid", (current?.ssid ?? base?.ssid).map(OrderedJSON.string))
                post.set(prefix + "wpa_psk", (current?.key ?? base?.key).map(OrderedJSON.string))
                post.set(prefix + "crypto", "aes"); post.set(prefix + "11be", "1"); post.set(prefix + "radio", "1"); post.set(prefix + "timesched", "0")
                if sixGHz { post.set(prefix + "auth_mode_x", "sae"); post.set(prefix + "mfp", "2") }
                else { post.set(prefix + "auth_mode_x", "psk2sae"); post.set(prefix + "mfp", "1") }
            } else if post.has(prefix + "ssid") {
                if input != nil, try !validateWireless(unit) { return }
                let current = form.wireless?.first { $0.unit == unit }
                post.set(prefix + "ssid", (current?.ssid ?? base?.ssid).map(OrderedJSON.string))
                post.set(prefix + "wpa_psk", (current?.key ?? base?.key).map(OrderedJSON.string))
                post.set(prefix + "crypto", "aes")
                if sixGHz { post.set(prefix + "auth_mode_x", "sae"); post.set(prefix + "mfp", "2") }
                else {
                    post.set(prefix + "auth_mode_x", isSupport("mlo") ? "psk2sae" : "psk2")
                    let joined = try await isJoinSmartConnect("6G1", c) ? true : try await isJoinSmartConnect("6G2", c)
                    post.set(prefix + "mfp", joined ? "1" : "0")
                }
            }
            if ["sae", "psk2sae"].contains(post.text(prefix + "auth_mode_x")) {
                let wifi7 = try await nvramGet([prefix + "crypto", prefix + "11be"], c)
                if let value = wifi7[prefix + "11be"], !value.isEmpty, value == "1" { post.set(prefix + "crypto", "aes") }
            }
        }
        if try await nvram("dwb_mode", c) == "1" || (isSupport("prelink_mssid") && isSupport("amas_bdl")) {
            if isSwMode("RT") || isSwMode("AP"), !isSupport("mainfhSetup"), try await checkDWBSSID(c) { return }
        }
        if isSupport("SDN_Scenario") { browser(.sdnScenario) }
        else if isSupport("mainfhSetup"), try await createSDNCompatibleNetwork(c) { try await goToIoT(c) }
        else if sys.forceChangePwInTheEnd { try await goToLogin(c) }
        else { try await submitQIS(c) }
    }
    /// isJoinSmartConnect (plugins.js 2756–2798), from the router's smart_connect_selif_x / smart_connect_x.
    mutating func isJoinSmartConnect(_ band: String, _ c: RouterClient) async throws -> Bool {
        var name = band.lowercased()
        if name == "2g" { name = "2g1" }; if name == "5g" { name = "5g1" }; if name == "6g" { name = "6g1" }
        let reference = ["", "", "", "6g2", "6g1", "5g2", "5g1", "2g1"]
        let selif = try await nvram("smart_connect_selif_x", c)
        let parsed = javaScriptParseInt(selif)
        var bits = Array(parsed.javaScriptString(radix: 2))
        while bits.count < 8 { bits.insert("0", at: 0) }
        let version = isSupport("smart_connect_v2") ? "v2" : (isSupport("smart_connect") || isSupport("bandstr")) ? "v1" : ""
        let v1 = try await nvram("smart_connect_x", c)
        if version == "v2" {
            guard let index = reference.firstIndex(of: name), index < bits.count else { return false }
            return bits[index] == "1"
        }
        switch v1 {
        case "1": return true
        case "2": return name == "5g1" || name == "5g2"
        case "3": return name == "2g1" || name == "5g1"
        default: return false
        }
    }
    /// check_dwb_ssid (plugins.js 707–743).
    mutating func checkDWBSSID(_ c: RouterClient) async throws -> Bool {
        let unit = try await nvram("dwb_band", c)
        guard let inputs = form.wireless, let backhaul = inputs.first(where: { $0.unit == unit }) else {
            if !sys.isDefault { for name in ["ssid", "auth_mode_x", "wpa_psk", "crypto", "mfp"] { post.remove("wl\(unit)_\(name)") } }
            return false
        }
        guard !backhaul.ssid.isEmpty else { return false }
        if inputs.contains(where: { $0.unit != unit && $0.ssid == backhaul.ssid }) {
            let title = allWlArray.first { $0.unit == unit }?.title ?? ""
            wirelessHints["ssid:" + unit] = javaScriptReplace("Use a different Network Name (SSID) for your #WIRELESSBAND band.", "#WIRELESSBAND", title)
            return true
        }
        return false
    }

    /// abort.wireless (2372–2473).
    mutating func abortWireless(_ c: RouterClient) async throws {
        post.remove(QISObject.general)
        for unit in 0...3 { post.remove(QISObject.wireless(String(unit))) }
        post.remove(smartConnectObject)
        post.remove(QISObject.fronthaul)
        if isSupport("autowan") {
            // `systemVariable.eth_wan_list["wan"].hasOwnProperty(…)` throws without a "wan" entry; nothing after it runs.
            guard let wan = sys.ethWanList["wan"] else { throw RouterError.validation("网页的“上一步”在这里出错（eth_wan_list 没有 wan），不会离开本页。") }
            for (key, _) in wan["extra_settings"]?.members ?? [] where post.has(key) { post.remove(key) }
        }
        if isSupport("mlo"), flag == "mlo" { exit = .mloPage; return }
        if sys.opMode == "WISP" { loadPreviousPage() }
        else if post.text("wan_proto") == "dhcp", form.dhcpOption { loadPage(.dhcpOption, reverse: true) }
        else if form.iptv { loadPage(.browser(.iptv), reverse: true) }
        else if post.has("modem_enable") { loadPage(.browser(.usbModem), reverse: true) }
        else if post.has("wan_heartbeat_x") { loadPage(.getIP, reverse: true) }
        else if post.has("wan_pppoe_username") { loadPage(.account, reverse: true) }
        else if post.has("wan_ipaddr_x") { loadPage(.staticIP, reverse: true) }
        else if post.has("lan_proto") { loadPage(post.text("lan_proto") == "dhcp" ? .getLanIP : .lanStatic, reverse: true) }
        else if ["DHCP", "V6PLUS", "OCNVC", "DSLITE", "V6OPT"].contains(sys.manualWanType ?? "") { loadPage(.wanSetting, reverse: true) }
        else if sys.detwanType == "DHCP" || sys.detwanType == "CONNECTED" {
            if sys.forceChangePw { loadPage(.login, reverse: true) }
            else if isSupport("amas_bdl") { loadPage(.browser(.aimesh("prelink_desc")), reverse: true) }
            else { loadPreviousPage() }
        }
        else if sys.detwanType == "DHCPSPECIALISP" { loadPreviousPage() }
        else { loadPage(.wanSetting, reverse: true) }
    }
}

// MARK: - IoT network (SDN)

extension QISWizard {
    /// goTo.SDN_IoT (6146–6193): the IoT inputs are built once, from the 2.4 GHz input with "_IoT" while it is under 27.
    mutating func goToIoT(_ c: RouterClient) async throws {
        if !sys.iotBuilt {
            sys.iotBuilt = true
            form.iotLater = false
            fillIoT()
        }
        loadPage(.iot)
    }
    mutating func fillIoT() {
        let baseUnit = wlUnit("2G").isEmpty ? "0" : wlUnit("2G")
        let base = form.wireless?.first { $0.unit == baseUnit }
        let ssid = base?.ssid ?? "undefined"
        form.values[.iotSSID] = ssid + (ssid.utf16.count < 27 ? "_IoT" : "")
        form.values[.iotKey] = base?.key ?? ""
    }
    /// #sdn_iot_checkbox change (6154–6175).
    mutating func iotLaterChanged(_ on: Bool) async throws {
        form.iotLater = on
        if on { form.values[.iotSSID] = ""; form.values[.iotKey] = "" } else { fillIoT() }
    }
    /// apply.SDN_IoT (1787–1829).
    mutating func applyIoT(_ c: RouterClient) async throws {
        let key = form.value(.iotKey), ssid = form.value(.iotSSID)
        if !key.isEmpty {
            hints[.iotKey] = nil
            if form.wireless?.contains(where: { $0.ssid == ssid }) == true { hints[.iotSSID] = QISText.duplicate; return }
            let problems = QISCheck.psk(key)
            if !problems.isEmpty { alerts += problems; return }
            if isSku("KR") {
                let problem = QISCheck.pskKR(key)
                if !problem.alerts.isEmpty { alerts += problem.alerts; if problem.clears { form.values[.iotKey] = "" }; return }
            }
            if let reason = QISCheck.blockChars(key, ["<", ">"]) { hints[.iotKey] = reason; return }
            if QISCheck.isWeak(key, "wpa_key"), try !confirm("weak-iot", QISText.commonPassword) { hints[.iotKey] = QISText.usePasswordHarder; return }
            let sdn = try await newSDNMLO(c)
            if !sdn.isEmpty {
                for (name, value) in sdn { post.set(name, value) }
                post.set("apg\(sys.apgIdx)_ssid", ssid)
                post.set("apg\(sys.apgIdx)_security", "<127>psk2>aes>\(key)>1")
            }
        }
        try await submitQIS(c)
    }
    /// The sdn_rl the SDN helpers start from: the default (`&#60`/`&#62` turned back) after a mode change or on a default
    /// router, otherwise the router's own.
    mutating func baseSDNRL(_ c: RouterClient) async throws -> String {
        if isSwModeChanged() || sys.isDefault {
            return javaScriptReplace(javaScriptReplace(try await nvramDefaultGet(["sdn_rl"], c)["sdn_rl"] ?? "", "&#60", "<", all: true), "&#62", ">", all: true)
        }
        return try await charToAscii("sdn_rl", c) ?? ""
    }
    /// get_new_sdn_mlo (plugins.js 2836–2880).
    mutating func newSDNMLO(_ c: RouterClient) async throws -> [(String, OrderedJSON)] {
        sys.sdnIdx = 0; sys.apgIdx = 0
        var sdnFree = Array(1...max(1, sdnMaximum)), apgFree = sdnFree
        if sdnMaximum < 1 { sdnFree = []; apgFree = [] }
        let rules = try await baseSDNRL(c)
        for entry in javaScriptSplit(rules, "<") where !entry.isEmpty {
            let fields = javaScriptSplit(entry, ">")
            sdnFree.removeAll { javaScriptLooselyEqual(.number(String($0)), .string(fields[0])) }
            if fields.count > 5 { apgFree.removeAll { javaScriptLooselyEqual(.number(String($0)), .string(fields[5])) } }
        }
        guard let sdn = sdnFree.first, let apg = apgFree.first else { return [] }
        var object = QISObject.sdn
        object[0].1 = .string(rules + "<\(sdn)>LEGACY>1>0>0>\(apg)>0>0>0>0>0>0>0>0>0>0>0>0>0>WEB>0>0")
        if let at = object.firstIndex(where: { $0.0 == "apg_dut_list" }) { object[at].1 = .string("<*>7>") }
        if let at = object.firstIndex(where: { $0.0 == "apg_mlo" }) { object[at].1 = .string("0") }
        object = object.map { $0.0.hasPrefix("apg") ? (javaScriptReplace($0.0, "apg", "apg\(apg)"), $0.1) : $0 }
        sys.sdnIdx = sdn; sys.apgIdx = apg
        return object
    }
    /// createSDNCompatibleNetwork (plugins.js 2882–2915).
    mutating func createSDNCompatibleNetwork(_ c: RouterClient) async throws -> Bool {
        if isSwModeChanged() { return true }
        let rules = try await charToAscii("sdn_rl", c) ?? ""
        let defaults = javaScriptReplace(javaScriptReplace(try await nvramDefaultGet(["sdn_rl"], c)["sdn_rl"] ?? "", "&#60", "<", all: true), "&#62", ">", all: true)
        if rules == defaults { return true }
        var legacy = false, count = 0
        for entry in javaScriptSplit(sys.isDefault ? defaults : rules, "<") where !entry.isEmpty {
            let fields = javaScriptSplit(entry, ">")
            if fields.count > 1, fields[1] == "LEGACY" { legacy = true }
            if javaScriptParseInt(fields[0]) > 0 { count += 1 }
        }
        return !legacy && count < sdnMaximum
    }
}

// MARK: - Final submit

extension QISWizard {
    /// apply.submitQIS (1354–1492) without WISP and the repeater copies: the PPPoE check, the wait for the firmware check,
    /// then updateChanges.
    mutating func submitQIS(_ c: RouterClient) async throws {
        let link = try await isConnected(c)
        let pppFail = try await isPppAuthFail(c)
        if isSupport("FRONTHAUL_NETWORK"), sys.wirelessBand == 3, post.has("smart_connect_x") {
            let current = try await nvram("smart_connect_x", c)
            if current != "1", javaScriptLooselyEqual(post["smart_connect_x"], .string("1")) {
                let dwb = try await nvramGet(["dwb_mode", "dwb_band"], c)
                if dwb["dwb_mode"] == "1", let band = dwb["dwb_band"], !band.isEmpty { post.set("wl\(band)_closed", "1") }
            }
        }
        if pppFail {
            hints[.pppoePassword] = QISText.pppFail
            loadPage(.account, reverse: true)
            return
        }
        if let live = liveUpdate.actor {
            // Throws QISFirmwareCheckStopped (nothing is submitted) while the check is stopped.
            let status = try await live.waitForSubmit(link: link, fupgrade: isSupport("fupgrade"))
            sys.isNewFw = status.isNewFw; sys.newFwVersion = status.newFwVersion; sys.forceLevel = status.forceLevel
            sys.websStateUpdate = status.websStateUpdate
        }
        try await updateChanges(c)
    }
    /// updateChanges (1355–1412).
    mutating func updateChanges(_ c: RouterClient) async throws {
        let update = !javaScriptLooselyEqual(sys.isNewFw, .number("0"))
        _ = try await nvram("SG_mode", force: true, c)
        if post.has("http_username") || post.has("http_passwd") {
            send(.chpass(try chpassFields()), ignoresAnswer: true)
        }
        if !sys.isDefault, isSupport("mtlancfg"), sys.opMode != sys.originOpMode {
            var names = ["vlan_rl", "subnet_rl", "radius_list", "sdn_access_rl"]
            if !isSupport("mainfhSetup") { names.insert("sdn_rl", at: 0) }
            for name in names {
                let value = try await nvramDefaultGet([name], c)[name] ?? ""
                post.set(name, javaScriptReplace(javaScriptReplace(value, "&#60", "<", all: true), "&#62", ">", all: true))
            }
        }
        if isSupport("mainfhSetup") { try await configApmVariables(c) }
        if update {
            post.set("action_mode", "apply"); post.set("rc_service", "")
            send(.apply(post.sent), ignoresAnswer: false)
            then = .update
        } else {
            try await setRestartService(onPost: true, c)
            send(.apply(post.sent), ignoresAnswer: false)
            then = .finish
        }
    }
    /// httpApi.chpass's data (2306–2332): restart_httpd, new_username and new_passwd in btoa when not empty, defpass_enable.
    func chpassFields() throws -> [(String, String)] {
        func btoa(_ text: String) throws -> String {
            guard text.unicodeScalars.allSatisfy({ $0.value <= 0xFF }) else {
                throw RouterError.validation("管理员名称或密码含有 btoa 不接受的字符（InvalidCharacterError），网页在这里停止，不会提交。")
            }
            return Data(text.unicodeScalars.map { UInt8($0.value) }).base64EncodedString()
        }
        func field(_ name: String) -> String { post[name].map(TORSettings.javaScriptString) ?? "" }
        let user = field("http_username"), password = field("http_passwd")
        return [("restart_httpd", "0"), ("new_username", user.isEmpty ? user : try btoa(user)),
                ("new_passwd", password.isEmpty ? password : try btoa(password)), ("defpass_enable", field("defpass_enable"))]
    }

    /// setRestartService (plugins.js 1887–1896) on qisPostData itself (submitQIS) or on a new object (abort.update):
    /// action_mode first, then getRestartService, which reads qisPostData and may delete from it.
    @discardableResult
    mutating func setRestartService(onPost: Bool, _ c: RouterClient) async throws -> QISPostData {
        var data = onPost ? post : QISPostData()
        data.set("action_mode", "apply")
        if onPost { post = data }
        let service = try await restartService(c)
        if onPost { data = post }
        data.set("rc_service", service)
        if sys.isDefault { data.set("cfg_pause", "3") }
        if onPost { post = data }
        return data
    }
    /// getRestartService (1770–1885).
    mutating func restartService(_ c: RouterClient) async throws -> String {
        let wantag = try await nvram("switch_wantag", c)
        let changeSku = try await nvram("webs_chg_sku", force: true, c) == "1"
        _ = try await nvram("webs_SG_mode", force: true, c)
        if isSwModeChanged(), isSwMode("RT") { return "restart_all" }
        if isSupport("2p5G_LWAN") || isSupport("10G_LWAN") || isSupport("10GS_LWAN") || isSupport("autowan") || ethWanCount > 1 {
            if isWANLANChange() { return "reboot" }
        }
        if (post.has("switch_wantag") && post.text("switch_wantag") != wantag) || post.has("wlc_ssid") || post.has("lan_proto")
            || post.has("wans_dualwan") || post.has("wans_mode") || isSwModeChanged() {
            return "reboot"
        }
        if changeSku { return "reboot" }
        if isSupport("mlo"), post.has("mld_enable"), isSupport("bcmwifi"), try await nvram("wl_mlo_config", c) == "" { return "reboot" }
        var script: [String] = []
        if sys.ipConflict { script.append("restart_subnet") }
        if post.has("wans_mt_ioport") { script.append("restart_mtwan_profile") }
        if post.has("time_zone") { script.append("restart_time") }
        if post.has("yadns_enable_x") { script.append("restart_yadns") }
        var wireless = post.has("wl0_ssid") || post.has("wl0.1_ssid") || post.has("wl0_11ax") || sys.isDefault
        if !wireless { wireless = try await isSmartConnectChanged(c) }
        if wireless { script.append("restart_wireless") }
        if sys.isDefault, isSupport("lantiq") { script.append("stop_bluetooth_service") }
        if post.has("cfg_master") { script.append("restart_cfgsync") }
        if !sys.restartWanIf, isWANChanged() {
            sys.restartWanIf = true
            script.append("restart_wan_if \(sys.ethWanIf)")
        }
        if !sys.restartWanIf, post.has("wrs_protect_enable") { script += ["restart_firewall", "restart_wrs"] }
        if post.has("sdn_rl") { for name in ["restart_wireless", "restart_sdn"] where !script.contains(name) { script.append(name) } }
        if post.has("sdn_rc_service") {
            for name in javaScriptSplit(post.text("sdn_rc_service"), ";") where !script.contains(name) { script.append(name) }
            post.remove("sdn_rc_service")
        }
        if script.contains("restart_subnet") { script.removeAll { ["restart_wireless", "restart_cfgsync", "restart_sdn"].contains($0) } }
        return script.joined(separator: ";")
    }
    /// isSmartConnectChanged (2176–2186).
    mutating func isSmartConnectChanged(_ c: RouterClient) async throws -> Bool {
        guard isSupport("SMARTCONNECT"), post.has("smart_connect_x") else { return false }
        return !javaScriptLooselyEqual(post["smart_connect_x"], .string(try await nvram("smart_connect_x", c)))
    }

    /// configApmVariables (plugins.js 2985–3070): the MAINFH networks rebuilt from the wireless inputs, the MAINBH added when
    /// missing, and the wl keys removed.
    mutating func configApmVariables(_ c: RouterClient) async throws {
        if !post.has("sdn_rl") { post.set("sdn_rl", try await baseSDNRL(c)) }
        post.set("sdn_rl", javaScriptSplit(post.text("sdn_rl"), "<").filter { !javaScriptContains($0, "MAINFH") }.joined(separator: "<"))
        for (name, _) in post.members where name.hasPrefix("apm") { post.remove(name) }
        _ = try await nvram("et0macaddr", c)
        let backhauls = javaScriptSplit(post.text("sdn_rl"), "<").filter { javaScriptContains($0, "MAINBH") }
        let backhaulIndex: OrderedJSON = backhauls.first.map { entry in
            let fields = javaScriptSplit(entry, ">"); return fields.count > 5 ? .string(fields[5]) : .null
        } ?? .number("1")
        let bh = backhaulIndex.text ?? "undefined"
        if backhauls.isEmpty {
            let name = String(try calcMD5(post.text("wl0_ssid")) + "N").prefix(32)
            let key = String(try calcMD5(post.text("wl0_wpa_psk")) + "K").prefix(32)
            post.set("sdn_rl", post.text("sdn_rl") + "<\(nextSDNIndex(post.text("sdn_rl")))>MAINBH>1>0>0>\(bh)>0>0>0>0>0>0>0>0>0>0>0>0>0>WEB>0>0")
            let members: [(String, OrderedJSON)] = [
                ("11be", .number("1")), ("ap_isolate", .number("0")), ("dut_list", .string("<*>127>")), ("enable", .number("1")),
                ("hide_ssid", .number("1")), ("macmode", .number("0")), ("mlo", .number("1")),
                ("security", .string("<3>psk2sae>aes+gcmp256>\(key)>0<13>psk2sae>aes+gcmp256>\(key)>0<16>sae>aes+gcmp256>\(key)>0<96>sae>aes+gcmp256>\(key)>0")),
                ("ssid", .string(String(name))), ("timesched", .number("0"))]
            for (suffix, value) in members { post.set("apm\(bh)_\(suffix)", value) }
        }
        let amasBundle = isSupport("amas_bdl")
        let mapping: [(all: Int, enable: Int)] = [(1 + 4 + 8 + 16, amasBundle ? 1 + 4 + 16 : 1 + 4 + 8 + 16), (1 + 2 + 32 + 64, amasBundle ? 1 + 2 + 32 : 1 + 2 + 32 + 64),
                                                 (1 + 2 + 16, 1 + 2 + 16), (1 + 4 + 8, amasBundle ? 1 + 4 : 1 + 4 + 8), (1 + 2, 1 + 2)]
        var apmIndex = 1
        let inputs = form.wireless ?? []
        for band in 0..<sys.wirelessBand {
            guard let input = inputs.first(where: { $0.unit == String(band) }) else { continue }
            let dutBand = inputs.count == 1 ? "all" : (self.band(ofUnit: band) ?? "undefined")
            var dutList = ""
            switch dutBand {
            case "2g1": dutList = Self.mainfhDutList(1)
            case "5g": dutList = Self.mainfhDutList(2)
            case "5g1": dutList = Self.mainfhDutList(wlUnit("5g2") == "" ? 2 : 4)
            case "5g2": dutList = Self.mainfhDutList(8)
            case "6g": dutList = Self.mainfhDutList(16)
            case "6g1": dutList = Self.mainfhDutList(wlUnit("6g2") == "" ? 16 : 32)
            case "6g2": dutList = Self.mainfhDutList(64)
            case "all":
                let all = dutBandCount
                dutList = Self.mainfhDutList(mapping.first { $0.all == all }?.enable ?? all)
            default: break
            }
            if javaScriptLooselyEqual(.number(String(apmIndex)), backhaulIndex) { apmIndex += 1 }
            post.set("sdn_rl", post.text("sdn_rl") + "<\(nextSDNIndex(post.text("sdn_rl")))>MAINFH>1>0>0>\(apmIndex)>0>0>0>0>0>0>0>0>0>0>0>0>0>WEB>0>0")
            let members: [(String, OrderedJSON)] = [
                ("11be", .number("1")), ("ap_isolate", .number("0")), ("dut_list", .string(dutList)), ("enable", .number("1")),
                ("hide_ssid", .number("0")), ("macmode", .number("0")), ("mlo", .number("0")),
                ("security", .string("<3>psk2sae>aes>\(input.key)>0<13>psk2sae>aes>\(input.key)>0<16>sae>aes>\(input.key)>0<96>sae>aes>\(input.key)>0")),
                ("ssid", .string(input.ssid)), ("timesched", .number("0"))]
            for (suffix, value) in members { post.set("apm\(apmIndex)_\(suffix)", value) }
            apmIndex += 1
        }
        for (name, _) in post.members where name.hasPrefix("wl") && !name.hasPrefix("wlc") { post.remove(name) }
    }
    /// getDutBand (plugins.js 2804–2814).
    var dutBandCount: Int {
        var count = 0
        if wlUnit("2G") != "" { count += 1 }
        if wlUnit("5G") != "", wlUnit("5G2") == "" { count += 2 }
        if wlUnit("5G1") != "", wlUnit("5G2") != "" { count += 4 }
        if wlUnit("5G2") != "" { count += 8 }
        if wlUnit("6G") != "", wlUnit("6G2") == "" { count += 16 }
        if wlUnit("6G1") != "", wlUnit("6G2") != "" { count += 32 }
        if wlUnit("6G2") != "" { count += 64 }
        return count
    }
    /// get_mainfh_dut_list(bitwise, 0) (plugins.js 2917–2953), without MLO.
    static func mainfhDutList(_ bitwise: Int) -> String {
        var band = 0
        for bit in [1, 2, 4, 8, 16, 32, 64] where bitwise & bit != 0 { band += bit }
        if bitwise & 4 != 0, bitwise & 2 == 0 { band += 2 }
        if bitwise & 64 != 0, bitwise & 16 == 0 { band += 16 }
        if bitwise & 2 != 0, band & 4 == 0 { band += 4 }
        if bitwise & 16 != 0, band & 64 == 0 { band += 64 }
        if bitwise & 8 != 0, bitwise > 8, band & 2 == 0 { band += 2 }
        if bitwise & 32 != 0, bitwise > 32, band & 16 == 0 { band += 16 }
        return "<*>\(band)>"
    }
    /// findNextSdnIndex (2955–2983) for a list in hand.
    func nextSDNIndex(_ rules: String) -> String {
        var free = sdnMaximum >= 1 ? Array(1...sdnMaximum) : []
        for entry in javaScriptSplit(rules, "<") where !entry.isEmpty {
            let index = javaScriptSplit(entry, ">")[0]
            free.removeAll { javaScriptLooselyEqual(.number(String($0)), .string(index)) }
        }
        return free.first.map(String.init) ?? "undefined"
    }
    /// calcMD5 (md5.js, not in the materials). For ASCII text the usual MD5 hex; other text is not reproduced.
    func calcMD5(_ text: String) throws -> String {
        guard text.unicodeScalars.allSatisfy(\.isASCII) else {
            throw RouterError.validation("网页在这里用 md5.js 的 calcMD5 为主无线名称生成回程网络名称；资料中没有 md5.js，非 ASCII 名称无法照算。请在浏览器中完成向导。")
        }
        return Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// goTo.Update (4524–4550) as Merlin leaves it: the upgrade button removed, the cancel button made 下一步; for a forced
    /// upgrade (isNewFw 2, level 1) there is no button at all.
    public var updateShowsNext: Bool { !(javaScriptLooselyEqual(sys.isNewFw, .number("2")) && javaScriptLooselyEqual(.string(sys.forceLevel), .number("1"))) }
    /// The two version boxes.
    public var updateVersions: (current: String, latest: String) {
        let latest = sys.newFwVersion.replacingOccurrences(of: #"^(\d+)_+(\d+)_+(\d+)(_+\d+)$"#, with: "$1.$2.$3$4", options: .regularExpression)
        let values = http.nvram.values
        let current = javaScriptReplace(values["firmver"] ?? "", ".", "", all: true) + "." + (values["buildno"] ?? "") + "_" + (values["extendno"] ?? "")
        return (current, latest)
    }
    /// What goTo.Update reads for the current version.
    mutating func goToUpdate(_ c: RouterClient) async throws {
        _ = try await nvramGet(["firmver"], c); _ = try await nvramGet(["buildno"], c); _ = try await nvramGet(["extendno"], c)
        loadPage(.update)
    }
}
