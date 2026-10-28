import SwiftUI
import RouterCore

struct DeviceHistoryView: View {
    @Environment(RouterStore.self) var store
    @ObservedObject var model: DeviceMonitorModel
    @State private var search = ""
    @State private var onlyWatched = false
    @State private var visibleLimit = 200
    @AppStorage("historyEventFilter") private var eventFilter: PresenceHistoryFilter = .changes
    @AppStorage("historyWindowDays") private var days = 7
    private var records: [DevicePresenceRecord] {
        model.records.filter { (!onlyWatched || $0.watched) && PresenceHistoryQuery.matches($0, search: search) }
    }
    private var filteredEvents: [PresenceEvent] {
        PresenceHistoryQuery.events(model.tracker.archive.events, records: model.tracker.archive.records,
            mac: model.selectedMAC, watchedOnly: onlyWatched, search: search, filter: eventFilter,
            since: Date().addingTimeInterval(-Double(max(1, min(30, days))) * 86400))
    }
    var body: some View {
        HStack(spacing: 0) {
            deviceList
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PageHeader(title: model.selectedMAC.flatMap { model.record($0)?.name } ?? "设备在线历史",
                        subtitle: "真实上下线变化集中呈现，发现记录与恢复监测可单独查看。", symbol: "clock.arrow.circlepath", eyebrow: "家庭网络")
                    if let notice = model.storageNotice { NoticeBanner(message: notice, tone: .attention) }
                    if !model.isMonitoring { NoticeBanner(message: "监测已暂停，历史记录仍可查看。恢复后与暂停前的状态比较：只记录有变化的设备并标注“暂停期间”，离线仍需连续 3 分钟确认，不补猜具体时间。", tone: .information) }
                    if let mac = model.selectedMAC {
                        DeviceActivitySection(model: model, mac: mac, compact: false)
                        if store.snapshot?.sample.devices?.contains(where: { $0.mac == mac }) == true {
                            Button { store.showDevice(mac) } label: { Label("查看当前连接与流量", systemImage: "chart.xyaxis.line") }.buttonStyle(.link)
                        }
                    } else {
                        HStack(spacing: 12) {
                            StatCard(title: "已记录", value: "\(model.records.count)", symbol: "desktopcomputer", tint: .primary, note: "包含离线设备")
                            StatCard(title: "已关注", value: "\(model.watched.count)", symbol: "bell.badge", tint: .teal, note: "仅这些设备提醒")
                            StatCard(title: "监测状态", value: model.isMonitoring ? "正在记录" : "已暂停", symbol: "waveform.path", tint: .blue, note: "跟随本机应用运行")
                        }
                    }
                    NotificationSettingsPanel(model: model.notifications)
                    timeline(filteredEvents)
                    Text("离线需连续 3 分钟确认；每台设备的提醒至少间隔 30 分钟。休眠、连接中断和写入设置会暂停判断；路由器在线列表突然大幅减少时最多暂缓 10 分钟再判断。原始记录保留最近 30 天，最多 10,000 条。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(28)
            }
        }
        .onChange(of: eventFilter) { visibleLimit = 200 }
        .onChange(of: days) { visibleLimit = 200 }
        .onChange(of: model.selectedMAC) { visibleLimit = 200 }
        .onChange(of: search) { resetSelectionIfHidden() }
        .onChange(of: onlyWatched) { resetSelectionIfHidden() }
    }
    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("设备历史").font(.headline).padding(.top, 8)
            TextField("搜索名称、IP 或 MAC", text: $search).textFieldStyle(.roundedBorder)
            Toggle("只看关注设备", isOn: $onlyWatched).font(.caption)
            Button { model.selectedMAC = nil } label: { Label("所有设备的记录", systemImage: "clock.arrow.circlepath").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.borderless)
            Divider()
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(records) { record in
                        Button { model.selectedMAC = record.mac } label: {
                            HStack(spacing: 10) {
                                DeviceGlyph(kind: store.deviceOverrides[record.mac] ?? record.kind, size: 31, online: model.isOnline(record.mac))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(record.name).font(.callout.weight(.medium)).lineLimit(1)
                                    Text(model.presenceLabel(record.mac)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if record.watched { Image(systemName: "bell.badge.fill").font(.caption).foregroundStyle(.teal) }
                            }.padding(9).background(model.selectedMAC == record.mac ? Color.teal.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain)
                    }
                    if records.isEmpty {
                        Text(onlyWatched ? "尚无匹配的关注设备。可在设备详情中开启“关注离线”。" : "没有匹配的设备。")
                            .font(.caption).foregroundStyle(.secondary).padding(.vertical, 12)
                    }
                }
            }
            Text("\(records.count) 台匹配 · 共 \(model.records.count) 台已记录").font(.caption).foregroundStyle(.secondary)
        }.padding(16).frame(width: 270).background(.bar)
    }
    @ViewBuilder private func timeline(_ events: [PresenceEvent]) -> some View {
        SectionTitle(title: "活动时间线", subtitle: "\(events.count) 条匹配记录 · 筛选只影响显示，原始记录完整保留。", symbol: "list.bullet")
        HStack {
            Picker("记录类型", selection: $eventFilter) {
                ForEach(PresenceHistoryFilter.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            Picker("时间范围", selection: $days) {
                Text("最近 24 小时").tag(1); Text("最近 7 天").tag(7); Text("最近 30 天").tag(30)
            }.labelsHidden().frame(width: 116)
        }
        if events.isEmpty {
            VStack(spacing: 12) {
                ContentUnavailableView(eventFilter == .changes ? "这段时间没有上下线变化" : "没有匹配的记录", systemImage: "clock.badge.checkmark",
                    description: Text(onlyWatched ? "当前只显示关注设备。调整关注筛选、时间范围或记录类型可查看其他记录。" : "首次发现与恢复监测分别记录，未监测的时段不会补猜。"))
                if eventFilter != .all { Button("查看全部记录") { eventFilter = .all }.buttonStyle(.link) }
            }
        } else {
            let groups = Dictionary(grouping: Array(events.prefix(visibleLimit))) { Calendar.current.startOfDay(for: $0.at) }
            ForEach(groups.keys.sorted(by: >), id: \.self) { day in
                let rows = groups[day] ?? []
                HStack { Text(MonitoringDate.day(day)).font(.subheadline.weight(.semibold)); Spacer(); Text("\(rows.count) 条").font(.caption).foregroundStyle(.secondary) }
                Panel {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { event in
                            Button { model.selectedMAC = event.mac } label: {
                                PresenceEventRow(event: event, showName: model.selectedMAC == nil, showDate: false)
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).help("查看这台设备的历史")
                            if event.id != rows.last?.id { Divider().padding(.vertical, 11) }
                        }
                    }
                }
            }
            if events.count > visibleLimit {
                Button("再显示 \(min(200, events.count - visibleLimit)) 条（已显示 \(visibleLimit) / \(events.count)）") { visibleLimit += 200 }
                    .buttonStyle(.link).frame(maxWidth: .infinity)
            }
        }
    }
    private func resetSelectionIfHidden() {
        visibleLimit = 200
        if let mac = model.selectedMAC, !records.contains(where: { $0.mac == mac }) { model.selectedMAC = nil }
    }
}

struct PresenceEventRow: View {
    let event: PresenceEvent
    var showName = true
    var showDate = true
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.kind == .offline || event.kind == .observedOffline ? "wifi.slash" : "wifi")
                .foregroundStyle(event.kind == .offline ? Color.orange : Color.teal).frame(width: 24).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(event.kind.title).font(.callout.weight(.medium))
                if showName { Text(event.name).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer()
            Text(showDate ? MonitoringDate.full(event.at) : MonitoringDate.time(event.at)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }
    private var detail: String? {
        let paused = event.afterPause == true
        switch (event.kind, event.absentSince) {
        case (.offline, let since?): return paused ? "暂停期间离开：恢复监测后从 \(MonitoringDate.time(since)) 起一直未发现，已持续确认。" : "从 \(MonitoringDate.time(since)) 起未再发现，已持续确认。"
        case (.online, _) where paused: return "暂停期间重新上线，时间为恢复监测后的首次确认。"
        default: return nil
        }
    }
}

struct DeviceActivitySection: View {
    @ObservedObject var model: DeviceMonitorModel
    let mac: String
    var compact = true
    var body: some View {
        if let record = model.record(mac) {
            Panel {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        SectionTitle(title: "在线记录与提醒", subtitle: model.presenceLabel(mac), symbol: "clock.badge.checkmark")
                        Spacer()
                        Toggle("关注离线", isOn: Binding(get: { model.record(mac)?.watched ?? false }, set: { model.setWatched($0, mac: mac) }))
                            .toggleStyle(.switch).fixedSize()
                    }
                    KeyValue(key: "最近在线", value: record.lastSeen.map(MonitoringDate.full) ?? "尚未观测到在线")
                    KeyValue(key: "开始记录", value: MonitoringDate.short(record.firstObserved))
                    if compact {
                        ForEach(Array(model.events(mac: mac).prefix(3))) { event in PresenceEventRow(event: event, showName: false) }
                    }
                    Text("只提醒你关注的设备。连续离线 3 分钟后发送系统通知。").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct NotificationSettingsPanel: View {
    @ObservedObject var model: DeviceNotifications
    @State private var testMessage: String?
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionTitle(title: "离线提醒", subtitle: model.status, symbol: "bell.badge")
                    Spacer()
                    if !model.authorized { Button("允许通知") { Task { await model.authorize() } } }
                    if model.requesting { ProgressView().controlSize(.small) }
                    Button("发送测试通知") {
                        Task {
                            if !model.authorized { await model.authorize() }
                            let sent = await model.send(name: "", eventID: "RouterBar-test-" + UUID().uuidString, test: true)
                            testMessage = sent ? "测试通知已提交到 macOS；显示方式受通知设置和专注模式影响。" : "通知尚未发送，请检查系统通知权限。"
                        }
                    }
                }.disabled(model.requesting)
                if let text = model.error ?? testMessage { Text(text).font(.caption).foregroundStyle(.secondary) }
            }
        }.task { await model.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await model.refresh() } }
    }
}
