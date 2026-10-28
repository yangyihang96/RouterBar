import SwiftUI
import RouterCore

struct DeviceTrafficSummary: View {
    @ObservedObject var model: DeviceMonitorModel
    let devices: [RouterDevice]
    private var online: Set<String> { Set(devices.filter(\.isOnline).map(\.mac)) }
    private var rates: [DeviceTrafficRate] { model.rates.values.filter { online.contains($0.mac) } }
    var body: some View {
        let measured = rates
        HStack(spacing: 20) {
            metric("已统计设备下载", value: measured.isEmpty ? nil : measured.reduce(0) { $0 + $1.download }, symbol: "arrow.down", color: .teal)
            Divider().frame(height: 35)
            metric("已统计设备上传", value: measured.isEmpty ? nil : measured.reduce(0) { $0 + $1.upload }, symbol: "arrow.up", color: .blue)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Label("\(measured.count) / \(online.count) 台在线设备有统计", systemImage: "chart.bar.xaxis").font(.caption.weight(.medium))
                Text(measured.count == online.count && !online.isEmpty ? "连续采样 · 实际流量" : "缺失统计不计入合计").font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 16).padding(.vertical, 12).card()
            .help("合计仅包含当前有连续流量统计的在线设备，与概览的整个路由器流量口径不同。")
    }
    private func metric(_ title: String, value: Double?, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.caption2).foregroundStyle(.secondary)
            Text(Format.speed(value)).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(color)
        }
    }
}
