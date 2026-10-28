import Foundation

/// A chart window includes only uninterrupted, valid samples for each device.
public struct DeviceTrafficWindow: Sendable {
    public private(set) var rates: [String: DeviceTrafficRate] = [:]
    public private(set) var history: [String: [DeviceTrafficRate]] = [:]
    private var calculator = DeviceTrafficCalculator()
    private let limit: Int
    public init(limit: Int = 60) { self.limit = max(1, limit) }
    public mutating func reset() { calculator.reset(); rates = [:]; history = [:] }
    public mutating func consume(_ reading: DeviceTrafficReading, online: Set<String>) {
        guard !calculator.isTooSoon(reading) else { return }
        rates = calculator.consume(reading).filter { online.contains($0.key) }
        history = history.filter { rates[$0.key] != nil }
        for (mac, rate) in rates {
            var points = history[mac] ?? []
            // A wall-clock adjustment must not create duplicate points or a line going backwards.
            if let last = points.last, rate.date <= last.date { points = [] }
            points.append(rate)
            history[mac] = Array(points.suffix(limit))
        }
    }
}

public enum DeviceSortOrder: String, CaseIterable, Sendable {
    case name, download, upload, weakSignal
    public var title: String {
        switch self { case .name: "设备名称"; case .download: "下载最多"; case .upload: "上传最多"; case .weakSignal: "信号最弱" }
    }
    public func sorted(_ devices: [RouterDevice], rates: [String: DeviceTrafficRate]) -> [RouterDevice] {
        func value(_ device: RouterDevice) -> Double? {
            switch self {
            case .name: nil
            case .download: rates[device.mac]?.download
            case .upload: rates[device.mac]?.upload
            case .weakSignal: device.isOnline && (device.band ?? 0) > 0 ? device.rssi.map { -Double($0) } : nil
            }
        }
        return devices.sorted { a, b in
            let x = value(a), y = value(b)
            if let x, let y, x != y { return x > y }
            if x != nil && y == nil { return true }
            if x == nil && y != nil { return false }
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? a.mac < b.mac : order == .orderedAscending
        }
    }
}
