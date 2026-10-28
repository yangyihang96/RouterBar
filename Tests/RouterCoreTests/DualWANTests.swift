import Foundation
import Testing
@testable import RouterCore

// 1.13：外部网络(WAN) › 双线路（Advanced_WANPort_Content.asp）在 RT-BE88U 上的端口选项、联动、校验、确认与发送的表单。

// MARK: - A router for this page

/// Answers appGet hooks (nvram_char_to_ascii from `nvram`, encoded as char_to_ascii does; get_ui_support from `support`;
/// other hooks from `hooks` as JSON), get_port_status.cgi, the DNS list and start_apply.htm (with `applyReply`). Records
/// every request with its raw body.
private actor DualWANRouter: RouterTransport {
    var nvram: [String: String]
    let support: [String: String]
    let hooks: [String: String]
    let pages: [String: String]
    let applyReply: String
    private(set) var requests: [(method: String, path: String, query: [String: String], body: String)] = []

    init(nvram: [String: String], support: [String: String], hooks: [String: String], pages: [String: String],
         applyReply: String = "<html><script>done_committing();</script></html>") {
        self.nvram = nvram; self.support = support; self.hooks = hooks; self.pages = pages; self.applyReply = applyReply
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
            var members: [String] = []
            for call in (query["hook"] ?? "").split(separator: ";").map(String.init) {
                if call == "get_ui_support()" {
                    let object = support.map { "\"\($0.key)\":\(Int($0.value).map(String.init) ?? "\"\($0.value)\"")" }.joined(separator: ",")
                    members.append("\"get_ui_support\":{\(object)}")
                } else if call.hasPrefix("nvram_char_to_ascii("), let comma = call.firstIndex(of: ",") {
                    let key = String(call[call.index(call.startIndex, offsetBy: 20)..<comma])
                    members.append("\"\(key)\":\"\(encode(nvram[key] ?? ""))\"")
                } else if call == "nvram_default_get(wans_mode)" {
                    members.append("\"wans_mode\":\(hooks[call] ?? "\"\"")")
                } else if call.hasSuffix("()"), let answer = hooks[String(call.dropLast(2))] {
                    members.append("\"\(call.dropLast(2))\":\(answer)")
                }
            }
            return RouterHTTPResponse(data: Data(("{" + members.joined(separator: ",") + "}").utf8), status: 200)
        case "start_apply.htm":
            return RouterHTTPResponse(data: Data(applyReply.utf8), status: 200)
        default:
            if let page = pages[path] { return RouterHTTPResponse(data: Data(page.utf8), status: 200) }
            return RouterHTTPResponse(data: Data(), status: 404)
        }
    }
    nonisolated func cancel() {}
    var writes: [(method: String, path: String, query: [String: String], body: String)] { requests.filter { $0.method != "GET" } }
}

/// char_to_ascii: letters and digits as they are, every other byte as %XX.
private func encode(_ text: String) -> String {
    text.utf8.map { byte in
        (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
    }.joined()
}
private func json(_ text: String?) -> OrderedJSON? { text.flatMap { try? OrderedJSON(data: Data($0.utf8)) } }

private let mac = "AA:BB:CC:DD:EE:FF"
/// ej_get_ethernet_wan_list's RTBE88U branch (web.c 40471–40509) with AUTO_WANPORT.
private let ethernetList = #"{"wan":{"wan_name":"10G WAN/LAN","extra_settings":{"wan_ifname_x":"eth0","autowan_enable":"0"}},"2p5g":{"wan_name":"2.5G WAN/LAN1","extra_settings":{"wan_ifname_x":"eth1","autowan_enable":"0"},"wans_lanport":"1"},"sfp":{"wan_name":"10G SFP+","extra_settings":{"wan_ifname_x":"eth9","autowan_enable":"0"},"wans_lanport":"9"}}"#
/// get_port_status.cgi: L1 is a WAN/LAN port (cap bit 9), L6 is flagged; L5 has an empty ui_display.
private let portStatus = #"{"port_info":{"AA:BB:CC:DD:EE:FF":{"W0":{"cap":"1","max_rate":"10000"},"L1":{"cap":"514","max_rate":"2500"},"L2":{"cap":"2","max_rate":"1000","flag":"0"},"L3":{"cap":"2","max_rate":"1000"},"L4":{"cap":"2","max_rate":1000},"L5":{"cap":"2","max_rate":"10000","ui_display":""},"L6":{"cap":"2","max_rate":"1000","flag":"2"},"U1":{"cap":"128"}}}}"#
private let dnsList = #"{"0":{"DNSService":"Google","ServiceIP1":"8.8.8.8","ping_target":"Yes"},"1":{"DNSService":"114DNS","ServiceIP1":"114.114.114.114","ping_target":"CN"},"2":{"DNSService":"Cloud<b>flare</b>","ServiceIP1":"1.1.1.1","ping_target":"Yes"},"3":{"DNSService":"Quad9","ServiceIP1":"9.9.9.9","ping_target":"No"}}"#
private let rtbe88u: [String: String] = ["dualwan": "1", "NEW_PHYMAP": "1", "autowan": "1", "usb_bk": "1", "lacp": "1", "wanbonding": "1",
                                         "mtlancfg": "6", "MaxRule_SDN": "19", "bwdpi": "2", "wanMax": "2", "mswan": "1"]
private let stored: [String: String] = [
    "productid": "RT-BE88U", "territory_code": "AU/01", "preferred_lang": "CN", "wans_dualwan": "wan none", "wlc_band": "", "bond_wan": "0",
    "wans_cap": "wan lan usb", "switch_stb_x": "0", "wandog_fb_count": "12", "wandog_maxfail": "5", "wans_mode": "fo", "wans_standby": "0",
    "dns_probe_timeout": "", "qos_enable": "0", "qos_type": "1", "lacp_enabled": "0", "wans_lanport": "1", "wanports_bond": "",
    "iptv_port_settings": "12", "autowan_enable": "0", "switch_wantag": "none", "wan_proto": "dhcp", "wan0_enable": "1", "wan1_enable": "0",
    "HwId": "", "lan_trunk_type": "0", "firmver": "3.0.0.6", "wl_ssid": "MyWiFi", "wan_unit": "0", "wans_extwan": "0", "wans_lb_ratio": "3:1",
    "dns_probe": "1", "wandog_enable": "0", "wan0_routing_isp_enable": "0", "wan0_routing_isp": "", "wan1_routing_isp_enable": "0",
    "wan1_routing_isp": "", "wans_usb_bk_act": "0", "wans_usb_bk": "1", "wans_routing_enable": "0", "wandog_interval": "5",
    "dns_probe_host": "dns.msftncsi.com", "wandog_target": "", "wans_routing_rulelist": "", "extendno": "0", "label_mac": mac,
    "vlan_trunk_rl": "", "wan_ifname_x": "eth0"
]

/// The page as dualWANPage() reads it from `stored` with `changes`.
private func page(_ changes: [String: String] = [:], support extra: [String: String] = [:], ethernet: String? = ethernetList,
                  dpi: String = #"{"DpiEngine":"0","bwdpi_sig_ver":"","sig_update_t":""}"#, encoded overrides: [String: String] = [:],
                  ports: String = portStatus) -> DualWANPage {
    let nvram = stored.merging(changes) { _, new in new }
    let support = rtbe88u.merging(extra) { _, new in new }
    let list = json(ethernet)
    let keys = Set(DualWANPage.keys + DualWANPage.extraKeys(list) + DualWANPage.apgKeys(support))
    var encoded = Dictionary(uniqueKeysWithValues: keys.map { ($0, encode(nvram[$0] ?? "")) })
    for key in DualWANPage.dutKeys(encoded, support: support) { encoded[key] = encode(nvram[key] ?? "") }
    encoded.merge(overrides) { _, new in new }
    return DualWANPage(encoded: encoded, support: support, ethernetList: list, rebootTime: "160", dpiStatus: json(dpi), lanMAC: mac,
                       portStatus: json(ports), dnsList: json(dnsList))
}
private func lines(_ submission: DualWANSubmission) -> [String] { submission.fields.map { $0.name + "=" + $0.value } }
private func index(_ select: DualWANSelect, _ value: String) -> Int { select.options.firstIndex { $0.value == value }! }
/// Answers every question with `answers`, in order, and returns the end.
private func apply(_ form: inout DualWANForm, _ answers: [Bool]) -> DualWANOutcome {
    let (next, outcome) = form.applying(answers)
    if case .confirm = outcome { return outcome }
    form = next
    return outcome
}
private let rebootQuestion = DualWANOutcome.confirm("重启路由器可能会使所有已联网的路由器中断网络连接。重启后，所有设备将会重新进行网络连接，确认继续？", .reboot)

// MARK: - Options

@Test func optionsFollowTheEthernetListAndThePortStatus() throws {
    let opened = page()
    #expect(opened.problems.isEmpty)
    #expect(opened.caps == "wan 2p5g sfp lan usb")
    #expect(opened.lanPorts == [.init(text: "LAN Port 2", value: "2"), .init(text: "LAN Port 3", value: "3"), .init(text: "LAN Port 4", value: "4"),
                              .init(text: "10G LAN5", value: "5")])
    let form = DualWANForm(page: opened)
    #expect(form.curState == "0" && form.wansFlag == 0)
    // Single WAN: no Ethernet LAN for the primary WAN, WAN 自动检测 first (autowan, nothing in conflict, DHCP).
    #expect(form.primary.options.map(\.text) == ["WAN 自动检测", "10G WAN/LAN", "2.5G WAN/LAN1", "10G SFP+", "USB"])
    #expect(form.primary.options.map(\.value) == ["auto", "wan", "2p5g", "sfp", "usb"])
    // get_ethwan_setting: wan_ifname_x eth0 and autowan_enable 0 are the "wan" member's.
    #expect(form.primary.value == "wan")
    #expect(form.second.options.map(\.text) == ["10G WAN/LAN", "2.5G WAN/LAN1", "10G SFP+", "Ethernet LAN", "USB"] && form.second.disabled)
    #expect(form.lanport1.options.map(\.value) == ["2", "3", "4", "5"] && form.lanport1.value == "2" && !form.lanport1Shown)
    #expect(form.primaryRowShown && !form.secondRowShown && form.usbTetheringShown && !form.usbTetheringHint && !form.modeRowShown)
    #expect(!form.failoverWording && form.fbCount == nil && form.dnsProbeHostShown && !form.wandogTargetShown && !form.routingTableShown)
    #expect(form.appended == [.init(name: "autowan_enable", value: "0")] && form.aggregationNoteShown)
    #expect(form.pingTargets.map(\.label) == ["Google (8.8.8.8)", "Cloudflare (1.1.1.1)"])

    // WAN 自动检测 is selected when it is on; with get_ethwan_setting matching nothing the stored type stays.
    let auto = DualWANForm(page: page(["autowan_enable": "1"]))
    #expect(auto.primary.value == "auto")
    // No WAN 自动检测 while LACP is on; China territory picks the CN ping targets.
    let lacp = DualWANForm(page: page(["lacp_enabled": "1", "territory_code": "CN/01"]))
    #expect(!lacp.primary.options.contains { $0.value == "auto" })
    #expect(lacp.pingTargets.map(\.label) == ["114DNS (114.114.114.114)"])
    // Without LAN ports from the port status every Ethernet LAN option goes.
    let noPorts = DualWANForm(page: DualWANPage(encoded: opened.encoded, support: opened.support, ethernetList: opened.ethernetList, rebootTime: "160",
                                                dpiStatus: nil, lanMAC: mac, portStatus: nil, dnsList: nil))
    #expect(!noPorts.second.options.contains { $0.value == "lan" } && noPorts.lanport1.options.map(\.value) == ["1", "2", "3", "4"])
    // A port whose cap_support is not an object keeps WANLAN undefined; `null.length` stops the loop with what it has.
    let odd = page(ports: #"{"port_info":{"AA:BB:CC:DD:EE:FF":{"L1":{"cap":"514","cap_support":"x"},"L2":{"cap":"2","max_rate":2500},"L3":{"cap":"2","ui_display":null},"L4":{"cap":"2"}}}}"#)
    #expect(odd.lanPorts == [.init(text: "LAN Port 1", value: "1"), .init(text: "2.5G LAN2", value: "2")])
}

@Test func theSwitchAndTheSelectsChangeTheFormAsThePageDoes() {
    var form = DualWANForm(page: page())
    #expect(form.switchOnQuestion == nil && form.switchOnReadsDefaultMode)
    form.switchOn(defaultMode: "fo")
    #expect(form.curState == "1" && form.wansFlag == 1 && form.secondRowShown && !form.second.disabled && form.modeRowShown)
    #expect(form.primary.options.map(\.value) == ["wan", "2p5g", "sfp", "lan", "usb"])
    // form_show(1) for "wan none": the second WAN is USB, the first of wan2, sfp+ and usb in wans_cap.
    #expect(form.primary.value == "wan" && form.second.value == "usb")
    #expect(form.wansMode == "fo" && form.failoverWording && form.fbSpanShown && !form.fbCountRowShown && form.fbCount == "12")
    #expect(form.appended == [.init(name: "autowan_enable", value: "0")] && !form.usbTetheringShown)

    // The same type in both: changeWANProto changes the other one.
    form.choose(primary: false, index: index(form.second, "wan"))
    #expect(form.primary.value == "usb" && form.second.value == "wan")
    form.choose(primary: true, index: index(form.primary, "wan"))
    #expect(form.primary.value == "wan" && form.second.value == "usb")
    form.choose(primary: true, index: index(form.primary, "lan"))
    #expect(form.lanport1Shown && !form.lanport2Shown)
    form.choose(primary: false, index: index(form.second, "lan"))
    // Both lan: the second's branch for lan sets the primary to wan.
    #expect(form.primary.value == "wan" && form.second.value == "lan" && !form.lanport1Shown && form.lanport2Shown)

    form.setFailback(true)
    #expect(form.wansMode == "fb" && form.fbCountRowShown)
    form.chooseMode("lb")
    #expect(form.wansMode == "lb" && form.ratioRowShown && form.lbNoteShown && form.routingTableShown && !form.routingRulesShown)
    #expect(form.ratio0.value == "3" && form.ratio1.value == "1" && form.ispUnit.checked == "0" && form.wan0Country.value == "0")
    // show_watchdog_table makes the fields again from their attributes.
    form.interval = "9"
    form.chooseMode("fo")
    #expect(form.interval == "5" && form.wansMode == "fo" && !form.fbChecked)
    form.setPing(true)
    #expect(form.wandogTargetShown && !form.wandogTarget.disabled)
}

// MARK: - Sending

@Test func dualWANFailoverSendsTheFormTheBrowserBuilds() {
    var form = DualWANForm(page: page())
    form.switchOn(defaultMode: "fo")
    #expect(form.applying([]).outcome == rebootQuestion)
    guard case .submit(let submission) = apply(&form, [true]) else { Issue.record("not submitted"); return }
    #expect(lines(submission) == ["current_page=Advanced_WANPort_Content.asp", "next_page=Advanced_WANPort_Content.asp", "modified=0",
                                  "action_mode=apply_new", "action_wait=160", "action_script=reboot", "preferred_lang=CN", "firmver=3.0.0.6",
                                  "wl_ssid=MyWiFi", "wan_unit=0", "wans_extwan=0", "wans_dualwan=wan usb", "wans_lanport=1", "dns_probe=1",
                                  "dns_probe_content=*", "wandog_enable=0", "wan0_enable=1", "wan1_enable=1", "detect_interval=", "wans_primary=wan",
                                  "wans_lanport1=2", "wans_second=usb", "wans_lanport2=2", "wans_usb_bk=1", "wans_mode=fo", "wandog_interval=5",
                                  "wandog_maxfail=5", "wandog_fb_count=12", "dns_probe_chk=", "dns_probe_host=dns.msftncsi.com",
                                  "autowan_enable=0", "wan_ifname_x=eth0"])
    #expect(submission.reboots && submission.wait == 160 && !submission.disablesDPI)
}

@Test func loadBalanceSendsTheRatioTheRulesAndDisablesDPIWhenConfirmed() {
    var form = DualWANForm(page: page(["wans_dualwan": "wan usb", "wans_routing_enable": "1",
                                       "wans_routing_rulelist": "<192.168.1.0/24>all>1<10.0.0.5>8.8.8.8>0"], dpi: #"{"DpiEngine":"1"}"#))
    #expect(form.curState == "1" && form.second.value == "usb" && form.rules == [["192.168.1.0/24", "all", "1"], ["10.0.0.5", "8.8.8.8", "0"]])
    form.chooseMode("lb")
    #expect(form.routingRulesShown && form.routingEnable.checked == "1")
    form.deleteRule(at: 0)
    #expect(form.applying([]).outcome == .confirm("如果您开启负载均衡选项，AiProtection 网络神盾 将被禁用。您确定要处理吗？", .dpi))
    // dpi_disable;reboot; is not "reboot": the page submits without the reboot question.
    guard case .submit(let submission) = apply(&form, [true]) else { Issue.record("not submitted"); return }
    #expect(lines(submission) == ["current_page=Advanced_WANPort_Content.asp", "next_page=Advanced_WANPort_Content.asp", "modified=0",
                                  "action_mode=apply_new", "action_wait=160", "action_script=dpi_disable;reboot;", "preferred_lang=CN",
                                  "firmver=3.0.0.6", "wl_ssid=MyWiFi", "wan_unit=0", "wans_extwan=0", "wans_dualwan=wan usb", "wans_lanport=1",
                                  "wans_lb_ratio=3:1", "dns_probe=1", "dns_probe_content=*", "wandog_enable=0", "wan0_routing_isp_enable=0",
                                  "wan0_routing_isp=None", "wan1_routing_isp_enable=0", "wan1_routing_isp=None",
                                  "wans_routing_rulelist=<10.0.0.5>8.8.8.8>0", "wan0_enable=1", "wan1_enable=1", "detect_interval=",
                                  "wans_primary=wan", "wans_lanport1=2", "wans_second=usb", "wans_lanport2=2", "wans_usb_bk=1", "wans_mode=lb",
                                  // The page opened in dual WAN, so form_show(0) never disabled wans_standby.
                                  "wans_standby=0", "wans_lb_ratio_0=3", "wans_lb_ratio_1=1", "wans_isp_unit=0", "wandog_interval=5",
                                  "wandog_maxfail=5", "wandog_fb_count=12", "dns_probe_chk=", "dns_probe_host=dns.msftncsi.com",
                                  "wans_routing_enable=1", "autowan_enable=0", "wan_ifname_x=eth0"])
    #expect(submission.disablesDPI && submission.reboots)

    // 取消 keeps what applyRule did before the question.
    var declined = DualWANForm(page: page(["wans_dualwan": "wan usb"], dpi: #"{"DpiEngine":"1"}"#))
    declined.chooseMode("lb")
    #expect(apply(&declined, [false]) == .cancelled)
    #expect(declined.hidden("wans_dualwan") == "wan usb" && declined.appended.contains(.init(name: "wan_ifname_x", value: "eth0")))
}

@Test func turningDualWANOffFromALANPortAsksAndSendsTheSingleWAN() {
    var form = DualWANForm(page: page(["wans_dualwan": "lan wan", "wans_lanport": "3", "qos_enable": "1"]))
    #expect(form.primary.value == "lan" && form.lanport1.value == "3" && form.lanport1Shown && form.second.value == "wan")
    #expect(form.switchOffQuestion == "当前的主要 WAN 是 LAN Port 3。禁用双 WAN 将更改主要 WAN 为 \"10G WAN/LAN\"，您确定要这样做吗？")
    form.switchOff(defaultMode: "fo", usbBackupActive: "1")
    #expect(form.curState == "0" && form.primary.value == "wan" && !form.secondRowShown && form.usbBackup == "0" && form.usbTetheringShown)
    #expect(form.primary.options.map(\.value) == ["auto", "wan", "2p5g", "sfp", "usb"])
    #expect(form.applying([]).outcome == .confirm("应用设置后，请在 QoS 页面中仔细检查您的下载/上传带宽配置。", .qos))
    #expect(form.applying([true]).outcome == rebootQuestion)
    guard case .submit(let submission) = apply(&form, [true, true]) else { Issue.record("not submitted"); return }
    #expect(lines(submission) == ["current_page=Advanced_WANPort_Content.asp", "next_page=Advanced_WANPort_Content.asp", "modified=0",
                                  "action_mode=apply_new", "action_wait=160", "action_script=reboot", "preferred_lang=CN", "firmver=3.0.0.6",
                                  "wl_ssid=MyWiFi", "wan_unit=0", "wans_extwan=0", "wans_dualwan=wan none", "wans_lanport=3", "dns_probe=1",
                                  "dns_probe_content=*", "wandog_enable=0", "wan0_enable=1", "wan1_enable=0", "bond_wan=0", "wans_usb_bk_act=0",
                                  "detect_interval=", "wans_primary=wan", "wans_lanport1=3", "wans_lanport2=3", "wans_usb_bk=0", "wans_mode=fo",
                                  "wandog_interval=5", "wandog_maxfail=5", "wandog_fb_count=12", "dns_probe_chk=",
                                  "dns_probe_host=dns.msftncsi.com", "autowan_enable=0", "wan_ifname_x=eth0"])
    // A LAN primary that is one of the list's ports is named by the list.
    let special = DualWANForm(page: page(["wans_dualwan": "lan wan", "wans_lanport": "9"]))
    #expect(special.primary.value == "sfp")
    #expect(special.switchOffQuestion == "当前的主要 WAN 是 10G SFP+。禁用双 WAN 将更改主要 WAN 为 \"10G WAN/LAN\"，您确定要这样做吗？")
}

@Test func lanPortsAsWANAndTheLACPConflict() {
    var form = DualWANForm(page: page(["lacp_enabled": "1"]))
    #expect(!form.primary.options.contains { $0.value == "auto" })
    form.switchOn(defaultMode: "fo")
    // 2.5G WAN/LAN1 as the second WAN: the 10G port stays the WAN (wan_ifname_x), 2.5G is LAN port 1.
    form.choose(primary: false, index: index(form.second, "2p5g"))
    #expect(form.applying([]).outcome == .confirm("将 LAN1 配置为 外部网络(WAN) 将停用 \"绑定/链路聚合\" 功能，您确定要继续吗？", .portConflict))
    #expect(form.applying([false]).outcome == .cancelled)
    guard case .submit(let submission) = apply(&form, [true, true]) else { Issue.record("not submitted"); return }
    #expect(submission.value("wans_dualwan") == "wan lan" && submission.value("wans_lanport") == "1" && submission.value("lacp_enabled") == "0")
    #expect(submission.value("wans_second") == "2p5g" && submission.value("wan_ifname_x") == "eth0")
    #expect(lines(submission).firstIndex(of: "lacp_enabled=0")! == lines(submission).firstIndex(of: "wan1_enable=0")! + 1)

    // Ethernet LAN with its port list: wans_lanport is the second list's choice; LAN 3 is not a bonding port.
    var lan = DualWANForm(page: page(["lacp_enabled": "1"]))
    lan.switchOn(defaultMode: "fo")
    lan.choose(primary: false, index: index(lan.second, "lan"))
    lan.chooseLANPort(primary: false, index: index(lan.lanport2, "3"))
    guard case .submit(let lanSubmission) = apply(&lan, [true]) else { Issue.record("not submitted"); return }
    #expect(lanSubmission.value("wans_dualwan") == "wan lan" && lanSubmission.value("wans_lanport") == "3" && lanSubmission.value("lacp_enabled") == nil)

    // The SFP+ port as primary and 2.5G as second: the primary is the LAN port (9), 2.5G takes wan_ifname_x.
    var ports = DualWANForm(page: page())
    ports.switchOn(defaultMode: "fo")
    ports.choose(primary: true, index: index(ports.primary, "sfp"))
    ports.choose(primary: false, index: index(ports.second, "2p5g"))
    guard case .submit(let portSubmission) = apply(&ports, [true]) else { Issue.record("not submitted"); return }
    #expect(portSubmission.value("wans_dualwan") == "lan wan" && portSubmission.value("wans_lanport") == "9" && portSubmission.value("wan_ifname_x") == "eth1")
}

@Test func iptvConflictsAskBeforeTheyAreTurnedOff() {
    var dual = DualWANForm(page: page(["switch_wantag": "unifi_home"]))
    #expect(!dual.primary.options.contains { $0.value == "auto" })
    dual.switchOn(defaultMode: "fo")
    #expect(dual.applying([]).outcome == .confirm("为确保没有冲突，当您启用 双线路 时，IPTV 将被停用。您确定要继续吗？", .iptvForDualWAN))
    guard case .submit(let submission) = apply(&dual, [true, true]) else { Issue.record("not submitted"); return }
    #expect(submission.value("switch_wantag") == "none" && submission.value("switch_stb_x") == "0")

    // A single WAN that is a LAN port turns IPTV off too; 取消 leaves the form as applyRule left it.
    var single = DualWANForm(page: page(["switch_stb_x": "4"]))
    single.choose(primary: true, index: index(single.primary, "2p5g"))
    #expect(single.applying([]).outcome == .confirm("将 \"2.5G WAN/LAN1\" 配置为 外部网络(WAN) 将停用 \"IPTV\" 功能，您确定要继续吗？", .iptvForPort))
    #expect(apply(&single, [false]) == .cancelled)
    #expect(single.wansMode == "fo" && single.hidden("wans_lb_ratio") == nil && single.hidden("wans_routing_rulelist") == nil)
    guard case .submit(let port) = apply(&single, [true, true]) else { Issue.record("not submitted"); return }
    #expect(port.value("wans_dualwan") == "wan none" && port.value("wan_ifname_x") == "eth1" && port.value("switch_stb_x") == "0")
}

@Test func vlanPortsStopTheApply() {
    var form = DualWANForm(page: page(["apg3_enable": "1", "apg3_dut_list": "<\(mac)>3>W0,L4<11:22:33:44:55:66>1>L2"]))
    #expect(form.page.vlanPorts?.access == ["0", "4"])
    form.switchOn(defaultMode: "fo")
    form.choose(primary: false, index: index(form.second, "lan"))
    form.chooseLANPort(primary: false, index: index(form.lanport2, "4"))
    #expect(apply(&form, []) == .alert("WAN 和 VLAN 不能被配置为同一个端口。"))
    // An unreadable dut list stops every apply.
    var broken = DualWANForm(page: page(["apg3_enable": "1", "apg3_dut_list": "<\(mac)>3"]))
    guard case .stopped = apply(&broken, []) else { Issue.record("not stopped"); return }
}

// MARK: - Checks

@Test func checksFollowValidatorJS() {
    // validator.isValidHost: the first pattern's "\." is "." in a string literal.
    // Any character joins the labels, so most words of four or more characters pass ("localh" + "o" + "st").
    for host in ["8.8.8.8", "www.google.com", "dns.msftncsi.com", "8x8x8x8", "google,com", "localhost", "2001:db8::1", "::ffff:1.2.3.4",
                 "user@example.org"] {
        #expect(DualWANForm.hostAlert(host) == nil, "\(host)")
    }
    for host in ["WWW.GOOGLE.COM", "a.b.c", "1.2.3", "foo..bar", "ab", "www.google.com\n", "abc😀com"] {
        #expect(DualWANForm.hostAlert(host) == host + " \n不是有效的 IP 地址！\n这不符合完全限定域名（FQDN）规则。", "\(host)")
    }
    var ping = DualWANForm(page: page())
    ping.setPing(true)
    #expect(apply(&ping, []) == .alert("栏位不能为空白"))
    ping.setPingTarget("foo..bar")
    #expect(apply(&ping, []) == .alert("foo..bar \n不是有效的 IP 地址！\n这不符合完全限定域名（FQDN）规则。"))
    ping.setPingTarget("8.8.8.8")
    guard case .submit(let submission) = apply(&ping, [true]) else { Issue.record("not submitted"); return }
    #expect(submission.value("wandog_enable") == "1" && submission.value("wandog_target") == "8.8.8.8" && submission.value("wandog_enable_chk") == "")

    // dns_probe_timeout 5 makes the interval at least 7.
    var interval = DualWANForm(page: page(["dns_probe_timeout": "5"]))
    #expect(apply(&interval, []) == .alert("请输入一数值介于 7 至 99"))
    interval.interval = "07"
    guard case .submit(let rewritten) = apply(&interval, [true]) else { Issue.record("not submitted"); return }
    #expect(rewritten.value("wandog_interval") == "7")

    var ratio = DualWANForm(page: page(["wans_dualwan": "wan usb"]))
    ratio.chooseMode("lb")
    ratio.setRatio(first: true, "0")
    #expect(apply(&ratio, []) == .alert("请输入一数值介于 1 至 9"))
}

@Test func theHotStandbyPanelSubmitsWithoutTheRebootQuestion() {
    // wans_standby neither 0 nor 1: the list shows 启用, which is not the stored value.
    var form = DualWANForm(page: page(["wans_standby": ""]))
    #expect(apply(&form, []) == .hotStandby)
    #expect(form.standbyPanelShown && form.detectInterval == "2" && form.detectCount.options.count == 99)
    #expect(form.detectCount.value == "5" && form.detectCount.options[4].text == "10" && form.standbyDetectionTime == "10")
    form.detectInterval = "0"
    #expect(form.updateStandbyTime() == "请输入一数值介于 1 至 9")
    form.detectInterval = "3"
    #expect(form.updateStandbyTime() == nil && form.standbyDetectionTime == "15")
    let submission = form.answerStandby(changing: true)
    #expect(submission.value("detect_interval") == "3" && submission.value("detect_count") == "5")
    #expect(submission.value("wandog_interval") == "3" && submission.value("wandog_maxfail") == "5" && submission.actionScript == "reboot")
}

// MARK: - What the app does not run, and the page's leftovers

@Test func pagesTheAppCannotFollowAreOnlyShown() {
    let ssid = page(["wl_ssid": "家"])
    #expect(ssid.attribute("wl_ssid") == "\u{E5}\u{AE}\u{B6}")
    #expect(ssid.problems.contains { $0.contains("wl_ssid") })
    #expect(page(["wan_proto": "dh'cp"]).problems.contains { $0.contains("wan_proto") })
    #expect(page(ethernet: nil).problems.contains { $0.contains("get_ethernet_wan_list") })
    #expect(page(support: ["gobi": "1"]).problems.contains { $0.contains("gobi") })
    #expect(page(["productid": "GT-BE98"]).problems.contains { $0.contains("GT-BE98") })
    // An undecodable rule list stops initial(): no autowan_enable input and no DNS list.
    let stopped = DualWANForm(page: page(encoded: ["wans_routing_rulelist": "%3C1.2.3.4%3E%FF"]))
    #expect(stopped.initialStopped && stopped.appended.isEmpty && stopped.pingTargets.isEmpty && !stopped.aggregationNoteShown)
}

@Test func whatACancelledApplyLeftStaysInTheForm() {
    // Failover disables the load balance fields; nothing enables them again.
    var form = DualWANForm(page: page(["wans_dualwan": "wan usb"]))
    #expect(apply(&form, [false]) == .cancelled)
    form.chooseMode("lb")
    guard case .submit(let lb) = apply(&form, [true]) else { Issue.record("not submitted"); return }
    #expect(lb.value("wans_mode") == "lb" && lb.value("wans_lb_ratio_0") == "3")
    #expect(lb.value("wans_lb_ratio") == nil && lb.value("wans_routing_rulelist") == nil && lb.value("wan0_routing_isp") == nil)

    // wan_ifname_x is added once; afterwards getElementsByName finds the banner's copy first.
    var single = DualWANForm(page: page())
    single.choose(primary: true, index: index(single.primary, "sfp"))
    #expect(apply(&single, [false]) == .cancelled)
    single.choose(primary: true, index: index(single.primary, "wan"))
    guard case .submit(let again) = apply(&single, [true]) else { Issue.record("not submitted"); return }
    #expect(again.value("wans_dualwan") == "wan none" && again.value("wan_ifname_x") == "eth9")
}

// MARK: - Routing rules

@Test func ruleFieldsCheckAndRewriteAsTableValidatorDoes() {
    let invalid = { (text: String) in (text, text + " 不是有效的 IP 地址！") as (String, String?) }
    let cases: [(String, (String, String?))] = [
        ("", ("", "栏位不能为空白")), ("  ", ("", "栏位不能为空白")), (" ALL ", ("all", nil)), ("192.168.001.010", ("192.168.1.10", nil)),
        ("0.0.0.0", invalid("0.0.0.0")), ("255.255.255.255", invalid("255.255.255.255")), ("256.1.1.1", invalid("256.1.1.1")),
        ("1.2.3", invalid("1.2.3")), ("Abc", invalid("abc")), ("10.0.0.0/24", ("10.0.0.0/24", nil)), ("10.0.0.0/024", ("10.0.0.0/24", nil)),
        // parseInt reads the mask: hex, trailing letters and a negative number pass.
        ("10.0.0.0/0x10", ("10.0.0.0/16", nil)), ("010.0.0.0/24ABC", ("10.0.0.0/24", nil)), ("10.0.0.0/-5", ("10.0.0.0/-5", nil)),
        ("10.0.0.0/0", invalid("10.0.0.0/0")), ("10.0.0.0/33", invalid("10.0.0.0/33")), ("10.0.0.0/", invalid("10.0.0.0/")),
        ("1.2.3.4/5/6", invalid("1.2.3.4/5/6")), ("0.0.0.0/8", invalid("0.0.0.0/8"))
    ]
    for (input, expected) in cases {
        let result = DualWANRuleField.leave(input)
        #expect(result.value == expected.0 && result.hint == expected.1, "\(input)")
    }
    // keyPress: a dot after three characters without one, "." and "/" where the page allows them, a and l only.
    #expect(DualWANRuleField.typing("1", after: "192") == "192." && DualWANRuleField.typing("1", after: "19") == "19")
    #expect(DualWANRuleField.typing("3", after: "1.2.3") == "1.2.3" && DualWANRuleField.typing("4", after: "1.2.333") == "1.2.333.")
    #expect(DualWANRuleField.typing("5", after: "1.2.3.444") == "1.2.3.444")
    #expect(DualWANRuleField.typing(".", after: "1.") == nil && DualWANRuleField.typing(".", after: "1.2.3.4") == nil && DualWANRuleField.typing(".", after: "12") == "12")
    #expect(DualWANRuleField.typing("/", after: "1.2.3") == nil && DualWANRuleField.typing("/", after: "1.2.3.4") == "1.2.3.4")
    #expect(DualWANRuleField.typing("x", after: "") == nil && DualWANRuleField.typing("A", after: "") == "" && DualWANRuleField.typing("l", after: "a") == "a")
    #expect(DualWANRuleField.edited("192", "1921", key: "1") == "192.1" && DualWANRuleField.edited("192", "192x", key: "x") == "192")
    #expect(DualWANRuleField.edited("192.", "192", key: nil) == "192" && DualWANRuleField.edited("", "1234567890123456789012", key: nil) == "123456789012345678")
    // maxlength stops the typed character, not the dot keyPress added.
    #expect(DualWANRuleField.edited("12345678901234567", "123456789012345678", key: "8") == "12345678901234567.")
    #expect(DualWANRuleField.edited("123.123.123.123456", "123.123.123.1234567", key: "7") == "123.123.123.123456")
    // A key typed over a selection goes through keyPress too; a pasted character is not filtered.
    #expect(DualWANRuleField.edited("1.2.3.4", "1.2.3.x", key: "x") == "1.2.3.4" && DualWANRuleField.edited("1.2.3.4", "1.2.3.x", key: nil) == "1.2.3.x")
}

@Test func theCreatePanelAddsRulesAsThePageDoes() {
    var form = DualWANForm(page: page(["wans_dualwan": "wan usb", "wans_mode": "lb", "wans_routing_enable": "1",
                                       "wans_routing_rulelist": "<10.0.0.5>8.8.8.8>0"]))
    form.chooseMode("lb")
    #expect(form.routingRulesShown && form.ruleAddAlert == nil)
    // A blank field gets its hint and ends the loop: the second one is not looked at.
    var panel = DualWANRulePanel()
    #expect(form.addRule(&panel) == .hint && panel.sourceHint == "栏位不能为空白" && panel.destinationHint == nil)
    panel.source = "192.168.001.000/024"; panel.leave(0)
    panel.destination = " ALL"; panel.leave(1)
    panel.unit = "1"
    #expect(panel.source == "192.168.1.0/24" && panel.destination == "all" && panel.sourceHint == nil)
    #expect(form.addRule(&panel) == .done)
    #expect(form.rules == [["10.0.0.5", "8.8.8.8", "0"], ["192.168.1.0/24", "all", "1"]])
    // The same source and destination with another WAN is a duplicate; equal source and destination is refused.
    var again = DualWANRulePanel()
    again.source = "192.168.1.0/24"; again.leave(0); again.destination = "all"; again.leave(1)
    #expect(form.addRule(&again) == .alert("此项已纳入列表中。"))
    var same = DualWANRulePanel()
    same.source = "all"; same.leave(0); same.destination = "all"; same.leave(1)
    #expect(form.addRule(&same) == .alert("Source IP and Destination IP can not be ALL at the same time"))
    var wrong = DualWANRulePanel()
    wrong.source = "1.2.3"; wrong.leave(0); wrong.destination = "all"; wrong.leave(1)
    #expect(form.addRule(&wrong) == .hint && wrong.sourceHint == "1.2.3 不是有效的 IP 地址！" && form.rules.count == 2)
    // The list goes with 应用本页面设置.
    guard case .submit(let submission) = apply(&form, [true]) else { Issue.record("not submitted"); return }
    #expect(submission.value("wans_routing_rulelist") == "<10.0.0.5>8.8.8.8>0<192.168.1.0/24>all>1")
    // 64 rules: 新增 alerts instead of opening the panel.
    let full = DualWANForm(page: page(["wans_routing_rulelist": (1...64).map { "<10.0.0.\($0)>all>0" }.joined()]))
    #expect(full.rules.count == 64 && full.ruleAddAlert == "本表仅允许 64 项目！")
}

@Test func editingARowChecksEachFieldWhenItIsLeft() {
    var form = DualWANForm(page: page(["wans_dualwan": "wan usb", "wans_routing_enable": "1",
                                       "wans_routing_rulelist": "<010.0.0.5>8.8.8.8>0<192.168.1.0/24>all>1<1.1.1.1>2.2.2.2"]))
    form.chooseMode("lb")
    // Leaving a field without changing it still runs the check, which writes the plain address into the list.
    var edit = form.editRule(at: 0)!
    #expect(edit.values == ["010.0.0.5", "8.8.8.8", "0"])
    form.leaveRuleEdit(&edit, column: 0)
    #expect(edit.values[0] == "10.0.0.5" && form.rules[0] == ["10.0.0.5", "8.8.8.8", "0"] && edit.canFinish)
    // Row 0 as 192.168.1.0/24 → all repeats row 1 (the WAN is not compared): the hint stays and the list keeps its value.
    edit.values[0] = "192.168.1.0/24"; form.leaveRuleEdit(&edit, column: 0)
    #expect(form.rules[0][0] == "192.168.1.0/24" && edit.canFinish)
    edit.values[1] = "ALL"; form.leaveRuleEdit(&edit, column: 1)
    #expect(edit.hints[1] == "此项已纳入列表中。" && !edit.canFinish && form.rules[0][1] == "8.8.8.8")
    edit.values[1] = "192.168.1.0/24"; form.leaveRuleEdit(&edit, column: 1)
    #expect(edit.hints[1] == "Source IP and Destination IP can not be ALL at the same time" && form.rules[0][1] == "8.8.8.8")
    edit.values[1] = "8.8.4.4"; form.leaveRuleEdit(&edit, column: 1)
    #expect(edit.canFinish && form.rules[0] == ["192.168.1.0/24", "8.8.4.4", "0"])
    edit.values[1] = "x"; form.leaveRuleEdit(&edit, column: 1)
    #expect(edit.hints[1] == "x 不是有效的 IP 地址！" && form.rules[0][1] == "8.8.4.4")
    // The WAN list commits unless the row already repeats another.
    var unit = form.editRule(at: 1)!
    #expect(form.changeRuleUnit(&unit, "0") == nil && form.rules[1][2] == "0")
    // A row without three fields: tableRuleValidation returns undefined, an empty hint that keeps the value out.
    var short = form.editRule(at: 2)!
    short.values[0] = "1.1.1.2"; form.leaveRuleEdit(&short, column: 0)
    #expect(short.hints[0] == "" && !short.canFinish && form.rules[2] == ["1.1.1.1", "2.2.2.2"])
    guard case .submit(let submission) = apply(&form, [true]) else { Issue.record("not submitted"); return }
    #expect(submission.value("wans_routing_rulelist") == "<192.168.1.0/24>8.8.4.4>0<192.168.1.0/24>all>0<1.1.1.1>2.2.2.2")

    // A row that already repeats another refuses a new WAN.
    var twins = DualWANForm(page: page(["wans_dualwan": "wan usb", "wans_routing_enable": "1", "wans_routing_rulelist": "<1.1.1.1>all>0<1.1.1.1>all>1"]))
    twins.chooseMode("lb")
    var twin = twins.editRule(at: 0)!
    #expect(twins.changeRuleUnit(&twin, "1") == "此项已纳入列表中。" && twins.rules[0][2] == "0")
}

// MARK: - Through the router

@Test func readingOnlyReadsAndApplyingPostsTheFormOnce() async throws {
    var nvram = stored
    nvram["apg2_enable"] = "1"; nvram["apg2_dut_list"] = "<\(mac)>3>L3"
    let router = DualWANRouter(nvram: nvram, support: rtbe88u,
                               hooks: ["get_ethernet_wan_list": ethernetList, "get_default_reboot_time": "160", "bwdpi_engine_status": #"{"DpiEngine":"0"}"#,
                                       "get_lan_hwaddr": "\"\(mac)\"", "nvram_default_get(wans_mode)": "\"fo\""],
                               pages: ["get_port_status.cgi": portStatus, "ajax/DNS_List.json": dnsList])
    let client = RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: router, writes: .reference)
    let page = try await client.dualWANPage()
    #expect(await router.writes.isEmpty)
    let requests = await router.requests
    #expect(requests.contains { $0.path == "get_port_status.cgi" && $0.query["node_mac"] == mac })
    #expect(requests.contains { $0.path == "ajax/DNS_List.json" && $0.query["v"] == "0" })
    let hooks = requests.compactMap { $0.query["hook"] }
    for hook in ["get_ethernet_wan_list()", "get_default_reboot_time()", "bwdpi_engine_status()", "get_lan_hwaddr()"] { #expect(hooks.contains(hook)) }
    #expect(hooks.contains { $0.contains("nvram_char_to_ascii(apg2_dut_list,apg2_dut_list)") })
    #expect(page.problems.isEmpty && page.vlanPorts?.access == ["3"] && page.rebootTime == "160")

    var form = DualWANForm(page: page)
    form.switchOn(defaultMode: try await client.dualWANDefaultMode())
    #expect(form.wansMode == "fo")
    guard case .submit(let submission) = apply(&form, [true]) else { Issue.record("not submitted"); return }
    #expect(try await client.submitDualWAN(submission) == .restarting)
    let writes = await router.writes
    #expect(writes.count == 1 && writes[0].path == "start_apply.htm")
    #expect(writes[0].body == "current_page=Advanced_WANPort_Content.asp&next_page=Advanced_WANPort_Content.asp&modified=0&action_mode=apply_new"
                            + "&action_wait=160&action_script=reboot&preferred_lang=CN&firmver=3.0.0.6&wl_ssid=MyWiFi&wan_unit=0&wans_extwan=0"
                            + "&wans_dualwan=wan+usb&wans_lanport=1&dns_probe=1&dns_probe_content=*&wandog_enable=0&wan0_enable=1&wan1_enable=1"
                            + "&detect_interval=&wans_primary=wan&wans_lanport1=2&wans_second=usb&wans_lanport2=2&wans_usb_bk=1&wans_mode=fo"
                            + "&wandog_interval=5&wandog_maxfail=5&wandog_fb_count=12&dns_probe_chk=&dns_probe_host=dns.msftncsi.com"
                            + "&autowan_enable=0&wan_ifname_x=eth0")

    // apply_new without a change: no service runs.
    let quiet = DualWANRouter(nvram: stored, support: rtbe88u, hooks: [:], pages: [:], applyReply: "<script>no_changes_and_no_committing();</script>")
    #expect(try await RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: quiet, writes: .reference).submitDualWAN(submission) == .unchanged)
    #expect(try await RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: quiet, writes: .reference).dualWANUSBBackupActive() == "0")
}

@Test func theDualWANTabIsNative() {
    #expect(WebMenuCatalog.location(of: .dualWAN) == WebLocation(menu: "menu_WAN", page: "Advanced_WANPort_Content.asp", part: "main"))
}
