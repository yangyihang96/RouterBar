import Foundation

// Traffic Analyzer › 流量监控: the router's per-interface counters (update.cgi netdev) and the history its
// rstats service keeps (Main_TrafficMonitor_last24.asp and Main_TrafficMonitor_daily.asp). Read only.

/// rstats interface keys: INTERNET (INTERNET1 for the second WAN), WIRED, BRIDGE, WIRELESS0…3 and bond members.
public enum TrafficInterface {
    /// The tab title tmcal.js gives the interface, or nil for what the web hides (BRIDGE, virtual radios).
    /// `wanTypes` is `wans_dualwan` split, e.g. ["wan", "none"]; `radioBands` are titles by radio unit.
    public static func title(_ key: String, wanTypes: [String], lanPort: String?, radioBands: [Int: String]) -> String? {
        switch key {
        case "WIRED": return "有线连接"
        case "BRIDGE": return nil
        case "INTERNET", "INTERNET1":
            let second = key == "INTERNET1"
            guard let type = wanTypes.dropFirst(second ? 1 : 0).first else { return second ? "第二 WAN" : "互联网" }
            switch type {
            case "usb": return "USB Modem"
            case "wan": return "WAN"
            case "wan2": return "WAN2"
            case "lan": return "LAN Port " + (lanPort ?? "")
            case "dsl" where !second: return "DSL WAN"
            case "sfp+": return "10G SFP+"
            default: return second ? "第二 WAN" : "首选 WAN"
            }
        default: break
        }
        if key.hasPrefix("WIRELESS") {
            guard !key.contains("."), let unit = Int(key.dropFirst("WIRELESS".count)) else { return nil }
            let band = radioBands[unit] ?? (unit == 3 ? "60 GHz" : RouterRadioBands.fallback[unit] ?? "wl\(unit)")
            return "无线连接 (" + band.replacingOccurrences(of: " GHz", with: "GHz") + ")"
        }
        if key.hasPrefix("WAGGR"), let port = Int(key.dropFirst(5)) {
            switch port {
            case 0: return "bond-slave (WAN)"
            case 1...8: return "bond-slave (LAN Port \(port))"
            case 30: return "bond-slave (10G base-T)"
            case 31: return "bond-slave (10G SFP+)"
            default: return nil
            }
        }
        if key.hasPrefix("LACPW") { return "bond-slave (WAN\(key.dropFirst(5)))" }
        if key.hasPrefix("LACP") { return "bond-slave (LAN Port \(key.dropFirst(4)))" }
        return key
    }
    /// The web's tab order: WANs, wired, then radios by unit.
    public static func order(_ key: String) -> Int {
        if key == "INTERNET" { return 0 }
        if key == "INTERNET1" { return 1 }
        if key.hasPrefix("WAGGR") { return 2 }
        if key == "WIRED" { return 3 }
        if key.hasPrefix("LACPW") { return 4 }
        if key.hasPrefix("LACP") { return 5 }
        if key.hasPrefix("WIRELESS") { return 6 + (Int(key.dropFirst(8)) ?? 9) }
        return 20
    }
    /// On a WAN, received is downloaded and sent is uploaded.
    public static func isWAN(_ key: String) -> Bool { key.hasPrefix("INTERNET") || key.hasPrefix("WAGGR") || key.hasPrefix("LACPW") }

    /// Bytes moved between two readings of one counter. The router's counters can be 32-bit and wrap, as the web
    /// allows for; a drop that a wrap cannot explain is a reset, and gives no reading.
    public static func delta(from old: UInt64, to new: UInt64) -> UInt64? {
        if new >= old { return new - old }
        guard old <= 0xFFFF_FFFF else { return nil }
        return (0x1_0000_0000 - old) + new
    }
}

/// Per-interface rates from successive counter readings, as the web's 即时流量图 draws them while it is open.
public struct TrafficRateWindow: Sendable {
    public struct Point: Sendable, Equatable, Identifiable {
        public let id: Int
        public let date: Date
        /// Bytes per second.
        public let received: Double
        public let sent: Double
        /// Points of different segments are not joined: a gap in reading breaks the line.
        public let segment: Int
    }
    public struct Summary: Sendable, Equatable {
        /// Bytes per second.
        public let currentReceived, currentSent, averageReceived, averageSent, peakReceived, peakSent: Double
        /// Bytes since the page started reading.
        public let totalReceived, totalSent: UInt64
    }
    public let capacity: Int
    /// A pause longer than this starts a new segment instead of averaging across it.
    public let maximumGap: TimeInterval
    /// Bytes per second no interface can reach (the router's fastest port is 10 Gbit/s): a counter that was
    /// reset, as when an interface restarts, would otherwise read as a huge burst.
    public let maximumRate: Double
    public private(set) var points: [String: [Point]] = [:]
    private struct Totals { var received: UInt64 = 0, sent: UInt64 = 0, seconds = 0.0, peakReceived = 0.0, peakSent = 0.0 }
    private var totals: [String: Totals] = [:]
    private var last: [String: TrafficCounters] = [:]
    private var lastTime: TimeInterval?
    private var nextID = 0, segment = 0

    public init(capacity: Int = 300, maximumGap: TimeInterval = 20, maximumRate: Double = 1.25e9) {
        self.capacity = capacity; self.maximumGap = maximumGap; self.maximumRate = maximumRate
    }

    /// `time` is monotonic (system uptime), so a clock change cannot fake a rate.
    public mutating func consume(_ counters: [String: TrafficCounters], at time: TimeInterval, date: Date) {
        defer { last = counters; lastTime = time }
        guard let previous = lastTime, time > previous else { return }
        let elapsed = time - previous
        guard elapsed <= maximumGap else { segment += 1; return }
        for (key, now) in counters {
            guard let old = last[key], let received = TrafficInterface.delta(from: old.received, to: now.received),
                  let sent = TrafficInterface.delta(from: old.sent, to: now.sent),
                  Double(received) / elapsed <= maximumRate, Double(sent) / elapsed <= maximumRate else { continue }
            nextID += 1
            let point = Point(id: nextID, date: date, received: Double(received) / elapsed, sent: Double(sent) / elapsed, segment: segment)
            var list = points[key] ?? []
            list.append(point)
            if list.count > capacity { list.removeFirst(list.count - capacity) }
            points[key] = list
            var sum = totals[key] ?? Totals()
            sum.received += received; sum.sent += sent; sum.seconds += elapsed
            sum.peakReceived = max(sum.peakReceived, point.received); sum.peakSent = max(sum.peakSent, point.sent)
            totals[key] = sum
        }
    }
    /// Figures since the page started reading; the chart keeps the last `capacity` points.
    public func summary(for key: String) -> Summary? {
        guard let current = points[key]?.last, let sum = totals[key], sum.seconds > 0 else { return nil }
        return Summary(currentReceived: current.received, currentSent: current.sent,
                       averageReceived: Double(sum.received) / sum.seconds, averageSent: Double(sum.sent) / sum.seconds,
                       peakReceived: sum.peakReceived, peakSent: sum.peakSent, totalReceived: sum.received, totalSent: sum.sent)
    }
}

/// The last 24 hours of one interface as rstats keeps it: bytes per 30-second sample, oldest first.
public struct TrafficHistory: Sendable, Equatable {
    public static let sampleSeconds: Double = 30
    public let received: [UInt64]
    public let sent: [UInt64]
    /// What the router reports alongside the samples, in bytes per sample (avg, max) and bytes (total).
    public let receivedAverage, receivedPeak, receivedTotal, sentAverage, sentPeak, sentTotal: Double?
}

extension TrafficHistory {
    /// Rates and totals over the last `count` samples, as the web recomputes them when fewer hours are shown.
    public func summary(lastSamples count: Int) -> TrafficRateWindow.Summary? {
        let rx = received.suffix(count), tx = sent.suffix(count)
        guard let lastRX = rx.last, let lastTX = tx.last else { return nil }
        let totalRX = rx.reduce(0, +), totalTX = tx.reduce(0, +)
        return .init(currentReceived: Double(lastRX) / Self.sampleSeconds, currentSent: Double(lastTX) / Self.sampleSeconds,
                     averageReceived: Double(totalRX) / (Double(rx.count) * Self.sampleSeconds),
                     averageSent: Double(totalTX) / (Double(tx.count) * Self.sampleSeconds),
                     peakReceived: Double(rx.max() ?? 0) / Self.sampleSeconds, peakSent: Double(tx.max() ?? 0) / Self.sampleSeconds,
                     totalReceived: totalRX, totalSent: totalTX)
    }
    /// The last `count` samples as rates, averaged into at most `limit` points so a day stays quick to draw.
    /// The newest sample ends at `end`.
    public func points(lastSamples count: Int, limit: Int, end: Date) -> [TrafficRateWindow.Point] {
        let rx = Array(received.suffix(count)), tx = Array(sent.suffix(count))
        let n = min(rx.count, tx.count)
        guard n > 0, limit > 0 else { return [] }
        let size = max(1, Int((Double(n) / Double(limit)).rounded(.up)))
        return stride(from: 0, to: n, by: size).enumerated().map { index, start in
            let range = start..<min(start + size, n)
            let seconds = Double(range.count) * Self.sampleSeconds
            let date = end.addingTimeInterval(-Double(n - range.upperBound) * Self.sampleSeconds)
            return .init(id: index, date: date, received: Double(rx[range].reduce(0, +)) / seconds, sent: Double(tx[range].reduce(0, +)) / seconds, segment: 0)
        }
    }
}

/// A day (or a month, with `day` 0) of rstats history, in KiB as the web's tables count them.
public struct TrafficRecord: Sendable, Equatable, Identifiable {
    public let year: Int
    /// 1…12.
    public let month: Int
    public let day: Int
    public let receivedKiB: UInt64
    public let sentKiB: UInt64
    public var id: Int { year * 10_000 + month * 100 + day }
    public var totalKiB: UInt64 { receivedKiB + sentKiB }
    public init(year: Int, month: Int, day: Int, receivedKiB: UInt64, sentKiB: UInt64) {
        self.year = year; self.month = month; self.day = day; self.receivedKiB = receivedKiB; self.sentKiB = sentKiB
    }
    /// rstats packs dates as ((year - 1900) << 16) | (zero-based month << 8) | day.
    init?(packed row: [UInt64]) {
        guard row.count >= 3 else { return nil }
        let date = row[0]
        let year = Int((date >> 16) & 0xFF) + 1900, month = Int((date >> 8) & 0xFF) + 1, day = Int(date & 0xFF)
        guard (1...12).contains(month), (0...31).contains(day) else { return nil }
        self.init(year: year, month: month, day: day, receivedKiB: row[1], sentKiB: row[2])
    }
}

public struct TrafficRecords: Sendable, Equatable {
    /// Newest first, as the web's tables list them.
    public var daily: [TrafficRecord]
    public var monthly: [TrafficRecord]
    public init(daily: [TrafficRecord] = [], monthly: [TrafficRecord] = []) { self.daily = daily; self.monthly = monthly }
}

extension RouterParser {
    /// Every interface's cumulative counters from `update.cgi?output=netdev`.
    public static func interfaceCounters(_ source: String) throws -> [String: TrafficCounters] {
        var counters: [String: TrafficCounters] = [:]
        for match in captures(#"['"]([A-Za-z0-9_.]+)['"]\s*:\s*\{\s*rx\s*:\s*(0x[0-9a-fA-F]+|\d+)\s*,\s*tx\s*:\s*(0x[0-9a-fA-F]+|\d+)\s*\}"#, in: source) {
            if let rx = counter(match[1]), let tx = counter(match[2]) { counters[match[0]] = TrafficCounters(received: rx, sent: tx) }
        }
        guard !counters.isEmpty else { throw RouterError.invalidResponse("接口流量") }
        return counters
    }

    /// `speed_history = {'INTERNET': {rx: […], rx_avg: …, …}, …}` as the 24-hour page embeds it.
    public static func trafficHistory(_ source: String) throws -> [String: TrafficHistory] {
        let literals = assignments(of: "speed_history", open: "{", close: "}", in: source)
        guard let literal = literals.first(where: { $0.contains("rx") }) ?? literals.first else { throw RouterError.invalidResponse("流量历史") }
        let body = String(literal)
        var history: [String: TrafficHistory] = [:]
        for key in captures(#"['"]([A-Za-z0-9_.]+)['"]\s*:\s*\{"#, in: body).map({ $0[0] }) {
            guard let keyRange = body.range(of: #"['"]"# + NSRegularExpression.escapedPattern(for: key) + #"['"]\s*:\s*\{"#, options: .regularExpression),
                  let open = body[keyRange].lastIndex(of: "{"), let entry = balanced(body, from: open, open: "{", close: "}").map(String.init) else { continue }
            func samples(_ name: String) -> [UInt64]? {
                capture("\\b" + name + #"\s*:\s*\[([^\]]*)\]"#, in: entry).map { list in
                    list.split(separator: ",").compactMap { counter($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                }
            }
            func number(_ name: String) -> Double? { capture("\\b" + name + #"\s*:\s*([0-9.]+)"#, in: entry).flatMap(Double.init) }
            guard let rx = samples("rx"), let tx = samples("tx") else { continue }
            history[key] = TrafficHistory(received: rx, sent: tx, receivedAverage: number("rx_avg"), receivedPeak: number("rx_max"),
                                          receivedTotal: number("rx_total"), sentAverage: number("tx_avg"), sentPeak: number("tx_max"), sentTotal: number("tx_total"))
        }
        return history
    }

    /// `daily_history` and `monthly_history`, which the daily and monthly pages both embed.
    public static func trafficRecords(_ source: String) throws -> TrafficRecords {
        let daily = try numberRows(named: "daily_history", in: source).compactMap(TrafficRecord.init(packed:))
        let monthly = ((try? numberRows(named: "monthly_history", in: source)) ?? []).compactMap(TrafficRecord.init(packed:))
        return TrafficRecords(daily: daily.sorted { $0.id > $1.id }, monthly: monthly.sorted { $0.id > $1.id })
    }
}

extension RouterClient {
    public func interfaceCounters() async throws -> [String: TrafficCounters] {
        try RouterParser.interfaceCounters(String(decoding: try await request("update.cgi", query: [.init(name: "output", value: "netdev")]), as: UTF8.self))
    }
    /// rstats history is kept only while 流量监控 history is switched on (`rstats_enable`).
    public func trafficHistoryEnabled() async throws -> Bool {
        try await readSettings(["rstats_enable"])["rstats_enable"] == "1"
    }
    public func trafficHistory() async throws -> [String: TrafficHistory] {
        try RouterParser.trafficHistory(try await readManagementDocument("Main_TrafficMonitor_last24.asp"))
    }
    public func trafficRecords() async throws -> TrafficRecords {
        try RouterParser.trafficRecords(try await readManagementDocument("Main_TrafficMonitor_daily.asp"))
    }
}
