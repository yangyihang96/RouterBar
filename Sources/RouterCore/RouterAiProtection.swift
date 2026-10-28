import Foundation

// AiProtection 网络神盾's record pages (Asuswrt-Merlin 3006.102.5 www/AiProtection_MaliciousSitesBlocking.asp,
// AiProtection_IntrusionPreventionSystem.asp and AiProtection_InfectedDevicePreventBlock.asp): what each page reads when
// it opens. Only reads; the pages' white list, CSV export and "delete events" are not offered.

/// The three protections that keep records, by the `type` their data pages take.
public enum AiProtectionKind: String, Sendable, CaseIterable, Hashable {
    /// 恶意网站拦截.
    case maliciousSites = "mals"
    /// 双向 IPS.
    case intrusionPrevention = "vp"
    /// 受感染设备防止及拦截.
    case infectedDevices = "cc"

    /// The protection's own switch; the page shows it on only together with AiProtection's `wrs_protect_enable`
    /// (initial() of each page).
    public var enableKey: String { "wrs_\(rawValue)_enable" }
    /// When the router started counting, in seconds; 0 until the first record (getEventTime()).
    public var sinceKey: String { "wrs_\(rawValue)_t" }
    var countKey: String { "\(rawValue)_n" }
    /// 双向 IPS charts by severity from getIPSChart.asp; the other two use getNonIPSChart.asp (getIPSChart()).
    var chartPage: RouterDataPage { self == .intrusionPrevention ? .intrusionChart : .protectionChart }

    /// Trend Micro categories the two non-IPS pages name, as `cat_id_index` lists them (malicious sites 395–398,
    /// infected devices 105–108); only 恶意网站拦截 lists "2" Illegal.
    public func categoryName(_ id: String) -> String? {
        guard self != .intrusionPrevention, self == .maliciousSites || id != "2" else { return nil }
        return Self.categories[id]
    }
    static let categories = ["39": "Proxy Avoidance", "73": "Malicious Software", "74": "Spyware", "75": "Phishing", "76": "Spam",
                             "77": "Adware", "78": "Malware Accomplic", "79": "Disease Vector", "80": "Cookies", "81": "Dialers",
                             "82": "Hacking", "83": "Joke Program", "84": "Password Cracking Apps", "85": "Remote Access",
                             "86": "Made for AdSense sites", "91": "C&C Server", "92": "Malicious Domain", "94": "Scam", "95": "Ransomware",
                             "2": "Illegal"]
}

/// One row of getIPSDetailEvent.asp?event=all.
public struct AiProtectionEvent: Sendable, Equatable {
    /// As the router writes it, in the router's own time zone, e.g. "2026-10-16 09:30:00".
    public let time: String
    public let source: String
    public let destination: String
    /// 双向 IPS: "H", "M" or "L" (the page's red, yellow and green dots).
    public let severity: String?
    /// 双向 IPS: the signature's title.
    public let threat: String?
    /// 双向 IPS: 1 Device Infected, 2 External Attacks (`direct_type`).
    public let direction: Int?
    /// The other two pages: the Trend Micro category id.
    public let category: String?
    public init(time: String, source: String, destination: String, severity: String? = nil, threat: String? = nil, direction: Int? = nil, category: String? = nil) {
        self.time = time; self.source = source; self.destination = destination
        self.severity = severity; self.threat = threat; self.direction = direction; self.category = category
    }
    /// Sortable [year, month, day, hour, minute, second], whatever the padding.
    var timeParts: [Int] { time.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) } }
}

/// Events the page lists as one row: 双向 IPS by the threat's first word and the destination, the other two pages by
/// destination and source. The row shows the first event of the group; opened, it lists every event's time, source and
/// destination (showDetailEvent()), so a 双向 IPS row can hold several sources.
public struct AiProtectionEventGroup: Sendable, Equatable, Identifiable {
    public let id: String
    /// In the router's order; never empty.
    public let events: [AiProtectionEvent]
    public var first: AiProtectionEvent { events[0] }
    public var times: [String] { events.map(\.time) }
}

public struct AiProtectionDeviceHits: Sendable, Equatable, Identifiable {
    /// A MAC address as the router lists it (upper-cased), or the router's own text when it is not one.
    public let device: String
    public let hits: Int
    public var id: String { device }
}

/// Seven days of counts, the last day being the one that holds the records' `chartEnd`. 双向 IPS draws all three
/// severities; the other two pages draw only the first series (drawLineChart()).
public struct AiProtectionChart: Sendable, Equatable {
    public let high: [Int]
    public let medium: [Int]
    public let low: [Int]
}

public struct AiProtectionRecords: Sendable, Equatable {
    public let kind: AiProtectionKind
    /// AiProtection's master switch (`wrs_protect_enable`) and this protection's own.
    public let masterEnabled: Bool
    public let featureEnabled: Bool
    public let since: Date?
    /// getAiProtectionEvent.asp's count for this protection.
    public let blocked: Int?
    public let devices: [AiProtectionDeviceHits]
    public let chart: AiProtectionChart?
    public let chartEnd: Date
    /// Newest first.
    public let groups: [AiProtectionEventGroup]
    public var isOn: Bool { masterEnabled && featureEnabled }
}

extension RouterParser {
    /// `event_count = {"mals_n":"3","vp_n":"0","cc_n":"1"}`.
    public static func aiProtectionCounts(_ source: String) throws -> [AiProtectionKind: Int] {
        guard let range = source.range(of: #"\bevent_count\s*=\s*\{"#, options: .regularExpression), let start = source[range].lastIndex(of: "{"),
              let literal = balanced(source, from: start, open: "{", close: "}"),
              let values = try? JSONSerialization.jsonObject(with: Data(literal.utf8)) as? [String: Any] else { throw RouterError.invalidResponse("AiProtection 拦截次数") }
        var counts: [AiProtectionKind: Int] = [:]
        for kind in AiProtectionKind.allCases {
            if let text = string(values[kind.countKey]) {
                guard let count = Int(text), count >= 0 else { throw RouterError.invalidResponse("AiProtection 拦截次数") }
                counts[kind] = count
            }
        }
        return counts
    }

    /// `data = '[["AA:BB:CC:DD:EE:01","4"], …]'`, the hits per device; most hits first, like the page's ranking.
    public static func aiProtectionDevices(_ source: String) throws -> [AiProtectionDeviceHits] {
        guard let value = try quotedData(source, label: "AiProtection 设备记录") else { return [] }
        guard let rows = value as? [[Any]] else { throw RouterError.invalidResponse("AiProtection 设备记录") }
        let hits = try rows.map { row -> AiProtectionDeviceHits in
            guard row.count >= 2, let device = string(row[0]), let text = string(row[1]), let count = Int(text), count >= 0 else { throw RouterError.invalidResponse("AiProtection 设备记录") }
            return AiProtectionDeviceHits(device: isMAC(device) ? device.uppercased() : device, hits: count)
        }
        return hits.enumerated().sorted { $0.element.hits != $1.element.hits ? $0.element.hits > $1.element.hits : $0.offset < $1.offset }.map(\.element)
    }

    /// `data = '[[high×7], [medium×7], [low×7]]'` (collectChart(), which reads the three without checking they exist).
    public static func aiProtectionChart(_ source: String) throws -> AiProtectionChart? {
        guard let value = try quotedData(source, label: "AiProtection 统计图") else { return nil }
        guard let series = value as? [[Any]], !series.isEmpty else { throw RouterError.invalidResponse("AiProtection 统计图") }
        func counts(_ list: [Any]) throws -> [Int] {
            try list.map { item in
                guard let text = string(item), let count = Int(text), count >= 0 else { throw RouterError.invalidResponse("AiProtection 统计图") }
                return count
            }
        }
        return AiProtectionChart(high: try counts(series[0]), medium: series.count > 1 ? try counts(series[1]) : [],
                                 low: series.count > 2 ? try counts(series[2]) : [])
    }

    /// `data = '[[time, …], …]'`. 双向 IPS rows are [time, severity, source, destination, threat, direction, …, category]
    /// (getIPSDetailData() 349–380); the other two pages' rows are [time, category, source, destination] (CSV header
    /// "Time,Threat,Source,Destination").
    public static func aiProtectionEvents(_ source: String, kind: AiProtectionKind) throws -> [AiProtectionEvent] {
        guard let value = try quotedData(source, label: "AiProtection 事件记录") else { return [] }
        guard let rows = value as? [[Any]], rows.count <= 50_000 else { throw RouterError.invalidResponse("AiProtection 事件记录") }
        return try rows.map { row in
            func text(_ index: Int) -> String { index < row.count ? (string(row[index]) ?? "") : "" }
            guard row.count >= (kind == .intrusionPrevention ? 6 : 4), !text(0).isEmpty else { throw RouterError.invalidResponse("AiProtection 事件记录") }
            if kind == .intrusionPrevention {
                return AiProtectionEvent(time: text(0), source: text(2), destination: text(3), severity: text(1), threat: text(4),
                                         direction: Int(text(5)), category: row.count > 7 ? text(7) : nil)
            }
            return AiProtectionEvent(time: text(0), source: text(2), destination: text(3), category: text(1))
        }
    }

    /// The page's rows: events grouped by its key, the group shown by its first event, newest first. The IPS page sorts
    /// this way (getIPSDetailData() 382–405); the other two pages keep the router's order, and this app sorts them alike.
    public static func aiProtectionGroups(_ events: [AiProtectionEvent], kind: AiProtectionKind) -> [AiProtectionEventGroup] {
        var order: [String] = []
        var groups: [String: [AiProtectionEvent]] = [:]
        for event in events {
            let key = kind == .intrusionPrevention
                ? (event.threat ?? "").components(separatedBy: " ")[0] + "_" + event.destination
                : event.destination + "_" + event.source
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(event)
        }
        return order.enumerated().sorted { a, b in
            let x = groups[a.element]![0].timeParts, y = groups[b.element]![0].timeParts
            return x != y ? x.lexicographicallyPrecedes(y) == false : a.offset < b.offset
        }.map { AiProtectionEventGroup(id: $0.element, events: groups[$0.element]!) }
    }

    /// The JSON inside `data = '…';`, or nil when the router has nothing to report (`data = '';`).
    static func quotedData(_ source: String, label: String) throws -> Any? {
        guard let body = capture(#"(?s)\bdata\s*=\s*'(.*)'\s*;"#, in: source) else { throw RouterError.invalidResponse(label) }
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        guard text.utf8.count <= 8_000_000, let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { throw RouterError.invalidResponse(label) }
        return value
    }
    public static func isMAC(_ text: String) -> Bool {
        text.range(of: #"^(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$"#, options: .regularExpression) != nil
    }
}

extension RouterClient {
    /// What one protection's page reads when it opens.
    public func aiProtectionRecords(_ kind: AiProtectionKind, now: Date = .now) async throws -> AiProtectionRecords {
        let settings = try await readSettings(["wrs_protect_enable", kind.enableKey, kind.sinceKey])
        let counts = try RouterParser.aiProtectionCounts(try await readDataPage(.protectionCounts))
        let devices = try RouterParser.aiProtectionDevices(try await readDataPage(.protectionEvents, [("type", kind.rawValue), ("event", "mac")]))
        let chart = try RouterParser.aiProtectionChart(try await readDataPage(kind.chartPage, [("type", kind.rawValue), ("date", String(Int(now.timeIntervalSince1970)))]))
        let events = try RouterParser.aiProtectionEvents(try await readDataPage(.protectionEventDetails, [("type", kind.rawValue), ("event", "all")]), kind: kind)
        let since = settings[kind.sinceKey].flatMap(TimeInterval.init).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        return AiProtectionRecords(kind: kind, masterEnabled: settings["wrs_protect_enable"] == "1", featureEnabled: settings[kind.enableKey] == "1",
                                   since: since, blocked: counts[kind], devices: devices, chart: chart, chartEnd: now,
                                   groups: RouterParser.aiProtectionGroups(events, kind: kind))
    }
}
