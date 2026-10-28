import SwiftUI
import RouterCore

/// 系统记录 › 无线用户: the devices on each Wi-Fi band as the router last reported them, refreshed with the panel.
struct WirelessClientsView: View {
    @Environment(RouterStore.self) var store

    private var devices: [RouterDevice] { (store.snapshot?.sample.devices ?? []).filter { $0.isOnline && ($0.band ?? 0) > 0 } }
    private var bands: [Int] { Set(devices.compactMap(\.band)).sorted() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 15) {
                    PageHeader(title: "无线用户", subtitle: "按频段列出正在使用 Wi-Fi 的设备、信号强度与连接速率。点击设备名称查看详情。", symbol: "wifi")
                    Spacer()
                    FreshnessView()
                }
                if store.snapshot == nil {
                    if store.phase == .connected { ProgressView("正在读取…").frame(maxWidth: .infinity, minHeight: 200) } else { ConnectionRequiredView() }
                } else if store.snapshot?.sample.devices == nil {
                    ContentUnavailableView("路由器没有返回设备列表", systemImage: "wifi.exclamationmark", description: Text("稍后刷新再查看。"))
                } else if devices.isEmpty {
                    ContentUnavailableView("没有在线的无线设备", systemImage: "wifi.slash")
                } else {
                    ForEach(bands, id: \.self) { band in bandPanel(band) }
                }
            }.padding(28)
        }
    }

    private func bandPanel(_ band: Int) -> some View {
        let list = devices.filter { $0.band == band }.sorted { ($0.rssi ?? -200) > ($1.rssi ?? -200) }
        return Panel {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(title: "\(list.first?.connectionLabel ?? "无线") · \(list.count) 台", symbol: "dot.radiowaves.left.and.right")
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                    GridRow {
                        ForEach(["设备", "MAC 地址", "IP 地址", "信号", "速率（发送 / 接收）", "已连接", "网络名称"], id: \.self) {
                            Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(list) { device in
                        GridRow {
                            Button { store.showDevice(device.mac) } label: {
                                Label(device.name, systemImage: store.kind(for: device).symbol).lineLimit(1).frame(maxWidth: 220, alignment: .leading)
                            }.buttonStyle(.link)
                            Text(device.mac).font(.caption.monospaced()).textSelection(.enabled)
                            Text(device.ip ?? "—").font(.caption.monospaced()).textSelection(.enabled)
                            HStack(spacing: 6) {
                                SignalBars(rssi: device.rssi)
                                Text(device.rssi.map { "\($0) dBm" } ?? "—").font(.caption).monospacedDigit()
                            }
                            Text(rate(device)).font(.caption).monospacedDigit()
                            Text(device.connectionTime ?? "—").font(.caption).monospacedDigit()
                            Text(device.ssid ?? "—").font(.caption).lineLimit(1)
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func rate(_ device: RouterDevice) -> String {
        func mbps(_ value: Double?) -> String { value.map { String(format: "%.0f", $0) } ?? "—" }
        return "\(mbps(device.txLinkMbps)) / \(mbps(device.rxLinkMbps)) Mbps"
    }
}
