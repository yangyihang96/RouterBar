import SwiftUI
import RouterCore

struct NetworkHealthView: View {
    @Environment(RouterStore.self) var store
    @ObservedObject var model: NetworkHealthModel
    private var severity: HealthSeverity { model.report?.severity ?? .unknown }
    private var statusColor: Color {
        switch severity { case .good: .teal; case .attention: .orange; case .failed: .red; case .unknown: .secondary }
    }
    private var statusSymbol: String {
        if model.running { return "waveform.path" }
        guard model.report != nil else { return "heart.text.clipboard" }
        switch severity { case .good: return "checkmark.shield"; case .attention: return "exclamationmark.shield"; case .failed: return "xmark.shield"; case .unknown: return "questionmark.circle" }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "网络健康", subtitle: "从本机连接到路由器、外网和 DNS，逐项确认哪里需要关注。", symbol: "heart.text.clipboard", eyebrow: "家庭网络")
                Panel {
                    HStack(spacing: 18) {
                        Image(systemName: statusSymbol).font(.system(size: 32)).foregroundStyle(statusColor)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(model.report?.title ?? "让网络状况更清楚").font(.title2.weight(.semibold))
                            Text(model.running ? model.progress : "检查不会更改设置。主动探测目标为 1.1.1.1 和 example.com。")
                                .font(.callout).foregroundStyle(.secondary)
                            if let date = model.report?.completedAt { Text("检查时间：\(MonitoringDate.full(date))").font(.caption).foregroundStyle(.secondary) }
                            if let report = model.report, !model.running {
                                HStack(spacing: 14) {
                                    Label("\(report.checks.filter { $0.severity == .good }.count) 项通过", systemImage: "checkmark.circle").foregroundStyle(.green)
                                    Label("\(report.checks.filter { $0.severity == .attention || $0.severity == .failed }.count) 项需关注", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                                    if report.checks.contains(where: { $0.severity == .unknown }) { Label("有未确认项", systemImage: "questionmark.circle").foregroundStyle(.secondary) }
                                }.font(.caption)
                            }
                        }
                        Spacer()
                        if model.running {
                            ProgressView().controlSize(.small)
                            Button("停止检查") { model.cancel() }
                        } else {
                            Button(model.report == nil ? "开始检查" : "重新检查") { model.run(store: store) }
                                .buttonStyle(.borderedProminent).controlSize(.large).tint(.teal)
                                .disabled(store.phase != .connected || store.operationTitle != nil)
                        }
                    }
                }
                if store.phase != .connected { ConnectionRequiredView() }
                if let report = model.report {
                    let concerns = report.checks.filter { $0.severity != .good }
                    let passed = report.checks.filter { $0.severity == .good }
                    if model.running || concerns.isEmpty {
                        ForEach(report.checks) { check in HealthCheckCard(check: check) }
                    } else {
                        SectionTitle(title: "优先查看", subtitle: "需要关注或尚未确认的结果显示在这里。", symbol: "exclamationmark.bubble")
                        ForEach(concerns) { check in HealthCheckCard(check: check) }
                        if !passed.isEmpty {
                            DisclosureGroup("已通过的检查（\(passed.count) 项）") {
                                VStack(spacing: 14) { ForEach(passed) { check in HealthCheckCard(check: check) } }.padding(.top, 12)
                            }
                        }
                    }
                    if report.canceled { NoticeBanner(message: "已停止等待。已启动的路由器探测可能继续自行结束，未完成项目不算检查通过。", tone: .information) }
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        Panel { SectionTitle(title: "连接路径", subtitle: "本机网络、管理接口、WAN 状态和外网探测", symbol: "network") }
                        Panel { SectionTitle(title: "设备与资源", subtitle: "关注设备、弱信号设备，以及路由器的内存、存储与温度", symbol: "desktopcomputer") }
                    }
                    NoticeBanner(message: "一次检查反映当前情况。外网目标可能限制 Ping；结果会保留不确定项，不会仅凭一次探测就判断整个网络断开。", tone: .information)
                }
                if model.recentReports.count > 1 {
                    DisclosureGroup("本次运行中的检查记录（\(model.recentReports.count)）") {
                        ForEach(model.recentReports) { report in
                            HStack { Text(report.title); Spacer(); Text(MonitoringDate.short(report.startedAt)).foregroundStyle(.secondary) }.font(.callout).padding(.vertical, 5)
                        }
                    }
                }
                Button("打开网络诊断") { store.open(.networkAnalysis) }.buttonStyle(.link)
            }.padding(30)
        }
    }
}
private struct HealthCheckCard: View {
    @Environment(RouterStore.self) var store
    let check: HealthCheck
    private var color: Color { switch check.severity { case .good: .green; case .attention: .orange; case .failed: .red; case .unknown: .secondary } }
    private var symbol: String { switch check.severity { case .good: "checkmark.circle.fill"; case .attention: "exclamationmark.circle.fill"; case .failed: "xmark.circle.fill"; case .unknown: "questionmark.circle" } }
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: symbol).font(.title2).foregroundStyle(color)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(check.title).font(.headline)
                        Text(check.summary).font(.callout)
                        if !check.advice.isEmpty { Text(check.advice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }
                    Spacer()
                }
                if !check.evidence.isEmpty {
                    DisclosureGroup("查看探测结果") { Text(check.evidence).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8) }
                }
                if let devices = check.relatedDevices {
                    Divider()
                    ForEach(devices) { device in
                        Button { store.showDevice(device.mac) } label: {
                            HStack(spacing: 12) {
                                DeviceGlyph(kind: store.deviceOverrides[device.mac] ?? device.kind, size: 32, online: check.id == "wifi")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(device.name).font(.callout.weight(.medium)).lineLimit(1)
                                    Text(device.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Label("查看设备", systemImage: "chevron.right").font(.caption).foregroundStyle(.teal)
                            }.padding(.vertical, 5).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
