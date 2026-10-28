import Foundation
import Testing
@testable import RouterCore

// 1.13：AiCloud 2.0 与设置、操作模式、Open NAT、游戏加速，以及它们共用的 validator.js 与客户端列表。

// MARK: - A router for these pages

/// Answers appGet hooks (nvram_char_to_ascii from `nvram`, get_ui_support from `support`, other hooks, with or without an
/// argument, from `hooks` as JSON), pages from `pages`, applyapp.cgi and start_apply.htm like the router (writing the
/// submitted variables into `nvram`). Records every request with its raw body.
private actor PageRouter: RouterTransport {
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
            if let open = hook.firstIndex(of: "("), !hook.hasPrefix("nvram_char_to_ascii(") {
                let name = String(hook[..<open]), argument = String(hook[hook.index(after: open)..<hook.index(before: hook.endIndex)])
                let key = argument.isEmpty ? name : name + "-" + argument
                if let answer = hooks[key] { return RouterHTTPResponse(data: Data("{\"\(key)\":\(answer)}".utf8), status: 200) }
                return RouterHTTPResponse(data: Data("{}".utf8), status: 200)
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
            for (key, value) in fields where !["action_mode", "rc_service", "action_wait"].contains(key) { nvram[key] = value }
            return try Self.reply(["modify": "1", "run_service": fields["rc_service"] ?? ""])
        case "start_apply.htm":
            for (key, value) in form(body) where !["current_page", "next_page", "action_mode", "action_script", "action_wait", "modified", "first_time"].contains(key) {
                nvram[key] = value
            }
            return RouterHTTPResponse(data: Data("<script>done_committing();</script>".utf8), status: 200)
        case "set_TM_EULA.cgi":
            for (key, value) in query { nvram[key] = value }
            return RouterHTTPResponse(data: Data("{}".utf8), status: 200)
        default:
            if let page = pages[path] { return RouterHTTPResponse(data: Data(page.utf8), status: 200) }
            return RouterHTTPResponse(data: Data(), status: 404)
        }
    }
    nonisolated func cancel() {}
    static func reply(_ object: Any) throws -> RouterHTTPResponse { RouterHTTPResponse(data: try JSONSerialization.data(withJSONObject: object), status: 200) }
    var actions: [(method: String, path: String, query: [String: String], body: String)] { requests.filter { $0.path != "appGet.cgi" } }
}

private func client(_ router: PageRouter) throws -> RouterClient { RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: router, writes: .reference) }
private func json(_ text: String) -> OrderedJSON { try! OrderedJSON(data: Data(text.utf8)) }
private func form(_ body: String) -> [String: String] {
    Dictionary(body.split(separator: "&").map { pair -> (String, String) in
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map {
            String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
        }
        return (parts[0], parts.count > 1 ? parts[1] : "")
    }, uniquingKeysWith: { first, _ in first })
}
private func keys(_ fields: [(String, String)]) -> [String] { fields.map(\.0) }
private func failure<T, E>(_ result: Result<T, E>) -> E? { if case .failure(let error) = result { error } else { nil } }
private func value(_ fields: [(String, String)], _ key: String) -> String? { fields.first { $0.0 == key }?.1 }

// MARK: - validator.js

@Test func validatorRangesRewriteWhatTheyAccept() {
    func check(_ text: String, _ low: Double, _ high: Double) -> (String, String?) {
        var value = text
        let alert = WebValidator.numberRange(&value, low, high)
        return (value, alert)
    }
    // range: leading zeros go (str2val), a blank becomes "0" only when accepted, Number() semantics decide.
    #expect(check("007", 1, 10) == ("7", nil) && check("0", 0, 5) == ("0", nil) && check("", 1, 10).1 == "请输入一数值介于 1 至 10")
    #expect(check(" 5", 1, 10) == (" 5", nil) && check("0x10", 1, 65535) == ("x10", nil) && check("1e1", 1, 10) == ("1e1", nil))
    #expect(check("11", 1, 10).1 == "请输入一数值介于 1 至 10" && check("abc", 1, 10).1 != nil)
    // numberRange: "a:b" rising, both ends in range, stays as typed; the alert names the end as typed.
    #expect(check("3:5", 1, 10) == ("3:5", nil) && check("5:3", 1, 10).1 == "不是有效的通信端口编号。" && check("0005:7", 1, 4).1 == "0005 不是有效的通信端口编号。")
    #expect(WebValidator.inetNetwork("") == -1 && WebValidator.inetNetwork("1.2.3") == -2 && WebValidator.inetNetwork("1.2.3.256") == -2 && WebValidator.inetNetwork("010.0.0.1") == 167_772_161)
    #expect(!WebValidator.isPrivateIP("10.0.0.0") && WebValidator.isPrivateIP("10.0.0.1") && !WebValidator.isPrivateIP("172.32.0.1") && !WebValidator.isPrivateIP("0.0.0.0"))
}

// MARK: - AiCloud 2.0

private func aiCloud(_ values: [String: String], wan: String = "100.64.1.2", support: [String: String] = ["cloudsync": "1", "rrsut": "1", "wifi7": "1", "realip": "1"]) -> AiCloudPage {
    let base = ["webdav_https_port": "443", "sw_mode": "1", "lan_ipaddr": "192.168.50.1", "wans_mode": "fo", "webdav_aidisk": "0", "webdav_proxy": "0",
                "enable_webdav": "0", "enable_cloudsync": "0", "preferred_lang": "CN", "firmver": "3.0.0.6"]
    return AiCloudPage(values: base.merging(values) { _, new in new }, wanIP: wan, support: support)
}

@Test func aiCloudAccessLineFollowsTheWanAddress() {
    // A private WAN address (strictly inside the ranges, or 0.0.0.0): plain text with the router's name in router mode.
    #expect(aiCloud([:], wan: "192.168.1.5").access == .local("https://www.asusrouter.com"))
    #expect(aiCloud(["webdav_https_port": "8443"], wan: "0.0.0.0").access == .local("https://www.asusrouter.com:8443"))
    #expect(aiCloud(["sw_mode": "3"], wan: "10.1.1.1").access == .local("https://192.168.50.1"))
    #expect(aiCloud([:], wan: "10.1.1.1", support: ["cloudsync": "1", "rrsut": "1", "tmo": "1"]).access == .local("https://cellspot.router"))
    // `https_port != 443` compares as a number: "" is 0, so the colon follows.
    #expect(aiCloud(["webdav_https_port": ""], wan: "10.1.1.1").access == .local("https://www.asusrouter.com:"))
    // Public: DDNS when enabled with a host name; otherwise the router's name, and a port other than 443 stops the script.
    #expect(aiCloud(["ddns_enable_x": "1", "ddns_hostname_x": "home.asuscomm.com", "webdav_https_port": "8443"]).access == .ddns("https://home.asuscomm.com:8443"))
    #expect(aiCloud([:]).access == .asusDomain("https://www.asusrouter.com", stopped: false))
    let stopped = aiCloud(["webdav_https_port": "8443"])
    #expect(stopped.access == .asusDomain("https://www.asusrouter.com", stopped: true) && stopped.scriptStops && stopped.showsSmartSync && !stopped.checksRealIP)
    // wifi7 removes 智能同步 when initial() gets to the end; without rrsut it throws earlier.
    #expect(!aiCloud([:]).showsSmartSync && aiCloud([:], support: ["cloudsync": "1"]).showsSmartSync && aiCloud([:]).checksRealIP)
    #expect(!aiCloud(["wans_mode": "lb"]).checksRealIP && aiCloud(["start_aicloud": "0"]).redirects)
}

@Test func aiCloudPrivateNoteFollowsTheRealAddress() {
    let page = aiCloud([:], wan: "100.64.1.2")
    // realip answered: external_ip 0 shows the note, 1 does not; unanswered: validator.isPrivateIP of the WAN address.
    #expect(page.showsPrivateNote(realIP: (0, true)) && !page.showsPrivateNote(realIP: (1, true)) && !page.showsPrivateNote(realIP: (-1, false)))
    #expect(aiCloud([:], wan: "192.168.1.5").showsPrivateNote(realIP: (-1, false)))
    // Only the public branch without DDNS stops at cloud_url (a port other than 443); a private address with that port goes on.
    #expect(aiCloud(["webdav_https_port": "8443"], wan: "192.168.1.5").showsPrivateNote(realIP: nil) && !aiCloud(["webdav_https_port": "8443"]).showsPrivateNote(realIP: (0, true)))
}

@Test func aiCloudSwitchesSendTheForm() async throws {
    // Turning one off turns enable_webdav off only when the other is `== 0`.
    let both = aiCloud(["webdav_aidisk": "1", "webdav_proxy": "1", "enable_webdav": "1"])
    #expect(value(both.fields(toggling: .cloudDisk), "webdav_aidisk") == "0" && value(both.fields(toggling: .cloudDisk), "enable_webdav") == "1")
    #expect(value(aiCloud(["webdav_aidisk": "1", "webdav_proxy": "", "enable_webdav": "1"]).fields(toggling: .cloudDisk), "enable_webdav") == "0")
    #expect(value(aiCloud([:]).fields(toggling: .smartAccess), "webdav_proxy") == "1" && value(aiCloud([:]).fields(toggling: .smartAccess), "enable_webdav") == "1")
    let fields = aiCloud([:]).fields(toggling: .cloudDisk)
    #expect(keys(fields) == ["preferred_lang", "firmver", "current_page", "next_page", "action_mode", "action_script", "action_wait", "enable_cloudsync",
                             "enable_webdav", "webdav_aidisk", "webdav_proxy"])
    let router = PageRouter(nvram: ["webdav_aidisk": "0", "webdav_proxy": "0", "enable_webdav": "0"])
    let receipt = try await client(router).submitAiCloudForm(fields, verifying: ["webdav_aidisk", "enable_webdav"])
    let sent = try #require(await router.actions.first)
    #expect(sent.path == "start_apply.htm" && sent.method == "POST" && receipt.isVerified)
    #expect(sent.body == "preferred_lang=CN&firmver=3.0.0.6&current_page=cloud_main.asp&next_page=cloud_main.asp&action_mode=apply&action_script=restart_webdav"
            + "&action_wait=3&enable_cloudsync=0&enable_webdav=1&webdav_aidisk=1&webdav_proxy=0")
}

@Test func aiCloudSettingsCheckAsApplyRuleDoes() {
    let values = ["webdav_acc_lock": "1", "enable_webdav_lock": "1", "webdav_lock_times": "3", "webdav_lock_interval": "2", "webdav_https_port": "443",
                  "webdav_http_port": "8082", "login_port": "80", "dm_http_port": "8081", "misc_httpsport_x": "8443", "misc_httpport_x": "8080",
                  "preferred_lang": "CN", "firmver": "3.0.0.6"]
    let settings = AiCloudSettings(values: values, support: ["rrsut": "1"])
    var draft = settings.draft
    #expect(settings.locked && settings.service == "restart_webdav" && draft.lockFieldsEnabled && draft.switchOn)
    #expect(AiCloudSettings(values: values, support: ["rrsut": "1", "aicloudipk": "1"]).service == "restart_setting_webdav")
    #expect(AiCloudSettings(values: values, support: ["aicloudipk": "1"]).service == "restart_webdav")
    // Leading zeros go before the conflict check, so "080" meets login_port; then parseInt rewrites both ports.
    draft.httpPort = "080"
    #expect(failure(settings.applying(draft)) == .alert("此端口用于: HTTP LAN port."))
    draft.httpPort = "8081"
    #expect(failure(settings.applying(draft)) == .alert("此端口用于: 下载大师."))
    draft.httpPort = "443"
    #expect(failure(settings.applying(draft)) == .samePorts)
    draft.httpPort = "8000:8100"
    guard case .success(let fields) = settings.applying(draft) else { Issue.record("not applied"); return }
    #expect(value(fields, "webdav_http_port") == "8000" && value(fields, "webdav_https_port") == "443")
    // A disabled field is still checked, and not sent.
    draft.setSwitch(false)
    draft.lockTimes = "0"
    #expect(failure(settings.applying(draft)) == .alert("请输入一数值介于 1 至 10"))
    draft.lockTimes = "3"
    guard case .success(let off) = settings.applying(draft) else { Issue.record("not applied"); return }
    #expect(keys(off) == ["preferred_lang", "firmver", "current_page", "next_page", "action_mode", "action_script", "action_wait", "enable_webdav_lock",
                          "webdav_acc_lock", "webdav_https_port", "webdav_http_port"] && value(off, "enable_webdav_lock") == "0")
    // 解锁 sends the form as it is, without the checks.
    draft.httpsPort = "bad"
    let unlock = settings.unlocking(draft)
    #expect(value(unlock, "webdav_acc_lock") == "0" && value(unlock, "webdav_https_port") == "bad")
}


// MARK: - 操作模式

@Test func operationModeOffersTheRadiosAndOpensTheWizard() {
    let support = ["amas": "2", "amasRouter": "1", "amasNode": "1", "repeater": "1", "psta": "1", "mtlancfg": "6"]
    let page = OperationModePage(values: ["sw_mode": "1", "wlc_express": "0", "productid": "RT-BE88U"], operationMode: "rt", support: support)
    #expect(page.modes.map(\.id) == ["routerMode", "apMode", "repeaterMode", "mbMode", "AiMeshMode"])
    #expect(page.modes[0].label == "无线路由器模式 / AiMesh 路由器模式（默认）" && page.initialMode?.id == "routerMode")
    #expect(page.modes.first { $0.id == "mbMode" }?.paragraphs.first?.hasPrefix("RT-BE88U 可被设置为无线桥接") == true)
    #expect(page.save(page.modes[0]) == .alreadyConfigured("RT-BE88U 已经设定为此模式。"))
    guard case .wizard(let flag, let questions) = page.save(page.modes[1]) else { Issue.record("no wizard"); return }
    #expect(flag == "lanip" && questions.count == 1 && questions[0].contains("专业访客网络 的配置文件列表将被清除") && questions[0].contains("无线接入点（AP）模式 / AiMesh 路由器（AP 模式）"))
    guard case .wizard(let repeater, let asked) = page.save(page.modes[2]) else { Issue.record("no wizard"); return }
    #expect(repeater == "sitesurvey_rep" && asked == ["若您将路由器的操作模式更改为中继模式， AiMesh 随心组网系统将会关闭。\n确定继续？"])
    #expect(page.save(page.modes[4]) == .wizard(flag: "amasnode_page", confirmations: []))
    // isSwMode("AP") makes sw_mode_orig the number 3; the express radios follow wlc_express.
    let ap = OperationModePage(values: ["sw_mode": "3", "wlc_express": "0"], operationMode: "ap", support: support)
    #expect(ap.originalMode == "3" && ap.initialMode?.id == "apMode" && ap.save(ap.modes[1]) == .alreadyConfigured(" 已经设定为此模式。"))
    guard case .wizard("rtMode", let back) = ap.save(ap.modes[0]) else { Issue.record("no wizard"); return }
    #expect(back.count == 1)
    let plain = OperationModePage(values: ["sw_mode": "2", "wlc_express": "2"], operationMode: "rp", support: ["repeater": "1", "rp_express_5g": "1"])
    #expect(plain.modes.map(\.id) == ["routerMode", "apMode", "repeaterMode", "rp_express_5g"] && plain.initialMode?.id == "rp_express_5g")
    #expect(plain.save(plain.modes[3]) == .alreadyConfigured(" 已经设定为此模式。") && plain.save(plain.modes[2]) == .wizard(flag: "sitesurvey_rep", confirmations: []))
}

// MARK: - Open NAT

private let gameScript = """
\u{FEFF}var gameProfile =
{"profile":[
{"title":"Battlefield V","port":"3659,5222","protocol":"BOTH","platform":"PC","class":"battlefield5","id":"battlefield5"},
{"title":"Battlefield V","port":"1935,3074","protocol":"BOTH","platform":"PS4","class":"battlefield5","id":"battlefield5"},
{"title":"Minecraft","port":"25565","protocol":"TCP","platform":"PC","class":"minecraft","id":"minecraft"},
]}
"""

@Test func openNATReadsTheProfilesAndDrawsTheRules() throws {
    let profiles = try #require(GameProfile.builtIn(gameScript))
    #expect(profiles.count == 3 && profiles[1].platform == "PS4" && profiles[2].protocol == "TCP")
    #expect(OpenNATPage.games(profiles).map(\.id) == ["battlefield5", "minecraft"])
    // The online list adds ids gameList does not have; titles it has stay.
    let online = [GameProfile(title: "New Title", port: "1", protocol: "TCP", platform: "PC", style: "x", id: "minecraft"),
                  GameProfile(title: "Other", port: "2", protocol: "UDP", platform: "PC", style: "y", id: "other")]
    #expect(OpenNATPage.games(online, adding: OpenNATPage.games(profiles)).map(\.title) == ["Battlefield V", "Minecraft", "Other"])
    let clients = [TORSettings.ClientEntry(mac: "AA", name: "Desk", nickName: "", ip: "192.168.50.20", online: true),
                   TORSettings.ClientEntry(mac: "BB", name: "Later", nickName: "Nick", ip: "192.168.50.20", online: true)]
    let list = "<Battlefield V@PS4>1935,3074>192.168.50.20>>BOTH><Minecraft>25565>192.168.50.9>>TCP><Manual&amp;>1000:2000,3000:4000,5000:6000>192.168.50.9>80>UDP>"
    let rules = try #require(OpenNATPage.rules(list, profiles: profiles, clients: clients))
    #expect(rules.map(\.id) == [1, 2, 3] && rules[0].platform == "PS4" && rules[0].device == "Later" && rules[1].platform == "PC")
    #expect(rules[2].name == "Manual&" && rules[2].platform == nil && rules[2].port == "1000:2000,3000..." && rules[2].fullPort.count == 29 && rules[2].internalPort == "80")
    // A rule without an external port has no length to read: the page stops drawing.
    #expect(OpenNATPage.rules("<Broken", profiles: profiles, clients: clients) == nil)
    #expect(OpenNATPage.deleting(2, from: "head" + list) == "<Battlefield V@PS4>1935,3074>192.168.50.20>>BOTH><Manual&amp;>1000:2000,3000:4000,5000:6000>192.168.50.9>80>UDP>")
}

@Test func openNATChecksANewRuleAsNewProfileOKDoes() throws {
    let page = OpenNATPage(values: ["wan0_proto": "dhcp"], builtIn: [], clients: [])
    let profiles = try #require(GameProfile.builtIn(gameScript))
    var rule = OpenNATPage.NewRule()
    rule.name = "Game"; rule.externalPort = "100-200, 300"; rule.localIP = "192.168.50.9"; rule.protocol = "UDP"
    guard case .success(let added) = page.adding(rule, to: "", profiles: profiles) else { Issue.record("not added"); return }
    // The external port is checked on a copy and saved as typed.
    #expect(added.list == "<Game>100-200, 300>192.168.50.9>>UDP>")
    rule.externalPort = "0"
    #expect(failure(page.adding(rule, to: "", profiles: profiles)) == .alert("本地 IP 或通信端口范围字段不得空白！"))
    rule.externalPort = "70000"
    #expect(failure(page.adding(rule, to: "", profiles: profiles)) == .alert("请输入一数值介于 1 至 65535"))
    rule.externalPort = "80"; rule.name = "名字"
    #expect(failure(page.adding(rule, to: "", profiles: profiles)) == .alert("本字符串无法包含：\" 名字\" !"))
    rule.name = "a%b"
    #expect(failure(page.adding(rule, to: "", profiles: profiles)) == .alert("<,>,% 是无效字符。"))
    rule.name = "Game"; rule.internalPort = "0080"
    guard case .success(let rewritten) = page.adding(rule, to: "x", profiles: profiles) else { Issue.record("not added"); return }
    #expect(rewritten.list == "x<Game>80>192.168.50.9>80>UDP>")
    rule.localIP = "192.168.50"
    #expect(failure(page.adding(rule, to: "", profiles: profiles)) == .invalidIP("192.168.50 不是有效的 IP 地址！"))
    // A game: one rule per checked platform record, named title@platform, without internal port or source.
    var game = OpenNATPage.NewRule()
    game.game = "battlefield5"; game.name = "Battlefield V"; game.localIP = "192.168.50.20"
    #expect(failure(page.adding(game, to: "", profiles: profiles)) == .alert("Please select at least one platform."))
    game.platforms = ["PS4", "PC"]
    guard case .success(let both) = page.adding(game, to: "", profiles: profiles) else { Issue.record("not added"); return }
    #expect(both.list == "<Battlefield V@PC>3659,5222>192.168.50.20>>BOTH><Battlefield V@PS4>1935,3074>192.168.50.20>>BOTH>")
    // With v6plus the Softwire check throws: nothing happens.
    rule.localIP = "192.168.50.9"
    #expect(failure(OpenNATPage(values: ["wan0_proto": "v6plus"], builtIn: [], clients: []).adding(rule, to: "", profiles: profiles)) == .stopped)
}

@Test func openNATSendsWhatThePageSends() async throws {
    let router = PageRouter(nvram: ["vts_enable_x": "0", "game_vts_rulelist": ""])
    let page = OpenNATPage(values: ["productid": "RT-BE88U", "preferred_lang": "CN", "firmver": "3.0.0.6"], builtIn: [], clients: [])
    let saved = try await client(router).saveOpenNATRules("<Game>80>192.168.50.9>>TCP>", page: page)
    let rules = try #require(await router.actions.first)
    #expect(saved.isVerified && rules.path == "start_apply.htm")
    #expect(rules.body == "productid=RT-BE88U&current_page=GameProfile.asp&next_page=GameProfile.asp&modified=0&action_wait=5&action_mode=apply"
            + "&action_script=restart_firewall&first_time=&preferred_lang=CN&firmver=3.0.0.6&game_vts_rulelist=%3CGame%3E80%3E192.168.50.9%3E%3ETCP%3E")
    let switched = try await client(router).setPortForwarding(true)
    let apply = try #require(await router.actions.last)
    #expect(switched.isVerified && apply.path == "applyapp.cgi" && apply.body.removingPercentEncoding?.contains("\"rc_service\":\"restart_firewall\"") == true)
}

// MARK: - 游戏加速

private func boost(_ values: [String: String]) -> GameBoostPage {
    let base = ["qos_enable": "0", "qos_type": "1", "rog_enable": "0", "bwdpi_game_list": "", "ctf_disable": "0", "fc_disable": "", "runner_disable": "",
                "ctf_fa_mode": "0", "TM_EULA": "1", "TM_EULA_time": "2026-01-01", "preferred_lang": "EN", "firmver": "3.0.0.6"]
    let clients = [TORSettings.ClientEntry(mac: "AA:BB:CC:DD:EE:01", name: "Console", nickName: "PS5", ip: "192.168.50.30", online: true)]
    return GameBoostPage(values: base.merging(values) { _, new in new }, support: ["adaptive_qos": "1", "gameMode": "1"], clients: clients, rebootTime: "120")
}

@Test func gameDeviceListFollowsGenGameList() {
    let page = boost(["bwdpi_game_list": "aa:bb:cc:dd:ee:01&#6011:22:33:44:55:66"])
    #expect(page.gameList == "aa:bb:cc:dd:ee:01<11:22:33:44:55:66" && page.devices("").isEmpty)
    let devices = page.devices(page.gameList)
    #expect(devices.map(\.name) == ["PS5", "New device"] && devices[0].ip == "192.168.50.30")
    // The duplicate check starts at the second entry and keeps case; the limit is `length > 64`.
    #expect(GameBoostPage.adding("", to: "a") == .failure(GameBoostPage.Alert("栏位不能为空白")))
    #expect(GameBoostPage.adding("a", to: "a") == .success("a<a") && GameBoostPage.adding("b", to: "a<b") == .failure(GameBoostPage.Alert("此项已纳入列表中。")))
    #expect(GameBoostPage.adding("B", to: "a<b") == .success("a<b<B"))
    let full = (0..<65).map { "m\($0)" }.joined(separator: "<")
    #expect(GameBoostPage.adding("x", to: full) == .failure(GameBoostPage.Alert("本表仅允许 64 项目！")) && GameBoostPage.adding("x", to: (0..<64).map { "m\($0)" }.joined(separator: "<")) != .failure(GameBoostPage.Alert("本表仅允许 64 项目！")))
    #expect(GameBoostPage.removing("b", from: "a<b<c<b") == "a<c")
}

@Test func gamePriorityChoosesServiceAndAsksForTerms() {
    #expect(boost(["TM_EULA": "0"]).asksTrendMicro && boost(["TM_EULA_time": ""]).asksTrendMicro && !boost([:]).asksTrendMicro && !boost(["qos_enable": "1", "TM_EULA": "0"]).asksTrendMicro)
    let on = boost([:]).priority(on: true, list: "a<b")
    #expect(!on.reboots && on.wait == 5 && keys(on.fields) == ["current_page", "next_page", "preferred_lang", "firmver", "action_mode", "action_script", "action_wait",
                                                                 "qos_enable", "qos_type", "bwdpi_game_list", "rog_enable"])
    #expect(value(on.fields, "qos_enable") == "1" && value(on.fields, "qos_type") == "1" && value(on.fields, "action_script") == "restart_qos;restart_firewall")
    let off = boost(["qos_enable": "1", "qos_type": "2"]).priority(on: false, list: "")
    #expect(value(off.fields, "qos_enable") == "0" && value(off.fields, "qos_type") == "2")
    // ctf_fa_mode "2" reboots unless hardware acceleration is off (ctf_disable == 1, or both fc and runner disable set).
    let reboot = boost(["ctf_fa_mode": "2"]).priority(on: true, list: "")
    #expect(reboot.reboots && reboot.wait == 120 && value(reboot.fields, "action_script") == "reboot")
    #expect(!boost(["ctf_fa_mode": "2", "ctf_disable": "1"]).priority(on: true, list: "").reboots && !boost(["ctf_fa_mode": "2", "fc_disable": "1", "runner_disable": "1"]).priority(on: true, list: "").reboots)
    #expect(value(boost(["qos_enable": "1"]).saving("x").fields, "qos_enable") == "1" && value(boost([:]).saving("x").fields, "bwdpi_game_list") == "x")
}

@Test func gameBoostAgreesToTheTermsRightAfterTheForm() async throws {
    // The terms window's 同意 runs eula_confirm (the form), then enableEula('tm', "1"); the read back covers TM_EULA.
    let router = PageRouter(nvram: ["qos_enable": "0", "qos_type": "1", "bwdpi_game_list": "", "TM_EULA": "0"])
    let receipt = try await client(router).submitGameBoost(boost(["TM_EULA": "0"]).priority(on: true, list: "a"), agreeingTrendMicro: true)
    let sent = await router.actions
    // The two go out together, as the page sends them; the order they arrive in is not fixed.
    #expect(Set(sent.map(\.path)) == ["start_apply.htm", "set_TM_EULA.cgi"] && sent.count == 2
            && sent.first { $0.path == "set_TM_EULA.cgi" }?.query == ["TM_EULA": "1"] && receipt.isVerified && receipt.verified.contains("TM_EULA"))
    // A reboot sends both as well and reads nothing back.
    let rebooting = PageRouter()
    let reboot = try await client(rebooting).submitGameBoost(boost(["ctf_fa_mode": "2", "TM_EULA": "0"]).priority(on: true, list: ""), agreeingTrendMicro: true)
    #expect(Set(await rebooting.actions.map(\.path)) == ["start_apply.htm", "set_TM_EULA.cgi"] && !reboot.isVerified && reboot.message.contains("也已发送"))
}

// MARK: - 客户端列表

@Test func clientListKeepsAddressesAndOnlineState() {
    let current = json(#"{"maclist":["aa:bb:cc:dd:ee:01","AA:BB:CC:DD:EE:02"],"aa:bb:cc:dd:ee:01":{"mac":"aa:bb:cc:dd:ee:01","name":" Desk ","nickName":"","ip":"192.168.50.20","isOnline":"1"},"AA:BB:CC:DD:EE:02":{"mac":"AA:BB:CC:DD:EE:02","name":"","nickName":"TV","ip":"192.168.50.21","isOnline":"0"}}"#)
    let history = json(#"{"maclist":["AA:BB:CC:DD:EE:03"],"AA:BB:CC:DD:EE:03":{"mac":"AA:BB:CC:DD:EE:03","name":"Old <1>","nickName":"","vendor":"X"}}"#)
    let list = TORSettings.clientList(current: current, history: history, lanMAC: "04:42:1A:00:00:01", productID: "RT-BE88U", amas: true)
    #expect(list.map(\.mac) == ["AA:BB:CC:DD:EE:01", "AA:BB:CC:DD:EE:02", "AA:BB:CC:DD:EE:03", "04:42:1A:00:00:01"])
    #expect(list[0].name == "Desk" && list[0].ip == "192.168.50.20" && list[0].online && !list[1].online && list[1].name == "AA:BB:CC:DD:EE:02")
    #expect(list[2].ip == "offline" && list[2].name == "Old &lt;1&gt;" && list[3].name == "RT-BE88U")
    // clientNames, built on it, is unchanged: nickName when set, else name.
    #expect(TORSettings.clientNames(current: current, history: history, lanMAC: "04:42:1A:00:00:01", productID: "RT-BE88U", amas: true)["AA:BB:CC:DD:EE:02"] == "TV")
}

// MARK: - Round 1 review

@Test func openNATWritesAGoodAddressBackAsItsNumbers() throws {
    var address = "192.168.050.009"
    #expect(WebValidator.ipAddrFinal(&address) == nil && address == "192.168.50.9")
    let page = OpenNATPage(values: ["wan0_proto": "dhcp"], builtIn: [], clients: [])
    var rule = OpenNATPage.NewRule()
    rule.name = "Game"; rule.externalPort = "80"; rule.localIP = "192.168.050.009"
    guard case .success(let added) = page.adding(rule, to: "", profiles: []) else { Issue.record("not added"); return }
    #expect(added.list == "<Game>80>192.168.50.9>>TCP>")
    // A hidden internal port is still checked after a game card was chosen (quickAddRule keeps it).
    var game = OpenNATPage.NewRule()
    game.game = "battlefield5"; game.platforms = ["PC"]; game.name = "Battlefield V"; game.localIP = "192.168.50.20"; game.internalPort = "70000"
    let profiles = try #require(GameProfile.builtIn(gameScript))
    #expect(failure(page.adding(game, to: "", profiles: profiles)) == .alert("请输入一数值介于 1 至 65535"))
}

@Test func portForwardingSwitchKeepsThePagesMemberOrder() async throws {
    let router = PageRouter(nvram: ["vts_enable_x": "0"])
    _ = try await client(router).setPortForwarding(true)
    let body = try #require(await router.actions.last?.body.removingPercentEncoding)
    #expect(body == #"{"vts_enable_x":"1","action_mode":"apply","action_wait":"5","rc_service":"restart_firewall"}"#)
}

@Test func dropDownListsLeaveOutMeshNodesAndUnknownOfflineClients() {
    let current = json(#"{"maclist":["AA:AA:AA:AA:AA:01","AA:AA:AA:AA:AA:02"],"AA:AA:AA:AA:AA:01":{"mac":"AA:AA:AA:AA:AA:01","name":"Desk","nickName":"","ip":"192.168.50.20","isOnline":"1","from":"networkmapd"},"AA:AA:AA:AA:AA:02":{"mac":"AA:AA:AA:AA:AA:02","name":"Node","nickName":"","ip":"192.168.50.2","isOnline":"1","amesh_isRe":"1","from":"networkmapd"}}"#)
    let history = json(#"{"maclist":["AA:AA:AA:AA:AA:03","AA:AA:AA:AA:AA:04"],"AA:AA:AA:AA:AA:03":{"mac":"AA:AA:AA:AA:AA:03","name":"Old","vendor":"X","from":"nmpClient"},"AA:AA:AA:AA:AA:04":{"mac":"AA:AA:AA:AA:AA:04","name":"Other","vendor":"X","from":"customList"}}"#)
    let list = TORSettings.clientList(current: current, history: history, lanMAC: "04:42:1A:00:00:01", productID: "RT-BE88U", amas: true)
    #expect(list.map(\.from) == ["networkmapd", "networkmapd", "nmpClient", "customList", "manual"] && list[1].meshNode && !list[1].online)
    let shown = TORSettings.dropdownClients(list)
    #expect(shown.online.map(\.mac) == ["AA:AA:AA:AA:AA:01"] && shown.offline.map(\.mac) == ["AA:AA:AA:AA:AA:03"])
    let long = TORSettings.ClientEntry(mac: "X", name: String(repeating: "n", count: 33))
    #expect(TORSettings.dropdownName(long) == String(repeating: "n", count: 30) + ".." && TORSettings.dropdownName(TORSettings.ClientEntry(mac: "X", name: "a", nickName: "b")) == "b")
}

@Test func keyPressesAreFilteredAsThePagesFilterThem() {
    func number(_ old: String, _ new: String, _ key: Character?, _ limit: Int = 5) -> String {
        WebValidator.edit(old, new, typed: key, maxLength: limit, keyPress: WebValidator.numberKeyPress)
    }
    // isNumber: a typed letter does nothing, also over a selection; a paste stays, one character or more, for the checks.
    #expect(number("80", "80a", "a") == "80" && number("80", "808", "8") == "808" && number("5", "a", "a", 2) == "5")
    #expect(number("123", "123x", nil) == "123x" && number("", "123x", nil) == "123x" && number("5", "a", nil, 2) == "a")
    // maxlength stops a typed key and cuts what a paste inserts, keeping the text around it.
    #expect(number("12345", "123456", "6") == "12345" && number("", "1234567", nil) == "12345" && number("12345", "1235", "5") == "1235")
    #expect(number("123x", "45123x", nil) == "4123x" && number("3600", "12343600", nil, 6) == "123600" && number("3600", "36123400", nil, 6) == "361200")
    // isHWAddr: twelve hex digits typed give the colons; other keys do nothing; a paste is kept (to 17 characters).
    func hardware(_ old: String, _ new: String, _ key: Character?) -> String {
        WebValidator.edit(old, new, typed: key, maxLength: 17, keyPress: WebValidator.hardwareAddressKeyPress)
    }
    var mac = ""
    for character in "AABBCCDDEEFF" { mac = hardware(mac, mac + String(character), character) }
    #expect(mac == "AA:BB:CC:DD:EE:FF")
    #expect(hardware("AA", "AAG", "G") == "AA" && hardware("AA", "AA:", ":") == "AA:" && hardware("AA:BB", "AA:BG", "G") == "AA:BB")
    // A key typed over a selection: the script appends ":" to the whole value, the caret goes to its end, the key goes in there.
    #expect(hardware("AA:BB", "AA:BC", "C") == "AA:BB:C")
    #expect(hardware("AA", "AAB", nil) == "AAB" && hardware("", "AABBCCDDEEFF", nil) == "AABBCCDDEEFF")
    #expect(hardware("AA:BB:CC:DD:EE:FF", "AA:BB:CC:DD:EE:FF1", "1") == "AA:BB:CC:DD:EE:FF")
    // A full field takes nothing from a paste, wherever it goes; a paste over a selection replaces it within the limit.
    #expect(hardware("AA:BB:CC:DD:EE:FF", "1AA:BB:CC:DD:EE:FF", nil) == "AA:BB:CC:DD:EE:FF")
    #expect(hardware("AA:BB:CC:DD:EE:FF", "AA:BB:12345:DD:EE:FF", nil) == "AA:BB:12:DD:EE:FF")
}

@Test func passwordAlertsDoNotShowThePassword() {
    // A password outside printable ASCII: the rule is stated, the characters are not; "<" and ">" as the page says them.
    let alert = WebValidator.blockSecretChars("щ€pass", ["<", ">"])
    #expect(alert != nil && !(alert ?? "").contains("щ") && !(alert ?? "").contains("€"))
    #expect(WebValidator.blockSecretChars("pa<ss", ["<", ">"]) == "<,> 是无效字符。" && WebValidator.blockSecretChars("pass", ["<", ">"]) == nil)
    #expect(WebValidator.blockChars("名称", ["<"]) == "本字符串无法包含：\" 名称\" !")
    let family = WebValidator.secretString("pass€щ")
    #expect(family != nil && !(family ?? "").contains("€") && WebValidator.secretString("\"pass") == "第一个字符不能是： [\"]")
}

@Test func pastesAreCutWhereTheTextFieldPutThem() {
    func port(_ old: String, _ new: String, _ key: Character?, _ replaced: Range<Int>?, _ limit: Int = 5) -> String {
        WebValidator.edit(old, new, typed: key, maxLength: limit, replaced: replaced, keyPress: WebValidator.numberKeyPress)
    }
    // "4433" pasted before or after "443" gives the same text; the field's range tells which end the old value keeps.
    #expect(port("443", "4433443", nil, 0..<0) == "44443" && port("443", "4433443", nil, 3..<3) == "44334")
    #expect(port("443", "4433443", nil, nil) == "44334")
    // Over a selection: the rest of the old text leaves the room, the selection goes even when nothing fits.
    #expect(port("443", "44433", nil, 1..<3, 4) == "4443" && port("12345", "1abc345", nil, 1..<2) == "1a345")
    #expect(port("123456", "1x3456", nil, 1..<2) == "13456" && port("123456", "9", nil, 0..<6) == "9")
    // A typed key without room: what it replaced goes all the same (a value longer than maxlength, from the router).
    #expect(port("123456", "923456", "9", 0..<1) == "23456" && port("123456", "923456", "9", nil) == "123456")
    #expect(port("12345", "123456", "6", 5..<5) == "12345")
    // A range that does not fit the two texts is not used.
    #expect(port("443", "4433443", nil, 2..<9) == "44334" && port("123", "129993", nil, 0..<0, 4) == "1293")
}

@Test func gameBoostChecksAgainOnceTheRouterIsBack() async throws {
    let page = boost(["ctf_fa_mode": "2", "TM_EULA": "0"])
    let sending = page.priority(on: true, list: "a")
    let router = PageRouter(nvram: ["qos_enable": "1", "qos_type": "1", "bwdpi_game_list": "a", "TM_EULA": "1"])
    let checked = try await client(router).checkGameBoost(sending, agreeingTrendMicro: true)
    #expect(checked.isVerified && checked.verified == ["qos_enable", "qos_type", "bwdpi_game_list", "TM_EULA"])
    let unchanged = PageRouter(nvram: ["qos_enable": "0", "qos_type": "1", "bwdpi_game_list": "", "TM_EULA": "0"])
    #expect(try await client(unchanged).checkGameBoost(sending, agreeingTrendMicro: true).unverified == ["qos_enable", "bwdpi_game_list", "TM_EULA"])
}

@Test func dualWANChecksTheSentValuesOnceTheRouterIsBack() async throws {
    let submission = DualWANSubmission(fields: [.init(name: "current_page", value: "Advanced_WANPort_Content.asp"), .init(name: "wans_dualwan", value: "wan lan"),
                                                .init(name: "wans_mode", value: "lb"), .init(name: "wans_routing_rulelist", value: "<all>8.8.8.8>1"),
                                                .init(name: "wans_mode", value: "fo"), .init(name: "wandog_enable", value: "1")])
    let router = PageRouter(nvram: ["wans_dualwan": "wan lan", "wans_mode": "lb", "wans_routing_rulelist": "&#60all&#628.8.8.8&#621", "wandog_enable": "0"])
    let checked = try await client(router).checkDualWAN(submission)
    // The first wans_mode is the one httpd takes; current_page and the like are not read.
    #expect(checked.verified == ["wans_dualwan", "wans_mode", "wans_routing_rulelist"] && checked.unverified == ["wandog_enable"])
    // The form's helper fields (wans_primary, the ratio boxes, …) only build the kept values and are not read back;
    // wanN_enable is kept through validate_instance, wl_ssid is not this page's.
    let helpers = DualWANSubmission(fields: [.init(name: "wans_primary", value: "wan"), .init(name: "wans_lb_ratio_0", value: "3"),
                                             .init(name: "wans_lb_ratio", value: "3:1"), .init(name: "wan1_enable", value: "1"),
                                             .init(name: "wl_ssid", value: "x"), .init(name: "dns_probe", value: "1")])
    let kept = PageRouter(nvram: ["wans_lb_ratio": "3:1", "wan1_enable": "1", "dns_probe": "1"])
    let read = try await client(kept).checkDualWAN(helpers)
    #expect(read.isVerified && read.verified == ["dns_probe", "wan1_enable", "wans_lb_ratio"])
}

// MARK: - Menu

@Test func batchTwoPagesHaveNativeHomes() {
    let pages: [(NativeFeature, String)] = [(.aiCloud, "cloud_main.asp"), (.aiCloudSettings, "cloud_settings.asp"),
                                            (.operationMode, "Advanced_OperationMode_Content.asp"), (.openNAT, "GameProfile.asp"), (.gameBoost, "GameBoost.asp")]
    for (feature, page) in pages { #expect(WebMenuCatalog.location(of: feature)?.page == page, "\(page)") }
    // The second WAN's IPv6 is a native page on the IPv6 page's 第二 WAN part (IPv61PageTests covers it).
    #expect(WebMenuCatalog.location(of: .ipv6SecondWAN)?.part == "ipv6-2")
}

// MARK: - Reads

@Test func batchTwoPagesReadWhatThePagesRead() async throws {
    let router = PageRouter(nvram: ["webdav_https_port": "443", "sw_mode": "1", "lan_hwaddr": "04:42:1A:00:00:01", "productid": "RT-BE88U", "reboot_time": "120"],
                            support: ["cloudsync": 1, "rrsut": 1, "amas": 2, "amasRouter": 1],
                            hooks: ["wanlink-ipaddr": "\"100.64.1.2\"", "get_operation_mode": "\"rt\"", "get_default_reboot_time": "120"],
                            pages: ["js/gameProfile.js": gameScript, "ajax/collected_FAQ.json": #"[{"Page":"cloud_main.asp","FAQ_Link":"178"},{"Page":"Advanced_OperationMode_Content.asp","FAQ_Link":"196"}]"#])
    let aiCloud = try await client(router).aiCloudPage()
    #expect(aiCloud.wanIP == "100.64.1.2" && aiCloud.builtIn && aiCloud.access == .asusDomain("https://www.asusrouter.com", stopped: false))
    #expect(try await client(router).operationModePage().operationMode == "rt")
    #expect(try await client(router).openNATPage().builtIn.count == 3)
    #expect(try await client(router).gameBoostPage().rebootTime == "120")
    #expect(try await client(router).faqNumber(page: "cloud_main.asp") == "178")
    #expect(try await client(router).faqNumber(page: "nope") == nil)
    // Nothing above writes.
    #expect(await router.actions.allSatisfy { $0.method == "GET" })
}
