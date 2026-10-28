import Foundation
import Testing
@testable import RouterCore

// 网络设置向导（QIS_wizard.htm，QIS_V3）：入口分流、协议页、自动侦测、手动 WAN（DHCP、PPPoE、静态 IP、PPTP、DHCP 选项、WAN 端口）、
// 本地登录、LAN IP、无线（Smart Connect、分频、MLO、SDN 主网络与 IoT）、最终提交与固件检查。账号、密码、SSID 都是虚构的。

// MARK: - A router for the wizard

/// nvram_char_to_ascii's answer: every byte but ASCII letters and digits as %XX.
private func ascii(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")) ?? value
}

/// Answers appGet hooks (nvram_char_to_ascii, nvram_default_get, get_ui_support and the hooks given as JSON text), the policy
/// CGIs, chpass.cgi and applyapp.cgi like the router; applyapp writes wan_ names under the wan_unit it carries. Records every
/// request with its query and body as sent. Agreeing to the privacy statement keeps get_ui_support's asus_pp (the version
/// offered) with a time, not the "1" sent; `failing` answers HTTP 500 to a request whose path and query contain one of its
/// texts (or the status given); `hold` keeps the next matching request waiting until `release`.
private actor QISRouter: RouterTransport {
    var nvram: [String: String]
    var defaults: [String: String]
    let support: String
    var hooks: [String: String]
    var pp: String
    var ppTime: String
    /// What set_ASUS_privacy_policy.cgi?ASUS_privacy_policy=1 keeps instead of the version offered.
    var ppKept: String?
    /// Texts of requests answered with an HTTP error instead, and that status.
    var failing: [String: Int] = [:]
    /// Texts of requests whose connection never opens (URLError.cannotConnectToHost).
    var unreachable: [String] = []
    private var holding: String?
    private var held: CheckedContinuation<Void, Never>?
    private var heldWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private(set) var requests: [(method: String, path: String, query: String, body: String)] = []

    init(nvram: [String: String], support: String, hooks: [String: String] = [:], defaults: [String: String] = [:], pp: String = "4", ppTime: String = "2025-01-01 00:00:00") {
        self.nvram = nvram; self.support = support; self.hooks = hooks; self.defaults = defaults; self.pp = pp; self.ppTime = ppTime
    }

    private func reply(_ text: String) -> RouterHTTPResponse { RouterHTTPResponse(data: Data(text.utf8), status: 200) }

    func send(_ request: URLRequest) async throws -> RouterHTTPResponse {
        guard let url = request.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw RouterError.network("no url") }
        let path = String(url.path.drop { $0 == "/" })
        let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        requests.append((request.httpMethod ?? "GET", path, parts.percentEncodedQuery ?? "", body))
        let line = path + "?" + (parts.percentEncodedQuery ?? "")
        if let holding, line.contains(holding) {
            self.holding = nil
            await withCheckedContinuation { held = $0; heldWaiters.values.forEach { $0.resume() }; heldWaiters = [:] }
        }
        if let status = failing.first(where: { line.contains($0.key) })?.value { return RouterHTTPResponse(data: Data("error".utf8), status: status) }
        if unreachable.contains(where: { line.contains($0) }) { throw URLError(.cannotConnectToHost) }
        let item = { (name: String) in parts.queryItems?.first { $0.name == name }?.value ?? "" }
        switch path {
        case "appGet.cgi":
            var answers: [String] = []
            for call in item("hook").split(separator: ";").map(String.init) {
                guard let open = call.firstIndex(of: "(") else { continue }
                let name = String(call[..<open])
                let arguments = call[call.index(after: open)..<call.index(before: call.endIndex)].split(separator: ",").map(String.init)
                switch name {
                case "nvram_char_to_ascii": answers.append("\"\(arguments[0])\":\"" + ascii(nvram[arguments[0]] ?? "") + "\"")
                case "nvram_default_get": answers.append("\"\(arguments[0])\":\"" + aspNvramText(Array((defaults[arguments[0]] ?? "").utf8)) + "\"")
                case "get_ui_support": answers.append("\"get_ui_support\":" + support)
                case "start_force_autodet", "restart_auto46det": answers.append("\"\(name)\":\"Success\"")
                default: if let answer = hooks[name] { answers.append("\"\(name)\":" + answer) }
                }
            }
            return reply("{\n" + answers.joined(separator: ",\n") + "\n}\n")
        case "applyapp.cgi":
            let object = try OrderedJSON(data: Data((body.removingPercentEncoding ?? "").utf8))
            let unit = object["wan_unit"]?.text
            for (key, value) in object.members where !["action_mode", "rc_service", "skip_modify_flag", "http_username", "http_passwd", "wan_unit"].contains(key) {
                if key.hasPrefix("wan_"), let unit { nvram["wan\(unit)_" + key.dropFirst(4)] = value.text } else { nvram[key] = value.text }
            }
            let service = object["rc_service"]?.text ?? ""
            return reply(service.isEmpty ? #"{"modify":"1"}"# : #"{"modify":"1","run_service":"\#(service)"}"#)
        case "get_ASUS_privacy_policy.cgi": return reply(#"{"ASUS_privacy_policy":"\#(pp)","ASUS_privacy_policy_time":"\#(ppTime)"}"#)
        case "set_ASUS_privacy_policy.cgi":
            let offered = (try? OrderedJSON(data: Data(support.utf8)))?["asus_pp"]?.text ?? ""
            pp = item("ASUS_privacy_policy") == "1" ? (ppKept ?? offered) : "0"
            ppTime = "2026-10-28 10:00:00"
            return reply(#"{"statusCode":"200"}"#)
        case "set_ASUS_NEW_EULA.cgi": nvram["ASUS_NEW_EULA"] = item("ASUS_NEW_EULA"); nvram["ASUS_NEW_EULA_time"] = "2026-10-28 10:00:00"; return reply("{}")
        case "set_security_update.cgi": nvram["security_update"] = item("security_update"); return reply("")
        case "get_security_update.cgi": return reply(#"{"security_update":\#(nvram["security_update"] ?? "0")}"#)
        case "chpass.cgi": return reply(#"{"statusCode":"200"}"#)
        default: return RouterHTTPResponse(data: Data(), status: 404)
        }
    }
    nonisolated func cancel() {}
    func set(_ key: String, _ value: String) { nvram[key] = value }
    func fail(_ texts: [String], status: Int = 500) { for text in texts { failing[text] = status } }
    func recover(_ texts: [String]) { for text in texts { failing[text] = nil } }
    func cannotConnect(_ texts: [String]) { unreachable += texts }
    func keep(privacy value: String) { ppKept = value }
    func hold(_ text: String) { holding = text }
    /// Returns once a request is waiting at the hold, or when the waiting test is cancelled (its time limit).
    func waitUntilHeld() async {
        guard held == nil else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { heldWaiters[id] = $0 }
        } onCancel: {
            Task { await self.stopWaiting(id) }
        }
    }
    private func stopWaiting(_ id: UUID) { heldWaiters.removeValue(forKey: id)?.resume() }
    func release() { held?.resume(); held = nil }
    /// The writes and actions: every request but the reads (start_force_autodet and restart_auto46det count).
    var writes: [(method: String, path: String, query: String, body: String)] {
        requests.filter { $0.path != "appGet.cgi" && !$0.path.hasPrefix("get_") || $0.query.contains("start_force_autodet") || $0.query.contains("restart_auto46det") }
    }
    func count(_ text: String) -> Int { requests.filter { ($0.path + "?" + $0.query).contains(text) }.count }
    /// applyapp bodies as JSON.stringify wrote them.
    var posts: [String] { requests.filter { $0.path == "applyapp.cgi" }.map { $0.body.removingPercentEncoding ?? "" } }
}

private let basePassword = "Kx8#vR2nQp"
/// A configured RT-BE88U-like router: router mode, Ethernet WAN on DHCP and online, dual band, Smart Connect on, MLO.
private let base: [String: String] = [
    "ASUS_NEW_EULA": "1", "ASUS_NEW_EULA_time": "2025-01-01 00:00:00", "TM_EULA": "0", "TM_EULA_time": "", "preferred_lang": "CN",
    "ASUS_PP_AutoWebUpgradeDisable": "0", "sw_mode": "1", "wlc_psta": "0", "wlc_dpsta": "0", "wlc_band": "", "wl_ifnames": "eth6 eth7",
    "wlnband_list": "2g1<5g1", "wl_version": "17.10.369", "productid": "RT-BE88U", "odmpid": "", "amas_bdlkey": "", "amas_bdl": "",
    "rc_support": "2.4G 5G mssid update utf8_ssid", "x_Setting": "1", "territory_code": "AU/01", "ipv6_service": "disabled", "reboot_time": "120",
    "lan_ipaddr": "192.168.50.1", "lan_proto": "static", "lan_dnsenable_x": "1", "lan_netmask": "255.255.255.0", "lan_gateway": "", "lan_dns1_x": "", "lan_dns2_x": "",
    "CoBrand": "", "wans_dualwan": "wan none", "wans_extwan": "0", "wans_mode": "fo", "dslx_transmode": "",
    "smart_connect_x": "1", "smart_connect_selif_x": "3", "mld_enable": "1", "dwb_mode": "0", "dwb_band": "",
    "wan_proto": "dhcp", "wan_pppoe_username": "", "wan_pppoe_passwd": "", "wan_heartbeat_x": "", "wan_ipaddr_x": "0.0.0.0", "wan_netmask_x": "0.0.0.0",
    "wan_gateway_x": "0.0.0.0", "wan_dns1_x": "", "wan_dns2_x": "", "wan_vendorid": "", "wan_clientid_type": "0", "wan_clientid": "",
    "wan0_proto": "dhcp", "wan0_pppoe_username": "", "wan0_pppoe_passwd": "", "wan0_dnsenable_x": "1", "wan0_heartbeat_x": "", "wan0_ipaddr_x": "0.0.0.0",
    "wan0_netmask_x": "0.0.0.0", "wan0_gateway_x": "0.0.0.0", "wan0_dns1_x": "", "wan0_dns2_x": "",
    "wan0_state_t": "2", "wan0_sbstate_t": "0", "wan0_auxstate_t": "0", "link_internet": "2", "link_wan": "1", "autodet_state": "", "autodet_auxstate": "",
    "usb_modem_act_sim": "", "wan1_state_t": "", "wan1_sbstate_t": "", "wan1_auxstate_t": "", "switch_wantag": "none", "wandog_interval": "5",
    "wl0_ssid": "Harbor", "wl0_wpa_psk": basePassword, "wl0_auth_mode_x": "psk2sae", "wl0_crypto": "aes", "wl0_mfp": "1", "wl0_11be": "1",
    "wl1_ssid": "Harbor_5G", "wl1_wpa_psk": basePassword, "wl1_auth_mode_x": "psk2sae", "wl1_crypto": "aes", "wl1_mfp": "1", "wl1_11be": "1",
    "http_username": "admin_example", "webs_chg_sku": "0", "webs_SG_mode": "0", "SG_mode": "0", "wl_mlo_config": "1",
    "firmver": "3.0.0.6", "buildno": "102", "extendno": "5", "et0macaddr": "02:00:00:00:00:01"
]
private let baseSupport = #"{"mlo":1,"amas":1,"smart_connect_v2":1,"bcmwifi":1,"dualband":1,"11AX":1,"qis_hide_he_features":1,"MaxLen_http_passwd":32}"#
private let baseHooks = ["get_operation_mode": #""rt""#, "check_pw": #""0""#, "get_feat_def": "{}", "get_ethernet_wan_list": "{}", "show_usb_path": "[]"]

private func router(_ extra: [String: String] = [:], support: String = baseSupport, hooks: [String: String] = [:], defaults: [String: String] = [:],
                    pp: String = "4", ppTime: String = "2025-01-01 00:00:00") -> QISRouter {
    QISRouter(nvram: base.merging(extra) { $1 }, support: support, hooks: baseHooks.merging(hooks) { $1 }, defaults: defaults, pp: pp, ppTime: ppTime)
}
private func client(_ router: QISRouter) throws -> RouterClient { RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: router, writes: .reference) }

/// Runs an event that must only change the page.
private func step(_ c: RouterClient, _ w: QISWizard, _ event: QISEvent, sourceLocation: SourceLocation = #_sourceLocation) async throws -> QISWizard {
    let outcome = try await c.qis(w, event)
    guard case .updated(let next) = outcome else { Issue.record("expected a page change, got \(outcome)", sourceLocation: sourceLocation); return w }
    return next
}
/// Runs an event that must ask to send requests.
private func submission(_ c: RouterClient, _ w: QISWizard, _ event: QISEvent, sourceLocation: SourceLocation = #_sourceLocation) async throws -> QISSubmission {
    let outcome = try await c.qis(w, event)
    guard case .submit(let s) = outcome else { Issue.record("expected requests, got \(outcome)", sourceLocation: sourceLocation); throw RouterError.validation("no submission") }
    return s
}

// MARK: - Entry and routing (QIS_wizard.htm 76–313)

@Test func startRoutesByPolicyThenFlag() async throws {
    // The EULA first when it is not agreed or has no time.
    #expect(try await client(router(["ASUS_NEW_EULA": "0"])).qisStart().page.id == "policy_page")
    if case .eula = try await client(router(["ASUS_NEW_EULA": "0"])).qisStart().page {} else { Issue.record("EULA page expected") }
    // goTo.EULA reads the status again: an agreed EULA with an empty time goes on to the privacy statement.
    if case .privacy = try await client(router(["ASUS_NEW_EULA_time": ""])).qisStart().page {} else { Issue.record("privacy page expected") }
    // The statement when it was agreed in version 1, or never answered (PP 0 with no time).
    if case .privacy = try await client(router(pp: "1")).qisStart().page {} else { Issue.record("privacy page expected for PP 1") }
    if case .privacy = try await client(router(pp: "0", ppTime: "")).qisStart().page {} else { Issue.record("privacy page expected for PP 0") }
    // A statement refused before (PP 0 with a time) lets the flag decide.
    #expect(try await client(router(pp: "0", ppTime: "2025-02-02 00:00:00")).qisStart().page == .welcome)

    let flags: [(String, QISPage)] = [("", .welcome), ("manual", .opMode), ("pppoe", .account), ("wireless", .wireless), ("mlo", .wireless),
                                      ("changePass", .login), ("lanip", .getLanIP), ("rtMode", .wanSetting), ("sitesurvey_rep", .browser(.repeater)),
                                      ("sitesurvey_mb", .browser(.mediaBridge)), ("wispMode", .browser(.wisp)), ("site2site", .browser(.siteToSite)),
                                      ("amasnode_page", .browser(.aimesh("amasnode_page"))), ("amas_addNode", .browser(.aimesh("amassearch_page")))]
    for (flag, page) in flags {
        let w = try await client(router()).qisStart(flag: flag)
        #expect(w.page == page, "flag \(flag)")
    }
    // EULA and PP flags open the policy pages even when both are agreed.
    if case .privacy = try await client(router()).qisStart(flag: "EULA").page {} else { Issue.record("EULA flag: agreed EULA goes on to PP") }
    if case .privacy = try await client(router()).qisStart(flag: "PP").page {} else { Issue.record("PP flag") }
    // The branches the app leaves to the router keep the flag that reaches them.
    #expect(try await client(router()).qisStart(flag: "sitesurvey_rep").browserFlag == "sitesurvey_rep")
    #expect(try await client(router()).qisStart(flag: "amas_addNode").browserFlag == "amas_addNode")
    // A router not set up yet (x_Setting 0 or empty) is left to the router's wizard.
    #expect(try await client(router(["x_Setting": "0"])).qisStart().page == .browser(.factoryDefault))
    #expect(try await client(router(["x_Setting": ""])).qisStart().page == .browser(.factoryDefault))
}

@Test func startReadsWithoutWritingAndQueuesTheWelcomeEffects() async throws {
    let r = router()
    let w = try await client(r).qisStart()
    // Only reads went out: appGet hooks and the privacy statement's state.
    #expect(await r.writes.isEmpty)
    // goTo.Welcome (2787–2843): start_force_autodet at once, the firmware check a second later — both left for the user.
    #expect(w.effects == [.autoDetect, .liveUpdate])
    #expect(w.screen.title == "欢迎使用 RT-BE88U")
    #expect(w.screen.choices.map(\.id) == ["create", "advanced"])
    // Japan with IPv6 adds restart_auto46det first.
    let japan = try await client(router(["territory_code": "JP/01", "ipv6_service": "ipv6pt"], support: #"{"s46":1}"#)).qisStart()
    #expect(japan.effects == [.auto46Detect, .autoDetect, .liveUpdate])
    // The effects go out only through qisSend(effect:), as the page sends them.
    let c = try client(r)
    try await c.qisSend(effect: .autoDetect)
    let sent = await r.requests.last!
    #expect(sent.method == "GET" && sent.path == "appGet.cgi" && sent.query == "hook=start_force_autodet()")
}

@Test func handleSysDepDetectionMayAskToRestartDetection() async throws {
    // detwanGetRet without a state it knows: detRetryCnt is undefined at first, so the page calls startAutoDet (656–673).
    let w = try await client(router(["wan0_state_t": "1", "wan0_sbstate_t": "0", "link_internet": "0"])).qisStart(flag: "wireless")
    #expect(w.effects == [.autoDetect])
    // autodet_state 4 with the auxstate not 1 asks for it too; a known state does not.
    #expect(try await client(router(["wan0_state_t": "1", "autodet_state": "4", "wan0_auxstate_t": "0"])).qisStart(flag: "wireless").effects == [.autoDetect])
    #expect(try await client(router()).qisStart(flag: "wireless").effects.isEmpty)
}

// MARK: - Policy pages (asus_policy.js 2449–2592)

@Test func eulaNeedsTheAgeBoxThenAgreesAsThePage() async throws {
    let r = router(["ASUS_NEW_EULA": "0"])
    let c = try client(r)
    var w = try await c.qisStart()
    #expect(w.screen.title == "最终用户许可协议" && w.screen.next == "同意" && w.screen.back == nil)
    #expect(w.policyDocument != nil)
    w = try await step(c, w, .next)
    #expect(w.alerts == ["请确认您已满 16 岁。"])
    w = try await step(c, w, .toggle("eulaAge", true))
    let s = try await submission(c, w, .next)
    #expect(s.requests == [.get("set_ASUS_NEW_EULA.cgi", [("ASUS_NEW_EULA", "1")], json: true)])
    let receipt = try await c.qisSubmit(s)
    let sent = await r.writes
    #expect(sent.map(\.path) == ["set_ASUS_NEW_EULA.cgi"] && sent[0].method == "GET" && sent[0].query == "ASUS_NEW_EULA=1")
    // newEula.set's callback: goTo.PP, which reads the status again.
    if case .privacy? = receipt.state?.page {} else { Issue.record("privacy page expected after the EULA") }
    #expect(receipt.verified == ["ASUS_NEW_EULA"] && receipt.unverified.isEmpty)
}

/// get_ui_support offering statement v4, never answered (PP 0 without a time): the privacy page with v4's text.
private let ppSupport = #"{"mlo":1,"amas":1,"smart_connect_v2":1,"bcmwifi":1,"dualband":1,"11AX":1,"qis_hide_he_features":1,"MaxLen_http_passwd":32,"asus_pp":4}"#
private func unansweredPrivacy(_ extra: [String: String] = [:]) -> QISRouter { router(extra, support: ppSupport, pp: "0", ppTime: "") }

@Test func privacyAgreeSendsTheChainThenWelcome() async throws {
    let r = unansweredPrivacy()
    let c = try client(r)
    let w = try await c.qisStart()
    #expect(w.screen.title == "ASUS隐私声明" && w.screen.back == "拒绝" && w.screen.next == "同意" && w.policyDocument != nil)
    let s = try await submission(c, w, .next)
    #expect(s.privacyVersion == "4")
    let receipt = try await c.qisSubmit(s)
    let sent = await r.writes
    #expect(sent.map { "\($0.method) \($0.path)?\($0.query)" } == ["GET set_ASUS_privacy_policy.cgi?ASUS_privacy_policy=1", "GET set_security_update.cgi?security_update=1",
                                                                  "POST applyapp.cgi?"])
    // webs_update_enable is the number 1 in the page's object (2503–2508).
    #expect(await r.posts == [#"{"webs_update_enable":1,"action_mode":"apply","rc_service":"saveNvram","skip_modify_flag":"1"}"#])
    #expect(receipt.state?.page == .welcome)
    #expect(receipt.state?.effects == [.autoDetect, .liveUpdate])
    // The read-back finds the version the page showed with a signing time, and the security update on through
    // get_security_update.cgi.
    #expect(Set(receipt.verified) == ["ASUS_privacy_policy", "security_update", "webs_update_enable"] && receipt.unverified.isEmpty)
    #expect(await r.count("get_security_update.cgi") == 1)

    // With ASUS_PP_AutoWebUpgradeDisable "1" the automatic upgrade is left alone.
    let quiet = unansweredPrivacy(["ASUS_PP_AutoWebUpgradeDisable": "1"])
    let q = try client(quiet)
    _ = try await q.qisSubmit(try await submission(q, try await q.qisStart(), .next))
    #expect(await quiet.posts.isEmpty)
}

@Test func privacyReadBackLooksForTheSignedVersionNotTheValueSent() async throws {
    // A router keeping the "1" that was sent has not signed the version shown.
    let verbatim = unansweredPrivacy()
    await verbatim.keep(privacy: "1")
    let v = try client(verbatim)
    let kept = try await v.qisSubmit(try await submission(v, try await v.qisStart(), .next))
    #expect(kept.unverified == ["ASUS_privacy_policy"] && kept.verified.contains("security_update"))
    // The security update: a router that did not take it, and a read of it that fails, are not verified.
    let off = unansweredPrivacy()
    await off.fail(["set_security_update.cgi"])
    let o = try client(off)
    let offReceipt = try await o.qisSubmit(try await submission(o, try await o.qisStart(), .next))
    #expect(offReceipt.unverified == ["security_update"] && offReceipt.verified.contains("ASUS_privacy_policy"))
    let unread = unansweredPrivacy()
    let u = try client(unread)
    let start = try await u.qisStart()
    await unread.fail(["get_security_update.cgi"])
    #expect(try await u.qisSubmit(try await submission(u, start, .next)).unverified == ["security_update"])
}

@Test func privacyRefusalShowsTheNoticeAndKnowRiskWithdraws() async throws {
    let r = unansweredPrivacy()
    let c = try client(r)
    var w = try await c.qisStart()
    w = try await step(c, w, .choose("disagree"))
    #expect(w.form.withdrawing)
    // 再次阅读 only closes the notice.
    #expect(try await step(c, w, .choose("readAgain")).form.withdrawing == false)
    let s = try await submission(c, w, .choose("knowRisk"))
    #expect(s.requests == [.get("set_ASUS_privacy_policy.cgi", [("ASUS_privacy_policy", "0")], json: true)])
    let receipt = try await c.qisSubmit(s)
    #expect(await r.writes.map(\.query) == ["ASUS_privacy_policy=0"])
    #expect(receipt.state?.page == .welcome)
    // Withdrawn: 0 with a time.
    #expect(receipt.verified == ["ASUS_privacy_policy"] && receipt.unverified.isEmpty)
    // A read that fails is not taken as 0 (privateEula.get's own default).
    let unread = unansweredPrivacy()
    let u = try client(unread)
    let refusing = try await step(u, try await u.qisStart(), .choose("disagree"))
    await unread.fail(["get_ASUS_privacy_policy.cgi"])
    #expect(try await u.qisSubmit(try await submission(u, refusing, .choose("knowRisk"))).unverified == ["ASUS_privacy_policy"])
}

@Test func privacyVersionWithoutTextSendsNothing() async throws {
    // PP 1 with a time asks again (asksPrivacyAfterEULA), for version 1, which asus_policy.js has no text for.
    let r = router(pp: "1")
    let c = try client(r)
    var w = try await c.qisStart()
    guard case .privacy(let status) = w.page else { Issue.record("privacy page expected"); return }
    #expect(status.privacyVersion == "1" && w.policyDocument == nil)
    #expect(w.screen.next == nil && w.screen.back == nil && w.screen.notes.first?.contains("v1") == true)
    let before = await r.requests.count
    for event: QISEvent in [.next, .choose("disagree"), .choose("knowRisk"), .choose("readAgain"), .back] {
        let next = try await step(c, w, event)
        #expect(next.page == w.page && !next.form.withdrawing, "\(event)")
        w = next
    }
    // Not a single request: no agreement, no withdrawal, no reads.
    #expect(await r.requests.count == before)
}

// MARK: - Detection (goTo.autoWan, goTo.Waiting, goTo.NoWan)

@Test func createFollowsTheDetection() async throws {
    // Online: straight to Wireless, with cfg_master for AiMesh.
    var c = try client(router())
    var w = try await step(c, try await c.qisStart(), .choose("create"))
    #expect(w.page == .wireless && w.post.has("cfg_master"))
    // A DHCP lease without internet: the waiting page, which counts to wandog_interval and then goes manual.
    let dhcp = router(["link_internet": "0"])
    c = try client(dhcp)
    w = try await step(c, try await c.qisStart(), .choose("create"))
    #expect(w.page == .waiting && w.pollInterval == 1)
    for _ in 0..<6 { w = try await step(c, w, .tick) }
    #expect(w.page == .waiting)
    w = try await step(c, w, .tick)
    #expect(w.page == .wanSetting)
    // Coming online meanwhile goes to Wireless.
    let online = router(["link_internet": "0"])
    c = try client(online)
    w = try await step(c, try await c.qisStart(), .choose("create"))
    await online.set("link_internet", "2")
    w = try await step(c, w, .tick)
    #expect(w.page == .wireless)
    // No cable: noWan_page, whose 手动设置 goes to the WAN types.
    c = try client(router(["link_wan": "0"]))
    w = try await step(c, try await c.qisStart(), .choose("create"))
    #expect(w.page == .noWan && w.screen.paragraphs == ["请将网络线接上 WAN 接口。系统将会自动侦测你的网络设定。"])
    #expect(try await step(c, w, .choose("manual")).page == .wanSetting)
    // A PPPoE server found: the account page.
    c = try client(router(["link_internet": "0", "autodet_state": "6"]))
    #expect(try await step(c, try await c.qisStart(), .choose("create")).page == .account)
}

// MARK: - Manual WAN and the WAN restart before Wireless

@Test func dhcpChangeRestartsTheWANWithTheWholeObject() async throws {
    let r = router(["wan0_proto": "pppoe", "wan_proto": "pppoe", "link_internet": "0"])
    let c = try client(r)
    var w = try await step(c, try await c.qisStart(), .choose("create"))
    #expect(w.page == .waiting)
    w = try await step(c, w, .choose("manual"))
    #expect(w.page == .wanSetting)
    #expect(w.screen.choices.map(\.id) == ["dhcp", "pppoe", "static", "pptp", "l2tp"])
    #expect(w.screen.toggles.map(\.id) == ["iptv", "dhcpOption"])
    let s = try await submission(c, w, .choose("dhcp"))
    // apply.dhcp (352–361): qisPostData itself, which keeps action_mode and rc_service, then Wireless without waiting.
    #expect(s.requests.count == 1 && s.state.page == .wireless && s.title == "按网页提交并重新启动 WAN？")
    let receipt = try await c.qisSubmit(s)
    #expect(await r.posts == [#"{"cfg_master":"1","wan_unit":0,"wan_proto":"dhcp","wan_dhcpenable_x":"1","wan_dnsenable_x":"1","action_mode":"apply","rc_service":"restart_wan_if 0"}"#])
    #expect(Set(receipt.verified) == ["cfg_master", "wan0_proto", "wan0_dhcpenable_x", "wan0_dnsenable_x"] && receipt.unverified.isEmpty)
    #expect(receipt.state?.restartWANDone == true)

    // The final object keeps action_mode and rc_service where the WAN restart put them; restart_wan_if is not asked again.
    let final = try await submission(c, receipt.state!, .next)
    _ = try await c.qisSubmit(final)
    let posts = await r.posts
    #expect(posts.count == 2)
    #expect(posts[1] == #"{"cfg_master":"1","wan_unit":0,"wan_proto":"dhcp","wan_dhcpenable_x":"1","wan_dnsenable_x":"1","action_mode":"apply","rc_service":"restart_wireless;restart_cfgsync","x_Setting":"1","w_Setting":"1","qis_Setting":"1","smart_connect_x":1,"smart_connect_selif_x":3,"wl0_ssid":"Harbor","wl0_wpa_psk":"Kx8#vR2nQp","wl0_crypto":"aes","wl0_11be":"1","wl0_radio":"1","wl0_timesched":"0","wl0_auth_mode_x":"psk2sae","wl0_mfp":"1","wl1_ssid":"Harbor","wl1_wpa_psk":"Kx8#vR2nQp","wl1_crypto":"aes","wl1_11be":"1","wl1_radio":"1","wl1_timesched":"0","wl1_auth_mode_x":"psk2sae","wl1_mfp":"1"}"#)
    // The body is encodeURIComponent of it.
    #expect(await r.requests.last { $0.path == "applyapp.cgi" }!.body.contains("Kx8%23vR2nQp"))
}

@Test func dhcpWithoutChangeSendsNothingBeforeWireless() async throws {
    let c = try client(router(["link_internet": "0"]))
    var w = try await step(c, try await c.qisStart(), .choose("create"))
    w = try await step(c, w, .choose("manual"))
    // The WAN is on DHCP already: goTo.DHCP adds nothing and isWANChanged is false.
    let next = try await step(c, w, .choose("dhcp"))
    #expect(next.page == .wireless && !next.post.has("wan_proto"))
}

@Test func pppoeFlagPrefillsChecksAndRestartsWithDnsmasq() async throws {
    let r = router(["wan0_pppoe_username": "old@isp.example"])
    let c = try client(r)
    var w = try await c.qisStart(flag: "pppoe")
    #expect(w.page == .account && w.form.value(.pppoeUsername) == "old@isp.example")
    #expect(w.screen.fields.map(\.title) == ["PPPoE 用户名", "PPPoE 密码"])
    w.edit(.pppoePassword, "")
    w = try await step(c, w, .next)
    #expect(w.hints == [.pppoePassword: "栏位不能为空白"])
    w.edit(.pppoeUsername, "user@isp.example")
    w.edit(.pppoePassword, "Pq4!mZ8w")
    let s = try await submission(c, w, .next)
    _ = try await c.qisSubmit(s)
    #expect(await r.posts == [#"{"wan_unit":0,"wan_proto":"pppoe","wan_dhcpenable_x":"1","wan_dnsenable_x":"1","wan_pppoe_username":"user@isp.example","wan_pppoe_passwd":"Pq4!mZ8w","action_mode":"apply","rc_service":"restart_wan_if 0;restart_dnsmasq"}"#])
    // abort.pppoe with flag pppoe: window.history.back().
    let back = try await c.qis(try await c.qisStart(flag: "pppoe"), .back)
    guard case .leave(.back, _) = back else { Issue.record("history.back expected"); return }
}

@Test func staticChecksTheGatewayAndRestarts() async throws {
    let r = router(["link_internet": "0"])
    let c = try client(r)
    var w = try await step(c, try await c.qisStart(), .choose("create"))
    w = try await step(c, w, .choose("manual"))
    w = try await step(c, w, .choose("static"))
    #expect(w.page == .staticIP && w.form.value(.staticIP) == "" && w.screen.fields.allSatisfy { $0.ipFilter && $0.maxLength == 15 })
    w = try await step(c, w, .next)
    #expect(Set(w.hints.keys) == [.staticIP, .staticMask, .staticGateway, .staticDNS1])
    w.edit(.staticIP, "203.0.113.20"); w.edit(.staticMask, "255.255.255.0"); w.edit(.staticGateway, "203.0.113.20"); w.edit(.staticDNS1, "1.1.1.1")
    w = try await step(c, w, .next)
    #expect(w.hints[.staticIP] == "你已将互联网IP设置为网关IP，RT-BE88U 也许因此无法正确的连接到互联网，请重新设置正确的网关IP。")
    w.edit(.staticGateway, "203.0.113.1")
    let s = try await submission(c, w, .next)
    _ = try await c.qisSubmit(s)
    #expect(await r.posts == [#"{"cfg_master":"1","wan_dhcpenable_x":"0","wan_dnsenable_x":"0","wan_ipaddr_x":"203.0.113.20","wan_netmask_x":"255.255.255.0","wan_gateway_x":"203.0.113.1","wan_dns1_x":"1.1.1.1","wan_dns2_x":"","wan_unit":0,"wan_proto":"static","action_mode":"apply","rc_service":"restart_wan_if 0"}"#])
    #expect(await r.nvram["wan0_ipaddr_x"] == "203.0.113.20")
}

@Test func pptpGoesThroughTheIPPageAndTheDHCPOption() async throws {
    let r = router(["link_internet": "0"])
    let c = try client(r)
    var w = try await step(c, try await c.qisStart(), .choose("create"))
    w = try await step(c, w, .choose("manual"))
    w = try await step(c, w, .toggle("dhcpOption", true))
    w = try await step(c, w, .choose("pptp"))
    #expect(w.page == .account && w.screen.fields.map(\.id) == [.pppoeUsername, .pppoePassword, .vpnServer])
    w = try await step(c, w, .next)
    #expect(w.hints.count == 3)
    w.edit(.pppoeUsername, "vpnuser"); w.edit(.pppoePassword, "Pq4!mZ8w"); w.edit(.vpnServer, "vpn.isp.example")
    w = try await step(c, w, .next)
    #expect(w.page == .getIP)
    // 动态 IP with the DHCP option box ticked on the WAN page: the DHCP option page (apply.dhcp 330–331).
    w = try await step(c, w, .choose("dhcp"))
    #expect(w.page == .dhcpOption)
    w.edit(.vendorID, "vendor-x")
    w = try await step(c, w, .toggle("clientIDType", true))
    #expect(w.screen.fields.first { $0.id == .clientID }?.enabled == false)
    let s = try await submission(c, w, .next)
    _ = try await c.qisSubmit(s)
    // apply.wan_dhcp_option sets wan_proto to dhcp (701–705), and wan_clientid_type is a number.
    #expect(await r.posts == [#"{"cfg_master":"1","wan_unit":0,"wan_proto":"dhcp","wan_pppoe_username":"vpnuser","wan_pppoe_passwd":"Pq4!mZ8w","wan_heartbeat_x":"vpn.isp.example","wan_dhcpenable_x":"1","wan_dnsenable_x":"1","wan_vendorid":"vendor-x","wan_clientid_type":1,"wan_clientid":"","action_mode":"apply","rc_service":"restart_wan_if 0"}"#])
}

@Test func wanPortsFromTheRouterListSetTheirExtraSettings() async throws {
    let list = #"{"wan":{"wan_name":"10G WAN","extra_settings":{"wans_extwan":"0","wans_dualwan":"wan none"}},"wan2":{"wan_name":"2.5G WAN","extra_settings":{"wans_extwan":"1","wans_dualwan":"wan none"}}}"#
    let r = router(["link_internet": "0"], support: #"{"mlo":1,"smart_connect_v2":1,"bcmwifi":1,"dualband":1,"autowan":1}"#, hooks: ["get_ethernet_wan_list": list])
    let c = try client(r)
    var w = try await step(c, try await c.qisStart(), .choose("create"))
    w = try await step(c, w, .choose("manual"))
    #expect(w.page == .wanOption)
    #expect(w.screen.choices.map(\.title) == ["10G WAN", "2.5G WAN"])
    #expect(w.screen.notes == ["WAN 自动检测功能将被停用。 请确保您的 WAN 线正确插入选定的端口。"])
    w = try await step(c, w, .choose("eth:wan2"))
    #expect(w.page == .wanSetting)
    #expect(w.post.text("wans_extwan") == "1" && w.post.text("autowan_enable") == "0")
    // 上一步 takes the port's settings and autowan_enable out again (abort.wan 1982–2004).
    w = try await step(c, w, .back)
    #expect(w.page == .wanOption && !w.post.has("wans_extwan") && !w.post.has("autowan_enable"))
    // With a port chosen the final change of WAN/LAN makes the router reboot (getRestartService 1783–1786).
    w = try await step(c, w, .choose("eth:wan2"))
    w = try await step(c, w, .choose("dhcp"))
    let s = try await submission(c, w, .next)
    #expect(s.restart == .reboot && s.requests.last?.service == "reboot")
}

// MARK: - Login (apply.login 136–292)

@Test func loginChecksAsThePage() async throws {
    let c = try client(router())
    var w = try await c.qisStart(flag: "changePass")
    #expect(w.screen.title == "登录" && w.screen.fields.map(\.maxLength) == [32, 33, 33])
    #expect(w.post.members.map { $0.name } == ["http_username", "http_passwd"])
    func hint(_ user: String, _ password: String, _ confirmation: String) async throws -> String? {
        var x = w
        x.edit(.username, user); x.edit(.password, password); x.edit(.passwordConfirm, confirmation)
        let next = try await step(c, x, .next)
        return next.hints[.username] ?? next.hints[.password] ?? next.hints[.passwordConfirm]
    }
    #expect(try await hint("", "", "") == "栏位不能为空白")
    #expect(try await hint("a", "Rt8!vQ2#mL", "Rt8!vQ2#mL") == "您的登录名称长度太短啰! 这样很不安全。")
    #expect(try await hint("-admin", "Rt8!vQ2#mL", "Rt8!vQ2#mL") == "路由器登录名仅允许使用字母与数字、下划线和横线。首字符不能为 \"-\" 或 \"_\"。")
    #expect(try await hint("root", "Rt8!vQ2#mL", "Rt8!vQ2#mL") == "用户帐号不能为'root','guest','anonymous' 请输入有效的帐号名称！")
    #expect(try await hint("home1", "home1", "home1") == "登录用户名和密码不得相同。")
    #expect(try await hint("home-admin", "Rt8!vQ2#mL", "Rt8!vQ2#mX") == "密码应匹配。")
    #expect(try await hint("home-admin", "admin", "admin") == "新密码与系统默认密码相同，强烈建议您设置一个更严谨的密码。")
    #expect(try await hint("home-admin", "abc", "abc") == "您的密码长度太短，这样不太安全！ 密码需在 5-32 个字符间。")
    #expect(try await hint("home-admin", String(repeating: "x", count: 33), String(repeating: "x", count: 33)) == "你的密码设置过长。密码需在 5-32 个字符间。")
    #expect(try await hint("home-admin", "\"Rt8!vQ2", "\"Rt8!vQ2") == "第一个字符不能是： [\"]")
    // A weak password asks; 取消 shows the hint, 确定 goes on.
    var weak = w
    weak.edit(.username, "home-admin"); weak.edit(.password, "qwerty"); weak.edit(.passwordConfirm, "qwerty")
    guard case .confirm(let question, let asking) = try await c.qis(weak, .next) else { Issue.record("confirm expected"); return }
    #expect(question.text == "常见的密码组合很容易让他人猜到，是否继续？")
    guard case .updated(let refused) = try await c.qisAnswer(asking, question: question, yes: false) else { Issue.record("page expected"); return }
    #expect(refused.hints[.password] == "为保障您的网络安全，请使用更复杂的密码。" && refused.page == .login)
    guard case .updated(let accepted) = try await c.qisAnswer(asking, question: question, yes: true) else { Issue.record("page expected"); return }
    #expect(accepted.page == .wireless && accepted.post.text("http_passwd") == "qwerty")
    // The KR policy for strict SKUs.
    let kr = try await client(router(["territory_code": "KR/01"])).qisStart(flag: "changePass")
    #expect(kr.screen.paragraphs.last == "密码长度必须至少包含 10 个字符，其中包括 1 个字母、1 个特殊字符和 1 个数字字符。不得有连续相同的字符。登录用户名和密码不得相同。")
    var x = kr
    x.edit(.username, "home-admin"); x.edit(.password, "Abcdefgh12"); x.edit(.passwordConfirm, "Abcdefgh12")
    #expect(try await step(try client(router(["territory_code": "KR/01"])), x, .next).hints[.password] == "密码长度必须至少包含 10 个字符，其中包括 1 个字母、1 个特殊字符和 1 个数字字符。不得有连续相同的字符。登录用户名和密码不得相同。")
}

@Test func changePassSendsChpassThenTheFinalObject() async throws {
    let r = router()
    let c = try client(r)
    var w = try await c.qisStart(flag: "changePass")
    w.edit(.username, "home-admin"); w.edit(.password, "Rt8!vQ2#mL"); w.edit(.passwordConfirm, "Rt8!vQ2#mL")
    w = try await step(c, w, .next)
    // apply.login goes on to the detection: online, so Wireless.
    #expect(w.page == .wireless && w.post.text("defpass_enable") == "0")
    let s = try await submission(c, w, .next)
    #expect(s.changesAdministrator && s.restart == .services("restart_wireless;restart_cfgsync"))
    let receipt = try await c.qisSubmit(s)
    let writes = await r.writes
    #expect(writes.map(\.path) == ["chpass.cgi", "applyapp.cgi"])
    // $.param of the data in its order, btoa for the non-empty values; a GET.
    #expect(writes[0].method == "GET" && writes[0].query == "restart_httpd=0&new_username=aG9tZS1hZG1pbg%3D%3D&new_passwd=UnQ4IXZRMiNtTA%3D%3D&defpass_enable=0")
    #expect(await r.posts.first?.hasPrefix(#"{"http_username":"home-admin","http_passwd":"Rt8!vQ2#mL","defpass_enable":"0","cfg_master":"1","x_Setting":"1""#) == true)
    #expect(receipt.changedAdministrator && receipt.chpassStatus == "200" && receipt.state?.page == .summary)
    // The read-back leaves the account out (httpd keeps it apart) and finds the rest.
    #expect(!receipt.verified.contains("http_username") && receipt.unverified.isEmpty && receipt.verified.contains("defpass_enable"))
}

@Test func defaultPasswordFillsTheDefaultAccount() async throws {
    let c = try client(router(support: #"{"mlo":1,"defpass":1}"#, defaults: ["http_username": "admin"]))
    var w = try await c.qisStart(flag: "changePass")
    #expect(w.screen.title == "本地登录" && w.form.defaultPassword && w.form.value(.username) == "admin")
    #expect(w.screen.fields.map(\.id) == [.username, .password] && w.screen.toggles.first?.id == "defpass")
    w.edit(.username, "home-admin")
    w = try await step(c, w, .next)
    #expect(w.post.text("http_passwd") == "" && w.post.text("defpass_enable") == "1")
    #expect(try w.chpassFields().map(\.1) == ["0", "aG9tZS1hZG1pbg==", "", "1"])
}

// MARK: - Operation mode and LAN IP

@Test func manualFlagShowsTheModesAndLeavesTheOthersToTheBrowser() async throws {
    let c = try client(router(support: #"{"mlo":1,"amas":1,"repeater":1,"psta":1,"wisp":1}"#))
    let w = try await c.qisStart(flag: "manual")
    #expect(w.post.members.map { $0.name } == ["sw_mode", "wlc_psta", "wlc_dpsta", "wlc_band"])
    #expect(w.screen.choices.map(\.title) == ["无线路由器 (默认)", "中继模式", "无线访问点 (Access Point)", "无线桥接 (Media Bridge)", "AiMesh", "公共 WiFi 模式 (WISP)"])
    #expect(try await step(c, w, .choose("rp")).page == .browser(.repeater))
    #expect(try await step(c, w, .choose("wisp")).browserFlag == "wispMode")
    // 上一步 with flag manual: window.history.back().
    guard case .leave(.back, _) = try await c.qis(w, .back) else { Issue.record("history.back expected"); return }
}

@Test func lanIPSwitchesToAccessPointAndReboots() async throws {
    let r = router()
    let c = try client(r)
    var w = try await c.qisStart(flag: "lanip")
    #expect(w.page == .getLanIP && w.screen.choices.map(\.title) == ["动态 IP", "手动分配"])
    w = try await step(c, w, .choose("static"))
    #expect(w.page == .lanStatic)
    w = try await step(c, w, .next)
    #expect(Set(w.hints.keys) == [.lanIP, .lanMask, .lanGateway, .lanDNS1])
    w.edit(.lanIP, "192.168.50.2"); w.edit(.lanMask, "255.255.255.0"); w.edit(.lanGateway, "192.168.50.1"); w.edit(.lanDNS1, "192.168.50.1")
    w = try await step(c, w, .next)
    #expect(w.page == .wireless)
    let s = try await submission(c, w, .next)
    // A LAN change reboots (getRestartService 1788–1797); the address after it is the static one.
    #expect(s.restart == .reboot && s.lanAddress == "192.168.50.2")
    let receipt = try await c.qisSubmit(s)
    #expect(receipt.checkAfterRestart && receipt.state?.page == .summary)
    let post = try #require(await r.posts.first)
    #expect(post.hasPrefix(#"{"sw_mode":3,"wlc_psta":0,"wlc_dpsta":0,"mlo_rp":0,"mlo_mb":0,"cfg_master":"1","lan_proto":"static","lan_dnsenable_x":"0","lan_ipaddr":"192.168.50.2","lan_gateway":"192.168.50.1","lan_netmask":"255.255.255.0","lan_dns2_x":"","lan_dns1_x":"192.168.50.1","x_Setting":"1""#))
    #expect(post.hasSuffix(#""action_mode":"apply","rc_service":"reboot"}"#))
    // 上一步 with flag lanip: window.history.back().
    guard case .leave(.back, _) = try await c.qis(try await c.qisStart(flag: "lanip"), .back) else { Issue.record("history.back expected"); return }
}

// MARK: - Wireless

@Test func smartConnectShowsOneInputAndSeparateShowsEachBand() async throws {
    let c = try client(router())
    var w = try await c.qisStart(flag: "wireless")
    #expect(w.screen.toggles == [QISToggle(id: "separate", title: "Separate 2.4 GHz, 5 GHz", on: false)])
    #expect(w.form.wireless?.map(\.unit) == ["0"] && w.form.wireless?.first?.ssid == "Harbor")
    #expect(w.wirelessTitles(w.form.wireless![0]) == (ssid: " 无线名称（SSID）", key: " 网络密码"))
    #expect(w.post.text("smart_connect_x") == "1" && w.post["smart_connect_x"] == .number("1") && w.post["smart_connect_selif_x"] == .number("3"))
    w = try await step(c, w, .toggle("separate", true))
    #expect(w.form.wireless?.map(\.title) == ["2.4 GHz", "5 GHz"] && w.form.wireless?.map(\.ssid) == ["Harbor", "Harbor_5G"])
    #expect(w.post["smart_connect_x"] == .string("0") && w.post["smart_connect_selif_x"] == .string("3"))
    // Typing in 2.4 GHz copies to 5 GHz with the suffix while the hidden sync box is on; typing in 5 GHz turns it off.
    w.editWireless("0", ssid: true, "Lagoon")
    #expect(w.form.wireless?.map(\.ssid) == ["Lagoon", "Lagoon_5G"])
    w.editWireless("1", ssid: true, "Lagoon-5")
    w.editWireless("0", ssid: true, "Lagoon2")
    #expect(w.form.wireless?.map(\.ssid) == ["Lagoon2", "Lagoon-5"])
    // An empty SSID and key are blank hints; a short key is the page's alert.
    w.editWireless("0", ssid: false, "short")
    var checked = try await step(c, w, .next)
    #expect(checked.alerts == ["WPA 无线密码应为 8~63 个字符的字符串或 64 个十六进制字符。"])
    w.editWireless("0", ssid: false, "Long-Enough-9")
    w.editWireless("1", ssid: false, "Long-Enough-9")
    checked = w
    checked.editWireless("1", ssid: true, "")
    checked = try await step(c, checked, .next)
    #expect(checked.wirelessHints["ssid:1"] == "栏位不能为空白")
    let s = try await submission(c, w, .next)
    let post = s.state.post
    #expect(post.text("wl0_ssid") == "Lagoon2" && post.text("wl1_ssid") == "Lagoon-5" && post.text("wl1_auth_mode_x") == "psk2sae" && post.text("wl1_mfp") == "1")
    #expect(s.requests.last?.service == "restart_wireless")
}

@Test func withoutMLOOnlyTheChangedBandsAreWritten() async throws {
    let support = #"{"smart_connect_v2":1,"bcmwifi":1,"dualband":1}"#
    let c = try client(router(["smart_connect_x": "0"], support: support))
    var w = try await c.qisStart(flag: "wireless")
    #expect(w.form.separate && w.form.wireless?.count == 2)
    // Nothing typed: no wl keys, only the completion flags and Smart Connect.
    var s = try await submission(c, w, .next)
    #expect(s.state.post.members.map { $0.name } == ["x_Setting", "w_Setting", "qis_Setting", "smart_connect_x", "smart_connect_selif_x", "action_mode", "rc_service"])
    #expect(s.requests.last?.service == "")
    // Typing adds every band's wirelessObj (the change handler), and both bands are written with psk2 / mfp 0.
    w.editWireless("1", ssid: true, "Harbor_5G_new")
    s = try await submission(c, w, .next)
    let post = s.state.post
    #expect(post.text("wl0_auth_mode_x") == "psk2" && post.text("wl0_mfp") == "0" && post.text("wl1_ssid") == "Harbor_5G_new")
    #expect(!post.has("wl0_11be") && s.requests.last?.service == "restart_wireless")
}

@Test func mloFlagBackGoesToTheMLOPage() async throws {
    let c = try client(router())
    guard case .leave(.mloPage, _) = try await c.qis(try await c.qisStart(flag: "mlo"), .back) else { Issue.record("MLO.asp expected"); return }
    // From the welcome path 上一步 goes back to the page before.
    var w = try await step(c, try await c.qisStart(), .choose("create"))
    w = try await step(c, w, .back)
    #expect(w.page == .welcome)
}

// MARK: - The firmware check and the update page

@Test func liveUpdateSendsTheCheckAndANewVersionLeadsToTheUpdatePage() async throws {
    let r = router(["webs_state_update": "1", "webs_state_flag": "1", "webs_state_info": "3004_388_8_2", "webs_state_level": "0",
                    "webs_update_ts": "1800000000>x", "apps_sq": ""])
    let c = try client(r)
    let live = QISLiveUpdate(pause: { _ in }, clock: { Date(timeIntervalSince1970: 1_800_000_100) })
    var w = try await c.qisStart(flag: "wireless")
    await live.run(from: w, client: c)
    #expect(await live.phase == .done)
    #expect(await r.posts == [#"{"action_mode":"apply","webs_update_trigger":"QIS","rc_service":"start_webs_update","skip_modify_flag":"1"}"#])
    w.liveUpdate = QISLiveUpdateLink(actor: live)
    let s = try await submission(c, w, .next)
    // A new version: the object goes with rc_service "" first (1404–1408).
    #expect(s.requests.last?.service == "" && s.restart == .none)
    let receipt = try await c.qisSubmit(s)
    let update = try #require(receipt.state)
    #expect(update.page == .update && update.screen.next == "下一步")
    #expect(update.updateVersions == (current: "3006.102_5", latest: "3004.388.8_2"))
    // 下一步 is abort.update: a new object with action_mode and rc_service only (2475–2478), then Finish.
    let next = try await submission(c, update, .next)
    #expect(next.requests == [.apply([("action_mode", .string("apply")), ("rc_service", .string("restart_wireless"))])])
    #expect(try await c.qisSubmit(next).state?.page == .summary)
}

// MARK: - SDN main network (mainfhSetup)

private let mainfhRules = "<0>DEFAULT>1>0>0>0>0>0>0>0>0>0>0>0>0>0>0>0>0>WEB>0>0<1>MAINFH>1>0>0>1>0>0>0>0>0>0>0>0>0>0>0>0>0>WEB>0>0<2>MAINBH>1>0>0>2>0>0>0>0>0>0>0>0>0>0>0>0>0>WEB>0>0"
/// A router with SDN main networks (mainfhSetup): MAINFH "Mainhall" and MAINBH, no LEGACY network yet.
private func mainfhRouter() -> QISRouter {
    let support = #"{"mlo":1,"smart_connect_v2":1,"bcmwifi":1,"dualband":1,"sdn_mwl":1,"sdn_mainfh":1,"mtlancfg":1,"MaxRule_SDN":16}"#
    return router(["sdn_rl": mainfhRules, "apm1_ssid": "Mainhall", "apm1_security": "<3>psk2sae>aes>Mn7#qW2xLp>0", "apm1_dut_list": "<*>7>"],
                  support: support, defaults: ["sdn_rl": "<0>DEFAULT>1>0>0>0>0>0>0>0>0>0>0>0>0>0>0>0>0>WEB>0>0"])
}

@Test func mainFronthaulRoutersRebuildTheSDNNetworks() async throws {
    let rules = mainfhRules
    let r = mainfhRouter()
    let c = try client(r)
    var w = try await c.qisStart(flag: "wireless")
    // get_sdn_main_fh_info: the inputs show the MAINFH network's name and key.
    #expect(w.form.wireless?.map(\.ssid) == ["Mainhall"] && w.form.wireless?.first?.key == "Mn7#qW2xLp")
    // No LEGACY network and room for one: the IoT page.
    w = try await step(c, w, .next)
    #expect(w.page == .iot && w.form.value(.iotSSID) == "Mainhall_IoT")
    #expect(try await step(c, w, .toggle("later", true)).form.value(.iotKey) == "")
    let s = try await submission(c, w, .next)
    let post = s.state.post
    // configApmVariables: MAINFH rebuilt from the input (index 1 free again), the MAINBH kept, wl keys gone.
    #expect(post.text("sdn_rl") == rules.replacingOccurrences(of: "<1>MAINFH>1>0>0>1>0>0>0>0>0>0>0>0>0>0>0>0>0>WEB>0>0", with: "")
            + "<3>LEGACY>1>0>0>3>0>0>0>0>0>0>0>0>0>0>0>0>0>WEB>0>0<1>MAINFH>1>0>0>1>0>0>0>0>0>0>0>0>0>0>0>0>0>WEB>0>0")
    #expect(post.text("apm1_security") == "<3>psk2sae>aes>Mn7#qW2xLp>0<13>psk2sae>aes>Mn7#qW2xLp>0<16>sae>aes>Mn7#qW2xLp>0<96>sae>aes>Mn7#qW2xLp>0")
    #expect(post.text("apm1_dut_list") == "<*>7>" && post["apm1_11be"] == .number("1"))
    #expect(post.text("apg3_ssid") == "Mainhall_IoT" && post.text("apg3_security") == "<127>psk2>aes>Mn7#qW2xLp>1" && post.text("apg3_dut_list") == "<*>7>")
    #expect(!post.members.contains { $0.name.hasPrefix("wl") })
    #expect(s.requests.last?.service == "restart_wireless;restart_sdn")
}

@Test func mainBackhaulIsAddedFromTheMD5OfTheMainNetwork() throws {
    #expect(QISWizard.mainfhDutList(3) == "<*>7>")
    #expect(QISWizard.mainfhDutList(1) == "<*>1>")
    #expect(QISWizard.mainfhDutList(2) == "<*>6>")
    let w = QISWizard(flag: "")
    #expect(try w.calcMD5("abc") == "900150983cd24fb0d6963f7d28e17f72")
    #expect(throws: RouterError.self) { try w.calcMD5("咖啡") }
}

// MARK: - Menu, checks and request encoding

@Test func setupWizardIsTheNativeQISPage() {
    #expect(WebMenuCatalog.location(of: .setupWizard) == WebLocation(menu: "menu_QIS", page: "QIS_wizard.htm", part: "main"))
}

@Test func checksFollowTheValidators() {
    #expect(QISCheck.hostName("ab") == nil && QISCheck.hostName("a_b-c") == nil && QISCheck.hostName("ab\n") != nil)
    #expect(QISCheck.isWeak("abcdef", "httpd_password") && QISCheck.isWeak("zyxw", "wpa_key") && QISCheck.isWeak("aaaa", "wpa_key"))
    #expect(!QISCheck.isWeak("Kx8#vR2nQp", "wpa_key") && QISCheck.isWeak("zxcvbnm", "httpd_password") && !QISCheck.isWeak("zxcvbnm", "wpa_key"))
    #expect(QISCheck.psk("1234567") == ["WPA 无线密码应为 8~63 个字符的字符串或 64 个十六进制字符。"])
    #expect(QISCheck.psk(" 12345678") == ["WPA金钥不能包含空格字符！"])
    #expect(QISCheck.psk("\"12345678") == ["第一个字符不能是： [\"]", "WPA 无线密码应为 8~63 个字符的字符串或 64 个十六进制字符。"])
    #expect(QISCheck.psk(String(repeating: "a", count: 64)).isEmpty && QISCheck.psk(String(repeating: "g", count: 64)).count == 1)
    #expect(QISCheck.ssid(String(repeating: "咖", count: 11), utf8SSID: true)?.alert == "网络名称的长度已经达到最大值。")
    #expect(QISCheck.ssid("咖啡", utf8SSID: true) == nil && QISCheck.ssid("咖啡", utf8SSID: false)?.alert == "SSID不能包含「 咖 」这个字符。")
    #expect(QISCheck.ssid("   ", utf8SSID: true)?.alert == "栏位不能为空白")
    #expect(QISCheck.blockChars("ab<cd", ["<", ">"]) == "<,> 是无效字符。")
    // validator.isIPAddr on key press: a dot after three digits, no double dot, nothing else.
    #expect(QISCheck.ipAddressKeyPress("192", "1") == "192." && QISCheck.ipAddressKeyPress("19", "2") == "19")
    #expect(QISCheck.ipAddressKeyPress("192.", ".") == nil && QISCheck.ipAddressKeyPress("1.2.3.4", ".") == nil && QISCheck.ipAddressKeyPress("1.2.3", ".") == "1.2.3" && QISCheck.ipAddressKeyPress("1", "a") == nil)
    #expect(WebValidator.edit("192", "1921", typed: "1", maxLength: 15, keyPress: QISCheck.ipAddressKeyPress) == "192.1")
}

@Test func requestsAreShownWithSecretsMasked() {
    let request = QISRequest.chpass([("restart_httpd", "0"), ("new_username", "aG9tZS1hZG1pbg=="), ("new_passwd", "UnQ4IXZRMiNtTA=="), ("defpass_enable", "0")])
    #expect(request.method == "GET" && request.path == "chpass.cgi")
    #expect(request.query == "restart_httpd=0&new_username=aG9tZS1hZG1pbg%3D%3D&new_passwd=UnQ4IXZRMiNtTA%3D%3D&defpass_enable=0")
    #expect(!request.summary.contains("UnQ4") && !request.summary.contains("aG9t"))
    let apply = QISRequest.apply([("wan_pppoe_passwd", .string("Pq4!mZ8w")), ("rc_service", .string("restart_wan_if 0"))])
    #expect(!apply.summary.contains("Pq4") && apply.summary.contains("rc_service=restart_wan_if 0"))
}

// MARK: - Review fixes

@Test func passwordChecksRefuseWithoutRepeatingTheInput() async throws {
    // The admin password: validator.invalidChar refuses a character outside " " to "~" but the hint does not show it.
    let c = try client(router())
    var login = try await c.qisStart(flag: "changePass")
    login.edit(.username, "home-admin"); login.edit(.password, "Rt8!vQ2#m咖"); login.edit(.passwordConfirm, "Rt8!vQ2#m咖")
    let refused = try await step(c, login, .next)
    #expect(refused.page == .login && refused.hints[.password] == QISText.passwordCharacters)
    #expect(!refused.hints.values.contains { $0.contains("咖") } && !refused.alerts.contains { $0.contains("咖") })
    // validator.KRSkuPwd for the strict SKUs.
    let kc = try client(router(["territory_code": "KR/01"]))
    var kr = try await kc.qisStart(flag: "changePass")
    kr.edit(.username, "home-admin"); kr.edit(.password, "Abc!12345x咖"); kr.edit(.passwordConfirm, "Abc!12345x咖")
    let krRefused = try await step(kc, kr, .next)
    #expect(krRefused.page == .login && krRefused.hints[.password] == QISText.passwordCharacters)
    // The Wi-Fi key: validator.psk (its validator.string alert first), and psk_KR / string_KR.
    let wc = try client(router())
    var wireless = try await wc.qisStart(flag: "wireless")
    wireless.editWireless("0", ssid: false, "Long-Enough-9é")
    let wifi = try await step(wc, wireless, .next)
    #expect(wifi.page == .wireless && wifi.alerts == [QISText.passwordCharacters, QISText.pskInvalid])
    let kwc = try client(router(["territory_code": "KR/01"]))
    var krWireless = try await kwc.qisStart(flag: "wireless")
    krWireless.editWireless("0", ssid: false, "Abc!1234é5")
    let krWifi = try await step(kwc, krWireless, .next)
    #expect(krWifi.page == .wireless && krWifi.alerts == [QISText.passwordCharactersNoSpace, QISText.pskInvalid])
    // The IoT key (apply.SDN_IoT's validator.psk).
    let ic = try client(mainfhRouter())
    var iot = try await step(ic, try await ic.qisStart(flag: "wireless"), .next)
    #expect(iot.page == .iot)
    iot.edit(.iotKey, "Mn7#qW2x咖Lp")
    let iotRefused = try await step(ic, iot, .next)
    #expect(iotRefused.page == .iot && iotRefused.alerts == [QISText.passwordCharacters, QISText.pskInvalid])
    #expect(!iotRefused.hints.values.contains { $0.contains("咖") })
    // The checks themselves, valid_block_chars included: refused as before, never echoed.
    let answers = [QISCheck.invalidChar("ab咖cd"), QISCheck.krPassword("Abc!12345x咖"), QISCheck.blockChars("ab咖cd", ["<", ">"]),
                   QISCheck.blockChars("ab\u{1}cd", ["<", ">"]), QISCheck.string("Long-Enough-9é")]
    #expect(answers.allSatisfy { $0 != nil && !$0!.contains("咖") && !$0!.contains("é") && !$0!.contains("\u{1}") })
    #expect(QISCheck.pskKR("Abc!1234é5").alerts.allSatisfy { !$0.contains("é") } && QISCheck.pskKR("Abc!1234é5").alerts.count == 2)
    #expect(QISCheck.invalidChar("Rt8!vQ2#mL") == nil && QISCheck.blockChars("Rt8!vQ2#mL", ["<", ">"]) == nil)
}

@Test func noWanAfterBackStopsOnAKnownStateWithoutDetectingAgain() async throws {
    let r = router(["link_wan": "0"])
    let c = try client(r)
    var w = try await step(c, try await c.qisStart(), .choose("create"))
    #expect(w.page == .noWan)
    w = try await step(c, w, .choose("manual"))
    #expect(w.page == .wanSetting)
    _ = w.takeEffects()   // the welcome page's, as the app takes them
    // 上一步: abort.wan's NOWAN timer, first after half a second, then every second while the state is one it does not know.
    w = try await step(c, w, .back)
    #expect(w.page == .noWan && w.pollInterval == 0.5)
    w = try await step(c, w, .tick)
    #expect(w.page == .noWan && w.pollInterval == 1)
    // CHECKING (the cable is in, the WAN not up) is a state it knows: the timer ends, and without 手动设置 nothing moves on.
    // That read itself asked for start_force_autodet (detwanGetRet's own startAutoDet), and nothing after it.
    await r.set("link_wan", "1"); await r.set("wan0_state_t", "1")
    w = try await step(c, w, .tick)
    #expect(w.page == .noWan && w.pollInterval == nil && w.effects == [.autoDetect])
    let reads = await r.requests.count
    for _ in 0..<3 { w = try await step(c, w, .tick) }
    #expect(await r.requests.count == reads && w.effects == [.autoDetect] && w.page == .noWan)
}

/// The app's side for QISController: one connection at a time, and what the controller asked of it.
@MainActor private final class FakeHost: QISHost {
    var client: RouterClient?
    var operation: String?
    var mayHaveChanged = 0, unchanged = 0, changed = 0, errors = 0
    init(_ client: RouterClient) { self.client = client }
    func qisClient() throws -> RouterClient { guard let client else { throw RouterError.authenticationRequired }; return client }
    var qisOperationInProgress: Bool { operation != nil }
    func qisBeginOperation(_ title: String) -> Bool { guard operation == nil else { return false }; operation = title; return true }
    func qisEndOperation() { operation = nil }
    func qisManagementError(_ error: Error) { errors += 1 }
    func qisAdministratorMayHaveChanged() { mayHaveChanged += 1 }
    func qisAdministratorUnchanged() { unchanged += 1 }
    func qisAdministratorChanged() { changed += 1 }
    var qisUptime: TimeInterval { 100 }
    func qisAwaitRestart(_ client: RouterClient, from uptime: TimeInterval, checks: Int) async -> QISRestartWait { .notConfirmed }
    func qisOpenMLOPage() {}
}
/// A controller whose timers never fire by themselves: the tests run the ticks.
@MainActor private func controller(_ host: FakeHost) -> QISController {
    let controller = QISController(pause: { _ in try await Task.sleep(for: .seconds(3600)) })
    controller.host = host
    return controller
}

@MainActor @Test(.timeLimit(.minutes(1))) func lateResultsOfAnOldSessionOrWizardAreDroppedAndSendNothing() async throws {
    // No WAN cable and offline, so the firmware check only waits for the internet.
    let r = router(["link_wan": "0", "link_internet": "0"])
    let host = FakeHost(try client(r))
    let qis = controller(host)
    qis.start(flag: "")
    await qis.settle()
    try #require(qis.wizard?.page == .welcome && qis.asked == [.autoDetect, .liveUpdate])
    qis.decide(send: true)
    await qis.settle()
    #expect(await r.count("start_force_autodet") == 1)
    // After 创建新的网络 the detection will find a state it does not know and want start_force_autodet again.
    await r.set("link_wan", "1"); await r.set("wan0_state_t", "1")
    await r.hold("link_wan")
    qis.perform(.choose("create"))
    await r.waitUntilHeld()
    // The connection is replaced while that read is out: its answer belongs to the old session.
    host.client = try client(r)
    await r.release()
    await qis.settle()
    #expect(qis.wizard?.page == .welcome && qis.busy == nil && qis.asked.isEmpty)
    #expect(await r.count("start_force_autodet") == 1)
    // The next click notices the new session: the wizard is read again under it rather than used with it.
    qis.perform(.choose("create"))
    await qis.settle()
    #expect(qis.notice == QISNotice("连接已经更换，网络设置向导已重新读取。", .information) && qis.wizard?.page == .welcome && qis.consent == nil)
    #expect(await r.count("start_force_autodet") == 1)

    // A new wizard on the new session; leaving the page while 创建新的网络 reads drops it the same way.
    qis.start(flag: "")
    await qis.settle()
    try #require(qis.wizard?.page == .welcome)
    qis.decide(send: true)
    await qis.settle()
    #expect(await r.count("start_force_autodet") == 2)
    await r.set("link_wan", "1"); await r.set("wan0_state_t", "1")
    await r.hold("link_wan")
    qis.perform(.choose("create"))
    await r.waitUntilHeld()
    qis.stop()
    await r.release()
    await qis.settle()
    #expect(qis.wizard?.page == .welcome && qis.busy == nil && qis.asked.isEmpty)
    #expect(await r.count("start_force_autodet") == 2)
}

@MainActor @Test(.timeLimit(.minutes(1))) func aClickDuringATickRunsAndTheTickIsDropped() async throws {
    let r = router(["link_wan": "0"])
    let host = FakeHost(try client(r))
    let qis = controller(host)
    qis.start(flag: "")
    await qis.settle()
    qis.decide(send: false)
    qis.perform(.choose("create"))
    await qis.settle()
    try #require(qis.wizard?.page == .noWan && qis.wizard?.pollInterval == 1)
    // A tick reads the detection while the cable goes in (online: CONNECTED, which would move on to Wireless).
    await r.set("link_wan", "1")
    await r.hold("link_wan")
    qis.tick()
    await r.waitUntilHeld()
    // 手动设置 meanwhile: the click is taken (busy) and wins; the tick's answer is never taken.
    qis.perform(.choose("manual"))
    #expect(qis.busy != nil)
    await r.release()
    await qis.settle()
    #expect(qis.wizard?.page == .wanSetting && qis.busy == nil && qis.notice == nil && !qis.timerRunning)
    qis.stop()

    // The dropped tick's read comes back as an HTTP error (an answer already on its way, not a cancellation): it is not
    // shown and not passed on to the connection's error handling, and the click still runs.
    let e = router(["link_wan": "0"])
    let errorHost = FakeHost(try client(e))
    let late = controller(errorHost)
    late.start(flag: "")
    await late.settle()
    late.decide(send: false)
    late.perform(.choose("create"))
    await late.settle()
    try #require(late.wizard?.page == .noWan)
    await e.hold("link_wan")
    late.tick()
    await e.waitUntilHeld()
    await e.fail(["link_wan"], status: 500)
    late.perform(.choose("manual"))
    await e.release()
    await late.settle()
    #expect(late.wizard?.page == .wanSetting && late.notice == nil && errorHost.errors == 0 && late.busy == nil)
    late.stop()

    // A click that fails on a polling page (here apply.manual's read of switch_wantag) leaves the page's timer running.
    let iptv = #"{"mlo":1,"amas":1,"smart_connect_v2":1,"bcmwifi":1,"dualband":1,"11AX":1,"qis_hide_he_features":1,"IPTV":1}"#
    let s = router(["link_internet": "0"], support: iptv)
    let keep = FakeHost(try client(s))
    let waiting = controller(keep)
    waiting.start(flag: "")
    await waiting.settle()
    waiting.decide(send: false)
    waiting.perform(.choose("create"))
    await waiting.settle()
    try #require(waiting.wizard?.page == .waiting && waiting.timerRunning)
    await s.fail(["switch_wantag"])
    waiting.perform(.choose("manual"))
    #expect(!waiting.timerRunning)
    await waiting.settle()
    #expect(waiting.wizard?.page == .waiting && waiting.notice?.tone == .error && waiting.busy == nil && waiting.timerRunning)
    waiting.stop()
}

/// The changePass entry's final submission: chpass.cgi, then the whole object.
private func changePassSubmission(_ r: QISRouter, live: QISLiveUpdate? = nil) async throws -> (RouterClient, QISSubmission) {
    let c = try client(r)
    var w = try await c.qisStart(flag: "changePass")
    w.edit(.username, "home-admin"); w.edit(.password, "Rt8!vQ2#mL"); w.edit(.passwordConfirm, "Rt8!vQ2#mL")
    w = try await step(c, w, .next)
    if let live { await live.run(from: w, client: c); w.liveUpdate = QISLiveUpdateLink(actor: live) }
    return (c, try await submission(c, w, .next))
}
private actor Counter { private(set) var value = 0; func add() { value += 1 } }

/// What qisSubmit said about the administrator account, in order.
private actor ChangeLog {
    private(set) var changes: [QISAdministratorChange] = []
    func add(_ change: QISAdministratorChange) { changes.append(change) }
}

@Test(.timeLimit(.minutes(1))) func chpassIsReportedBeforeItGoesOutAndWhatFailsAfterItDoesNotThrow() async throws {
    // Reported before chpass.cgi is handed to the transport: while its answer is still awaited (httpd has already changed
    // the account then, web.c 26876 before 26884) the caller knows. Cancelled meanwhile, the receipt still comes back.
    let held = router()
    var (c, s) = try await changePassSubmission(held)
    await held.hold("chpass.cgi")
    let early = ChangeLog()
    let task = Task { [s, c] in try await c.qisSubmit(s, onAdministratorChange: { await early.add($0) }) }
    await held.waitUntilHeld()
    #expect(await early.changes == [.mayChange])
    task.cancel()
    await held.release()
    let cancelled = try await task.value
    let afterCancel = await early.changes
    #expect(cancelled.changedAdministrator && afterCancel == [.mayChange] && cancelled.state?.page == .wireless)

    // The object after it refused (HTTP 500): the account may have changed all the same.
    let refused = router()
    (c, s) = try await changePassSubmission(refused)
    await refused.fail(["applyapp.cgi"])
    let partial = ChangeLog()
    let stopped = try await c.qisSubmit(s, onAdministratorChange: { await partial.add($0) })
    let partialChanges = await partial.changes
    #expect(stopped.changedAdministrator && partialChanges == [.mayChange] && stopped.state?.page == .wireless && stopped.chpassStatus == "200")

    // A new firmware: goTo.Update reads the version after the object, and that read fails.
    let update = router(["webs_state_update": "1", "webs_state_flag": "1", "webs_state_info": "3004_388_8_2", "webs_state_level": "0",
                         "webs_update_ts": "1800000000>x", "apps_sq": ""])
    (c, s) = try await changePassSubmission(update, live: QISLiveUpdate(pause: { _ in }, clock: { Date(timeIntervalSince1970: 1_800_000_100) }))
    #expect(s.requests.last?.service == "")
    await update.fail(["firmver"])
    let late = ChangeLog()
    let unread = try await c.qisSubmit(s, onAdministratorChange: { await late.add($0) })
    let lateChanges = await late.changes
    #expect(unread.changedAdministrator && lateChanges == [.mayChange] && unread.state?.page == .wireless && unread.message.contains("读取下一步所需的信息没有完成"))

    // Answered with an HTTP error, 500 or 404, it may still have run (do_chpass before its answer, web.c 26876, 26884):
    // it stays reported. Only a connection that never opened, or a stop before it was sent, takes the report back; the
    // page goes on with the object either way (it does not look at chpass's answer).
    for status in [500, 404, 403] {
        let uncertain = router()
        (c, s) = try await changePassSubmission(uncertain)
        await uncertain.fail(["chpass.cgi"], status: status)
        let maybe = ChangeLog()
        let maybeReceipt = try await c.qisSubmit(s, onAdministratorChange: { await maybe.add($0) })
        let maybeChanges = await maybe.changes
        #expect(maybeReceipt.changedAdministrator && maybeChanges == [.mayChange], "HTTP \(status)")
    }
    let missing = router()
    (c, s) = try await changePassSubmission(missing)
    await missing.cannotConnect(["chpass.cgi"])
    let none = ChangeLog()
    let notTaken = try await c.qisSubmit(s, onAdministratorChange: { await none.add($0) })
    let noneChanges = await none.changes
    #expect(!notTaken.changedAdministrator && noneChanges == [.mayChange, .unchanged] && notTaken.state?.page == .summary)
    let stopping = router()
    (c, s) = try await changePassSubmission(stopping)
    let stop = ChangeLog()
    let stoppedFirst = try await Task { [s, c] in
        try await c.qisSubmit(s, onAdministratorChange: { change in
            await stop.add(change)
            if change == .mayChange { withUnsafeCurrentTask { $0?.cancel() } }   // stopped right before sending
        })
    }.value
    let stopChanges = await stop.changes
    let stoppingWrites = await stopping.writes
    #expect(!stoppedFirst.changedAdministrator && stopChanges == [.mayChange, .unchanged] && stoppingWrites.isEmpty && stoppedFirst.state == nil)
}

/// The changePass entry run up to its final submission in a controller.
@MainActor private func controllerAtChangePassSubmission(_ r: QISRouter, _ host: FakeHost) async throws -> QISController {
    let qis = controller(host)
    qis.start(flag: "changePass")
    await qis.settle()
    qis.edit(.username, "home-admin"); qis.edit(.password, "Rt8!vQ2#mL"); qis.edit(.passwordConfirm, "Rt8!vQ2#mL")
    qis.perform(.next)
    await qis.settle()
    try #require(qis.wizard?.page == .wireless)
    qis.perform(.next)
    await qis.settle()
    try #require(qis.submission?.changesAdministrator == true)
    return qis
}

@MainActor @Test(.timeLimit(.minutes(1))) func theControllerStopsTheSavedLoginBeforeChpassGoesOut() async throws {
    let r = router()
    let host = FakeHost(try client(r))
    let qis = try await controllerAtChangePassSubmission(r, host)
    await r.hold("chpass.cgi"); await r.fail(["applyapp.cgi"])
    qis.confirmSubmission()
    await r.waitUntilHeld()
    // chpass.cgi is on its way and its answer not back: the saved login is already off.
    #expect(host.mayHaveChanged == 1 && host.unchanged == 0 && host.changed == 0 && host.operation != nil)
    // Leaving the page does not stop the submission, and the object failing after it changes nothing about the account.
    qis.stop()
    await r.release()
    await qis.settle()
    #expect(host.mayHaveChanged == 1 && host.unchanged == 0 && host.changed == 1 && host.operation == nil)

    // chpass.cgi answered with HTTP 404: it may have run, so the saved login stays off and the change is reported.
    let refusing = router()
    let other = FakeHost(try client(refusing))
    let second = try await controllerAtChangePassSubmission(refusing, other)
    await refusing.fail(["chpass.cgi"], status: 404)
    second.confirmSubmission()
    await second.settle()
    #expect(other.mayHaveChanged == 1 && other.unchanged == 0 && other.changed == 1 && other.operation == nil)
    second.stop()
    // Its connection never opened: it never ran, so the saved login is given back and no change is reported.
    let unreachable = router()
    let third = FakeHost(try client(unreachable))
    let thirdController = try await controllerAtChangePassSubmission(unreachable, third)
    await unreachable.cannotConnect(["chpass.cgi"])
    thirdController.confirmSubmission()
    await thirdController.settle()
    #expect(third.mayHaveChanged == 1 && third.unchanged == 1 && third.changed == 0 && third.operation == nil && thirdController.wizard?.page == .summary)
    thirdController.stop()
}

@Test func pppoePageCarriesTheIPTVBoxAndHandsOverWhenTicked() async throws {
    let support = #"{"mlo":1,"amas":1,"smart_connect_v2":1,"bcmwifi":1,"dualband":1,"11AX":1,"qis_hide_he_features":1,"IPTV":1}"#
    // goTo.PPPoE outside 手动设置 moves the box to the account page, ticked because the router has an ISP profile.
    let r = router(["switch_wantag": "movistar", "wan0_pppoe_username": "old@isp.example"], support: support)
    let c = try client(r)
    var w = try await c.qisStart(flag: "pppoe")
    #expect(w.page == .account && w.screen.toggles == [QISToggle(id: "iptv", title: "网络服务运营商 (ISP) 特殊需求  （仅支持某些 WAN 类型）", on: true)])
    w.edit(.pppoeUsername, "user@isp.example"); w.edit(.pppoePassword, "Pq4!mZ8w")
    // Ticked: apply.pppoe hands over to goTo.IPTV (the browser here) before the WAN restart, so nothing is sent.
    #expect(try await step(c, w, .next).page == .browser(.iptv))
    #expect(await r.writes.isEmpty)
    // Unticked by the user: the WAN restart as usual.
    let unticked = try await step(c, w, .toggle("iptv", false))
    #expect(unticked.page == .account && unticked.screen.toggles.first?.on == false)
    let s = try await submission(c, unticked, .next)
    #expect(s.requests.last?.service == "restart_wan_if 0;restart_dnsmasq" && s.state.page == .wireless)
    // 手动设置 (apply.manual) keeps the box on the WAN type page, and PPPoE chosen there does not move it.
    let m = try client(router(["switch_wantag": "movistar", "link_wan": "0"], support: support))
    var wan = try await step(m, try await m.qisStart(), .choose("create"))
    wan = try await step(m, wan, .choose("manual"))
    #expect(wan.page == .wanSetting && wan.screen.toggles.map(\.id) == ["iptv", "dhcpOption"] && wan.form.iptv)
    let account = try await step(m, wan, .choose("pppoe"))
    #expect(account.page == .account && account.screen.toggles.isEmpty)
    // Without an ISP profile the box moves but stays unticked.
    #expect(try await client(router(support: support)).qisStart(flag: "pppoe").screen.toggles.first?.on == false)
}

@Test func summaryShowsTheIoTNetworkAfterTheMainOne() async throws {
    let r = mainfhRouter()
    let c = try client(r)
    let iot = try await step(c, try await c.qisStart(flag: "wireless"), .next)
    #expect(iot.page == .iot)
    let summary = try #require(try await c.qisSubmit(try await submission(c, iot, .next)).state)
    #expect(summary.page == .summary && summary.form.wireless?.map(\.ssid) == ["Mainhall"])
    let network = try #require(summary.summaryIoT)
    #expect(network.title == "物联网网络" && network.ssidTitle == " 无线名称（SSID）" && network.ssid == "Mainhall_IoT")
    #expect(network.keyTitle == " 网络密码" && network.key == "Mn7#qW2xLp")
    // 可能稍后连接 empties the IoT key: the summary shows the main network only; so does a router without the IoT page.
    let later = try await step(c, iot, .toggle("later", true))
    #expect(try await c.qisSubmit(try await submission(c, later, .next)).state?.summaryIoT == nil)
    let plain = try client(router())
    let plainSummary = try await plain.qisSubmit(try await submission(plain, try await plain.qisStart(flag: "wireless"), .next)).state
    #expect(plainSummary?.page == .summary && plainSummary?.summaryIoT == nil)
}

// MARK: - Review fixes, second round

/// Opens once; whoever waits returns from then on (or when the waiting test is cancelled).
private actor Gate {
    private var opened = false
    private var waiting: [UUID: CheckedContinuation<Void, Never>] = [:]
    func open() { opened = true; waiting.values.forEach { $0.resume() }; waiting = [:] }
    func wait() async {
        guard !opened else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiting[id] = $0 }
        } onCancel: {
            Task { await self.stopWaiting(id) }
        }
    }
    private func stopWaiting(_ id: UUID) { waiting.removeValue(forKey: id)?.resume() }
}

/// A newer firmware as the router reports it once its check has run.
private let newFirmware = ["webs_state_update": "1", "webs_state_flag": "1", "webs_state_info": "3004_388_8_2", "webs_state_level": "0",
                           "webs_update_ts": "1800000000>x"]
private let checkClock: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_800_000_100) }

/// A clock the test moves on, and the pauses a firmware check asked for; the first pause is where the page is left.
private final class CheckTime: @unchecked Sendable {
    private let lock = NSLock()
    private var now = 1_800_000_100.0, asked: [Double] = []
    var clock: @Sendable () -> Date { { [self] in lock.withLock { Date(timeIntervalSince1970: now) } } }
    func pause(_ seconds: Double) throws {
        if lock.withLock({ asked.append(seconds); return asked.count == 1 }) { throw CancellationError() }
    }
    func advance(_ seconds: Double) { lock.withLock { now += seconds } }
    var pauses: [Double] { lock.withLock { asked } }
}

@Test(.timeLimit(.minutes(1))) func comingBackWithinTheFirstTwoSecondsWaitsTheRest() async throws {
    // A fresh result, which the check reads once two seconds have passed since its request went through (plugins.js 2282,
    // 2301).
    let r = router(["webs_state_update": "1", "webs_update_ts": "1800000101>x"])
    let c = try client(r)
    let w = try await c.qisStart(flag: "wireless")
    let time = CheckTime()
    let live = QISLiveUpdate(pause: { try time.pause($0) }, clock: time.clock)
    // The request goes through and the page is left during those two seconds: nothing is read yet.
    await live.run(from: w, client: c)
    let stopped = await live.phase, early = await r.count("webs_state_update")
    #expect(stopped == .stopped && time.pauses == [2] && early == 0)
    // Coming back half a second later: the rest of the two seconds first, then the read; the request is not sent again.
    time.advance(0.5)
    await live.run(from: w, client: c)
    let done = await live.phase, checks = await r.posts.filter { $0.contains("start_webs_update") }
    #expect(time.pauses == [2, 1.5] && done == .done && checks.count == 1)
}

@Test(.timeLimit(.minutes(1))) func aStoppedFirmwareCheckSubmitsNothingAndCarriesOnLikeThePage() async throws {
    // The check went out and reads webs_state_update "0" (still checking): the state the page's wait keeps waiting for.
    let r = router(["webs_state_update": "0", "webs_update_ts": ""])
    let c = try client(r)
    var w = try await c.qisStart(flag: "wireless")
    let calls = Counter(), firstRead = Gate()
    let live = QISLiveUpdate(pause: { _ in
        await calls.add()
        if await calls.value == 2 {
            // After the first read: the check waits here until its page is left.
            await firstRead.open()
            try await Task.sleep(for: .seconds(3600))
        }
        try Task.checkCancellation(); await Task.yield()
    }, clock: checkClock)
    let check = Task { [w] in await live.run(from: w, client: c) }
    await firstRead.wait()
    check.cancel()
    await check.value
    let stoppedPhase = await live.phase, stoppedStatus = await live.status
    #expect(stoppedPhase == .stopped && stoppedStatus.websStateUpdate == "0")
    // 应用本页面设置 while it is stopped: the event ends with the reason and builds no request at all.
    w.liveUpdate = QISLiveUpdateLink(actor: live)
    let before = await r.writes.count
    await #expect(throws: QISFirmwareCheckStopped.self) { try await c.qis(w, .next) }
    #expect(await r.writes.count == before)
    // The check carries on (no second start_webs_update) and reads that a new firmware is there: the page's update branch,
    // rc_service "" first (handler.js 1404–1408), not the restart the old "0" would have led to.
    for (key, value) in newFirmware { await r.set(key, value) }
    await live.run(from: w, client: c)
    #expect(await live.phase == .done)
    let s = try await submission(c, w, .next)
    let checks = await r.posts.filter { $0.contains("start_webs_update") }
    #expect(s.then == .update && s.requests.last?.service == "" && checks.count == 1)
}

@Test(.timeLimit(.minutes(1))) func aFirmwareCheckReadsOnAfterAFailedReadAndOnlyItsRequestFailingEndsIt() async throws {
    // One read fails ("" for every name, as httpApi.nvramGet answers): the check reads again, finds the new firmware, and
    // the submit takes the update branch.
    let r = router(["webs_state_update": "0", "webs_update_ts": ""])
    let c = try client(r)
    var w = try await c.qisStart(flag: "wireless")
    let calls = Counter()
    let live = QISLiveUpdate(pause: { _ in
        await calls.add()
        switch await calls.value {
        case 1: await r.fail(["webs_state_update"])                                    // pause(2): the first read fails
        case 2: await r.recover(["webs_state_update"]); for (key, value) in newFirmware { await r.set(key, value) }
        default: break
        }
        try Task.checkCancellation(); await Task.yield()
    }, clock: checkClock)
    await live.run(from: w, client: c)
    #expect(await live.phase == .done)
    w.liveUpdate = QISLiveUpdateLink(actor: live)
    let s = try await submission(c, w, .next)
    #expect(s.then == .update && s.requests.last?.service == "")

    // The check's own request refused: as on the page (nvramSet calls back only on success) nothing is read, and the submit
    // waits its ten seconds on a state it never got, then goes on.
    let refused = router()
    await refused.fail(["applyapp.cgi"])
    let rc = try client(refused)
    var rw = try await rc.qisStart(flag: "wireless")
    let dead = QISLiveUpdate(pause: { _ in try Task.checkCancellation(); await Task.yield() }, clock: checkClock)
    await dead.run(from: rw, client: rc)
    let deadPhase = await dead.phase, deadStatus = await dead.status
    let reads = await refused.count("webs_state_update")
    #expect(deadPhase != .done && deadPhase != .stopped && deadStatus.websStateUpdate == nil && reads == 0)
    if case .failed = deadPhase {} else { Issue.record("failed expected, got \(deadPhase)") }
    rw.liveUpdate = QISLiveUpdateLink(actor: dead)
    let rs = try await submission(rc, rw, .next)
    #expect(rs.then == .finish)
}

@Test(.timeLimit(.minutes(1))) func aFirmwareCheckResumedDuringItsRequestWaitsForThatRequest() async throws {
    // A result from long before the check: never fresh for it.
    let r = router(["webs_state_update": "1", "webs_update_ts": "1799990000>x"])
    let c = try client(r)
    let w = try await c.qisStart(flag: "wireless")
    // Nothing here should pause; a run that reads anyway gives up after a while instead of reading for ever.
    let pauses = Counter()
    let live = QISLiveUpdate(pause: { _ in
        await pauses.add()
        if await pauses.value > 50 { throw CancellationError() }
        try Task.checkCancellation(); await Task.yield()
    }, clock: checkClock)
    await r.hold("applyapp.cgi")
    let first = Task { await live.run(from: w, client: c) }
    await r.waitUntilHeld()
    // The page is left and come back to while start_webs_update is still on its way, and then it is refused.
    first.cancel()
    let second = Task { await live.run(from: w, client: c) }
    while await live.runs < 2, !Task.isCancelled { await Task.yield() }
    await r.fail(["applyapp.cgi"], status: 404)
    await r.release()
    await first.value
    await second.value
    // Sent once; no result was read for a check that did not go through, and the old run changed nothing.
    let checks = await r.posts.filter { $0.contains("start_webs_update") }
    let reads = await r.count("webs_state_update")
    let phase = await live.phase, status = await live.status
    #expect(checks.count == 1 && reads == 0 && status.websStateUpdate == nil)
    if case .failed = phase {} else { Issue.record("failed expected, got \(phase)") }

    // Going through instead: the run that waited reads after it, and the old result is not taken as the answer.
    let ok = router(["webs_state_update": "1", "webs_update_ts": "1799990000>x"])
    let oc = try client(ok)
    let ow = try await oc.qisStart(flag: "wireless")
    let reading = Counter()
    let checking = QISLiveUpdate(pause: { _ in
        await reading.add()
        if await reading.value > 3 { try await Task.sleep(for: .seconds(3600)) }
        try Task.checkCancellation(); await Task.yield()
    }, clock: checkClock)
    await ok.hold("applyapp.cgi")
    let one = Task { await checking.run(from: ow, client: oc) }
    await ok.waitUntilHeld()
    one.cancel()
    let two = Task { await checking.run(from: ow, client: oc) }
    while await checking.runs < 2, !Task.isCancelled { await Task.yield() }
    let readsBefore = await ok.count("webs_state_update")
    await ok.release()
    while await ok.count("webs_state_update") < 2, !Task.isCancelled { await Task.yield() }
    let stale = await checking.phase
    #expect(readsBefore == 0 && stale == .checking)
    two.cancel()
    await one.value
    await two.value
}

@MainActor @Test(.timeLimit(.minutes(1))) func comingBackCarriesOnTheFirmwareCheckWithoutSendingItAgain() async throws {
    let r = router(["webs_state_update": "0", "webs_update_ts": ""])
    let host = FakeHost(try client(r))
    let qis = controller(host)
    qis.start(flag: "")
    await qis.settle()
    try #require(qis.asked.contains(.liveUpdate))
    // 照网页发送: the router is online, so the check goes out at once.
    await r.hold("applyapp.cgi")
    qis.decide(send: true)
    await r.waitUntilHeld()
    await r.release()
    let live = try #require(qis.wizard?.liveUpdate.actor)
    while await live.phase != .checking, !Task.isCancelled { await Task.yield() }
    // Leaving the page stops it; coming back after the first two seconds, it reads the result without a second
    // start_webs_update (within them it would wait for the rest first, comingBackWithinTheFirstTwoSecondsWaitsTheRest).
    qis.stop()
    while await live.phase != .stopped, !Task.isCancelled { await Task.yield() }
    try await Task.sleep(for: .seconds(2.2))
    await r.hold("webs_state_update")
    qis.resume()
    await r.waitUntilHeld()
    await r.release()
    while await live.status.websStateUpdate != "0", !Task.isCancelled { await Task.yield() }
    let posts = await r.posts.filter { $0.contains("start_webs_update") }
    #expect(posts.count == 1 && qis.wizard?.liveUpdate.actor === live)
    #expect(await live.phase == .checking)
    qis.stop()
}

@MainActor @Test(.timeLimit(.minutes(1))) func theFirmwareCheckAsksAgainRightBeforeItsPost() async throws {
    // Told not to go on, the check sends nothing.
    let quiet = router()
    let qc = try client(quiet)
    let check = QISLiveUpdate(pause: { _ in })
    await check.run(from: try await qc.qisStart(flag: "wireless"), client: qc, shouldSend: { false })
    let quietPhase = await check.phase, quietPosts = await quiet.posts
    #expect(quietPhase == .stopped && quietPosts.isEmpty)
    // In the controller: the connection is replaced while the check waits for the router to be online.
    let r = router()
    let host = FakeHost(try client(r))
    let qis = controller(host)
    qis.start(flag: "")
    await qis.settle()
    await r.hold("link_internet")
    qis.decide(send: true)
    await r.waitUntilHeld()
    host.client = try client(r)
    await r.release()
    let live = try #require(qis.wizard?.liveUpdate.actor)
    while await live.phase == .waitingForInternet, !Task.isCancelled { await Task.yield() }
    let livePhase = await live.phase, livePosts = await r.posts
    #expect(livePhase == .stopped && livePosts.isEmpty)
    qis.stop()
}

@MainActor @Test(.timeLimit(.minutes(1))) func aWithdrawalAnswerRunsOnlyForThePageItWasGivenOn() async throws {
    let r = unansweredPrivacy()
    let host = FakeHost(try client(r))
    let qis = controller(host)
    qis.start(flag: "")
    await qis.settle()
    qis.perform(.choose("disagree"))
    await qis.settle()
    try #require(qis.withdrawShown)
    // 我理解此风险 is pressed and the notice closes; meanwhile the page is left and the wizard opened again.
    let late = try #require(qis.deferAnswer(.choose("knowRisk")))
    qis.stop()
    qis.start(flag: "")
    await qis.settle()
    qis.perform(late)
    await qis.settle()
    let writes = await r.writes
    #expect(qis.submission == nil && qis.busy == nil && writes.isEmpty && qis.wizard?.form.withdrawing == false)
    // Given on the page still shown, it runs once: the withdrawal asks to be sent.
    qis.perform(.choose("disagree"))
    await qis.settle()
    let answer = try #require(qis.deferAnswer(.choose("knowRisk")))
    qis.perform(answer)
    await qis.settle()
    #expect(qis.submission?.requests == [.get("set_ASUS_privacy_policy.cgi", [("ASUS_privacy_policy", "0")], json: true)])
    qis.cancelSubmission()
    qis.perform(answer)
    await qis.settle()
    #expect(qis.submission == nil)
    qis.stop()
}
