import Foundation

// 内部网络(LAN) › VLAN（1.11）：VLAN 分页（Advanced_VLAN_Switch_Content.asp）与 VLAN 配置文件分页
// （Advanced_VLAN_Profile_Content.asp），按 Asuswrt-Merlin tag 3006.102.5 打开时显示的内容。只读：只发 GET。

/// Number(text) in JavaScript (StringToNumber), nil for NaN and for a missing value: white space around the number is
/// ignored, blank text is 0, and besides decimals (sign, fraction, exponent, Infinity) only unsigned 0x/0o/0b integers count.
func javaScriptNumber(_ text: String?) -> Double? {
    guard let text else { return nil }
    let scalars = Array(text.unicodeScalars)
    func space(_ scalar: Unicode.Scalar) -> Bool {
        [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0xFEFF, 0x2028, 0x2029].contains(scalar.value) || scalar.properties.generalCategory == .spaceSeparator
    }
    guard let first = scalars.firstIndex(where: { !space($0) }), let last = scalars.lastIndex(where: { !space($0) }) else { return 0 }
    let body = String(String.UnicodeScalarView(scalars[first...last]))
    func matches(_ pattern: String) -> Bool { body.range(of: pattern, options: .regularExpression) != nil }
    if matches(#"^[+-]?Infinity$"#) { return body.hasPrefix("-") ? -.infinity : .infinity }
    for (pattern, radix) in [(#"^0[xX][0-9A-Fa-f]+$"#, 16.0), (#"^0[oO][0-7]+$"#, 8.0), (#"^0[bB][01]+$"#, 2.0)] where matches(pattern) {
        return body.dropFirst(2).reduce(0.0) { $0 * radix + Double(Int(String($1), radix: Int(radix)) ?? 0) }
    }
    guard matches(#"^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][+-]?[0-9]+)?$"#) else { return nil }
    var digits = Substring(body), sign = 1.0
    if let mark = digits.first, mark == "+" || mark == "-" { sign = mark == "-" ? -1 : 1; digits = digits.dropFirst() }
    var decimal = String(digits)
    if decimal.hasPrefix(".") { decimal = "0" + decimal }
    decimal = decimal.replacingOccurrences(of: ".e", with: ".0e").replacingOccurrences(of: ".E", with: ".0E")
    if decimal.hasSuffix(".") { decimal += "0" }
    return Double(decimal).map { sign * $0 }
}

/// `text == number` in JavaScript for a text that may be missing (undefined equals no number).
func javaScriptLooselyEquals(_ text: String?, _ number: Double) -> Bool {
    guard let text, let value = javaScriptNumber(text) else { return false }
    return value == number
}

/// convertRulelistToJson (Advanced_VLAN_Switch_Content.asp 363–384, Advanced_VLAN_Profile_Content.asp 90–111): entries
/// between "<" (empty ones skipped), fields between ">"; a field the entry does not have is undefined (nil).
enum RouterRuleRows {
    static func rows(_ list: String) -> [[String]] {
        list.components(separatedBy: "<").filter { !$0.isEmpty }.map { $0.components(separatedBy: ">") }
    }
}

extension Array where Element == String {
    subscript(field index: Int) -> String? { indices.contains(index) ? self[index] : nil }
}

/// sdn_rl fields the VLAN pages read (sdnRuleTable 132–151 / 405–424) and vlan_rl's (vlanRuleTable 126–130 / 399–403).
enum VLANFields {
    static let sdnVLAN = 3, sdnAPG = 5
    static let vlanIndex = 0, vlanID = 1, vlanIsolation = 2
}

/// Guest_Network_naming (state.js 991–1003): what the VLAN 配置文件 page calls the page for networks with DHCP.
func guestNetworkNaming(_ support: [String: String]) -> String {
    func on(_ name: String) -> Bool { !["", "0"].contains(support[name] ?? "") }
    guard on("mtlancfg") else { return "访客网络" }
    if on("BUSINESS") { return "自定义网络" }
    return on("SMART_HOME_MASTER_UI") ? "访客网络" : "专业访客网络"
}

// MARK: - VLAN 配置文件

/// 内部网络(LAN) › VLAN › VLAN 配置文件 (Advanced_VLAN_Profile_Content.asp): the vlan_rl profiles in the router's order,
/// each with the names of the networks that use it, as show_vlan_profile (257–357) lists them when the page opens.
public struct VLANProfileList: Sendable, Equatable {
    public struct Profile: Sendable, Equatable {
        /// 无线名称（SSID）, one line per network; the page shows "--" when they join to nothing (320–326).
        public let networks: [String]
        /// VLAN ID as written; an entry without one leaves the cell empty (327).
        public let vid: String
        /// 端口隔离, checked when port_isolation == 1 (332–337).
        public let isolated: Bool

        /// The cell as a browser shows it: the names joined with <br> and inserted as HTML, or "--".
        public var shownNetworks: String { networks.isEmpty ? "--" : HTMLText.visible(networks.joined(separator: "<br>")) }
        public var shownVID: String { HTMLText.visible(vid) }
    }
    public let profiles: [Profile]
    /// $feature$ in the description (86–87).
    public let feature: String

    public var description: String {
        "VLAN 设置在此指的是创建仅包含 VLAN 的网络。如果您希望创建带有 DHCP 的 VLAN，请前往 \(feature)"
    }

    /// The networks the list names (213–238): sdn_rl rows with a VLAN (vlan_idx > 0) whose vlan_rl entry is there and
    /// whose apg index is above 0. The page's script stops at a row whose vlan_idx no entry has (it reads vid of
    /// vlan_rl_json[-1]), so no row after it is named; and before any row, at a vlan_trunklist port without "#"
    /// (`split("#")[1].split(",")`, 190–211), so then none is.
    static func namedRows(sdnRL: String, vlanRL: String, trunkList: String) -> [(vlanIndex: String, apg: String)] {
        let trunks = trunkList.components(separatedBy: "<")
        if trunks.count > 1, trunks.dropFirst().contains(where: { $0.components(separatedBy: ">").dropFirst().contains { !$0.contains("#") } }) {
            return []
        }
        let vlans = RouterRuleRows.rows(vlanRL)
        var named: [(vlanIndex: String, apg: String)] = []
        for row in RouterRuleRows.rows(sdnRL) {
            guard let vlanIndex = row[field: VLANFields.sdnVLAN], let number = javaScriptNumber(vlanIndex), number > 0 else { continue }
            guard vlans.contains(where: { $0[field: VLANFields.vlanIndex] == vlanIndex }) else { break }
            if let apg = row[field: VLANFields.sdnAPG], let index = javaScriptNumber(apg), index > 0 { named.append((vlanIndex, apg)) }
        }
        return named
    }

    static func ssidKey(apg: String) -> String { "apg\(apg)_ssid" }

    public init(values: [String: String], support: [String: String]) {
        let named = Self.namedRows(sdnRL: values["sdn_rl"] ?? "", vlanRL: values["vlan_rl"] ?? "", trunkList: values["vlan_trunklist"] ?? "")
        profiles = RouterRuleRows.rows(values["vlan_rl"] ?? "").map { vlan in
            let names = named.filter { $0.vlanIndex == vlan[field: VLANFields.vlanIndex] }.map { values[Self.ssidKey(apg: $0.apg)] ?? "" }
            return Profile(networks: names.joined(separator: ",").isEmpty ? [] : names, vid: vlan[field: VLANFields.vlanID] ?? "",
                           isolated: javaScriptLooselyEquals(vlan[field: VLANFields.vlanIsolation], 1))
        }
        feature = guestNetworkNaming(support)
    }
}

// MARK: - VLAN（端口）

/// 内部网络(LAN) › VLAN › VLAN (Advanced_VLAN_Switch_Content.asp): for the AiMesh router and each node that reports LAN
/// ports, the ports' link state and VLAN mode and profile, as gen_VLAN_port_table (700–1389) draws them when the page
/// opens, with the notes under each table.
public struct VLANPortTable: Sendable, Equatable {
    public enum Link: Sendable, Equatable {
        /// `unknown`: an is_on the page's switch does not know; it draws the unplugged icon without the text under it.
        case unplugged, connected, warning, unknown
    }

    /// One of the page's selection lists.
    public enum Selection: Sendable, Equatable {
        /// Disabled, showing this text.
        case locked(String)
        /// The text the list shows; nil when it has no choices.
        case shown(String?)
    }

    public struct Port: Sendable, Equatable, Identifiable {
        /// The port's key in the page's port array.
        public let id: String
        public let link: Link
        /// The number on the icon: the label without "L", empty when the port has its own name.
        public let number: String
        /// The text under the icon: the port's own name or its maximum rate.
        public let caption: String?
        /// The link rate shown when pointing at a connected or warned port.
        public let speed: String?
        /// "Aggregation" on the icon: a port of dual WAN, WAN aggregation, LACP or IPTV.
        public let aggregation: Bool
        public let mode: Selection
        public let profile: Selection
    }

    /// Where a note's 点击这里 leads.
    public enum Destination: String, Sendable, Equatable {
        case dualWAN = "Advanced_WANPort_Content.asp", wan = "Advanced_WAN_Content.asp", iptv = "Advanced_IPTV_Content.asp"
    }

    /// A note under a table as the HTML the page builds (1224–1382); `runs` shows it the way a browser does.
    public struct Note: Sendable, Equatable {
        public let html: String
        public let destination: Destination?
    }

    public struct NoteRun: Sendable, Equatable {
        public let text: String
        public let bold: Bool
        public let link: Bool
    }

    public struct Node: Sendable, Equatable, Identifiable {
        public let id: String
        /// AiMesh 路由器 for the first node listed, AiMesh 节点 for the rest (772–779).
        public let title: String
        /// Model, MAC address and location, as the first header cell lists them (785).
        public let model: String
        public let mac: String
        public let location: String
        /// The ports, four to a row (812–1202).
        public let rows: [[Port]]
        /// Without ports: 联机中断 for an offline node; otherwise the page waits and reloads after 30 seconds (1205–1222).
        public let waiting: Waiting?
        public let notes: [Note]
    }

    public enum Waiting: Sendable, Equatable { case disconnected, loading }

    public let nodes: [Node]

    /// The page reloads after 30 seconds while a node waits for its ports (1220).
    public var reloadsSoon: Bool { nodes.contains { $0.waiting == .loading } }

    public static let description = "VLAN 交换机控制设置"
    /// str_vlan_desc2 (156) with CN.dict's VALN_Switch_desc2.
    public static let modeDescription = "若要同时将 VLAN 端口设置为 AiMesh 以太回传端口，请选择“全部(默认值)”。Access模式和Trunk模式中的 VLAN 端口不支持此类设置。"

    /// nvram the page reads (426–434, 608), and productid (based_modelid, state.js 278) for get_bonding_ports.
    static let keys = ["wans_dualwan", "wans_lanport", "bond_wan", "wanports_bond", "lacp_enabled", "switch_stb_x", "iptv_stb_port",
                       "iptv_voip_port", "iptv_bridge_port", "sdn_rl", "vlan_rl", "vlan_trunklist", "productid"]

    /// How a browser shows a note's HTML (HTMLText's rules): <b> makes the text bold until its </b> (a stray </b> does
    /// nothing and an unclosed <b> lasts to the end), and the text inside <a …></a> is the link.
    public static func runs(_ html: String) -> [NoteRun] {
        HTMLText.layout(HTMLText.tokens(html)).map { NoteRun(text: $0.text, bold: $0.bold, link: $0.link) }
    }
}

/// The page's script on the router's answers: what runs as it loads (426–643), then what initial draws (700–1389). A
/// statement that throws ends the loading script but not initial, so the table then shows what was set up to that point;
/// `Stop` stands for such a statement.
struct VLANPortBuilder {
    struct Stop: Error {}

    /// rate_map (161–168).
    static let rates: [(value: String, text: String)] = [("10", "10 Mbps"), ("100", "100 Mbps"), ("1000", "1 Gbps"), ("2500", "2.5 Gbps"),
                                                         ("5000", "5 Gbps"), ("10000", "10 Gbps")]
    /// aimesh_location_arr (state.js 1005–1015) with CN.dict's names.
    static let locations: [String: String] = [
        "Home": "家中", "Living Room": "客厅", "Dining Room": "餐厅", "Bedroom": "卧室", "Office": "办公室", "Stairwell": "楼梯间", "Hall": "大厅",
        "Kitchen": "厨房", "Attic": "阁楼", "Basement": "地下室", "Yard": "院子", "Master Bedroom": "主卧", "Guest Room": "客房", "Kids Room": "儿童房",
        "Study Room": "书房", "Hallway": "玄关", "Walk-in Closet": "步入式衣帽间", "Bathroom": "浴室", "First Floor": "一楼", "Second Floor": "二楼",
        "Third Floor": "三楼", "Storage": "储物间", "Balcony": "阳台", "Meeting Room": "会议室", "Garage": "车库", "Gaming Room": "游戏室", "Gym": "健身房",
        "Custom": "自定义"]

    /// A port as the loading script keeps it (461–490).
    struct LANPort {
        let label: String
        let status: OrderedJSON?
        let speed: String
        let maxRate: String
        /// ui_display when it is set and not empty, otherwise "" (475–479).
        let name: String
        let detail: OrderedJSON
        var profile: String? = "0"
        var mode = ""
    }

    /// A node's `port` array. Ports go to index (last character of the label) − 1, so labels ending in 0 or in a letter
    /// land on properties such as "-1" or "NaN", which the array's length leaves out and Object.entries lists after the
    /// indices.
    struct Ports {
        private(set) var indexed: [Int: LANPort] = [:]
        private(set) var named: [(String, LANPort)] = []

        /// The property name JavaScript makes of a number (NaN for nil).
        static func key(_ number: Double?) -> String { number.map(javaScriptText) ?? "NaN" }
        static func arrayIndex(_ key: String) -> Int? {
            guard let index = Int(key), index >= 0, index <= 4_294_967_294, String(index) == key else { return nil }
            return index
        }
        subscript(key: String) -> LANPort? {
            get { Self.arrayIndex(key).map { indexed[$0] } ?? named.first { $0.0 == key }?.1 }
            set {
                if let index = Self.arrayIndex(key) { indexed[index] = newValue; return }
                if let at = named.firstIndex(where: { $0.0 == key }) {
                    if let newValue { named[at].1 = newValue } else { named.remove(at: at) }
                } else if let newValue {
                    named.append((key, newValue))
                }
            }
        }
        var length: Int { (indexed.keys.max() ?? -1) + 1 }
        var entries: [(String, LANPort)] { indexed.keys.sorted().map { (String($0), indexed[$0]!) } + named }
        /// findKeyByPortLabel (645–652): the first entry with that label, else null (the page then reads port[null]).
        func key(label: String) -> String { entries.first { $0.1.label == label }?.0 ?? "null" }
    }

    struct Node {
        let mac: String
        let model: OrderedJSON?
        let productID: String?
        let location: OrderedJSON?
        let online: OrderedJSON?
        let capability: OrderedJSON?
        let config: OrderedJSON?
        var ports = Ports()
    }

    struct Profile { let name: String; let vid: String?; let apg: String? }

    let values: [String: String]
    let support: [String: String]
    var nodes: [(String, Node)] = []
    var profiles: [Profile] = []

    // MARK: JavaScript values

    static func text(_ value: OrderedJSON?) -> String? { value?.text }

    /// ToNumber of a JSON value: null 0, booleans 0/1, text as Number(text); objects and arrays NaN (nil).
    static func number(_ value: OrderedJSON?) -> Double? {
        switch value {
        case .string(let text), .number(let text): javaScriptNumber(text)
        case .bool(let on): on ? 1 : 0
        case .null: 0
        default: nil
        }
    }

    /// ToInt32: NaN and infinities are 0, other numbers wrap to 32 bits.
    static func int32(_ number: Double?) -> Int32 {
        guard let number, number.isFinite else { return 0 }
        let whole = number.rounded(.towardZero).truncatingRemainder(dividingBy: 4_294_967_296)
        return Int32(truncatingIfNeeded: Int64(whole))
    }

    /// The members of a JSON object in the order JavaScript enumerates them: array-index names first, ascending, then the
    /// others as written.
    static func enumerationOrder(_ members: [(String, OrderedJSON)]) -> [(String, OrderedJSON)] {
        let indexed = members.compactMap { member in Ports.arrayIndex(member.0).map { ($0, member) } }.sorted { $0.0 < $1.0 }.map(\.1)
        return indexed + members.filter { Ports.arrayIndex($0.0) == nil }
    }

    // MARK: Loading (426–643)

    /// aimesh_get_node_lan_port (js/httpApi.js 2193–2211): the number of entries in capability 27's lan_port.
    static func lanPortCount(_ node: OrderedJSON) -> Int {
        switch node["capability"]?["27"]?["lan_port"] {
        case .array(let entries): entries.count
        case .object(let members): members.count
        default: 0
        }
    }

    /// A capability bit as aimesh_get_node_capability reads it (js/httpApi.js 2076–2091; an empty value counts as 0).
    static func capability(_ node: Node, _ index: String) -> Int32 { int32(number(node.capability?[index] ?? .null)) }

    /// Whether get_VLAN_port_status throws on an answer (170–361): set_cap_support (324–333) gives each member of
    /// port_info[mac] a cap_support, which fails for members that are not objects; the handler then reads
    /// `data.cap_support.WAN` (214) from a JSON copy of the answer (201), in which an array member has lost it; and both go
    /// through the member list with jQuery, which fails for non-empty text, numbers and true, and on an array's numeric keys.
    static func statusThrows(_ answer: OrderedJSON, mac: String) -> Bool {
        guard let portInfo = answer["port_info"], portInfo != .null, let ports = portInfo[mac], ports != .null else { return false }
        switch ports {
        case .object(let members):
            return members.contains { member in
                if case .object = member.1 { false } else { true }
            }
        case .array(let elements): return !elements.isEmpty
        case .string(let text): return !text.isEmpty
        case .number(let text): return javaScriptNumber(text) != 0
        case .bool(let on): return on
        case .null: return false
        }
    }

    /// `ui_display != undefined && ui_display != ""` (476): text that is not empty; a number unless it is 0.
    static func name(_ value: OrderedJSON?) -> String {
        switch value {
        case .string(let text): text
        case .number(let text): javaScriptNumber(text) == 0 ? "" : text
        case .bool(let on): on ? "true" : ""
        default: ""
        }
    }

    /// The rate_map text whose value equals the port's (`item.value == …`), 10 Mbps when none does (466–474).
    static func rate(_ value: OrderedJSON?) -> String {
        rates.first { rate in
            switch value {
            case .string(let text): rate.value == text
            case .number, .bool: javaScriptNumber(rate.value) == number(value)
            default: false
            }
        }?.text ?? rates[0].text
    }

    /// The nodes the table lists (440–499): AiMesh nodes with LAN ports and without capability 4 bit 22 whose port status
    /// answer has node_info, each with the LAN ports ("L" in the label) of port_info[mac].
    mutating func loadNodes(_ mesh: [OrderedJSON], status: [String: OrderedJSON]) throws {
        for entry in mesh {
            guard Self.lanPortCount(entry) > 0, case .string(let mac)? = entry["mac"] else { continue }
            var node = Node(mac: mac, model: entry["model_name"], productID: Self.text(entry["product_id"]), location: entry["alias"],
                            online: entry["online"], capability: entry["capability"], config: entry["config"])
            // A failed request leaves the answer `{}`; the page asks once for node_info and again for port_info.
            let answer = status[mac] ?? .object([])
            if Self.statusThrows(answer, mac: mac) { throw Stop() }
            guard let info = answer["node_info"], info != .null, Self.capability(node, "4") & (1 << 22) == 0 else { continue }
            guard let portInfo = answer["port_info"], portInfo != .null else { throw Stop() }
            for (key, port) in Self.enumerationOrder(portInfo[mac]?.members ?? []) where key.contains("L") {
                let last = key.utf16.last.map { String(decoding: [$0], as: UTF16.self) }
                node.ports[Ports.key(javaScriptNumber(last).map { $0 - 1 })] = LANPort(
                    label: key, status: port["is_on"], speed: Self.rate(port["link_rate"]), maxRate: Self.rate(port["max_rate"]),
                    name: Self.name(port["ui_display"]), detail: port)
            }
            if let at = nodes.firstIndex(where: { $0.0 == mac }) { nodes[at].1 = node } else { nodes.append((mac, node)) }
        }
    }

    /// "apg" + apg_idx + "_…", with "undefined" for a row without the field, as JavaScript joins it.
    static func apgKey(_ apg: String?, _ name: String) -> String { "apg\(apg ?? "undefined")_\(name)" }

    /// The profiles the lists offer (502–544): networks whose VLAN vlan_rl has, by SSID, then the VLAN IDs no network
    /// uses; with each network's apg dut list, to which the listed nodes missing from it are added (386–391).
    mutating func loadProfiles(apgValues: [String: String]) -> [(String, [[String]])] {
        let vlans = RouterRuleRows.rows(values["vlan_rl"] ?? "")
        var dutLists: [(String, [[String]])] = []
        for row in RouterRuleRows.rows(values["sdn_rl"] ?? "") {
            guard let vlan = vlans.last(where: { $0[field: VLANFields.vlanIndex] == row[field: VLANFields.sdnVLAN] }) else { continue }
            let apg = row[field: VLANFields.sdnAPG]
            profiles.append(Profile(name: apgValues[Self.apgKey(apg, "ssid")] ?? "", vid: vlan[field: VLANFields.vlanID], apg: apg))
            var list = apgValues[Self.apgKey(apg, "dut_list")] ?? ""
            for (mac, _) in nodes where !list.contains(mac) { list += "<" + mac + ">>" }
            let key = Self.apgKey(apg, "dut_list")
            if let at = dutLists.firstIndex(where: { $0.0 == key }) { dutLists[at].1 = RouterRuleRows.rows(list) } else { dutLists.append((key, RouterRuleRows.rows(list))) }
        }
        for vlan in vlans where !profiles.contains(where: { $0.vid == vlan[field: VLANFields.vlanID] }) {
            profiles.append(Profile(name: vlan[field: VLANFields.vlanID] ?? "undefined", vid: vlan[field: VLANFields.vlanID], apg: ""))
        }
        return dutLists
    }

    /// The ports the apg dut lists bind (546–602): each port a list names takes the network's VLAN ID as its profile, and
    /// every port of every list is then set to Access. Ports are numbers (old firmware) or labels.
    mutating func applyDutLists(_ dutLists: [(String, [[String]])]) throws {
        let sdn = RouterRuleRows.rows(values["sdn_rl"] ?? "")
        let vlans = RouterRuleRows.rows(values["vlan_rl"] ?? "")
        for (key, dutList) in dutLists {
            let apg = String(key.dropFirst(3).dropLast("_dut_list".count))
            // `sdn.vlan_idx != 0` holds for a row without the field; vlanId and vlanIdx start as "".
            var vlanIndex: String? = ""
            if let row = sdn.first(where: { $0[field: VLANFields.sdnAPG] == apg && !javaScriptLooselyEquals($0[field: VLANFields.sdnVLAN], 0) }) {
                vlanIndex = row[field: VLANFields.sdnVLAN]
            }
            var vid: String? = ""
            if let vlan = vlans.first(where: { $0[field: VLANFields.vlanIndex] == vlanIndex }) { vid = vlan[field: VLANFields.vlanID] }
            for entry in dutList {
                guard let lanport = entry[field: 2] else { throw Stop() }
                guard !lanport.isEmpty else { continue }
                for port in lanport.components(separatedBy: ",") { try setPort(mac: entry[field: 0], port: port) { $0.profile = vid } }
            }
            for (_, list) in dutLists {
                for entry in list {
                    guard let lanport = entry[field: 2] else { throw Stop() }
                    for port in lanport.components(separatedBy: ",") where !port.isEmpty { try setPort(mac: entry[field: 0], port: port) { $0.mode = "Access" } }
                }
            }
        }
    }

    /// One port a dut list names: by label when it is not a number, otherwise port[parseInt − 1]. A node the table does
    /// not list, or one without ports, is passed over; a port that is not there throws.
    private mutating func setPort(mac: String?, port: String, _ change: (inout LANPort) -> Void) throws {
        guard let mac, let at = nodes.firstIndex(where: { $0.0 == mac }), nodes[at].1.ports.length > 0 else { return }
        let key = javaScriptNumber(port) == nil ? nodes[at].1.ports.key(label: port) : Ports.key(javaScriptInteger(port).map { Double($0) - 1 })
        guard var lanPort = nodes[at].1.ports[key] else { throw Stop() }
        change(&lanPort)
        nodes[at].1.ports[key] = lanPort
    }

    /// vlan_trunklist (608–643): "<mac>port#vids>…" puts those ports in Trunk mode with the VLAN IDs as their profile. A
    /// node the table does not list throws; a port the node does not have is passed over.
    mutating func applyTrunkList() throws {
        let entries = (values["vlan_trunklist"] ?? "").components(separatedBy: "<")
        guard entries.count > 1 else { return }
        for entry in entries.dropFirst() {
            let fields = entry.components(separatedBy: ">")
            for field in fields.dropFirst() {
                let parts = field.components(separatedBy: "#")
                guard let at = nodes.firstIndex(where: { $0.0 == fields[0] }) else { throw Stop() }
                let ports = nodes[at].1.ports
                let number = javaScriptInteger(parts[0])
                let key = number == nil ? ports.key(label: parts[0]) : Ports.key(number.map { Double($0) - 1 })
                guard var port = ports[key] else { continue }
                port.mode = "Trunk"
                port.profile = parts[field: 1]
                nodes[at].1.ports[key] = port
            }
        }
    }

    // MARK: Drawing (700–1389)

    /// manage_get_lacp (1819–1837) with the test of 904–905: LACP on the first node by lacp_enabled, on any node by
    /// capability 5 bit 0 with config.link_aggregation.lacp_enabled == 1.
    func usesLACP(_ node: Node, first: Bool) -> Bool {
        if first, javaScriptLooselyEquals(values["lacp_enabled"], 1) { return true }
        let enabled = Self.text(node.config?["link_aggregation"]?["lacp_enabled"]).flatMap { javaScriptInteger($0) } ?? 0
        return Self.capability(node, "5") & 1 != 0 && enabled == 1
    }

    /// get_bonding_ports (state.js 757–783): a model's LACP ports when the router supports LACP.
    func bondingPorts(_ productID: String?) -> [String] {
        guard !["", "0"].contains(support["lacp"] ?? "") else { return [] }
        let based = values["productid"] ?? ""
        switch productID {
        case "GT-AC5300", "RT-AC86U", "GT-AC2900": return ["4", "3"]
        case "XT8PRO", "BT12", "BM68": return ["2", "3"]
        case "BT10": return ["1", "2"]
        case "BQ16", "BQ16_PRO": return ["3", "4"]
        default:
            if ["GT-BE98", "GT-BE98_PRO", "GT-BE96"].contains(productID ?? "") || ["GT-BE19000", "GT-BE19000AI", "GT-BE96_AI"].contains(based) {
                return values["lacp_ifnames_x"] == "eth0 eth3" ? ["0", "6"] : ["5", "6"]
            }
            return ["1", "2"]
        }
    }

    /// Whether get_bonding_ports takes its GT-BE branch, which reads lacp_ifnames_x.
    static func readsLACPInterfaces(mesh: [OrderedJSON], productID: String) -> Bool {
        ["GT-BE19000", "GT-BE19000AI", "GT-BE96_AI"].contains(productID)
            || mesh.contains { ["GT-BE98", "GT-BE98_PRO", "GT-BE96"].contains(text($0["product_id"]) ?? "") }
    }

    /// A bit of the port's `cap` as capability_map names them (173–191), read as `parseInt(cap) & (1 << bit)`.
    static func cap(_ port: OrderedJSON, _ bit: Int) -> Bool {
        guard let cap = text(port["cap"]).flatMap({ javaScriptInteger($0) }) else { return false }
        return Int32(truncatingIfNeeded: cap) & Int32(truncatingIfNeeded: 1 << bit) > 0
    }

    /// `ext_port_id != -1` is false only for -1 itself, as a number or numeric text.
    static func isMinusOne(_ value: OrderedJSON?) -> Bool {
        switch value {
        case .string, .number, .bool, .null: number(value) == -1
        default: false
        }
    }

    /// `connected_flag == "0"` (1207).
    static func isZeroText(_ value: OrderedJSON?) -> Bool {
        switch value {
        case .string(let text): text == "0"
        case .number, .bool: number(value) == 0
        default: false
        }
    }

    /// The ports a note names, as the page collects them: their numbers, and separately the names of those that have one
    /// (the note pairs them by position, so a port without a name can take the next one's).
    struct Collected {
        var numbers: [String] = []
        var names: [String] = []
        mutating func add(_ number: String, _ name: String) { numbers.append(number); if !name.isEmpty { names.append(name) } }
        var html: String {
            numbers.indices.map { "<b>" + (names.indices.contains($0) ? names[$0] : "LAN " + numbers[$0]) + "</b>" }.joined(separator: " / ")
        }
    }

    func table() -> VLANPortTable {
        let dualWANLAN = (values["wans_dualwan"] ?? "").contains("lan")
        let lanport = values["wans_lanport"] ?? ""
        let stb = javaScriptNumber(values["switch_stb_x"])
        let iptvLists = ["iptv_stb_port", "iptv_voip_port", "iptv_bridge_port"].map { values[$0] ?? "" }
        return VLANPortTable(nodes: nodes.enumerated().map { position, entry in
            let (mac, node) = entry
            let first = position == 0
            var wanAggregation = Collected(), linkAggregation = Collected(), iptv = Collected(), wan = Collected(), externalSwitch = Collected()
            var wanlanTag: Double? = 0
            var ports: [VLANPortTable.Port] = []
            let lacp = usesLACP(node, first: first)
            let bonding = lacp ? bondingPorts(node.productID) : []
            for (key, port) in node.ports.entries where node.ports.length > 0 {
                let number = port.label.replacingOccurrences(of: "L", with: "", options: [], range: port.label.range(of: "L"))
                var tag = 0, aggregation = false
                if first, dualWANLAN, lanport == number { tag = 1; aggregation = true }
                let bonded = first && key == "3" && javaScriptLooselyEquals(values["bond_wan"], 1)
                let lacpPort = bonding.contains(number)
                // `indexOf(port) > 0`: a list starting with the port's number does not count (913–917).
                let iptvPort = first && stb != 0 && iptvLists.contains { list in
                    list.range(of: number).map { list.utf16.distance(from: list.startIndex, to: $0.lowerBound) > 0 } ?? false
                }
                if bonded || lacpPort || iptvPort {
                    tag = 1; aggregation = true
                    if bonded { wanAggregation.add(number, port.name) }
                    if lacpPort { linkAggregation.add(number, port.name) }
                    if iptvPort { iptv.add(number, port.name) }
                }
                if Self.cap(port.detail, 0) { tag = 2; wan.add(number, port.name) }
                if Self.cap(port.detail, 1), Self.cap(port.detail, 9), !Self.isMinusOne(port.detail["ext_port_id"]) {
                    tag = 3; externalSwitch.add(number, port.name)
                }
                if Self.cap(port.detail, 29) || Self.cap(port.detail, 30) {
                    wanlanTag = javaScriptInteger(key).map { Double($0) + 1 }
                    tag = 4; wan.add(number, port.name)
                }
                let link: VLANPortTable.Link = switch port.status {
                case .string("0"): .unplugged
                case .string("1"): .connected
                case .string("2"): .warning
                default: .unknown
                }
                // The number and the text under the icon go into the page as HTML (877, 858).
                ports.append(VLANPortTable.Port(
                    id: key, link: link, number: port.name.isEmpty ? HTMLText.visible(number) : "",
                    caption: link == .unknown ? nil : HTMLText.visible(port.name.isEmpty ? port.maxRate : port.name),
                    speed: link == .connected || link == .warning ? port.speed : nil, aggregation: aggregation,
                    mode: tag != 0 ? .locked("全部(默认值)") : .shown(Self.modeTitle(port.mode)),
                    profile: tag != 0 ? .locked("默认值") : profileSelection(port)))
            }
            let notes = notesFor(first: first, lacp: lacp, wanAggregation: wanAggregation, linkAggregation: linkAggregation, iptv: iptv,
                                 wan: wan, externalSwitch: externalSwitch, wanlanTag: wanlanTag, dualWANLAN: dualWANLAN, lanport: lanport)
            let location = Self.text(node.location) ?? "undefined"
            // The header cell's list items are HTML too (785).
            return VLANPortTable.Node(
                id: mac, title: first ? "AiMesh 路由器" : "AiMesh 节点", model: HTMLText.visible(Self.text(node.model) ?? "undefined"), mac: HTMLText.visible(mac),
                location: HTMLText.visible(Self.locations[location] ?? location), rows: stride(from: 0, to: ports.count, by: 4).map { Array(ports[$0..<min($0 + 4, ports.count)]) },
                waiting: node.ports.length > 0 ? nil : (Self.isZeroText(node.online) ? .disconnected : .loading), notes: notes)
        })
    }

    /// insert_vlan_mode_selector (1391–1443): the option the port's mode selects; the first, 全部(默认值), when none does.
    static func modeTitle(_ mode: String) -> String { ["Access": "Access", "Trunk": "Trunk"][mode] ?? "全部(默认值)" }

    /// insert_vlan_profile_selector (1519–1611), by the mode list's value: 默认值, disabled (全部); the networks' profiles
    /// (Access); Allow all tagging and every profile (Trunk). Of several options marked selected the last shows, of none
    /// the first.
    func profileSelection(_ port: LANPort) -> VLANPortTable.Selection {
        func shown(_ options: [(title: String, selected: Bool)]) -> VLANPortTable.Selection {
            .shown((options.last { $0.selected } ?? options.first)?.title)
        }
        switch port.mode {
        case "Access":
            return shown(profiles.filter { $0.apg != "" }.map { ($0.name, $0.vid == port.profile) })
        case "Trunk":
            return shown([("Allow all tagging(默认值)", false)] + profiles.map { ($0.apg != "" ? $0.name : "(\($0.vid ?? "undefined"))", $0.vid == port.profile) })
        default:
            return .locked("默认值")
        }
    }

    /// The notes under a node's table (1224–1382), built as the page builds their HTML, mistakes included: the WAN
    /// aggregation note's loop names its ports through `a`, still undefined there, so it writes only "</b>" for each port
    /// and leaves "<b>LAN undefined" at the start of the LACP note (1258–1284).
    func notesFor(first: Bool, lacp: Bool, wanAggregation: Collected, linkAggregation: Collected, iptv: Collected, wan: Collected,
                  externalSwitch: Collected, wanlanTag: Double?, dualWANLAN: Bool, lanport: String) -> [VLANPortTable.Note] {
        func used(_ name: String) -> String { "此端口正在由 \(name) 使用。" }
        func modify(_ id: String) -> String { " <a id=\"\(id)\">点击这里</a>进行修改。" }
        var notes: [VLANPortTable.Note] = []
        let tag = wanlanTag.flatMap { $0 != 0 ? $0 : nil }
        if first, (dualWANLAN && !lanport.isEmpty) || tag != nil {
            var html = "<b>LAN "
            if dualWANLAN, !lanport.isEmpty {
                html += lanport
                if let tag, javaScriptNumber(lanport) != tag { html += ", " + Ports.key(tag) }
            } else if let tag {
                html += Ports.key(tag)
            }
            notes.append(.init(html: html + "</b>: 由于硬件限制，此端口目前无法使用 VLAN 功能。" + modify("modify_wans"), destination: .dualWAN))
        }
        var lacpPrefix = ""
        if first, javaScriptLooselyEquals(values["bond_wan"], 1), !wanAggregation.numbers.isEmpty {
            let html = wanAggregation.numbers.indices.map { $0 > 0 ? " / </b>" : "</b>" }.joined() + ": " + used("WAN 聚合") + modify("modify_wan_bonding")
            lacpPrefix = String(repeating: "<b>LAN undefined", count: wanAggregation.numbers.count)
            notes.append(.init(html: html, destination: .wan))
        }
        if lacp, !linkAggregation.numbers.isEmpty {
            notes.append(.init(html: lacpPrefix + linkAggregation.html + ": " + used("绑定/链路聚合"), destination: nil))
        }
        if first, !iptv.numbers.isEmpty {
            notes.append(.init(html: iptv.html + ": " + used("网络电视 (IPTV)") + modify("modify_iptv"), destination: .iptv))
        }
        if !wan.numbers.isEmpty { notes.append(.init(html: wan.html + ": " + used(first ? "以太网 WAN" : "Ethernet Backhaul"), destination: nil)) }
        if !externalSwitch.numbers.isEmpty { notes.append(.init(html: externalSwitch.html + ": " + used("external switch port"), destination: nil)) }
        return notes
    }
}

extension VLANPortTable {
    /// The table from the router's answers: `mesh` is get_cfg_clientlist, `status` the get_port_status.cgi answers by
    /// node MAC (none for a failed request, which the page's error handler leaves as `{}`), `apgValues` the SSIDs and dut
    /// lists of the networks whose VLAN vlan_rl has.
    init(values: [String: String], support: [String: String], mesh: [OrderedJSON], status: [String: OrderedJSON], apgValues: [String: String]) {
        var builder = VLANPortBuilder(values: values, support: support)
        do {
            try builder.loadNodes(mesh, status: status)
            let dutLists = builder.loadProfiles(apgValues: apgValues)
            try builder.applyDutLists(dutLists)
            try builder.applyTrunkList()
        } catch {}
        self = builder.table()
    }

    /// The apg variables the profile lists read (512–523): SSID and dut list of each network whose VLAN vlan_rl has.
    static func apgKeys(values: [String: String]) -> [String] {
        let vlans = RouterRuleRows.rows(values["vlan_rl"] ?? "")
        return RouterRuleRows.rows(values["sdn_rl"] ?? "")
            .filter { row in vlans.contains { $0[field: VLANFields.vlanIndex] == row[field: VLANFields.sdnVLAN] } }
            .flatMap { row in ["ssid", "dut_list"].map { VLANPortBuilder.apgKey(row[field: VLANFields.sdnAPG], $0) } }
    }
}

// MARK: - Reading

extension RouterClient {
    public func vlanProfileList() async throws -> VLANProfileList {
        let support = try await uiCapabilities()
        var values = try await readSettings(["sdn_rl", "vlan_rl", "vlan_trunklist"])
        let keys = VLANProfileList.namedRows(sdnRL: values["sdn_rl"] ?? "", vlanRL: values["vlan_rl"] ?? "", trunkList: values["vlan_trunklist"] ?? "")
            .map { VLANProfileList.ssidKey(apg: $0.apg) }
        values.merge(try await readSettings(Self.readableKeys(keys))) { _, new in new }
        return VLANProfileList(values: values, support: support)
    }

    public func vlanPortTable() async throws -> VLANPortTable {
        let support = try await uiCapabilities()
        var values = try await readSettings(VLANPortTable.keys)
        // hookGet answers "" for a failed request, and no node is listed then (437, 440).
        let mesh: [OrderedJSON] = if case .array(let nodes)? = try await optionalHook("get_cfg_clientlist") { nodes } else { [] }
        if VLANPortBuilder.readsLACPInterfaces(mesh: mesh, productID: values["productid"] ?? "") {
            values.merge(try await readSettings(["lacp_ifnames_x"])) { _, new in new }
        }
        var status: [String: OrderedJSON] = [:]
        for node in mesh where VLANPortBuilder.lanPortCount(node) > 0 {
            guard case .string(let mac)? = node["mac"], status[mac] == nil,
                  let text = try await optionalDataPage(.portStatus, [("node_mac", mac)]), let answer = try? OrderedJSON(data: Data(text.utf8)) else { continue }
            status[mac] = answer
        }
        let apgValues = try await readSettings(Self.readableKeys(VLANPortTable.apgKeys(values: values)))
        return VLANPortTable(values: values, support: support, mesh: mesh, status: status, apgValues: apgValues)
    }

    /// How many nodes `get_port_status.cgi?node_mac=all` reports (check_get_port_status_update 671–687, which reloads the
    /// page when the number changes); nil when the request fails, which the page ignores.
    public func vlanReportedNodeCount() async -> Int? {
        guard let text = try? await readDataPage(.portStatus, [("node_mac", "all")]), let answer = try? OrderedJSON(data: Data(text.utf8)) else { return nil }
        // `for (var node in response.node_info)`: an object's members, an array's or a text's indices, nothing else.
        switch answer["node_info"] {
        case .object(let members): return members.count
        case .array(let elements): return elements.count
        case .string(let text): return text.utf16.count
        default: return 0
        }
    }

    /// One appGet.cgi hook without arguments, with the members in the order the router wrote them.
    func orderedHook(_ name: String) async throws -> OrderedJSON? {
        try OrderedJSON(data: try await request("appGet.cgi", query: [.init(name: "hook", value: "\(name)()")]))[name]
    }

    /// Reads whose failure the page takes as an empty answer (hookGet answers "", an ajax error leaves `{}`). A cancelled
    /// read still ends in CancellationError, so a page that was left does not show a partial reading, and an expired
    /// login still ends the read, so the app can sign in again.
    func optionalHook(_ name: String) async throws -> OrderedJSON? {
        try await orEmpty { try await orderedHook(name) }
    }
    func optionalAnyHook(_ name: String) async throws -> Any? {
        do { return try await hook(name) }
        catch RouterError.authenticationRequired { throw RouterError.authenticationRequired }
        catch is CancellationError { throw CancellationError() }
        catch { return nil }
    }
    func optionalDataPage(_ page: RouterDataPage, _ query: [(String, String)]) async throws -> String? {
        try await orEmpty { try await readDataPage(page, query) }
    }
    private func orEmpty<Value: Sendable>(_ read: () async throws -> Value?) async throws -> Value? {
        do { return try await read() }
        catch RouterError.authenticationRequired { throw RouterError.authenticationRequired }
        catch is CancellationError { throw CancellationError() }
        catch { return nil }
    }

    /// Variable names readSettings accepts; others (from odd list fields) are left out and read as "", the way the
    /// router answers names it does not have.
    static func readableKeys(_ keys: [String]) -> [String] {
        keys.filter { $0.range(of: #"^[A-Za-z][A-Za-z0-9_.]{0,79}$"#, options: .regularExpression) != nil }
    }
}
