import SwiftUI
import Charts
import RouterCore

/// Traffic Analyzer › 流量监控: the web page's four switch choices. Interfaces are named and ordered like the
/// web's tabs; 接收 and 传送 are the router's own words (on the WAN they are download and upload).
struct TrafficMonitorView: View {
    let mode: TrafficMonitorMode
    var body: some View {
        switch mode {
        case .realtime: RealtimeTrafficView()
        case .last24: TrafficHistoryView()
        case .daily: TrafficRecordsView(monthly: false)
        case .monthly: TrafficRecordsView(monthly: true)
        }
    }
}

// MARK: - 即时流量图

private struct RealtimeTrafficView: View {
    @Environment(RouterStore.self) var store
    @State private var window = TrafficRateWindow(capacity: 300)
    @State private var keys: [String] = []
    @State private var selection = "INTERNET"
    @State private var error: String?
    @State private var readAt: Date?
    private var connected: Bool { store.phase == .connected }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 15) {
                    PageHeader(title: "即时流量图", subtitle: "路由器各接口的实时速度，与网页一样每 2 秒读取一次。曲线和统计从打开本页开始记录，最多保留 10 分钟。", symbol: "chart.xyaxis.line")
                    Spacer()
                    if let readAt { Text("读取于 \(MonitoringDate.time(readAt))").font(.caption).foregroundStyle(.secondary) }
                }
                ReadErrorLabel(message: error)
                if !connected {
                    ConnectionRequiredView()
                } else if keys.isEmpty {
                    ReadingPlaceholder(failed: error != nil, minHeight: 220)
                } else {
                    TrafficInterfacePicker(keys: keys, selection: $selection)
                    TrafficChartPanel(points: window.points[selection] ?? [], wan: TrafficInterface.isWAN(selection),
                                      caption: "本页打开期间", empty: "再读取一次后显示速度曲线。")
                    TrafficSummaryTable(summary: window.summary(for: selection), wan: TrafficInterface.isWAN(selection),
                                        note: "平均、最大与总流量值从打开本页开始计算。")
                    TrafficDirectionNote(wan: TrafficInterface.isWAN(selection))
                }
            }.padding(28)
        }
        .task(id: connected) {
            guard connected else { return }
            while !Task.isCancelled {
                if store.operationTitle == nil { await read() }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func read() async {
        do {
            let counters = try await store.connectedClient().interfaceCounters()
            window.consume(counters, at: ProcessInfo.processInfo.systemUptime, date: .now)
            keys = TrafficInterfacePicker.visible(Array(counters.keys), store: store)
            if !keys.contains(selection), let first = keys.first { selection = first }
            readAt = .now; error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
            store.handleManagementError(error)
        }
    }
}

// MARK: - 过去24小时流量图

private struct TrafficHistoryReading: Sendable {
    let enabled: Bool
    let history: [String: TrafficHistory]
}

private struct TrafficHistoryView: View {
    @Environment(RouterStore.self) var store
    @StateObject private var reading = RouterReading<TrafficHistoryReading>()
    @State private var selection = "INTERNET"
    @State private var hours = 24
    private var connected: Bool { store.phase == .connected }
    private var keys: [String] { TrafficInterfacePicker.visible(reading.value.map { Array($0.history.keys) } ?? [], store: store) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusPageHeader(title: "过去24小时流量图", subtitle: "路由器按 30 秒记录的各接口流量，最多 24 小时。页面打开时每 30 秒更新一次。",
                                 symbol: "chart.xyaxis.line", readAt: reading.readAt, loading: reading.loading) { await load() }
                ReadErrorLabel(message: reading.error)
                if !connected {
                    ConnectionRequiredView()
                } else if let value = reading.value {
                    if !value.enabled {
                        TrafficHistoryOffNotice()
                    } else if keys.isEmpty {
                        ContentUnavailableView("路由器还没有流量记录", systemImage: "chart.xyaxis.line", description: Text("流量记录开启后，路由器每 30 秒记录一次。"))
                    } else {
                        HStack {
                            TrafficInterfacePicker(keys: keys, selection: $selection)
                            Spacer()
                            Picker("显示", selection: $hours) { ForEach([1, 6, 12, 24], id: \.self) { Text("\($0) 小时").tag($0) } }
                                .pickerStyle(.segmented).labelsHidden().fixedSize()
                        }
                        let history = value.history[selection]
                        let samples = hours * 120
                        TrafficChartPanel(points: history?.points(lastSamples: samples, limit: 360, end: reading.readAt ?? .now) ?? [],
                                          wan: TrafficInterface.isWAN(selection), caption: "过去 \(hours) 小时 · 每点为 30 秒或更长时段的平均速度", empty: "这个接口还没有记录。")
                        TrafficSummaryTable(summary: history?.summary(lastSamples: samples), wan: TrafficInterface.isWAN(selection),
                                            note: "按路由器记录的过去 \(hours) 小时计算；即时流量值是最近 30 秒的平均速度。")
                        TrafficDirectionNote(wan: TrafficInterface.isWAN(selection))
                    }
                } else if reading.loading {
                    ReadingPlaceholder(failed: reading.error != nil && !reading.loading, minHeight: 220)
                }
            }.padding(28)
        }
        .onChange(of: keys) { _, keys in if !keys.contains(selection), let first = keys.first { selection = first } }
        .task(id: connected) {
            guard connected else { return }
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func load() async {
        await reading.load(store: store) { client in
            let enabled = try await client.trafficHistoryEnabled()
            var history: [String: TrafficHistory] = [:]
            if enabled { history = try await client.trafficHistory() }
            return TrafficHistoryReading(enabled: enabled, history: history)
        }
    }
}

// MARK: - 单日流量表 / Monthly

private struct TrafficRecordsReading: Sendable {
    let enabled: Bool
    let records: TrafficRecords
}

private struct TrafficRecordsView: View {
    @Environment(RouterStore.self) var store
    let monthly: Bool
    @StateObject private var reading = RouterReading<TrafficRecordsReading>()
    private var connected: Bool { store.phase == .connected }
    private var records: [TrafficRecord] { monthly ? reading.value?.records.monthly ?? [] : reading.value?.records.daily ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusPageHeader(title: monthly ? "Monthly" : "单日流量表",
                                 subtitle: (monthly ? "按月统计" : "按日统计") + "的互联网（WAN）流量，由路由器记录。接收即下载，传送即上传。",
                                 symbol: "calendar", readAt: reading.readAt, loading: reading.loading) { await load() }
                ReadErrorLabel(message: reading.error)
                if !connected {
                    ConnectionRequiredView()
                } else if let value = reading.value {
                    if !value.enabled {
                        TrafficHistoryOffNotice()
                    } else if records.isEmpty {
                        ContentUnavailableView("目前没有数据", systemImage: "calendar", description: Text("路由器每天记录一次，记录开启后的第二天开始出现。"))
                    } else {
                        if !monthly { lastThirtyDays }
                        chart
                        table
                    }
                } else if reading.loading {
                    ReadingPlaceholder(failed: reading.error != nil && !reading.loading, minHeight: 220)
                }
            }.padding(28)
        }
        .task(id: connected) { if connected, reading.value == nil { await load() } }
    }

    private func load() async {
        await reading.load(store: store) { client in
            let enabled = try await client.trafficHistoryEnabled()
            var records = TrafficRecords()
            if enabled { records = try await client.trafficRecords() }
            return TrafficRecordsReading(enabled: enabled, records: records)
        }
    }

    private func label(_ record: TrafficRecord) -> String {
        monthly ? String(format: "%d-%02d", record.year, record.month) : String(format: "%d-%02d-%02d", record.year, record.month, record.day)
    }
    private func date(_ record: TrafficRecord) -> Date? {
        Calendar.current.date(from: DateComponents(year: record.year, month: record.month, day: max(record.day, 1)))
    }
    /// The table's own date form, so the range above it reads the same way.
    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// The web's 过去 30 天 summary: the 30 days that end with the newest record.
    private var lastThirtyDays: some View {
        let newest = records.first.flatMap(date)
        let start = newest.flatMap { Calendar.current.date(byAdding: .day, value: -29, to: $0) }
        let span = records.filter { record in date(record).map { day in start.map { day >= $0 } ?? true } ?? false }
        let received = span.reduce(UInt64(0)) { $0 + $1.receivedKiB }, sent = span.reduce(UInt64(0)) { $0 + $1.sentKiB }
        return Panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("过去 30 天").font(.headline)
                    if let start, let newest { Text("\(Self.day.string(from: start)) ~ \(Self.day.string(from: newest))").font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                }
                HStack(spacing: 14) {
                    StatCard(title: "接收", value: Format.bytes(Double(received) * 1024), symbol: "arrow.down", tint: .teal, note: "下载")
                    StatCard(title: "传送", value: Format.bytes(Double(sent) * 1024), symbol: "arrow.up", tint: .blue, note: "上传")
                    StatCard(title: "总流量值", value: Format.bytes(Double(received + sent) * 1024), symbol: "sum", tint: .primary, note: "\(span.count) 天的记录")
                }
            }
        }
    }

    private var chart: some View {
        let shown = Array(records.prefix(monthly ? 24 : 30).reversed())
        let peak = shown.map { Double(max($0.receivedKiB, $0.sentKiB)) }.max() ?? 0
        let (unit, divisor) = peak >= 1024 * 1024 ? ("GB", 1024.0 * 1024) : ("MB", 1024.0)
        let period: Calendar.Component = monthly ? .month : .day
        return Panel {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text(monthly ? "每月流量" : "每日流量").font(.headline); Spacer(); Text("接收").foregroundStyle(.teal); Text("传送").foregroundStyle(.blue) }.font(.caption)
                Chart {
                    ForEach(shown) { record in
                        if let day = date(record) {
                            BarMark(x: .value("日期", day, unit: period), y: .value(unit, Double(record.receivedKiB) / divisor))
                                .foregroundStyle(.teal).position(by: .value("方向", "接收"))
                            BarMark(x: .value("日期", day, unit: period), y: .value(unit, Double(record.sentKiB) / divisor))
                                .foregroundStyle(.blue).position(by: .value("方向", "传送"))
                        }
                    }
                }
                .chartYAxisLabel(unit)
                // A date axis labels every few days (or months) instead of crowding one label under every bar.
                .chartXAxis {
                    AxisMarks(preset: .aligned, values: .stride(by: period, count: monthly ? (shown.count > 12 ? 3 : 1) : 5)) { _ in
                        AxisGridLine(); AxisTick()
                        // A format style formats in the process locale, not the view's, so it names Chinese itself.
                        AxisValueLabel(format: (monthly ? Date.FormatStyle.dateTime.year().month() : .dateTime.month().day()).locale(Locale(identifier: "zh_CN")))
                    }
                }
                .frame(height: 200)
            }
        }
    }

    private var table: some View {
        Panel {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                GridRow {
                    ForEach(["日期", "接收", "传送", "总流量值"], id: \.self) { Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(records) { record in
                    GridRow {
                        Text(label(record)).monospacedDigit()
                        // Flexible number columns spread the table across the panel instead of leaving it to one side.
                        Text(Format.bytes(Double(record.receivedKiB) * 1024)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing).gridColumnAlignment(.trailing)
                        Text(Format.bytes(Double(record.sentKiB) * 1024)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing).gridColumnAlignment(.trailing)
                        Text(Format.bytes(Double(record.totalKiB) * 1024)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing).gridColumnAlignment(.trailing)
                    }.font(.callout)
                }
            }
        }
    }
}

// MARK: - Shared pieces

/// The web's interface tabs: names and order from tmcal.js, LAN bridge and virtual radios left out.
private struct TrafficInterfacePicker: View {
    @Environment(RouterStore.self) var store
    let keys: [String]
    @Binding var selection: String

    static func visible(_ keys: [String], store: RouterStore) -> [String] {
        keys.filter { title($0, store: store) != nil }.sorted { (TrafficInterface.order($0), $0) < (TrafficInterface.order($1), $1) }
    }
    static func title(_ key: String, store: RouterStore) -> String? {
        TrafficInterface.title(key, wanTypes: store.currentWANTypes, lanPort: store.currentWANLANPort, radioBands: store.radioBands)
    }

    var body: some View {
        Picker("接口", selection: $selection) {
            ForEach(keys, id: \.self) { key in Text(Self.title(key, store: store) ?? key).tag(key) }
        }.pickerStyle(.segmented).labelsHidden().fixedSize()
    }
}

private struct TrafficChartPanel: View {
    let points: [TrafficRateWindow.Point]
    let wan: Bool
    let caption: String
    let empty: String

    var body: some View {
        let peak = points.map { max($0.received, $0.sent) }.max() ?? 0
        let (unit, divisor) = peak >= 1_000_000 ? ("MB/s", 1_000_000.0) : ("KB/s", 1_000.0)
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(caption).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(wan ? "接收（下载）" : "接收").foregroundStyle(.teal); Text(wan ? "传送（上传）" : "传送").foregroundStyle(.blue)
                }.font(.caption)
                if points.count > 1 {
                    Chart {
                        ForEach(points) { point in
                            LineMark(x: .value("时间", point.date), y: .value(unit, point.received / divisor), series: .value("方向", "接收\(point.segment)"))
                                .foregroundStyle(.teal).interpolationMethod(.linear)
                            LineMark(x: .value("时间", point.date), y: .value(unit, point.sent / divisor), series: .value("方向", "传送\(point.segment)"))
                                .foregroundStyle(.blue).interpolationMethod(.linear)
                        }
                    }
                    // Aligned marks keep the first and last time labels inside the plot instead of cutting them off.
                    .chartXAxis { AxisMarks(preset: .aligned) }
                    .chartYAxisLabel(unit).chartYScale(domain: .automatic(includesZero: true)).frame(height: 220)
                } else {
                    ContentUnavailableView("正在采集", systemImage: "waveform.path", description: Text(empty)).frame(height: 180)
                }
            }
        }
    }
}

/// The web's table under the chart: 即时、平均、最大 and 总流量值 for each direction.
private struct TrafficSummaryTable: View {
    let summary: TrafficRateWindow.Summary?
    let wan: Bool
    let note: String

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
                    GridRow {
                        Text("")
                        ForEach(["即时流量值", "平均流量值", "最大流量值", "总流量值"], id: \.self) { Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    row(wan ? "接收（下载）" : "接收", tint: .teal, summary.map { ($0.currentReceived, $0.averageReceived, $0.peakReceived, $0.totalReceived) })
                    row(wan ? "传送（上传）" : "传送", tint: .blue, summary.map { ($0.currentSent, $0.averageSent, $0.peakSent, $0.totalSent) })
                }
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ title: String, tint: Color, _ values: (Double, Double, Double, UInt64)?) -> some View {
        GridRow {
            Label(title, systemImage: "circle.fill").labelStyle(.titleAndIcon).foregroundStyle(tint).font(.callout.weight(.medium))
            Text(values.map { Format.speed($0.0) } ?? "—").monospacedDigit()
            Text(values.map { Format.speed($0.1) } ?? "—").monospacedDigit()
            Text(values.map { Format.speed($0.2) } ?? "—").monospacedDigit()
            Text(values.map { Format.bytes(Double($0.3)) } ?? "—").monospacedDigit()
        }.font(.callout)
    }
}

private struct TrafficDirectionNote: View {
    let wan: Bool
    var body: some View {
        if !wan {
            Text("有线和无线接口按路由器的角度统计：接收是设备发给路由器的数据，传送是路由器发给设备的数据。各接口会重复计算同一份流量，不能相加。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct TrafficHistoryOffNotice: View {
    @Environment(RouterStore.self) var store
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NoticeBanner(message: "路由器的流量记录没有开启（rstats_enable），因此没有历史数据。网页的流量监控各分页只读取这项设置，“Monitoring Settings”分页只设定保存位置和周期。", tone: .information)
            Button("查看即时流量图") { if let location = store.menuSet.location(of: .trafficMonitor(.realtime)) { store.navigate(.web(location)) } }.buttonStyle(.link)
        }
    }
}
