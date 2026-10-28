import Foundation

public enum InternetState: String, Sendable {
    case online, offline, unknown
    public var title: String {
        switch self { case .online: "互联网在线"; case .offline: "互联网未连接"; case .unknown: "互联网状态未知" }
    }
}

public struct RouterIdentity: Sendable, Equatable {
    public var model: String
    public var firmware: String
    public var lanAddress: String?
    public var wanAddress: String?
    public var hardwareAddress: String?
    public init(model: String, firmware: String, lanAddress: String?, wanAddress: String?, hardwareAddress: String? = nil) {
        self.model = model; self.firmware = firmware; self.lanAddress = lanAddress; self.wanAddress = wanAddress
        self.hardwareAddress = hardwareAddress
    }
}

public struct RouterDevice: Identifiable, Sendable, Equatable {
    public let mac: String
    public let name: String
    public let ip: String?
    public let vendor: String?
    public let isOnline: Bool
    public let band: Int?
    public let rssi: Int?
    public let txLinkMbps: Double?
    public let rxLinkMbps: Double?
    public let connectionTime: String?
    public let internetAllowed: Bool?
    public let isCurrentDevice: Bool
    public let ssid: String?
    public let deviceDescription: String?
    public var id: String { mac }
    public var connectionLabel: String {
        switch band { case 0: "有线"; case 1: "2.4 GHz"; case 2: "5 GHz"; case 3: "5 GHz-2"; case 4: "6 GHz"; default: "未知连接" }
    }
    public var classification: DeviceClassification { DeviceClassifier.classify(name: name, vendor: vendor, description: deviceDescription) }
    public var symbol: String { classification.kind.symbol }
}

public struct CPUTicks: Sendable, Equatable {
    public let total: UInt64
    public let used: UInt64
    public init(total: UInt64, used: UInt64) { self.total = total; self.used = used }
}

public struct TrafficCounters: Sendable, Equatable {
    public let received: UInt64
    public let sent: UInt64
    public init(received: UInt64, sent: UInt64) { self.received = received; self.sent = sent }
}

public struct RouterSample: Sendable {
    public var identity: RouterIdentity
    public var internet: InternetState
    public var devices: [RouterDevice]?
    public var cpu: [String: CPUTicks]?
    public var memoryUsedKiB: Double?
    public var memoryTotalKiB: Double?
    public var traffic: TrafficCounters?
    public var uptime: TimeInterval?
    public var sampledAt: Date
    public var monotonicTime: TimeInterval
    public var unavailable: [String]
    public init(identity: RouterIdentity, internet: InternetState = .unknown, devices: [RouterDevice]? = nil,
                cpu: [String: CPUTicks]? = nil, memoryUsedKiB: Double? = nil, memoryTotalKiB: Double? = nil,
                traffic: TrafficCounters? = nil, uptime: TimeInterval? = nil,
                sampledAt: Date = Date(), monotonicTime: TimeInterval = ProcessInfo.processInfo.systemUptime,
                unavailable: [String] = []) {
        self.identity = identity; self.internet = internet; self.devices = devices; self.cpu = cpu
        self.memoryUsedKiB = memoryUsedKiB; self.memoryTotalKiB = memoryTotalKiB; self.traffic = traffic
        self.uptime = uptime; self.sampledAt = sampledAt; self.monotonicTime = monotonicTime; self.unavailable = unavailable
    }
}

public struct RouterSnapshot: Sendable {
    public var sample: RouterSample
    public var cpuPercent: Double?
    public var downloadBytesPerSecond: Double?
    public var uploadBytesPerSecond: Double?
    public var onlineDevices: [RouterDevice]? { sample.devices?.filter(\.isOnline) }
    public var memoryPercent: Double? {
        guard let used = sample.memoryUsedKiB, let total = sample.memoryTotalKiB, total > 0 else { return nil }
        return used / total * 100
    }
}

public struct MetricCalculator: Sendable {
    private var previous: RouterSample?
    public init() {}
    public mutating func reset() { previous = nil }
    public mutating func consume(_ sample: RouterSample) -> RouterSnapshot {
        defer { previous = sample }
        var snapshot = RouterSnapshot(sample: sample)
        guard let old = previous, old.identity == sample.identity else { return snapshot }
        let elapsed = sample.monotonicTime - old.monotonicTime
        guard elapsed > 0, elapsed < 180,
              !(sample.uptime != nil && old.uptime != nil && sample.uptime! < old.uptime!) else { return snapshot }
        if let a = old.traffic, let b = sample.traffic, b.received >= a.received, b.sent >= a.sent {
            snapshot.downloadBytesPerSecond = Double(b.received - a.received) / elapsed
            snapshot.uploadBytesPerSecond = Double(b.sent - a.sent) / elapsed
        }
        if let a = old.cpu, let b = sample.cpu, !b.isEmpty, Set(a.keys) == Set(b.keys) {
            var totals = 0.0, used = 0.0
            for (key, value) in b {
                guard let prev = a[key], value.total >= prev.total, value.used >= prev.used else { return snapshot }
                totals += Double(value.total - prev.total); used += Double(value.used - prev.used)
            }
            if totals > 0, used <= totals { snapshot.cpuPercent = used / totals * 100 }
        }
        return snapshot
    }
}
