import SwiftUI
import Charts
import RouterCore

struct OverviewView: View {
    @Environment(RouterStore.self) var store
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gap) {
                if let snapshot = store.snapshot {
                    hero(snapshot)
                    traffic
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.gap), count: 4), spacing: Theme.gap) {
                        StatCard(title: "在线设备", value: store.onlineCount, symbol: "laptopcomputer.and.iphone", tint: .blue, note: deviceSummary)
                        MeterTile(title: "CPU", percent: snapshot.cpuPercent, symbol: "cpu", tint: .teal,
                                  note: snapshot.cpuPercent == nil ? "等待下一次采样" : "所有核心平均")
                        MeterTile(title: "内存", percent: snapshot.memoryPercent, symbol: "memorychip", tint: .indigo, note: memoryNote(snapshot))
                        StatCard(title: "持续运行", value: Format.uptime(snapshot.sample.uptime), symbol: "clock.arrow.circlepath", tint: .orange, note: "自路由器上次启动")
                    }
                    HStack(alignment: .top, spacing: Theme.gap) {
                        connection(snapshot)
                        shortcuts
                    }.fixedSize(horizontal: false, vertical: true)
                    if !snapshot.sample.unavailable.isEmpty {
                        Label("暂不可用：" + snapshot.sample.unavailable.joined(separator: "、"), systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    ContentUnavailableView {
                        Label("连接你的华硕路由器", systemImage: "wifi.router")
                    } description: { Text("连接后即可查看网络状态、在线设备和实时流量。") }
                      actions: { Button("设置连接") { store.open(.connection) }.buttonStyle(.borderedProminent).tint(Theme.accent) }
                        .frame(maxWidth: .infinity, minHeight: 360)
                }
            }.padding(Theme.page)
        }
    }

    // MARK: Parts

    private func hero(_ snapshot: RouterSnapshot) -> some View {
        HStack(alignment: .center, spacing: 20) {
            BrandIcon(size: 66)
            VStack(alignment: .leading, spacing: 7) {
                Text(store.profile?.displayName ?? snapshot.sample.identity.model).font(.system(size: 24, weight: .semibold))
                HStack(spacing: 10) { StatusBadge(); FreshnessView() }
                Text("固件 \(store.profile?.firmwareVersion ?? snapshot.sample.identity.firmware)" + (store.profile.map { " · \($0.family == .merlin ? "Asuswrt-Merlin" : "华硕原厂固件")" } ?? ""))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            speed("下载", snapshot.downloadBytesPerSecond, symbol: "arrow.down", tint: .teal)
            Rectangle().fill(Theme.hairline).frame(width: 0.5, height: 46)
            speed("上传", snapshot.uploadBytesPerSecond, symbol: "arrow.up", tint: .blue)
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading).card()
    }

    private func speed(_ label: String, _ value: Double?, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(label, systemImage: symbol).font(.subheadline).foregroundStyle(.secondary).labelStyle(TintedIconLabel(tint: tint))
            Text(Format.speed(value)).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
        }.frame(minWidth: 132, alignment: .leading)
    }

    private var traffic: some View {
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("网络流量").font(.headline)
                    Text(trafficSpan).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    legend("下载", .teal); legend("上传", .blue)
                }
                if store.history.count > 1 {
                    let current = store.history.last?.segment
                    Chart {
                        ForEach(store.history.filter { $0.segment == current }) { point in
                            AreaMark(x: .value("时间", point.date), y: .value("MB/s", point.download / 1_000_000))
                                .foregroundStyle(LinearGradient(colors: [.teal.opacity(0.28), .teal.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                                .interpolationMethod(.monotone)
                        }
                        ForEach(store.history) { point in
                            LineMark(x: .value("时间", point.date), y: .value("MB/s", point.download / 1_000_000), series: .value("流量", "下载\(point.segment)"))
                                .foregroundStyle(.teal).lineStyle(StrokeStyle(lineWidth: 2)).interpolationMethod(.monotone)
                            LineMark(x: .value("时间", point.date), y: .value("MB/s", point.upload / 1_000_000), series: .value("流量", "上传\(point.segment)"))
                                .foregroundStyle(.blue).lineStyle(StrokeStyle(lineWidth: 1.5)).interpolationMethod(.monotone)
                        }
                    }
                    .chartYScale(domain: .automatic(includesZero: true))
                    .chartYAxis { AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(Theme.hairline)
                        AxisValueLabel { if let number = value.as(Double.self) { Text(String(format: number < 10 ? "%.1f" : "%.0f", number)) } }
                    } }
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { value in
                        AxisValueLabel { if let date = value.as(Date.self) { Text(Self.clock.string(from: date)) } }
                    } }
                    .chartYAxisLabel("MB/s")
                    .frame(height: 170)
                } else {
                    ContentUnavailableView("正在采集流量", systemImage: "waveform.path", description: Text("收到连续采样后，将显示实际速度曲线。"))
                        .frame(height: 150)
                }
            }
        }
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 5) { RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 12, height: 3); Text(title) }
            .font(.caption).foregroundStyle(.secondary)
    }

    private func connection(_ snapshot: RouterSnapshot) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                Text("连接信息").font(.headline)
                VStack(spacing: 0) {
                    row("局域网", snapshot.sample.identity.lanAddress ?? "暂不可用")
                    Divider()
                    row("WAN IP", snapshot.sample.identity.wanAddress ?? "暂不可用")
                    Divider()
                    row("型号", modelText(snapshot))
                    Divider()
                    row("频段", store.profile.map { $0.radios.map(\.title).joined(separator: " · ") }.flatMap { $0.isEmpty ? nil : $0 } ?? "—")
                }
            }.frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func row(_ key: String, _ value: String) -> some View { KeyValue(key: key, value: value).padding(.vertical, 5) }
    private func modelText(_ snapshot: RouterSnapshot) -> String {
        guard let profile = store.profile else { return snapshot.sample.identity.model }
        if let marketed = profile.marketedModel, marketed != profile.model { return "\(marketed)（\(profile.model)）" }
        return profile.model
    }

    private var shortcuts: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                Text("常用").font(.headline)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    if store.menuSet.location(of: .clients) != nil { shortcut("客户端", "laptopcomputer.and.iphone", .blue) { store.open(.clients) } }
                    shortcut("设备历史", LocalPage.deviceHistory.symbol, Theme.tint(local: .deviceHistory)) { store.open(.deviceHistory) }
                    shortcut("网络健康", LocalPage.health.symbol, Theme.tint(local: .health)) { store.open(.health) }
                    if store.menuSet.location(of: .vpnStatus) != nil { shortcut("VPN 状态", "lock.shield", .purple) { store.open(.vpnStatus) } }
                    if store.menuSet.location(of: .firmware) != nil { shortcut("固件升级", "arrow.down.circle", .gray) { store.open(.firmware) } }
                    if store.menuSet.location(of: .systemInfo) != nil { shortcut("系统信息", "info.circle", .gray) { store.open(.systemInfo) } }
                }
            }.frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func shortcut(_ title: String, _ symbol: String, _ tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                SymbolTile(symbol: symbol, tint: tint, size: 26)
                Text(title).font(.callout)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Theme.well, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var trafficSpan: String {
        let minutes = Int((store.history.first.map { Date().timeIntervalSince($0.date) } ?? 0) / 60)
        return minutes < 1 ? "整个家庭网络 · 刚开始记录" : "整个家庭网络 · 最近 \(minutes) 分钟"
    }
    /// 24-hour clock times on the chart, as the rest of the app writes them.
    static let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    private var deviceSummary: String {
        guard let clients = store.snapshot?.onlineDevices else { return "设备列表暂不可用" }
        let wired = clients.filter { $0.band == 0 }.count
        let wireless = clients.filter { ($0.band ?? 0) > 0 }.count
        return "\(wireless) 台无线 · \(wired) 台有线"
    }
    private func memoryNote(_ snapshot: RouterSnapshot) -> String {
        guard let used = snapshot.sample.memoryUsedKiB, let total = snapshot.sample.memoryTotalKiB else { return "未返回内存用量" }
        return "\((used / 1024).rounded().clampedInt) / \((total / 1024).rounded().clampedInt) MB"
    }
}

/// A percentage with a bar under it.
struct MeterTile: View {
    let title: String
    let percent: Double?
    let symbol: String
    let tint: Color
    var note: String? = nil
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Image(systemName: symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(tint)
                    Text(title).font(.subheadline).foregroundStyle(.secondary)
                }
                Text(Format.percent(percent)).font(.system(size: 25, weight: .semibold, design: .rounded)).monospacedDigit()
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.well)
                        Capsule().fill(tint.gradient).frame(width: geometry.size.width * min(1, max(0, (percent ?? 0) / 100)))
                    }
                }.frame(height: 5)
                if let note { Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }.frame(minHeight: StatCard.height, alignment: .topLeading)
        }
    }
}

/// A label whose icon has its own color.
struct TintedIconLabel: LabelStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) { configuration.icon.foregroundStyle(tint).font(.caption.weight(.bold)); configuration.title }
    }
}
