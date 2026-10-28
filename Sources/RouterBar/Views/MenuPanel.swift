import SwiftUI
import Charts
import RouterCore

struct MenuPanel: View {
    @Environment(RouterStore.self) var store
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let snapshot = store.snapshot {
                traffic(snapshot)
                HStack(spacing: 8) {
                    figure("在线", store.onlineCount, symbol: "laptopcomputer.and.iphone")
                    figure("CPU", Format.percent(snapshot.cpuPercent), symbol: "cpu")
                    figure("内存", Format.percent(snapshot.memoryPercent), symbol: "memorychip")
                }
                devices(snapshot)
                FreshnessView()
            } else {
                Text("连接路由器后，菜单栏会显示实时网络状态和在线设备。").font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let at = store.reconnectAt { ReconnectCountdown(at: at).font(.caption) }
            if store.credentialAccess.state.isWaiting {
                HStack { Image(systemName: "key.fill").foregroundStyle(.orange); Text("钥匙串操作进行中").font(.caption); Spacer(); Button("查看") { show { store.open(.connection) } }.buttonStyle(.link) }
            }
            footer
        }
        .padding(16).frame(width: 380)
    }

    private var header: some View {
        HStack(spacing: 11) {
            BrandIcon(size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(store.profile?.displayName ?? store.snapshot?.sample.identity.model ?? "路由器面板").font(.headline)
                StatusDot(color: store.statusColor, text: store.statusTitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("刷新路由器状态").disabled(store.phase != .connected || store.isRefreshing)
        }
    }

    private func traffic(_ snapshot: RouterSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                speed("下载", snapshot.downloadBytesPerSecond, symbol: "arrow.down", tint: .teal)
                Spacer(minLength: 8)
                speed("上传", snapshot.uploadBytesPerSecond, symbol: "arrow.up", tint: .blue)
            }
            if store.history.count > 1 {
                let points = Array(store.history.suffix(40))
                let current = points.last?.segment
                Chart {
                    ForEach(points.filter { $0.segment == current }) { point in
                        AreaMark(x: .value("时间", point.date), y: .value("下载", point.download))
                            .foregroundStyle(LinearGradient(colors: [.teal.opacity(0.3), .teal.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                    }
                    ForEach(points) { point in
                        LineMark(x: .value("时间", point.date), y: .value("下载", point.download), series: .value("方向", "下载\(point.segment)"))
                            .foregroundStyle(.teal).interpolationMethod(.monotone)
                        LineMark(x: .value("时间", point.date), y: .value("上传", point.upload), series: .value("方向", "上传\(point.segment)"))
                            .foregroundStyle(.blue.opacity(0.8)).interpolationMethod(.monotone)
                    }
                }
                .chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 54).accessibilityLabel("最近网络流量")
            }
        }
        .padding(14).background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }

    private func speed(_ label: String, _ value: Double?, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(label, systemImage: symbol).font(.caption).foregroundStyle(.secondary).labelStyle(TintedIconLabel(tint: tint))
            Text(Format.speed(value)).font(.system(size: 21, weight: .semibold, design: .rounded)).monospacedDigit()
        }
    }

    private func figure(_ label: String, _ value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(label, systemImage: symbol).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Theme.well, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    @ViewBuilder private func devices(_ snapshot: RouterSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("在线设备").font(.subheadline.weight(.semibold))
                Spacer()
                Button("查看全部") { show { store.open(.clients) } }.buttonStyle(.link).font(.caption)
            }
            if let devices = snapshot.onlineDevices {
                ForEach(Array(devices.prefix(5))) { device in
                    HStack(spacing: 10) {
                        DeviceGlyph(kind: store.kind(for: device), size: 28, online: device.isOnline)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(String(device.name.prefix(30))).font(.callout).lineLimit(1)
                            Text(store.kind(for: device).title).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(device.connectionLabel).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if devices.isEmpty { Text("暂无在线设备").font(.caption).foregroundStyle(.secondary) }
            } else {
                Text("设备列表暂不可用").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button(store.snapshot == nil ? "设置连接" : "打开面板") { show { if store.snapshot == nil { store.open(.connection) } else { store.open(.overview) } } }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
            if store.menuSet.location(of: .vpnStatus) != nil { Button("VPN") { show { store.open(.vpnStatus) } } }
            Spacer()
            Menu {
                Button("连接设置") { show { store.open(.connection) } }
                Button("设备历史与提醒") { show { store.open(.deviceHistory) } }
                Button("检查网络健康") { show { store.open(.health) } }
                if store.menuSet.location(of: .firmware) != nil { Button("固件升级") { show { store.open(.firmware) } } }
                Button("断开本机连接") { store.disconnect() }.disabled(store.phase != .connected)
                Divider()
                Button("退出路由器面板") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.top, 2)
    }

    /// Navigates the main window, then brings it forward.
    private func show(_ navigate: () -> Void) {
        navigate()
        openWindow(id: "dashboard")
        NSApp.activate(ignoringOtherApps: true)
    }
}
