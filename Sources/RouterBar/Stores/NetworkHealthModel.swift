import SwiftUI
import Network
import RouterCore

@MainActor
final class NetworkHealthModel: ObservableObject {
    @Published private(set) var report: NetworkHealthReport?
    @Published private(set) var recentReports: [NetworkHealthReport] = []
    @Published private(set) var running = false
    @Published private(set) var progress = ""
    @Published private(set) var localNetworkAvailable: Bool?
    @Published private(set) var localConnection = "正在读取本机网络"
    private let pathMonitor = NWPathMonitor()
    private var task: Task<Void, Never>?
    /// Called when the Mac regains a usable network path after losing it.
    var onPathAvailable: (@MainActor () -> Void)?
    init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            let connection = path.usesInterfaceType(.wiredEthernet) ? "有线网络" : path.usesInterfaceType(.wifi) ? "Wi-Fi" : "当前网络路径"
            Task { @MainActor [weak self] in
                guard let self else { return }
                let regained = available && self.localNetworkAvailable == false
                self.localNetworkAvailable = available; self.localConnection = connection
                if regained { self.onPathAvailable?() }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "RouterBar.NetworkPath"))
    }
    func reset() { task?.cancel(); report = nil; recentReports = [] }
    func cancel() { task?.cancel() }
    func run(store: RouterStore) {
        guard !running, store.beginOperation("正在检查网络健康", readOnly: true) else { return }
        running = true; report = NetworkHealthReport(); progress = "检查本机与路由器连接"
        task = Task {
            defer {
                running = false; progress = ""; task = nil; store.endOperation()
                if let report { recentReports.insert(report, at: 0); recentReports = Array(recentReports.prefix(10)) }
            }
            add(.init(id: "mac", title: "这台 Mac 的网络", severity: localNetworkAvailable == true ? .good : localNetworkAvailable == false ? .failed : .unknown,
                summary: localNetworkAvailable == true ? "\(localConnection) 路径可用" : "本机网络路径尚不可用",
                advice: localNetworkAvailable == true ? "本机有网络路径；外网是否可达由后续测试确认。" : "检查 Wi-Fi 或网线连接。"))
            do {
                let client = try store.connectedClient()
                let began = ProcessInfo.processInfo.systemUptime
                let info = try await client.readSettings(["productid"])
                try Task.checkCancellation()
                let elapsed = (ProcessInfo.processInfo.systemUptime - began) * 1000
                add(.init(id: "router", title: "路由器管理连接", severity: .good,
                    summary: "\(info["productid"] ?? "路由器") 已响应 · \(Int(elapsed)) ms",
                    advice: "这里测量管理接口响应时间，不是 Ping 延迟。"))
                let sample = try await client.sample()
                try Task.checkCancellation()
                add(.init(id: "wan", title: "互联网连接状态", severity: sample.internet == .online ? .good : sample.internet == .offline ? .failed : .unknown,
                    summary: sample.internet.title, advice: sample.internet == .offline ? "检查光猫、WAN 网线和运营商连接；不自动重启或改设置。" : "来自路由器报告，继续用主动测试交叉检查。"))
                progress = "检查路由器到外网的连通性"
                do {
                    let output = try await probe(client, method: "3", host: "1.1.1.1")
                    if let ping = HealthResultParser.ping(output) {
                        let summary = "丢包 \(String(format: "%.0f", ping.lossPercent))%" + (ping.averageMilliseconds.map { " · 平均 \(String(format: "%.1f", $0)) ms" } ?? "")
                        add(.init(id: "ping", title: "路由器 → 外网", severity: ping.lossPercent == 0 && (ping.averageMilliseconds ?? 0) < 100 ? .good : .attention,
                            summary: summary, advice: ping.lossPercent > 0 ? "测试目标为 1.1.1.1；目标可能限制 Ping，单次丢包不等于整个互联网断开。" : "5 次短时探测，不能代表长期稳定性。", evidence: output))
                    } else { add(.init(id: "ping", title: "路由器 → 外网", severity: .unknown, summary: "未识别到完整 Ping 结果", evidence: output)) }
                } catch is CancellationError { throw CancellationError() }
                catch { add(.init(id: "ping", title: "路由器 → 外网", severity: .unknown, summary: error.localizedDescription)) }
                progress = "检查域名解析"
                do {
                    let output = try await probe(client, method: "5", host: "example.com")
                    let dns = HealthResultParser.dns(output)
                    add(.init(id: "dns", title: "域名解析", severity: dns == .resolved ? .good : dns == .failed ? .attention : .unknown,
                        summary: dns == .resolved ? "example.com 已返回地址" : dns == .failed ? "域名查询未成功" : "未识别到明确的解析结果",
                        advice: dns == .resolved ? "使用路由器当前的 DNS 配置，未修改服务器地址。" : "可在日志与工具里查看 DNS 结果，再检查现有 DNS 设置。", evidence: output))
                } catch is CancellationError { throw CancellationError() }
                catch { add(.init(id: "dns", title: "域名解析", severity: .unknown, summary: error.localizedDescription)) }
                try Task.checkCancellation()
                let weak = sample.devices.map(HealthDeviceAnalysis.weakSignalDevices)
                add(.init(id: "wifi", title: "无线设备信号", severity: weak == nil ? .unknown : weak!.isEmpty ? .good : .attention,
                    summary: weak.map { $0.isEmpty ? "未发现低于 −75 dBm 的在线设备" : "\($0.count) 台设备信号较弱" } ?? "设备列表暂不可用",
                    advice: weak?.isEmpty == false ? "以下是检查时的设备，按信号从弱到强排列。点开可查看当前连接与流量，检查距离、遮挡和接入位置。" : "信号强度只是一项指标，不等于实际网速。",
                    relatedDevices: (weak ?? []).map { .init(mac: $0.mac, name: $0.name, kind: $0.classification.kind, detail: "\($0.rssi ?? 0) dBm · \($0.connectionLabel)") }))
                let watched = store.monitor.watched
                if let devices = sample.devices {
                    let online = Set(devices.filter(\.isOnline).map(\.mac))
                    let absent = watched.filter { !online.contains($0.mac) }
                    add(.init(id: "watched", title: "关注的设备", severity: absent.isEmpty ? .good : .attention,
                        summary: watched.isEmpty ? "尚未选择关注设备" : absent.isEmpty ? "\(watched.count) 台关注设备均在线" : "\(absent.count) 台关注设备当前不在线",
                        advice: "离线提醒仍需连续 3 分钟确认；此次检查不会立即触发提醒。",
                        relatedDevices: absent.map { .init(mac: $0.mac, name: $0.name, kind: $0.kind, detail: "检查时未在线 · \($0.ip ?? $0.mac)") }))
                } else { add(.init(id: "watched", title: "关注的设备", severity: .unknown, summary: "设备列表暂不可用")) }
                if let used = sample.memoryUsedKiB, let total = sample.memoryTotalKiB, total > 0 {
                    let percent = used / total * 100
                    add(.init(id: "memory", title: "路由器内存", severity: percent >= 90 ? .attention : .good,
                        summary: "当前使用 \(Int(percent))%", advice: "采用路由器的实际使用口径；一次读数不用于推断持续资源不足。"))
                } else { add(.init(id: "memory", title: "路由器内存", severity: .unknown, summary: "暂未返回有效数据")) }
                progress = "检查路由器存储与温度"
                do {
                    let status = try await client.systemStatus()
                    let info = try await client.systemInfo()
                    try Task.checkCancellation()
                    add(HealthSystemAnalysis.storage(status: status, info: info))
                    add(HealthSystemAnalysis.temperature(status: status, radioTitles: store.radioBands.isEmpty ? RouterRadioBands.fallback : store.radioBands))
                } catch is CancellationError { throw CancellationError() }
                catch RouterError.authenticationRequired { throw RouterError.authenticationRequired }
                catch {
                    add(.init(id: "storage", title: "路由器存储", severity: .unknown, summary: error.localizedDescription))
                    add(.init(id: "temperature", title: "路由器温度", severity: .unknown, summary: error.localizedDescription))
                }
                report?.completedAt = .now
            } catch is CancellationError {
                report?.canceled = true; report?.completedAt = .now
            } catch {
                add(.init(id: "connection-error", title: "检查中断", severity: .failed, summary: error.localizedDescription,
                    advice: "确认本机仍连接家庭网络，并检查路由器连接状态。"))
                report?.completedAt = .now; store.handleManagementError(error)
            }
        }
    }
    private func add(_ check: HealthCheck) { report?.checks.append(check) }
    private func probe(_ client: RouterClient, method: String, host: String) async throws -> String {
        try Task.checkCancellation()
        let job = try await client.startDiagnostic(method: method, host: host, version: "v4")
        for _ in 0..<25 {
            try await Task.sleep(for: .seconds(1))
            let result = try await client.diagnosticResult(job: job)
            if result.complete { return String(result.text.prefix(8000)) }
        }
        throw RouterError.network("本次探测等待超时，结果尚未确认。")
    }
}
