import Foundation

public enum RouterParser {
    public static func json(_ data: Data) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(decoding: data, as: UTF8.self)
            if isLoginPage(text) { throw RouterError.authenticationRequired }
            throw RouterError.invalidResponse("JSON")
        }
        if value["error_status"] != nil { throw RouterError.authenticationRequired }
        return value
    }
    /// The login page, or the script that sends an expired session to it. A JSON reply is data, never the login
    /// page, even when a device name in it reads "Main_Login.asp".
    public static func isLoginPage(_ text: String) -> Bool {
        if let first = text.unicodeScalars.first(where: { !CharacterSet.whitespacesAndNewlines.contains($0) && $0 != "\u{FEFF}" }),
           first == "{" || first == "[" { return false }
        return text.contains("Main_Login.asp") || text.contains("login_authorization") || text.contains("<title>ASUS Login")
    }
    public static func string(_ value: Any?) -> String? {
        if let s = value as? String, !s.isEmpty { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }
    public static func identity(_ values: [String: Any], status: String?) throws -> RouterIdentity {
        guard let model = string(values["productid"]) else { throw RouterError.invalidResponse("型号") }
        let major = string(values["firmver"])?.replacingOccurrences(of: ".", with: "")
        let build = string(values["buildno"])
        var firmware = [major, build].compactMap { $0 }.joined(separator: ".")
        if let ext = string(values["extendno"]), ext != "0" { firmware += "_" + ext }
        let unit = status.flatMap { capture(#"active_wan_unit=(\d+)"#, in: $0) } ?? string(values["wan_unit"]) ?? "0"
        let wan = status.flatMap { capture("wan\(unit)_ipaddr=([^<]+)", in: $0) }
        return RouterIdentity(model: model, firmware: firmware.isEmpty ? "未知" : firmware,
                              lanAddress: string(values["lan_ipaddr"]), wanAddress: wan, hardwareAddress: string(values["lan_hwaddr"]))
    }
    public static func internet(_ xml: String) -> InternetState {
        guard let value = capture(#"<wan>link_internet=(\d+)</wan>"#, in: xml) else { return .unknown }
        switch value { case "2": return .online; case "0", "1": return .offline; default: return .unknown }
    }
    public static func uptime(_ xml: String) -> TimeInterval? {
        capture(#"\((\d+) secs since boot\)"#, in: xml).flatMap(Double.init)
    }
    public static func clients(_ data: Data) throws -> [RouterDevice] {
        let root = try json(data)
        guard let clients = root["get_clientlist"] as? [String: Any] else { throw RouterError.invalidResponse("设备列表") }
        // Partial/malformed device state must pause presence tracking, never look like an offline device.
        for (mac, item) in clients where mac.range(of: #"^(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$"#, options: .regularExpression) != nil {
            guard let device = item as? [String: Any], let state = string(device["isOnline"]), ["0", "1"].contains(state) else {
                throw RouterError.invalidResponse("设备在线状态不完整")
            }
        }
        return clients.compactMap { mac, item -> RouterDevice? in
            guard mac.range(of: #"^(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$"#, options: .regularExpression) != nil,
                  let d = item as? [String: Any] else { return nil }
            let name = string(d["nickName"]) ?? string(d["name"]) ?? mac
            let band = string(d["isWL"]).flatMap(Int.init)
            let signal = string(d["rssi"]).flatMap(Int.init)
            let internet = string(d["internetState"])
            return RouterDevice(mac: mac.uppercased(), name: name,
                                ip: string(d["ip"]).flatMap { ["offline", "0.0.0.0"].contains($0.lowercased()) ? nil : $0 },
                                vendor: string(d["vendor"]), isOnline: string(d["isOnline"]) == "1", band: band,
                                rssi: band != 0 && signal != nil && signal! < 0 ? signal : nil,
                                txLinkMbps: positiveDouble(d["curTx"]), rxLinkMbps: positiveDouble(d["curRx"]),
                                connectionTime: string(d["wlConnectTime"]),
                                internetAllowed: internet == "1" ? true : (internet == "0" ? false : nil),
                                isCurrentDevice: string(d["isLogin"]) == "1", ssid: string(d["ssid"]),
                                deviceDescription: string(d["dpiDevice"]))
        }.sorted {
            if $0.isOnline != $1.isOnline { return $0.isOnline }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.mac < $1.mac : order == .orderedAscending
        }
    }
    private static func positiveDouble(_ value: Any?) -> Double? {
        guard let v = string(value).flatMap(Double.init), v.isFinite, v > 0 else { return nil }; return v
    }
    /// Extracts balanced JSON literals as data. Router JavaScript is never evaluated.
    public static func object(named name: String, in source: String) throws -> [String: Any] {
        guard let range = source.range(of: "\\b" + NSRegularExpression.escapedPattern(for: name) + "\\s*=\\s*\\{", options: .regularExpression),
              let start = source[range].lastIndex(of: "{") else { throw RouterError.invalidResponse(name) }
        var depth = 0, quoted = false, escaped = false
        for index in source[start...].indices {
            let c = source[index]
            if quoted {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { quoted = false }
            } else if c == "\"" { quoted = true }
            else if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 { return try json(Data(source[start...index].utf8)) }
            }
        }
        throw RouterError.invalidResponse(name)
    }
    public static func stringRows(named name: String, in source: String) throws -> [[String]] {
        guard let range = source.range(of: "\\b" + NSRegularExpression.escapedPattern(for: name) + "\\s*=\\s*\\[", options: .regularExpression), let start = source[range].lastIndex(of: "[") else { throw RouterError.invalidResponse("诊断数据") }
        var depth = 0, quoted = false, escaped = false
        for index in source[start...].indices {
            let c = source[index]
            if quoted {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { quoted = false }
            } else if c == "\"" { quoted = true }
            else if c == "[" { depth += 1 }
            else if c == "]" {
                depth -= 1
                if depth == 0 {
                    guard let rows = try JSONSerialization.jsonObject(with: Data(source[start...index].utf8)) as? [[String]] else { throw RouterError.invalidResponse("诊断数据") }
                    return rows.filter { !$0.isEmpty }
                }
            }
        }
        throw RouterError.invalidResponse("诊断数据")
    }
    public static func cpuAndMemory(_ source: String) throws -> (cpu: [String: CPUTicks], used: Double?, total: Double?) {
        let cpu = try object(named: "cpuInfo", in: source)
        let memory = try object(named: "memInfo", in: source)
        var ticks: [String: CPUTicks] = [:]
        for (key, val) in cpu {
            if let d = val as? [String: Any], let total = string(d["total"]).flatMap(UInt64.init),
               let used = string(d["usage"]).flatMap(UInt64.init) { ticks[key] = CPUTicks(total: total, used: used) }
        }
        guard !ticks.isEmpty else { throw RouterError.invalidResponse("CPU") }
        let used = string(memory["simple_used"]).flatMap(Double.init)
        let total = string(memory["total"]).flatMap(Double.init)
        let valid = used != nil && total != nil && used!.isFinite && total!.isFinite && used! >= 0 && used! <= total! && total! > 0
        return (ticks, valid ? used : nil, valid ? total : nil)
    }
    public static func traffic(_ source: String) throws -> TrafficCounters {
        let pattern = #"['\"]INTERNET['\"]\s*:\s*\{\s*rx\s*:\s*(0x[0-9a-fA-F]+|\d+)\s*,\s*tx\s*:\s*(0x[0-9a-fA-F]+|\d+)\s*\}"#
        guard let rx = capture(pattern, in: source, group: 1), let tx = capture(pattern, in: source, group: 2),
              let received = counter(rx), let sent = counter(tx) else { throw RouterError.invalidResponse("互联网流量") }
        return TrafficCounters(received: received, sent: sent)
    }
    static func counter(_ value: String) -> UInt64? {
        value.hasPrefix("0x") ? UInt64(value.dropFirst(2), radix: 16) : UInt64(value)
    }
    public static func capture(_ pattern: String, in source: String, group: Int = 1) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let match = re.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              group < match.numberOfRanges, let range = Range(match.range(at: group), in: source) else { return nil }
        return String(source[range])
    }
    /// The capture groups of every match, in order; a group that did not take part is "".
    static func captures(_ pattern: String, in source: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: source, range: NSRange(source.startIndex..., in: source)).map { match in
            (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: source).map { String(source[$0]) } ?? "" }
        }
    }
    /// The literal that opens at `start` and ends at its matching `close`, skipping quoted text.
    static func balanced(_ source: String, from start: String.Index, open: Character, close: Character) -> Substring? {
        var depth = 0, quoted: Character?, escaped = false
        for index in source[start...].indices {
            let c = source[index]
            if let quote = quoted {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == quote { quoted = nil }
            } else if c == "\"" || c == "'" { quoted = c }
            else if c == open { depth += 1 }
            else if c == close {
                depth -= 1
                if depth == 0 { return source[start...index] }
            }
        }
        return nil
    }
    /// A flat array of JavaScript strings, e.g. `mem_stats_arr = ["1999.96", "58.20", …];`, possibly over several lines.
    public static func strings(named name: String, in source: String) throws -> [String] {
        guard let range = source.range(of: "\\b" + NSRegularExpression.escapedPattern(for: name) + "\\s*=\\s*\\[", options: .regularExpression),
              let start = source[range].lastIndex(of: "["), let literal = balanced(source, from: start, open: "[", close: "]"),
              let values = try? JSONSerialization.jsonObject(with: Data(literal.utf8)) as? [String] else { throw RouterError.invalidResponse(name) }
        return values
    }
    /// The literals assigned to `name` at the start of a line, in page order. Pages reset their data with
    /// placeholders such as `var daily_history = [];` or `speed_history = {};` around the rendered value.
    static func assignments(of name: String, open: Character, close: Character, in source: String) -> [Substring] {
        guard let re = try? NSRegularExpression(pattern: "(?m)^[ \\t]*" + NSRegularExpression.escapedPattern(for: name) + "\\s*=\\s*\\" + String(open)) else { return [] }
        return re.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap { match in
            guard let range = Range(match.range, in: source), let start = source[range].lastIndex(of: open) else { return nil }
            return balanced(source, from: start, open: open, close: close)
        }
    }
    /// Rows of numbers in hexadecimal or decimal, e.g. `daily_history = [[0x7e080b,0x0,0x0], …]`: the first
    /// assignment that holds rows, or an empty list when every assignment is empty.
    public static func numberRows(named name: String, in source: String) throws -> [[UInt64]] {
        let literals = assignments(of: name, open: "[", close: "]", in: source)
        guard let literal = literals.first(where: { $0.dropFirst().contains("[") }) ?? literals.first else { throw RouterError.invalidResponse(name) }
        return try captures(#"\[([^\[\]]*)\]"#, in: String(literal.dropFirst().dropLast())).map { row in
            try row[0].split(separator: ",").map { token in
                let text = token.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let value = counter(text) else { throw RouterError.invalidResponse(name) }
                return value
            }
        }
    }
    /// A capability as the web's isSupport() reads it from state.js `ui_support`: listed with a non-zero value. nil when
    /// the list is not in the form this reads (`ui_support = [{ … }]` with JSON members), so it stays unknown.
    public static func uiSupport(_ name: String, in stateScript: String) -> Bool? {
        guard let range = stateScript.range(of: #"\bui_support\s*=\s*\[\s*\{"#, options: .regularExpression),
              let start = stateScript[range].lastIndex(of: "{"), let literal = balanced(stateScript, from: start, open: "{", close: "}"),
              let values = try? JSONSerialization.jsonObject(with: Data(literal.utf8)) as? [String: Any] else { return nil }
        return (values[name] as? NSNumber).map { $0.doubleValue != 0 } ?? false
    }
    /// Text of a server-rendered table cell: entities decoded, tags dropped, spaces collapsed.
    static func cellText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, value) in ["&nbsp;": " ", "&deg;": "°", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
