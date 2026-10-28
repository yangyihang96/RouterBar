import Foundation

public enum HealthSeverity: String, Codable, Sendable { case good, attention, failed, unknown }
public struct HealthRelatedDevice: Identifiable, Codable, Sendable {
    public var id: String { mac }
    public let mac: String
    public let name: String
    public let kind: DeviceKind
    public let detail: String
    public init(mac: String, name: String, kind: DeviceKind, detail: String) {
        self.mac = mac; self.name = name; self.kind = kind; self.detail = detail
    }
}
public struct HealthCheck: Identifiable, Codable, Sendable {
    public let id: String
    public let title: String
    public let severity: HealthSeverity
    public let summary: String
    public let advice: String
    public var evidence: String = ""
    public var relatedDevices: [HealthRelatedDevice]?
    public init(id: String, title: String, severity: HealthSeverity, summary: String, advice: String = "", evidence: String = "", relatedDevices: [HealthRelatedDevice] = []) {
        self.id = id; self.title = title; self.severity = severity; self.summary = summary; self.advice = advice; self.evidence = evidence
        self.relatedDevices = relatedDevices.isEmpty ? nil : relatedDevices
    }
}
public struct NetworkHealthReport: Identifiable, Codable, Sendable {
    public var id = UUID()
    public let startedAt: Date
    public var completedAt: Date?
    public var canceled = false
    public var checks: [HealthCheck] = []
    public init(startedAt: Date = .now) { self.startedAt = startedAt }
    public var severity: HealthSeverity {
        if canceled || completedAt == nil { return .unknown }
        if checks.contains(where: { $0.severity == .failed }) { return .failed }
        if checks.contains(where: { $0.severity == .attention }) { return .attention }
        if checks.isEmpty || checks.contains(where: { $0.severity == .unknown }) { return .unknown }
        return .good
    }
    public var title: String {
        if canceled { return "检查已停止" }
        if completedAt == nil { return "正在检查网络" }
        if checks.contains(where: { $0.severity == .failed }) { return "发现需要处理的问题" }
        if checks.contains(where: { $0.severity == .attention }) { return "网络有需要关注的项目" }
        if checks.isEmpty || checks.contains(where: { $0.severity == .unknown }) { return "部分结果尚未确认" }
        return "本次检查通过"
    }
}

public enum HealthDeviceAnalysis {
    public static func weakSignalDevices(_ devices: [RouterDevice]) -> [RouterDevice] {
        devices.filter { $0.isOnline && ($0.band ?? 0) > 0 && ($0.rssi ?? 0) < -75 }
            .sorted { ($0.rssi ?? 0) == ($1.rssi ?? 0) ? $0.mac < $1.mac : ($0.rssi ?? 0) < ($1.rssi ?? 0) }
    }
}
/// Storage and temperatures from System Info, judged by the same lines the page draws.
public enum HealthSystemAnalysis {
    /// The app's own line for a warm reading; the router's pages show temperatures without one.
    public static let warmCelsius = 85.0

    /// NVRAM and JFFS use, flagged as Tools_Sysinfo.asp colors its bars: above 90 % once rounded to whole percent.
    public static func storage(status: RouterSystemStatus, info: RouterSystemInfo) -> HealthCheck {
        var severity = HealthSeverity.good
        var summary: [String] = [], advice: [String] = [], evidence: [String] = []
        if let used = status.nvramUsedBytes, let total = info.nvramTotalBytes, total > 0 {
            let percent = (used / total * 100).rounded().clampedInt
            summary.append("NVRAM 已用 \(percent)%")
            evidence.append("NVRAM \(used.clampedInt) / \(total.clampedInt) 字节")
            if percent > 90 { severity = worse(severity, .attention); advice.append("NVRAM 接近用满时，新的设置可能无法保存。") }
        } else {
            severity = worse(severity, .unknown); summary.append("NVRAM 用量未返回")
        }
        if info.jffsMounted == false {
            severity = worse(severity, .attention); summary.append("JFFS 分区未挂载")
            advice.append("JFFS 未挂载时，存放在其中的脚本和记录无法使用。")
        } else if let free = status.jffsFreeMB, let total = info.jffsTotalMB, total > 0 {
            let percent = ((total - free) / total * 100).rounded().clampedInt
            summary.append("JFFS 已用 \(percent)%")
            evidence.append(String(format: "JFFS %.2f / %.2f MB", total - free, total))
            if percent > 90 { severity = worse(severity, .attention); advice.append("JFFS 空间不足时，脚本、日志和记录可能无法写入。") }
        } else {
            severity = worse(severity, .unknown); summary.append("JFFS 用量未返回")
        }
        if advice.isEmpty { advice.append("与“系统信息”页相同，用量超过 90% 时提示。") }
        return HealthCheck(id: "storage", title: "路由器存储", severity: severity, summary: summary.joined(separator: " · "),
                           advice: advice.joined(separator: " "), evidence: evidence.joined(separator: "\n"))
    }

    /// The CPU and each radio that reports a temperature; radios that are off are left out, as on the page.
    public static func temperature(status: RouterSystemStatus, radioTitles: [Int: String]) -> HealthCheck {
        var readings: [(sensor: String, celsius: Double)] = []
        if let cpu = status.cpuTemperature { readings.append(("CPU", cpu)) }
        for unit in status.radioTemperatures.keys.sorted() {
            if case .celsius(let celsius) = status.radioTemperatures[unit] { readings.append((radioTitles[unit] ?? "wl\(unit)", celsius)) }
        }
        guard !readings.isEmpty else {
            return HealthCheck(id: "temperature", title: "路由器温度", severity: .unknown, summary: "路由器未报告温度")
        }
        let warm = readings.filter { $0.celsius >= warmCelsius }.map(\.sensor)
        let summary = readings.map { "\($0.sensor) \($0.celsius.rounded().clampedInt) °C" }.joined(separator: " · ")
        return HealthCheck(id: "temperature", title: "路由器温度", severity: warm.isEmpty ? .good : .attention, summary: summary,
                           advice: warm.isEmpty ? "一次读数；任一读数达到 85 °C 时提示。" : "\(warm.joined(separator: "、")) 温度偏高。检查路由器周围是否通风、有无遮挡；一次读数仅供参考。")
    }

    private static func worse(_ a: HealthSeverity, _ b: HealthSeverity) -> HealthSeverity {
        let order: [HealthSeverity] = [.good, .unknown, .attention, .failed]
        return order.firstIndex(of: a)! >= order.firstIndex(of: b)! ? a : b
    }
}

public struct PingObservation: Sendable, Equatable {
    public let lossPercent: Double
    public let averageMilliseconds: Double?
    public init(lossPercent: Double, averageMilliseconds: Double?) { self.lossPercent = lossPercent; self.averageMilliseconds = averageMilliseconds }
}
public enum HealthResultParser {
    public static func ping(_ text: String) -> PingObservation? {
        guard let lossText = RouterParser.capture(#"([0-9]+(?:\.[0-9]+)?)%\s*packet loss"#, in: text),
              let loss = Double(lossText), (0...100).contains(loss) else { return nil }
        let avgText = RouterParser.capture(#"(?:round-trip|rtt)[^=\n]*=\s*[0-9.]+/([0-9.]+)/[0-9.]+"#, in: text)
        let average = avgText.flatMap(Double.init)
        if loss < 100, average == nil { return nil }
        return .init(lossPercent: loss, averageMilliseconds: average)
    }
    public enum DNSResult: Sendable, Equatable { case resolved, failed, unknown }
    public static func dns(_ text: String) -> DNSResult {
        let lower = text.lowercased()
        if ["nxdomain", "servfail", "can't resolve", "timed out", "no servers could be reached"].contains(where: lower.contains) { return .failed }
        guard let nameRange = text.range(of: #"(?im)^\s*Name:\s*[^\s]+"#, options: .regularExpression) else { return .unknown }
        let answers = String(text[nameRange.upperBound...])
        if answers.range(of: #"(?im)^\s*Address(?:es|\s*\d+)?:\s*(?:[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+|[0-9a-f]*:[0-9a-f:]+)"#, options: .regularExpression) != nil { return .resolved }
        return .unknown
    }
}
