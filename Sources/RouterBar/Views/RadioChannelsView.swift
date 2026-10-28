import SwiftUI
import RouterCore

/// Channel and bandwidth control embedded in the radio0 / radio1 professional settings sections.
/// Options come only from the router's own chanspec list; saving shares the current login and operation gate.
struct RadioChannelsView: View {
    @Environment(RouterStore.self) var store
    let unit: Int
    @State private var snapshot: RadioChannelSnapshot?
    @State private var bandwidth = RadioBandwidth.auto.rawValue
    @State private var chanspec = RadioChannelSnapshot.autoChanspec
    @State private var loading = false
    @State private var saving = false
    @State private var notice: String?
    @State private var verified = false
    @State private var needsReread = false
    @State private var confirming = false

    static func unit(forSectionID id: String) -> Int? { ["radio0": 0, "radio1": 1][id] }
    private var title: String { RadioBand(rawValue: unit)?.title ?? "无线" }
    private var changed: Bool { snapshot.map { $0.bandwidth != bandwidth || $0.chanspec != chanspec } ?? false }
    private var validation: String? {
        guard let snapshot, changed else { return nil }
        do { try snapshot.validate(bandwidth: bandwidth, chanspec: chanspec); return nil } catch { return error.localizedDescription }
    }
    private var width: RadioBandwidth { RadioBandwidth(rawValue: bandwidth) ?? .auto }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("\(title) 信道与频宽", systemImage: "dot.radiowaves.left.and.right").font(.headline)
                    Spacer()
                    if loading || saving { ProgressView().controlSize(.small) }
                    Button("重新读取") { Task { await load() } }.disabled(loading || saving)
                }
                if let notice {
                    Label(notice, systemImage: verified ? "checkmark.circle.fill" : "info.circle")
                        .font(.callout).foregroundStyle(verified ? .green : .orange).padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading).background((verified ? Color.green : .orange).opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                if let snapshot {
                    VStack(alignment: .leading, spacing: 2) {
                        KeyValue(key: "当前频宽", value: snapshot.currentBandwidthLabel)
                        KeyValue(key: "当前信道", value: snapshot.currentChanspecLabel)
                    }
                    Divider()
                    row("频宽", changed: snapshot.bandwidth != bandwidth) {
                        Picker("频宽", selection: Binding(get: { bandwidth }, set: { select(width: $0, in: snapshot) })) {
                            if RadioBandwidth(rawValue: bandwidth).map({ !snapshot.widths.contains($0) }) ?? true { Text("当前：\(bandwidth.isEmpty ? "未设置" : bandwidth)").tag(bandwidth) }
                            ForEach(snapshot.widths) { Text(snapshot.label(for: $0)).tag($0.rawValue) }
                        }
                    }
                    row("控制信道", changed: snapshot.chanspec != chanspec) {
                        Picker("控制信道", selection: $chanspec) {
                            let options = snapshot.options(for: width)
                            if !options.contains(where: { $0.raw == chanspec }) { Text("当前：\(chanspec.isEmpty ? "未设置" : chanspec)").tag(chanspec) }
                            ForEach(options) { Text($0.label).tag($0.raw) }
                        }
                    }
                    Text("已读取路由器当前允许的信道。5 GHz 的 160 MHz 选项会随“允许 160 MHz 频宽”开关更新。")
                        .font(.caption).foregroundStyle(.secondary)
                    if !snapshot.unsupportedChanspecs.isEmpty {
                        Text("路由器另提供 \(snapshot.unsupportedChanspecs.count) 项 240/320 MHz 信道，本应用暂不写入：\(snapshot.unsupportedChanspecs.joined(separator: "、"))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let validation { Text(validation).font(.callout).foregroundStyle(.red) }
                    HStack(spacing: 12) {
                        Label("保存会重启无线服务，\(title) 设备会暂时断开。", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("撤销") { bandwidth = snapshot.bandwidth; chanspec = snapshot.chanspec }.disabled(!changed)
                        Button("保存信道设置") { confirming = true }.buttonStyle(.borderedProminent).tint(.teal)
                            .disabled(!changed || validation != nil || needsReread)
                    }
                    if needsReread { Text("上次保存结果尚未确认，请先重新读取再进行新的修改。").font(.caption).foregroundStyle(.orange) }
                } else if !loading {
                    Text("尚未读取信道能力。点击重新读取。").font(.callout).foregroundStyle(.secondary)
                }
            }.disabled(store.operationTitle != nil || store.phase != .connected)
        }
        .task(id: unit) { await load() }
        .alert("确认更改 \(title) 信道与频宽？", isPresented: $confirming) {
            Button("取消", role: .cancel) {}
            Button("确认保存") { Task { await save() } }
        } message: {
            Text("\(summary)\n\n路由器会重启无线服务，连接路由器 Wi-Fi 的设备（可能包括这台 Mac）会暂时断开连接，约需 15–30 秒恢复。保存前会重新读取路由器能力并校验。")
        }
    }

    private var summary: String {
        guard let snapshot else { return "" }
        let after = RadioBandwidth(rawValue: bandwidth).map { snapshot.label(for: $0) } ?? bandwidth
        let channel = snapshot.options(for: width).first { $0.raw == chanspec }?.label ?? chanspec
        return "频宽：\(snapshot.currentBandwidthLabel) → \(after)\n信道：\(snapshot.currentChanspecLabel) → \(channel)"
    }

    private func row<Content: View>(_ label: String, changed: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 18) {
            HStack(spacing: 6) { if changed { Circle().fill(.teal).frame(width: 5, height: 5) }; Text(label).font(.callout) }.frame(maxWidth: .infinity, alignment: .leading)
            content().labelsHidden().frame(width: 260).accessibilityLabel(label)
        }
    }

    /// Changing width keeps the chosen channel only if it is legal for the new width.
    private func select(width raw: String, in snapshot: RadioChannelSnapshot) {
        bandwidth = raw
        guard let width = RadioBandwidth(rawValue: raw) else { return }
        let options = snapshot.options(for: width)
        if !options.contains(where: { $0.raw == chanspec }) {
            chanspec = options.first(where: { $0.raw == RadioChannelSnapshot.autoChanspec })?.raw ?? options.first?.raw ?? chanspec
        }
    }

    func load() async {
        guard !loading, !saving else { return }
        loading = true; defer { loading = false }
        do {
            let fresh = try await store.connectedClient().readRadioChannels(unit: unit)
            snapshot = fresh; bandwidth = fresh.bandwidth; chanspec = fresh.chanspec; needsReread = false
            if !verified { notice = nil }
        } catch is CancellationError {
        } catch {
            snapshot = nil; verified = false; notice = error.localizedDescription; store.handleManagementError(error)
        }
    }

    func save() async {
        guard let snapshot, changed, validation == nil, !saving, store.beginOperation("正在保存 \(title) 信道与频宽") else { return }
        let change = RadioChannelChange(snapshot: snapshot, bandwidth: bandwidth, chanspec: chanspec)
        saving = true; notice = nil; verified = false
        defer { saving = false; store.endOperation() }
        do {
            let receipt = try await store.connectedClient().applyRadioChannels(change)
            notice = receipt.message; verified = receipt.isVerified
            if receipt.isVerified { self.snapshot = snapshot.replacing(bandwidth: change.afterBandwidth, chanspec: change.afterChanspec) }
            else { needsReread = true }
        } catch { notice = error.localizedDescription; store.handleManagementError(error) }
    }
}
