import Foundation

// MARK: - Open NAT

/// One record of gameProfile.profile (js/gameProfile.js, or the online gameProfile.json / opennat_pf.json): a game on one
/// platform with the ports to forward. Values are kept as the page reads them, as text.
public struct GameProfile: Sendable, Equatable {
    public let title: String
    public let port: String
    public let `protocol`: String
    public let platform: String
    public let style: String
    public var id: String

    init(_ record: OrderedJSON) {
        func text(_ name: String) -> String { record[name].map(TORSettings.javaScriptString) ?? "undefined" }
        title = text("title"); port = text("port"); `protocol` = text("protocol"); platform = text("platform"); style = text("class"); id = text("id")
    }
    public init(title: String, port: String, protocol: String, platform: String, style: String, id: String) {
        self.title = title; self.port = port; self.protocol = `protocol`; self.platform = platform; self.style = style; self.id = id
    }

    /// js/gameProfile.js: `var gameProfile = {"profile":[…,]}`, an object literal whose last record is followed by a comma.
    public static func builtIn(_ script: String) -> [GameProfile]? {
        guard let open = script.firstIndex(of: "{"), let close = script.lastIndex(of: "}") else { return nil }
        let literal = String(script[open...close]).replacingOccurrences(of: #",(\s*[\]}])"#, with: "$1", options: .regularExpression)
        guard let object = try? OrderedJSON(data: Data(literal.utf8)), case .array(let records)? = object["profile"] else { return nil }
        return records.map(GameProfile.init)
    }
    /// The online lists: `Object.keys(response).map(e => response[e])` (updatProfileOnline 141–156); opennat_pf.json is
    /// first unwrapped from `updatePfList(…)` (searchOpenNatProfile.js 3–8).
    public static func online(_ data: Data, unwrapping: Bool = false) -> [GameProfile]? {
        var text = String(decoding: data, as: UTF8.self)
        if unwrapping, let range = text.range(of: #"^updatePfList\((.*)\)$"#, options: .regularExpression) {
            text = String(text[range].dropFirst("updatePfList(".count).dropLast())
        }
        switch try? OrderedJSON(data: Data(text.utf8)) {
        case .array(let records)?: return records.map(GameProfile.init)
        case .object(let members)?:
            // Object.keys order: index-like keys first. A repeated key keeps its first place and its last value.
            var last: [String: OrderedJSON] = [:]
            for (key, value) in members { last[key] = value }
            return JavaScriptKeys.ordered(members.map(\.0).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }).compactMap { last[$0].map(GameProfile.init) }
        default: return nil
        }
    }
    public static let onlineCatalog = URL(string: "https://nw-dlcdnet.asus.com/plugin/js/gameProfile.json")!
    public static let searchCatalog = URL(string: "https://nw-dlcdnet.asus.com/plugin/js/opennat_pf.json")!
}

/// 游戏加速 › Open NAT (GameProfile.asp): the game port-forwarding rules (game_vts_rulelist), the switch for port forwarding
/// as a whole (vts_enable_x) and the profiles new rules are made from.
public struct OpenNATPage: Sendable, Equatable {
    static let keys = ["game_vts_rulelist", "vts_enable_x", "wan0_proto", "productid", "preferred_lang", "firmver"]
    public let values: [String: String]
    /// gameProfile.profile as the router's js/gameProfile.js gives it.
    public let builtIn: [GameProfile]
    public let clients: [TORSettings.ClientEntry]

    public init(values: [String: String], builtIn: [GameProfile], clients: [TORSettings.ClientEntry]) {
        self.values = values; self.builtIn = builtIn; self.clients = clients
    }

    public var portForwarding: Bool { values["vts_enable_x"] == "1" }
    /// vts_rulelist_array (30): the stored list with &#62 turned back into ">". The legacy Rocket League block (36–80) builds
    /// a corrected copy it never uses.
    public var stored: String { (values["game_vts_rulelist"] ?? "").replacingOccurrences(of: "&#62", with: ">") }
    /// With v6plus, ocnvc or v6opt initial() reads s46_ports_check_flag, which no script defines: it throws before the
    /// switch and the rules are drawn, and 确认 throws at the same check.
    public var softwireStops: Bool { ["v6plus", "ocnvc", "v6opt"].contains(values["wan0_proto"] ?? "") }

    /// One game of gameList (collectGameList 120–131): the title and class of the first record with its id.
    public struct Game: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let style: String
    }
    /// gameList for these profiles, adding to an earlier one: ids it has keep their title, new ids follow in Object.keys
    /// order (index-like ids first).
    public static func games(_ profiles: [GameProfile], adding earlier: [Game] = []) -> [Game] {
        var games = Dictionary(earlier.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var order = earlier.map(\.id)
        for profile in profiles where games[profile.id] == nil {
            games[profile.id] = Game(id: profile.id, title: profile.title, style: profile.style); order.append(profile.id)
        }
        return JavaScriptKeys.ordered(order).compactMap { games[$0] }
    }

    /// One row of the list (genListTable 202–300).
    public struct Rule: Sendable, Equatable, Identifiable {
        /// The row's index in the list split at "<" (1 for the first rule), which 删除 removes.
        public let id: Int
        public let name: String
        /// _platformObj[_platform]: nil when no platform was found; "undefined" for one the table does not know.
        public let platform: String?
        public let port: String
        public let fullPort: String
        public let device: String
        public let ip: String
        public let `protocol`: String
        public let internalPort: String
    }
    static let platformNames = ["PC": "PC", "XBOXSerX": "XBOX Series X", "XBOXONE": "XBOX ONE", "XBOX360": "XBOX 360", "PS5": "PS5",
                                "PS4": "PS4", "PS3": "PS3", "STEAM": "STEAM", "SWITCH": "SWITCH"]

    /// The rows of a list, or nil where the page's loop throws (a rule without an external port has no length to read),
    /// which leaves the table as it was.
    public static func rules(_ list: String, profiles: [GameProfile], clients: [TORSettings.ClientEntry]) -> [Rule]? {
        var rows: [Rule] = []
        for (index, row) in list.components(separatedBy: "<").enumerated().dropFirst() {
            let columns = row.components(separatedBy: ">")
            func column(_ at: Int) -> String? { at < columns.count ? columns[at] : nil }
            let name = columns[0]
            var platform = ""
            for target in profiles where target.port == column(1) {
                let parts = name.components(separatedBy: "@")
                if parts.count < 2 {
                    if target.title == name || name.contains(target.title) { platform = target.platform }
                } else {
                    platform = parts[1]
                }
            }
            guard let port = column(1) else { return nil }
            let units = Array(port.utf16)
            let shown = units.count > 18 ? String(decoding: units.prefix(14), as: UTF16.self) + "..." : port
            let ip = column(2) ?? "undefined"
            let device = clients.last { $0.ip == ip }?.name ?? ""
            rows.append(Rule(id: index, name: HTMLText.visible(name, inside: ["div"]),
                             platform: platform.isEmpty ? nil : platformNames[platform] ?? "undefined",
                             port: HTMLText.visible(shown, inside: ["div"]), fullPort: port, device: HTMLText.visible(device, inside: ["div"]),
                             ip: HTMLText.visible(ip, inside: ["div"]), protocol: HTMLText.visible(column(4) ?? "undefined", inside: ["div"]),
                             internalPort: HTMLText.visible(column(3) ?? "undefined", inside: ["div"])))
        }
        return rows
    }

    /// deleteRule (302–313): the rows after the first "<" except the one removed; text before the first "<" goes too.
    public static func deleting(_ index: Int, from list: String) -> String {
        list.components(separatedBy: "<").enumerated().dropFirst().filter { $0.offset != index }.map { "<" + $0.element }.joined()
    }

    /// What 确认 (newProfileOK 563–658) is given: the selected game ("default_game" for Manual), the checked platforms and
    /// the fields as typed.
    public struct NewRule: Sendable, Equatable {
        public var game = "default_game"
        public var platforms: Set<String> = []
        public var name = ""
        public var `protocol` = "TCP"
        public var externalPort = ""
        public var internalPort = ""
        public var localIP = ""
        public var sourceIP = ""
        public init() {}
        public var manual: Bool { game == "default_game" }
    }
    public enum AddStop: Error, Equatable {
        case alert(String)
        /// validIPForm's alert, after which the page clears the local IP field.
        case invalidIP(String)
        /// The Softwire check throws (see softwireStops): nothing happens.
        case stopped
    }
    static let platforms = ["PC", "XBOXSerX", "XBOXONE", "XBOX360", "PS5", "PS4", "PS3", "STEAM", "SWITCH"]

    /// The list with the new rule added, or why not; the rule as the page writes it (internal port and local IP as the
    /// checks rewrote them).
    public func adding(_ rule: NewRule, to list: String, profiles: [GameProfile]) -> Result<(list: String, rule: NewRule), AddStop> {
        var rule = rule
        if !rule.manual, !Self.platforms.contains(where: rule.platforms.contains) { return .failure(.alert("Please select at least one platform.")) }
        if let alert = WebValidator.blockChars(rule.name, ["<", ">", "%"]) ?? WebValidator.blockChars(rule.externalPort, ["<", ">"])
            ?? WebValidator.blockChars(rule.internalPort, ["<", ">"]) { return .failure(.alert(alert)) }
        if rule.manual {
            if rule.externalPort == "OTHER" {
                rule.internalPort = ""
                if let alert = WebValidator.numberRange(&rule.externalPort, 1, 255) { return .failure(.alert(alert)) }
            } else {
                if let alert = Self.checkMultiRange(rule.externalPort) { return .failure(.alert(alert)) }
                if softwireStops { return .failure(.stopped) }
            }
        }
        if !rule.internalPort.isEmpty, let alert = WebValidator.numberRange(&rule.internalPort, 1, 65535) { return .failure(.alert(alert)) }
        if rule.localIP.isEmpty { return .failure(.alert("栏位不能为空白")) }
        if let alert = WebValidator.ipAddrFinal(&rule.localIP) { return .failure(.invalidIP(alert)) }
        var list = list
        if rule.manual {
            list += "<" + rule.name + ">" + rule.externalPort + ">" + rule.localIP + ">" + rule.internalPort + ">" + rule.protocol + ">" + rule.sourceIP
        } else {
            for target in profiles where target.id == rule.game && rule.platforms.contains(target.platform) {
                list += "<" + rule.name + "@" + target.platform + ">" + target.port + ">" + rule.localIP + ">>" + target.protocol + ">"
            }
        }
        return .success((list, rule))
    }

    /// check_multi_range(obj, 1, 65535, true) (381–404): "-" and "~" read as ":", the text split at "," and ":", each part
    /// trimmed and stripped of leading zeros, then validate_single_range (validate_multi_range never sees a ":" left).
    static func checkMultiRange(_ text: String) -> String? {
        let parts = text.replacingOccurrences(of: "-", with: ":").replacingOccurrences(of: "~", with: ":")
            .components(separatedBy: CharacterSet(charactersIn: ",:"))
        for part in parts {
            var value = javaScriptTrim(part)
            value = String(String.UnicodeScalarView(value.unicodeScalars.drop { $0 == "0" }))
            if value.isEmpty || javaScriptNumber(value) == 0 { return "本地 IP 或通信端口范围字段不得空白！" }
            // validate_single_range (366–379): every character a digit, then the number in range.
            let range = "请输入一数值介于 1 至 65535"
            guard value.utf16.allSatisfy({ (0x30...0x39).contains($0) }), let number = Double(value), number >= 1, number <= 65535 else { return range }
        }
        return nil
    }
}

extension WebValidator {
    /// Block_chars (state.js 1542–1568): characters outside ASCII 32–126 first, then any of the keywords.
    static func blockChars(_ text: String, _ keywords: [String]) -> String? {
        let invalid = String(decoding: text.utf16.filter { $0 < 32 || $0 > 126 }, as: UTF16.self)
        if !invalid.isEmpty { return "本字符串无法包含：\" " + invalid + "\" !" }
        if !text.isEmpty, keywords.contains(where: text.contains) { return keywords.joined(separator: ",") + " 是无效字符。" }
        return nil
    }
    /// blockChars for a password: the same checks, but the characters the page would list (part of the password) are not
    /// shown; the alert states the rule instead.
    static func blockSecretChars(_ text: String, _ keywords: [String]) -> String? {
        if text.utf16.contains(where: { $0 < 32 || $0 > 126 }) {
            return "本字符串无法包含：英文半角可打印字符（空格至 ~）以外的字符。为保护密码，这里不显示具体字符。"
        }
        return blockChars(text, keywords)
    }

    /// validator.ipAddrFinal (1046–1276) for a field without one of the names it treats specially (validIPForm(obj, 0)
    /// with an empty value passes): digits and dots, four parts of at most 255; a bad value is cleared, a good one written
    /// back as its four numbers (1228), so leading zeros go.
    static func ipAddrFinal(_ value: inout String) -> String? {
        if value.isEmpty { return nil }
        var number = -1, parts: [Int] = []
        func bad() -> String { let alert = value + " 不是有效的 IP 地址！"; value = ""; return alert }
        for unit in value.utf16 {
            if (0x30...0x39).contains(unit) {
                number = number == -1 ? Int(unit - 0x30) : min(number, 1_000) * 10 + Int(unit - 0x30)
            } else {
                if number < 0 || number > 255 || unit != 0x2E { return bad() }
                parts.append(number); number = -1
            }
        }
        if parts.count != 3 || number < 0 || number > 255 { return bad() }
        value = (parts + [number]).map(String.init).joined(separator: ".")
        return nil
    }
}

extension RouterClient {
    public func openNATPage() async throws -> OpenNATPage {
        let values = try await readSettings(OpenNATPage.keys + ["lan_hwaddr", "productid"])
        let support = try await uiCapabilities()
        let builtIn = GameProfile.builtIn(try await readManagementDocument("js/gameProfile.js")) ?? []
        let clients = TORSettings.clientList(current: try await optionalHook("get_clientlist"), history: try await optionalHook("get_clientlist_from_json_database"),
                                             lanMAC: values["lan_hwaddr"] ?? "", productID: values["productid"] ?? "",
                                             amas: !["", "0"].contains(support["amas"] ?? ""))
        return OpenNATPage(values: values, builtIn: builtIn, clients: clients)
    }

    /// switchPortForward (426–437): httpApi.nvramSet with restart_firewall, then five seconds; read back.
    public func setPortForwarding(_ on: Bool) async throws -> ApplyReceipt {
        try acquireMutation(); defer { releaseMutation() }
        let value = on ? "1" : "0"
        try await submitApply(ordered: [("vts_enable_x", value), ("action_mode", "apply"), ("action_wait", "5"), ("rc_service", "restart_firewall")])
        try await Task.sleep(for: .seconds(5))
        let saved = try await readSettings(["vts_enable_x"])["vts_enable_x"] == value
        return ApplyReceipt(verified: saved ? ["vts_enable_x"] : [], unverified: saved ? [] : ["vts_enable_x"],
                            message: saved ? "已从路由器重新读取，端口转发已" + (on ? "开启。" : "关闭。") : "路由器已响应，但读回的端口转发开关与提交的不一致。请重新读取并检查。")
    }

    /// applyRule (315–319): the form `form` (672–683) to start_apply.htm with restart_firewall; read back after five seconds.
    public func saveOpenNATRules(_ list: String, page: OpenNATPage) async throws -> ApplyReceipt {
        try acquireMutation(); defer { releaseMutation() }
        let fields = [("productid", page.values["productid"] ?? ""), ("current_page", "GameProfile.asp"), ("next_page", "GameProfile.asp"),
                      ("modified", "0"), ("action_wait", "5"), ("action_mode", "apply"), ("action_script", "restart_firewall"), ("first_time", ""),
                      ("preferred_lang", page.values["preferred_lang"] ?? ""), ("firmver", page.values["firmver"] ?? ""), ("game_vts_rulelist", list)]
        _ = try await request("start_apply.htm", method: "POST", body: RouterAuthentication.orderedForm(fields, .formSubmission),
                              contentType: "application/x-www-form-urlencoded", timeout: 60)
        try await Task.sleep(for: .seconds(5))
        let after = (try await readSettings(["game_vts_rulelist"])["game_vts_rulelist"] ?? "")
            .replacingOccurrences(of: "&#62", with: ">").replacingOccurrences(of: "&#60", with: "<")
        let saved = after == list
        return ApplyReceipt(verified: saved ? ["game_vts_rulelist"] : [], unverified: saved ? [] : ["game_vts_rulelist"],
                            message: saved ? "已从路由器重新读取，游戏规则已保存。" : "路由器已响应，但读回的规则与提交的不一致。请重新读取并检查。")
    }
}
