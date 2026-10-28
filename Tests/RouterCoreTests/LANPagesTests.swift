import Foundation
import Testing
@testable import RouterCore

// 1.11 read-only pages: 内部网络(LAN) › VLAN and VLAN 配置文件. Values follow the shapes the Asuswrt-Merlin 3006.102.5
// pages read (sdn_rl, vlan_rl, apgN_dut_list, vlan_trunklist, get_cfg_clientlist, get_port_status.cgi), with invented
// MACs, network names and port answers.

private let router = "AA:BB:CC:DD:EE:01", node = "AA:BB:CC:DD:EE:02", missing = "AA:BB:CC:DD:EE:99"

// MARK: Ordered JSON and JavaScript numbers

@Test func orderedJSONKeepsTheOrderTheRouterWrote() throws {
    let json = try OrderedJSON(data: Data(#"{"L2":{"a":1},"L1":[true,null,"x\/yé"],"W0":-1.5e2,"L2":2,"10":"t"}"#.utf8))
    // A repeated name keeps its first place and its last value, as JSON.parse does.
    #expect(json.members.map(\.0) == ["L2", "L1", "W0", "10"])
    #expect(json["L2"] == .number("2") && json["W0"]?.text == "-1.5e2" && json["10"] == .string("t"))
    #expect(json["L1"] == .array([.bool(true), .null, .string("x/yé")]))
    // JavaScript enumerates array-index names first.
    #expect(VLANPortBuilder.enumerationOrder(json.members).map(\.0) == ["10", "L2", "L1", "W0"])
    for bad in ["{", #"{"a":}"#, "[1,]", "01", #""\x""#, "{} x", "nul"] {
        #expect(throws: RouterError.self) { try OrderedJSON(data: Data(bad.utf8)) }
    }
}

@Test func numbersAreReadAsJavaScriptsNumberReadsThem() {
    #expect(javaScriptNumber("") == 0 && javaScriptNumber(" \u{3000} ") == 0 && javaScriptNumber(" 3 ") == 3)
    #expect(javaScriptNumber("0x10") == 16 && javaScriptNumber("0b11") == 3 && javaScriptNumber("0o17") == 15)
    #expect(javaScriptNumber("1e3") == 1000 && javaScriptNumber(".5") == 0.5 && javaScriptNumber("5.") == 5 && javaScriptNumber("+1") == 1)
    #expect(javaScriptNumber("-Infinity") == -.infinity && javaScriptNumber("1.e2") == 100)
    #expect(javaScriptNumber("abc") == nil && javaScriptNumber("1_0") == nil && javaScriptNumber("-0x1") == nil && javaScriptNumber("0x") == nil)
    #expect(javaScriptNumber(nil) == nil && javaScriptNumber("inf") == nil && javaScriptNumber("1 2") == nil)
    #expect(javaScriptLooselyEquals(" 1", 1) && !javaScriptLooselyEquals(nil, 0) && javaScriptLooselyEquals("", 0))
}

// MARK: VLAN 配置文件

@Test func vlanProfilesNameTheirNetworksAsThePageDoes() {
    let values = ["sdn_rl": "<1>A>1>1>2>3<2>B>1>1>2>4<3>C>1>9>0>5<4>D>1>2>0>6<5>E>1>0>0>7",
                  "vlan_rl": "<1>52>0<2>60> 1<3>", "apg3_ssid": "Guest", "apg4_ssid": "", "apg6_ssid": "Late"]
    // Row C names VLAN 9, which vlan_rl does not have: the page's script stops there, so D is not named.
    let named = VLANProfileList.namedRows(sdnRL: values["sdn_rl"]!, vlanRL: values["vlan_rl"]!, trunkList: "<\(router)>L1#all>L2#")
    #expect(named.map(\.apg) == ["3", "4"])
    // A trunk port without "#" throws while the page parses vlan_trunklist, before it names any network.
    #expect(VLANProfileList.namedRows(sdnRL: values["sdn_rl"]!, vlanRL: values["vlan_rl"]!, trunkList: "<\(router)>L1").isEmpty)
    let stopped = VLANProfileList(values: values.merging(["vlan_trunklist": "<\(router)>L1#52>"]) { _, new in new }, support: [:])
    #expect(stopped.profiles.map(\.shownNetworks) == ["--", "--", "--"])
    let list = VLANProfileList(values: values, support: ["mtlancfg": "1"])
    #expect(list.profiles == [
        .init(networks: ["Guest", ""], vid: "52", isolated: false),
        .init(networks: [], vid: "60", isolated: true),
        .init(networks: [], vid: "", isolated: false)
    ])
    #expect(list.feature == "专业访客网络" && list.description.hasSuffix("请前往 专业访客网络"))
    #expect(guestNetworkNaming([:]) == "访客网络" && guestNetworkNaming(["mtlancfg": "1", "BUSINESS": "1"]) == "自定义网络")
    // A single network without a name joins to nothing, which the page shows as "--".
    let unnamed = VLANProfileList(values: ["sdn_rl": "<1>A>1>1>2>3", "vlan_rl": "<1>52>1", "apg3_ssid": ""], support: [:])
    #expect(unnamed.profiles.first?.networks == [] && unnamed.profiles.first?.isolated == true)
    // The names go into the cell as HTML, joined with <br>.
    // A <br> at the end makes no empty line.
    #expect(list.profiles[0].shownNetworks == "Guest" && list.profiles[1].shownNetworks == "--")
    let marked = VLANProfileList(values: ["sdn_rl": "<1>A>1>1>2>3<2>B>1>1>2>4", "vlan_rl": "<1>52>1", "apg3_ssid": "Guest &lt;IoT&gt;", "apg4_ssid": "A  <i>b</i>"], support: [:])
    #expect(marked.profiles[0].shownNetworks == "Guest <IoT>\nA b")
}

// MARK: VLAN（端口）

private func json(_ text: String) -> OrderedJSON { try! OrderedJSON(data: Data(text.utf8)) }

private func port(_ isOn: String, _ link: String, _ max: String, cap: Int = 2, name: String? = nil) -> String {
    #"{"is_on":\#(isOn),"link_rate":"\#(link)","max_rate":"\#(max)","cap":"\#(cap)""# + (name.map { #","ui_display":"\#($0)""# } ?? "") + "}"
}

private func status(_ mac: String, _ ports: [(String, String)]) -> OrderedJSON {
    json(#"{"node_info":{"\#(mac)":{}},"port_info":{"\#(mac)":{"# + ports.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + "}}}")
}

private func meshNode(_ mac: String, alias: String = "Living Room", capability4: String = "0", online: String = "1", lanPorts: Bool = true) -> OrderedJSON {
    json(#"{"mac":"\#(mac)","model_name":"RT-BE88U","product_id":"RT-BE88U","alias":"\#(alias)","online":\#(online),"capability":{"4":\#(capability4)"#
         + (lanPorts ? #","27":{"lan_port":[{"index":"1"}]}"# : "") + "}}")
}

private let profiles = ["sdn_rl": "<1>Guest>1>1>2>3<2>IoT>1>0>0>4", "vlan_rl": "<1>52>0<2>60>1", "productid": "RT-BE88U"]
private let profileValues = ["apg3_ssid": "Guest", "apg3_dut_list": "<\(router)>3>L4"]

@Test func vlanPortsShowLinksModesAndProfilesAsThePageDraws() throws {
    let values = profiles.merging(["wans_dualwan": "wan lan", "wans_lanport": "2", "bond_wan": "0", "lacp_enabled": "0", "switch_stb_x": "1",
                                   "iptv_stb_port": "LAN3", "iptv_voip_port": "4", "iptv_bridge_port": "",
                                   "vlan_trunklist": "<\(router)>L6#all>L7#60"]) { _, new in new }
    let ports: [(String, String)] = [
        ("W0", port(#""1""#, "1000", "2500", cap: 1)), ("L1", port(#""1""#, "1000", "2500")), ("L2", port(#""0""#, "0", "2500")),
        ("L3", port(#""2""#, "100", "1000")), ("L4", port("1", "2500", "2500")), ("L5", port(#""1""#, "10000", "10000", cap: 3, name: "10G WAN/LAN")),
        ("L6", port(#""1""#, "2500", "2500")), ("L7", port(#""1""#, "2500", "2500"))
    ]
    let mesh = [meshNode(router), meshNode(node, lanPorts: false), meshNode(missing)]
    let table = VLANPortTable(values: values, support: [:], mesh: mesh, status: [router: status(router, ports)], apgValues: profileValues)
    // The node without LAN ports and the one whose answer has no node_info are not listed.
    #expect(table.nodes.map(\.id) == [router])
    let cap = try #require(table.nodes.first)
    #expect(cap.title == "AiMesh 路由器" && cap.model == "RT-BE88U" && cap.location == "客厅" && cap.waiting == nil)
    #expect(cap.rows.map { $0.map(\.id) } == [["0", "1", "2", "3"], ["4", "5", "6"]])
    let all = cap.rows.flatMap { $0 }
    // L1: connected, the maximum rate under the icon, All with the profile list disabled.
    #expect(all[0] == .init(id: "0", link: .connected, number: "1", caption: "2.5 Gbps", speed: "1 Gbps", aggregation: false,
                            mode: .shown("全部(默认值)"), profile: .locked("默认值")))
    // L2 is the dual WAN LAN port and L3 an IPTV port ("LAN3".indexOf("3") > 0); both are locked.
    #expect(all[1].link == .unplugged && all[1].speed == nil && all[1].aggregation && all[1].mode == .locked("全部(默认值)"))
    #expect(all[2].link == .warning && all[2].speed == "100 Mbps" && all[2].caption == "1 Gbps" && all[2].aggregation && all[2].profile == .locked("默认值"))
    // L4: is_on as a number is not a state the switch knows; the network's dut list makes it Access with its SSID, and
    // "4" at the start of iptv_voip_port does not count as an IPTV port.
    #expect(all[3] == .init(id: "3", link: .unknown, number: "4", caption: nil, speed: nil, aggregation: false, mode: .shown("Access"), profile: .shown("Guest")))
    // L5 has a name and the WAN capability; L6 and L7 are trunks: all tagging, and the pure VLAN profile as "(60)".
    #expect(all[4].number == "" && all[4].caption == "10G WAN/LAN" && all[4].speed == "10 Gbps" && !all[4].aggregation && all[4].mode == .locked("全部(默认值)"))
    #expect(all[5].mode == .shown("Trunk") && all[5].profile == .shown("Allow all tagging(默认值)"))
    #expect(all[6].mode == .shown("Trunk") && all[6].profile == .shown("(60)"))
    #expect(cap.notes == [
        .init(html: "<b>LAN 2</b>: 由于硬件限制，此端口目前无法使用 VLAN 功能。 <a id=\"modify_wans\">点击这里</a>进行修改。", destination: .dualWAN),
        .init(html: "<b>LAN 3</b>: 此端口正在由 网络电视 (IPTV) 使用。 <a id=\"modify_iptv\">点击这里</a>进行修改。", destination: .iptv),
        .init(html: "<b>10G WAN/LAN</b>: 此端口正在由 以太网 WAN 使用。", destination: nil)
    ])
}

@Test func vlanNotesKeepThePagesMistakes() throws {
    let values = profiles.merging(["bond_wan": "1", "lacp_enabled": "1", "switch_stb_x": "0"]) { _, new in new }
    let ports = (1...4).map { ("L\($0)", port(#""1""#, "1000", "1000")) }
    let table = VLANPortTable(values: values, support: ["lacp": "1"], mesh: [meshNode(router)], status: [router: status(router, ports)], apgValues: [:])
    let notes = try #require(table.nodes.first?.notes)
    // WAN aggregation (port key 3) names its ports through an undefined `a`: only "</b>" stays in its note, and
    // "<b>LAN undefined" starts the LACP note, which then stays bold to the end.
    #expect(notes.map(\.html) == [
        "</b>: 此端口正在由 WAN 聚合 使用。 <a id=\"modify_wan_bonding\">点击这里</a>进行修改。",
        "<b>LAN undefined<b>LAN 1</b> / <b>LAN 2</b>: 此端口正在由 绑定/链路聚合 使用。"
    ])
    #expect(VLANPortTable.runs(notes[0].html) == [.init(text: ": 此端口正在由 WAN 聚合 使用。 ", bold: false, link: false),
                                                  .init(text: "点击这里", bold: false, link: true), .init(text: "进行修改。", bold: false, link: false)])
    #expect(VLANPortTable.runs(notes[1].html) == [.init(text: "LAN undefinedLAN 1 / LAN 2: 此端口正在由 绑定/链路聚合 使用。", bold: true, link: false)])
    // LACP takes LAN 1 and 2 (get_bonding_ports' default), WAN aggregation the port with key 3; LAN 3 is free.
    #expect(table.nodes.first!.rows.flatMap { $0 }.map(\.aggregation) == [true, true, false, true])
    // Names and numbers are collected apart and paired by position, so a port without a name takes the next one's.
    var wan = VLANPortBuilder.Collected()
    wan.add("1", ""); wan.add("2", "2.5G WAN")
    #expect(wan.html == "<b>2.5G WAN</b> / <b>LAN 2</b>")
}

@Test func vlanPortsFollowTheScriptWhereItStops() {
    // A trunk entry for a node the table does not list throws; the dut list before it has already set L1 to Access.
    let values = profiles.merging(["vlan_trunklist": "<\(missing)>L1#52<\(router)>L2#all"]) { _, new in new }
    let ports: [(String, String)] = [("L1", port(#""1""#, "1000", "1000")), ("L2", port(#""1""#, "1000", "1000")), ("L10", port(#""0""#, "1000", "1000"))]
    let table = VLANPortTable(values: values, support: [:], mesh: [meshNode(router)], status: [router: status(router, ports)],
                              apgValues: ["apg3_ssid": "Guest", "apg3_dut_list": "<\(router)>3>L1"])
    let all = table.nodes.first!.rows.flatMap { $0 }
    // L10 lands on port[-1]: after the indices, and left out of the length.
    #expect(all.map(\.id) == ["0", "1", "-1"] && all[2].number == "10")
    #expect(all[0].mode == .shown("Access") && all[1].mode == .shown("全部(默认值)"))
    // An answer whose port list holds a member that is not an object stops the script at that node: nothing after it
    // is listed and no profile is applied.
    let broken = json(#"{"node_info":{"\#(node)":{}},"port_info":{"\#(node)":{"W0":"down","L1":{"is_on":"1"}}}}"#)
    let stopped = VLANPortTable(values: profiles, support: [:], mesh: [meshNode(router), meshNode(node), meshNode(missing)],
                                status: [router: status(router, ports), node: broken, missing: status(missing, ports)], apgValues: profileValues)
    #expect(stopped.nodes.map(\.id) == [router])
    #expect(stopped.nodes[0].rows.flatMap { $0 }.allSatisfy { $0.mode == .shown("全部(默认值)") })
    // An array member loses the cap_support set_cap_support gave it in the handler's JSON copy, which then throws.
    let arrayMember = json(#"{"node_info":{"\#(node)":{}},"port_info":{"\#(node)":{"L1":[]}}}"#)
    let arrayStopped = VLANPortTable(values: profiles, support: [:], mesh: [meshNode(router), meshNode(node)],
                                     status: [router: status(router, ports), node: arrayMember], apgValues: profileValues)
    #expect(arrayStopped.nodes.map(\.id) == [router])
    // An answer without port_info throws when the page reads port_info[mac].
    let noPorts = VLANPortTable(values: profiles, support: [:], mesh: [meshNode(router)], status: [router: json(#"{"node_info":{}}"#)], apgValues: [:])
    #expect(noPorts.nodes.isEmpty)
    // capability 4 bit 22 (Smart Home Master UI) keeps a node out.
    let master = VLANPortTable(values: profiles, support: [:], mesh: [meshNode(router, capability4: "4194304")], status: [router: status(router, ports)], apgValues: [:])
    #expect(master.nodes.isEmpty)
}

@Test func vlanNodesWithoutPortsWaitOrShowDisconnected() {
    let wanOnly = [("W0", port(#""1""#, "1000", "1000", cap: 1))]
    let offline = VLANPortTable(values: profiles, support: [:], mesh: [meshNode(router), meshNode(node, alias: "Office", online: #""0""#)],
                                status: [router: status(router, wanOnly), node: status(node, wanOnly)], apgValues: [:])
    #expect(offline.nodes.map(\.waiting) == [.loading, .disconnected] && offline.reloadsSoon)
    #expect(offline.nodes[1].title == "AiMesh 节点" && offline.nodes[1].location == "办公室" && offline.nodes[1].rows.isEmpty)
    // A WAN port of a node is its backhaul.
    let ports = [("L1", port(#""1""#, "1000", "1000", cap: 1))]
    let backhaul = VLANPortTable(values: profiles, support: [:], mesh: [meshNode(router), meshNode(node)],
                                 status: [router: status(router, ports), node: status(node, ports)], apgValues: [:])
    #expect(backhaul.nodes.map { $0.notes.map(\.html) } == [["<b>LAN 1</b>: 此端口正在由 以太网 WAN 使用。"], ["<b>LAN 1</b>: 此端口正在由 Ethernet Backhaul 使用。"]])
}

// MARK: Reading through the client

private actor LANRouter: RouterTransport {
    let nvram: [String: String]
    let support: [String: String]
    let mesh: String?
    let portStatus: [String: String]
    /// JSON answers of other hooks by name. A hook (or "get_port_status.cgi") in `cancelled` throws CancellationError, as
    /// a request does when its task is cancelled; one in `waiting` answers only when its task is cancelled; one in
    /// `expired` answers 401, as when the login has expired.
    let hooks: [String: String]
    let cancelled: Set<String>
    let waiting: Set<String>
    let expired: Set<String>
    private(set) var requests: [URLRequest] = []
    init(nvram: [String: String], support: [String: String] = [:], mesh: String?, portStatus: [String: String] = [:],
         hooks: [String: String] = [:], cancelled: Set<String> = [], waiting: Set<String> = [], expired: Set<String> = []) {
        self.nvram = nvram; self.support = support; self.mesh = mesh; self.portStatus = portStatus; self.hooks = hooks
        self.cancelled = cancelled; self.waiting = waiting; self.expired = expired
    }
    func send(_ request: URLRequest) async throws -> RouterHTTPResponse {
        requests.append(request)
        guard let url = request.url, request.httpMethod == "GET" else { throw RouterError.network("Only reads are expected") }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let hook = query.first { $0.name == "hook" }?.value ?? ""
        let name = hook.hasSuffix("()") ? String(hook.dropLast(2)) : url.lastPathComponent
        if cancelled.contains(name) { throw CancellationError() }
        if waiting.contains(name) { try await Task.sleep(for: .seconds(60)); throw CancellationError() }
        if expired.contains(name) { return RouterHTTPResponse(data: Data(), status: 401) }
        switch url.lastPathComponent {
        case "appGet.cgi":
            if hook == "get_ui_support()" { return try Self.reply(["get_ui_support": support]) }
            if hook == "get_cfg_clientlist()" {
                guard let mesh else { return RouterHTTPResponse(data: Data("<html>".utf8), status: 200) }
                return RouterHTTPResponse(data: Data("{\"get_cfg_clientlist\":\(mesh)}".utf8), status: 200)
            }
            if hook.hasSuffix("()"), let answer = hooks[String(hook.dropLast(2))] {
                return RouterHTTPResponse(data: Data("{\"\(hook.dropLast(2))\":\(answer)}".utf8), status: 200)
            }
            var object: [String: String] = [:]
            for call in hook.split(separator: ";") {
                guard call.hasPrefix("nvram_char_to_ascii("), let open = call.firstIndex(of: "("), let comma = call.firstIndex(of: ",") else { continue }
                let key = String(call[call.index(after: open)..<comma]); object[key] = nvram[key] ?? ""
            }
            return try Self.reply(object)
        case "get_port_status.cgi":
            let mac = query.first { $0.name == "node_mac" }?.value ?? ""
            return RouterHTTPResponse(data: Data((portStatus[mac] ?? "{}").utf8), status: 200)
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
    func asked(_ hook: String) -> Bool {
        requests.contains { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "hook" }?.value == hook + "()" }
    }
    static func reply(_ object: Any) throws -> RouterHTTPResponse { RouterHTTPResponse(data: try JSONSerialization.data(withJSONObject: object), status: 200) }
}

private func client(_ transport: LANRouter) throws -> RouterClient { RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: transport, writes: .reference) }

@Test func vlanPagesReadOnlyWithGets() async throws {
    let meshText = #"[{"mac":"\#(router)","model_name":"RT-BE88U","product_id":"RT-BE88U","alias":"Home","online":"1","capability":{"27":{"lan_port":{"1":{}}}}},"#
        + #"{"mac":"\#(node)","model_name":"RT-AX58U","capability":{"4":"0"}}]"#
    let statusText = #"{"node_info":{"\#(router)":{}},"port_info":{"\#(router)":{"L1":{"is_on":"1","link_rate":"1000","max_rate":"1000","cap":"2"}}}}"#
    let transport = LANRouter(nvram: profiles.merging(profileValues) { _, new in new }, mesh: meshText, portStatus: [router: statusText, "all": #"{"node_info":{"a":{},"b":{}}}"#])
    let reader = try client(transport)
    let table = try await reader.vlanPortTable()
    #expect(table.nodes.map(\.id) == [router] && table.nodes[0].location == "家中")
    let requests = await transport.requests
    #expect(requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil })
    // Only the node with LAN ports is asked for its ports, by its MAC.
    let portRequests = requests.filter { $0.url?.lastPathComponent == "get_port_status.cgi" }
    #expect(portRequests.compactMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems }.map { $0.map(\.value) } == [[router]])
    #expect(await transport.readKeys.isSuperset(of: ["vlan_trunklist", "wans_lanport", "apg3_ssid", "apg3_dut_list"]))
    #expect(!(await transport.readKeys).contains("apg4_ssid"))
    #expect(await reader.vlanReportedNodeCount() == 2)
    let profileList = try await reader.vlanProfileList()
    #expect(profileList.profiles.map(\.networks) == [["Guest"], []])
    // A get_cfg_clientlist answer that is not JSON lists no node, as the page's hookGet answers "".
    let quiet = LANRouter(nvram: profiles, mesh: nil)
    #expect(try await client(quiet).vlanPortTable().nodes.isEmpty)
    // The port status page takes a MAC or "all", nothing else.
    await #expect(throws: RouterError.self) { try await reader.readDataPage(.portStatus, [("node_mac", "a b")]) }
    await #expect(throws: RouterError.self) { try await reader.readDataPage(.portStatus, [("label_name", "all")]) }
}

@Test func vlanPartsHaveNativeHomes() {
    #expect(WebMenuCatalog.location(of: .vlanPorts) == WebLocation(menu: "menu_LAN", page: "Advanced_VLAN_Switch_Content.asp", part: "ports"))
    #expect(WebMenuCatalog.location(of: .vlanProfiles) == WebLocation(menu: "menu_LAN", page: "Advanced_VLAN_Switch_Content.asp", part: "profiles"))
}

// MARK: TOR

@Test func torNamesComeFromThePagesClientList() {
    let current = json(#"{"maclist":["\#(router)","aa:bb:cc:dd:ee:03","AA:BB:CC:DD:EE:03","AA:BB:CC:DD:EE:04"],"#
        + #""\#(router)":{"mac":"\#(router)","name":" Desk ","nickName":"","isOnline":"1"},"#
        + #""aa:bb:cc:dd:ee:03":{"mac":"aa:bb:cc:dd:ee:03","name":"Phone","nickName":" My <b>Phone</b> ","isOnline":"0"},"#
        + #""AA:BB:CC:DD:EE:03":{"mac":"AA:BB:CC:DD:EE:03","name":"Second","nickName":"","isOnline":"1"},"#
        + #""AA:BB:CC:DD:EE:04":{"mac":"AA:BB:CC:DD:EE:04","name":" ","nickName":""}}"#)
    let history = json(#"{"maclist":["AA:BB:CC:DD:EE:05","AA:BB:CC:DD:EE:06"],"#
        + #""AA:BB:CC:DD:EE:05":{"mac":"AA:BB:CC:DD:EE:05","name":"Old <TV>","vendor":"x"},"#
        + #""AA:BB:CC:DD:EE:06":{"mac":"AA:BB:CC:DD:EE:06","nickName":"Gone","vendor":"y"}}"#)
    let names = TORSettings.clientNames(current: current, history: history, lanMAC: "AA:BB:CC:DD:EE:10", productID: "RT-BE88U", amas: true)
    // Upper-case MACs, the first entry winning; nickName before name; a blank name is the MAC; history names are encoded.
    #expect(names == [router: "Desk", "AA:BB:CC:DD:EE:03": "My <b>Phone</b>", "AA:BB:CC:DD:EE:04": "AA:BB:CC:DD:EE:04",
                      "AA:BB:CC:DD:EE:05": "Old &lt;TV&gt;", "AA:BB:CC:DD:EE:06": "Gone", "AA:BB:CC:DD:EE:10": "RT-BE88U"])
    // A history answer without maclist ends genClientList: no history and no router entry.
    #expect(TORSettings.clientNames(current: current, history: nil, lanMAC: "AA:BB:CC:DD:EE:10", productID: "RT-BE88U", amas: true).count == 3)
    // A history device without vendor is added, then genClientList stops.
    let noVendor = json(#"{"maclist":["AA:BB:CC:DD:EE:05","AA:BB:CC:DD:EE:06"],"AA:BB:CC:DD:EE:05":{"mac":"AA:BB:CC:DD:EE:05","name":"Old"},"#
        + #""AA:BB:CC:DD:EE:06":{"mac":"AA:BB:CC:DD:EE:06","name":"Late","vendor":"y"}}"#)
    #expect(TORSettings.clientNames(current: nil, history: noVendor, lanMAC: "X", productID: "P", amas: true) == ["AA:BB:CC:DD:EE:05": "Old"])
    // A device whose name is not text keeps its empty name and stops the list.
    let broken = json(#"{"maclist":["A","B"],"A":{"mac":"a","name":5,"nickName":""},"B":{"mac":"b","name":"B","nickName":""}}"#)
    #expect(TORSettings.clientNames(current: broken, history: history, lanMAC: "X", productID: "P", amas: true) == ["A": ""])
    // On AiMesh routers an online AiMesh node counts as an offline device when the history list is counted; a number 1
    // is online. More than a hundred counted devices end the history list (546–595).
    let mesh = json(#"{"maclist":["A","C"],"A":{"mac":"A","name":"Node","nickName":"","isOnline":"1","amesh_isRe":"1"},"#
        + #""C":{"mac":"C","name":"Laptop","nickName":"","isOnline":1}}"#)
    let others = (1...100).map { "B\($0)" }
    let longHistory = json("{\"maclist\":[" + (["A", "C"] + others + ["T"]).map { "\"\($0)\"" }.joined(separator: ",") + "],"
        + (["A", "C"] + others + ["T"]).map { "\"\($0)\":{\"mac\":\"\($0)\",\"name\":\"n\($0)\",\"vendor\":\"v\"}" }.joined(separator: ",") + "}")
    #expect(TORSettings.clientNames(current: mesh, history: longHistory, lanMAC: "X", productID: "P", amas: true)["T"] == nil)
    #expect(TORSettings.clientNames(current: mesh, history: longHistory, lanMAC: "X", productID: "P", amas: false)["T"] == "nT")
    #expect(TORSettings.looselyEqualsOne(.number("1")) && TORSettings.looselyEqualsOne(.bool(true)) && !TORSettings.looselyEqualsOne(.string(" 1")))
    // An array compares as the text JavaScript turns it into: [[1]] and [1.0] are "1"; [" 1"], [null,1] and {} are not.
    #expect(TORSettings.looselyEqualsOne(.array([.array([.number("1")])])) && TORSettings.looselyEqualsOne(.array([.number("1.0")])))
    #expect(!TORSettings.looselyEqualsOne(.array([.string(" 1")])) && !TORSettings.looselyEqualsOne(.array([.null, .number("1")]))
            && !TORSettings.looselyEqualsOne(.object([])))
    #expect(TORSettings.javaScriptString(.array([.null, .array([.number("1e999"), .bool(false)]), .object([])])) == ",Infinity,false,[object Object]")
    // So a device online as [[1]] is not counted, and the device after a hundred others still gets its name.
    let upToT = json("{\"maclist\":[" + (["A"] + others + ["T"]).map { "\"\($0)\"" }.joined(separator: ",") + "],"
        + (["A"] + others + ["T"]).map { "\"\($0)\":{\"mac\":\"\($0)\",\"name\":\"n\($0)\",\"vendor\":\"v\"}" }.joined(separator: ",") + "}")
    let nested = json(#"{"maclist":["A"],"A":{"mac":"A","name":"Node","nickName":"","isOnline":[[1]]}}"#)
    let spaced = json(#"{"maclist":["A"],"A":{"mac":"A","name":"Node","nickName":"","isOnline":[" 1"]}}"#)
    #expect(TORSettings.clientNames(current: nested, history: upToT, lanMAC: "X", productID: "P", amas: false)["T"] == "nT")
    #expect(TORSettings.clientNames(current: spaced, history: upToT, lanMAC: "X", productID: "P", amas: false)["T"] == nil)
    // The TOR list shows the names as a browser shows their HTML.
    let tor = TORSettings(values: ["Tor_enable": "1", "Tor_redir_list": "<AA:BB:CC:DD:EE:03<AA:BB:CC:DD:EE:05"], names: names)
    #expect(tor.names["AA:BB:CC:DD:EE:03"] == "My Phone" && tor.names["AA:BB:CC:DD:EE:05"] == "Old <TV>")
}

@Test func torShowsWhatThePageShows() {
    let on = TORSettings(values: ["Tor_enable": "1", "Tor_socksport": "9050", "Tor_transport": "9040", "Tor_dnsport": "9053",
                                  "Tor_redir_list": "<\(router)<\(node.lowercased())"])
    #expect(on.enableTitle == "启用" && on.enabled && on.socksPort == "9050" && on.dnsPort == "9053")
    #expect(on.specifiedMACs && on.macs == [router, node.lowercased()])
    // Off hides the rows; a value that is neither leaves the list on its first option, 启用, with the rows hidden.
    #expect(TORSettings(values: ["Tor_enable": "0"]).enableTitle == "停用")
    let unset = TORSettings(values: [:])
    #expect(unset.enableTitle == "启用" && !unset.enabled && !unset.specifiedMACs)
    // A list without "<" shows 目前没有数据 under Only Specified MACs; text before the first "<" is not shown.
    let noSeparator = TORSettings(values: ["Tor_enable": "1", "Tor_redir_list": router])
    #expect(noSeparator.specifiedMACs && noSeparator.macs == nil)
    #expect(TORSettings(values: ["Tor_redir_list": "x<\(router)"]).macs == [router])
}

// MARK: 用户自定义优先级

private let qosDefaults = ["qos_orates": "80-100,10-100,5-100,3-100,2-95,0-0,0-0,0-0,0-0,0-0", "qos_irates": "100,100,100,100,100,0,0,0,0,0",
                           "qos_obw": "102400", "qos_ibw": "512", "qos_enable": "1", "qos_ack": "on", "qos_syn": "on", "qos_fin": "off", "qos_rst": "off", "qos_icmp": "on"]

@Test func qosPrioritiesShowTheLimitsAndRanges() {
    let priority = QoSUserPriority(values: qosDefaults, support: ["bwdpi": "1"])
    #expect(priority.title == "带宽管理 QoS - 传统带宽管理" && !priority.showsEnableHint)
    #expect(priority.levels.first == .init(name: "最高", uploadMin: "80", uploadMax: "100", downloadMax: "100", uploadRange: "80 ~ 100 Mb/s", downloadRange: "0 ~ 512 Kb/s"))
    #expect(priority.levels.last?.uploadRange == "2 ~ 95 Mb/s" && priority.levels.map(\.name) == ["最高", "高", "中", "低", "最低"])
    #expect(priority.packets.map(\.on) == [true, true, false, false, true])
    // 100000 Kb/s shows as 97.66 Mb/s; the ranges are rounded to hundredths from that.
    let fractional = QoSUserPriority(values: qosDefaults.merging(["qos_obw": "100000", "qos_orates": "10-20,1-2,1-2,1-2,1-2"]) { _, new in new }, support: [:])
    #expect(fractional.title == "流量管理 - QoS" && fractional.levels[0].uploadRange == "9.77 ~ 19.53 Mb/s")
    // Values are matched as numbers; one that is no option leaves its list on 0. Bandwidth that is not a number gives NaN.
    let odd = QoSUserPriority(values: qosDefaults.merging(["qos_orates": "05-abc,1-2,1-2,1-2,1-2", "qos_obw": "abc", "qos_enable": "0"]) { _, new in new }, support: [:])
    #expect(odd.levels[0].uploadMin == "5" && odd.levels[0].uploadMax == "0" && odd.levels[0].uploadRange == "NaN ~ NaN Kb/s" && odd.showsEnableHint)
    // With fewer than five entries gen_options throws at the first missing one: later lists stay empty, no range is
    // written and the hint stays, whatever qos_enable says.
    let short = QoSUserPriority(values: qosDefaults.merging(["qos_orates": "10-20,30-40"]) { _, new in new }, support: [:])
    #expect(short.levels.map(\.uploadMin) == ["10", "30", nil, nil, nil] && short.levels.allSatisfy { $0.uploadRange == nil } && short.showsEnableHint)
    #expect(javaScriptRound(2.5) == 3 && javaScriptRound(-2.5) == -2 && javaScriptText(9.77) == "9.77" && javaScriptText(100) == "100")
    // Math.round decides from the fraction, so the largest number below a half rounds down.
    #expect(javaScriptRound(0.49999999999999994) == 0 && javaScriptRound(0.5) == 1 && javaScriptRound(-0.4) == 0)
    // Number::toString beyond Int64 and around the switch to exponent notation, as JavaScript writes them.
    #expect(javaScriptText(9.765625e18) == "9765625000000000000" && javaScriptText(1.2345678901234568e20) == "123456789012345680000")
    #expect(javaScriptText(1e21) == "1e+21" && javaScriptText(1e-7) == "1e-7" && javaScriptText(0.000001) == "0.000001")
    #expect(javaScriptText(-0.0) == "0" && javaScriptText(-1.5) == "-1.5" && javaScriptText(.nan) == "NaN" && javaScriptText(2.5e-8) == "2.5e-8")
    let huge = QoSUserPriority(values: qosDefaults.merging(["qos_obw": "1e22"]) { _, new in new }, support: [:])
    // Checked against node: 80 × 9765625000000000000 is not exact in floating point.
    #expect(huge.levels[0].uploadRange == "7812499999999999000 ~ 9765625000000000000 Mb/s")
}

@Test func htmlEntityTableLoads() {
    // The full WHATWG list: 2231 names, legacy ones with and without ";".
    #expect(HTMLText.entities.count == 2231 && HTMLText.entities["lt;"] == "<" && HTMLText.entities["copy"] == "©")
}

@Test func htmlTextShowsWhatABrowserShows() {
    #expect(HTMLText.visible("a &lt;b&gt; &amp;&#60&#x3e; &nbsp;c") == "a <b> &<> \u{00A0}c")
    // The image that does not load keeps the spaces on either side apart, as Chrome draws it.
    #expect(HTMLText.visible(" one  <br/>two<b>bold</b> <img src=x> three<i") == "one\ntwobold  three")
    // The full list of named references, the longest match first; numeric references with the Windows-1252 table and
    // leading zeros.
    #expect(HTMLText.decode("&copy; &#0; &unknown; &notit; &notin; &#128; &#000000065; &#x110000; &#x;") == "© \u{FFFD} &unknown; ¬it; ∉ € A \u{FFFD} &#x;")
    // <br> with attributes, a quoted ">" in an attribute, references decoded before white space collapses, white space
    // collapsing across tags, hidden script text, comments, blocks and a final <br>.
    #expect(HTMLText.visible("A<br class=x>B") == "A\nB" && HTMLText.visible("A&#32; B") == "A B" && HTMLText.visible(#"A<span title=">">B</span>"#) == "AB")
    #expect(HTMLText.visible("A <b> B</b>") == "A B" && HTMLText.visible("<script>x<b>y</script>z") == "z" && HTMLText.visible("<!-- c -->z<!-->w") == "zw")
    #expect(HTMLText.visible("x</div><div>y") == "x\ny" && HTMLText.visible("a<br><br>") == "a\n" && HTMLText.visible("a</br>b") == "a\nb")
    #expect(HTMLText.visible("1 < 2 </") == "1 < 2 </" && HTMLText.visible("a<!DOCTYPE x>b</ junk>c</>d") == "abcd")
    #expect(VLANPortTable.runs("<B>A &amp; B</b><br>x<i>y</i>") == [.init(text: "A & B", bold: true, link: false), .init(text: "\nxy", bold: false, link: false)])
}

@Test func htmlTextFollowsTheParsersElements() {
    func runs(_ html: String) -> [String] { VLANPortTable.runs(html).map { ($0.bold ? "*" : "") + ($0.link ? "@" : "") + $0.text } }
    // CR LF and CR are read as LF and collapse with other white space, also when a reference makes them.
    #expect(HTMLText.visible("A\r\nB") == "A B" && HTMLText.visible("A\rB") == "A B" && HTMLText.visible("A&#13;&#10; B") == "A B")
    #expect(runs("A\r\n<b>B</b>") == ["A ", "*B"])
    // A comment ends at "--!>" too, and "--!-" does not end it.
    #expect(HTMLText.visible("A<!--x--!>B") == "AB" && HTMLText.visible("A<!--x--!->B") == "A" && HTMLText.visible("A<!---->B") == "AB")
    // xmp and plaintext show their raw text as written, as blocks keeping white space; textarea decodes references and
    // drops a first line feed; an end tag at the very end does not close raw text.
    #expect(HTMLText.visible("<xmp>Guest</xmp>") == "Guest" && HTMLText.visible("A<xmp><b>&copy;  x</xmp>B") == "A\n<b>&copy;  x\nB")
    #expect(HTMLText.visible("<xmp>a</xmp") == "a</xmp" && HTMLText.visible("A<plaintext></b>&amp;") == "A\n</b>&amp;")
    #expect(HTMLText.visible("<textarea>\n &lt;x&gt;  y</textarea>") == " <x>  y")
    // pre keeps spaces and line feeds, without its first line feed unless something comes before it.
    #expect(HTMLText.visible("<pre>\n  a  b\n</pre>c") == "  a  b\nc" && HTMLText.visible("<pre><!---->\nx</pre>") == "\nx")
    // What the default style hides shows nothing, its line breaks included.
    #expect(HTMLText.visible("A<noscript>B</noscript>C") == "AC" && HTMLText.visible("A<template><div>B</div></template>C") == "AC")
    #expect(HTMLText.visible("A<dialog>B</dialog>C") == "AC" && HTMLText.visible("A<title>T</title>B") == "AB")
    // An end tag with nothing open to close is ignored; one that closes an open block ends its line, and the elements
    // inside it end with it. </p> alone still makes an (empty) paragraph.
    #expect(HTMLText.visible("A</section>B") == "AB" && HTMLText.visible("A</hr>B") == "AB" && HTMLText.visible("A</p>B") == "A\nB")
    #expect(HTMLText.visible("<section>A</section>B") == "A\nB" && HTMLText.visible("<div>A<span>B</div>C</span>D") == "AB\nCD")
    #expect(HTMLText.visible("<li>a<li>b") == "a\nb" && HTMLText.visible("<ul><li>a</ul>b") == "a\nb" && HTMLText.visible("<h1>A<h2>B") == "A\nB")
    // Lines as Chrome draws them (measured): a <br> before a block or at the end, and a final line feed in a pre, add no
    // line; an image gives a block a line, and spaces on either side of one stay apart.
    #expect(HTMLText.visible("A<div><br>B</div>") == "A\n\nB" && HTMLText.visible("A<br><div>B</div>") == "A\nB")
    #expect(HTMLText.visible("a<br><br><br>") == "a\n\n" && HTMLText.visible("<pre>a\n\n</pre>c") == "a\n\nc" && HTMLText.visible("<div>A<br></div>B") == "A\nB")
    #expect(HTMLText.visible("x <img> <img> y") == "x   y" && HTMLText.visible("A<div><img></div>B") == "A\n\nB" && HTMLText.visible("a <embed> b") == "a b")
    // Written into a <div> of a table cell, as the TOR list does, "</div>" ends that div; "</td>" is not followed.
    #expect(HTMLText.visible("A</div>B", inside: ["td", "div"]) == "A\nB" && HTMLText.visible("A</td>B", inside: ["td", "div"]) == "AB")
    #expect(TORSettings.listText("x</div>y") == "x\ny" && TORSettings.listText("x</div>y</div>z") == "x\nyz")
    // b reopens after a block that closed it and ends at its own end tag; formatting opened inside an object ends with
    // it, and an end tag for formatting opened before it is ignored inside; a second a closes the first.
    #expect(runs("<b>A<div>B</b>C</div>") == ["*A\nB", "C"] && runs("<div><b>A</div>B") == ["*A\nB"])
    #expect(runs("<object><b>A</object>B") == ["*A", "B"] && runs("<b><object>A</b>B</object>C") == ["*ABC"])
    #expect(runs("<a>x<a>y</a>z") == ["@xy", "z"])
    // Formatting elements are on the stack of open elements, as in Chrome's DOM: </b> closes the datalist opened inside
    // it, the adoption agency moves a block that was inside it, a heading opened inside b leaves the outer heading open,
    // and </form> takes only the form off the stack.
    #expect(HTMLText.visible("<b><datalist></b>Guest") == "Guest" && HTMLText.visible("<b><datalist><div>x</b>y") == "xy")
    #expect(runs("<h1><b>A<h2>B</h2>C</h1>D") == ["*A\nB\nC\nD"] && runs("<b>1<p>2</b>3</p>") == ["*1\n2", "3"])
    #expect(runs("<div><b>A</div><p>B") == ["*A\nB"] && runs("<i><b><u><s><p>x</i>y") == ["*xy"] && runs("<b><b><b><b>x</b></b></b></b>y") == ["*x", "y"])
    #expect(HTMLText.visible("<form><div>x</form>y") == "xy" && HTMLText.visible("<p><button><p>x</button>y") == "x\ny")
    #expect(TORSettings.listText("<b><datalist></b>Guest") == "Guest" && TORSettings.listText("<h1><b>A<h2>B</h2>C</h1>D") == "A\nB\nC\nD")
    // Noah's Ark counts elements as the same by name and attributes (lower-case names, decoded values, any order, the
    // first of a repeated name): four b with different ids all stay, so the first is opened again for y; four alike leave
    // three, which the three </b> remove (Chrome, measured). In attribute values "&ampx" is not decoded.
    #expect(runs("<p><b id=1><b id=2><b id=3><b id=4>x</p></b></b></b>y") == ["*x\ny"] && runs("<p><b><b><b><b>x</p></b></b></b>y") == ["*x", "\ny"])
    #expect(runs(#"<p><b title="&amp;"><b title="&"><b title=&amp;><b title='&'>x</p></b></b></b>y"#) == ["*x", "\ny"])
    #expect(runs("<p><b a=1 c=2><b c=2 a=1><b A=1 c=2 a=3><b c=2 a=1>x</p></b></b></b>y") == ["*x", "\ny"])
    #expect(runs("<p><b t='&ampx'><b t='&amp;x'><b t='&ampx'><b t='&ampx'>x</p></b></b></b>y") == ["*x\ny"])
    #expect(HTMLText.decode("&ampx &amp= &amp;x", inAttribute: true) == "&ampx &amp= &x" && HTMLText.decode("&ampx &amp=") == "&x &=")
    // Deep nesting and a wide adoption agency stay within the call stack and in linear time.
    #expect(HTMLText.visible(String(repeating: "<span>", count: 20000) + "X") == "X")
    #expect(runs("<b><div>" + String(repeating: "<span>x</span>", count: 4000) + "</b>") == ["*" + String(repeating: "x", count: 4000)])
    // search closes a p and is a block, but is not special (Chrome, measured): </em> does not move it, and </span> closes
    // the span around it.
    #expect(HTMLText.visible("<p>a<search>b") == "a\nb" && HTMLText.visible("<em><search>a</em>b") == "a\nb" && HTMLText.visible("<span>a<search>b</span>c") == "a\nb\nc")
    // Past a stack of 512 open elements, a new element goes next to the current node, as Chrome does (measured): the b
    // after 511 divs is inside the last one, after 512 or more it follows the last div as a block.
    #expect(HTMLText.visible(String(repeating: "<div>", count: 511) + "x<b>y</b>") == "xy")
    #expect(HTMLText.visible(String(repeating: "<div>", count: 512) + "x<b>y</b>") == "x\ny")
    #expect(HTMLText.visible(String(repeating: "<div>", count: 2000) + "x<b>y</b>") == "x\ny")
    // Preformatted spaces stay at the end of a line and at the end; only collapsible ones are removed.
    #expect(HTMLText.visible("<pre>a  \nb  </pre>") == "a  \nb  " && HTMLText.visible("<pre>  </pre>") == "  " && HTMLText.visible("<xmp>a  </xmp>") == "a  ")
    #expect(runs("<textarea>a  </textarea>b") == ["a  b"])
    // The earlier counterexamples hold for the styled pieces as well.
    #expect(runs("<b>A</b><xmp><b>x</xmp>") == ["*A", "\n<b>x"] && runs("<b>A<!--x--!>B</b>") == ["*AB"] && runs("<b>A</section>B</b>") == ["*AB"])
}

@Test func torAndPriorityReadOnlyWithGets() async throws {
    let transport = LANRouter(nvram: qosDefaults.merging(["Tor_enable": "1", "Tor_redir_list": "<\(router)"]) { _, new in new }, support: ["bwdpi": "1"], mesh: nil)
    let reader = try client(transport)
    let tor = try await reader.torSettings()
    #expect(tor.macs == [router] && tor.names.isEmpty)
    // With the devices hooks answering, the names come through: the listed MAC by its nickName, as HTML.
    let devices = #"{"maclist":["\#(router)"],"\#(router)":{"mac":"\#(router)","name":"Desk","nickName":"Desk &amp; Lamp","isOnline":"1"}}"#
    let named = LANRouter(nvram: ["Tor_enable": "1", "Tor_redir_list": "<\(router)<\(node)"], mesh: nil,
                          hooks: ["get_clientlist": devices, "get_clientlist_from_json_database": #"{"maclist":[]}"#])
    #expect(try await client(named).torSettings().names == [router: "Desk & Lamp"])
    let hooksAsked = await named.requests.compactMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value }
    #expect(hooksAsked.contains("get_clientlist()") && hooksAsked.contains("get_clientlist_from_json_database()"))
    // A cancelled read ends in CancellationError instead of a reading without names; other failures read as empty.
    for hook in ["get_clientlist", "get_clientlist_from_json_database"] {
        let cancelling = LANRouter(nvram: ["Tor_enable": "1", "Tor_redir_list": "<\(router)"], mesh: nil, hooks: ["get_clientlist": devices], cancelled: [hook])
        await #expect(throws: CancellationError.self) { try await client(cancelling).torSettings() }
    }
    let cancelledMesh = LANRouter(nvram: profiles, mesh: "[]", cancelled: ["get_cfg_clientlist"])
    await #expect(throws: CancellationError.self) { try await client(cancelledMesh).vlanPortTable() }
    #expect(try await reader.qosUserPriority().levels.count == 5)
    #expect(await transport.requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil && $0.url?.lastPathComponent == "appGet.cgi" })
    #expect(WebMenuCatalog.location(of: .tor)?.page == "Advanced_TOR_Content.asp")
    #expect(WebMenuCatalog.location(of: .qosUserPriority) == WebLocation(menu: "menu_BandwidthMonitor", page: "QoS_EZQoS.asp", part: "priority"))
}

@Test func optionalReadsEndWhenCancelledOrSignedOut() async throws {
    // A read cancelled while the router has not answered ends there: nothing is asked after the request that waited.
    let devices = #"{"maclist":[]}"#
    let slow = LANRouter(nvram: ["Tor_enable": "1", "Tor_redir_list": "<\(router)"], mesh: nil,
                         hooks: ["get_clientlist_from_json_database": devices], waiting: ["get_clientlist"])
    let reader = try client(slow)
    let task = Task { try await reader.torSettings() }
    var waiting = false
    for _ in 0..<500 {
        if await slow.asked("get_clientlist") { waiting = true; break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(waiting)
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    let asked = await slow.requests.count
    try await Task.sleep(for: .milliseconds(100))
    let after = await slow.requests.count, history = await slow.asked("get_clientlist_from_json_database")
    #expect(after == asked && !history)
    // The VLAN page's port answers stop a cancelled read too; an expired login is reported, not read as an empty answer.
    let mesh = #"[{"mac":"\#(router)","capability":{"27":{"lan_port":{"1":{}}}}}]"#
    await #expect(throws: CancellationError.self) { try await client(LANRouter(nvram: profiles, mesh: mesh, cancelled: ["get_port_status.cgi"])).vlanPortTable() }
    for page in ["get_port_status.cgi", "get_cfg_clientlist"] {
        await #expect(throws: RouterError.authenticationRequired) { try await client(LANRouter(nvram: profiles, mesh: mesh, expired: [page])).vlanPortTable() }
    }
    for hook in ["get_clientlist", "get_clientlist_from_json_database"] {
        let expired = LANRouter(nvram: ["Tor_enable": "1", "Tor_redir_list": "<\(router)"], mesh: nil,
                                hooks: ["get_clientlist": devices, "get_clientlist_from_json_database": devices], expired: [hook])
        await #expect(throws: RouterError.authenticationRequired) { try await client(expired).torSettings() }
    }
}
