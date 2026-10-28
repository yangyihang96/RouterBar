import Foundation

// Adaptive QoS › 网络速度（AdaptiveQoS_InternetSpeed.asp 里的 internet_speed.html）（1.12）：按 Asuswrt-Merlin tag 3006.102.5
// 的页面源码显示上次结果、历史纪录与测速。测速、获取服务器列表与删除历史和网页发送相同的请求，由界面先请用户确认。

// MARK: - JavaScript formatting

/// Number.prototype.toFixed(digits): the exact binary value rounded to `digits` decimals, a tie going to the larger
/// number; plain notation below 1e21, exponent notation (Number::toString) from there.
func javaScriptFixed(_ number: Double, _ digits: Int) -> String {
    guard number.isFinite else { return javaScriptText(number) }
    if abs(number) >= 1e21 { return javaScriptText(number) }
    // printf writes the exact decimal expansion of the double; 80 places hold every value this page formats.
    let exact = String(format: "%.80f", abs(number))
    let parts = exact.split(separator: ".", maxSplits: 1)
    var whole = Array(parts[0]), fraction = Array(parts.count > 1 ? parts[1] : "")
    let rest = fraction.count > digits ? Array(fraction[digits...]) : []
    fraction = Array(fraction.prefix(digits))
    while fraction.count < digits { fraction.append("0") }
    if let first = rest.first, first >= "5" {
        // Carry into the kept digits.
        var digitsArray = whole + fraction, index = digitsArray.count - 1
        while index >= 0 {
            if digitsArray[index] == "9" { digitsArray[index] = "0"; index -= 1 } else { digitsArray[index] = Character(String(digitsArray[index].wholeNumberValue! + 1)); break }
        }
        if index < 0 { digitsArray.insert("1", at: 0) }
        whole = Array(digitsArray.prefix(digitsArray.count - digits)); fraction = Array(digitsArray.suffix(digits))
    }
    let text = String(whole) + (digits > 0 ? "." + String(fraction) : "")
    // (-0.001).toFixed(2) is "-0.00": a negative number keeps its sign; -0 is not below 0 and has none.
    return number < 0 ? "-" + text : text
}

/// ToNumber for a JSON value: null is 0, booleans 0 or 1, text and arrays by their text; a missing value and objects NaN.
func javaScriptToNumber(_ value: OrderedJSON?) -> Double {
    switch value {
    case nil, .object?: return .nan
    case .null?: return 0
    case .bool(let on)?: return on ? 1 : 0
    case .number(let text)?: return javaScriptNumber(text) ?? .nan
    case let value?: return javaScriptNumber(TORSettings.javaScriptString(value)) ?? .nan
    }
}

/// ToInt32, as the bitwise operators apply it.
func javaScriptInt32(_ number: Double) -> Int32 {
    guard number.isFinite else { return 0 }
    let wrapped = number.rounded(.towardZero).truncatingRemainder(dividingBy: 4_294_967_296)
    let positive = wrapped < 0 ? wrapped + 4_294_967_296 : wrapped
    return Int32(bitPattern: UInt32(positive))
}

extension OrderedJSON {
    /// JSON.stringify: members in order, numbers as JavaScript writes them (non-finite as null), text escaped the way
    /// the browser escapes it.
    var javaScriptJSON: String {
        switch self {
        case .object(let members):
            // Own keys in JavaScript's order: array indices first, ascending, then the others as added.
            "{" + JavaScriptKeys.ordered(members.map(\.0)).compactMap { key in members.first { $0.0 == key }.map { Self.quoted(key) + ":" + $0.1.javaScriptJSON } }
                .joined(separator: ",") + "}"
        case .array(let elements): "[" + elements.map(\.javaScriptJSON).joined(separator: ",") + "]"
        case .string(let text): Self.quoted(text)
        case .number(let text): javaScriptNumber(text).map { $0.isFinite ? javaScriptText($0) : "null" } ?? "null"
        case .bool(let on): on ? "true" : "false"
        case .null: "null"
        }
    }
    static func quoted(_ text: String) -> String {
        var out = "\""
        for unit in text.unicodeScalars {
            switch unit {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let scalar where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(unit)
            }
        }
        return out + "\""
    }
}

// MARK: - Page

/// A statement of the page's script that throws (reading a member of undefined or null, `toFixed` of a value that is not a
/// number): the script stops there, keeping what it already wrote.
struct ScriptStop: Error {}

enum JavaScriptMember {
    /// `value.name`: a member of an object; undefined for other values; throws for undefined and null.
    static func get(_ value: OrderedJSON?, _ name: String) throws -> OrderedJSON? {
        guard let value, value != .null else { throw ScriptStop() }
        return value[name]
    }
    /// `value.toFixed(n)`: only a number has it.
    static func fixed(_ value: OrderedJSON?, _ digits: Int) throws -> String {
        guard case .number(let text)? = value, let number = javaScriptNumber(text) else { throw ScriptStop() }
        return javaScriptFixed(number, digits)
    }
    /// jQuery `.text(value)`: undefined reads instead of writing (nil here); anything else is written as its text, which
    /// for an object or array can throw (see string).
    static func text(_ value: OrderedJSON?) throws -> String? {
        switch value {
        case nil: nil
        case .null?: ""
        case let value?: try string(value)
        }
    }
    /// ToNumber, as `bytes * 8` applies it: an object or array goes through its text first, which can throw.
    static func number(_ value: OrderedJSON) throws -> Double {
        switch value {
        case .object, .array: javaScriptNumber(try string(value)) ?? .nan
        default: javaScriptToNumber(value)
        }
    }
    /// `parseInt(value)`: its text first, which for an object or array can throw (see string).
    static func parseInt(_ value: OrderedJSON?) throws -> Double? {
        guard let value else { return SiteSurvey.parseInt(nil) }
        switch value {
        case .object, .array: return SiteSurvey.parseInt(.string(try string(value)))
        default: return SiteSurvey.parseInt(value)
        }
    }
    /// `value.length > 20` throws for undefined and null.
    static func checkLength(_ value: OrderedJSON?) throws { if value == nil || value == .null { throw ScriptStop() } }
    /// `value.toString()`, `value + ""` and the text an attribute takes: an object with a member named toString (which in
    /// JSON is never a function) throws, as does an array holding one; an array joins its elements, null and undefined
    /// in it as "".
    static func string(_ value: OrderedJSON) throws -> String {
        switch value {
        case .object(let members):
            if members.contains(where: { $0.0 == "toString" }) { throw ScriptStop() }
            return "[object Object]"
        case .array(let elements):
            return try elements.map { $0 == .null ? "" : try string($0) }.joined(separator: ",")
        default:
            return TORSettings.javaScriptString(value)
        }
    }
}

extension String {
    /// `a == b` for JavaScript strings: the same UTF-16 code units (Swift's == also equates canonically equivalent text).
    public func sameUnits(_ other: String) -> Bool { utf16.elementsEqual(other.utf16) }
}

public struct InternetSpeedPage: Sendable, Equatable {
    /// ookla_state, ookla_start_time, preferred_lang, link_internet, the VPN clients' state and names, ispctrl_desc.
    public let values: [String: String]
    public let support: [String: String]
    /// ookla_speedtest_get_history as the page keeps it: the records and the trailing {} (an empty answer becomes [{}]).
    public let history: [OrderedJSON]
    /// state.js 284: `uptimeStr.substring(26,31)`, the "+hhmm" of the router's clock.
    public let timezone: String
    /// The link rate shown instead of the test (see `showsLinkRate`), in Mbps.
    public let linkRate: Int?

    static let keys = ["ookla_state", "ookla_start_time", "preferred_lang", "link_internet", "ispctrl_desc"]
        + (1...5).flatMap { ["vpn_client\($0)_state", "vpn_client\($0)_desc", "wgc\($0)_enable", "wgc\($0)_desc"] }

    public init(values: [String: String], support: [String: String], history: [OrderedJSON], timezone: String, linkRate: Int?) {
        self.values = values; self.support = support; self.history = history.isEmpty ? [.object([])] : history
        self.timezone = timezone; self.linkRate = linkRate
    }

    func isSupported(_ key: String) -> Bool { !["", "0"].contains(support[key] ?? "") }
    /// internetSpeed_lite_support: no history.
    public var lite: Bool { isSupported("ookla_lite") }
    public var connected: Bool { values["link_internet"] == "2" }
    /// A test another page started is still running (init 185–202).
    public var testing: Bool { values["ookla_state"] == "1" }

    /// ispctrl_desc as the page reads it (81–87).
    public enum ISPControl: Sendable, Equatable {
        case none, controlled
        /// JSON.parse throws on text that is not JSON, and reading ISPCtrl of null throws: the script stops at line 81,
        /// before it registers the code that shows either view and runs init, so the page shows neither.
        case broken
    }
    public var ispControl: ISPControl {
        guard let raw = values["ispctrl_desc"], !raw.isEmpty else { return .none }
        guard let parsed = try? OrderedJSON(data: Data(raw.utf8)), parsed != .null else { return .broken }
        // `ispctrl_desc.ISPCtrl != ""`: undefined (also of a value that is not an object) is not == "".
        guard let control = parsed["ISPCtrl"] else { return .controlled }
        return JavaScriptCompare.looselyEqualsEmptyText(control) ? .none : .controlled
    }
    /// The page shows the WAN link rate instead of the test when a WAN port links at 5 Gbps or more and the router cannot
    /// test that fast, or an ISP controls the line (136–157).
    public var showsLinkRate: Bool {
        linkRate != nil && ((!isSupported("10g_speedTest") && !isSupported("eth_monitor")) || ispControl == .controlled)
    }
    /// init_linkRate (161–173): at 1000 or more in whole Gbps.
    public var linkRateText: (value: String, unit: String)? {
        guard let rate = linkRate else { return nil }
        return rate >= 1000 ? (javaScriptText(javaScriptRound(Double(rate) / 1000)), "Gbps") : (String(rate), "Mbps")
    }

    /// build_interface_list (1244–1272): WAN, then connected OpenVPN clients and enabled WireGuard clients; the list shows
    /// only when there is more than WAN.
    public var interfaces: [(title: String, value: String)] {
        var list = [(title: "WAN", value: "")]
        if isSupported("openvpnd") {
            for unit in 1...5 where values["vpn_client\(unit)_state"] == "2" { list.append(("OVPN\(unit): " + (values["vpn_client\(unit)_desc"] ?? ""), "tun1\(unit)")) }
        }
        if isSupported("wireguard") {
            for unit in 1...5 where values["wgc\(unit)_enable"] == "1" { list.append(("WGC\(unit): " + (values["wgc\(unit)_desc"] ?? ""), "wgc\(unit)")) }
        }
        return list
    }

    public var records: [OrderedJSON] { Array(history.dropLast()) }
}

/// What the page writes into its fields; nil leaves a field as it was. `stopped` is set where the writing script threw.
public struct SpeedTestDisplay: Sendable, Equatable {
    public var date: String?
    public var time: String?
    public var host: String?
    public var location: String?
    public var download: String?
    public var upload: String?
    public var latency: String?
    public var jitter: String?
    public var detailDownload: String?
    public var detailUpload: String?
    public var detailTime: String?
    public var level: SpeedLevel?
    public var stopped = false

    /// show_latest_record (1023–1054), in its order. It runs when the history has a record and no test is running.
    public static func latest(_ record: OrderedJSON, timezone: String, lite: Bool) -> SpeedTestDisplay {
        var display = SpeedTestDisplay()
        do {
            let when = try InternetSpeed.localTime(try JavaScriptMember.get(record, "timestamp"), timezone: timezone)
            let download = try InternetSpeed.mbps(try JavaScriptMember.get(try JavaScriptMember.get(record, "download"), "bandwidth"))
            let upload = try InternetSpeed.mbps(try JavaScriptMember.get(try JavaScriptMember.get(record, "upload"), "bandwidth"))
            let server = try JavaScriptMember.get(record, "server")
            display.date = when.date; display.time = when.time
            let name = try JavaScriptMember.get(server, "name")
            display.host = try JavaScriptMember.text(name)
            try JavaScriptMember.checkLength(name)
            let location = try JavaScriptMember.get(server, "location")
            display.location = try JavaScriptMember.text(location)
            try JavaScriptMember.checkLength(location)
            display.download = download; display.detailDownload = download
            display.upload = upload; display.detailUpload = upload
            let ping = try JavaScriptMember.get(record, "ping")
            display.latency = try JavaScriptMember.fixed(try JavaScriptMember.get(ping, "latency"), 2)
            display.jitter = try JavaScriptMember.fixed(try JavaScriptMember.get(ping, "jitter"), 2)
            if !lite, let loss = try JavaScriptMember.get(record, "packetLoss") { _ = try JavaScriptMember.fixed(loss, 2) }
            display.level = SpeedLevel(mbps: download)
        } catch { display.stopped = true }
        return display
    }
}

/// One row of 历史纪录 as add_speedTest_history (676–866) draws it, up to where its code throws.
public struct SpeedTestHistoryRow: Sendable, Equatable {
    /// The row exists once the record had a timestamp to read.
    public var drawn = false
    /// `history_obj.result.id`, which the check box carries.
    public var id: String?
    public var date: String?
    public var time: String?
    public var download: String?
    public var upload: String?
    public var latency: String?
    public var jitter: String?
    public var stopped = false

    public init(_ record: OrderedJSON, timezone: String) {
        do {
            let when = try InternetSpeed.localTime(try JavaScriptMember.get(record, "timestamp"), timezone: timezone)
            drawn = true
            // jQuery's attr leaves the id empty for undefined and null; other values become text, which can throw.
            let raw = try JavaScriptMember.get(try JavaScriptMember.get(record, "result"), "id")
            id = raw == nil || raw == .null ? "" : try JavaScriptMember.string(raw!)
            date = when.date; time = when.time
            download = try InternetSpeed.mbps(try JavaScriptMember.get(try JavaScriptMember.get(record, "download"), "bandwidth"))
            upload = try InternetSpeed.mbps(try JavaScriptMember.get(try JavaScriptMember.get(record, "upload"), "bandwidth"))
            let ping = try JavaScriptMember.get(record, "ping")
            latency = try JavaScriptMember.fixed(try JavaScriptMember.get(ping, "latency"), 2)
            jitter = try JavaScriptMember.fixed(try JavaScriptMember.get(ping, "jitter"), 2)
            if let loss = try JavaScriptMember.get(record, "packetLoss") { _ = try JavaScriptMember.fixed(loss, 2) }
        } catch { stopped = true }
    }
}

/// change_speed_level (590–650): the rating of a download speed, by parseInt of its Mbps text.
public struct SpeedLevel: Sendable, Equatable {
    public let name: String
    public let title: String
    public let detail: String
    public let range: String

    public static let all: [SpeedLevel] = [
        SpeedLevel(name: "极快", title: "做任何事", detail: "您的网络速度极快！这种极快的网络速度，您可以做任何事情。", range: "901+"),
        SpeedLevel(name: "超快", title: "支持许多 4k 串流和游戏", detail: "您的网络速度超快！您可以串流传输许多 4K 电影，并可以同时在多个设备上玩在线游戏！", range: "251 - 900"),
        SpeedLevel(name: "很快", title: "支持多设备 4K 串流", detail: "您的网络速度不错！您可以同时串流传输许多 4K 电影。", range: "101 - 250"),
        SpeedLevel(name: "不错", title: "支持多设备串流传输", detail: "您的网络速度很棒！您可以在多个设备上进行串流传输！", range: "51 - 100"),
        SpeedLevel(name: "良好", title: "支持网页浏览", detail: "您的网络速度良好！您可以流畅地进行网络浏览！", range: "6 - 50"),
        SpeedLevel(name: "一般", title: "支持 SD 视频串流", detail: "您的网络速度一般。您可以在多个设备上串流传输 SD 视频。如果您在许多设备上串流传输，则可能会看到一些缓冲现象。", range: "0 - 5")
    ]

    init(name: String, title: String, detail: String, range: String) { self.name = name; self.title = title; self.detail = detail; self.range = range }

    /// nil when parseInt gives NaN: no branch matches and the rating stays as it was.
    public init?(mbps: String) {
        guard let speed = SiteSurvey.parseInt(.string(mbps)) else { return nil }
        // parseInt gives a whole number, so the ranges' gaps (50–51, …) never occur.
        self = Self.all[speed >= 901 ? 0 : speed >= 251 ? 1 : speed >= 101 ? 2 : speed >= 51 ? 3 : speed >= 6 ? 4 : 5]
    }
}

public enum InternetSpeed {
    /// convert_Bps_to_Mbps (566–580): bytes × 8 / 10⁶ with no decimals from 12.5 GB/s, one from 1.25 GB/s, else two.
    public static func mbps(_ bytes: OrderedJSON?) throws -> String {
        // `bytes * 8` and parseInt(bytes) turn an object or array into text first, which can throw.
        if let bytes { _ = try JavaScriptMember.number(bytes) }
        let megabits = javaScriptToNumber(bytes) * 8 / (1000 * 1000)
        let whole = SiteSurvey.parseInt(bytes) ?? .nan
        return javaScriptFixed(megabits, whole >= 12_500_000_000 ? 0 : whole >= 1_250_000_000 ? 1 : 2)
    }

    /// convert_to_localtime (249–278): `new Date(gmt_time)` moved by the hours of the router's "+hhmm" (minutes are
    /// ignored, and without a sign the time is 0), written as Y/M/D and HH:MM from UTC.
    public static func localTime(_ timestamp: OrderedJSON?, timezone: String) throws -> (date: String, time: String) {
        let units = Array(timezone.utf16)
        let hours = SiteSurvey.parseInt(.string(String(decoding: units.dropFirst().prefix(2), as: UTF16.self)))
        let sign = units.first.map { String(decoding: [$0], as: UTF16.self) } ?? ""
        let milliseconds = try javaScriptDate(timestamp)
        var target: Double
        switch sign {
        case "+": target = milliseconds + (hours ?? .nan) * 3_600_000
        case "-": target = milliseconds - (hours ?? .nan) * 3_600_000
        default: target = 0
        }
        // A Date past ±8.64e15 ms is invalid, so every field is NaN.
        if !target.isFinite || abs(target) > 8.64e15 { return ("NaN/NaN/NaN", "NaN:NaN") }
        target = target.rounded(.towardZero)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.era, .year, .month, .day, .hour, .minute], from: Date(timeIntervalSince1970: target / 1000))
        func two(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
        let year = parts.era == 0 ? 1 - parts.year! : parts.year!
        return ("\(year)/\(parts.month!)/\(parts.day!)", "\(two(parts.hour!)):\(two(parts.minute!))")
    }

    /// `new Date(value).getTime()`: a number is the time itself (whole milliseconds, NaN past ±8.64e15), null 0, a
    /// boolean 0 or 1, undefined NaN; text (and an object or array, as its text, which can throw) is read as the
    /// ECMAScript date-time format: a date alone is UTC, a date and time without an offset is the Mac's local time. Other
    /// text is NaN here; browsers also accept some older formats.
    static func javaScriptDate(_ value: OrderedJSON?) throws -> Double {
        func clip(_ time: Double) -> Double { time.isFinite && abs(time) <= 8.64e15 ? time.rounded(.towardZero) + 0 : .nan }
        switch value {
        case nil: return .nan
        case .null?: return 0
        case .bool(let on)?: return on ? 1 : 0
        case .number(let text)?: return clip(javaScriptNumber(text) ?? .nan)
        case let value?: return clip(parse(try JavaScriptMember.string(value)))
        }
    }

    static func parse(_ text: String, zone: TimeZone = .current) -> Double {
        // ASCII digits only, up to the very end of the text; V8 also takes a space for "T" and an offset without its colon.
        let pattern = #"^([+-][0-9]{6}|[0-9]{4})(?:-([0-9]{2})(?:-([0-9]{2}))?)?(?:[T ]([0-9]{2}):([0-9]{2})(?::([0-9]{2})(?:\.([0-9]+))?)?(Z|[+-][0-9]{2}:?[0-9]{2})?)?\z"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return .nan }
        func group(_ index: Int) -> String? { Range(match.range(at: index), in: text).map { String(text[$0]) } }
        func number(_ index: Int, _ absent: Int) -> Int? { group(index).map { Int($0) } ?? absent }
        guard group(1) != "-000000", let year = number(1, 0), let month = number(2, 1), let day = number(3, 1),
              let hour = number(4, 0), let minute = number(5, 0), let second = number(6, 0),
              let millisecond = Int(String((group(7) ?? "0").prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)) else { return .nan }
        // V8 takes any day up to 31 and lets it run into the next month (2026-02-30 is 2 March).
        guard (1...12).contains(month), (1...31).contains(day), minute < 60, second < 60,
              hour < 24 || (hour == 24 && minute == 0 && second == 0 && millisecond == 0) else { return .nan }
        // MakeDay / MakeTime on the proleptic Gregorian calendar.
        func days(from year: Int, _ month: Int, _ day: Int) -> Int {
            let y = month <= 2 ? year - 1 : year
            let era = (y >= 0 ? y : y - 399) / 400
            let yoe = y - era * 400
            let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
            let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
            return era * 146_097 + doe - 719_468
        }
        var time = Double(days(from: year, month, day)) * 86_400_000 + Double(hour * 3_600_000 + minute * 60_000 + second * 1000 + millisecond)
        if let offset = group(8) {
            if offset != "Z" {
                let digits = offset.dropFirst().filter { $0 != ":" }
                guard let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)), hours < 24, minutes < 60 else { return .nan }
                time -= (offset.hasPrefix("-") ? -1 : 1) * Double(hours * 3_600_000 + minutes * 60_000)
            }
        } else if group(4) != nil {
            time = utc(fromLocal: time, zone: zone)
        }
        return time
    }

    /// UTC(t) (ECMA-262 21.4.1.26): the earliest instant whose local time is t; a local time a transition skips takes the
    /// offset in effect before the transition (as V8: in Sydney 2026-10-04T02:30 is 16:30Z, 2026-04-05T02:30 is 15:30Z).
    static func utc(fromLocal local: Double, zone: TimeZone) -> Double {
        func offset(_ instant: Double) -> Double { Double(zone.secondsFromGMT(for: Date(timeIntervalSince1970: instant / 1000))) * 1000 }
        let before = offset(local - 86_400_000)
        let instants = Set([before, offset(local), offset(local + 86_400_000)]).map { local - $0 }.filter { offset($0) == local - $0 }
        return instants.min() ?? local - before
    }

    /// The id a history row carries (`history_obj.result.id`, as the element id text).
    public static func recordID(_ record: OrderedJSON) -> String { record["result"]?["id"].map(TORSettings.javaScriptString) ?? "" }

    /// convert_speedTestHistory_to_str (312–320): every record but the trailing {} as JSON, each followed by "\n".
    public static func historyText(_ history: [OrderedJSON]) -> String {
        history.dropLast().map { $0.javaScriptJSON + "\n" }.joined()
    }

    public enum HistoryUpdate: Sendable, Equatable {
        /// check_duplicate_result found the result id.
        case unchanged
        case added([OrderedJSON])
        /// check_duplicate_result threw (a record or the result has no `result`).
        case stopped
    }
    /// A finished test added to the history (get_speedTest_result 502–521): unless a record has its result id (the
    /// page compares with ==), it goes first, and a full list of 50 (51 with {}) first loses its 50th. A lite router
    /// keeps only the newest.
    public static func adding(_ result: OrderedJSON, to history: [OrderedJSON], lite: Bool) -> HistoryUpdate {
        var list = history
        if lite {
            if list.count == 2 { list[0] = result } else { list.insert(result, at: 0) }
            return .added(list)
        }
        do {
            for record in list.dropLast() {
                let known = try JavaScriptMember.get(try JavaScriptMember.get(record, "result"), "id")
                let id = try JavaScriptMember.get(try JavaScriptMember.get(result, "result"), "id")
                if try looselyEqual(known, id) { return .unchanged }
            }
        } catch { return .stopped }
        if list.count == 51 { list.remove(at: 49) }
        list.insert(result, at: 0)
        return .added(list)
    }

    public enum Deletion: Sendable, Equatable {
        case unchanged
        case deleted([OrderedJSON])
        /// A record before the match had no `result.id` and the page threw: the records removed until then stay removed
        /// on the page, nothing is written and the selection stays.
        case stopped([OrderedJSON])
    }
    /// delete_history (898–932): each selected id removes the first record whose `result.id.toString()` equals it,
    /// reading the records in order up to that match.
    public static func deleting(_ ids: [String], from history: [OrderedJSON]) -> Deletion {
        var list = history, changed = false
        for id in ids {
            for index in list.indices.dropLast() {
                guard let value = try? JavaScriptMember.get(try JavaScriptMember.get(list[index], "result"), "id"), value != .null,
                      let text = try? JavaScriptMember.string(value) else { return .stopped(list) }
                if text.sameUnits(id) { list.remove(at: index); changed = true; break }
            }
        }
        return changed ? .deleted(list) : .unchanged
    }

    /// update_history_inform (964–977): ten records a page; the range shown, or nil when there is no record.
    public static func pageRange(page: Int, count: Int) -> (start: Int, end: Int, lastPage: Int)? {
        guard count > 1 else { return nil }
        let lastPage = count <= 11 ? 0 : Int((Double(count - 1) / 10).rounded(.up)) - 1
        let start = page * 10 + 1
        return (start, min(start + 9, count - 1), lastPage)
    }

    public struct HistoryRendering: Sendable, Equatable {
        public var rows: [SpeedTestHistoryRow] = []
        /// A record's code threw (whether or not its row was already drawn): the page stops there.
        public var stopped = false
    }
    /// show_history_results (652–674) for a page: the rows it draws, up to a record whose code throws.
    public static func historyRows(_ history: [OrderedJSON], page: Int, timezone: String) -> HistoryRendering {
        var rendering = HistoryRendering()
        guard let range = pageRange(page: page, count: history.count), range.start <= range.end else { return rendering }
        for record in history[(range.start - 1)...(range.end - 1)] {
            let row = SpeedTestHistoryRow(record, timezone: timezone)
            if row.drawn { rendering.rows.append(row) }
            if row.stopped { rendering.stopped = true; break }
        }
        return rendering
    }

    /// `a == b` for the ids the page compares.
    static func looselyEqual(_ a: OrderedJSON?, _ b: OrderedJSON?) throws -> Bool {
        switch (a, b) {
        case (nil, nil), (nil, .null?), (.null?, nil), (.null?, .null?): return true
        case (nil, _), (_, nil), (.null?, _), (_, .null?): return false
        case (.string(let x)?, .string(let y)?): return x.sameUnits(y)
        case (.number(let x)?, .number(let y)?): return javaScriptNumber(x) == javaScriptNumber(y)
        // Two objects or arrays are equal only when they are the same object, which parsed values never are.
        case (.object?, .object?), (.array?, .array?), (.object?, .array?), (.array?, .object?): return false
        case (let x?, let y?):
            // Mixed types: an object or array becomes its text first (which can throw); text with text compares as text,
            // anything else as numbers (NaN equals nothing).
            func primitive(_ value: OrderedJSON) throws -> OrderedJSON {
                switch value {
                case .object, .array: .string(try JavaScriptMember.string(value))
                default: value
                }
            }
            let left = try primitive(x), right = try primitive(y)
            if case .string(let s) = left, case .string(let t) = right { return s.sameUnits(t) }
            func number(_ value: OrderedJSON) -> Double? {
                switch value {
                case .bool(let on): on ? 1 : 0
                case .number(let text), .string(let text): javaScriptNumber(text)
                default: nil
                }
            }
            guard let l = number(left), let r = number(right) else { return false }
            return l == r
        }
    }
}

/// What one read of a running test writes (get_speedTest_result 411–533): every line is processed again on each read,
/// so a later write replaces an earlier one; the read stops where the script throws, which also ends the reading.
public struct SpeedTestProgress: Sendable, Equatable {
    public var display = SpeedTestDisplay()
    /// The "result" line once the test finished.
    public var result: OrderedJSON?
    /// The line before the trailing {} reports an error: the page stops the test (ERR_TERMINATE).
    public var failed = false
    /// The line before {} has level "error"; the page tolerates 50 of these.
    public var levelError = false
    /// Fewer than two entries: nothing written yet.
    public var empty = false

    public static func read(_ answer: OrderedJSON?, timezone: String, lite: Bool) -> SpeedTestProgress {
        var progress = SpeedTestProgress()
        // hookGet answers "" for a failed request, whose length is 0.
        guard let answer, answer != .string("") else { progress.empty = true; return progress }
        guard case .array(let entries) = answer else { progress.display.stopped = true; return progress }
        guard entries.count >= 2 else { progress.empty = true; return progress }
        do {
            let before = entries[entries.count - 2]
            if try JavaScriptMember.get(before, "error") != nil { progress.failed = true; return progress }
            if let level = try JavaScriptMember.get(before, "level"), try InternetSpeed.looselyEqual(level, .string("error")) { progress.levelError = true }
            for entry in entries.dropLast() {
                let type = try JavaScriptMember.get(entry, "type")
                func isType(_ name: String) throws -> Bool { try InternetSpeed.looselyEqual(type, .string(name)) }
                if try isType("testStart") {
                    let when = try InternetSpeed.localTime(try JavaScriptMember.get(entry, "timestamp"), timezone: timezone)
                    progress.display.date = when.date; progress.display.time = when.time
                    let server = try JavaScriptMember.get(entry, "server")
                    if let name = try JavaScriptMember.text(try JavaScriptMember.get(server, "name")) { progress.display.host = name }
                    if let location = try JavaScriptMember.text(try JavaScriptMember.get(server, "location")) { progress.display.location = location }
                } else if try isType("download") {
                    // `parseInt(download.bandwidth)` first.
                    let whole = try JavaScriptMember.parseInt(try JavaScriptMember.get(try JavaScriptMember.get(entry, "download"), "bandwidth"))
                    progress.display.download = try InternetSpeed.mbps(whole.map { .number(javaScriptText($0)) } ?? .string("NaN"))
                } else if try isType("upload") {
                    progress.display.upload = try InternetSpeed.mbps(try JavaScriptMember.get(try JavaScriptMember.get(entry, "upload"), "bandwidth"))
                } else if try isType("result") {
                    let when = try InternetSpeed.localTime(try JavaScriptMember.get(entry, "timestamp"), timezone: timezone)
                    progress.display.date = when.date; progress.display.time = when.time
                    let ping = try JavaScriptMember.get(entry, "ping")
                    progress.display.latency = try JavaScriptMember.fixed(try JavaScriptMember.get(ping, "latency"), 2)
                    progress.display.jitter = try JavaScriptMember.fixed(try JavaScriptMember.get(ping, "jitter"), 2)
                    let download = try InternetSpeed.mbps(try JavaScriptMember.get(try JavaScriptMember.get(entry, "download"), "bandwidth"))
                    progress.display.detailDownload = download
                    progress.display.detailUpload = try InternetSpeed.mbps(try JavaScriptMember.get(try JavaScriptMember.get(entry, "upload"), "bandwidth"))
                    if !lite, let loss = try JavaScriptMember.get(entry, "packetLoss") { _ = try JavaScriptMember.fixed(loss, 2) }
                    if let level = SpeedLevel(mbps: download) { progress.display.level = level }
                    progress.display.detailTime = when.date + " " + when.time
                    progress.result = entry
                    // The page handles the history next and stops reading.
                    return progress
                }
            }
        } catch { progress.display.stopped = true }
        return progress
    }
}

/// A server of the nearby list (create_server_list 1128–1205): entries with a name; the name goes into the page as
/// HTML, the location as text.
public struct SpeedTestServer: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let location: String

    /// The list stops at an entry whose location is not text (`.length` of undefined throws).
    public static func list(_ answer: OrderedJSON?) -> [SpeedTestServer] {
        guard case .array(let entries)? = answer else { return [] }
        var servers: [SpeedTestServer] = []
        for entry in entries {
            // `speedTest_servers[key]["name"]` throws for null, which ends the list.
            if entry == .null { break }
            guard let name = entry["name"], name != .null else { continue }
            guard case .string(let location)? = entry["location"] else { break }
            let nameText = TORSettings.javaScriptString(name)
            servers.append(SpeedTestServer(id: entry["id"].map(TORSettings.javaScriptString) ?? "undefined",
                                           name: HTMLText.visible(nameText, inside: ["div"]), location: location))
        }
        return servers
    }
}

extension RouterClient {
    public func internetSpeedPage() async throws -> InternetSpeedPage {
        let values = try await readSettings(InternetSpeedPage.keys)
        let support = try await uiCapabilities()
        let history: [OrderedJSON]
        if case .array(let list)? = try await optionalHook("ookla_speedtest_get_history") { history = list } else { history = [] }
        let uptime = try await optionalHook("uptime")?.text ?? ""
        let timezone = String(decoding: Array(uptime.utf16).dropFirst(26).prefix(5), as: UTF16.self)
        return InternetSpeedPage(values: values, support: support, history: history, timezone: timezone, linkRate: try await wanLinkRateAbove5G())
    }

    /// The fastest WAN link of the router's own ports at 5000 Mbps or more (get_port_status_array for get_lan_hwaddr,
    /// 101–129): an active port (is_on "1") with the primary or secondary WAN capability bit.
    func wanLinkRateAbove5G() async throws -> Int? {
        guard let mac = try await optionalHook("get_lan_hwaddr")?.text, !mac.isEmpty,
              let text = try await optionalDataPage(.portStatus, [("node_mac", mac)]),
              let answer = try? OrderedJSON(data: Data(text.utf8)), let ports = answer["port_info"]?[mac] else { return nil }
        var primary = 0.0, secondary = 0.0
        for (_, port) in ports.members where TORSettings.looselyEqualsOne(port["is_on"]) {
            let capability = javaScriptInt32(javaScriptToNumber(port["cap"]))
            let rate = javaScriptToNumber(port["link_rate"])
            // The last such port of each kind is the one shown; the larger of the two wins.
            if capability & (1 << 30) != 0, rate >= 5000 { primary = rate }
            if capability & (1 << 29) != 0, rate >= 5000 { secondary = rate }
        }
        let rate = primary >= secondary ? primary : secondary
        return rate >= 5000 && rate < 1e9 ? Int(rate) : nil
    }

    /// do_speedTest_exe (330–361): records the start time, then starts Ookla: the test (with a server id or the nearest),
    /// or "list" for the nearby servers. Returns the start time the page then measures its two minutes from.
    public func startOokla(list: Bool, serverID: String, interface: String) async throws -> Double {
        try acquireMutation(); defer { releaseMutation() }
        let start = (Date().timeIntervalSince1970 * 1000).rounded(.down)
        _ = try await request("set_ookla_speedtest_start_time.cgi", method: "POST",
                              body: RouterAuthentication.orderedForm([("ookla_start_time", javaScriptText(start))], .jQuery),
                              contentType: "application/x-www-form-urlencoded; charset=UTF-8")
        _ = try await request("ookla_speedtest_exe.cgi", method: "POST",
                              body: RouterAuthentication.orderedForm([("type", list ? "list" : ""), ("id", list ? "" : serverID), ("iface", interface)], .jQuery),
                              contentType: "application/x-www-form-urlencoded; charset=UTF-8")
        return start
    }

    public func ooklaResult() async throws -> OrderedJSON? { try await optionalHook("ookla_speedtest_get_result") }
    /// Reading the list also sets ookla_state back to idle (web.c 33097–33119), so it is sent as a change: a failure
    /// after sending is reported as unconfirmed. The page reads it only after "list".
    public func ooklaServers() async throws -> OrderedJSON? {
        try acquireMutation(); defer { releaseMutation() }
        return try OrderedJSON(data: try await request("appGet.cgi", query: [.init(name: "hook", value: "ookla_speedtest_get_servers()")], changes: true))["ookla_speedtest_get_servers"]
    }

    /// set_ookla_speedtest_state.cgi (web.c 33176–33193): an error state above 1 also stops Ookla.
    public func setOoklaState(_ state: String) async throws {
        try acquireMutation(); defer { releaseMutation() }
        _ = try await request("set_ookla_speedtest_state.cgi", method: "POST", body: RouterAuthentication.orderedForm([("ookla_state", state)], .jQuery),
                              contentType: "application/x-www-form-urlencoded; charset=UTF-8")
    }

    /// ookla_speedtest_write_history.cgi: replaces the history file with the records.
    public func writeSpeedTestHistory(_ history: [OrderedJSON]) async throws {
        try acquireMutation(); defer { releaseMutation() }
        _ = try await request("ookla_speedtest_write_history.cgi", method: "POST",
                              body: RouterAuthentication.orderedForm([("speedTest_history", InternetSpeed.historyText(history))], .jQuery),
                              contentType: "application/x-www-form-urlencoded; charset=UTF-8")
    }
}
