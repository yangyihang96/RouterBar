import Foundation
import CoreFoundation

public struct DeviceTrafficCounters: Sendable, Equatable {
    public let upload: UInt64
    public let download: UInt64
    public init(upload: UInt64, download: UInt64) { self.upload = upload; self.download = download }
}
public struct DeviceTrafficReading: Sendable {
    public let source: String
    public let counters: [String: DeviceTrafficCounters]
    /// The router's own counters from the same page, when it reports them.
    public let router: DeviceTrafficCounters?
    public let date: Date
    public let monotonic: TimeInterval
    public init(source: String, counters: [String: DeviceTrafficCounters], router: DeviceTrafficCounters? = nil, date: Date = .now, monotonic: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.source = source; self.counters = counters; self.router = router; self.date = date; self.monotonic = monotonic
    }
}
public struct DeviceTrafficRate: Identifiable, Sendable, Equatable {
    public var id: String { mac }
    public let mac: String
    public let upload: Double
    public let download: Double
    public let date: Date
}
public struct DeviceTrafficCalculator: Sendable {
    /// Router counters advance in steps; two reads moments apart would turn one step into a spike.
    public static let minimumInterval: TimeInterval = 3
    private var previous: DeviceTrafficReading?
    public init() {}
    public mutating func reset() { previous = nil }
    /// Such a read is skipped and the earlier baseline kept, so the next rate covers a longer interval.
    public func isTooSoon(_ reading: DeviceTrafficReading) -> Bool {
        guard let previous, previous.source == reading.source else { return false }
        let elapsed = reading.monotonic - previous.monotonic
        return elapsed > 0 && elapsed < Self.minimumInterval
    }
    public mutating func consume(_ reading: DeviceTrafficReading) -> [String: DeviceTrafficRate] {
        defer { previous = reading }
        guard let previous, previous.source == reading.source else { return [:] }
        let elapsed = reading.monotonic - previous.monotonic
        guard elapsed > 0, elapsed <= 150 else { return [:] }
        var rates: [String: DeviceTrafficRate] = [:]
        for (mac, counter) in reading.counters {
            guard let before = previous.counters[mac], counter.upload >= before.upload, counter.download >= before.download else { continue }
            rates[mac] = .init(mac: mac, upload: Double(counter.upload - before.upload) / elapsed,
                download: Double(counter.download - before.download) / elapsed, date: reading.date)
        }
        return rates
    }
}
public enum DeviceTrafficParser {
    public static func parse(_ source: String) throws -> [String: DeviceTrafficCounters] {
        guard source.utf8.count <= 2_000_000,
              let range = source.range(of: #"\barray_traffic\s*=\s*\["#, options: .regularExpression),
              let start = source[range].lastIndex(of: "[") else { throw RouterError.invalidResponse("单设备流量") }
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
                    guard let rows = try JSONSerialization.jsonObject(with: Data(source[start...index].utf8)) as? [[Any]], rows.count <= 4096 else { throw RouterError.invalidResponse("单设备流量数组") }
                    var result: [String: DeviceTrafficCounters] = [:]
                    for row in rows {
                        guard row.count >= 3, let mac = row[0] as? String,
                              mac.range(of: #"^(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$"#, options: .regularExpression) != nil,
                              let up = unsigned(row[1]), let down = unsigned(row[2]), result[mac.uppercased()] == nil else { throw RouterError.invalidResponse("单设备流量计数") }
                        result[mac.uppercased()] = .init(upload: up, download: down)
                    }
                    return result
                }
            }
        }
        throw RouterError.invalidResponse("单设备流量数组")
    }
    private static func unsigned(_ value: Any) -> UInt64? {
        let text: String
        if let string = value as? String { text = string }
        else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { text = number.stringValue }
        else { return nil }
        guard text.range(of: #"^\d+$"#, options: .regularExpression) != nil else { return nil }
        return UInt64(text)
    }
}
extension RouterClient {
    public func deviceTraffic() async throws -> DeviceTrafficReading {
        let paths = preferredTrafficPath.map { [$0] } ?? ["getTraffic.asp", "getTraffic_Dns.asp"]
        var empty: DeviceTrafficReading?
        for path in paths {
            do {
                let text = String(decoding: try await request(path, timeout: 5), as: UTF8.self)
                let counters = try DeviceTrafficParser.parse(text)
                let reading = DeviceTrafficReading(source: path, counters: counters, router: DeviceTrafficParser.routerTotal(text))
                if !counters.isEmpty { preferredTrafficPath = path; return reading }
                empty = reading
            } catch RouterError.authenticationRequired { throw RouterError.authenticationRequired }
            catch is CancellationError { throw CancellationError() }
            catch { continue }
        }
        if let empty { return empty }
        preferredTrafficPath = nil
        throw RouterError.invalidResponse("路由器未提供可用的单设备流量计数")
    }
}
