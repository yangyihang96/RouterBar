import Foundation
import Testing
@testable import RouterCore

// 1.10 read-only pages: 无线 › WPS, WDS, 漫游阻止列表, MLO and 网络工具 › Smart Connect 规则. Values follow the shapes the
// Asuswrt-Merlin 3006.102.5 pages read, with made-up contents: invented MACs, an example network name and key, and a
// checksum-valid example PIN.

private let macA = "AA:BB:CC:DD:EE:01", macB = "AA:BB:CC:DD:EE:02"

// MARK: Bands and JavaScript numbers

@Test func bandsAreNamedAndNumberedLikeTheWeb() {
    let dual = WirelessBands(list: "2g1<5g1")
    #expect(dual.bands.map(\.title) == ["2.4 GHz", "5 GHz"])
    #expect(dual.unit(of: "5G") == 1 && dual.unit(of: "5G1") == 1 && dual.unit(of: "5G2") == nil && dual.unit(of: "2g1") == 0)
    let quad = WirelessBands(list: "2g1<5g1<5g2<6g1")
    #expect(quad.bands.map(\.title) == ["2.4 GHz", "5 GHz-1", "5 GHz-2", "6 GHz"])
    #expect(quad.twoFiveGHz && quad.sixGHz)
    let twoSix = WirelessBands(list: "2g1<5g1<6g1<6g2")
    #expect(twoSix.bands.map(\.title) == ["2.4 GHz", "5 GHz", "6 GHz-1", "6 GHz-2"])
    #expect(twoSix.unit(of: "6G") == 2 && twoSix.unit(of: "6G2") == 3)
    // A unit is the entry's position, so an empty entry still counts; the web lists bands by kind, not by unit.
    let odd = WirelessBands(list: "5g1<<2g1")
    #expect(odd.bands.map(\.unit) == [0, 2] && odd.unit(of: "2G") == 2)
    #expect(odd.listed.map(\.code) == ["2g1", "5g1"])
    #expect(WirelessBands(list: "").bands.isEmpty)
}

@Test func numbersAreReadAsThePagesReadThem() {
    #expect(javaScriptInteger("0x1C", radix: 16) == 28 && javaScriptInteger("1c", radix: 16) == 28)
    #expect(javaScriptInteger("12 dBm") == 12 && javaScriptInteger(" -52") == -52 && javaScriptInteger("0x1f") == 31)
    #expect(javaScriptInteger("") == nil && javaScriptInteger("x1") == nil && javaScriptInteger("-", radix: 16) == nil)
    // ECMAScript's white space (U+FEFF, U+3000 and U+2028 but not U+0085); a combining mark ends the number.
    #expect(javaScriptInteger("\u{FEFF}7") == 7 && javaScriptInteger("\u{3000}\u{2028}-7") == -7 && javaScriptInteger("\u{85}7") == nil)
    #expect(javaScriptInteger("1\u{0301}2") == 1 && javaScriptInteger("0X1f") == 31 && javaScriptInteger("0x1f", radix: 10) == 0)
    #expect(javaScriptEquals(" 1", 1) && javaScriptEquals("", 0) && javaScriptEquals("1.0", 1))
    #expect(!javaScriptEquals(nil, 0) && !javaScriptEquals("x", 0) && !javaScriptEquals("2", 1))
}

// MARK: WPS

/// WPS_info.xml with 13 items: the ones the page shows ([0] state, [1] configured, [7] PIN, [11] auth, [12] band) and others
/// that hold the network name and key.
private func wpsItems(_ tag: String, state: String = "Idle", configured: String = "Yes", pin: String = "12345670", auth: String = "psk2", band: String = "1") -> String {
    let items = [state, configured, "ExampleNet", "WPA2-Personal", "AES", "example-key", "1", pin, "0", "0", "0", auth, band]
    return items.map { "<\(tag)>\($0)</\(tag)>" }.joined(separator: "\n")
}
private func wpsXML(_ body: String) -> String { "\u{FEFF}<?xml version=\"1.0\" ?>\n<wps>\n\(body)\n</wps>\n" }

@Test func wpsInfoKeepsOnlyWhatThePageShows() throws {
    let info = try WPSInfo(xml: wpsXML(wpsItems("wps_info")))
    #expect(info.tags["wps_info"] == WPSInfo.Items(state: "Idle", configured: "Yes", pin: "12345670", authMode: "psk2", band: "1"))
    #expect(!String(describing: info).contains("ExampleNet") && !String(describing: info).contains("example-key"))
    // Two bands, an empty element (undefined on the page), entities and a missing <wps> element.
    let two = try WPSInfo(xml: wpsXML(wpsItems("wps_info0", band: "0") + "\n<wps_info1/>\n<wps_info1>&lt;Idle&gt; &amp; more</wps_info1>"))
    #expect(two.tags["wps_info0"]?.band == "0")
    #expect(two.tags["wps_info1"]?.state == nil && two.tags["wps_info1"]?.configured == "<Idle> & more")
    // RT-BE88U writes empty items as <wps_info></wps_info> (items 6 and 8 with WPS off); the later items keep their places.
    let gaps = ["Not used", "Yes", "ExampleNet", "WPA2-Personal", "AES", "k", "", "12345670", "", "0", "0", "psk2sae", "0"]
    let router = try WPSInfo(xml: wpsXML(gaps.map { "<wps_info>\($0)</wps_info>" }.joined(separator: "\n")))
    #expect(router.tags["wps_info"] == WPSInfo.Items(state: "Not used", configured: "Yes", pin: "12345670", authMode: "psk2sae", band: "0"))
    #expect(throws: RouterError.self) { try WPSInfo(xml: "<html>Main_Login.asp</html>") }
}

private func wpsConfiguration(_ values: [String: String] = [:], support: [String: String] = ["5G": "1"]) -> WPSConfiguration {
    let base = ["wps_enable": "1", "wps_band_x": "1", "wps_multiband": "", "wps_dualband": "0", "wl_closed": "0", "wlnband_list": "2g1<5g1",
                "wl0_radio": "1", "wl1_radio": "1", "wl_auth_mode_x": "psk2", "wl_wep_x": "0", "wl0_wep_x": "0", "wl1_wep_x": "0",
                "wl0_auth_mode_x": "psk2", "wl1_auth_mode_x": "psk2", "wl2_auth_mode_x": "", "wl3_auth_mode_x": ""]
    return WPSConfiguration(values: base.merging(values) { _, new in new }, support: support)
}

@Test func wpsStatusOfOneBand() throws {
    let info = try WPSInfo(xml: wpsXML(wpsItems("wps_info")))
    let on = WPSStatus(configuration: wpsConfiguration(), info: info)
    #expect(on.enabled && on.bands == [.init("5 GHz")] && on.notice == nil)
    #expect(on.state == "Idle" && on.configured == "已启用" && on.pin == "12345670" && !on.inProgress && !on.wpa3Unsupported && !on.hiddenSSID)
    #expect(wpsConfiguration().pollsStatus)
    // Off: 未启用, and the WPS 方法 row (with the WPA3 note) is hidden.
    let off = WPSStatus(configuration: wpsConfiguration(["wps_enable": "0", "wl0_auth_mode_x": "sae", "wps_band_x": "0"]),
                        info: try WPSInfo(xml: wpsXML(wpsItems("wps_info", configured: "No", band: "0"))))
    #expect(!off.enabled && off.state == "未启用" && off.configured == "未启用" && off.bands == [.init("2.4 GHz")] && !off.wpa3Unsupported)
    // On 2.4 GHz with WPA3 the note shows; a lone "5 GHz" has no band prefix on the page, so it never does.
    let wpa3 = WPSStatus(configuration: wpsConfiguration(["wl0_auth_mode_x": "sae", "wps_band_x": "0"]), info: try WPSInfo(xml: wpsXML(wpsItems("wps_info", band: "0"))))
    #expect(wpa3.wpa3Unsupported)
    #expect(!WPSStatus(configuration: wpsConfiguration(["wl1_auth_mode_x": "sae"]), info: info).wpa3Unsupported)
    let triBand = WPSStatus(configuration: wpsConfiguration(["wlnband_list": "2g1<5g1<5g2", "wl1_auth_mode_x": "sae"]), info: info)
    #expect(triBand.wpa3Unsupported && triBand.bands == [.init("5 GHz-1")])
    // A pairing in progress, a hidden network and a router that hides the PIN.
    let busy = WPSStatus(configuration: wpsConfiguration(["wl0_closed": "1"], support: ["5G": "1", "lyra_hide": "1"]),
                         info: try WPSInfo(xml: wpsXML(wpsItems("wps_info", state: "Start WPS Process"))))
    #expect(busy.inProgress && busy.hiddenSSID && busy.pin == nil && busy.state == "Start WPS Process")
    // Without 5 GHz the page hides 当前频率.
    #expect(WPSStatus(configuration: wpsConfiguration(support: [:]), info: info).bands == nil)
}

@Test func wpsNoticesHideTheRowsLikeThePage() throws {
    let info = try WPSInfo(xml: wpsXML(wpsItems("wps_info")))
    let radioOff = WPSStatus(configuration: wpsConfiguration(["wl1_radio": "0"]), info: info)
    #expect(radioOff.notice == .wifiOff([.init(title: "", unit: 1)]))
    #expect(radioOff.state == nil && radioOff.pin == nil && radioOff.configured == nil)
    // WPA-Personal (psk) is refused by WPS 2.0; the link goes to 一般设置 of the item's band.
    let rejected = WPSStatus(configuration: wpsConfiguration(), info: try WPSInfo(xml: wpsXML(wpsItems("wps_info", auth: "psk"))))
    #expect(rejected.notice == .authRejected([.init(title: "", unit: 1)]) && rejected.state == nil)
    #expect(!wpsConfiguration(["wl0_auth_mode_x": "psk"]).pollsStatus && !wpsConfiguration(["wl0_auth_mode_x": "open", "wl0_wep_x": "1"]).pollsStatus)
}

@Test func wpsUsesTheValuesOfTheBandThePageOpensOn() throws {
    // Opening the page copies wl<wl_unit>_ over the wl_ values (ej_wl_get_parameter), so old wl_ copies do not count.
    let info = try WPSInfo(xml: wpsXML(wpsItems("wps_info")))
    let stale = wpsConfiguration(["wl_unit": "1", "wl_subunit": "-1", "wl_closed": "1", "wl1_closed": "0", "wl_auth_mode_x": "psk", "wl1_auth_mode_x": "psk2"])
    #expect(stale.pollsStatus && !WPSStatus(configuration: stale, info: info).hiddenSSID)
    // wl_subunit above 0 picks the sub-interface; a wl_unit of -1 copies nothing, and empty values read as 0 like atoi.
    let sub = wpsConfiguration(["wl_unit": "0", "wl_subunit": "1", "wl0.1_closed": "1", "wl0.1_auth_mode_x": "psk", "wl0.1_wep_x": "0"])
    #expect(!sub.pollsStatus && WPSStatus(configuration: sub, info: info).hiddenSSID)
    #expect(WPSConfiguration.interfacePrefix(unit: "0", subunit: "2") == "wl0.2_" && WPSConfiguration.interfacePrefix(unit: "1", subunit: "0") == "wl1_")
    #expect(WPSConfiguration.interfacePrefix(unit: "", subunit: "") == "wl0_" && WPSConfiguration.interfacePrefix(unit: "-1", subunit: "1") == nil)
    let none = wpsConfiguration(["wl_unit": "-1", "wl_closed": "1", "wl0_closed": "0"])
    #expect(WPSStatus(configuration: none, info: info).hiddenSSID)
    // An empty band value leaves the wl_ one.
    #expect(WPSStatus(configuration: wpsConfiguration(["wl_unit": "0", "wl_closed": "1", "wl0_closed": ""]), info: info).hiddenSSID)
}

@Test func wpsFollowsThePagesModelBranches() throws {
    let five = try WPSInfo(xml: wpsXML(wpsItems("wps_info", band: "1")))
    // RT-AC87U and RT-AC87R keep initial()'s title and check the 2.4 GHz switch, whatever band the answer names.
    let ac87 = WPSStatus(configuration: wpsConfiguration(["productid": "RT-AC87U", "wps_band_x": "0", "wl1_radio": "0"]), info: five)
    #expect(ac87.bands == [.init("2.4 GHz")] && ac87.notice == nil && ac87.state == "Idle")
    let dual = WPSStatus(configuration: wpsConfiguration(["productid": "RT-AC87R", "wps_dualband": "1"]), info: five)
    #expect(dual.bands == [.init("2.4 GHz"), .init("5 GHz")])
    // Other models take the title from the answer and check that band's switch.
    let other = WPSStatus(configuration: wpsConfiguration(["wps_band_x": "0", "wl1_radio": "0"]), info: five)
    #expect(other.bands == [.init("5 GHz")] && other.notice == .wifiOff([.init(title: "", unit: 1)]))
    // RT-AC55U and RT-AC55UHP add the switched-off band to 连线状态.
    let ac55 = WPSStatus(configuration: wpsConfiguration(["productid": "RT-AC55U", "wps_band_x": "0", "wl0_radio": "0"]), info: five)
    #expect(ac55.state == "Idle (2.4G is disabled)")
    let both = try WPSInfo(xml: wpsXML(wpsItems("wps_info0", band: "0") + "\n" + wpsItems("wps_info1", band: "1")))
    let ac55Both = WPSStatus(configuration: wpsConfiguration(["productid": "RT-AC55UHP", "wps_multiband": "1", "wl1_radio": "0"], support: ["5G": "1", "wps_multiband": "1"]), info: both)
    #expect(ac55Both.state == "Idle / Idle (5G is disabled)")
}

@Test func wpsStatusOfBothBands() throws {
    let support = ["5G": "1", "wps_multiband": "1"]
    let xml = wpsXML(wpsItems("wps_info0", band: "0") + "\n" + wpsItems("wps_info1", configured: "No", band: "1"))
    let both = WPSStatus(configuration: wpsConfiguration(["wps_multiband": "1"], support: support), info: try WPSInfo(xml: xml))
    #expect(both.bands == [.init("2.4 GHz"), .init("5 GHz")] && both.notice == nil)
    #expect(both.state == "Idle / Idle" && both.configured == "Yes / No" && both.pin == "12345670")
    // One band's Wi-Fi off: the note names it and the rows stay; both off hides them.
    let one = WPSStatus(configuration: wpsConfiguration(["wps_multiband": "1", "wl0_radio": "0"], support: support), info: try WPSInfo(xml: xml))
    #expect(one.notice == .wifiOff([.init(title: "2.4 GHz", unit: 0)]) && one.state == "Idle / Idle")
    let none = WPSStatus(configuration: wpsConfiguration(["wps_multiband": "1", "wl0_radio": "0", "wl1_radio": "0"], support: support), info: try WPSInfo(xml: xml))
    #expect(none.state == nil && none.pin == nil)
    // While WPS is off the band names come from the answer, struck through where the band refuses WPS.
    let refused = wpsXML(wpsItems("wps_info0", auth: "psk", band: "0") + "\n" + wpsItems("wps_info1", band: "1"))
    let off = WPSStatus(configuration: wpsConfiguration(["wps_multiband": "1", "wps_enable": "0"], support: support), info: try WPSInfo(xml: refused))
    #expect(off.bands == [.init("2.4 GHz", struck: true), .init("5 GHz")] && off.notice == .authRejected([.init(title: "2.4 GHz", unit: 0)]))
    #expect(off.state == "未启用 / 未启用")
}

// MARK: Reading through the client

private actor WirelessRouter: RouterTransport {
    var nvram: [String: String]
    let support: [String: String]
    let clients: [String: Any]
    let wps: String
    /// JSON answers of other hooks by name, e.g. "get_cfg_clientlist"; "<cancelled>" stands for a request whose task was
    /// cancelled, "<expired>" for a login that has expired (401).
    let hooks: [String: String]
    private(set) var requests: [URLRequest] = []
    init(nvram: [String: String] = [:], support: [String: String] = [:], clients: [String: Any] = [:], wps: String = "", hooks: [String: String] = [:]) {
        self.nvram = nvram; self.support = support; self.clients = clients; self.wps = wps; self.hooks = hooks
    }
    func send(_ request: URLRequest) async throws -> RouterHTTPResponse {
        requests.append(request)
        guard let url = request.url, request.httpMethod == "GET" else { throw RouterError.network("Only reads are expected") }
        switch url.lastPathComponent {
        case "appGet.cgi":
            let hook = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "hook" }?.value ?? ""
            if hook == "get_ui_support()" { return try Self.reply(["get_ui_support": support]) }
            if hook == "get_clientlist()" { return try Self.reply(["get_clientlist": clients]) }
            if hook.hasSuffix("()"), let answer = hooks[String(hook.dropLast(2))] {
                if answer == "<cancelled>" { throw CancellationError() }
                if answer == "<expired>" { return RouterHTTPResponse(data: Data(), status: 401) }
                return RouterHTTPResponse(data: Data("{\"\(hook.dropLast(2))\":\(answer)}".utf8), status: 200)
            }
            var object: [String: String] = [:]
            for call in hook.split(separator: ";") {
                guard call.hasPrefix("nvram_char_to_ascii("), let open = call.firstIndex(of: "("), let comma = call.firstIndex(of: ",") else { continue }
                let key = String(call[call.index(after: open)..<comma]); object[key] = nvram[key] ?? ""
            }
            return try Self.reply(object)
        case "WPS_info.xml": return RouterHTTPResponse(data: Data(wps.utf8), status: 200)
        default: return RouterHTTPResponse(data: Data(), status: 404)
        }
    }
    nonisolated func cancel() {}
    var readKeys: Set<String> {
        Set(requests.compactMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "hook" }?.value }
            .flatMap { $0.split(separator: ";") }.compactMap { call in
                guard call.hasPrefix("nvram_char_to_ascii("), let open = call.firstIndex(of: "("), let comma = call.firstIndex(of: ",") else { return nil }
                return String(call[call.index(after: open)..<comma])
            })
    }
    var paths: [String] { requests.compactMap { $0.url?.lastPathComponent } }
    static func reply(_ object: Any) throws -> RouterHTTPResponse { RouterHTTPResponse(data: try JSONSerialization.data(withJSONObject: object), status: 200) }
}
private func client(_ router: WirelessRouter) throws -> RouterClient { RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: router, writes: .reference) }

@Test func wpsReadsItsSettingsAndTheStatusPage() async throws {
    let router = WirelessRouter(nvram: ["wps_enable": "1", "wps_band_x": "0", "wlnband_list": "2g1<5g1", "wl0_radio": "1", "wl1_radio": "1", "wl0_wep_x": "0",
                                        "wl0_auth_mode_x": "psk2", "wl_auth_mode_x": "psk2", "wl_wep_x": "0"],
                                support: ["5G": "1"], wps: wpsXML(wpsItems("wps_info", band: "0")))
    let reader = try client(router)
    let status = WPSStatus(configuration: try await reader.wpsConfiguration(), info: try await reader.wpsInfo())
    #expect(status.bands == [.init("2.4 GHz")] && status.state == "Idle")
    let requests = await router.requests
    #expect(requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil })
    #expect(Set(await router.paths) == ["appGet.cgi", "WPS_info.xml"])
    // wl_unit and wl_subunit first, then that band's values.
    let band = WirelessRouter(nvram: ["wps_enable": "1", "wps_band_x": "0", "wl_unit": "1", "wl_subunit": "-1", "wl_closed": "0", "wl1_closed": "1"],
                              support: ["5G": "1"], wps: wpsXML(wpsItems("wps_info", band: "0")))
    let read = try await client(band).wpsConfiguration()
    #expect(WPSStatus(configuration: read, info: try await client(band).wpsInfo()).hiddenSSID)
    #expect(await band.readKeys.isSuperset(of: ["wl_unit", "wl_subunit", "wl1_closed", "wl1_auth_mode_x", "wl1_wep_x"]))
}

// MARK: WDS

private let wdsValues = ["wlnband_list": "2g1<5g1", "sw_mode": "1", "wlc_band": "", "wl_unit": "1", "wl0_hwaddr": macA, "wl1_hwaddr": macB,
                         "wl0_mode_x": "0", "wl0_wdsapply_x": "1", "wl0_wdslist": "", "wl0_bw": "1", "wl0_chanspec": "6", "wl0_channel": "0",
                         "wl1_mode_x": "2", "wl1_wdsapply_x": "1", "wl1_wdslist": "<\(macA)<\(macB)", "wl1_bw": "0", "wl1_chanspec": "0", "wl1_channel": "36"]

@Test func wdsShowsEachBandWithoutChoosingIt() {
    let wds = WDSSettings(values: wdsValues, support: ["5G": "1", "wl6": "1"])
    #expect(wds.macs.map(\.title) == ["2.4 GHz MAC", "5 GHz MAC"] && wds.macs.map(\.mac) == [macA, macB])
    #expect(wds.showsBand && wds.currentUnit == 1 && wds.radios.map(\.band.title) == ["2.4 GHz", "5 GHz"])
    let two = wds.radios[0], five = wds.radios[1]
    // AP Only fixes 连接列表中的访问点 to 否, whatever is stored.
    #expect(two.modeTitle == "AP Only" && two.connectListedTitle == "否" && two.connectListedFixed && two.remoteAPs.isEmpty)
    #expect(five.modeTitle == "Hybrid" && five.connectListedTitle == "是" && !five.connectListedFixed && five.remoteAPs == [macA, macB])
    // wl6 routers say 自动 with bw 0 and chanspec 0; others with bw 1 and channel 0.
    #expect(!two.autoBandwidth && !two.autoChannel && five.autoBandwidth && five.autoChannel)
    let older = WDSSettings(values: wdsValues, support: ["5G": "1"])
    #expect(older.radios[0].autoBandwidth && older.radios[0].autoChannel && !older.radios[1].autoBandwidth && !older.radios[1].autoChannel)
    #expect(!wds.radios.contains { $0.unavailable })
    #expect(WDSSettings(values: wdsValues.merging(["wl1_mode_x": "7"]) { _, new in new }, support: [:]).radios[1].modeTitle == "未识别的值 7")
}

@Test func wdsFollowsThePagesSpecialCases() {
    // A second 5 GHz band or a 6 GHz band adds a third MAC row and renames the second (initial 115–123).
    let tri = WDSSettings(values: wdsValues.merging(["wlnband_list": "2g1<5g1<5g2", "wl2_hwaddr": "AA:BB:CC:DD:EE:03"]) { _, new in new }, support: ["5G": "1"])
    #expect(tri.macs.map(\.title) == ["2.4 GHz MAC", "5 GHz-1 MAC", "5 GHz-2 MAC"] && tri.radios.count == 3)
    let six = WDSSettings(values: wdsValues.merging(["wlnband_list": "2g1<5g1<6g1"]) { _, new in new }, support: ["5G": "1"])
    #expect(six.macs.map(\.title) == ["2.4 GHz MAC", "5 GHz-1 MAC", "6 GHz MAC"])
    // As a repeater the band that connects upstream has no settings here; without 5 GHz there is no 频段 row.
    let repeater = WDSSettings(values: wdsValues.merging(["sw_mode": "2", "wlc_band": "1"]) { _, new in new }, support: ["5G": "1"])
    #expect(repeater.radios.map(\.unavailable) == [false, true])
    let single = WDSSettings(values: wdsValues.merging(["wlnband_list": "2g1"]) { _, new in new }, support: [:])
    #expect(!single.showsBand && single.macs.count == 1 && single.radios.count == 1)
    // Ralink routers fix the choice to 是 in WDS Only.
    #expect(WDSSettings(values: wdsValues.merging(["wl1_mode_x": "1", "wl1_wdsapply_x": "0"]) { _, new in new }, support: ["rawifi": "1"]).radios[1].connectListedTitle == "是")
}

@Test func wdsFollowsTheOperationModeAndModelBranches() {
    // state.js counts AP mode with wlc_psta 2 as a repeater and wlc_psta 1 or 3 as a media bridge (254–265).
    for (mode, psta, upstream) in [("3", "2", true), ("3", "1", true), ("3", "3", true), ("2", "1", true), ("4", "", true), ("3", "0", false), ("1", "1", false)] {
        let wds = WDSSettings(values: wdsValues.merging(["sw_mode": mode, "wlc_psta": psta, "wlc_band": "1"]) { _, new in new }, support: ["5G": "1"])
        #expect(wds.radios.map(\.unavailable) == [false, upstream], "sw_mode \(mode), wlc_psta \(psta)")
    }
    #expect(WDSSettings.switchMode("3", psta: "2") == "2" && WDSSettings.switchMode("2", psta: " 1") == "4" && WDSSettings.switchMode("1", psta: "") == "1")
    // Lantiq routers offer only Hybrid; RT-AC87U uses Hybrid on its second band and hides AP 模式 there.
    let lantiq = WDSSettings(values: wdsValues, support: ["5G": "1", "lantiq": "1"])
    #expect(lantiq.radios.map(\.modeTitle) == ["Hybrid", "Hybrid"] && lantiq.radios[0].connectListedTitle == "是" && lantiq.radios.allSatisfy(\.showsMode))
    let ac87 = WDSSettings(values: wdsValues.merging(["productid": "RT-AC87U"]) { _, new in new }, support: ["5G": "1"])
    #expect(ac87.radios.map(\.modeTitle) == ["AP Only", "Hybrid"] && ac87.radios.map(\.showsMode) == [true, false])
}

@Test func wdsReadsOnlyItsVariablesAndNeverScans() async throws {
    let router = WirelessRouter(nvram: wdsValues, support: ["5G": "1", "wl6": "1"])
    let wds = try await client(router).wdsSettings()
    #expect(wds.radios.count == 2)
    let keys = await router.readKeys
    #expect(keys.contains("wl1_chanspec") && !keys.contains("wl1_channel") && !keys.contains("wl2_hwaddr"))
    #expect(keys.isSuperset(of: ["sw_mode", "wlc_psta", "wlc_band", "productid"]))
    #expect(await router.paths.allSatisfy { $0 == "appGet.cgi" })
}

// MARK: 漫游阻止列表

@Test func roamingListKeepsEachDeviceOnce() async throws {
    let list = RoamingBlockList(values: ["rast_static_cli_enable": "1", "wl0_rast_static_client": "<aa:bb:cc:dd:ee:01<\(macB)<aa:bb:cc:dd:ee:01"])
    #expect(list.enabled && list.enableTitle == "是" && list.macs == [macA, macB])
    #expect(RoamingBlockList(values: ["rast_static_cli_enable": "0", "wl0_rast_static_client": ""]).macs.isEmpty)
    #expect(RoamingBlockList(values: ["rast_static_cli_enable": "x"]).enableTitle == "未选择")
    let router = WirelessRouter(nvram: ["rast_static_cli_enable": "0", "wl0_rast_static_client": "<\(macA)"])
    let read = try await client(router).roamingBlockList()
    #expect(!read.enabled && read.enableTitle == "否" && read.macs == [macA])
    #expect(await router.readKeys == ["rast_static_cli_enable", "wl0_rast_static_client"])
}

// MARK: Smart Connect 规则

private let smartValues = [
    "wlnband_list": "2g1<5g1", "smart_connect_selif_x": "3", "bsd_bounce_detect": "180 2 3600",
    // [6] 0x42: load balance (bit 6) and RSSI 大于 (bit 1). 0x0 leaves RSSI blank.
    "wl0_bsd_steering_policy": "80 5 3 -52 0 110 0x42", "wl1_bsd_steering_policy": "70 5 3 -82 1000 0 0x0",
    // [10] 0x8002: 802.11ax only (bit 15) and 大于; 0x4000: 802.11a/b/g/n/ac (bit 14).
    "wl0_bsd_sta_select_policy": "10 -52 0 110 0 0 1 0 0 0 0x8002", "wl1_bsd_sta_select_policy": "10 -82 0 0 0 0 1 0 0 0 0x4000",
    "wl0_bsd_if_select_policy": "wl1", "wl1_bsd_if_select_policy": "wl2",
    // [1] 0x4: 802.11ac/ax only (bit 2); 0x400: 802.11a/b/g/n/ac (bit 10).
    "wl0_bsd_if_qualify_policy": "0 0x4", "wl1_bsd_if_qualify_policy": "60 0x400"
]

@Test func smartConnectColumnsShowWhatThePageFillsIn() {
    let rules = SmartConnectRules(values: smartValues, smartConnectV2: true, subunit: nil)
    #expect(rules.columns.map(\.band.title) == ["2.4 GHz", "5 GHz"] && rules.columns.allSatisfy(\.active))
    let two = rules.columns[0], five = rules.columns[1]
    #expect(two.loadBalance && two.steeringRSSIGreater == true && two.steeringCapability == .all)
    #expect(!five.loadBalance && five.steeringRSSIGreater == nil)
    #expect(SmartConnectRules.Column.field(two.steering, 3) == "-52" && SmartConnectRules.Column.field(two.steering, 9) == "undefined")
    #expect(two.stationRSSIGreater == true && two.stationCapability == .ax && five.stationRSSIGreater == false && five.stationCapability == .abgnac)
    #expect(two.qualifyCapability == .acAx && five.qualifyCapability == .abgnac)
    // The first 目标频段 choice shows its first entry when the stored interface is not offered.
    #expect(two.targets == ["5 GHz"] && five.targets == ["2.4 GHz"])
    #expect(rules.bounceDetect == ["180", "2", "3600"])
    // Without smart_connect_v2, or without a band's bit, the column shows "- -".
    #expect(SmartConnectRules(values: smartValues, smartConnectV2: false, subunit: nil).columns.allSatisfy { !$0.active })
    let onlyTwo = SmartConnectRules(values: smartValues.merging(["smart_connect_selif_x": "1"]) { _, new in new }, smartConnectV2: true, subunit: nil)
    #expect(onlyTwo.columns.map(\.active) == [true, false] && onlyTwo.columns[0].targets == [""])
}

@Test func smartConnectTargetsAndTheStationQuirk() {
    let tri = smartValues.merging(["wlnband_list": "2g1<5g1<5g2", "smart_connect_selif_x": "7", "wl0_bsd_if_select_policy": "wl2 wl1",
                                   "wl1_bsd_if_select_policy": "wl2", "wl2_bsd_if_select_policy": "", "wl2_bsd_steering_policy": "",
                                   "wl2_bsd_sta_select_policy": "", "wl2_bsd_if_qualify_policy": ""]) { _, new in new }
    let rules = SmartConnectRules(values: tri, smartConnectV2: true, subunit: nil)
    #expect(rules.columns.map(\.band.title) == ["2.4 GHz", "5 GHz-1", "5 GHz-2"])
    #expect(rules.columns[0].targets == ["5 GHz-2", "5 GHz-1"] && rules.columns[1].targets == ["5 GHz-2", "none"])
    #expect(rules.columns[2].targets == ["2.4 GHz", "none"])
    // genStaCapability reads the station flags of the column numbered like the band's wl unit: with the units out of the
    // web's order, 2.4 GHz shows the 5 GHz band's choice.
    let swapped = SmartConnectRules(values: smartValues.merging(["wlnband_list": "5g1<2g1"]) { _, new in new }, smartConnectV2: true, subunit: nil)
    #expect(swapped.columns.map(\.band.title) == ["2.4 GHz", "5 GHz"])
    #expect(swapped.columns[0].stationCapability == .ax && swapped.columns[1].stationCapability == .abgnac)
    #expect(swapped.columns[0].station[1] == "-82")
}

@Test func smartConnectReadsTheMainNetworksSubinterface() async throws {
    #expect(SmartConnectSubunit.mainFronthaul(sdnRL: "<0>DEFAULT>1>0>0>0<3>MAINFH>1>0>2>2", apWifiRL: "<wl0.2>1<wl0.1>3") == "1")
    #expect(SmartConnectSubunit.mainFronthaul(sdnRL: "<3>MAINFH>1", apWifiRL: "<wl0.x>3") == "1")
    var nvram = smartValues.merging(["sdn_rl": "<0>DEFAULT>1>0>0>0<3>MAINFH>1>0>2>2", "ap_wifi_rl": "<wl0.2>3<wl1.2>3"]) { _, new in new }
    nvram["wl0.2_bsd_sta_select_policy"] = "10 -60 0 0 0 0 1 0 0 0 0x0"; nvram["wl1.2_bsd_sta_select_policy"] = "10 -70 0 0 0 0 1 0 0 0 0x0"
    nvram["wl0.2_bsd_if_select_policy"] = "wl1.2"; nvram["wl1.2_bsd_if_select_policy"] = "wl0.2"
    let router = WirelessRouter(nvram: nvram, support: ["sdn_mainfh": "1", "smart_connect_v2": "1"])
    let rules = try await client(router).smartConnectRules()
    #expect(rules.columns.map { $0.station[1] } == ["-60", "-70"] && rules.columns[0].targets == ["5 GHz"])
    let keys = await router.readKeys
    #expect(keys.contains("wl0.2_bsd_sta_select_policy") && !keys.contains("wl0_bsd_sta_select_policy") && keys.contains("wl0_bsd_steering_policy"))
}

// MARK: MLO

private let mloRules = "<0>DEFAULT>1>0>0>0<1>MLO>1>0>0>4<2>MLO>0>0>0>5<3>MAINFH>1>0>2>2<4>MLO>1>0>0>6<5>Guest>1>0>0>7"

@Test func mloListsBackhaulFirstLikeThePage() {
    let values = ["mld_enable": "1", "mlo_bh_band": "", "wlnband_list": "2g1<5g1", "sdn_rl": mloRules,
                  "apg4_ssid": "Example-BH-1", "apg4_mlo": "1", "apg5_ssid": "Example-MLO", "apg5_mlo": "2", "apg5_disabled": "1",
                  "apg6_ssid": "Example-BH-2", "apg6_mlo": "1"]
    let mlo = MLOOverview(values: values, support: ["mlo": "1"], online: ["1": 2, "2": 1])
    #expect(mlo.enabled && mlo.backhaulBands == nil && mlo.showsWirelessSettings)
    // Backhaul networks are put in front one by one, so the last one comes first; MAINFH and Guest rows are not MLO.
    #expect(mlo.networks.map(\.id) == ["4", "1", "2"])
    #expect(mlo.networks.map(\.backhaul) == [true, true, false] && mlo.networks.map(\.onlineDevices) == [0, 2, 1])
    #expect(mlo.networks[2].needsReconfiguring && !mlo.networks[2].enabled && mlo.networks[1].enabled && !mlo.networks[1].needsReconfiguring)
    #expect(!MLOOverview(values: values, support: ["sdn_mwl": "1"], online: [:]).showsWirelessSettings)
    #expect(MLOOverview(values: ["sdn_rl": "garbled"], support: [:], online: [:]).networks.isEmpty)
    // Each row is read on its own: a short row, or one without an apg index above 0, leaves out only itself.
    let broken = MLOOverview(values: ["sdn_rl": "<0>DEFAULT<1>MLO>1<2>MLO>1>0>0>x<5>MLO>1>0>0>0<3>MLO>1>0>0>5", "apg5_mlo": "2", "apg0_mlo": "2"], support: [:], online: [:])
    #expect(broken.networks.map(\.id) == ["3"])
}

@Test func mloNetworksShowThePagesIconsAndTags() {
    let values = ["sdn_rl": "<1>MLO>1>2>0>4>1>0<2>MLO>1>0>0>5>0>3<7>MLO>0>9>0>6", "vlan_rl": "<2>52>0<9",
                  "apg4_mlo": "2", "apg4_ssid": "Example-A", "apg4_11be": "1", "apg4_security": "<3>sae>aes>k>0", "apg4_dut_list": "<\(macA)>3>",
                  "apg5_mlo": "2", "apg5_ssid": "Example-B", "apg5_11be": "0", "apg5_security": "<3>open>none>>0", "apg5_dut_list": "<\(macA)>0>",
                  "apg6_mlo": "1", "apg6_ssid": "Example-C", "apg6_disabled": "1", "apg6_security": ""]
    let mlo = MLOOverview(values: values, support: ["mlo": "1", "wifi7": "1"], online: [:], scheduleOn: ["apg4": "0", "apg5": "1"])
    #expect(mlo.networks.map(\.id) == ["7", "1", "2"])
    let c = mlo.networks[0], a = mlo.networks[1], b = mlo.networks[2]
    // VLAN index 2 is VID 52; WiFi7 from _11be; Wi-Fi off by schedule; locked; the VPN 客户端 tag from column 6.
    #expect(a.vlanID == "52" && a.wifi7 && a.scheduledOff && a.secured && !a.wired && a.vpnClient && !a.vpnServer)
    // No VLAN entry for index 0; an open network; a band of 0 is 有线连接; the VPN server tag from column 7.
    #expect(b.vlanID == nil && !b.wifi7 && !b.scheduledOff && !b.secured && b.wired && !b.vpnClient && b.vpnServer)
    // A VLAN entry without an ID; a row without columns 6 and 7 shows both tags, as undefined != "0" does on the page.
    #expect(c.vlanID == "" && c.needsReconfiguring && c.secured && !c.wired && c.vpnClient && c.vpnServer)
    // The WiFi7 icon needs ui_support wifi7.
    #expect(!MLOOverview(values: values, support: ["mlo": "1"], online: [:]).networks[1].wifi7)
}

@Test func mloBackhaulBandsFollowTheMainRoutersBands() throws {
    let support = ["mlo": "1", "mlo_bh_band": "1"]
    func node(_ json: String) throws -> Any? { (try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any])?.first }
    // capability 26 lists 2.4, 5-1, 5-2 and 6 GHz: 1 + 4 + 8 + 16.
    let quad = MLOOverview.meshBandTotal(try node(#"[{"mac":"AA:BB:CC:DD:EE:01","capability":{"26":{"wifi_band":[{"band":"1","count":"3"},{"band":4},{"band":"8"},{"band":"16"}]}}}]"#))
    #expect(quad == 29)
    // $.each also walks an object's values: 2.4, 5, 6-1 and 6-2 GHz.
    #expect(MLOOverview.meshBandTotal(try node(#"[{"capability":{"26":{"wifi_band":{"a":{"band":"1"},"b":{"band":2},"c":{"band":"32"},"d":{"band":"64"}}}}}]"#)) == 99)
    func title(_ value: String, _ total: Int, _ support: [String: String] = support) -> String? {
        MLOOverview(values: ["mlo_bh_band": value], support: support, online: [:], meshBands: total).backhaulBands
    }
    #expect(title("", quad) == "5GHz-1, 5GHz-2 and 6GHz (默认)" && title("25", quad) == "2GHz, 5GHz and 6GHz" && title("99", quad) == "未识别的值 99")
    // Without wifi_band entries the guest network capabilities count: 2.4, 5, 6-1 and 6-2 GHz.
    let guest = MLOOverview.meshBandTotal(try node(#"[{"capability":{"6":1,"7":"3","8":"","24":1,"34":"1","26":{"wifi_band":[]}}}]"#))
    #expect(guest == 1 + 2 + 32 + 64 && title("35", guest) == "2GHz, 5GHz and 6GHz" && title("", guest) == "5GHz, 6GHz-1 and 6GHz-2 (默认)")
    // Bands that are reported but not numbers count as 0 and stop the guest network fallback.
    #expect(MLOOverview.meshBandTotal(try node(#"[{"capability":{"6":1,"26":{"wifi_band":[{"band":"x"}]}}}]"#)) == 0)
    // No main router entry (an empty get_cfg_clientlist), bands without a choice, or no mlo: no choices.
    #expect(MLOOverview.meshBandTotal(try node("[]")) == 0 && MLOOverview.meshBandTotal(nil) == 0)
    #expect(title("", 0) == "" && title("28", 0) == "未识别的值 28" && title("", quad, ["mlo_bh_band": "1"]) == "")
    #expect(title("", quad, ["mlo": "1"]) == nil)
    #expect(javaScriptInt32("0x3") == 3 && javaScriptInt32(" 5 ") == 5 && javaScriptInt32("x") == 0 && javaScriptInt32(4.9) == 4 && javaScriptInt32(nil) == 0)
}

@Test func mloCountsOnlineDevicesByNetwork() async throws {
    // A new list for each use: the dictionary is not Sendable, so one value cannot be handed to two routers.
    func clients() -> [String: Any] {
        ["maclist": [macA, macB, "AA:BB:CC:DD:EE:03"],
         macA: ["sdn_idx": "1", "isOnline": "1"], macB: ["sdn_idx": 1, "isOnline": "1"],
         "AA:BB:CC:DD:EE:03": ["sdn_idx": "2", "isOnline": "0"], "AA:BB:CC:DD:EE:04": ["isOnline": "1"]]
    }
    let parsed = try SDNClientCount.parse(try JSONSerialization.data(withJSONObject: ["get_clientlist": clients()]))
    #expect(parsed == ["1": 2])
    let router = WirelessRouter(nvram: ["mld_enable": "0", "sdn_rl": mloRules, "apg4_mlo": "1", "apg4_ssid": "Example-BH"], support: ["mlo": "1"], clients: clients())
    let mlo = try await client(router).mloOverview()
    #expect(!mlo.enabled && mlo.networks.map(\.id) == ["1"] && mlo.networks[0].onlineDevices == 2)
    // Without MLO networks the device list is not read.
    let empty = WirelessRouter(nvram: ["sdn_rl": "<0>DEFAULT>1>0>0>0"], clients: clients())
    _ = try await client(empty).mloOverview()
    #expect(await !empty.requests.contains { $0.url?.query?.contains("get_clientlist") == true || $0.url?.query?.contains("apg_wifi_sched_on") == true })
}

@Test func mloReadsTheMainRoutersBandsAndSchedulesOnlyWhenShown() async throws {
    let cfg = #"[{"mac":"AA:BB:CC:DD:EE:01","capability":{"26":{"wifi_band":[{"band":"1"},{"band":"4"},{"band":"8"},{"band":"16"}]}}}]"#
    let router = WirelessRouter(nvram: ["mld_enable": "1", "mlo_bh_band": "", "sdn_rl": mloRules, "apg4_mlo": "1"], support: ["mlo": "1", "mlo_bh_band": "1"],
                                hooks: ["get_cfg_clientlist": cfg, "apg_wifi_sched_on": #"{"apg4":"0"}"#])
    let mlo = try await client(router).mloOverview()
    #expect(mlo.backhaulBands == "5GHz-1, 5GHz-2 and 6GHz (默认)" && mlo.networks.map(\.id) == ["1"] && mlo.networks[0].scheduledOff)
    let requests = await router.requests, paths = await router.paths
    #expect(requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil } && Set(paths) == ["appGet.cgi"])
    // Without 回程频段 the AiMesh list is not read; a hook the router does not answer leaves no choices and Wi-Fi on.
    let plain = WirelessRouter(nvram: ["sdn_rl": mloRules, "apg4_mlo": "1"], support: ["mlo": "1"])
    #expect(try await client(plain).mloOverview().networks.allSatisfy { !$0.scheduledOff })
    #expect(await !plain.requests.contains { $0.url?.query?.contains("get_cfg_clientlist") == true })
    let silent = WirelessRouter(nvram: ["mlo_bh_band": "", "sdn_rl": mloRules, "apg4_mlo": "1"], support: ["mlo": "1", "mlo_bh_band": "1"])
    #expect(try await client(silent).mloOverview().backhaulBands == "")
    // A cancelled read or an expired login is not an unanswered hook: the read ends with it.
    for hook in ["get_cfg_clientlist", "apg_wifi_sched_on"] {
        let nvram = ["mld_enable": "1", "mlo_bh_band": "", "sdn_rl": mloRules, "apg4_mlo": "1"], support = ["mlo": "1", "mlo_bh_band": "1"]
        let cancelled = WirelessRouter(nvram: nvram, support: support, hooks: [hook: "<cancelled>"])
        await #expect(throws: CancellationError.self) { try await client(cancelled).mloOverview() }
        let expired = WirelessRouter(nvram: nvram, support: support, hooks: [hook: "<expired>"])
        await #expect(throws: RouterError.authenticationRequired) { try await client(expired).mloOverview() }
    }
}

@Test func mloNetworksShowTheAccessTimeAndPortalTags() {
    // Column 11 is the portal: 1 and 3 on with an access time, 2 off with one, 8 on with only a schedule (1) and no column 11.
    let values = ["sdn_rl": "<1>MLO>1>0>0>4>0>0>0>0>0>2<3>MLO>1>0>0>5>0>0>0>0>0>4<2>MLO>0>0>0>6>0>0>0>0>0>2<8>MLO>1>0>0>7>0>0",
                  "cp_type_rl": "<2>2<4>4",
                  "apg4_mlo": "2", "apg4_timesched": "2", "apg4_expiretime": "T11700000000Z,T01700003661Z",
                  "apg5_mlo": "2", "apg5_timesched": "2", "apg5_expiretime": "T11699990000Z,T01699999999Z",
                  "apg6_mlo": "2", "apg6_timesched": "2", "apg6_expiretime": "T11700000000Z,T01700003661Z",
                  "apg7_mlo": "2", "apg7_timesched": "1", "apg7_expiretime": "T11700000000Z,T01700003661Z"]
    let support = ["mlo": "1", "captivePortal": "1", "cp_freewifi": "1"]
    let mlo = MLOOverview(values: values, support: support, online: [:], routerTime: 1_700_000_000, operationMode: "rt")
    #expect(mlo.networks.map(\.id) == ["1", "3", "2", "8"])
    let a = mlo.networks[0], b = mlo.networks[1], c = mlo.networks[2], d = mlo.networks[3]
    // 3661 seconds left: 01:01:01, counted down from the read and never below 0.
    #expect(a.accessTime == MLOOverview.AccessTime(end: 1_700_003_661, routerTime: 1_700_000_000) && a.accessTime?.counts == true)
    #expect(a.accessTime?.text(after: 0) == "01:01:01" && a.accessTime?.text(after: 62) == "00:59:59" && a.accessTime?.remaining(after: 5000) == 0)
    // An access time that has ended shows 00:00:00 and does not count; a network that is off, or on a schedule, has no tag.
    #expect(b.accessTime?.counts == false && b.accessTime?.text(after: 30) == "00:00:00" && c.accessTime == nil && d.accessTime == nil)
    // The page reads its list again when the first tag that counts down reaches 0; without one it does not.
    #expect(mlo.readsAgainAfter == 3661 && MLOOverview(values: values, support: support, online: [:], routerTime: 1_800_000_000).readsAgainAfter == nil)
    let twoCounting = values.merging(["apg5_expiretime": "T11700000000Z,T01700000090Z"]) { _, new in new }
    #expect(MLOOverview(values: twoCounting, support: support, online: [:], routerTime: 1_700_000_000).readsAgainAfter == 90)
    // The portal tags do not depend on the switch; a row without column 11 has none.
    #expect(a.freeWiFi && !a.messageBoard && !b.freeWiFi && b.messageBoard && c.freeWiFi && !d.freeWiFi && !d.messageBoard)
    // Outside router and WISP mode the page knows no portal types.
    #expect(MLOOverview(values: values, support: support, online: [:], operationMode: "ap").networks.allSatisfy { !$0.freeWiFi && !$0.messageBoard })
}

@Test func mloAccessTimeFollowsThePagesParsing() {
    func time(_ expire: String, _ now: Int = 1_700_000_000) -> MLOOverview.AccessTime? { MLOOverview.accessTime(expire, routerTime: now) }
    // The second entry must be 13 characters long; JavaScript counts UTF-16 units, so an emoji counts twice.
    #expect(time("") == nil && time("T11700000000Z") == nil && time("x,T0170000366Z") == nil && time("x,T01700003661Z0") == nil)
    #expect(time("x,T01700003661😀") == nil)
    // Only split(",")[1] counts: a second access time after "<" makes that entry longer.
    #expect(time("T11700000000Z,T01700003661Z<T11700000000Z,T01700007200Z") == nil)
    // parseInt reads the leading digits; without any it is NaN, which leaves no time.
    #expect(time("x,T0170000366xZ")?.end == 170_000_366 && time("x,T0x700003661Z")?.end == nil && time("x,T0x700003661Z")?.text(after: 0) == "00:00:00")
    // A combining mark is a code unit of its own: it ends the number, here after "1".
    #expect(time("x,T01\u{0301}70000000Z", 0)?.end == 1 && time("x,T01\u{0301}70000000Z", 0)?.text(after: 0) == "00:00:01")
    // Hours keep their last two digits, as on the page: 100 hours and 5 seconds read 00:00:05, and without the router's
    // clock (0) the whole end time is left.
    #expect(time("x,T01700360005Z")?.text(after: 0) == "00:00:05" && time("x,T01700003661Z", 0)?.text(after: 0) == "23:14:21")
}

@Test func mloPortalTagsNeedTheRoutersPortalTypes() {
    let support = ["captivePortal": "1", "cp_freewifi": "1"]
    func types(_ list: String, _ support: [String: String] = support, _ mode: String = "rt") -> Set<String> {
        MLOOverview.portalTypes(list, support: support, operationMode: mode)
    }
    #expect(types("<2>2<4>4<1>1") == ["2", "4"] && types("<2>2<4>4", support, "wisp") == ["2", "4"])
    #expect(["ap", "rp", "mb", ""].allSatisfy { types("<2>2<4>4", support, $0).isEmpty })
    // 留言板 is not offered on BUSINESS models; neither type without captivePortal and cp_freewifi, or with SMART_HOME_MASTER_UI.
    #expect(types("<2>2<4>4", ["captivePortal": "1", "cp_freewifi": "1", "BUSINESS": "1"]) == ["2"])
    #expect(types("<2>2<4>4", ["captivePortal": "1"]).isEmpty && types("<2>2<4>4", ["captivePortal": "1", "cp_freewifi": "1", "SMART_HOME_MASTER_UI": "1"]).isEmpty)
    // Only the types the router lists; an entry without a type is skipped.
    #expect(types("<2>2") == ["2"] && types("<4").isEmpty && types("").isEmpty)
}

@Test func mloReadsTheClockAndPortalTypesOnlyWhenNeeded() async throws {
    let nvram = ["sdn_rl": "<1>MLO>1>0>0>4>0>0>0>0>0>2", "cp_type_rl": "<2>2",
                 "apg4_mlo": "2", "apg4_timesched": "2", "apg4_expiretime": "T11700000000Z,T01700003661Z"]
    let support = ["mlo": "1", "captivePortal": "1", "cp_freewifi": "1"]
    let router = WirelessRouter(nvram: nvram, support: support, hooks: ["utctimestamp": #""1700000061""#, "get_operation_mode": #""rt""#])
    let network = try #require(try await client(router).mloOverview().networks.first)
    #expect(network.accessTime == MLOOverview.AccessTime(end: 1_700_003_661, routerTime: 1_700_000_061) && network.accessTime?.text(after: 0) == "01:00:00")
    #expect(network.freeWiFi && !network.messageBoard)
    let requests = await router.requests, keys = await router.readKeys
    #expect(requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil } && keys.isSuperset(of: ["apg4_timesched", "apg4_expiretime", "cp_type_rl"]))
    // The mode comes before the portal types, and the clock is the last request.
    let order = requests.compactMap { $0.url?.query }
    let mode = try #require(order.firstIndex { $0.contains("get_operation_mode") }), types = try #require(order.firstIndex { $0.contains("cp_type_rl") })
    #expect(mode < types && order.last?.contains("utctimestamp") == true)
    // A network that is off and has no Free WiFi or 留言板 portal: no clock, no mode, no portal types.
    let plain = WirelessRouter(nvram: ["sdn_rl": "<1>MLO>0>0>0>4>0>0>0>0>0>1", "apg4_mlo": "2", "apg4_timesched": "2"], support: support)
    let quiet = try #require(try await client(plain).mloOverview().networks.first)
    #expect(quiet.accessTime == nil && !quiet.freeWiFi)
    let queries = await plain.requests.compactMap { $0.url?.query }, plainKeys = await plain.readKeys
    #expect(!queries.contains { $0.contains("utctimestamp") || $0.contains("get_operation_mode") } && !plainKeys.contains("cp_type_rl"))
    // A clock the router does not answer counts as 0, as on the page; without captivePortal the mode is not read.
    let silent = WirelessRouter(nvram: nvram, support: ["mlo": "1"])
    #expect(try await client(silent).mloOverview().networks.first?.accessTime?.routerTime == 0)
    await #expect(throws: CancellationError.self) { try await client(WirelessRouter(nvram: nvram, support: ["mlo": "1"], hooks: ["utctimestamp": "<cancelled>"])).mloOverview() }
    await #expect(throws: RouterError.authenticationRequired) {
        try await client(WirelessRouter(nvram: nvram, support: ["mlo": "1"], hooks: ["utctimestamp": "<expired>"])).mloOverview()
    }
    #expect(await !silent.requests.contains { $0.url?.query?.contains("get_operation_mode") == true })
}

@Test func mloReadsOnlyForTheNetworksItShows() async throws {
    let support = ["mlo": "1", "captivePortal": "1", "cp_freewifi": "1"]
    let timed = ["sdn_rl": "<1>MLO>1>0>0>4>0>0>0>0>0>2", "cp_type_rl": "<2>2", "apg4_timesched": "2", "apg4_expiretime": "T11700000000Z,T01700003661Z"]
    let hooks = ["utctimestamp": #""1700000061""#, "get_operation_mode": #""rt""#]
    func queries(_ router: WirelessRouter) async -> [String] { await router.requests.compactMap { $0.url?.query } }
    func asks(_ queries: [String], _ names: [String]) -> Bool { queries.contains { query in names.contains { query.contains($0) } } }
    // A row the list does not show (_mlo "0") reads no clock, mode, portal types, schedule or devices.
    let hidden = WirelessRouter(nvram: timed.merging(["apg4_mlo": "0"]) { _, new in new }, support: support, hooks: hooks)
    #expect(try await client(hidden).mloOverview().networks.isEmpty)
    let hiddenQueries = await queries(hidden), hiddenKeys = await hidden.readKeys
    #expect(!asks(hiddenQueries, ["utctimestamp", "get_operation_mode", "apg_wifi_sched_on", "get_clientlist"]) && !hiddenKeys.contains("cp_type_rl"))
    // A BUSINESS model offers no 留言板, so a 留言板 portal reads no mode.
    let business = WirelessRouter(nvram: ["sdn_rl": "<1>MLO>1>0>0>4>0>0>0>0>0>4", "cp_type_rl": "<4>4", "apg4_mlo": "2"],
                                  support: support.merging(["BUSINESS": "1"]) { _, new in new }, hooks: hooks)
    #expect(try await client(business).mloOverview().networks.first?.messageBoard == false)
    #expect(await !asks(queries(business), ["get_operation_mode"]))
    // In AP mode the page knows no portal types: the mode is read, cp_type_rl is not.
    let ap = WirelessRouter(nvram: timed.merging(["apg4_mlo": "2"]) { _, new in new }, support: support, hooks: ["get_operation_mode": #""ap""#])
    #expect(try await client(ap).mloOverview().networks.first?.freeWiFi == false)
    let apQueries = await queries(ap), apKeys = await ap.readKeys
    #expect(asks(apQueries, ["get_operation_mode"]) && !apKeys.contains("cp_type_rl"))
    // The page has the mode from the start, so a mode the router does not give fails the read; a clock it does not give is 0.
    let noMode = WirelessRouter(nvram: timed.merging(["apg4_mlo": "2"]) { _, new in new }, support: support, hooks: ["get_operation_mode": "<"])
    await #expect(throws: RouterError.self) { try await client(noMode).mloOverview() }
    let noClock = WirelessRouter(nvram: timed.merging(["apg4_mlo": "2"]) { _, new in new }, support: support, hooks: ["utctimestamp": "<", "get_operation_mode": #""rt""#])
    let network = try #require(try await client(noClock).mloOverview().networks.first)
    #expect(network.accessTime?.routerTime == 0 && network.accessTime?.text(after: 0) == "23:14:21" && network.freeWiFi)
}

// MARK: Navigation

@Test func wirelessPagesHaveNativeHomes() {
    let expected: [(NativeFeature, String)] = [
        (.wps, "Advanced_WWPS_Content.asp"), (.wds, "Advanced_WMode_Content.asp"), (.roamingBlock, "Advanced_Roaming_Block_Content.asp"),
        (.mlo, "MLO.asp"), (.smartConnectRules, "Advanced_Smart_Connect.asp")
    ]
    for (feature, page) in expected { #expect(WebMenuCatalog.location(of: feature)?.page == page, "\(page)") }
}
