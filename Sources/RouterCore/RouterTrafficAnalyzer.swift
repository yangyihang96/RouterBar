import Foundation

// Traffic Analyzer › 统计数值 (TrafficAnalyzer_Statistic.asp), Adaptive QoS › 带宽监控 (AdaptiveQoS_Bandwidth_Monitor.asp) and
// 网页浏览历史 (AdaptiveQoS_WebHistory.asp), 流量监控 › Monitoring Settings (Main_TrafficMonitor_settings.asp) and AiCloud › 日志
// (cloud_syslog.asp), Asuswrt-Merlin 3006.102.5: what the pages read. Their switches are only reported, never changed.

/// The switches that decide what these pages show. With `dns_dpi` the web uses the `_Dns` data pages and the dns_dpi
/// switches (state.js 653, decide_dns_or_bwdpi()); without it, the Trend Micro engine's switches and agreement.
public struct TrafficAnalyzerSwitches: Sendable, Equatable {
    public let dnsBased: Bool
    /// 统计数值's switch: `dns_dpi_trf_analysis`, or `bwdpi_db_enable`.
    public let statistics: Bool
    /// 带宽监控's 应用程序分析: `dns_dpi_apps_analysis`, or `apps_analysis`; the page lists a device's apps only when on.
    public let appAnalysis: Bool
    /// 网页浏览历史's switch `bwdpi_wh_enable`.
    public let webHistory: Bool
    /// The Trend Micro agreement (`TM_EULA`), which turning on the engine's features asks for.
    public let trendMicroAgreed: Bool
    public init(dnsBased: Bool, values: [String: String]) {
        self.dnsBased = dnsBased
        statistics = values[dnsBased ? "dns_dpi_trf_analysis" : "bwdpi_db_enable"] == "1"
        appAnalysis = values[dnsBased ? "dns_dpi_apps_analysis" : "apps_analysis"] == "1"
        webHistory = values["bwdpi_wh_enable"] == "1"
        trendMicroAgreed = values["TM_EULA"] == "1"
    }
    static let keys = ["dns_dpi_trf_analysis", "bwdpi_db_enable", "dns_dpi_apps_analysis", "apps_analysis", "bwdpi_wh_enable", "TM_EULA"]
}

/// 统计数值's 显示方式: the last 24 hours by hour, or the last 7 or 31 days by day (TrafficAnalyzer_Statistic.asp 960–975).
public enum TrafficStatisticsPeriod: String, CaseIterable, Sendable, Identifiable {
    case daily, weekly, monthly
    public var id: String { rawValue }
    public var title: String { switch self { case .daily: "每天"; case .weekly: "每周"; case .monthly: "每月" } }
    var duration: String { switch self { case .daily: "24"; case .weekly: "7"; case .monthly: "31" } }
    var chartMode: String { self == .daily ? "hour" : "day" }
    /// draw_flow() (1264 onwards; loops at 1275, 1326 and 1375) always draws 24, 7 or 31 points: entry i of the router's list is point i, oldest
    /// first, a missing entry counts as zero, and anything past the last point is not drawn.
    public var slots: Int { switch self { case .daily: 24; case .weekly: 7; case .monthly: 31 } }
}

/// Bytes sent and received, as the database counts them.
public struct TrafficVolume: Sendable, Equatable {
    public let upload: UInt64
    public let download: UInt64
    public var total: UInt64 { upload + download }
    public init(upload: UInt64, download: UInt64) { self.upload = upload; self.download = download }
}

/// A device (by MAC address) or an app (by the name the router gives it) and its traffic over the period.
public struct TrafficStatisticsItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let volume: TrafficVolume
}

public struct TrafficStatistics: Sendable, Equatable {
    public let period: TrafficStatisticsPeriod
    /// When the page asked; the last hour or day of the timeline is the one that holds it.
    public let end: Date
    /// `period.slots` entries, one per hour (每天) or day, oldest first, the way draw_flow() labels them.
    public let timeline: [TrafficVolume]
    /// Most traffic first.
    public let clients: [TrafficStatisticsItem]
    public let apps: [TrafficStatisticsItem]
}

/// One row of 网页浏览历史.
public struct WebHistoryEntry: Sendable, Equatable, Identifiable {
    public let id: Int
    public let device: String
    public let date: Date
    public let host: String
}

/// One page of 网页浏览历史 as the router sent it.
public struct WebHistoryPage: Sendable, Equatable {
    public let entries: [WebHistoryEntry]
    /// Rows before the page dropped repeats; getWebHistory() offers the next page when the router sent 50 (200–213).
    public let received: Int
    public var hasNextPage: Bool { received >= 50 }
}

/// 流量监控 › Monitoring Settings as the page shows it.
public struct TrafficMonitorSettings: Sendable, Equatable {
    public enum Location: Sendable, Equatable {
        case ram
        case custom(String)
        case nvram
    }
    /// From `rstats_path`: empty is RAM, "*nvram" is NVRAM, anything else a directory (set_rstats_location()).
    public let location: Location
    /// `rstats_stime`, in hours.
    public let saveHours: Int?
    /// `rstats_new`: create or reset the data files at the next save.
    public let resetFiles: Bool
    /// `rstats_offset`, 1–31.
    public let monthStartDay: Int?
    public init(values: [String: String]) {
        let path = values["rstats_path"] ?? ""
        location = path.isEmpty ? .ram : path == "*nvram" ? .nvram : .custom(path)
        saveHours = values["rstats_stime"].flatMap(Int.init)
        resetFiles = values["rstats_new"] == "1"
        monthStartDay = values["rstats_offset"].flatMap(Int.init)
    }
    static let keys = ["rstats_path", "rstats_stime", "rstats_new", "rstats_offset"]
}

/// Adaptive QoS › 带宽监控: each device's and the router's current rate, from two readings of the same counters.
public struct BandwidthSample: Sendable, Equatable {
    /// Most traffic first.
    public let devices: [DeviceTrafficRate]
    /// From `router_traffic`; nil when the router does not report it or the counter went back.
    public let router: DeviceTrafficRate?
    public let date: Date
}

public struct BandwidthMonitor: Sendable {
    private var calculator = DeviceTrafficCalculator()
    private var previous: DeviceTrafficReading?
    public init() {}
    public mutating func reset() { calculator.reset(); previous = nil }
    /// nil until there is an earlier reading to compare with, and for a reading that came too soon after it.
    /// A counter that went back (a restart or a wrap) gives no rate for that interval, as on the web page.
    public mutating func consume(_ reading: DeviceTrafficReading) -> BandwidthSample? {
        guard !calculator.isTooSoon(reading) else { return nil }
        let before = previous
        previous = reading
        let devices = calculator.consume(reading)
        guard let before, before.source == reading.source else { return nil }
        let elapsed = reading.monotonic - before.monotonic
        guard elapsed > 0, elapsed <= 150 else { return nil }
        var router: DeviceTrafficRate?
        if let old = before.router, let new = reading.router, new.upload >= old.upload, new.download >= old.download {
            router = DeviceTrafficRate(mac: "", upload: Double(new.upload - old.upload) / elapsed, download: Double(new.download - old.download) / elapsed, date: reading.date)
        }
        let sorted = devices.values.sorted { ($0.upload + $0.download, $1.mac) > ($1.upload + $1.download, $0.mac) }
        return BandwidthSample(devices: sorted, router: router, date: reading.date)
    }
}

extension RouterParser {
    /// `array_statistics = [[name, up, down], …]` from getAppTraffic or getWanTraffic in `detail` mode, most traffic first.
    public static func trafficStatisticsItems(_ source: String) throws -> [TrafficStatisticsItem] {
        try statisticsRows(source).map { row in
            guard row.count >= 3, let name = string(row[0]), let up = volume(row[1]), let down = volume(row[2]) else { throw RouterError.invalidResponse("统计数值") }
            return TrafficStatisticsItem(id: isMAC(name) ? name.uppercased() : name, volume: TrafficVolume(upload: up, download: down))
        }.enumerated().sorted { a, b in
            a.element.volume.total != b.element.volume.total ? a.element.volume.total > b.element.volume.total : a.offset < b.offset
        }.map(\.element)
    }
    /// `array_statistics = [[up, down], …]` from getWanTraffic in `hour` or `day` mode.
    public static func trafficTimeline(_ source: String) throws -> [TrafficVolume] {
        try statisticsRows(source).map { row in
            guard row.count >= 2, let up = volume(row[0]), let down = volume(row[1]) else { throw RouterError.invalidResponse("统计数值") }
            return TrafficVolume(upload: up, download: down)
        }
    }
    static func statisticsRows(_ source: String) throws -> [[Any]] {
        guard let range = source.range(of: #"\barray_statistics\s*=\s*\["#, options: .regularExpression), let start = source[range].lastIndex(of: "["),
              let literal = balanced(source, from: start, open: "[", close: "]"), literal.utf8.count <= 4_000_000,
              let rows = try? JSONSerialization.jsonObject(with: Data(literal.utf8)) as? [[Any]] else { throw RouterError.invalidResponse("统计数值") }
        return rows
    }
    /// A byte count. The page adds them as JavaScript numbers, exact only up to 2^53, so anything larger is not a count
    /// the page could show; refusing it also keeps every sum the app makes from overflowing.
    static func volume(_ value: Any) -> UInt64? {
        guard let text = string(value), text.range(of: #"^\d+$"#, options: .regularExpression) != nil, let count = UInt64(text), count <= 1 << 53 else { return nil }
        return count
    }

    /// `array_temp = [[mac, seconds, host], …]`, without the rows the page drops as repeats (parsingAjaxResult()).
    public static func webHistory(_ source: String) throws -> WebHistoryPage {
        guard let range = source.range(of: #"\barray_temp\s*=\s*\["#, options: .regularExpression), let start = source[range].lastIndex(of: "["),
              let literal = balanced(source, from: start, open: "[", close: "]"), literal.utf8.count <= 4_000_000,
              let rows = try? JSONSerialization.jsonObject(with: Data(literal.utf8)) as? [[Any]] else { throw RouterError.invalidResponse("网页浏览历史") }
        var entries: [WebHistoryEntry] = []
        var seen = Set<String>()
        for row in rows {
            guard row.count >= 3, let device = string(row[0]), let seconds = string(row[1]), let stamp = TimeInterval(seconds), let host = string(row[2]) else { throw RouterError.invalidResponse("网页浏览历史") }
            guard seen.insert(device + "\u{1F}" + seconds + "\u{1F}" + host.uppercased()).inserted else { continue }
            entries.append(WebHistoryEntry(id: entries.count, device: isMAC(device) ? device.uppercased() : device, date: Date(timeIntervalSince1970: stamp), host: host))
        }
        return WebHistoryPage(entries: entries, received: rows.count)
    }

    /// The text of cloud_syslog.asp's read-only box, which dumps the AiCloud server's two log files (web.c 2645–2650).
    public static func aiCloudLog(_ page: String) throws -> String {
        guard let body = capture(#"(?s)<textarea[^>]*\bid="textarea"[^>]*>(.*?)</textarea>"#, in: page) else { throw RouterError.invalidResponse("AiCloud 日志") }
        var text = body
        for (entity, value) in ["&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&#x27;": "'", "&amp;": "&"] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return text
    }
}

extension DeviceTrafficParser {
    /// `router_traffic = ["sent", "received"]`: the router's own counters on the same page (calculate_router_traffic()).
    public static func routerTotal(_ source: String) -> DeviceTrafficCounters? {
        guard let last = RouterParser.captures(#"\brouter_traffic\s*=\s*\[\s*"?(\d+)"?\s*,\s*"?(\d+)"?\s*\]"#, in: source).last,
              let up = UInt64(last[0]), let down = UInt64(last[1]) else { return nil }
        return DeviceTrafficCounters(upload: up, download: down)
    }
}

extension RouterClient {
    public func trafficAnalyzerSwitches() async throws -> TrafficAnalyzerSwitches {
        let support = try await uiCapabilities()
        return TrafficAnalyzerSwitches(dnsBased: !["", "0"].contains(support["dns_dpi"] ?? ""), values: try await readSettings(TrafficAnalyzerSwitches.keys))
    }
    /// What 统计数值 reads when it opens or the period changes: all devices, all apps and the router's timeline
    /// (get_every_client_data(), get_every_app_data(), get_wan_data()).
    public func trafficStatistics(_ period: TrafficStatisticsPeriod, dnsBased: Bool, now: Date = .now) async throws -> TrafficStatistics {
        let date = String(Int(now.timeIntervalSince1970))
        let clientsPage: RouterDataPage = dnsBased ? .clientStatisticsDNS : .clientStatistics
        let appsPage: RouterDataPage = dnsBased ? .appStatisticsDNS : .appStatistics
        let clients = try RouterParser.trafficStatisticsItems(try await readDataPage(clientsPage, [("client", "all"), ("mode", "detail"), ("dura", period.duration), ("date", date)]))
        let apps = try RouterParser.trafficStatisticsItems(try await readDataPage(appsPage, [("client", "all"), ("mode", "detail"), ("dura", period.duration), ("date", date)]))
        let points = try RouterParser.trafficTimeline(try await readDataPage(appsPage, [("client", "all"), ("mode", period.chartMode), ("dura", period.duration), ("date", date)]))
        let timeline = (0..<period.slots).map { $0 < points.count ? points[$0] : TrafficVolume(upload: 0, download: 0) }
        return TrafficStatistics(period: period, end: now, timeline: timeline, clients: clients, apps: apps)
    }
    /// The apps one device used over the period (get_client_used_app_data()).
    public func trafficStatistics(apps client: String, period: TrafficStatisticsPeriod, dnsBased: Bool, now: Date = .now) async throws -> [TrafficStatisticsItem] {
        guard RouterParser.isMAC(client) else { throw RouterError.validation("请选择一台设备") }
        let page: RouterDataPage = dnsBased ? .appStatisticsDNS : .appStatistics
        return try RouterParser.trafficStatisticsItems(try await readDataPage(page, [("client", client), ("mode", "detail"), ("dura", period.duration), ("date", String(Int(now.timeIntervalSince1970)))]))
    }
    /// One page of up to 50 entries in the router's order, as getWebHistory() asks for it.
    public func webHistory(page: Int) async throws -> WebHistoryPage {
        guard (1...10_000).contains(page) else { throw RouterError.validation("页码超出范围") }
        return try RouterParser.webHistory(try await readDataPage(.webHistory, [("client", "all"), ("page", String(page))]))
    }
    /// 带宽监控's counters from the page the web polls: getTraffic_Dns.asp when the router uses DNS DPI, getTraffic.asp
    /// otherwise (AdaptiveQoS_Bandwidth_Monitor.asp 541–545; update_device_tarffic() 1458, update_device_tarffic_Dns() 1473).
    public func bandwidthTraffic(dnsBased: Bool) async throws -> DeviceTrafficReading {
        let page: RouterDataPage = dnsBased ? .realtimeTrafficDNS : .realtimeTraffic
        let text = try await readDataPage(page)
        return DeviceTrafficReading(source: page.rawValue, counters: try DeviceTrafficParser.parse(text), router: DeviceTrafficParser.routerTotal(text))
    }
    public func trafficMonitorSettings() async throws -> TrafficMonitorSettings {
        TrafficMonitorSettings(values: try await readSettings(TrafficMonitorSettings.keys))
    }
    public func aiCloudLog() async throws -> String {
        try RouterParser.aiCloudLog(try await readManagementDocument("cloud_syslog.asp"))
    }
}
