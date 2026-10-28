import Foundation
import Testing
@testable import RouterCore

// 1.12：网易UU加速器、网络打印机服务器、政策、Amazon Alexa、通过网络（LAN）唤醒、Site Survey 与 网络速度。

// MARK: - A router for these pages

/// Answers appGet hooks (nvram_char_to_ascii from `nvram`, get_ui_support from `support`, others from `hooks` as JSON),
/// pages and CGIs from `pages`, applyapp.cgi like the router (writing its fields into `nvram`) and start_apply.htm
/// (writing wollist). Records every request with its raw body.
private actor ToolRouter: RouterTransport {
    var nvram: [String: String]
    let support: [String: Any]
    let hooks: [String: String]
    let pages: [String: String]
    private(set) var requests: [(method: String, path: String, query: [String: String], body: String)] = []

    init(nvram: [String: String] = [:], support: [String: Any] = [:], hooks: [String: String] = [:], pages: [String: String] = [:]) {
        self.nvram = nvram; self.support = support; self.hooks = hooks; self.pages = pages
    }

    func send(_ request: URLRequest) async throws -> RouterHTTPResponse {
        guard let url = request.url else { throw RouterError.network("no url") }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let path = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        requests.append((request.httpMethod ?? "GET", path, query, body))
        switch path {
        case "appGet.cgi":
            let hook = query["hook"] ?? ""
            if hook == "get_ui_support()" { return try Self.reply(["get_ui_support": support]) }
            if hook.hasPrefix("nvram_match_x(") { return RouterHTTPResponse(data: Data("{\"nvram_match_x-\":\(hooks["nvram_match_x"] ?? "\"\"")}".utf8), status: 200) }
            if hook.hasSuffix("()"), let answer = hooks[String(hook.dropLast(2))] {
                return RouterHTTPResponse(data: Data("{\"\(hook.dropLast(2))\":\(answer)}".utf8), status: 200)
            }
            var object: [String: String] = [:]
            for call in hook.split(separator: ";") {
                guard call.hasPrefix("nvram_char_to_ascii("), let open = call.firstIndex(of: "("), let comma = call.firstIndex(of: ",") else { continue }
                let key = String(call[call.index(after: open)..<comma])
                object[key] = (nvram[key] ?? "").addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            }
            return try Self.reply(object)
        case "applyapp.cgi":
            guard let decoded = body.removingPercentEncoding, let fields = try JSONSerialization.jsonObject(with: Data(decoded.utf8)) as? [String: String] else {
                return RouterHTTPResponse(data: Data(), status: 400)
            }
            for (key, value) in fields where !["action_mode", "rc_service"].contains(key) { nvram[key] = value }
            return try Self.reply(["modify": "1", "run_service": fields["rc_service"] ?? ""])
        case "start_apply.htm":
            if let wollist = form(body)["wollist"] { nvram["wollist"] = wollist }
            return RouterHTTPResponse(data: Data("<script>done_committing();</script>".utf8), status: 200)
        default:
            if let page = pages[path] { return RouterHTTPResponse(data: Data(page.utf8), status: 200) }
            if request.httpMethod == "POST" || path.hasSuffix(".cgi") || path.hasSuffix(".htm") { return RouterHTTPResponse(data: Data("{}".utf8), status: 200) }
            return RouterHTTPResponse(data: Data(), status: 404)
        }
    }
    nonisolated func cancel() {}
    static func reply(_ object: Any) throws -> RouterHTTPResponse { RouterHTTPResponse(data: try JSONSerialization.data(withJSONObject: object), status: 200) }
    /// The requests other than reads of appGet.cgi.
    var actions: [(method: String, path: String, query: [String: String], body: String)] { requests.filter { $0.path != "appGet.cgi" } }
    var hooksAsked: [String] { requests.compactMap { $0.query["hook"] } }
}

private func client(_ router: ToolRouter) throws -> RouterClient { RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: router, writes: .reference) }
private func json(_ text: String) -> OrderedJSON { try! OrderedJSON(data: Data(text.utf8)) }
/// application/x-www-form-urlencoded decoding ("+" is a space).
private func form(_ body: String) -> [String: String] {
    Dictionary(body.split(separator: "&").map { pair -> (String, String) in
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map {
            String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
        }
        return (parts[0], parts.count > 1 ? parts[1] : "")
    }, uniquingKeysWith: { first, _ in first })
}

// MARK: - JavaScript helpers

@Test func toFixedRoundsTheExactValueWithTiesUp() {
    #expect(javaScriptFixed(0.125, 2) == "0.13")
    #expect(javaScriptFixed(1.005, 2) == "1.00")
    #expect(javaScriptFixed(2.5, 0) == "3")
    #expect(javaScriptFixed(-2.5, 0) == "-3")
    #expect(javaScriptFixed(-0.001, 2) == "-0.00")
    #expect(javaScriptFixed(9.9999, 2) == "10.00")
    #expect(javaScriptFixed(99.995, 2) == "100.00")
    #expect(javaScriptFixed(12.345, 2) == "12.35" && javaScriptFixed(-0.001, 0) == "-0")
    #expect(javaScriptFixed(1e21, 2) == "1e+21")
    #expect(javaScriptFixed(.nan, 2) == "NaN")
}

@Test func comparisonsFollowJavaScript() {
    #expect(JavaScriptCompare.atLeast(.string("4"), "1") && !JavaScriptCompare.atLeast(.string("0"), "1") && !JavaScriptCompare.atLeast(.string(""), "1"))
    // Text compares as text: "10" is below "2".
    #expect(JavaScriptCompare.below(.string("10"), "2") && JavaScriptCompare.atLeast(.string("a"), "1"))
    #expect(JavaScriptCompare.atLeast(.number("4"), "1") && JavaScriptCompare.below(.number("0"), "2"))
    #expect(!JavaScriptCompare.atLeast(nil, "1") && !JavaScriptCompare.below(nil, "2"))
    #expect(JavaScriptCompare.relational(.number("4"), .string("\u{A0}0")) == .orderedDescending)
    #expect(JavaScriptCompare.relational(.array([.string("3")]), .string("20")) == .orderedDescending)
    #expect(JavaScriptCompare.relational(.null, .number("0")) == .orderedSame && JavaScriptCompare.relational(.string("x"), .number("1")) == nil)
    #expect(JavaScriptCompare.looselyZero(.string("")) && JavaScriptCompare.looselyZero(.string(" 0 ")) && JavaScriptCompare.looselyZero(.number("0")))
    #expect(!JavaScriptCompare.looselyZero(.null) && !JavaScriptCompare.looselyZero(nil) && !JavaScriptCompare.looselyZero(.string("x")))
    #expect(json(#"{"a":1.50,"b":1E5,"c":"q\"\n\u0001é"}"#).javaScriptJSON == #"{"a":1.5,"b":100000,"c":"q\"\n\u0001é"}"#)
    // Own keys: array indices first, ascending.
    #expect(json(#"{"2":"b","1":"a","x":0,"01":1}"#).javaScriptJSON == #"{"1":"a","2":"b","x":0,"01":1}"#)
}

@Test func formsKeepThePageOrderAndEncoding() {
    let jQuery = String(decoding: RouterAuthentication.orderedForm([("type", ""), ("id", "a b+!*'()~"), ("iface", "tun12")], .jQuery), as: UTF8.self)
    #expect(jQuery == "type=&id=a+b%2B!*'()~&iface=tun12")
    let submitted = String(decoding: RouterAuthentication.orderedForm([("action_mode", " Refresh "), ("x", "a-b_c.d*e!~'():")], .formSubmission), as: UTF8.self)
    #expect(submitted == "action_mode=+Refresh+&x=a-b_c.d*e%21%7E%27%28%29%3A")
}

// MARK: - 网易UU加速器 and links

@Test func uuOpensTheRegistrationPageWithTheLowerCaseLabelMAC() async throws {
    #expect(UUAccelerator(labelMAC: "AA:BB:CC:00:11:22").registerURL?.absoluteString == "https://router.uu.163.com/asus/pc.html#/acce?gwSn=aa:bb:cc:00:11:22&type=asuswrt")
    #expect(UUAccelerator(labelMAC: nil).registerURL == nil)
    let router = ToolRouter(hooks: ["get_label_mac": "\"AA:BB:CC:00:11:22\""])
    #expect(try await client(router).uuAccelerator().labelMAC == "AA:BB:CC:00:11:22")
    #expect(AsusSupportLink.faq("146", lang: "CN")?.absoluteString == "https://nw-dlcdnet.asus.com/support/forward.html?model=&type=Faq&lang=CN&kw=&num=146")
    #expect(AsusSupportLink.policy(lang: "CN", kw: "tm_ppp")?.absoluteString == "https://nw-dlcdnet.asus.com/support/forward.html?model=&type=Policy&lang=CN&kw=tm_ppp&num=")
    #expect(AsusSupportLink.target("tmeula", lang: "CN")?.absoluteString == "https://nw-dlcdnet.asus.com/support/forward.html?model=&type=TMeula&lang=CN&kw=&num=")
    #expect(AsusSupportLink.target("personal", lang: "CN") == nil)
}

@Test func printerSwitchIsACatalogSectionWithTheWebService() throws {
    let section = try #require(SettingsCatalog.sections.first { $0.id == "printer" })
    #expect(section.service == "restart_lpd;restart_u2ec;" && section.wait == 5 && section.fields.map(\.key) == ["usb_printer"])
}

// MARK: - 政策

@Test func policyTextsComeFromTheDictionary() throws {
    let privacy = try #require(PolicyTexts.privacy(version: "4"))
    #expect(privacy.title == "ASUS 隐私声明" && privacy.blocks.first?.kind == .title && privacy.blocks.first?.text == "ASUS 隐私声明")
    #expect(privacy.blocks[2].links.first?.url == "personal" && privacy.blocks[2].text.contains("系统管理>政策"))
    // The link's text sits in the paragraph, where the window links it.
    #expect(privacy.blocks[2].text.contains(privacy.blocks[2].links[0].title))
    // "<拒绝>" is text, not a tag.
    #expect(privacy.blocks[4].text.contains("<拒绝>"))
    #expect(PolicyTexts.privacy(version: "3") == nil && PolicyTexts.privacy(version: "undefined") == nil)
    #expect(PolicyTexts.personalData(version: "2")?.blocks.count == 12)
    let eula = try #require(PolicyTexts.eula)
    #expect(eula.blocks.first?.text == "最终用户许可协议(以下简称“EULA”)" && eula.blocks.contains { $0.marker == "1.1.1" } && eula.blocks.contains { $0.marker == "12." })
    let trendMicro = try #require(PolicyTexts.trendMicro)
    #expect(trendMicro.title == "趋势科技（中国）有限公司最终用户许可协议" && trendMicro.blocks.count == 5)
    #expect(trendMicro.blocks.flatMap(\.links).map(\.url) == ["tmeula", "https://nw-dlcdnet.asus.com/trend/tm_privacy", "https://nw-dlcdnet.asus.com/trend/tm_pdcd"])
}

private func status(eula: String = "1", tm: String = "0", tmTime: String = "t", pp: OrderedJSON?, time: OrderedJSON?, support: OrderedJSON? = .number("4"), noUpgrade: String = "") -> PrivacyPolicyStatus {
    PrivacyPolicyStatus(values: ["ASUS_NEW_EULA": eula, "TM_EULA": tm, "TM_EULA_time": tmTime, "preferred_lang": "CN", "ASUS_PP_AutoWebUpgradeDisable": noUpgrade],
                        pp: pp, ppTime: time, ppSupport: support)
}

@Test func privacyBlocksFollowTheStoredAnswers() {
    let agreed = status(pp: .string("4"), time: .string("2026-01-01"))
    #expect(agreed.privacyAgreed && agreed.privacyVersion == "4" && !agreed.privacyAsksAgreement && !agreed.featureNeedsAgreement)
    let none = status(pp: .string("0"), time: .string(""))
    #expect(!none.privacyAgreed && none.privacyVersion == "4" && none.privacyAsksAgreement && none.featureNeedsAgreement && none.privacyDocument != nil)
    // A failed request leaves the number 0 and "".
    let failed = status(pp: .number("0"), time: .string(""), support: .number("2"))
    #expect(!failed.privacyAgreed && failed.privacyVersion == "2")
    // "10" is at least "1" but also below "2" as text.
    let ten = status(pp: .string("10"), time: .string("t"))
    #expect(ten.privacyAgreed && ten.privacyAsksAgreement && ten.privacyVersion == "10" && ten.privacyDocument == nil)
    // " 0" == 0 but is not below "2": the version (4) is above it, so the window still asks.
    #expect(status(pp: .string("\u{A0}0"), time: .string("t")).privacyAsksAgreement)
    #expect(status(pp: nil, time: nil).privacyVersion == "undefined" && !status(pp: nil, time: nil).privacyAgreed)
    #expect(status(tm: "1", pp: .string("4"), time: .string("t")).showsTrendMicro && !agreed.showsTrendMicro)
    #expect(status(eula: "0", pp: .string("4"), time: .string("t")).eulaAsksAgreement && !agreed.eulaAsksAgreement)
    // checkPolicy after the EULA.
    #expect(status(pp: .string("1"), time: .string("t")).asksPrivacyAfterEULA)
    #expect(status(pp: .string("1"), time: nil).asksPrivacyAfterEULA)
    #expect(none.asksPrivacyAfterEULA && !agreed.asksPrivacyAfterEULA && !status(eula: "0", pp: .string("0"), time: .string("")).asksPrivacyAfterEULA)
    #expect(agreed.agreementEnablesAutoUpgrade && !status(pp: .string("0"), time: .string(""), noUpgrade: "1").agreementEnablesAutoUpgrade)
}

@Test func checkPolicyOpensTheNextWindow() {
    #expect(status(eula: "0", pp: .string("4"), time: .string("t")).followUp(onPageLoad: false) == .updateNotice)
    #expect(status(pp: .string("0"), time: .string("")).followUp(onPageLoad: false) == .privacy)
    #expect(status(pp: .string("4"), time: .string("t")).followUp(onPageLoad: true) == .none)
    // Only the page's load-time check asks for Trend Micro's terms.
    let trendMicro = status(tm: "1", tmTime: "", pp: .string("4"), time: .string("t"))
    #expect(trendMicro.followUp(onPageLoad: true) == .trendMicro && trendMicro.followUp(onPageLoad: false) == .none)
    #expect(trendMicro.trendMicroAsksAgreement && !status(tm: "1", pp: .string("4"), time: .string("t")).trendMicroAsksAgreement)
}

@Test func privacyActionsSendWhatTheWindowsSend() async throws {
    let answer = #"{"ASUS_privacy_policy":"0","ASUS_privacy_policy_time":""}"#
    let router = ToolRouter(nvram: ["ASUS_NEW_EULA": "1", "TM_EULA": "1", "ASUS_PP_AutoWebUpgradeDisable": "0"], support: ["asus_pp": 4],
                            pages: ["get_ASUS_privacy_policy.cgi": answer])
    let read = try await client(router).privacyPolicyStatus()
    #expect(!read.privacyAgreed && read.privacyVersion == "4" && read.showsTrendMicro)
    _ = try await client(router).applyPrivacyPolicy(.agreePrivacy(updates: true))
    var actions = await router.actions.filter { $0.path != "get_ASUS_privacy_policy.cgi" }
    #expect(actions.map(\.path) == ["set_ASUS_privacy_policy.cgi", "set_security_update.cgi", "applyapp.cgi"])
    #expect(actions[0].query == ["ASUS_privacy_policy": "1"] && actions[1].query == ["security_update": "1"])
    #expect(await router.nvram["webs_update_enable"] == "1")

    let quiet = ToolRouter(nvram: ["ASUS_PP_AutoWebUpgradeDisable": "1"], pages: ["get_ASUS_privacy_policy.cgi": answer])
    _ = try await client(quiet).applyPrivacyPolicy(.agreePrivacy(updates: true))
    actions = await quiet.actions.filter { $0.path != "get_ASUS_privacy_policy.cgi" }
    #expect(actions.map(\.path) == ["set_ASUS_privacy_policy.cgi", "set_security_update.cgi"])

    let alexa = ToolRouter(pages: ["get_ASUS_privacy_policy.cgi": answer])
    for action: PrivacyPolicyAction in [.agreePrivacy(updates: false), .withdrawPrivacy, .agreeEULA, .withdrawTrendMicro, .agreeTrendMicro] {
        _ = try await client(alexa).applyPrivacyPolicy(action)
    }
    actions = await alexa.actions.filter { $0.path != "get_ASUS_privacy_policy.cgi" }
    #expect(actions.map(\.path) == ["set_ASUS_privacy_policy.cgi", "set_ASUS_privacy_policy.cgi", "set_ASUS_NEW_EULA.cgi", "set_TM_EULA.cgi", "set_TM_EULA.cgi"])
    #expect(actions.map(\.query) == [["ASUS_privacy_policy": "1"], ["ASUS_privacy_policy": "0"], ["ASUS_NEW_EULA": "1"], ["TM_EULA": "0"], ["TM_EULA": "1"]])
    #expect(actions.allSatisfy { $0.method == "GET" })

    // privateEula.set and newEula.set go on only with a JSON answer: nothing more is sent after one that is not.
    let truncated = ToolRouter(nvram: ["ASUS_PP_AutoWebUpgradeDisable": "0"], pages: ["get_ASUS_privacy_policy.cgi": answer, "set_ASUS_privacy_policy.cgi": "{\"ASUS_priv"])
    await #expect(throws: RouterError.self) { try await client(truncated).applyPrivacyPolicy(.agreePrivacy(updates: true)) }
    #expect(await truncated.actions.map(\.path) == ["set_ASUS_privacy_policy.cgi"])

    // An answer that is not JSON keeps the page's defaults.
    let broken = ToolRouter(support: ["asus_pp": 2], pages: ["get_ASUS_privacy_policy.cgi": "not json"])
    let defaults = try await client(broken).privacyPolicyStatus()
    #expect(defaults.pp == .number("0") && defaults.ppTime == .string("") && defaults.privacyVersion == "2")
}

@Test func thirdPartyNoticeNamesTheParty() {
    let speed = ThirdPartyPolicy.speedtest.agreement
    #expect(speed.before == "通过使用 Speedtest 应用程序，您同意 " && speed.link == "Ookla PRIVACY POLICY" && speed.after == "。")
    #expect(ThirdPartyPolicy.alexa.details[0].hasPrefix("请注意，您的信息将由 Amazon.com Services LLC 通过 Alexa 收集。"))
    #expect(ThirdPartyPolicy.speedtest.introduction != nil && ThirdPartyPolicy.alexa.introduction == nil)
}

// MARK: - Amazon Alexa

private func alexa(_ values: [String: String], token: String = "1", external: Int = -1, support: [String: String] = [:]) -> AlexaPage {
    AlexaPage(values: ["link_internet": "2", "productid": "RT-BE88U"].merging(values) { _, new in new }, support: support, tokenEmpty: token, externalIP: external)
}

@Test func alexaStatusFollowsShowAccountState() {
    let asus = ["ddns_enable_x": "1", "ddns_hostname_x": "home.asuscomm.com", "ddns_server_x": "WWW.ASUS.COM", "ddns_return_code_chk": "200", "misc_http_x": "1"]
    #expect(alexa(["link_internet": "1"]).status == .noInternet)
    #expect(alexa(asus, token: "", external: 1).status == .registered)
    #expect(alexa(asus, token: "1", external: 1).status == .account)
    #expect(alexa(asus.merging(["misc_http_x": "0"]) { _, new in new }, external: 1).status == .enableRemoteControl)
    #expect(alexa(asus.merging(["ddns_return_code_chk": "401"]) { _, new in new }, external: 1).status == .enableRemoteControl)
    // Another DDNS service counts once it has updated without an error.
    let other = ["ddns_enable_x": "1", "ddns_hostname_x": "x.example", "ddns_server_x": "WWW.NO-IP.COM", "ddns_updated": "1", "misc_http_x": "1"]
    #expect(alexa(other, external: 1).status == .account && alexa(other.merging(["ddns_return_code_chk": "auth_fail"]) { _, new in new }, external: 1).status == .enableRemoteControl)
    // Without a public address only the account counts.
    #expect(alexa([:], token: "", external: 0).status == .registered && alexa([:], token: "1", external: -1).status == .account)
    #expect(alexa([:]).title == "Amazon Alexa Skill" && alexa([:], support: ["ifttt": "1"]).title == "Alexa & IFTTT - Amazon Alexa Skill")
    #expect(alexa([:]).defaultRegion.name == "美国" && alexa(["territory_code": "OP/01"]).defaultRegion.name == "澳大利亚＆新西兰")
    #expect(alexa(["preferred_lang": "CN"]).faqURL.absoluteString == "https://www.asus.com.cn/support/FAQ/1033393")
    #expect(alexa(["preferred_lang": "XX"]).faqURL.absoluteString == "https://www.asus.com/support/FAQ/1033393")
    #expect(alexa(["oauth_auth_status": "2"]).appGuideline && !alexa([:]).appGuideline)
    // The five-second update changes link_internet, misc_http_x and the token; the DDNS check keeps the loaded values.
    let loaded = alexa(asus, token: "1", external: 1)
    #expect(loaded.refreshed(live: ["link_internet": "1"]).status == .noInternet)
    #expect(loaded.refreshed(live: ["link_internet": "2", "misc_http_x": "0"]).status == .enableRemoteControl)
    #expect(loaded.refreshed(live: ["link_internet": "2", "misc_http_x": "1", "ddns_enable_x": "0"], tokenEmpty: "").status == .registered)
}

@Test func alexaReadsTheRealAddressAndActs() async throws {
    let realIP = """
    var wan0_realip_state = "2";
    var wan1_realip_state = "";
    var wan0_realip_ip = "203.0.113.9";
    var wan1_realip_ip = "";
    var active_wan_unit = "0";
    var wan0_ipaddr = "203.0.113.9";
    var wan1_ipaddr = "";
    """
    #expect(RealIPCheck.evaluate(realIP) == ("2", 1))
    #expect(RealIPCheck.evaluate(realIP.replacingOccurrences(of: "\"203.0.113.9\";\nvar wan1_realip_ip", with: "\"198.51.100.1\";\nvar wan1_realip_ip")).external == 0)
    #expect(RealIPCheck.evaluate(realIP.replacingOccurrences(of: "active_wan_unit = \"0\"", with: "active_wan_unit = \"2\"")).external == -1)
    let router = ToolRouter(nvram: ["link_internet": "2", "ddns_enable_x": "1", "ddns_hostname_x": "h", "ddns_server_x": "WWW.ASUS.COM", "ddns_return_code_chk": "200", "misc_http_x": "1"],
                            hooks: ["nvram_match_x": "\"1\""], pages: ["get_real_ip.asp": realIP, "get_IFTTTPincode.cgi": "{\n\"ifttt_pincode\":\"123456\"\n}\n"])
    // The page opens before get_real_ip answers; the open page then reads it (and owns its count).
    let opened = try await client(router).alexaPage()
    #expect(opened.externalIP == -1 && opened.tokenEmpty == "1")
    #expect(await !router.requests.contains { $0.path == "get_real_ip.asp" })
    let real = try await client(router).alexaRealIP()
    #expect(real.external == 1 && real.answered)
    let page = opened.refreshed(externalIP: real.external)
    #expect(page.status == .account)
    let live = try await client(router).alexaLiveStatus(page)
    #expect(live.status == .account && live.live["misc_http_x"] == "1" && live.externalIP == 1)
    #expect(try await client(router).alexaActivationCode() == "123456")
    // The token itself is never read.
    #expect(await !router.hooksAsked.contains { $0.contains("ifttt_token,") })
}

// MARK: - 通过网络（LAN）唤醒

@Test func wakeOnLANListFollowsThePage() {
    let stored = WakeOnLANList.stored("<PC>aa:bb:cc:dd:ee:ff<Laptop>11:22:33:44:55:66<X>aa:bb:cc:dd:ee:ff<NoGt")
    #expect(stored.map(\.key) == ["aa:bb:cc:dd:ee:ff", "11:22:33:44:55:66", "undefined"] && stored.map(\.name) == ["X", "Laptop", "NoGt"])
    #expect(WakeOnLANList.stored("<A>5<B>3<C>x").map(\.key) == ["3", "5", "x"])
    let list = WakeOnLANList(wollist: "<PC>aa:bb:cc:dd:ee:ff<Laptop>11:22:33:44:55:66", clientNames: ["11:22:33:44:55:66": "Phone", "AA:BB:CC:DD:EE:FF": "Desk"])
    // The client list is keyed by upper-case MAC, so only the exact key finds a name.
    #expect(list.entries.map(\.name) == ["PC", "Phone"] && list.rows.map(\.mac) == ["AA:BB:CC:DD:EE:FF", "11:22:33:44:55:66"])
    #expect(list.encoded == "<PC>aa:bb:cc:dd:ee:ff<Phone>11:22:33:44:55:66" && WakeOnLANList(wollist: "", clientNames: [:]).encoded == "")
    #expect(WakeOnLANList.isMAC("AA:BB:CC:DD:EE:FF") && WakeOnLANList.isMAC("xAA:BB:CC:DD:EE:FF") && WakeOnLANList.isMAC(""))
    #expect(!WakeOnLANList.isMAC("AA:BB:CC:DD:EE:FFx") && !WakeOnLANList.isMAC("AABBCCDDEEFF"))
    #expect(list.adding("", clientNames: [:]) == .failure(.blank) && list.adding("zz", clientNames: [:]) == .failure(.format))
    #expect(list.adding("11:22:33:44:55:66", clientNames: [:]) == .failure(.duplicate))
    // The stored lower-case key is not the upper-cased input, so the page adds it again.
    guard case .success(let added) = list.adding("aa:bb:cc:dd:ee:ff", clientNames: ["AA:BB:CC:DD:EE:FF": "Desk"]) else { Issue.record("not added"); return }
    #expect(added.entries.last?.key == "AA:BB:CC:DD:EE:FF" && added.entries.last?.name == "Desk" && added.rows.count == 3)
    // 移除 deletes the upper-cased key: the lower-case row goes from the table, its twin from the list.
    let removed = added.removing(row: 0)
    #expect(removed.rows.map(\.key) == ["11:22:33:44:55:66", "AA:BB:CC:DD:EE:FF"] && removed.entries.map(\.key) == ["aa:bb:cc:dd:ee:ff", "11:22:33:44:55:66"])
    #expect(removed.encoded == "<PC>aa:bb:cc:dd:ee:ff<Phone>11:22:33:44:55:66")
    // A lower-case row removed alone stays saved; with its row gone and entries left, 添加 throws and does nothing.
    let lower = WakeOnLANList(wollist: "<PC>aa:bb:cc:dd:ee:ff", clientNames: [:]).removing(row: 0)
    #expect(lower.rows.isEmpty && lower.entries.count == 1 && !lower.showsNoData && lower.adding("a1:b2:c3:d4:e5:f6", clientNames: [:]) == .failure(.stopped))
    // An upper-case one is removed; the empty list is drawn again with 目前没有数据.
    let upper = WakeOnLANList(wollist: "<PC>AA:BB:CC:DD:EE:FF", clientNames: [:]).removing(row: 0)
    #expect(upper.entries.isEmpty && upper.showsNoData && upper.encoded == "")
    guard case .success(let fresh) = list.adding("a1:b2:c3:d4:e5:f6", clientNames: [:]) else { Issue.record("not added"); return }
    #expect(fresh.entries.last?.name == "New device" && fresh.removing(row: 2).encoded == list.encoded)
    let full = WakeOnLANList(wollist: (0..<32).map { String(format: "<d>00:00:00:00:00:%02X", $0) }.joined(), clientNames: [:])
    #expect(full.adding("a1:b2:c3:d4:e5:f6", clientNames: [:]) == .failure(.limit))
}

@Test func wakeOnLANSendsTheWebForms() async throws {
    let router = ToolRouter(nvram: ["wollist": "<PC>aa:bb:cc:dd:ee:ff", "lan_hwaddr": "04:42:1A:00:00:01", "preferred_lang": "CN", "firmver": "3.0.0.6", "productid": "RT-BE88U"],
                            pages: ["cmdRet_check.htm": "XU6J03M6\n"])
    let page = try await client(router).wakeOnLANPage()
    #expect(page.stored == "<PC>aa:bb:cc:dd:ee:ff" && page.lanMAC == "04:42:1A:00:00:01" && page.list.entries.count == 1)
    try await client(router).wakeOnLAN("AA:BB:CC:DD:EE:FF", adding: "", page: page)
    let wake = try #require(await router.actions.first { $0.path == "apply.cgi" })
    #expect(wake.method == "POST" && wake.body == "current_page=Main_WOL_Content.asp&next_page=Main_WOL_Content.asp&group_id=&modified=0"
            + "&action_mode=+Refresh+&action_script=&action_wait=&first_time=&preferred_lang=CN"
            + "&SystemCmd=ether-wake+-i+br0+-b+AA%3ABB%3ACC%3ADD%3AEE%3AFF&firmver=3.0.0.6&destIP=AA%3ABB%3ACC%3ADD%3AEE%3AFF&wollist_macAddr=")
    #expect(try await client(router).commandLog().contains("XU6J03M6"))
    await #expect(throws: WakeOnLANError.invalidTarget) { try await client(router).wakeOnLAN("nope", adding: "", page: page) }
    let receipt = try await client(router).saveWakeOnLANList(WakeOnLANList(wollist: "<Desk>11:22:33:44:55:66", clientNames: [:]), page: page)
    let save = try #require(await router.actions.first { $0.path == "start_apply.htm" })
    #expect(save.body == "productid=RT-BE88U&current_page=Main_WOL_Content.asp&next_page=Main_WOL_Content.asp&modified=0&action_mode=apply&action_wait=3"
            + "&action_script=&wollist=%3CDesk%3E11%3A22%3A33%3A44%3A55%3A66")
    let saved = await router.nvram["wollist"]
    #expect(receipt.isVerified && saved == "<Desk>11:22:33:44:55:66")
    // applyRule reads the table's first row before anything: with every row removed but a lower-case key left there is
    // none, it throws, and nothing is sent.
    let emptied = WakeOnLANList(wollist: "<A>aa:bb:cc:dd:ee:ff", clientNames: [:]).removing(row: 0)
    #expect(emptied.tableEmptied)
    let sent = await router.actions.count
    await #expect(throws: WakeOnLANError.stopped) { try await client(router).saveWakeOnLANList(emptied, page: page) }
    #expect(await router.actions.count == sent)
}

// MARK: - Site Survey

private let survey = SiteSurvey(state: "5", rows: json("""
[["2G","My%20Net","6","WPA2-Personal","AES","80","aa:bb:cc:dd:ee:01","ax"],
 ["5G",null,"36","x","y","10","aa:bb:cc:dd:ee:02","ac"],
 ["6G","Bad%FFFFx","37","x","y","10","aa:bb:cc:dd:ee:03","be"],
 ["6G","","37","WPA3-Personal","AES","30","aa:bb:cc:dd:ee:04","be"],
 ["5G","Open Cafe","36","Open System","NONE","55","aa:bb:cc:dd:ee:05","ac"],
 ["5G","%3Cb%3EBold%3C%2Fb%3E%20%26amp%3B","149","WPA2-Personal","WEP","55","aa:bb:cc:dd:ee:06","ac"]]
""").arrayValue, radio2: "0", radio5: "")

private extension OrderedJSON { var arrayValue: [OrderedJSON] { if case .array(let elements) = self { elements } else { [] } } }

@Test func siteSurveyListsTheRowsAsThePageWritesThem() throws {
    guard case .networks(let networks) = survey.table(survey.rows) else { Issue.record("no table"); return }
    #expect(networks.map(\.id) == [0, 3, 4, 5])
    #expect(networks[0].ssid == "My Net" && networks[0].channel == "6 (ax)" && networks[0].security == "WPA2-Personal (AES)" && networks[0].band == "2.4 GHz")
    #expect(networks[0].bars == 4 && networks[0].locked && !networks[0].open && networks[0].signal == "80")
    #expect(networks[1].ssid == "[hidden]" && networks[1].hidden && networks[1].channel == "6g37 (ax)" && networks[1].band == "6 GHz" && networks[1].bars == 2)
    // A literal space becomes &nbsp; before decoding.
    #expect(networks[2].ssid == "Open\u{A0}Cafe" && networks[2].security == "Open System" && networks[2].open && !networks[2].locked && networks[2].bars == 3)
    // Encoded markup is decoded into HTML: the tags are not shown, the entity is.
    #expect(networks[3].ssid == "Bold &" && networks[3].security == "WEP" && networks[3].band == "5 GHz")
    #expect(survey.radio2Off && !survey.radio5Off)
    #expect(SiteSurvey(state: "3", rows: [], radio2: "1", radio5: "1").table([]) == .searching)
    #expect(SiteSurvey(state: "5", rows: [.array([])], radio2: "1", radio5: "1").table([.array([])]) == .noResult)
    #expect(SiteSurvey(state: "5", rows: [], radio2: "1", radio5: "1").table([]) == .networks([]))
    #expect(survey.table([json(#"["2G","%E4%B8","1","a","b","1","m","n"]"#)]) == .stopped)
    // The SSID cell calls toUpperCase on the MAC, and the first row's length is read: anything but text, or a null first
    // row, throws and the table stays as it was. A row that is a number reads undefined and is skipped.
    #expect(survey.table([json(#"["2G","A","1","a","b","1",null,"n"]"#)]) == .stopped && survey.table([json(#"["2G","A","1","a","b","1",5,"n"]"#)]) == .stopped)
    #expect(survey.table([.null]) == .stopped && survey.table([.string("ab")]) == .stopped && survey.table([.number("5")]) == .networks([]))
}

@Test func uriDecodingThrowsWhereJavaScriptDoes() {
    #expect(SiteSurvey.decodeURIComponent("%E4%B8%AD%20a") == "中 a")
    for broken in ["%E4%B8", "%ZZ", "%C0%80", "100%", "%ED%A0%80", "%80", "%F8%80%80%80%80"] { #expect(SiteSurvey.decodeURIComponent(broken) == nil, "\(broken)") }
    #expect(SiteSurvey.decodeURIComponent("%00") == "\u{0}")
}

@Test func siteSurveySortsLikeDoSorter() throws {
    let rows = survey.rows
    func ids(_ sorted: [OrderedJSON]?) -> [String] { (sorted ?? []).compactMap { $0.arrayValue[safe: 6]?.text.map { String($0.suffix(2)) } } }
    // Signal, descending by default; equal signals keep their order.
    #expect(ids(SiteSurvey.sorted(rows, by: .signal, descending: true)) == ["01", "05", "06", "04", "02", "03"])
    #expect(ids(SiteSurvey.sorted(rows, by: .channel, descending: false)) == ["01", "02", "05", "03", "04", "06"])
    // A text column calls toUpperCase on every value: the null SSID throws, and nothing is sorted.
    #expect(SiteSurvey.sorted(rows, by: .ssid, descending: false) == nil)
    #expect(SiteSurvey.sorted(rows + [.null], by: .signal, descending: true) == nil)
    #expect(ids(SiteSurvey.sorted(rows.filter { $0.arrayValue[safe: 1] != .null }, by: .ssid, descending: false)).first == "04")
    // Sorting the sorted rows again keeps the earlier order among equal values (the page sorts aplist in place).
    let bySignal = try #require(SiteSurvey.sorted(rows, by: .signal, descending: true))
    #expect(ids(SiteSurvey.sorted(bySignal, by: .channel, descending: false)) == ["01", "05", "02", "04", "03", "06"])
    #expect(SiteSurvey.parseInt(.string(" 0x1A ")) == 26 && SiteSurvey.parseInt(.string("12abc")) == 12 && SiteSurvey.parseInt(.string("abc")) == nil)
}

private extension Array { subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil } }

@Test func siteSurveyReadsApscanAndScansWithTheWebForm() async throws {
    let apscan = "\u{FEFF}child_macaddr = 'x';\n_sw_mode = '1';\nwlc_state = '0';\nwlc_sbstate = '0';\nwlc_scan_state = '5';\n_wlc_ssid = '';\naplist = [[[\"2G\",\"A\",\"1\",\"Open System\",\"NONE\",\"50\",\"AA:BB:CC:DD:EE:FF\",\"n\"]]][0];\n"
    let router = ToolRouter(nvram: ["preferred_lang": "CN", "firmver": "3.0.0.6"], hooks: ["radio_status": #"{"radio_2":"1", "radio_5":"0"}"#], pages: ["apscan.asp": apscan])
    let read = try await client(router).siteSurvey()
    #expect(read.finished && read.rows.count == 1 && !read.radio2Off && read.radio5Off)
    #expect(await router.actions.allSatisfy { $0.method == "GET" })
    try await client(router).startSiteSurvey()
    let scan = try #require(await router.actions.first { $0.path == "start_apply2.htm" })
    #expect(scan.method == "POST" && scan.body == "current_page=Advanced_Wireless_Survey.asp&next_page=Advanced_Wireless_Survey.asp&prev_page=Advanced_Wireless_Survey.asp"
            + "&modified=0&flag=sitesurvey&action_mode=apply&action_wait=1&action_script=restart_wlcscan&first_time=&SystemCmd=&preferred_lang=CN&firmver=3.0.0.6")
    #expect(SiteSurvey.vendorKey("aa:bb:cc:dd:ee:ff") == "AABBCC")
}

// MARK: - 网络速度

@Test func speedValuesAreFormattedAsThePageDoes() throws {
    #expect(try InternetSpeed.mbps(.number("125000")) == "1.00" && InternetSpeed.mbps(.number("15625")) == "0.13")
    #expect(try InternetSpeed.mbps(.number("1250000000")) == "10000.0" && InternetSpeed.mbps(.number("12500000000")) == "100000")
    #expect(try InternetSpeed.mbps(nil) == "NaN" && InternetSpeed.mbps(.null) == "0.00" && InternetSpeed.mbps(.string("125000")) == "1.00")
    // `bytes * 8` turns an object or array into text first: an array joins, an object with a toString member throws.
    #expect(try InternetSpeed.mbps(.array([.number("125000")])) == "1.00" && InternetSpeed.mbps(json("{}")) == "NaN")
    #expect(throws: ScriptStop.self) { try InternetSpeed.mbps(json(#"{"toString":0}"#)) }
    let utc = OrderedJSON.string("2026-10-27T03:04:05Z")
    #expect(try InternetSpeed.localTime(utc, timezone: "+1100") == ("2026/10/27", "14:04"))
    #expect(try InternetSpeed.localTime(utc, timezone: "-0530") == ("2026/10/26", "22:04"))
    #expect(try InternetSpeed.localTime(utc, timezone: "1100") == ("1970/1/1", "00:00"))
    #expect(try InternetSpeed.localTime(.string("nonsense"), timezone: "+1100") == ("NaN/NaN/NaN", "NaN:NaN"))
    #expect(try InternetSpeed.localTime(.string("2026-01-05T23:30:00.123Z"), timezone: "+0100") == ("2026/1/6", "00:30"))
    // new Date(value) by type: a number is the time, null 0; text also with a space and an offset without colon.
    #expect(try InternetSpeed.localTime(.number("0"), timezone: "+0000") == ("1970/1/1", "00:00") && InternetSpeed.localTime(.null, timezone: "+0100") == ("1970/1/1", "01:00"))
    #expect(try InternetSpeed.javaScriptDate(.string("2026-01-01 00:00:00Z")) == 1_767_225_600_000)
    #expect(try InternetSpeed.javaScriptDate(.string("2026-01-01T00:00:00+0530")) == 1_767_205_800_000)
    #expect(try InternetSpeed.javaScriptDate(.string("2026-02-30")) == 1_772_409_600_000 && InternetSpeed.javaScriptDate(.string("2026-13-01")).isNaN)
    #expect(try InternetSpeed.javaScriptDate(.string("2026-01-01T24:00:00Z")) == 1_767_312_000_000 && InternetSpeed.javaScriptDate(.array([.number("2020")])) == 1_577_836_800_000)
    #expect(throws: ScriptStop.self) { try InternetSpeed.javaScriptDate(json(#"{"toString":0}"#)) }
    #expect(try InternetSpeed.javaScriptDate(json("{}")).isNaN && JavaScriptMember.parseInt(.array([.string("12px")])) == 12)
    #expect(throws: ScriptStop.self) { try JavaScriptMember.parseInt(json(#"[{"toString":0}]"#)) }
    #expect(try InternetSpeed.javaScriptDate(nil).isNaN && InternetSpeed.javaScriptDate(.number("8.64e15")) == 8.64e15 && InternetSpeed.javaScriptDate(.number("8.7e15")).isNaN)
    #expect(["5.99", "6.00", "50.99", "51", "100.5", "101", "250.9", "251", "900.99", "901"].map { SpeedLevel(mbps: $0)?.name ?? "" }
            == ["一般", "良好", "良好", "不错", "不错", "很快", "很快", "超快", "超快", "极快"])
    #expect(SpeedLevel(mbps: "NaN") == nil)
}

private func record(_ id: String, download: Int = 12_500_000, latency: String = "12.345") -> OrderedJSON {
    json(#"{"type":"result","timestamp":"2026-10-27T03:04:05Z","ping":{"jitter":0.5,"latency":\#(latency)},"download":{"bandwidth":\#(download)},"upload":{"bandwidth":2500000},"packetLoss":0,"server":{"name":"Telstra","location":"Sydney"},"result":{"id":"\#(id)"}}"#)
}

@Test func speedHistoryKeepsFiftyRecordsNewestFirst() {
    let empty: [OrderedJSON] = [.object([])]
    guard case .added(let one) = InternetSpeed.adding(record("a"), to: empty, lite: false) else { Issue.record("not added"); return }
    #expect(one.count == 2 && InternetSpeed.adding(record("a"), to: one, lite: false) == .unchanged)
    var full = (0..<50).map { record("r\($0)") } + [.object([])]
    guard case .added(let replaced) = InternetSpeed.adding(record("new"), to: full, lite: false) else { Issue.record("not added"); return }
    full = replaced
    #expect(full.count == 51 && InternetSpeed.recordID(full[0]) == "new" && InternetSpeed.recordID(full[49]) == "r48")
    #expect(InternetSpeed.adding(record("b"), to: one, lite: true) == .added([record("b"), .object([])]))
    // check_duplicate_result reads result.id of every record and of the result: a missing one throws.
    #expect(InternetSpeed.adding(json(#"{"type":"result"}"#), to: one, lite: false) == .stopped)
    #expect(InternetSpeed.adding(record("c"), to: [json("{}"), .object([])], lite: false) == .stopped)
    #expect(InternetSpeed.adding(json(#"{"type":"result"}"#), to: empty, lite: false) != .stopped)
    // check_duplicate_result compares every record's id with ==: an object id with a toString member throws there even
    // when its record is not on the page shown, and nothing is written.
    let oddLater = (0..<10).map { record("r\($0)") } + [json(#"{"result":{"id":{"toString":0}}}"#), .object([])]
    #expect(InternetSpeed.adding(record("new"), to: oddLater, lite: false) == .stopped)
    #expect(InternetSpeed.adding(record("[object Object]"), to: [json(#"{"result":{"id":{}}}"#), .object([])], lite: false) == .unchanged)
    guard case .deleted(let remaining) = InternetSpeed.deleting(["r3", "zz"], from: full) else { Issue.record("not deleted"); return }
    #expect(remaining.count == full.count - 1 && !remaining.contains { InternetSpeed.recordID($0) == "r3" })
    #expect(InternetSpeed.deleting(["zz"], from: full) == .unchanged)
    // delete_history reads result.id.toString() of each record up to the match: one without it throws, after the removals
    // made so far and before anything is written.
    let broken = json(#"{"result":{}}"#)
    #expect(InternetSpeed.deleting(["b"], from: [broken, record("b"), .object([])]) == .stopped([broken, record("b"), .object([])]))
    #expect(InternetSpeed.deleting(["a", "b"], from: [record("a"), broken, record("b"), .object([])]) == .stopped([broken, record("b"), .object([])]))
    #expect(InternetSpeed.deleting(["a"], from: [record("a"), broken, .object([])]) == .deleted([broken, .object([])]))
    // toString() throws for an object with a toString member, also inside an array id; ids compare as UTF-16 units.
    let odd = json(#"{"result":{"id":{"toString":0}}}"#), nested = json(#"{"result":{"id":[1,{"toString":0}]}}"#)
    #expect(InternetSpeed.deleting(["b"], from: [odd, record("b"), .object([])]) == .stopped([odd, record("b"), .object([])]))
    #expect(InternetSpeed.deleting(["b"], from: [nested, record("b"), .object([])]) == .stopped([nested, record("b"), .object([])]))
    guard case .deleted(let kept) = InternetSpeed.deleting(["\u{e9}"], from: [record("e\u{301}"), record("\u{e9}"), .object([])]) else { Issue.record("not deleted"); return }
    #expect(kept.count == 2 && InternetSpeed.recordID(kept[0]).utf16.count == 2)
    #expect(InternetSpeed.pageRange(page: 0, count: 1) == nil)
    #expect(InternetSpeed.pageRange(page: 0, count: 11).map { [$0.start, $0.end, $0.lastPage] } == [1, 10, 0])
    #expect(InternetSpeed.pageRange(page: 1, count: 12).map { [$0.start, $0.end, $0.lastPage] } == [11, 11, 1])
    // A page past the end shows nothing, as the page does after a deletion.
    #expect(InternetSpeed.historyRows(full, page: 9, timezone: "") == InternetSpeed.HistoryRendering())
    #expect(InternetSpeed.historyText([record("x"), .object([])]).hasSuffix("\"result\":{\"id\":\"x\"}}\n"))
}

@Test func speedResultsStopWhereThePageThrows() {
    let latest = SpeedTestDisplay.latest(record("a"), timezone: "+1100", lite: false)
    #expect(!latest.stopped && latest.download == "100.00" && latest.upload == "20.00" && latest.latency == "12.35" && latest.jitter == "0.50")
    #expect(latest.level?.name == "不错" && latest.date == "2026/10/27" && latest.time == "14:04" && latest.host == "Telstra" && latest.location == "Sydney")
    // A latency that is not a number: toFixed throws after the speeds are written, before the rating.
    let text = SpeedTestDisplay.latest(record("a", latency: "\"12.3\""), timezone: "+1100", lite: false)
    #expect(text.stopped && text.download == "100.00" && text.latency == nil && text.level == nil)
    // Without a server the dates are written and the host is not.
    let serverless = SpeedTestDisplay.latest(json(#"{"timestamp":"2026-10-27T03:04:05Z","download":{"bandwidth":1},"upload":{"bandwidth":1}}"#), timezone: "+0000", lite: false)
    #expect(serverless.stopped && serverless.date == "2026/10/27" && serverless.host == nil)
    #expect(SpeedTestDisplay.latest(.null, timezone: "", lite: false) == SpeedTestDisplay(stopped: true))
    // History rows stop at the first record whose code throws; a null record draws no row.
    let rendering = InternetSpeed.historyRows([record("a"), record("b", latency: "null"), record("c"), .object([])], page: 0, timezone: "+0000")
    let rows = rendering.rows
    #expect(rendering.stopped && rows.count == 2 && rows[0].latency == "12.35" && !rows[0].stopped && rows[1].stopped && rows[1].id == "b" && rows[1].download == "100.00")
    // A null record throws before its row is drawn: no row, but drawing (and init after it) still stops.
    let nullFirst = InternetSpeed.historyRows([.null, record("c"), .object([])], page: 0, timezone: "")
    #expect(nullFirst.rows.isEmpty && nullFirst.stopped && !InternetSpeed.historyRows([record("a"), .object([])], page: 0, timezone: "").stopped)
    // The check box takes the id as its attribute: an id whose text conversion throws stops after the row is drawn.
    let oddID = SpeedTestHistoryRow(json(#"{"timestamp":"2026-10-27T03:04:05Z","result":{"id":{"toString":0}}}"#), timezone: "+0000")
    #expect(oddID.drawn && oddID.stopped && SpeedTestHistoryRow(json(#"{"timestamp":"2026-10-27T03:04:05Z","result":{}}"#), timezone: "").id == "")
    // new Date of a timestamp whose text conversion throws: no row, and the drawing stops.
    let oddTime = SpeedTestHistoryRow(json(#"{"timestamp":{"toString":0},"result":{"id":"x"}}"#), timezone: "+0000")
    #expect(!oddTime.drawn && oddTime.stopped)
}

@Test func javaScriptDatesTakeOnlyTheDateFormat() throws {
    // ASCII digits only (other decimal digits neither match nor crash), checked offsets, and the end of the text itself.
    #expect(InternetSpeed.parse("2026-\u{661}\u{660}-01T00:00:00Z").isNaN && InternetSpeed.parse("\u{662}\u{660}\u{662}\u{666}-01-01").isNaN)
    #expect(InternetSpeed.parse("2026-01-01T00:00+24:00").isNaN && InternetSpeed.parse("2026-01-01T00:00+00:60").isNaN && InternetSpeed.parse("2026-01-01\n").isNaN)
    // A local time is the earliest instant with that local time; one a transition skips takes the offset before it (V8).
    let sydney = try #require(TimeZone(identifier: "Australia/Sydney"))
    #expect(InternetSpeed.parse("2026-10-04T00:30:00", zone: sydney) == 1_791_037_800_000)
    #expect(InternetSpeed.parse("2026-10-04T02:30:00", zone: sydney) == 1_791_045_000_000)
    #expect(InternetSpeed.parse("2026-04-05T02:30:00", zone: sydney) == 1_775_316_600_000)
    #expect(InternetSpeed.parse("2026-02-29T00:00", zone: sydney) == 1_772_283_600_000)
}

@Test func speedProgressReadsTheOoklaLines() {
    let running = json(#"[{"type":"testStart","timestamp":"2026-10-27T03:04:05Z","server":{"name":"Optus","location":"Perth"}},{"type":"download","download":{"bandwidth":1250000.7}},{}]"#)
    let progress = SpeedTestProgress.read(running, timezone: "+0800", lite: false)
    #expect(progress.display.host == "Optus" && progress.display.location == "Perth" && progress.display.download == "10.00" && progress.display.time == "11:04" && progress.result == nil)
    #expect(SpeedTestProgress.read(json("[{}]"), timezone: "", lite: false).empty && SpeedTestProgress.read(nil, timezone: "", lite: false).empty)
    #expect(SpeedTestProgress.read(.string(""), timezone: "", lite: false).empty && SpeedTestProgress.read(json("{}"), timezone: "", lite: false).display.stopped)
    #expect(SpeedTestProgress.read(json(#"[{"type":"log"},{"error":"x"},{}]"#), timezone: "", lite: false).failed)
    #expect(SpeedTestProgress.read(json(#"[{"type":"log","level":"error"},{}]"#), timezone: "", lite: false).levelError)
    let done = SpeedTestProgress.read(.array([record("z"), .object([])]), timezone: "+0000", lite: false)
    #expect(done.result != nil && done.display.date == "2026/10/27" && done.display.detailDownload == "100.00" && done.display.latency == "12.35")
    // A result the page cannot format stops the reading before the history.
    let bad = SpeedTestProgress.read(.array([record("z", latency: "\"1\""), .object([])]), timezone: "+0000", lite: false)
    #expect(bad.display.stopped && bad.result == nil && bad.display.date == "2026/10/27")
    // A bandwidth whose text conversion throws stops the read before anything is taken as the result.
    let oddSpeed = SpeedTestProgress.read(json(#"[{"type":"result","timestamp":"2026-10-27T03:04:05Z","ping":{"jitter":0.5,"latency":1},"download":{"bandwidth":{"toString":0}},"upload":{"bandwidth":1},"result":{"id":"x"}},{}]"#), timezone: "", lite: false)
    #expect(oddSpeed.display.stopped && oddSpeed.result == nil)
    // The other conversions and `==` comparisons on the way turn an object into text too: a download line's parseInt,
    // the timestamp's new Date, the level and the type each stop the read before the result after them.
    let result = #""type":"result","ping":{"jitter":0.5,"latency":1},"download":{"bandwidth":1},"upload":{"bandwidth":1},"result":{"id":"x"}"#
    #expect(SpeedTestProgress.read(json(#"[{"timestamp":0,\#(result)},{}]"#), timezone: "", lite: false).result != nil)
    for lines in [#"{"type":"download","download":{"bandwidth":{"toString":0}}},{"timestamp":0,\#(result)}"#,
                  #"{"timestamp":{"toString":0},\#(result)}"#,
                  #"{"timestamp":0,"level":{"toString":0},\#(result)}"#,
                  #"{"type":{"toString":0}},{"timestamp":0,\#(result)}"#] {
        let stopped = SpeedTestProgress.read(json("[" + lines + ",{}]"), timezone: "", lite: false)
        #expect(stopped.display.stopped && stopped.result == nil)
    }
    // An array type is its text: ["result"] == "result".
    let arrayType = #"[{"type":["result"],"timestamp":0,"ping":{"jitter":0.5,"latency":1},"download":{"bandwidth":1},"upload":{"bandwidth":1},"result":{"id":"x"}},{}]"#
    #expect(SpeedTestProgress.read(json(arrayType), timezone: "", lite: false).result != nil)
    let servers = SpeedTestServer.list(json(#"[{"id":1,"name":"A&amp;B","location":"Sydney"},{"id":2,"location":"x"},{"id":3,"name":"C"},{"id":4,"name":"D","location":"Z"},{}]"#))
    #expect(servers == [SpeedTestServer(id: "1", name: "A&B", location: "Sydney")])
    #expect(SpeedTestServer.list(json(#"[{"id":1,"name":"A","location":"S"},null,{"id":2,"name":"B","location":"T"}]"#)).count == 1)
}

@Test func speedPageShowsWhatTheRouterAllows() async throws {
    var values = ["link_internet": "2", "ookla_state": "0", "vpn_client2_state": "2", "vpn_client2_desc": "Home", "wgc1_enable": "1", "wgc1_desc": "WG"]
    let page = InternetSpeedPage(values: values, support: ["openvpnd": "1", "wireguard": "1"], history: [], timezone: "+1100", linkRate: nil)
    #expect(page.interfaces.map(\.title) == ["WAN", "OVPN2: Home", "WGC1: WG"] && page.interfaces.map(\.value) == ["", "tun12", "wgc1"])
    #expect(page.history == [.object([])] && !page.showsLinkRate && page.connected && page.ispControl == .none)
    #expect(InternetSpeedPage(values: values, support: [:], history: [], timezone: "", linkRate: nil).interfaces.count == 1)
    // The link rate replaces the test only when the router cannot test that fast or an ISP controls the line.
    #expect(InternetSpeedPage(values: values, support: [:], history: [], timezone: "", linkRate: 10000).showsLinkRate)
    #expect(!InternetSpeedPage(values: values, support: ["10g_speedTest": "1"], history: [], timezone: "", linkRate: 10000).showsLinkRate)
    for (text, control) in [(#"{"ISPCtrl":"x"}"#, InternetSpeedPage.ISPControl.controlled), ("{}", .controlled), ("5", .controlled), (#"{"ISPCtrl":""}"#, .none),
                            ("", .none), ("not json", .broken), ("null", .broken)] {
        values["ispctrl_desc"] = text
        let read = InternetSpeedPage(values: values, support: ["10g_speedTest": "1"], history: [], timezone: "", linkRate: 10000)
        #expect(read.ispControl == control && read.showsLinkRate == (control == .controlled), "\(text)")
    }
    #expect(InternetSpeedPage(values: values, support: [:], history: [], timezone: "", linkRate: 10000).linkRateText! == ("10", "Gbps"))

    let router = ToolRouter(nvram: ["link_internet": "2", "ookla_state": "0"], support: ["10g_speedTest": 1],
                            hooks: ["ookla_speedtest_get_history": "[\(record("h").javaScriptJSON)\n,{}]", "uptime": "\"Mon, 27 Oct 2026 14:05:01 +1100(1 secs since boot)\"",
                                    "get_lan_hwaddr": "\"04:42:1A:00:00:01\""])
    let read = try await client(router).internetSpeedPage()
    #expect(read.timezone == "+1100" && read.records.count == 1 && read.linkRate == nil)
    #expect(SpeedTestDisplay.latest(read.history[0], timezone: read.timezone, lite: read.lite).host == "Telstra")
    // Opening the page only reads, and does not read the server list (which sets ookla_state).
    #expect(await router.actions.allSatisfy { $0.method == "GET" && !$0.path.hasPrefix("ookla") && !$0.path.hasPrefix("set_") })
    #expect(await !router.hooksAsked.contains("ookla_speedtest_get_servers()"))
    let start = try await client(router).startOokla(list: false, serverID: "42", interface: "tun12")
    let sent = await router.actions.filter { $0.method == "POST" }
    #expect(sent.map(\.path) == ["set_ookla_speedtest_start_time.cgi", "ookla_speedtest_exe.cgi"])
    #expect(sent[0].body == "ookla_start_time=" + javaScriptText(start) && sent[1].body == "type=&id=42&iface=tun12")
    _ = try await client(router).startOokla(list: true, serverID: "42", interface: "")
    #expect(await router.actions.last!.body == "type=list&id=&iface=")
    try await client(router).writeSpeedTestHistory([record("w"), .object([])])
    let written = await router.actions.last!.body
    #expect(form(written)["speedTest_history"] == record("w").javaScriptJSON + "\n" && !written.contains("%20"))
    try await client(router).setOoklaState("3")
    #expect(await router.actions.last!.body == "ookla_state=3")
}
