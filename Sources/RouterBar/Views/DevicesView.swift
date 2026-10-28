import SwiftUI
import RouterCore

struct DevicesView: View {
    @Environment(RouterStore.self) var store
    @ObservedObject var monitor: DeviceMonitorModel
    @State private var search = ""
    @State private var filter = "在线"
    @State private var family = "全部类型"
    @State private var selection: String?
    @AppStorage("deviceLayout") private var layout = "grid"
    @AppStorage("deviceSortOrder") private var sortOrder: DeviceSortOrder = .name
    private let filters = ["在线", "全部", "无线", "有线", "离线"]
    private var baseDevices: [RouterDevice] {
        (store.snapshot?.sample.devices ?? []).filter { d in
            switch filter {
            case "在线": return d.isOnline
            case "无线": return d.isOnline && (d.band ?? 0) > 0
            case "有线": return d.isOnline && d.band == 0
            case "离线": return !d.isOnline
            default: return true
            }
        }
    }
    private var devices: [RouterDevice] {
        sortOrder.sorted(baseDevices.filter { d in
            (family == "全部类型" || store.kind(for: d).family == family) &&
            (search.isEmpty || [d.name, d.mac, d.ip ?? "", d.vendor ?? "", store.kind(for: d).title].contains { $0.localizedCaseInsensitiveContains(search) })
        }, rates: monitor.rates)
    }
    private var selected: RouterDevice? { store.snapshot?.sample.devices?.first { $0.id == selection } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    PageHeader(title: "连接设备", subtitle: "\(store.onlineCount) 台在线 · 查看设备类型、信号与上网权限", symbol: "laptopcomputer.and.iphone", eyebrow: "家庭网络")
                    Spacer(); FreshnessView()
                }
                HStack(spacing: 12) {
                    Picker("连接状态", selection: $filter) { ForEach(filters, id: \.self) { Text($0) } }.pickerStyle(.segmented).frame(width: 300)
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索设备、类型、IP 或 MAC", text: $search).textFieldStyle(.plain)
                        if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
                    }.padding(.horizontal, 10).padding(.vertical, 7).card(radius: 8)
                    Picker("显示方式", selection: $layout) {
                        Image(systemName: "square.grid.2x2").tag("grid")
                        Image(systemName: "list.bullet").tag("list")
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 76)
                }
                HStack(spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(["全部类型", "个人设备", "智能家居", "影音娱乐", "网络与存储", "待识别"], id: \.self) { item in
                            let count = baseDevices.filter { item == "全部类型" || store.kind(for: $0).family == item }.count
                            Button { family = item } label: {
                                HStack(spacing: 6) { Text(item); Text("\(count)").monospacedDigit().opacity(0.65) }
                                    .font(.caption.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(family == item ? Theme.accent.opacity(0.14) : Theme.card, in: Capsule())
                                    .overlay(Capsule().strokeBorder(family == item ? Color.clear : Theme.hairline, lineWidth: 0.5))
                                    .foregroundStyle(family == item ? Theme.accent : Color.secondary)
                            }.buttonStyle(.plain)
                        }
                    }
                }
                Picker("排序", selection: $sortOrder) {
                    ForEach(DeviceSortOrder.allCases, id: \.self) { Text($0.title).tag($0) }
                }.frame(width: 138)
                }
                if let devices = store.snapshot?.sample.devices { DeviceTrafficSummary(model: monitor, devices: devices) }
            }.padding(24)
            if store.snapshot?.sample.devices == nil {
                ContentUnavailableView("设备列表暂不可用", systemImage: "network", description: Text("连接路由器并成功读取后，设备会出现在这里。"))
            } else if devices.isEmpty {
                ContentUnavailableView("没有匹配的设备", systemImage: "magnifyingglass", description: Text("尝试更换筛选条件或搜索内容。"))
            } else if layout == "grid" {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 340), spacing: 14)], spacing: 14) {
                        ForEach(devices) { device in
                            Button { selection = device.id } label: { DeviceCard(device: device, kind: store.kind(for: device), rate: monitor.rates[device.mac], watched: monitor.record(device.mac)?.watched == true) }.buttonStyle(.plain)
                                .contextMenu { copyActions(device) }
                        }
                    }.padding(.horizontal, 24).padding(.bottom, 16)
                }
            } else {
                Table(devices, selection: $selection) {
                    TableColumn("设备") { device in
                        HStack(spacing: 10) {
                            DeviceGlyph(kind: store.kind(for: device), size: 34, online: device.isOnline)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(device.name).fontWeight(.medium).lineLimit(1)
                                Text(store.kind(for: device).title).font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 5)
                    }.width(min: 180, ideal: 230)
                    TableColumn("IP 地址") { Text($0.ip ?? "—").font(.system(.callout, design: .monospaced)) }.width(120)
                    TableColumn("连接") { Text($0.connectionLabel).foregroundStyle(.secondary) }.width(65)
                    TableColumn("实际下载") { Text(Format.speed(monitor.rates[$0.mac]?.download)).font(.caption).monospacedDigit().foregroundStyle(.teal) }.width(85)
                    TableColumn("实际上传") { Text(Format.speed(monitor.rates[$0.mac]?.upload)).font(.caption).monospacedDigit().foregroundStyle(.blue) }.width(85)
                    TableColumn("信号") { d in HStack { SignalBars(rssi: d.rssi); Text(d.rssi.map { "\($0)" } ?? "—").font(.caption).monospacedDigit() } }.width(65)
                    TableColumn("状态") { Text($0.isOnline ? "在线" : "离线").font(.caption).foregroundStyle($0.isOnline ? .green : .secondary) }.width(45)
                }.contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first, let d = devices.first(where: { $0.id == id }) { copyActions(d) }
                }
            }
            HStack { Text("显示 \(devices.count) 台"); Spacer(); Text(monitor.trafficStatus).lineLimit(1); Button("设备历史") { monitor.selectedMAC = nil; store.open(.deviceHistory) }.buttonStyle(.link) }.font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 12)
        }
        .sheet(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selection = nil } })) {
            if let device = selected { DeviceDetailView(device: device, monitor: monitor).environment(store) }
        }
        .onChange(of: store.requestedDeviceMAC, initial: true) { _, mac in
            if let mac { selection = mac; store.requestedDeviceMAC = nil }
        }
    }
    @ViewBuilder private func copyActions(_ device: RouterDevice) -> some View {
        Button("查看设备详情") { selection = device.id }
        Button("复制 IP 地址") { copy(device.ip ?? "") }.disabled(device.ip == nil)
        Button("复制 MAC 地址") { copy(device.mac) }
    }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
}

struct DeviceCard: View {
    let device: RouterDevice
    let kind: DeviceKind
    var rate: DeviceTrafficRate?
    var watched = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                DeviceGlyph(kind: kind, size: 46, online: device.isOnline)
                Spacer()
                if watched { Image(systemName: "bell.badge.fill").font(.caption).foregroundStyle(.teal) }
                HStack(spacing: 5) { Circle().fill(device.isOnline ? Color.green : .secondary).frame(width: 5, height: 5); Text(device.isOnline ? "在线" : "离线") }
                    .font(.caption2).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(device.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(kind.title).font(.caption).foregroundStyle(kind.tint)
            }
            Divider().opacity(0.6)
            HStack { Text("↓ " + Format.speed(rate?.download)); Spacer(); Text("↑ " + Format.speed(rate?.upload)) }
                .font(.caption.monospacedDigit()).foregroundStyle(.teal).help("路由器统计的实际流量；— 表示暂未取得连续计数")
            HStack(spacing: 4) {
                Text(device.ip ?? "无 IP 地址").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if device.band == 0 { Image(systemName: "cable.connector").foregroundStyle(.secondary) } else { SignalBars(rssi: device.rssi) }
                Text(device.connectionLabel).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
            .card(radius: 14)
    }
}

struct DeviceDetailView: View {
    @Environment(RouterStore.self) var store
    @Environment(\.dismiss) private var dismiss
    let device: RouterDevice
    @ObservedObject var monitor: DeviceMonitorModel
    private var kind: DeviceKind { store.kind(for: device) }
    @State private var deviceName = ""
    @State private var managementNotice: String?
    /// Renaming and pausing follow the 3.0.0.6 web code: on another firmware line, or before the router is identified,
    /// they wait (RouterClient refuses them too).
    private var writeRefusal: String? { store.phase == .connected ? store.writeScope.referenceWebRefusal : nil }
    @State private var pendingAction: String?
    @State private var confirmAction = false
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                DeviceGlyph(kind: kind, size: 64, online: device.isOnline)
                VStack(alignment: .leading, spacing: 6) { Text(device.name).font(.title2.weight(.semibold)); Text(kind.title).foregroundStyle(kind.tint) }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary) }.buttonStyle(.plain)
            }
            Panel {
                VStack(spacing: 8) {
                    KeyValue(key: "IP 地址", value: device.ip ?? "暂不可用")
                    KeyValue(key: "MAC 地址", value: device.mac)
                    KeyValue(key: "厂商", value: device.vendor ?? "未知")
                    KeyValue(key: "网络", value: device.ssid ?? device.connectionLabel)
                    KeyValue(key: "信号", value: device.rssi.map { "\($0) dBm" } ?? "—")
                    KeyValue(key: "接收 / 发送链路", value: [device.rxLinkMbps, device.txLinkMbps].map { $0.map { String(format: "%.1f", $0) } ?? "—" }.joined(separator: " / ") + " Mbps")
                    KeyValue(key: "连接时长", value: device.connectionTime ?? "—")
                    KeyValue(key: "互联网访问", value: device.internetAllowed.map { $0 ? "允许" : "已暂停" } ?? "状态未提供")
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("设备识别", systemImage: "sparkle").font(.headline)
                    Spacer()
                    Picker("设备类型", selection: Binding(get: { store.deviceOverrides[device.mac]?.rawValue ?? "auto" }, set: { store.setKind(DeviceKind(rawValue: $0), for: device) })) {
                        Text("自动识别").tag("auto")
                        ForEach(DeviceKind.allCases) { Text($0.title).tag($0.rawValue) }
                    }.labelsHidden().frame(width: 180)
                }
                Text(store.deviceOverrides[device.mac] != nil ? "使用你为这台设备指定的本机分类。" : device.classification.reason + " · 可信度：" + device.classification.confidence)
                    .font(.caption).foregroundStyle(.secondary)
                Text("链路速率是设备与路由器的协商速率，不代表实际下载速度。").font(.caption2).foregroundStyle(.secondary)
            }
            Divider()
            DeviceTrafficPanel(model: monitor, mac: device.mac)
            DeviceActivitySection(model: monitor, mac: device.mac)
            Button("查看这台设备的完整历史") { monitor.selectedMAC = device.mac; store.open(.deviceHistory); dismiss() }.buttonStyle(.link)
            VStack(alignment: .leading, spacing: 12) {
                Text("路由器上的设备设置").font(.headline)
                if let writeRefusal { Text(writeRefusal).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                HStack { TextField("设备名称", text: $deviceName).textFieldStyle(.roundedBorder); Button("保存名称") { pendingAction = "rename"; confirmAction = true }.disabled(deviceName == device.name || deviceName.isEmpty) }
                HStack {
                    Button("暂停上网") { pendingAction = "pause"; confirmAction = true }.disabled(device.isCurrentDevice)
                    Button("恢复上网") { pendingAction = "resume"; confirmAction = true }
                    Spacer()
                }
                if let managementNotice { Text(managementNotice).font(.caption).foregroundStyle(.secondary) }
            }.disabled(store.operationTitle != nil || store.phase != .connected || writeRefusal != nil)
            HStack { Spacer(); Button("完成") { dismiss() }.buttonStyle(.borderedProminent).tint(.teal).keyboardShortcut(.defaultAction) }
        }.padding(28)
        }.frame(width: 620, height: 720)
        .onAppear { deviceName = device.name }
        .confirmationDialog("确认修改这台设备？", isPresented: $confirmAction, titleVisibility: .visible) {
            Button(pendingAction == "rename" ? "保存名称" : pendingAction == "pause" ? "暂停上网" : "恢复上网") { Task { await manageDevice() } }
        } message: { Text(pendingAction == "rename" ? "新名称会保存到路由器。" : "将修改 \(device.name) 的互联网访问规则，设备仍可连接本地网络。") }
    }
    private func manageDevice() async {
        guard let action = pendingAction, store.beginOperation("正在更新设备设置") else { return }
        defer { store.endOperation(); Task { await store.refresh() } }
        do {
            let client = try store.connectedClient()
            if action == "rename" { managementNotice = try await client.renameDevice(mac: device.mac, name: deviceName).message; return }
            let pausing = action == "pause"
            let result = try await client.setInternetPaused(mac: device.mac, name: device.name, paused: pausing, resumeState: PausedRuleMemory.state(for: device.mac))
            // A rule created by this pause has no earlier schedule; an already blocked rule keeps what was remembered.
            if !pausing || result.priorState != "2" { PausedRuleMemory.remember(pausing ? result.priorState : nil, mac: device.mac) }
            managementNotice = result.receipt.message
        } catch { managementNotice = error.localizedDescription; store.handleManagementError(error) }
    }
}

/// The device's parental-control state from before RouterBar paused it, so resuming can restore a time schedule.
private enum PausedRuleMemory {
    private static let key = "pausedDeviceRuleStates"
    static func state(for mac: String) -> String { (UserDefaults.standard.dictionary(forKey: key)?[mac.uppercased()] as? String) ?? "0" }
    static func remember(_ state: String?, mac: String) {
        var states = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        states[mac.uppercased()] = state == "1" ? "1" : nil
        UserDefaults.standard.set(states, forKey: key)
    }
}
