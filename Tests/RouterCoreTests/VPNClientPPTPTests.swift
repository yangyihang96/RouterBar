import Foundation
import Testing
@testable import RouterCore

// VPN › VPN 客户端 › PPTP/L2TP（Advanced_VPNClient_Content.asp + VPN/vpnc.html）：三条列表的格式、两种分支的显示与状态、表单的
// 校验与提示，以及每个写入的完整请求和读回。

// MARK: - A router for this page

/// nvram_char_to_ascii's answer: every byte but ASCII letters and digits as %XX.
private func ascii(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")) ?? value
}
private func json(_ text: String) -> OrderedJSON { try! OrderedJSON(data: Data(text.utf8)) }

/// Answers appGet hooks (nvram_char_to_ascii from `nvram`; get_ui_support and other hooks as the JSON text given, so numbers
/// stay numbers) and applyapp.cgi like the router: the members written into `nvram` in order, restart_default_wan moving
/// vpnc_default_wan_tmp into vpnc_default_wan. Records every request with its decoded body.
private actor VPNCRouter: RouterTransport {
    var nvram: [String: String]
    let support: String
    let hooks: [String: String]
    /// Whether restart_default_wan moves vpnc_default_wan_tmp into vpnc_default_wan (it always clears the tmp).
    let defaultApplies: Bool
    private(set) var requests: [(method: String, path: String, query: String, body: String)] = []

    init(nvram: [String: String], support: String = "{}", hooks: [String: String] = [:], defaultApplies: Bool = true) {
        self.nvram = nvram; self.support = support; self.hooks = hooks; self.defaultApplies = defaultApplies
    }

    func send(_ request: URLRequest) async throws -> RouterHTTPResponse {
        guard let url = request.url else { throw RouterError.network("no url") }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "hook" }?.value ?? ""
        let body = request.httpBody.map { String(decoding: $0, as: UTF8.self).removingPercentEncoding ?? "" } ?? ""
        let path = String(url.path.drop { $0 == "/" })
        requests.append((request.httpMethod ?? "GET", path, query, body))
        switch path {
        case "appGet.cgi":
            var parts: [String] = []
            for call in query.split(separator: ";").map(String.init) {
                guard let open = call.firstIndex(of: "(") else { continue }
                let name = String(call[..<open])
                let arguments = call[call.index(after: open)..<call.index(before: call.endIndex)].split(separator: ",").map(String.init)
                if name == "nvram_char_to_ascii", let key = arguments.first {
                    parts.append("\"\(key)\":\"" + ascii(nvram[key] ?? "") + "\"")
                } else if name == "get_ui_support" {
                    parts.append("\"get_ui_support\":" + support)
                } else if let answer = hooks[name] {
                    parts.append("\"\(name)\":" + answer)
                }
            }
            return RouterHTTPResponse(data: Data(("{\n" + parts.joined(separator: ",\n") + "\n}\n").utf8), status: 200)
        case "applyapp.cgi":
            let object = try OrderedJSON(data: Data(body.utf8))
            for (key, value) in object.members where !["action_mode", "rc_service"].contains(key) { nvram[key] = value.text }
            let service = object["rc_service"]?.text ?? ""
            if service.contains("restart_default_wan"), let tmp = nvram["vpnc_default_wan_tmp"], !tmp.isEmpty {
                if defaultApplies { nvram["vpnc_default_wan"] = tmp }
                nvram["vpnc_default_wan_tmp"] = ""
            }
            return RouterHTTPResponse(data: try JSONSerialization.data(withJSONObject: ["modify": "1", "run_service": service]), status: 200)
        default:
            return RouterHTTPResponse(data: Data(), status: 404)
        }
    }
    nonisolated func cancel() {}
    var posts: [String] { requests.filter { $0.path == "applyapp.cgi" }.map(\.body) }
    func value(_ key: String) -> String? { nvram[key] }
}

private func client(_ router: VPNCRouter) throws -> RouterClient { RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: router, writes: .reference) }

private func vpnPage(_ nvram: [String: String], support: String = "{}", hooks: [String: String] = [:], mode: String = "rt",
                  clients: [TORSettings.ClientEntry] = []) -> VPNClientPage {
    VPNClientPage(support: json(support), encoded: nvram.mapValues(ascii), hooks: hooks.mapValues(json), operationMode: mode, clients: clients)
}
private func success<T, E>(_ result: Result<T, E>) -> T? { if case .success(let value) = result { value } else { nil } }
private func failure<T, E>(_ result: Result<T, E>) -> E? { if case .failure(let error) = result { error } else { nil } }

/// Without Fusion: three profiles, the first the running client.
private let plainList = "Office>PPTP>vpn.example.com>alice>secret<Lab>L2TP>10.0.0.1>bob>pw<Old>OpenVPN>2>carol>pw2"
private let running = ["vpnc_proto": "pptp", "vpnc_heartbeat_x": "vpn.example.com", "vpnc_pppoe_username": "alice", "vpnc_pppoe_passwd": "secret",
                       "vpnc_state_t": "2", "vpnc_sbstate_t": "0"]
private func plainPage(_ extra: [String: String] = [:], support: String = "{}") -> VPNClientPage {
    vpnPage(["vpnc_clientlist": plainList, "vpnc_pptp_options_x_list": "<+mppe-128<auto<auto"].merging(running) { $1 }.merging(extra) { $1 }, support: support)
}
/// Fusion: Home (active, 3, the default connection), Work (4), Lab (active, 5).
private let fusionList = "Home>PPTP>1.2.3.4>u>p>1>3>>>0>0>Web<Work>L2TP>5.6.7.8>v>q>0>4>>>0>0>Web<Lab>PPTP>9.9.9.9>w>r>1>5>>>0>0>Web"
private let fusionHooks = ["get_vpnc_nondef_wan_prof_list": #""3>0<4>0<5>1""#, "get_vpnc_status": #""2>0>3<5>0>4<4>2>5""#, "get_wan_unit": "0"]
private let wan = ["wans_dualwan": "wan none", "sw_mode": "1", "wan0_state_t": "2", "wan0_sbstate_t": "0", "wan0_auxstate_t": "0", "link_internet": "2",
                   "wan0_ipaddr": "100.64.1.2", "wan0_proto": "dhcp"]
private func fusionPage(_ extra: [String: String] = [:], support: String = #"{"real_vpn_fusion":1,"dualwan":1}"#, hooks: [String: String] = [:],
                        mode: String = "rt", clients: [TORSettings.ClientEntry] = []) -> VPNClientPage {
    vpnPage(["vpnc_clientlist": fusionList, "vpnc_pptp_options_x_list": "<auto<auto<auto", "vpnc_default_wan": "3"].merging(wan) { $1 }.merging(extra) { $1 },
         support: support, hooks: fusionHooks.merging(hooks) { $1 }, mode: mode, clients: clients)
}

// MARK: - The lists

@Test func profilesReadAndWriteTheListsAsThePageDoes() {
    // Without Fusion: the active and vpnc_idx fields are written empty, region is dropped, the field after it always empty.
    let plain = VPNClientProfile.profiles("Office>PPTP>vpn.example.com>alice>pa&ss>1>3>JP>x>2>1>App<Lab>L2TP>10.0.0.1>bob>pw", options: "<+mppe-128<",
                                          fusion: false, defaultSupport: [:], defaultWAN: "")
    #expect(plain.map(\.idx) == [0, 1] && plain[0].pptpOptions == "+mppe-128" && plain[1].pptpOptions == "auto" && plain[0].region == "")
    let lists = VPNClientProfile.lists(plain, fusion: false)
    #expect(lists.clientlist == "Office>PPTP>vpn.example.com>alice>pa&ss>>>>>2>1>App<Lab>L2TP>10.0.0.1>bob>pw>>>>>0>0>Web")
    #expect(lists.options == "<+mppe-128<auto")
    // Fusion: active "1", vpnc_idx, region; a missing field is undefined and written as "undefined".
    let fusion = VPNClientProfile.profiles("Home>PPTP>1.2.3.4>u>p>1>3>JP>x>2>1>App<Bare", options: "", fusion: true, defaultSupport: ["3": true], defaultWAN: "3")
    #expect(fusion[0].activate && fusion[0].vpncIndex == .string("3") && fusion[0].defaultWANSupported && fusion[0].defaultWANSelected && fusion[0].region == "JP")
    #expect(fusion[1].proto == nil && fusion[1].vpncIndex == nil && fusion[1].region == nil && !fusion[1].activate)
    #expect(VPNClientProfile.lists(fusion, fusion: true).clientlist
        == "Home>PPTP>1.2.3.4>u>p>1>3>JP>>2>1>App<Bare>undefined>undefined>undefined>undefined>0>undefined>undefined>>0>0>Web")
    #expect(VPNClientProfile.lists(fusion, fusion: true).options == "<auto<auto")
    // The PPTP option is read at the entry's split index + 1, empty segments counted: a leading "<" shifts it.
    #expect(VPNClientProfile.profiles("<A>PPTP>s>u>p", options: "<x<+mppe-40", fusion: false, defaultSupport: [:], defaultWAN: "")[0].pptpOptions == "+mppe-40")
    // An empty option reads "auto" and the next one keeps its place.
    #expect(VPNClientProfile.profiles("A>PPTP>s>u>p<B>PPTP>t>u>p", options: "<<+mppe-40", fusion: false, defaultSupport: [:], defaultWAN: "").map(\.pptpOptions) == ["auto", "+mppe-40"])
    #expect(VPNClientProfile.defaultSupport("1>0<3>1<7") == ["1": true, "3": false, "7": false])
}

@Test func fusionRulesAndBindingsReadAsThePageReadsThem() throws {
    let dhcp = "<aa:bb:cc:dd:ee:01>192.168.50.10>>pc<AA:BB:CC:DD:EE:02>192.168.50.11>8.8.8.8>tv"
    let rules = "1>192.168.50.10>>3><0>192.168.50.11>>3<1>>>3>br1<1>192.168.50.99>>3><1>2"
    let read = try #require(VPNClientPolicies.read(dhcp: ascii(dhcp), rules: ascii(rules)))
    #expect(read.bindings.map(\.mac) == ["AA:BB:CC:DD:EE:01", "AA:BB:CC:DD:EE:02"] && read.readDHCP == dhcp && read.readRules == rules)
    // A rule needs four fields and a binding for its IP (or br1/br2); its MAC, DNS and host name come from the binding.
    #expect(read.rules.count == 3 && read.rules[0].mac == "AA:BB:CC:DD:EE:01" && read.rules[0].hostname == "pc" && read.rules[1].brifname == "" && read.rules[2].wireless)
    // Written back with "<" before every binding, the MAC upper-cased and five fields to a rule: both now differ from what was read.
    #expect(read.dhcpList == "<AA:BB:CC:DD:EE:01>192.168.50.10>>pc<AA:BB:CC:DD:EE:02>192.168.50.11>8.8.8.8>tv")
    #expect(read.ruleList == "1>192.168.50.10>>3><0>192.168.50.11>>3><1>>>3>br1")
    // dhcp_staticlist is decoded twice: a stored "%" stops the script, a stored "%41" becomes "A".
    #expect(VPNClientPolicies.read(dhcp: ascii("<AA>1.1.1.1>>50%"), rules: "") == nil)
    #expect(VPNClientPolicies.read(dhcp: ascii("<AA>1.1.1.1>>%41"), rules: "")?.bindings.first?.hostname == "A")
    // Text before the first "<" is not a binding; a VPN Wi-Fi rule with an IP that has no binding throws (`.mac` of undefined).
    #expect(VPNClientPolicies.read(dhcp: ascii("junk<AA>1.1.1.1>>h"), rules: "")?.bindings.count == 1)
    #expect(VPNClientPolicies.read(dhcp: "", rules: ascii("1>192.168.50.77>>3>br2")) == nil)
}

@Test func devicesAndTheDeviceListFollowTheRules() throws {
    let read = try #require(VPNClientPolicies.read(dhcp: ascii("<aa:bb:cc:dd:ee:01>192.168.50.10>>pc<AA:BB:CC:DD:EE:02>192.168.50.11>8.8.8.8>tv"),
                                                   rules: ascii("1>192.168.50.10>>3><0>192.168.50.11>>3><1>>>3>br1")))
    let base = [TORSettings.ClientEntry(mac: "AA:BB:CC:DD:EE:02", name: "TV", ip: "192.168.50.11", online: true),
                TORSettings.ClientEntry(mac: "AA:BB:CC:DD:EE:03", name: "Phone", nickName: "My phone", ip: "192.168.50.5", online: true),
                TORSettings.ClientEntry(mac: "AA:BB:CC:DD:EE:04", name: "Node", ip: "192.168.50.2", online: true, meshNode: true),
                TORSettings.ClientEntry(mac: "AA:BB:CC:DD:EE:05", name: "Old")]
    // initial() adds the devices of rules and bindings that clientList lacks, named by their MAC.
    let clients = VPNClientPage.clients(base, adding: read)
    #expect(clients.map(\.mac) == base.map(\.mac) + ["AA:BB:CC:DD:EE:01", ""] && clients[4].ip == "192.168.50.10" && clients[4].from == "vpnc_dev_policy")
    // The profile's devices by IP, the VPN Wi-Fi rule left out; the switch shows activate == true.
    let devices = read.devices(of: "3", clients: clients)
    #expect(devices.map(\.name) == ["AA:BB:CC:DD:EE:01", "TV"] && devices.map(\.on) == [true, false] && devices.map(\.rule) == [0, 1])
    var toggled = read
    toggled.toggle(1)
    #expect(toggled.rules[1].activate == "1" && toggled.ruleList == "1>192.168.50.10>>3><1>192.168.50.11>>3><1>>>3>br1")
    // 设备: online devices by inet_network of the IP, without AiMesh nodes; another profile's IPs are disabled.
    let choices = read.choices(for: "3", clients: clients)
    #expect(choices.map(\.name) == ["My phone", "AA:BB:CC:DD:EE:01", "TV"] && choices.map(\.checked) == [false, true, true])
    #expect(read.choices(for: "4", clients: clients).map(\.taken) == [false, true, true])
    // 确认 with the phone and .10: a binding for the phone, a rule for it, the unchecked TV's rule gone, br1 kept.
    let assigned = try #require(success(read.assigning([choices[0], choices[1]], to: "3")))
    #expect(assigned.ruleList == "1>192.168.50.10>>3><1>>>3>br1<1>192.168.50.5>>3>")
    #expect(assigned.dhcpList == "<AA:BB:CC:DD:EE:01>192.168.50.10>>pc<AA:BB:CC:DD:EE:02>192.168.50.11>8.8.8.8>tv<AA:BB:CC:DD:EE:03>192.168.50.5>>")
    // 64 bindings or more stop it with the alert.
    let full = try #require(VPNClientPolicies.read(dhcp: ascii((1...63).map { "<00:00:00:00:00:\(String($0, radix: 16))>10.0.0.\($0)>>" }.joined()), rules: ""))
    let extra = VPNClientPolicies.Choice(id: 0, mac: "00:00:00:00:01:00", ip: "10.0.1.1", name: "x", checked: false, taken: false)
    #expect(failure(full.assigning([extra], to: "3"))?.message == "您的规则已达到最大数量。 手动指定 IP 的 DHCP 列表 (最多限制： 64) 如果您想添加新规则，请删除不使用的规则。")
    let fewer = try #require(VPNClientPolicies.read(dhcp: ascii((1...62).map { "<00:00:00:00:00:\(String($0, radix: 16))>10.0.0.\($0)>>" }.joined()), rules: ""))
    #expect(success(fewer.assigning([extra], to: "3"))?.bindings.count == 63)
}

// MARK: - What the page shows

@Test func statusTextsFollowThePage() {
    // vpnc_state_t compared with numbers: "" counts as 0, so a blank state is 正在连接….
    #expect(VPNClientStatus.pptp(state: "", sub: "") == VPNClientStatus(on: true, text: "正在连接…", error: nil))
    #expect(VPNClientStatus.pptp(state: "2", sub: "0").text == "已联机" && VPNClientStatus.pptp(state: "4", sub: "0").text == "正在连接…")
    #expect(VPNClientStatus.pptp(state: "4", sub: "2") == VPNClientStatus(on: true, text: "连接失败", error: "授权失败"))
    #expect(VPNClientStatus.pptp(state: "4", sub: "7").error == "IP / 路由冲突" && VPNClientStatus.pptp(state: "3", sub: "0") == VPNClientStatus(on: true, text: "连接失败", error: nil))
    #expect(VPNClientStatus.fusion(["5", "0", "1"]).text == "未联机" && VPNClientStatus.fusion(["4", "0", "1"]).text == "正在初始化，请稍候")
    #expect(VPNClientStatus.fusion(["6", "7", "1"]) == VPNClientStatus(on: true, text: "连接失败", error: "IP / 路由冲突"))
    #expect(VPNClientStatus.fusion(["0", "2", "1"]).error == "授权失败" && VPNClientStatus.fusion(["4", "3", "1"]).text == "其他" && VPNClientStatus.fusion(["4"]).text == "其他")
    #expect(VPNClientStatus.fusion(["3", "0", "1"]).text == "" && VPNClientStatus.fusion(nil).text == "")
    #expect(VPNClientStatus.openVPN(state: "-1", errno: "5") == VPNClientStatus(on: true, text: "连接失败", error: "授权失败"))
}

@Test func nvramGetAnswersAsTheBrowserParsesThem() {
    var cache = NvramGetCache()
    // A backslash that starts no JSON escape fails the answer: every name asked reads "" and nothing is kept.
    let encoded = ["a": ascii("CORP\\alice"), "b": ascii("plain"), "c": ascii("中&\""), "d": ascii("x\\ty")]
    #expect(cache.get(["a", "b"], force: false, encoded: encoded) == ["a": "", "b": ""])
    #expect(cache.get(["b"], force: false, encoded: encoded) == ["b": "plain"])
    #expect(cache.get(["a", "b"], force: false, encoded: encoded) == ["a": "", "b": "plain"])
    // nvram_get writes bytes outside printable ASCII, and " & < >, as "&#" and the number; "\t" is a JSON escape.
    #expect(cache.get(["c", "d"], force: false, encoded: encoded) == ["c": "&#228&#184&#173&#38&#34", "d": "x\ty"])
    // Kept values stay until a forced read.
    #expect(cache.get(["b"], force: false, encoded: ["b": ascii("changed")]) == ["b": "plain"] && cache.get(["b"], force: true, encoded: ["b": ascii("changed")]) == ["b": "changed"])
}

@Test func withoutFusionTheRunningClientMarksOneProfile() {
    let page = plainPage()
    #expect(!page.fusion && page.title == "VPN 客户端" && page.maximum == 10 && page.stop == nil && page.internet == nil)
    #expect(page.statuses[0] == VPNClientStatus(on: true, text: "已联机", error: nil) && page.statuses[1] == .off && page.statuses[2] == .off)
    #expect(page.profiles.map(\.activate) == [true, false, false] && page.listLimitNote == "规则的最大数量为 10。")
    // Only the first of two matching profiles (check_profile_status takes [0]).
    let twice = vpnPage(["vpnc_clientlist": "A>PPTP>vpn.example.com>alice>secret<B>PPTP>vpn.example.com>alice>secret"].merging(running) { $1 })
    #expect(twice.statuses[0]?.on == true && twice.statuses[1] == .off)
    // nvram_get writes "&" as "&#38": a password with it never matches the stored one.
    #expect(plainPage(["vpnc_clientlist": "Office>PPTP>vpn.example.com>alice>pa&ss", "vpnc_pppoe_passwd": "pa&ss"]).statuses[0] == .off)
    // A domain user name: the backslash fails the running client's answer, so nothing shows connected.
    #expect(plainPage(["vpnc_clientlist": "Office>PPTP>vpn.example.com>CORP\\alice>secret", "vpnc_pppoe_username": "CORP\\alice"]).statuses[0] == .off)
    // A profile without a protocol: the list stops drawing there, no status is read.
    let broken = vpnPage(["vpnc_clientlist": "Office>PPTP>s>u>p<Bare<Lab>L2TP>s2>u>p"])
    #expect(broken.stop == .drawing(1) && broken.statuses[0] == .off && broken.statuses[2] == nil)
    // A list decodeURIComponent rejects: nothing is drawn.
    #expect(VPNClientPage(support: json("{}"), encoded: ["vpnc_clientlist": "%E4%B8"], hooks: [:], operationMode: "rt", clients: []).stop == .profiles)
}

@Test func theFiveSecondCheckReadsWhatThePageReadsAgain() {
    let first = plainPage()
    // A new state shows; the running client stays as first read until a switch makes the check read it again first.
    let moved = ["vpnc_state_t": ascii("4"), "vpnc_sbstate_t": ascii("2"), "vpnc_heartbeat_x": ascii("other.example.com")]
    #expect(first.polled(encoded: moved, refreshingClient: false).statuses[0] == VPNClientStatus(on: true, text: "连接失败", error: "授权失败"))
    #expect(first.polled(encoded: moved, refreshingClient: true).statuses[0] == .off)
    let fusion = fusionPage()
    #expect(fusion.polled(hooks: ["get_vpnc_status": .string("1>0>3<5>0>5")], refreshingClient: false).statuses[0]?.text == "正在连接…")
}

@Test func fusionShowsActiveProfilesTheirStatusesAndTheInternetItem() {
    let page = fusionPage()
    #expect(page.fusion && page.title == "VPN Fusion" && page.maximum == 16 && page.stop == nil)
    #expect(page.statuses[0] == VPNClientStatus(on: true, text: "已联机", error: nil) && page.statuses[1] == .off
        && page.statuses[2] == VPNClientStatus(on: true, text: "连接失败", error: "授权失败"))
    #expect(page.tags(page.profiles[0]) == ["默认连接"] && page.profiles[0].defaultWANSupported && !page.profiles[2].defaultWANSupported)
    #expect(page.internet == VPNClientInternetItem(wan: VPNClientWAN(status: "connected", statusText: "已联机", ip: "100.64.1.2", protoText: "动态 IP"), isDefault: false))
    #expect(page.activeLimitNote == "由于并发活动 VPN 连接数上限最大为 2。请先停用一个现用 VPN 连接后再启用另一个。")
    #expect(page.profiles[0].nameTitle == "连接名称: Home")
}

@Test func isSupportHandsThePageTheValueItself() {
    // "0" as text is truthy in JavaScript, 0 as a number is not.
    #expect(vpnPage([:], support: #"{"real_vpn_fusion":"0"}"#, hooks: fusionHooks).fusion)
    #expect(!vpnPage([:], support: #"{"real_vpn_fusion":0}"#).fusion)
    // MaxRule_VPN_FUSION_Conn: "0" or missing gives 2, otherwise parseInt (NaN for text without digits).
    #expect(fusionPage(support: #"{"real_vpn_fusion":1,"MaxRule_VPN_FUSION_Conn":"3"}"#).activeLimitNote.contains("最大为 3。"))
    #expect(fusionPage(support: #"{"real_vpn_fusion":1,"MaxRule_VPN_FUSION_Conn":"x"}"#).activeLimitNote.contains("最大为 NaN。"))
    // Without get_vpnc_nondef_wan_prof_list as text update_vpnc_clientlist_json throws; rules that do not decode stop initial() too.
    #expect(vpnPage(["vpnc_clientlist": fusionList], support: #"{"real_vpn_fusion":1}"#).stop == .profiles)
    #expect(fusionPage(["dhcp_staticlist": "<AA>1.1.1.1>>50%"]).stop == .policies)
}

@Test func theInternetCardShowsTheWANsAsGetWanInfoDoes() {
    // Dual WAN in fail-over: the WAN that is not active is 闲置待机 with the placeholders.
    var dual = fusionPage(["wans_dualwan": "wan usb", "wans_mode": "fo", "vpnc_default_wan": "0"])
    let card = dual.internetEditor()
    #expect(card.title == "互联网" && card.index == "0" && card.defaultSwitch == .on)
    #expect(card.blocks == [VPNClientWANBlock(title: "首选 WAN", connected: true, statusText: "已联机", ipTitle: "外部网络IP", ip: "100.64.1.2", proto: "动态 IP"),
                            VPNClientWANBlock(title: "第二 WAN", connected: false, statusText: "闲置待机", ipTitle: "外部网络IP", ip: "- -. - -. - -. - -", proto: "- -")])
    var access = fusionPage(["lan_ipaddr": "192.168.50.1", "lan_proto": "static"], mode: "ap")
    #expect(access.internetEditor().blocks == [VPNClientWANBlock(title: "WAN 状态", connected: true, statusText: "AP 模式", ipTitle: "内部网络 IP", ip: "192.168.50.1", proto: "静态 IP")])
    #expect(VPNClientPage.ssidNames(wlnband: ascii("5g1<2g1")) == ["wl1.1_ssid", "wl0.1_ssid"] && VPNClientPage.ssidNames(wlnband: "") == ["wl.1_ssid", "wl.1_ssid"])
}

// MARK: - The form

@Test func validationFollowsValidateFormat() {
    let good = VPNClientForm(desc: "Office", type: "pptp", server: "vpn.example.com", username: "alice", password: "secret")
    #expect(good.validated().invalid == nil && good.complete)
    var form = good
    form.desc = ""
    #expect(form.validated().invalid == VPNClientForm.Invalid(field: .desc, message: "栏位不能为空白") && !form.complete)
    form.desc = "a.b"
    #expect(form.validated().invalid?.message == #"*,+,|,:,?,<,>,,,.,/,;,[,],\,=," 是无效字符。"#)
    form.desc = "办公室"
    #expect(form.validated().invalid?.message == "本字符串无法包含：\" 办公室\" !")
    // Digits and dots: strictly inside 1.0.0.0–126.255.255.255 or 128.0.0.0–255.255.255.255; anything else is only checked for
    // characters (no FQDN check).
    let servers: [(String, Bool)] = [("1.0.0.0", false), ("1.0.0.1", true), ("126.255.255.255", false), ("127.0.0.1", false), ("128.0.0.0", false),
                                     ("128.0.0.1", true), ("255.255.255.254", true), ("255.255.255.255", false), ("0.1.2.3", false), ("1.2.3", false),
                                     ("1234", false), ("vpn example:1723", true), (".", true), ("中文.cn", false), ("a<b", false)]
    for (server, accepted) in servers {
        var candidate = good
        candidate.server = server
        #expect((candidate.validated().invalid == nil) == accepted, "\(server)")
    }
    form = good; form.server = "1.0.0.0"
    #expect(form.validated().invalid == VPNClientForm.Invalid(field: .server, message: "1.0.0.0 不是有效的 IP 地址！"))
    form.server = "a<b"
    #expect(form.validated().invalid?.message == "<,> 是无效字符。")
    // An accepted address loses its leading zeros, and keeps them gone when a later field fails.
    form.server = "010.001.002.003"; form.username = ""
    #expect(form.validated().form.server == "10.1.2.3" && form.validated().invalid == VPNClientForm.Invalid(field: .username, message: "栏位不能为空白"))
    form = good; form.password = "p>w"; form.username = " alice "
    #expect(form.validated().invalid == VPNClientForm.Invalid(field: .password, message: "<,> 是无效字符。"))
    // A type the select does not have: only the name is checked.
    form = VPNClientForm(desc: "x", type: nil)
    #expect(form.validated().invalid == nil && form.complete && form.typeTitle == "")
}

@Test func editingFillsTheInputsAsThePageDoes() {
    var page = vpnPage(["vpnc_clientlist": "R&D>PPTP>vpn.example.com>a'b>p\"w", "vpnc_pptp_options_x_list": "<+mppe"])
    // htmlEncode into the inputs; the type fixed; a stored option the list does not have selects nothing.
    var editor = page.editor(for: 0)
    #expect(editor.title == "PPTP" && editor.typeFixed && !editor.stopped)
    #expect(editor.form == VPNClientForm(desc: "R&amp;D", type: "pptp", pptpOptions: nil, server: "vpn.example.com", username: "a&#39;b", password: "p&quot;w"))
    #expect(page.encodedInputs(editor) == ["连接名称", "用户名", "密码"])
    // 应用's check then refuses the name, which now holds ";".
    #expect(failure(page.saving(editor)) == .invalid(VPNClientForm.Invalid(field: .desc, message: #"*,+,|,:,?,<,>,,,.,/,;,[,],\,=," 是无效字符。"#)))
    // With the name fixed, the entities are saved as shown and the option list gets "undefined" for nothing selected.
    editor.form.desc = "RD"
    #expect(success(page.saving(editor))?.json
        == #"{"vpnc_clientlist":"RD>PPTP>vpn.example.com>a&#39;b>p&quot;w>>>>>0>0>Web","vpnc_pptp_options_x_list":"<undefined","action_mode":"apply"}"#)
    let new = page.editor(for: nil)
    #expect(new.title == "添加设置文件" && !new.typeFixed && new.form == VPNClientForm() && new.applyTitle == "应用目前所有设置")
}

// MARK: - Requests

@Test func switchesWithoutFusionChangeTheRunningClient() throws {
    let page = plainPage()
    #expect(try #require(success(page.switching(0, on: true))).json
        == #"{"vpnc_proto":"pptp","action_mode":"apply","rc_service":"restart_vpncall","vpnc_heartbeat_x":"vpn.example.com","vpnc_pppoe_username":"alice","vpnc_pppoe_passwd":"secret","vpnc_auto_conn":"1","vpnc_pptp_options_x":"+mppe-128"}"#)
    #expect(try #require(success(page.switching(0, on: false))).json
        == #"{"vpnc_proto":"disable","action_mode":"apply","rc_service":"restart_vpncall","vpnc_heartbeat_x":"","vpnc_pppoe_username":"","vpnc_pppoe_passwd":"","vpnc_auto_conn":"1","vpnc_pptp_options_x":""}"#)
    #expect(try #require(success(page.switching(1, on: true))).json
        == #"{"vpnc_proto":"l2tp","action_mode":"apply","rc_service":"restart_vpncall","vpnc_heartbeat_x":"10.0.0.1","vpnc_pppoe_username":"bob","vpnc_pppoe_passwd":"pw","vpnc_auto_conn":"1"}"#)
    // An OpenVPN entry of the list switches the OpenVPN client its server field names.
    let openVPN = try #require(success(page.switching(2, on: true)))
    #expect(openVPN.json == #"{"vpnc_proto":"openvpn","action_mode":"apply","rc_service":"restart_vpncall","vpn_client_unit":"2","vpn_clientx_eas":"2,","vpn_client2_username":"carol","vpn_client2_password":"pw2"}"#)
    #expect(openVPN.checks == ["vpnc_proto", "vpn_clientx_eas", "vpn_client2_username", "vpn_client2_password"])
}

@Test func theNATCheckOfThe7114SDKAddsTheReboot() throws {
    let support = #"{"sdk7114":1,"wanMax":2}"#
    var asks = plainPage(["wan1_proto": "pppoe", "ctf_disable": "0", "vpncoppp": ""], support: support)
    #expect(asks.natNames == ["wan0_proto", "wan1_proto", "ctf_disable", "vpncoppp"])
    let reboot = asks.natCheck()
    #expect(reboot == VPNClientNAT(reboot: true, forceOff: true))
    let request = try #require(success(asks.switching(0, on: true, nat: reboot)))
    #expect(request.json == #"{"vpnc_proto":"pptp","action_mode":"apply","rc_service":"reboot","vpnc_heartbeat_x":"vpn.example.com","vpnc_pppoe_username":"alice","vpnc_pppoe_passwd":"secret","vpnc_auto_conn":"1","ctf_nonat_force":"1","vpnc_pptp_options_x":"+mppe-128"}"#)
    #expect(request.reboots)
    var forced = plainPage(["wan0_proto": "pppoe", "ctf_disable": "0", "vpncoppp": "1"], support: support)
    #expect(forced.natCheck() == VPNClientNAT(reboot: false, forceOff: true))
    var off = plainPage(["wan0_proto": "pppoe", "ctf_disable": "1"], support: support)
    #expect(off.natCheck() == .none && plainPage().natNames.isEmpty)
}

@Test func fusionSwitchesWriteTheListWithTheUnitAsANumber() throws {
    let page = fusionPage()
    // Two active profiles already: a third is refused.
    #expect(failure(page.switching(1, on: true))?.message == "由于并发活动 VPN 连接数上限最大为 2。请先停用一个现用 VPN 连接后再启用另一个。")
    #expect(try #require(success(page.switching(0, on: false))).json
        == #"{"action_mode":"apply","rc_service":"stop_vpnc","vpnc_unit":0,"vpnc_clientlist":"Home>PPTP>1.2.3.4>u>p>0>3>>>0>0>Web<Work>L2TP>5.6.7.8>v>q>0>4>>>0>0>Web<Lab>PPTP>9.9.9.9>w>r>1>5>>>0>0>Web","vpnc_pptp_options_x_list":"<auto<auto<auto"}"#)
    let three = fusionPage(support: #"{"real_vpn_fusion":1,"MaxRule_VPN_FUSION_Conn":3}"#)
    #expect(try #require(success(three.switching(1, on: true))).json
        == #"{"action_mode":"apply","rc_service":"restart_vpnc","vpnc_unit":1,"vpnc_clientlist":"Home>PPTP>1.2.3.4>u>p>1>3>>>0>0>Web<Work>L2TP>5.6.7.8>v>q>1>4>>>0>0>Web<Lab>PPTP>9.9.9.9>w>r>1>5>>>0>0>Web","vpnc_pptp_options_x_list":"<auto<auto<auto"}"#)
}

@Test func savingWithoutFusionWritesTheListsAndTheRunningClient() throws {
    var page = plainPage()
    var new = page.editor(for: nil)
    new.form = VPNClientForm(desc: "New", type: "l2tp", server: "009.8.7.6", username: "dan", password: "x")
    let added = try #require(success(page.saving(new)))
    #expect(added.json == #"{"vpnc_clientlist":"Office>PPTP>vpn.example.com>alice>secret>>>>>0>0>Web<Lab>L2TP>10.0.0.1>bob>pw>>>>>0>0>Web<Old>OpenVPN>2>carol>pw2>>>>>0>0>Web<New>L2TP>9.8.7.6>dan>x>>>>>0>0>Web","vpnc_pptp_options_x_list":"<+mppe-128<auto<auto<auto","action_mode":"apply"}"#)
    #expect(added.after == .seconds(0.8) && added.checks == ["vpnc_clientlist", "vpnc_pptp_options_x_list"])
    // Protocol, server, user name and password decide a duplicate; the name and the PPTP option do not.
    new.form = VPNClientForm(desc: "Again", type: "pptp", pptpOptions: "-mppc", server: "vpn.example.com", username: "alice", password: "secret")
    #expect(failure(page.saving(new)) == .alert(.duplicate))
    new.form.type = "l2tp"
    #expect(success(page.saving(new)) != nil)
    // The running profile: the client takes the new settings and restarts.
    var office = page.editor(for: 0)
    office.form.pptpOptions = "-mppc"
    #expect(try #require(success(page.saving(office))).json
        == #"{"vpnc_clientlist":"Office>PPTP>vpn.example.com>alice>secret>>>>>0>0>Web<Lab>L2TP>10.0.0.1>bob>pw>>>>>0>0>Web<Old>OpenVPN>2>carol>pw2>>>>>0>0>Web","vpnc_pptp_options_x_list":"<-mppc<auto<auto","action_mode":"apply","rc_service":"restart_vpncall","vpnc_proto":"pptp","vpnc_heartbeat_x":"vpn.example.com","vpnc_pppoe_username":"alice","vpnc_pppoe_passwd":"secret","vpnc_pptp_options_x":"-mppc"}"#)
}

@Test func savingWithFusionSwitchesANewProfileOnAndSendsTheRules() throws {
    var page = fusionPage(["vpnc_default_wan": "0"], support: #"{"real_vpn_fusion":1,"MaxRule_VPN_FUSION_Conn":3}"#)
    var new = page.editor(for: nil, newIndex: .number("6"))
    #expect(new.autoEnable && new.applyTitle == "应用并开启" && new.index == "6" && new.policies != nil)
    new.form = VPNClientForm(desc: "New", type: "pptp", server: "8.8.4.4", username: "e", password: "s")
    let request = try #require(success(page.saving(new, newIndex: .number("6"))))
    #expect(request.json == #"{"vpnc_clientlist":"Home>PPTP>1.2.3.4>u>p>1>3>>>0>0>Web<Work>L2TP>5.6.7.8>v>q>0>4>>>0>0>Web<Lab>PPTP>9.9.9.9>w>r>1>5>>>0>0>Web<New>PPTP>8.8.4.4>e>s>1>6>>>0>0>Web","vpnc_pptp_options_x_list":"<auto<auto<auto<auto","action_mode":"apply","vpnc_unit":3,"vpnc_default_wan_tmp":6,"rc_service":"restart_vpnc;restart_default_wan;"}"#)
    #expect(request.after == .seconds(10))
    // On a 7114 router with PPPoE the reboot replaces the services, without the page's confirm.
    let reboot = try #require(success(page.saving(new, newIndex: .number("6"), nat: VPNClientNAT(reboot: true, forceOff: true))))
    #expect(reboot.json.hasSuffix(#""vpnc_default_wan_tmp":6,"ctf_nonat_force":"1","rc_service":"reboot"}"#) && reboot.reboots)
    // An active profile cannot be edited.
    let active = page.editor(for: 0)
    #expect(failure(page.saving(active)) == .alert(.deactivateToEdit))
    // Devices given to Work: the bindings and rules with their services.
    page = fusionPage(clients: [TORSettings.ClientEntry(mac: "AA:BB:CC:DD:EE:03", name: "Phone", ip: "192.168.50.5", online: true)])
    var work = page.editor(for: 1)
    let home = page.editor(for: 0)
    #expect(work.defaultSwitch == .off && work.canAssign(page) == nil && home.canAssign(page) == .deactivateToEdit)
    work.policies = try #require(success(work.policies!.assigning(work.choices(page), to: work.index)))
    let saved = try #require(success(page.saving(work)))
    #expect(saved.json.hasSuffix(#""action_mode":"apply","dhcp_staticlist":"<AA:BB:CC:DD:EE:03>192.168.50.5>>","vpnc_dev_policy_list":"1>192.168.50.5>>4>","vpnc_dev_policy_list_tmp":"","rc_service":"restart_net_and_phy;restart_vpnc_dev_policy;"}"#))
    #expect(saved.after == .networkRestart && saved.checks == ["vpnc_clientlist", "vpnc_pptp_options_x_list", "dhcp_staticlist", "vpnc_dev_policy_list"])
}

@Test func theVPNWiFiInterfaceFollowsTheFirstWirelessRule() throws {
    let nvram = ["vpnc_clientlist": "Home>PPTP>1.2.3.4>u>p>0>3>>>0>0>Web<Work>L2TP>5.6.7.8>v>q>0>4>>>0>0>Web", "vpnc_pptp_options_x_list": "<auto<auto",
                 "vpnc_dev_policy_list": "1>>>3>br1<1>>>3>br2", "wlnband_list": "2g1<5g1", "wl0.1_ssid": "Guest&Co", "wl1.1_ssid": "Guest5", "vpnc_default_wan": "0"]
    var page = fusionPage(nvram, support: #"{"real_vpn_fusion":1,"ig_site2site":1}"#)
    #expect(page.instantGuard && page.tags(page.profiles[0]) == ["VPN WiFi"])
    var home = page.editor(for: 0)
    #expect(home.wireless?.option == "3" && home.wireless?.locked == false && home.wireless?.hints == ["2.4 GHz : Guest&Co", "5 GHz : Guest5"])
    let work = page.editor(for: 1)
    #expect(work.wireless?.locked == true && work.wireless?.option == "0" && work.wireless?.hints == ["* VPN WiFi 已经在使用中。"])
    home.chooseWireless("1")
    #expect(home.wireless?.hints == ["2.4 GHz : Guest&Co"])
    let saved = try #require(success(page.saving(home)))
    #expect(saved.json.hasSuffix(#""vpnc_dev_policy_list":"1>>>3>br1","vpnc_dev_policy_list_tmp":"1>>>3>br1<1>>>3>br2","rc_service":"restart_vpnc_dev_policy;"}"#))
    // Locked: Work's save leaves the VPN Wi-Fi rules alone.
    #expect(success(page.saving(work))?.value("vpnc_dev_policy_list") == nil)
    // mtlancfg turns the interface off.
    #expect(!fusionPage(nvram, support: #"{"real_vpn_fusion":1,"ig_site2site":1,"mtlancfg":1}"#).instantGuard)
}

@Test func deletingStopsTheClientOrResetsTheDefaultFirst() throws {
    let plain = plainPage()
    #expect(try #require(success(plain.deleting(0, policies: nil))).map(\.json)
        == [#"{"vpnc_clientlist":"Lab>L2TP>10.0.0.1>bob>pw>>>>>0>0>Web<Old>OpenVPN>2>carol>pw2>>>>>0>0>Web","vpnc_pptp_options_x_list":"<auto<auto","action_mode":"apply","rc_service":"restart_vpncall","vpnc_proto":"disable"}"#])
    #expect(try #require(success(plain.deleting(2, policies: nil))).map(\.json)
        == [#"{"vpnc_clientlist":"Office>PPTP>vpn.example.com>alice>secret>>>>>0>0>Web<Lab>L2TP>10.0.0.1>bob>pw>>>>>0>0>Web","vpnc_pptp_options_x_list":"<+mppe-128<auto","action_mode":"apply","vpn_crt_client2_ca":"","vpn_crt_client2_crt":"","vpn_crt_client2_key":"","vpn_crt_client2_static":"","vpn_crt_client2_crl":""}"#])
    var fusion = fusionPage(["vpnc_default_wan": "4", "dhcp_staticlist": "<AA:BB:CC:DD:EE:03>192.168.50.5>>", "vpnc_dev_policy_list": "1>192.168.50.5>>4><1>192.168.50.5>>3>"])
    #expect(failure(fusion.deleting(0, policies: nil)) == .deactivateToDelete)
    let work = fusion.editor(for: 1)
    let requests = try #require(success(fusion.deleting(1, policies: work.policies)))
    #expect(requests.map(\.json) == [#"{"action_mode":"apply","rc_service":"restart_default_wan","vpnc_default_wan_tmp":"0"}"#,
                                      #"{"vpnc_clientlist":"Home>PPTP>1.2.3.4>u>p>1>3>>>0>0>Web<Lab>PPTP>9.9.9.9>w>r>1>5>>>0>0>Web","vpnc_pptp_options_x_list":"<auto<auto","action_mode":"apply","rc_service":"restart_vpnc_dev_policy","vpnc_dev_policy_list":"1>192.168.50.5>>3>","vpnc_dev_policy_list_tmp":"1>192.168.50.5>>4><1>192.168.50.5>>3>"}"#])
    #expect(requests[1].after == .seconds(3))
}

@Test func theDefaultConnectionAndTheInternetCardSendAtOnce() throws {
    var page = fusionPage(["vpnc_default_wan": "0"])
    #expect(try #require(success(page.defaultConnection(index: "4", on: true))).json == #"{"action_mode":"apply","vpnc_default_wan_tmp":"4","rc_service":"restart_default_wan"}"#)
    #expect(try #require(success(page.defaultConnection(index: "4", on: false))).json == #"{"action_mode":"apply","vpnc_default_wan_tmp":"0","rc_service":"restart_default_wan"}"#)
    #expect(failure(page.defaultConnection(index: "0", on: false)) == .keepInternetDefault)
    let unchanged = try #require(VPNClientPolicies.read(dhcp: "", rules: ""))
    #expect(success(page.internetApplying(unchanged))?.json == #"{"action_mode":"apply"}"#)
    #expect(page.editor(for: 2).defaultSwitch == .unsupported)
}

// MARK: - Through the router

@Test func thePageIsReadAndASwitchIsSentAsTheWebSendsIt() async throws {
    let router = VPNCRouter(nvram: ["vpnc_clientlist": plainList, "vpnc_pptp_options_x_list": "<+mppe-128<auto<auto"].merging(running) { $1 })
    let client = try client(router)
    let page = try await client.vpnClientPage()
    #expect(page.statuses[0]?.text == "已联机" && page.profiles.count == 3)
    let request = try #require(success(page.switching(1, on: true)))
    let receipt = try await client.submitVPNClient([request])
    #expect(await router.posts == [#"{"vpnc_proto":"l2tp","action_mode":"apply","rc_service":"restart_vpncall","vpnc_heartbeat_x":"10.0.0.1","vpnc_pppoe_username":"bob","vpnc_pppoe_passwd":"pw","vpnc_auto_conn":"1"}"#])
    #expect(receipt.isVerified && receipt.verified == ["vpnc_auto_conn", "vpnc_heartbeat_x", "vpnc_pppoe_passwd", "vpnc_pppoe_username", "vpnc_proto"])
    // The 5-second check reads the state and the running client again.
    let polled = try await client.vpnClientPoll(page, refreshingClient: true)
    #expect(polled.statuses[1]?.on == true && polled.statuses[0] == .off)
}

@Test func fusionIsReadWithItsHooksAndTheDefaultConnectionWaitsForTheRouter() async throws {
    let router = VPNCRouter(nvram: ["vpnc_clientlist": fusionList, "vpnc_pptp_options_x_list": "<auto<auto<auto", "vpnc_default_wan": "3"].merging(wan) { $1 },
                            support: #"{"real_vpn_fusion":1,"dualwan":1}"#, hooks: fusionHooks.merging(["get_operation_mode": #""rt""#, "get_new_vpnc_index": "6"]) { $1 })
    let client = try client(router)
    let page = try await client.vpnClientPage()
    #expect(page.fusion && page.statuses[2]?.error == "授权失败" && page.internet?.wan.statusText == "已联机" && page.operationMode == "rt")
    let form = try await client.vpnClientFormPage(page, new: true)
    #expect(form.newIndex == .number("6"))
    let request = try #require(success(page.defaultConnection(index: "4", on: true)))
    let receipt = try await client.submitVPNClient([request])
    #expect(receipt.isVerified && receipt.verified == ["vpnc_default_wan"] && receipt.message.contains("已是 4"))
    #expect(await router.value("vpnc_default_wan") == "4")
    // The switch writes vpnc_unit as a number.
    let switched = try #require(success(page.switching(0, on: false)))
    _ = try await client.submitVPNClient([switched])
    #expect(await router.posts.last?.hasPrefix(#"{"action_mode":"apply","rc_service":"stop_vpnc","vpnc_unit":0,"#) == true)
}

// MARK: - Review 1.14.0

@Test func aLateSwitchPreparationIsDroppedWhenThePageChanged() throws {
    // The NAT check started on this page (two active, three allowed).
    let support = #"{"real_vpn_fusion":1,"MaxRule_VPN_FUSION_Conn":3}"#
    let started = fusionPage(support: support)
    let basis = started.basis
    // A 5-second check changes the status texts only: the answer is built on the page as it now is.
    let polled = started.polled(hooks: ["get_vpnc_status": .string("1>0>3<1>0>5")], refreshingClient: false)
    #expect(polled.stillMatches(basis) && success(polled.switching(1, on: true, nat: .none, preparedOn: basis)) != nil)
    // Work was deleted and the page read again meanwhile: the late answer is refused, nothing is built from the old list.
    let reread = vpnPage(["vpnc_clientlist": "Home>PPTP>1.2.3.4>u>p>1>3>>>0>0>Web<Lab>PPTP>9.9.9.9>w>r>1>5>>>0>0>Web", "vpnc_pptp_options_x_list": "<auto<auto",
                          "vpnc_default_wan": "3"].merging(wan) { $1 }, support: support, hooks: fusionHooks)
    #expect(!reread.stillMatches(basis) && failure(reread.switching(1, on: true, nat: .none, preparedOn: basis)) == .stale)
    // Another profile switched off meanwhile, or the default connection moved: refused too.
    let switched = fusionPage(["vpnc_clientlist": fusionList.replacingOccurrences(of: "Lab>PPTP>9.9.9.9>w>r>1", with: "Lab>PPTP>9.9.9.9>w>r>0")], support: support)
    #expect(failure(switched.switching(1, on: true, nat: .none, preparedOn: basis)) == .stale)
    #expect(!fusionPage(["vpnc_default_wan": "4"], support: support).stillMatches(basis))
    // Without Fusion the running client decides which profile is active: a change of it refuses what was prepared before.
    let plain = plainPage()
    let moved = plain.polled(encoded: ["vpnc_proto": ascii("l2tp"), "vpnc_heartbeat_x": ascii("10.0.0.1"), "vpnc_pppoe_username": ascii("bob"),
                                       "vpnc_pppoe_passwd": ascii("pw")], refreshingClient: true)
    #expect(moved.profiles.map(\.activate) == [false, true, false] && !moved.stillMatches(plain.basis))
    #expect(plain.polled(encoded: ["vpnc_state_t": ascii("1")], refreshingClient: false).stillMatches(plain.basis))
}

@Test func aListThatFailedToReadOffersNoWrites() throws {
    // A list decodeURIComponent rejects: nothing is drawn, and the request builder refuses a new profile.
    var broken = VPNClientPage(support: json("{}"), encoded: ["vpnc_clientlist": "%E4%B8"], hooks: [:], operationMode: "rt", clients: [])
    #expect(broken.stop == .profiles && broken.profiles.isEmpty && !broken.writable)
    var new = broken.editor(for: nil)
    new.form = VPNClientForm(desc: "New", type: "pptp", server: "8.8.4.4", username: "e", password: "s")
    #expect(failure(broken.saving(new)) == .alert(.listUnavailable))
    // Fusion without get_vpnc_nondef_wan_prof_list as text: every kind of write is refused.
    let fusion = vpnPage(["vpnc_clientlist": fusionList], support: #"{"real_vpn_fusion":1}"#)
    #expect(fusion.stop == .profiles && !fusion.writable && failure(fusion.defaultConnection(index: "3", on: true)) == .listUnavailable)
    #expect(failure(fusion.internetApplying(try #require(VPNClientPolicies.read(dhcp: "", rules: "")))) == .listUnavailable)
    // A profile the list cannot draw, or rules that do not decode: refused as well.
    let drawing = vpnPage(["vpnc_clientlist": "Office>PPTP>s>u>p<Bare"])
    #expect(drawing.stop == .drawing(1) && failure(drawing.switching(0, on: true)) == .listUnavailable && failure(drawing.deleting(0, policies: nil)) == .listUnavailable)
    #expect(!fusionPage(["dhcp_staticlist": "<AA>1.1.1.1>>50%"]).writable)
    // A list read without error that is empty is writable: the new profile is then the whole list.
    var empty = vpnPage(["vpnc_clientlist": ""])
    #expect(empty.stop == nil && empty.profiles.isEmpty && empty.writable)
    var first = empty.editor(for: nil)
    first.form = new.form
    #expect(success(empty.saving(first))?.json == #"{"vpnc_clientlist":"New>PPTP>8.8.4.4>e>s>>>>>0>0>Web","vpnc_pptp_options_x_list":"<auto","action_mode":"apply"}"#)
    // A stop at the status check leaves the writes.
    let status = fusionPage(hooks: ["get_vpnc_status": #""%E4""#])
    #expect(status.stop == .status && status.writable && success(status.switching(0, on: false)) != nil)
}

@Test func theDefaultConnectionIsCheckedAgainstWhatIsReadBack() async throws {
    let nvram = ["vpnc_clientlist": fusionList, "vpnc_pptp_options_x_list": "<auto<auto<auto", "vpnc_default_wan": "3"].merging(wan) { $1 }
    let hooks = fusionHooks.merging(["get_operation_mode": #""rt""#]) { $1 }
    // The router clears vpnc_default_wan_tmp but keeps vpnc_default_wan: not verified.
    let keeping = VPNCRouter(nvram: nvram, support: #"{"real_vpn_fusion":1}"#, hooks: hooks, defaultApplies: false)
    var page = try await client(keeping).vpnClientPage()
    var work = page.editor(for: 1)
    #expect(work.defaultSwitch == .off)
    let request = try #require(success(page.defaultConnection(index: work.index, on: true)))
    let kept = try await client(keeping).submitVPNClient([request])
    #expect(!kept.isVerified && kept.unverified == ["vpnc_default_wan"] && kept.message.contains("是 3，不是 4"))
    // The switch shows what is read back (as the list's 默认连接 tag does), not the state it was asked for.
    work.defaultSwitch = .on
    let reread = try await client(keeping).vpnClientPage()
    #expect(reread.refreshed(work).defaultSwitch == .off && reread.tags(reread.profiles[0]) == ["默认连接"])
    // A router that applies it: verified, and the switch and the tags follow the new default.
    let applying = VPNCRouter(nvram: nvram, support: #"{"real_vpn_fusion":1}"#, hooks: hooks)
    let done = try await client(applying).submitVPNClient([request])
    #expect(done.isVerified && done.message.contains("已是 4"))
    let after = try await client(applying).vpnClientPage()
    #expect(after.refreshed(work).defaultSwitch == .on && after.tags(after.profiles[1]) == ["默认连接"] && after.tags(after.profiles[0]).isEmpty)
    // 互联网's switch too.
    let internet = page.internetEditor()
    #expect(internet.defaultSwitch == .off && fusionPage(["vpnc_default_wan": "0"]).refreshed(internet).defaultSwitch == .on)
}

@Test func thePageSitsUnderTheVPNClientTab() {
    #expect(WebMenuCatalog.location(of: .pptpClient) == WebLocation(menu: "menu_VPN", page: "Advanced_OpenVPNClient_Content.asp", part: "pptp"))
}
