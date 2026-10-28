import SwiftUI
import Charts
import RouterCore

struct DeviceTrafficPanel: View {
    @ObservedObject var model: DeviceMonitorModel
    let mac: String
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "实际流量", subtitle: "来自路由器带宽监控，与无线链路协商速率分开显示。", symbol: "chart.xyaxis.line")
                if let rate = model.rates[mac] {
                    HStack {
                        Label("下载 " + Format.speed(rate.download), systemImage: "arrow.down").foregroundStyle(.teal)
                        Spacer()
                        Label("上传 " + Format.speed(rate.upload), systemImage: "arrow.up").foregroundStyle(.blue)
                    }.font(.headline).monospacedDigit()
                    let points = model.rateHistory[mac] ?? []
                    if points.count > 1 {
                        let useMB = points.contains { max($0.download, $0.upload) >= 1_000_000 }
                        let unit = useMB ? "MB/s" : "KB/s"
                        let divisor = useMB ? 1_000_000.0 : 1_000.0
                        Chart {
                            ForEach(points, id: \.date) { point in
                                LineMark(x: .value("时间", point.date), y: .value(unit, point.download / divisor), series: .value("方向", "下载")).foregroundStyle(.teal)
                                LineMark(x: .value("时间", point.date), y: .value(unit, point.upload / divisor), series: .value("方向", "上传")).foregroundStyle(.blue)
                            }
                        }.chartYAxisLabel(unit)
                            .chartXAxis {
                                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                                    AxisGridLine()
                                    AxisValueLabel { if let date = value.as(Date.self) { Text(MonitoringDate.time(date)) } }
                                }
                            }.frame(height: 125)
                            .accessibilityLabel("设备实际上传与下载的连续采样曲线")
                    } else {
                        Text("已取得实时速度，继续采样后显示变化曲线。").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("更新于 \(MonitoringDate.time(rate.date)) · 最近 \(points.count) 次连续采样").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("尚无这台设备的连续流量计数").font(.callout.weight(.medium))
                    Text(model.trafficStatus).font(.caption).foregroundStyle(.secondary)
                }
                Text("未统计到的流量不填为 0；采样中断后曲线重新开始，最多显示最近 60 次连续采样。").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
