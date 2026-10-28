import SwiftUI
import Charts
import RouterCore

/// System Info › Sysinfo (Tools_Sysinfo.asp): hardware, memory, storage, temperatures and connections. Like the web
/// page, the live figures are read again every 3 seconds while the page is open.
struct SystemInfoView: View {
    @Environment(RouterStore.self) var store
    @StateObject private var info = RouterReading<RouterSystemInfo>()
    @StateObject private var status = RouterReading<RouterSystemStatus>()
    @State private var trend: [TemperaturePoint] = []
    @State private var recordedAt: Date?

    private struct TemperaturePoint: Identifiable {
        let id: Int
        let date: Date
        let sensor: String
        let celsius: Double
    }

    private struct Radio: Hashable {
        let unit: Int
        let title: String
    }

    private var connected: Bool { store.phase == .connected }
    /// The radios to list, by unit: the bands the router reports, or the web's own guess when they cannot be read.
    private var radios: [Radio] {
        if !store.radioBands.isEmpty { return store.radioBands.sorted { $0.key < $1.key }.map { Radio(unit: $0.key, title: $0.value) } }
        let reported = (status.value?.radioTemperatures ?? [:]).filter { $0.value != .disabled }.keys
        return reported.sorted().map { Radio(unit: $0, title: RouterRadioBands.fallback[$0] ?? "wl\($0)") }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusPageHeader(title: "Sysinfo", subtitle: "路由器的硬件、内存、闪存、温度和连接数。页面打开时每 3 秒更新一次，与网页相同。",
                                 symbol: "info.circle", readAt: status.readAt, loading: info.loading || status.loading) { await reload() }
                ReadErrorLabel(message: status.error ?? info.error)
                if !connected {
                    ConnectionRequiredView()
                } else if status.value == nil && info.value == nil {
                    ReadingPlaceholder(failed: status.error != nil && !status.loading, minHeight: 220)
                } else {
                    cards
                    temperatureChart
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14, alignment: .top), GridItem(.flexible(), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                        routerPanel
                        VStack(spacing: 14) { cpuPanel; memoryPanel }
                        storagePanel
                        networkPanel
                    }
                }
            }.padding(28)
        }
        .task(id: connected) {
            guard connected else { return }
            if info.value == nil { await info.load(store: store) { try await $0.systemInfo() } }
            while !Task.isCancelled {
                await status.load(store: store) { try await $0.systemStatus() }
                record()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func reload() async {
        await info.load(store: store) { try await $0.systemInfo() }
        await status.load(store: store) { try await $0.systemStatus() }
        record()
    }

    /// Keeps about five minutes of temperatures for the chart, one entry per successful reading.
    private func record() {
        guard let value = status.value, let readAt = status.readAt, readAt != recordedAt else { return }
        recordedAt = readAt
        var id = (trend.last?.id ?? 0) + 1
        if let cpu = value.cpuTemperature { trend.append(.init(id: id, date: readAt, sensor: "CPU", celsius: cpu)); id += 1 }
        for radio in radios {
            if case .celsius(let celsius) = value.radioTemperatures[radio.unit] { trend.append(.init(id: id, date: readAt, sensor: radio.title, celsius: celsius)); id += 1 }
        }
        trend.removeAll { readAt.timeIntervalSince($0.date) > 300 }
    }

    // MARK: Cards

    private var cards: some View {
        let value = status.value
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 14)], spacing: 14) {
            StatCard(title: "CPU 温度", value: value?.cpuTemperature.map(celsius) ?? "—", symbol: "thermometer.medium", tint: .orange, note: "处理器")
            ForEach(radios, id: \.self) { radio in
                StatCard(title: "\(radio.title) 温度", value: temperature(value?.radioTemperatures[radio.unit]), symbol: "dot.radiowaves.left.and.right", tint: tint(for: radio.title), note: "无线芯片")
            }
            StatCard(title: "连接数", value: value?.connections.map { "\($0.total)" } ?? "—", symbol: "point.3.connected.trianglepath.dotted", tint: .primary,
                     note: value?.connections.map { "其中 \($0.active) 个活动" + (info.value?.connectionLimit.map { " · 上限 \($0)" } ?? "") } ?? "等待读取")
        }
    }

    private var temperatureChart: some View {
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text("温度").font(.headline); Spacer(); Text("本页打开期间，最近 5 分钟").font(.caption).foregroundStyle(.secondary) }
                if Set(trend.map(\.date)).count > 1 {
                    Chart(trend) { point in
                        LineMark(x: .value("时间", point.date), y: .value("°C", point.celsius), series: .value("传感器", point.sensor))
                            .foregroundStyle(by: .value("传感器", point.sensor))
                    }
                    .chartForegroundStyleScale(domain: sensors, range: sensors.map(tint(for:)))
                    .chartXAxis { AxisMarks(preset: .aligned) }
                    .chartYAxisLabel("°C").chartYScale(domain: .automatic(includesZero: false)).frame(height: 150)
                } else {
                    ContentUnavailableView("正在记录温度", systemImage: "thermometer.medium", description: Text("连续读取几次后显示温度曲线。")).frame(height: 120)
                }
            }
        }
    }
    private var sensors: [String] { ["CPU"] + radios.map(\.title) }

    // MARK: Panels

    private var routerPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(title: "路由器", symbol: "wifi.router")
                KeyValue(key: "型号", value: info.value?.model ?? "—")
                KeyValue(key: "固件版本", value: info.value?.firmware ?? "—")
                KeyValue(key: "固件编译", value: info.value?.firmwareBuild ?? "—")
                KeyValue(key: "Bootloader", value: info.value?.bootloader ?? "—")
                KeyValue(key: "已开机时间", value: Format.uptime(store.snapshot?.sample.uptime))
                if let drivers = info.value?.wirelessDrivers, !drivers.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("无线驱动版本").font(.callout).foregroundStyle(.secondary)
                        ForEach(drivers, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                    }.padding(.vertical, 3)
                }
                if let features = info.value?.features, !features.isEmpty {
                    DisclosureGroup("功能（\(features.count) 项）") {
                        Text(features.joined(separator: "  ")).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                    }.font(.callout)
                }
            }
        }
    }

    private var cpuPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(title: "CPU", symbol: "cpu")
                KeyValue(key: "型号", value: info.value?.cpuModel ?? "—")
                KeyValue(key: "平均负载（1、5、15 分钟）", value: status.value?.loadAverage.map { $0.map { String(format: "%.2f", $0) }.joined(separator: ", ") } ?? "—")
            }
        }
    }

    private var memoryPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(title: "内存", symbol: "memorychip")
                if let memory = status.value?.memory, memory.total > 0 {
                    MemoryBar(memory: memory)
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                        GridRow { pair("总计", memory.total); pair("已用", memory.used) }
                        GridRow { pair("可用", memory.available); pair("空闲", memory.free) }
                        GridRow { pair("缓冲", memory.buffers); pair("缓存", memory.cache) }
                    }.font(.callout)
                    KeyValue(key: "交换空间", value: memory.swapTotal > 0 ? String(format: "已用 %.2f / %.2f MB", memory.swapUsed, memory.swapTotal) : "未使用交换空间")
                } else {
                    Text("等待读取").foregroundStyle(.secondary)
                }
            }
        }
    }
    @ViewBuilder private func pair(_ label: String, _ megabytes: Double) -> some View {
        Text(label).foregroundStyle(.secondary)
        Text(String(format: "%.2f MB", megabytes)).monospacedDigit().gridColumnAlignment(.trailing)
    }

    private var storagePanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "内部存储", symbol: "internaldrive")
                if let used = status.value?.nvramUsedBytes, let total = info.value?.nvramTotalBytes, total > 0 {
                    UsageBar(title: "NVRAM", fraction: used / total, detail: "\(used.clampedInt) / \(total.clampedInt) 字节")
                } else {
                    KeyValue(key: "NVRAM", value: "—")
                }
                if info.value?.jffsMounted == false {
                    KeyValue(key: "JFFS", value: "JFFS 分区未挂载")
                } else if let free = status.value?.jffsFreeMB, let total = info.value?.jffsTotalMB, total > 0 {
                    UsageBar(title: "JFFS", fraction: (total - free) / total, detail: String(format: "%.2f / %.2f MB", total - free, total))
                } else {
                    KeyValue(key: "JFFS", value: "—")
                }
                Text("用量超过 90% 时标为橙色，与网页相同。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var networkPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(title: "网络", symbol: "network")
                if let facts = info.value?.hardwareAcceleration, !facts.isEmpty {
                    KeyValue(key: "硬件加速", value: facts.map { "\($0.label)：\($0.value == "Enabled" ? "已启用" : $0.value == "Disabled" ? "已停用" : $0.value)" }.joined(separator: "  ·  "))
                }
                KeyValue(key: "连接", value: status.value?.connections.map { "\($0.total)" + (info.value?.connectionLimit.map { " / \($0)" } ?? "") + " · \($0.active) 个活动" } ?? "—")
                ForEach(radios, id: \.self) { radio in
                    KeyValue(key: "无线客户端（\(radio.title)）", value: clients(status.value?.wirelessClients[radio.unit]))
                }
                Text("已授权指完成 Wi-Fi 密码验证的设备，已认证指完成连接认证的设备。" + (info.value?.reportsAssociated == false ? "Wi-Fi 7 路由器不提供“已关联”计数，网页同样不显示。" : ""))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Formatting

    private func celsius(_ value: Double) -> String { String(format: "%.0f °C", value) }
    private func temperature(_ value: RouterTemperature?) -> String {
        switch value {
        case .celsius(let c): celsius(c)
        case .disabled: "已关闭"
        case nil: "—"
        }
    }
    private func clients(_ counts: RouterSystemStatus.WirelessCounts?) -> String {
        guard let counts else { return "—" }
        let parts = (info.value?.reportsAssociated == false ? [] : ["已关联 \(counts.associated)"]) + ["已授权 \(counts.authorized)", "已认证 \(counts.authenticated)"]
        return parts.joined(separator: " · ")
    }
    private func tint(for sensor: String) -> Color {
        if sensor == "CPU" { return .orange }
        if sensor.hasPrefix("2.4") { return .teal }
        if sensor.hasPrefix("6") { return .purple }
        return .blue
    }
}

/// Memory as the web's doughnut splits it: used, reclaimable (cache the kernel can free) and free.
private struct MemoryBar: View {
    let memory: RouterSystemStatus.Memory
    var body: some View {
        let parts: [(String, Double, Color)] = [("已用", memory.used, .teal), ("可回收", memory.reclaimable, .blue.opacity(0.45)), ("空闲", memory.free, .secondary.opacity(0.25))]
        let total = max(parts.map(\.1).reduce(0, +), 1)
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(parts.indices, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 3).fill(parts[index].2).frame(width: max(0, proxy.size.width * parts[index].1 / total - 2))
                    }
                }
            }.frame(height: 10)
            HStack(spacing: 12) {
                ForEach(parts.indices, id: \.self) { index in
                    HStack(spacing: 4) { Circle().fill(parts[index].2).frame(width: 7, height: 7); Text("\(parts[index].0) \(parts[index].1.rounded().clampedInt) MB") }
                }
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A storage area's use, orange above 90% as on the web page.
private struct UsageBar: View {
    let title: String
    let fraction: Double
    let detail: String
    var body: some View {
        let value = min(max(fraction, 0), 1)
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text(title).font(.callout); Spacer(); Text("\((value * 100).rounded().clampedInt)%").font(.callout.weight(.medium)).monospacedDigit() }
            // The web rounds to whole percent before comparing with 90.
            ProgressView(value: value).tint((value * 100).rounded() > 90 ? .orange : .teal)
            Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}
