import Foundation

// VPN › TOR（Advanced_TOR_Content.asp）与 带宽管理 QoS › 用户自定义优先级（Advanced_QOSUserPrio_Content.asp）（1.11）：
// 按 Asuswrt-Merlin tag 3006.102.5 打开时显示的内容。只读：只发 GET。

/// A number as JavaScript writes it (Number::toString): the shortest digits that read back as the number, in plain
/// notation from 1e-6 up to 1e21 and in exponent notation outside it; NaN and Infinity by name, −0 as 0.
func javaScriptText(_ number: Double) -> String {
    if number.isNaN { return "NaN" }
    if number == 0 { return "0" }
    if number.isInfinite { return number < 0 ? "-Infinity" : "Infinity" }
    if number < 0 { return "-" + javaScriptText(-number) }
    // Swift's description gives the same shortest digits, as "9.77", "100.0", "1e-07" or "9.765625e+18".
    let description = "\(number)"
    var mantissa = Substring(description), exponent = 0
    if let mark = description.firstIndex(where: { $0 == "e" || $0 == "E" }) {
        mantissa = description[..<mark]
        exponent = Int(description[description.index(after: mark)...]) ?? 0
    }
    let parts = mantissa.split(separator: ".", omittingEmptySubsequences: false)
    var digits = String(parts[0]) + (parts.count > 1 ? String(parts[1]) : "")
    var point = parts[0].count + exponent
    while digits.count > 1, digits.hasPrefix("0") { digits.removeFirst(); point -= 1 }
    while digits.count > 1, digits.hasSuffix("0") { digits.removeLast() }
    let count = digits.count
    if count <= point, point <= 21 { return digits + String(repeating: "0", count: point - count) }
    if point > 0, point <= 21 { return digits.prefix(point) + "." + digits.dropFirst(point) }
    if point > -6, point <= 0 { return "0." + String(repeating: "0", count: -point) + digits }
    let power = point - 1
    let suffix = "e" + (power >= 0 ? "+" : "-") + String(abs(power))
    return count == 1 ? digits + suffix : digits.prefix(1) + "." + digits.dropFirst() + suffix
}

/// Math.round: the nearest whole number, halves up. Decided from the fraction, so values just below a half (such as
/// 0.49999999999999994) round down as in JavaScript.
func javaScriptRound(_ number: Double) -> Double {
    guard number.isFinite else { return number }
    let whole = number.rounded(.down)
    return number - whole >= 0.5 ? whole + 1 : whole
}

/// String.prototype.trim: removes JavaScript's white space and line terminators at both ends.
func javaScriptTrim(_ text: String) -> String {
    let scalars = Array(text.unicodeScalars)
    func space(_ scalar: Unicode.Scalar) -> Bool {
        [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0xFEFF, 0x2028, 0x2029].contains(scalar.value) || scalar.properties.generalCategory == .spaceSeparator
    }
    guard let first = scalars.firstIndex(where: { !space($0) }), let last = scalars.lastIndex(where: { !space($0) }) else { return "" }
    return String(String.UnicodeScalarView(scalars[first...last]))
}

// MARK: - TOR

/// VPN › TOR (Advanced_TOR_Content.asp): TOR on or off, its three ports and whose traffic it takes, as initial (40–45),
/// show_tor_settings (259–281) and show_tor_redir_list (47–113) show them.
public struct TORSettings: Sendable, Equatable {
    /// The TOR list: 启用 for "1", 停用 for "0"; another value selects neither option, so the list shows its first,
    /// 启用 (332–335).
    public let enableTitle: String
    /// The rows under TOR show only for "1" (show_tor_settings).
    public let enabled: Bool
    public let socksPort: String
    public let transPort: String
    public let dnsPort: String
    /// Redirect all user from: LAN(br0) for an empty list, otherwise Only Specified MACs, which shows the list (265–272).
    public let specifiedMACs: Bool
    /// The list's entries after each "<" (Tor_redir_list, split as the page splits its escaped "&#60"); nil when there is
    /// no "<", for which the page shows 目前没有数据.
    public let macs: [String]?
    /// The name shown for each listed MAC the client list knows (show_tor_redir_list 64–73), as a browser shows the HTML
    /// the page writes for it.
    public let names: [String: String]

    public init(values: [String: String], names: [String: String] = [:]) {
        let enable = values["Tor_enable"] ?? ""
        enableTitle = enable == "0" ? "停用" : "启用"
        enabled = enable == "1"
        socksPort = values["Tor_socksport"] ?? ""
        transPort = values["Tor_transport"] ?? ""
        dnsPort = values["Tor_dnsport"] ?? ""
        let list = values["Tor_redir_list"] ?? ""
        specifiedMACs = !list.isEmpty
        let parts = list.components(separatedBy: "<")
        macs = parts.count == 1 ? nil : Array(parts.dropFirst())
        self.names = names.mapValues(Self.listText)
    }

    static let keys = ["Tor_enable", "Tor_socksport", "Tor_transport", "Tor_dnsport", "Tor_redir_list", "lan_hwaddr", "productid"]

    /// How the list shows a name or MAC: the page writes each into a <div> of a table cell (show_tor_redir_list 101–103),
    /// so a "</div>" in it ends that line.
    public static func listText(_ html: String) -> String { HTMLText.visible(html, inside: ["td", "div"]) }

    /// `value == "1"` in JavaScript for a JSON value: text compares as text, numbers and booleans as numbers, an array as
    /// the text it turns into, and an object never.
    static func looselyEqualsOne(_ value: OrderedJSON?) -> Bool {
        switch value {
        case .string(let text): text == "1"
        case .number(let text): javaScriptNumber(text) == 1
        case .bool(let on): on
        case .array(let elements): javaScriptString(.array(elements)) == "1"
        default: false
        }
    }

    /// String(value) in JavaScript for a JSON value: an array joins its elements' texts with commas (null as nothing,
    /// nested arrays the same way), an object is "[object Object]", and a number is written as Number::toString writes it.
    static func javaScriptString(_ value: OrderedJSON) -> String {
        switch value {
        case .string(let text): text
        case .number(let text): javaScriptNumber(text).map(javaScriptText) ?? text
        case .bool(let on): on ? "true" : "false"
        case .null: "null"
        case .object: "[object Object]"
        case .array(let elements): elements.map { $0 == .null ? "" : javaScriptString($0) }.joined(separator: ",")
        }
    }

    /// htmlEnDeCode.htmlEncode, which genClientList applies to the names of devices from the history database.
    static func htmlEncode(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }

    /// The page's clientList as client_function.js builds it (originData 245–249, genClientList 389–608), as the HTML
    /// the TOR list writes for each device (nickName when it is not empty, else name): devices from get_clientlist by
    /// upper-case MAC, the first entry winning, a blank name replaced by the MAC (398–445); then devices of the history
    /// database (get_clientlist_from_json_database) until more than a hundred are counted, HTML-encoded (546–595); then the
    /// router itself, named by productid, on AiMesh routers (598–607).
    ///
    /// genClientList stops at the first statement that throws, keeping what it has: a listed MAC without an entry, a MAC
    /// or name that is not text, a history answer without maclist (which also leaves out the router), and a history
    /// device whose vendor is not text (after it is added).
    static func clientNames(current: OrderedJSON?, history: OrderedJSON?, lanMAC: String, productID: String, amas: Bool) -> [String: String] {
        var shown: [String: String] = [:]
        for entry in clientList(current: current, history: history, lanMAC: lanMAC, productID: productID, amas: amas) {
            shown[entry.mac] = entry.nickName.isEmpty ? entry.name : entry.nickName
        }
        return shown
    }

    /// One device of clientList: name and nickName as genClientList keeps them (HTML for history devices), ip (the
    /// router's answer as text; "offline" from setClientAttr for history devices) and isOnline.
    public struct ClientEntry: Sendable, Equatable {
        public let mac: String
        public var name = ""
        public var nickName = ""
        public var ip = "offline"
        public var online = false
        /// `from`: networkmapd's or the database's text (nil for undefined), "manual" for the router itself.
        public var from: String?
        /// amesh_isRe: the entry is an AiMesh node.
        public var meshNode = false
        public init(mac: String, name: String = "", nickName: String = "", ip: String = "offline", online: Bool = false, from: String? = nil, meshNode: Bool = false) {
            self.mac = mac; self.name = name; self.nickName = nickName; self.ip = ip; self.online = online; self.from = from; self.meshNode = meshNode
        }
    }

    /// showDropdownClientList(…, "all") (client_function.js 3826–3949): every client but AiMesh nodes; the online ones, then
    /// (under 显示离线设备) the offline ones the network map database holds (`from == "nmpClient"`), both in list order.
    public static func dropdownClients(_ clients: [ClientEntry]) -> (online: [ClientEntry], offline: [ClientEntry]) {
        let shown = clients.filter { !$0.meshNode }
        return (shown.filter(\.online), shown.filter { !$0.online && $0.from == "nmpClient" })
    }
    /// The name an item shows (genClientItem): the nickName, else the name, cut to 30 characters and ".." past 32.
    public static func dropdownName(_ client: ClientEntry) -> String {
        let name = client.nickName.isEmpty ? client.name : client.nickName
        let units = Array(name.utf16)
        return units.count > 32 ? String(decoding: units.prefix(30), as: UTF16.self) + ".." : name
    }

    /// clientList in genClientList's order (see clientNames).
    static func clientList(current: OrderedJSON?, history: OrderedJSON?, lanMAC: String, productID: String, amas: Bool) -> [ClientEntry] {
        var entries: [ClientEntry] = []
        var index: [String: Int] = [:]
        /// The device each maclist entry names; nil when maclist is missing. A missing device is `undefined`.
        func devices(_ answer: OrderedJSON?) -> [OrderedJSON?]? {
            guard case .array(let macs)? = answer?["maclist"] else { return nil }
            return macs.map { mac in mac.text.flatMap { answer?[$0] } }
        }
        /// `typeof client.mac == "undefined"` passes over the device; reading anything of undefined or null throws, and so
        /// does toUpperCase on a MAC that is not text.
        func mac(_ client: OrderedJSON?) throws -> String? {
            guard let client, client != .null else { throw VLANPortBuilder.Stop() }
            guard let value = client["mac"] else { return nil }
            guard case .string(let mac) = value else { throw VLANPortBuilder.Stop() }
            // `if(!thisClientMacAddr) continue;`: an empty MAC is passed over too.
            return mac.isEmpty ? nil : mac.uppercased()
        }
        func add(_ key: String) -> Int { entries.append(ClientEntry(mac: key)); index[key] = entries.count - 1; return entries.count - 1 }
        do {
            for client in devices(current) ?? [] {
                guard let key = try mac(client), let client else { continue }
                guard index[key] == nil else { continue }
                let at = add(key)
                entries[at].online = looselyEqualsOne(client["isOnline"])
                entries[at].from = client["from"].map(javaScriptString)
                // `.ip = thisClient.ip` comes before the name (436–440).
                entries[at].ip = client["ip"].map(javaScriptString) ?? "undefined"
                guard case .string(let name)? = client["name"] else { throw VLANPortBuilder.Stop() }
                entries[at].name = javaScriptTrim(name).isEmpty ? key : javaScriptTrim(name)
                guard case .string(let nickName)? = client["nickName"] else { throw VLANPortBuilder.Stop() }
                entries[at].nickName = javaScriptTrim(nickName)
                // On AiMesh routers an online AiMesh node counts as offline (494–498).
                if amas, let node = client["amesh_isRe"], node != .null {
                    entries[at].meshNode = looselyEqualsOne(node)
                    if entries[at].meshNode { entries[at].online = false }
                }
            }
            guard let history = devices(history) else { throw VLANPortBuilder.Stop() }
            var counted = 0
            for client in history {
                guard let key = try mac(client), let client else { continue }
                if counted > 100 { break }
                if index[key] == nil {
                    func text(_ field: String, missing: String) throws -> String {
                        guard let value = client[field] else { return missing }
                        guard case .string(let text) = value else { throw VLANPortBuilder.Stop() }
                        return javaScriptTrim(text).isEmpty ? missing : javaScriptTrim(text)
                    }
                    let name = try text("name", missing: key), nickName = try text("nickName", missing: "")
                    let at = add(key)
                    entries[at].name = htmlEncode(name); entries[at].nickName = htmlEncode(nickName)
                    entries[at].from = client["from"].map(javaScriptString)
                    if amas { entries[at].meshNode = looselyEqualsOne(client["amesh_isRe"]) }
                    guard case .string? = client["vendor"] else { throw VLANPortBuilder.Stop() }
                    counted += 1
                } else if let at = index[key], !entries[at].online {
                    entries[at].from = client["from"].map(javaScriptString)
                    counted += 1
                }
            }
            if amas, index[lanMAC] == nil { let at = add(lanMAC); entries[at].name = productID; entries[at].from = "manual" }
        } catch {}
        return entries
    }
}

// MARK: - 用户自定义优先级

/// 带宽管理 QoS › 用户自定义优先级 (Advanced_QOSUserPrio_Content.asp): the five priorities' upload and download limits
/// and the packets sent first, as initial (27–42) fills the page: init_changeScale (44–51) shows a bandwidth above 999
/// Kb/s in Mb/s, gen_options (155–189) first selects each limit from qos_orates / qos_irates and then writes the ranges
/// they give.
public struct QoSUserPriority: Sendable, Equatable {
    public struct Level: Sendable, Equatable {
        /// 最高, 高, 中, 低, 最低.
        public let name: String
        /// The percentages the lists show; nil for a list gen_options did not fill.
        public let uploadMin: String?
        public let uploadMax: String?
        public let downloadMax: String?
        /// 当前带宽设置范围, e.g. "9.77 ~ 19.53 Mb/s"; nil when it was not written.
        public let uploadRange: String?
        public let downloadRange: String?
    }

    public struct Packet: Sendable, Equatable {
        public let name: String
        public let on: Bool
    }

    /// 带宽管理 QoS - 传统带宽管理 on routers with bwdpi, otherwise 流量管理 - QoS (29–34).
    public let title: String
    /// 请先开启的带宽管理后再设定上传与下载速率限制。 shows unless qos_enable is "1" and initial got that far (38–39).
    public let showsEnableHint: Bool
    public let levels: [Level]
    /// ACK, SYN, FIN, RST, ICMP, checked when their variable is "on" (nvram_match).
    public let packets: [Packet]

    static let names = ["最高", "高", "中", "低", "最低"]
    static let keys = ["qos_orates", "qos_irates", "qos_obw", "qos_ibw", "qos_enable", "qos_ack", "qos_syn", "qos_fin", "qos_rst", "qos_icmp"]

    /// init_changeScale: above 999 the bandwidth is shown in Mb/s, as Math.round(value / 1024 × 100) / 100.
    static func scaled(_ value: String) -> (value: String, unit: String) {
        guard let number = javaScriptNumber(value), number > 999 else { return (value, "Kb/s") }
        return (javaScriptText(javaScriptRound(number / 1024 * 100) / 100), "Mb/s")
    }

    /// add_options_value: the option 0…100 equal to the stored value (`orig == i`), the first (0) when none is.
    static func selected(_ value: String?) -> String {
        guard let value, let number = javaScriptNumber(value), number == number.rounded(), (0...100).contains(number) else { return "0" }
        return javaScriptText(number)
    }

    public init(values: [String: String], support: [String: String]) {
        title = ["", "0"].contains(support["bwdpi"] ?? "") ? "流量管理 - QoS" : "带宽管理 QoS - 传统带宽管理"
        let upload = Self.scaled(values["qos_obw"] ?? ""), download = Self.scaled(values["qos_ibw"] ?? "")
        let outRows = (values["qos_orates"] ?? "").components(separatedBy: ",")
        let inRows = (values["qos_irates"] ?? "").components(separatedBy: ",")
        // gen_options throws at the first priority without an entry (`qos_orates_row[j].split`), leaving the lists after
        // it empty, writing no range and ending initial before it hides the hint.
        let filled = min(outRows.count, inRows.count, 5)
        let complete = filled == 5
        levels = Self.names.enumerated().map { j, name in
            guard j < filled else { return Level(name: name, uploadMin: nil, uploadMax: nil, downloadMax: nil, uploadRange: nil, downloadRange: nil) }
            let out = outRows[j].components(separatedBy: "-"), into = inRows[j].components(separatedBy: "-")
            let minimum = Self.selected(out[field: 0]), maximum = Self.selected(out[field: 1]), downloadMax = Self.selected(into[field: 0])
            func range(_ percent: String, _ bandwidth: String) -> String {
                javaScriptText(javaScriptRound((javaScriptNumber(percent) ?? .nan) * (javaScriptNumber(bandwidth) ?? .nan)) / 100)
            }
            return Level(name: name, uploadMin: minimum, uploadMax: maximum, downloadMax: downloadMax,
                         uploadRange: complete ? "\(range(minimum, upload.value)) ~ \(range(maximum, upload.value)) \(upload.unit)" : nil,
                         downloadRange: complete ? "0 ~ \(range(downloadMax, download.value)) \(download.unit)" : nil)
        }
        showsEnableHint = !complete || values["qos_enable"] != "1"
        packets = [("ACK", "qos_ack"), ("SYN", "qos_syn"), ("FIN", "qos_fin"), ("RST", "qos_rst"), ("ICMP", "qos_icmp")].map {
            Packet(name: $0.0, on: values[$0.1] == "on")
        }
    }
}

// MARK: - Reading

extension RouterClient {
    public func torSettings() async throws -> TORSettings {
        let support = try await uiCapabilities()
        let values = try await readSettings(TORSettings.keys)
        // hookGet answers "" for a failed request: no devices from get_clientlist, and genClientList stops at the
        // history answer.
        let names = TORSettings.clientNames(current: try await optionalHook("get_clientlist"), history: try await optionalHook("get_clientlist_from_json_database"),
                                            lanMAC: values["lan_hwaddr"] ?? "", productID: values["productid"] ?? "",
                                            amas: !["", "0"].contains(support["amas"] ?? ""))
        let listed = TORSettings(values: values).macs ?? []
        return TORSettings(values: values, names: names.filter { listed.contains($0.key) })
    }

    public func qosUserPriority() async throws -> QoSUserPriority {
        let support = try await uiCapabilities()
        return QoSUserPriority(values: try await readSettings(QoSUserPriority.keys), support: support)
    }
}
