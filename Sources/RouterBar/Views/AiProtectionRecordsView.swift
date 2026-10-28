import SwiftUI
import Charts
import RouterCore

/// AiProtection 网络神盾 › 恶意网站拦截, 双向 IPS and 受感染设备防止及拦截: the records the router already keeps, laid out
/// like the web page (安全事件, 客户端排名, the seven-day chart, 成功保护的事件). Only reads: the protections are switched on
/// the 网络保护 tab, and the white list, CSV export and deleting events stay on the web page.
struct AiProtectionRecordsView: View {
    @Environment(RouterStore.self) var store
    let kind: AiProtectionKind
    @StateObject private var reading = RouterReading<AiProtectionRecords>()
    @State private var expanded: Set<String> = []
    private var connected: Bool { store.phase == .connected }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusPageHeader(title: title, subtitle: subtitle, symbol: symbol, readAt: reading.readAt, loading: reading.loading) { await load() }
                ReadErrorLabel(message: reading.error)
                if !connected {
                    ConnectionRequiredView()
                } else if let records = reading.value {
                    if !records.isOn { switchNotice(records) }
                    summary(records)
                    chart(records)
                    events(records)
                } else {
                    ReadingPlaceholder(failed: reading.error != nil && !reading.loading, minHeight: 220)
                }
            }.padding(28)
        }
        .task(id: connected) { if connected, reading.value == nil { await load() } }
    }

    private func load() async { await reading.load(store: store) { try await $0.aiProtectionRecords(kind) } }

    private var title: String {
        switch kind { case .maliciousSites: "恶意网站拦截"; case .intrusionPrevention: "双向 IPS"; case .infectedDevices: "受感染设备防止及拦截" }
    }
    private var subtitle: String {
        switch kind {
        case .maliciousSites: "AiProtection 按趋势科技的数据库拦截已知恶意网站。这里显示路由器保存的拦截记录与统计。"
        case .intrusionPrevention: "双向 IPS 阻止外部攻击和设备向外发出的恶意连接。这里显示路由器保存的拦截记录与统计。"
        case .infectedDevices: "阻止受感染的设备与恶意服务器通信，防止私人信息外泄。这里显示路由器保存的拦截记录与统计。"
        }
    }
    private var symbol: String {
        switch kind { case .maliciousSites: "hand.raised"; case .intrusionPrevention: "shield.lefthalf.filled"; case .infectedDevices: "cross.case" }
    }

    // MARK: Sections

    private func switchNotice(_ records: AiProtectionRecords) -> some View {
        let reason = records.masterEnabled ? "这项保护的开关已关闭" : "AiProtection 网络神盾的总开关已关闭"
        return VStack(alignment: .leading, spacing: 8) {
            NoticeBanner(message: "“\(title)”目前没有开启：\(reason)。本页只显示路由器已有的记录，不会替你开启功能，也不会替你同意趋势科技的条款。", tone: .information)
            if let location = store.menuSet.location(ofSection: "aiprotection") {
                Button("查看“网络保护”分页的开关") { store.navigate(.web(location)) }.buttonStyle(.link)
            }
        }
    }

    private func summary(_ records: AiProtectionRecords) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
            StatCard(title: "安全事件", value: records.blocked.map { "拦截 \($0) 次" } ?? "—", symbol: "shield.checkered", tint: .teal,
                     note: records.since.map { "自 \(MonitoringDate.short($0)) 起" } ?? "路由器尚未开始统计")
            StatCard(title: "保护状态", value: records.isOn ? "已开启" : "未开启", symbol: records.isOn ? "checkmark.shield" : "shield.slash",
                     tint: records.isOn ? .green : .secondary, note: records.masterEnabled ? "AiProtection 总开关已开启" : "AiProtection 总开关已关闭")
            Panel {
                VStack(alignment: .leading, spacing: 10) {
                    Text("客户端排名").font(.headline)
                    if records.devices.isEmpty {
                        Text("未检测到事件").font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(records.devices.prefix(5)) { device in
                            HStack {
                                Button { if RouterParser.isMAC(device.device) { store.showDevice(device.device) } } label: {
                                    Text(name(device.device)).lineLimit(1)
                                }.buttonStyle(.plain)
                                Spacer()
                                Text("拦截 \(device.hits) 次").monospacedDigit().foregroundStyle(.secondary)
                            }.font(.callout)
                        }
                        if records.devices.count > 5 { Text("另有 \(records.devices.count - 5) 台设备").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }

    private struct ChartPoint: Identifiable {
        let id: String
        let day: Date
        let series: String
        let count: Int
    }

    private func chart(_ records: AiProtectionRecords) -> some View {
        let calendar = Calendar.current
        let last = calendar.startOfDay(for: records.chartEnd)
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0 - 6, to: last) }
        var series: [(String, [Int], Color)] = [("拦截", records.chart?.high ?? [], .orange)]
        if kind == .intrusionPrevention, let chart = records.chart {
            series = [("High", chart.high, .red), ("Medium", chart.medium, .yellow), ("Low", chart.low, .green)]
        }
        let points = series.flatMap { name, counts, _ in
            days.enumerated().map { index, day in ChartPoint(id: "\(name)-\(index)", day: day, series: name, count: index < counts.count ? counts[index] : 0) }
        }
        return Panel {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text("威胁活动").font(.headline); Spacer(); Text("最近 7 天，按本机日期标注").font(.caption).foregroundStyle(.secondary) }
                if records.chart == nil {
                    Text("路由器没有返回最近 7 天的统计。").font(.callout).foregroundStyle(.secondary)
                } else {
                    Chart(points) { point in
                        LineMark(x: .value("日期", point.day, unit: .day), y: .value("次数", point.count), series: .value("级别", point.series))
                            .foregroundStyle(by: .value("级别", point.series))
                        PointMark(x: .value("日期", point.day, unit: .day), y: .value("次数", point.count))
                            .foregroundStyle(by: .value("级别", point.series))
                    }
                    .chartForegroundStyleScale(domain: series.map(\.0), range: series.map(\.2))
                    .chartXAxis {
                        AxisMarks(values: days) { _ in
                            AxisGridLine(); AxisTick()
                            AxisValueLabel(format: Date.FormatStyle.dateTime.month(.defaultDigits).day().locale(Locale(identifier: "zh_CN")))
                        }
                    }
                    .chartYScale(domain: 0...max(4, points.map(\.count).max() ?? 0))
                    .frame(height: 180)
                }
            }
        }
    }

    private func events(_ records: AiProtectionRecords) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("成功保护的事件").font(.headline)
                    Spacer()
                    if !records.groups.isEmpty { Text("\(records.groups.count) 行，共 \(records.groups.reduce(0) { $0 + $1.times.count }) 个事件").font(.caption).foregroundStyle(.secondary) }
                }
                if records.groups.isEmpty {
                    Text("目前没有数据").font(.callout).foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
                        GridRow {
                            ForEach(columns, id: \.self) { Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                        }
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(records.groups) { group in
                            row(group)
                            if expanded.contains(group.id) {
                                // As the page opens a row: every event of the group with its time, source and destination.
                                ForEach(Array(group.events.enumerated()), id: \.offset) { _, event in
                                    GridRow {
                                        Text(event.time).monospacedDigit()
                                        ForEach(0..<(kind == .intrusionPrevention ? 2 : 1), id: \.self) { _ in Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                                        Text(name(event.source)).lineLimit(1)
                                        Text(event.destination).textSelection(.enabled)
                                    }.font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Text("时间是路由器记录的时间（路由器所设时区）。\(kind == .intrusionPrevention ? "威胁名称首词与目标相同" : "目标与来源相同")的事件合并为一行，点击箭头展开每个事件的时间、来源和目标。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var columns: [String] {
        kind == .intrusionPrevention ? ["时间", "级别", "类型", "来源", "目标", "威胁"] : ["时间", "威胁", "来源", "目标"]
    }

    @ViewBuilder private func row(_ group: AiProtectionEventGroup) -> some View {
        let event = group.first
        GridRow {
            HStack(spacing: 4) {
                Text(event.time).monospacedDigit()
                if group.times.count > 1 {
                    Button { if expanded.contains(group.id) { expanded.remove(group.id) } else { expanded.insert(group.id) } } label: {
                        Image(systemName: expanded.contains(group.id) ? "chevron.down" : "chevron.right")
                    }.buttonStyle(.borderless).help("共 \(group.events.count) 个事件")
                }
            }
            if kind == .intrusionPrevention {
                Circle().fill(severityColor(event.severity)).frame(width: 11, height: 11).help(event.severity ?? "")
                Text(direction(event.direction))
                Text(name(event.source)).lineLimit(1)
                Text(event.destination).textSelection(.enabled)
                Text(event.threat ?? "").textSelection(.enabled)
            } else {
                Text(event.category.map { kind.categoryName($0) ?? "类别 \($0)" } ?? "—")
                Text(name(event.source)).lineLimit(1)
                Text(event.destination).textSelection(.enabled)
            }
        }.font(.callout)
    }

    private func severityColor(_ severity: String?) -> Color {
        switch severity { case "H": .red; case "M": .yellow; default: .green }
    }
    /// The page's `direct_type` names.
    private func direction(_ value: Int?) -> String {
        switch value { case 1: "Device Infected"; case 2: "External Attacks"; default: "—" }
    }
    /// The web names a device by its client-list name and falls back to what the router recorded.
    private func name(_ device: String) -> String {
        store.snapshot?.sample.devices?.first { $0.mac == device }?.name ?? device
    }
}
