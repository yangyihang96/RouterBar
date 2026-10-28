import SwiftUI
import Charts
import RouterCore

// Traffic Analyzer › 统计数值, Adaptive QoS › 带宽监控 and 网页浏览历史, 流量监控 › Monitoring Settings and AiCloud › 日志:
// read-only pages. A switch that is off is reported as off; none of these pages turns one on or accepts an agreement.

extension Format {
    /// Bits per second the way the web's bandwidth gauges count them: bytes × 8, 1024-based (calculate_traffic()).
    static func bitRate(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond else { return "—" }
        let kilobits = max(0, bytesPerSecond) * 8 / 1024
        return kilobits >= 1024 ? String(format: "%.2f Mbps", kilobits / 1024) : String(format: "%.1f Kbps", kilobits)
    }
}

/// 双向 / 下载 / 上传, the web's 统计类别 choices.
private enum TrafficDirection: String, CaseIterable, Identifiable {
    case both = "双向", download = "下载", upload = "上传"
    var id: String { rawValue }
    func value(_ volume: TrafficVolume) -> UInt64 {
        switch self { case .both: volume.total; case .download: volume.download; case .upload: volume.upload }
    }
}

@MainActor private func deviceName(_ store: RouterStore, _ id: String) -> String {
    store.snapshot?.sample.devices?.first { $0.mac == id }?.name ?? id
}

// MARK: - 统计数值

struct TrafficStatisticsView: View {
    /// The apps of one device over one period, so a late answer for another device or period is never shown.
    private struct ClientApps: Sendable {
        let client: String
        let period: TrafficStatisticsPeriod
        let apps: [TrafficStatisticsItem]
    }
    @Environment(RouterStore.self) var store
    @StateObject private var switches = RouterReading<TrafficAnalyzerSwitches>()
    @StateObject private var reading = RouterReading<TrafficStatistics>()
    @StateObject private var clientApps = RouterReading<ClientApps>()
    @State private var period: TrafficStatisticsPeriod = .daily
    @State private var direction: TrafficDirection = .both
    @State private var selectedClient: String?
    private var connected: Bool { store.phase == .connected }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusPageHeader(title: "统计数值", subtitle: "Traffic Analyzer 按设备和应用统计的流量。统计开启后，路由器每小时汇总一次数据。",
                                 symbol: "chart.bar.xaxis", readAt: reading.readAt ?? switches.readAt, loading: switches.loading || reading.loading) { await reload() }
                ReadErrorLabel(message: switches.error ?? reading.error)
                if !connected {
                    ConnectionRequiredView()
                } else if let state = switches.value {
                    // The page reads the database whether or not collection is on (initial(), 104–120).
                    if !state.statistics { offNotice(state) }
                    statistics(state)
                } else {
                    ReadingPlaceholder(failed: switches.error != nil && !switches.loading, minHeight: 220)
                }
            }.padding(28)
        }
        .task(id: connected) { if connected, switches.value == nil { await reload() } }
        .onChange(of: period) { _, _ in selectedClient = nil; Task { await loadStatistics(supersede: true) } }
    }

    private func reload() async {
        await switches.load(store: store) { try await $0.trafficAnalyzerSwitches() }
        await loadStatistics()
    }
    /// `supersede` when the period changed: the newer request replaces one still under way.
    private func loadStatistics(supersede: Bool = false) async {
        guard let state = switches.value else { return }
        let period = period
        await reading.load(store: store, supersede: supersede) { try await $0.trafficStatistics(period, dnsBased: state.dnsBased) }
        if let selectedClient { await loadApps(selectedClient) }
    }
    private func loadApps(_ client: String) async {
        guard let state = switches.value else { return }
        let period = period
        await clientApps.load(store: store, supersede: true) { ClientApps(client: client, period: period, apps: try await $0.trafficStatistics(apps: client, period: period, dnsBased: state.dnsBased)) }
    }

    private func offNotice(_ state: TrafficAnalyzerSwitches) -> some View {
        var message = "统计数值没有开启，路由器不再记录新的流量；下面显示路由器数据库里已有的记录，与网页相同。开关在网页的“统计数值”分页，本应用不替你开启。"
        if !state.dnsBased && !state.trendMicroAgreed { message += "开启时网页会要求同意趋势科技的条款。" }
        return VStack(alignment: .leading, spacing: 8) {
            NoticeBanner(message: message, tone: .information)
            if let location = store.menuSet.location(of: .trafficMonitor(.realtime)) {
                Button("查看流量监控（接口流量）") { store.navigate(.web(location)) }.buttonStyle(.link)
            }
        }
    }

    @ViewBuilder private func statistics(_ state: TrafficAnalyzerSwitches) -> some View {
        HStack(spacing: 16) {
            Picker("显示方式", selection: $period) { ForEach(TrafficStatisticsPeriod.allCases) { Text($0.title).tag($0) } }.frame(maxWidth: 220)
            Picker("统计类别", selection: $direction) { ForEach(TrafficDirection.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).frame(maxWidth: 240)
            Spacer()
        }
        if let stats = reading.value, stats.period == period {
            totals(stats)
            timeline(stats)
            ranking(title: "客户端", items: stats.clients, empty: "无客户端", isDevice: true)
            if let selectedClient { clientDetail(selectedClient) }
            ranking(title: "应用程序", items: stats.apps, empty: "无应用程序", isDevice: false)
            Text("流量按路由器数据库的字节数计算，单位按 1024 换算。图表的每一格是一小时（每天）或一天（每周、每月），最后一格包含读取时刻。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            ReadingPlaceholder(failed: reading.error != nil && !reading.loading, minHeight: 160)
        }
    }

    private func totals(_ stats: TrafficStatistics) -> some View {
        let up = stats.timeline.reduce(0.0) { $0 + Double($1.upload) }, down = stats.timeline.reduce(0.0) { $0 + Double($1.download) }
        return HStack(spacing: 14) {
            StatCard(title: "下载", value: Format.bytes(down), symbol: "arrow.down", tint: .teal, note: stats.period.title)
            StatCard(title: "上传", value: Format.bytes(up), symbol: "arrow.up", tint: .blue, note: stats.period.title)
            StatCard(title: "总流量值", value: Format.bytes(up + down), symbol: "sum", tint: .primary, note: "路由器整体")
        }
    }

    private struct Bar: Identifiable {
        let id: Int
        let date: Date
        let bytes: Double
    }

    private func timeline(_ stats: TrafficStatistics) -> some View {
        let calendar = Calendar.current
        let hourly = stats.period == .daily
        let last = hourly ? (calendar.dateInterval(of: .hour, for: stats.end)?.start ?? stats.end) : calendar.startOfDay(for: stats.end)
        let count = stats.timeline.count
        let bars = stats.timeline.enumerated().compactMap { index, volume -> Bar? in
            calendar.date(byAdding: hourly ? .hour : .day, value: index - (count - 1), to: last).map { Bar(id: index, date: $0, bytes: Double(direction.value(volume))) }
        }
        let peak = bars.map(\.bytes).max() ?? 0
        let (unit, divisor) = peak >= 1024 * 1024 * 1024 ? ("GB", 1024.0 * 1024 * 1024) : peak >= 1024 * 1024 ? ("MB", 1024.0 * 1024) : ("KB", 1024.0)
        return Panel {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text(hourly ? "每日流量" : stats.period == .weekly ? "每周流量" : "每月流量").font(.headline); Spacer(); Text(direction.rawValue).font(.caption).foregroundStyle(.secondary) }
                Chart(bars) { bar in
                    BarMark(x: .value("时间", bar.date, unit: hourly ? .hour : .day), y: .value(unit, bar.bytes / divisor)).foregroundStyle(.teal)
                }
                .chartYAxisLabel(unit)
                .chartXAxis {
                    AxisMarks(preset: .aligned, values: .stride(by: hourly ? .hour : .day, count: hourly ? 3 : stats.period == .weekly ? 1 : 5)) { _ in
                        AxisGridLine(); AxisTick()
                        AxisValueLabel(format: (hourly ? Date.FormatStyle.dateTime.hour() : .dateTime.month(.defaultDigits).day()).locale(Locale(identifier: "zh_CN")))
                    }
                }
                .frame(height: 190)
            }
        }
    }

    private func ranking(title: String, items: [TrafficStatisticsItem], empty: String, isDevice: Bool) -> some View {
        let sorted = items.enumerated().sorted { a, b in
            let x = direction.value(a.element.volume), y = direction.value(b.element.volume)
            return x != y ? x > y : a.offset < b.offset
        }.map(\.element)
        let sum = sorted.reduce(0.0) { $0 + Double(direction.value($1.volume)) }
        return Panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text(title).font(.headline); Spacer(); Text("\(items.count) 项").font(.caption).foregroundStyle(.secondary) }
                if sorted.isEmpty {
                    Text(empty).font(.callout).foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 7) {
                        GridRow {
                            ForEach([title, "下载", "上传", "使用量", "使用量(%)"], id: \.self) { Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                        }
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(sorted) { item in
                            GridRow {
                                if isDevice {
                                    Button { selectedClient = selectedClient == item.id ? nil : item.id; if let client = selectedClient { Task { await loadApps(client) } } } label: {
                                        Label(deviceName(store, item.id), systemImage: selectedClient == item.id ? "chevron.down" : "chevron.right").lineLimit(1)
                                    }.buttonStyle(.plain).help("查看这台设备使用的应用程序")
                                } else {
                                    Text(item.id).lineLimit(1)
                                }
                                Text(Format.bytes(Double(item.volume.download))).monospacedDigit()
                                Text(Format.bytes(Double(item.volume.upload))).monospacedDigit()
                                Text(Format.bytes(Double(direction.value(item.volume)))).monospacedDigit()
                                Text(sum > 0 ? String(format: "%.1f%%", Double(direction.value(item.volume)) / sum * 100) : "—").monospacedDigit()
                            }.font(.callout)
                        }
                    }
                }
            }
        }
    }

    private func clientDetail(_ client: String) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("\(deviceName(store, client)) 使用的应用程序").font(.headline)
                    Spacer()
                    if clientApps.loading { ProgressView().controlSize(.small) }
                    Button("收起") { selectedClient = nil }.buttonStyle(.link)
                }
                ReadErrorLabel(message: clientApps.error)
                if let value = clientApps.value, value.client == client, value.period == period {
                    if value.apps.isEmpty { Text("无应用程序").font(.callout).foregroundStyle(.secondary) }
                    ForEach(value.apps.prefix(20)) { app in
                        HStack {
                            Text(app.id).lineLimit(1)
                            Spacer()
                            Text("下载 \(Format.bytes(Double(app.volume.download))) · 上传 \(Format.bytes(Double(app.volume.upload)))").monospacedDigit().foregroundStyle(.secondary)
                        }.font(.callout)
                    }
                }
            }
        }
    }
}

// MARK: - 带宽监控

struct BandwidthMonitorView: View {
    @Environment(RouterStore.self) var store
    @StateObject private var switches = RouterReading<TrafficAnalyzerSwitches>()
    @StateObject private var traffic = RouterReading<DeviceTrafficReading>()
    @State private var monitor = BandwidthMonitor()
    @State private var sample: BandwidthSample?
    @State private var consumedAt: Date?
    private var connected: Bool { store.phase == .connected }

    private struct Row: Identifiable {
        let id: String
        let name: String
        let rate: DeviceTrafficRate
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusPageHeader(title: "带宽监控", subtitle: "路由器和各在线设备当前的上传与下载速率。页面打开时每 3 秒读取一次流量计数（网页每 2 秒），与网页一样按相邻两次读数之差计算。",
                                 symbol: "speedometer", readAt: traffic.readAt, loading: traffic.loading) { await read() }
                ReadErrorLabel(message: traffic.error ?? switches.error)
                if !connected {
                    ConnectionRequiredView()
                } else if let reading = traffic.value, reading.counters.isEmpty {
                    NoticeBanner(message: "路由器目前没有提供各设备的流量计数，因此无法显示带宽。网页的带宽监控同样依赖这些计数。", tone: .information)
                } else if let sample {
                    gauges(sample)
                    devices(sample)
                    notes
                } else if traffic.value != nil {
                    ProgressView("已读到第一份计数，等待下一次读取后计算速率…").frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    ReadingPlaceholder(failed: traffic.error != nil && !traffic.loading, minHeight: 160)
                }
            }.padding(28)
        }
        .task(id: connected) {
            guard connected else { monitor.reset(); sample = nil; return }
            while !Task.isCancelled {
                await read()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// The web polls getTraffic_Dns.asp when the router uses DNS DPI and getTraffic.asp otherwise, so the engine is
    /// known before the first count is read.
    private func read() async {
        if switches.value == nil { await switches.load(store: store) { try await $0.trafficAnalyzerSwitches() } }
        guard let dnsBased = switches.value?.dnsBased else { return }
        await traffic.load(store: store) { try await $0.bandwidthTraffic(dnsBased: dnsBased) }
        guard let reading = traffic.value, reading.date != consumedAt else { return }
        consumedAt = reading.date
        if let next = monitor.consume(reading) { sample = next }
    }

    private func gauges(_ sample: BandwidthSample) -> some View {
        HStack(spacing: 14) {
            StatCard(title: "上传", value: Format.bitRate(sample.router?.upload), symbol: "arrow.up", tint: .blue, note: sample.router == nil ? "路由器本次未提供整体计数" : "路由器整体")
            StatCard(title: "下载", value: Format.bitRate(sample.router?.download), symbol: "arrow.down", tint: .teal, note: sample.router == nil ? "路由器本次未提供整体计数" : "路由器整体")
            StatCard(title: "在线设备", value: "\(rows(sample).count)", symbol: "laptopcomputer.and.iphone", tint: .primary, note: "有流量计数的在线设备")
        }
    }

    /// The web lists only devices that are in its client list and online (calculate_traffic()).
    private func rows(_ sample: BandwidthSample) -> [Row] {
        let online = Dictionary((store.snapshot?.sample.devices ?? []).filter(\.isOnline).map { ($0.mac, $0.name) }, uniquingKeysWith: { first, _ in first })
        return sample.devices.compactMap { rate in online[rate.mac].map { Row(id: rate.mac, name: $0, rate: rate) } }
    }

    private func devices(_ sample: BandwidthSample) -> some View {
        let list = rows(sample)
        let peak = max(list.map { max($0.rate.upload, $0.rate.download) }.max() ?? 0, 1)
        return Panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("设备").font(.headline); Spacer(); Text("按当前总速率排序").font(.caption).foregroundStyle(.secondary) }
                if list.isEmpty { Text("目前没有在线设备的流量计数。").font(.callout).foregroundStyle(.secondary) }
                ForEach(list) { row in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Button { store.showDevice(row.id) } label: { Text(row.name).lineLimit(1) }.buttonStyle(.plain)
                            Spacer()
                            Label(Format.bitRate(row.rate.upload), systemImage: "arrow.up").foregroundStyle(.blue)
                            Label(Format.bitRate(row.rate.download), systemImage: "arrow.down").foregroundStyle(.teal)
                        }.font(.callout).monospacedDigit()
                        GeometryReader { proxy in
                            VStack(alignment: .leading, spacing: 2) {
                                Capsule().fill(.blue.opacity(0.7)).frame(width: max(2, proxy.size.width * row.rate.upload / peak), height: 4)
                                Capsule().fill(.teal.opacity(0.7)).frame(width: max(2, proxy.size.width * row.rate.download / peak), height: 4)
                            }
                        }.frame(height: 10)
                    }
                }
            }
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("速率按网页的口径换算：每秒字节数 × 8，以 1024 进位（1 Mbps = 1024 Kbps）。“网络地图 › 客户端”以每秒字节数显示设备速率。")
            if switches.value?.appAnalysis == false {
                Text("应用程序分析没有开启，网页不展开各设备使用的应用；本应用也不替你开启。")
            }
        }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - 网页浏览历史

struct WebHistoryView: View {
    @Environment(RouterStore.self) var store
    @StateObject private var switches = RouterReading<TrafficAnalyzerSwitches>()
    @StateObject private var reading = RouterReading<WebHistoryPage>()
    @State private var page = 1
    private var connected: Bool { store.phase == .connected }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusPageHeader(title: "网页浏览历史", subtitle: "路由器记录的各设备访问过的网站，每页 50 条。",
                                 symbol: "clock.arrow.circlepath", readAt: reading.readAt ?? switches.readAt, loading: switches.loading || reading.loading) { await reload() }
                ReadErrorLabel(message: switches.error ?? reading.error)
                if !connected {
                    ConnectionRequiredView()
                } else if let state = switches.value {
                    if state.webHistory { history } else {
                        // initial() reads the history only while the switch is on (43–53).
                        NoticeBanner(message: "网页浏览历史没有开启，路由器不记录访问过的网站；网页这时不显示记录，本应用同样不读取。开关在网页的“网页浏览历史”分页，本应用不替你开启。", tone: .information)
                    }
                } else {
                    ReadingPlaceholder(failed: switches.error != nil && !switches.loading, minHeight: 220)
                }
            }.padding(28)
        }
        .task(id: connected) { if connected, switches.value == nil { await reload() } }
    }

    private func reload() async {
        await switches.load(store: store) { try await $0.trafficAnalyzerSwitches() }
        if switches.value?.webHistory == true { await load() }
    }
    private func load() async {
        let page = page
        await reading.load(store: store) { try await $0.webHistory(page: page) }
    }

    @ViewBuilder private var history: some View {
        if let result = reading.value {
            let entries = result.entries
            HStack {
                Button { page -= 1; Task { await load() } } label: { Label("上一页", systemImage: "chevron.left") }.disabled(page <= 1 || reading.loading)
                Text("第 \(page) 页").monospacedDigit()
                Button { page += 1; Task { await load() } } label: { Label("下一页", systemImage: "chevron.right") }.disabled(!result.hasNextPage || reading.loading)
                Spacer()
            }
            Panel {
                if entries.isEmpty {
                    Text("目前没有数据").font(.callout).foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 7) {
                        GridRow { ForEach(["访问时间", "设备", "域名"], id: \.self) { Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary) } }
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(entries) { entry in
                            GridRow {
                                Text(MonitoringDate.full(entry.date)).monospacedDigit()
                                Text(deviceName(store, entry.device)).lineLimit(1)
                                Text(entry.host).textSelection(.enabled)
                            }.font(.callout)
                        }
                    }
                }
            }
            Text("访问时间按本机时区显示，与网页相同。").font(.caption).foregroundStyle(.secondary)
        } else {
            ReadingPlaceholder(failed: reading.error != nil && !reading.loading, minHeight: 160)
        }
    }
}

// MARK: - Monitoring Settings

struct TrafficMonitorSettingsView: View {
    @Environment(RouterStore.self) var store
    @StateObject private var reading = RouterReading<TrafficMonitorSettings>()
    private var connected: Bool { store.phase == .connected }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusPageHeader(title: "Monitoring Settings", subtitle: "流量监控的历史记录保存在哪里、多久保存一次，以及每月统计从哪一天开始。本页只显示当前设置。",
                                 symbol: "gearshape.2", readAt: reading.readAt, loading: reading.loading) { await load() }
                ReadErrorLabel(message: reading.error)
                if !connected {
                    ConnectionRequiredView()
                } else if let settings = reading.value {
                    Panel {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Traffic Monitor").font(.headline).padding(.bottom, 6)
                            KeyValue(key: "流量历史保存位置", value: location(settings.location))
                            if case .custom(let path) = settings.location { KeyValue(key: "保存位置", value: path) }
                            if settings.location != .ram {
                                KeyValue(key: "保存频率", value: settings.saveHours.map(frequency) ?? "—")
                                KeyValue(key: "创建或重置数据文件", value: settings.resetFiles ? "是" : "否")
                            }
                            KeyValue(key: "每月统计起始日", value: settings.monthStartDay.map { "每月 \($0) 日" } ?? "—")
                        }
                    }
                    Text("保存在 RAM 时，路由器重新启动后历史记录会清空；网页在这一页修改这些设置，本应用不提供修改。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    ReadingPlaceholder(failed: reading.error != nil && !reading.loading, minHeight: 220)
                }
            }.padding(28)
        }
        .task(id: connected) { if connected, reading.value == nil { await load() } }
    }

    private func load() async { await reading.load(store: store) { try await $0.trafficMonitorSettings() } }

    private func location(_ location: TrafficMonitorSettings.Location) -> String {
        switch location { case .ram: "RAM（默认）"; case .custom: "自定义位置"; case .nvram: "NVRAM" }
    }
    /// The page's choices: Every 1 hour, 6 hours, 12 hours, 1 day, 3 days.
    private func frequency(_ hours: Int) -> String {
        switch hours { case 24: "每天"; case 72: "每 3 天"; default: "每 \(hours) 小时" }
    }
}

// MARK: - AiCloud 日志

struct AiCloudLogView: View {
    @Environment(RouterStore.self) var store
    @StateObject private var reading = RouterReading<String>()
    private var connected: Bool { store.phase == .connected }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StatusPageHeader(title: "日志", subtitle: "AiCloud 服务的访问与同步记录，与网页“AiCloud 2.0 › 日志”相同。",
                             symbol: "doc.text.magnifyingglass", readAt: reading.readAt, loading: reading.loading, subtitleLineLimit: 2) { await load() }
            ReadErrorLabel(message: reading.error)
            if !connected {
                ConnectionRequiredView()
            } else if let log = reading.value {
                if log.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView("目前没有日志", systemImage: "doc.text", description: Text("AiCloud 还没有写入记录。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView([.vertical, .horizontal]) {
                        Text(log).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                    .card(radius: 10)
                }
            } else {
                ReadingPlaceholder(failed: reading.error != nil && !reading.loading, minHeight: 220)
            }
        }
        // The page does not scroll: keep the header at the top whatever the log area needs.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(28)
        .task(id: connected) { if connected, reading.value == nil { await load() } }
    }

    private func load() async { await reading.load(store: store) { try await $0.aiCloudLog() } }
}
