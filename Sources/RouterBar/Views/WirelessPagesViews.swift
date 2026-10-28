import RouterCore
import SwiftUI

// 无线 › WPS、WDS、漫游阻止列表、MLO 与 网络工具 › Smart Connect 规则（1.10）：路由器网页打开这些分页时显示的内容。
// 只读：不开始 WPS 配对、不扫描基地台、不切换开关，也不保存任何设置。

@MainActor private func knownDeviceName(_ store: RouterStore, _ mac: String) -> String? {
    store.snapshot?.sample.devices?.first { $0.mac.caseInsensitiveCompare(mac) == .orderedSame }?.name
}

/// A label and a value laid out like KeyValue, for values that are more than one text.
private struct ValueRow<Value: View>: View {
    let key: String
    @ViewBuilder let value: Value
    var body: some View {
        HStack(alignment: .firstTextBaseline) { Text(key).foregroundStyle(.secondary); Spacer(); value }
            .font(.callout).padding(.vertical, 3)
    }
}

/// A band's 一般设置 ("wifi") or 专业设置 ("radio") section, where the web's links go after choosing the band; nil where the
/// router's menu has no page for that band, so a link never opens another band's settings. A link without a band goes to
/// the first, as the page's would (it saves `wl_unit` as "undefined", which reads as 0).
@MainActor private func bandSection(_ store: RouterStore, _ prefix: String, unit: Int?) -> String? {
    let unit = unit ?? 0
    let id = store.profile?.radios.first(where: { $0.unit == unit }).flatMap { SettingsCatalog.radioSectionID(templateID: "\(prefix)\(unit)", radio: $0) }
        ?? "\(prefix)\(unit)"
    return store.menuSet.location(ofSection: id) == nil ? nil : id
}

// MARK: - WPS

struct WPSView: View {
    @Environment(RouterStore.self) var store
    @StateObject private var configuration = RouterReading<WPSConfiguration>()
    @StateObject private var info = RouterReading<WPSInfo>()
    @State private var showsPIN = false
    private var connected: Bool { store.phase == .connected }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusPageHeader(title: "WPS", subtitle: "WPS (WiFi Protected Setup) 可让您轻松地设置一个安全的无线网络。本页显示 WPS 当前的状态，打开期间与网页一样约每 4 秒读取一次。",
                                 symbol: "wave.3.right.circle", readAt: info.readAt, loading: configuration.loading || info.loading) { await reload() }
                ReadErrorLabel(message: configuration.error ?? info.error)
                if !connected {
                    ConnectionRequiredView()
                } else if let settings = configuration.value, let answer = info.value {
                    let status = WPSStatus(configuration: settings, info: answer)
                    if status.hiddenSSID { NoticeBanner(message: "注： 若 SSID 被隐藏则无法使用 WPS 功能。", tone: .attention) }
                    Panel { rows(status) }
                    if status.wpa3Unsupported { NoticeBanner(message: "WPA3-Personal 不支持 WPS。", tone: .attention) }
                    notes
                } else {
                    ReadingPlaceholder(failed: configuration.error != nil && !configuration.loading, minHeight: 220)
                }
            }.padding(28)
        }
        .task(id: connected) {
            guard connected else { return }
            await reload()
            // The page keeps reading the status while the bands allow WPS (InitializeTimer 368–380, StartTheTimer 389–405).
            while !Task.isCancelled, configuration.value?.pollsStatus == true {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { break }
                await info.load(store: store) { try await $0.wpsInfo() }
            }
        }
    }

    private func reload() async {
        await configuration.load(store: store) { try await $0.wpsConfiguration() }
        await info.load(store: store) { try await $0.wpsInfo() }
    }

    private func rows(_ status: WPSStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            KeyValue(key: "启用 WPS", value: status.enabled ? "已启用" : "未启用")
            if let notice = status.notice { noticeView(notice).padding(.vertical, 4) }
            if let bands = status.bands {
                ValueRow(key: "当前频率") {
                    HStack(spacing: 4) {
                        ForEach(Array(bands.enumerated()), id: \.offset) { index, band in
                            if index > 0 { Text("/").foregroundStyle(.secondary) }
                            Text(band.title.isEmpty ? "—" : band.title).strikethrough(band.struck).foregroundStyle(band.struck ? .secondary : .primary)
                        }
                    }
                }
            }
            if let state = status.state {
                ValueRow(key: "连线状态") {
                    HStack(spacing: 6) { if status.inProgress { ProgressView().controlSize(.small) }; Text(state.isEmpty ? "—" : state).textSelection(.enabled) }
                }
            }
            if let configured = status.configured { KeyValue(key: "配置", value: configured) }
            if let pin = status.pin {
                ValueRow(key: "访问点 PIN 码") {
                    HStack(spacing: 8) {
                        if showsPIN { Text(pin).monospaced().textSelection(.enabled) } else { Text(String(repeating: "•", count: max(pin.count, 4))).monospaced() }
                        Button(showsPIN ? "隐藏" : "显示") { showsPIN.toggle() }.buttonStyle(.link)
                    }
                }
            }
        }
    }

    /// The page's notes under 启用 WPS (show_wsc_status 509–523, show_wsc_status2 631–664).
    private func noticeView(_ notice: WPSStatus.Notice) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch notice {
            case .wifiOff(let links):
                NoticeBanner(message: "* 开启 WiFi 以设置 WPS。", tone: .attention)
                linkButtons(links, text: "前往设置", section: "radio")
            case .authRejected(let links):
                NoticeBanner(message: "根据 WPS 2.0 规定，当路由器在使用 WEP 或 TKIP 时 WPS 功能必须关闭。\nWPS 并不支持您目前设置的安全授权方式，请前往一般设置修改后再启用 WPS。", tone: .attention)
                linkButtons(links, text: "一般设置", section: "wifi")
            }
        }
    }

    private func linkButtons(_ links: [WPSStatus.BandLink], text: String, section prefix: String) -> some View {
        HStack(spacing: 10) {
            ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                if let section = bandSection(store, prefix, unit: link.unit) {
                    Button(link.title.isEmpty ? text : "\(text) \(link.title)") { store.open(section: section) }
                }
            }
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("网页在这一页开关 WPS、切换频段、重置配置，并用按钮（Push button）或客户端 PIN 码开始配对；这些操作会改变路由器设置或让路由器开始配对，本应用不提供。")
            Text("访问点 PIN 码默认隐藏，点“显示”后才显示。")
        }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - WDS

struct WDSView: View {
    @Environment(RouterStore.self) var store
    @StateObject private var reading = RouterReading<WDSSettings>()
    private var connected: Bool { store.phase == .connected }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusPageHeader(title: "WDS", subtitle: "无线桥接（又名 WDS）功能允许您的 \(store.snapshot?.sample.identity.model ?? "路由器") 无线连接至其他基地台。WDS 也可作为中继模式。",
                                 symbol: "point.3.connected.trianglepath.dotted", readAt: reading.readAt, loading: reading.loading) { await load() }
                ReadErrorLabel(message: reading.error)
                if !connected {
                    ConnectionRequiredView()
                } else if let wds = reading.value {
                    guide
                    settings(wds)
                    Text("网页打开这一页时会自动扫描周边基地台，供加入远程列表；切换频段、加入或删除基地台都会保存设置。本应用不扫描，也不修改。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    ReadingPlaceholder(failed: reading.error != nil && !reading.loading, minHeight: 220)
                }
            }.padding(28)
        }
        .task(id: connected) { if connected, reading.value == nil { await load() } }
    }

    private func load() async { await reading.load(store: store) { try await $0.wdsSettings() } }

    private var guide: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                Text("注意：仅支持 Open System/NONE, Open System/WEP 加密方式。欲设置相关验证方法，请先选择「Legacy」作为您的无线模式。").foregroundStyle(.orange)
                if let section = bandSection(store, "wifi", unit: 0) { Button("前往一般设置") { store.open(section: section) } }
                Text("开启 WDS 延伸无线讯号，请按以下步骤操作：").padding(.top, 4)
                ForEach(Array(["选择 [WDS Only] 或 [Hybrid] 模式并在远程列表中添加存取点的 MAC 地址。",
                               "确认此无线路由器与您想要连接的基地台使用相同的频道。",
                               "在想连线的基地台 WDS 管理介面中，输入本无线路由器 MAC 位址位址。",
                               "要获得最佳性能，请进入「高级设置」>「无线网络」>「一般设置」为网络中的每台路由器设置相同的通道带宽、通道与延伸通道。"].enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1). \(step)").foregroundStyle(.secondary)
                }
            }.font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func settings(_ wds: WDSSettings) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 4) {
                Text("基本设置").font(.headline).padding(.bottom, 6)
                ForEach(wds.macs) { KeyValue(key: $0.title, value: $0.mac.isEmpty ? "—" : $0.mac) }
                ForEach(wds.radios) { radio in
                    Divider().padding(.vertical, 8)
                    if wds.showsBand {
                        HStack(alignment: .firstTextBaseline) {
                            Text(radio.band.title).font(.subheadline.weight(.semibold))
                            if radio.band.unit == wds.currentUnit { Text("网页打开时显示这个频段").font(.caption).foregroundStyle(.secondary) }
                        }.padding(.bottom, 4)
                    }
                    band(radio)
                }
            }
        }
    }

    @ViewBuilder private func band(_ radio: WDSSettings.Radio) -> some View {
        if radio.unavailable {
            Text("目前的运作模式不支持此页面。").font(.callout).foregroundStyle(.orange)
        } else {
            if radio.autoBandwidth { hint("当前您正在使用自动频道带宽。", unit: radio.band.unit) }
            if radio.autoChannel { hint("当前您正在使用自动频道。", unit: radio.band.unit) }
            if radio.showsMode { KeyValue(key: "AP 模式", value: radio.modeTitle) }
            KeyValue(key: "连接列表中的访问点", value: radio.connectListedFixed ? "\(radio.connectListedTitle)（此模式下固定）" : radio.connectListedTitle)
            Text("远程基地台列表 (最多限制：4)").font(.callout).foregroundStyle(.secondary).padding(.top, 6)
            if radio.remoteAPs.isEmpty {
                Text("目前没有数据").font(.callout).foregroundStyle(.orange)
            } else {
                ForEach(Array(radio.remoteAPs.enumerated()), id: \.offset) { _, mac in
                    Text(mac.isEmpty ? "（空）" : mac).font(.callout).monospaced().textSelection(.enabled)
                }
            }
        }
    }

    private func hint(_ text: String, unit: Int) -> some View {
        HStack(spacing: 8) {
            Text(text).foregroundStyle(.orange)
            if let section = bandSection(store, "wifi", unit: unit) { Button("前往修改") { store.open(section: section) }.buttonStyle(.link) }
        }.font(.callout)
    }
}

// MARK: - 漫游阻止列表

struct RoamingBlockListView: View {
    @Environment(RouterStore.self) var store
    @StateObject private var reading = RouterReading<RoamingBlockList>()
    private var connected: Bool { store.phase == .connected }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusPageHeader(title: "漫游阻止列表", subtitle: "您可以将设备添加到漫游阻止列表中，设备将不会在 AiMesh 节点之间漫游。本页只显示当前列表。",
                                 symbol: "figure.walk.motion.trianglebadge.exclamationmark", readAt: reading.readAt, loading: reading.loading) { await load() }
                ReadErrorLabel(message: reading.error)
                if !connected {
                    ConnectionRequiredView()
                } else if let list = reading.value {
                    Panel {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("基本设置").font(.headline).padding(.bottom, 6)
                            KeyValue(key: "启用漫游阻止列表", value: list.enableTitle)
                        }
                    }
                    if list.enabled { devices(list) }
                    Text("网页保存时把列表写入每个频段；本应用不修改。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    ReadingPlaceholder(failed: reading.error != nil && !reading.loading, minHeight: 220)
                }
            }.padding(28)
        }
        .task(id: connected) { if connected, reading.value == nil { await load() } }
    }

    private func load() async { await reading.load(store: store) { try await $0.roamingBlockList() } }

    private func devices(_ list: RoamingBlockList) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                Text("漫游阻止列表 (最多限制：64)").font(.headline)
                Text("客户名称 (MAC 地址)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if list.macs.isEmpty {
                    Text("目前没有数据").font(.callout).foregroundStyle(.orange)
                }
                ForEach(Array(list.macs.enumerated()), id: \.offset) { _, mac in
                    HStack {
                        // show_wl_maclist_x names devices the client list knows and calls the rest "New device" (55–127).
                        if let name = knownDeviceName(store, mac) {
                            Button { store.showDevice(mac) } label: { Text(name).lineLimit(1) }.buttonStyle(.plain)
                        } else {
                            Text("New device").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(mac).monospaced().textSelection(.enabled)
                    }.font(.callout)
                }
            }
        }
    }
}

// MARK: - Smart Connect 规则

struct SmartConnectRulesView: View {
    @Environment(RouterStore.self) var store
    @StateObject private var reading = RouterReading<SmartConnectRules>()
    private var connected: Bool { store.phase == .connected }
    private typealias Column = SmartConnectRules.Column

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusPageHeader(title: "Smart Connect 规则", subtitle: "设置下列 Smart Connect 相关信息。本页只显示当前规则。",
                                 symbol: "arrow.triangle.branch", readAt: reading.readAt, loading: reading.loading) { await load() }
                ReadErrorLabel(message: reading.error)
                if !connected {
                    ConnectionRequiredView()
                } else if let rules = reading.value {
                    HStack { Spacer(); Button("阅览名单") { store.open(.clients) } }
                    table("控制触发条件", rules, [
                        ("启用负载平衡", { $0.loadBalance ? "是" : "否" }),
                        ("带宽使用量", { "\(Column.field($0.steering, 0)) %" }),
                        ("RSSI", { rssi($0.steeringRSSIGreater, Column.field($0.steering, 3)) }),
                        ("PHY 速率降低", { "\(Column.field($0.steering, 4)) Mbps" }),
                        ("PHY 速率提高", { "\(Column.field($0.steering, 5)) Mbps" }),
                        ("功能", { $0.steeringCapability.title })
                    ])
                    table("STA 选取规则", rules, [
                        ("RSSI", { rssi($0.stationRSSIGreater, Column.field($0.station, 1)) }),
                        ("PHY 速率降低", { "\(Column.field($0.station, 2)) Mbps" }),
                        ("PHY 速率提高", { "\(Column.field($0.station, 3)) Mbps" }),
                        ("功能", { $0.stationCapability.title })
                    ])
                    table("界面选择与审核程序", rules, [
                        ("目标频段", targets),
                        ("带宽使用量", { "\(Column.field($0.qualify, 0)) %" }),
                        ("功能", { $0.qualifyCapability.title })
                    ])
                    bounce(rules.bounceDetect)
                    notes
                } else {
                    ReadingPlaceholder(failed: reading.error != nil && !reading.loading, minHeight: 220)
                }
            }.padding(28)
        }
        .task(id: connected) { if connected, reading.value == nil { await load() } }
    }

    private func load() async { await reading.load(store: store) { try await $0.smartConnectRules() } }

    private func rssi(_ greater: Bool?, _ value: String) -> String {
        let comparison = greater.map { $0 ? "大于 " : "小于 " } ?? ""
        return "\(comparison)\(value) dBm"
    }
    private func targets(_ column: Column) -> String {
        column.targets.isEmpty ? "—" : column.targets.enumerated().map { "\($0.offset + 1): \($0.element.isEmpty ? "—" : $0.element)" }.joined(separator: "\n")
    }

    private func table(_ title: String, _ rules: SmartConnectRules, _ rows: [(String, (Column) -> String)]) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow {
                        Text("频段").foregroundStyle(.secondary)
                        ForEach(rules.columns) { Text($0.band.title).fontWeight(.semibold) }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            Text(row.0).foregroundStyle(.secondary)
                            // isSmartConnectSelifBand(): bands Smart Connect does not use show "- -" in every row (152–179).
                            ForEach(rules.columns) { column in Text(column.active ? row.1(column) : "- -").monospacedDigit().textSelection(.enabled) }
                        }
                    }
                }.font(.callout)
            }
        }
    }

    private func bounce(_ values: [String]) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 4) {
                Text("弹回检测").font(.headline).padding(.bottom, 6)
                KeyValue(key: "窗口时间", value: "\(Column.field(values, 0)) 秒")
                KeyValue(key: "计数", value: Column.field(values, 1))
                KeyValue(key: "停留时间", value: "\(Column.field(values, 2)) 秒")
            }
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("显示“- -”的频段没有加入 Smart Connect，或路由器不支持新版规则，网页同样只显示“- -”。")
            Text("RSSI 的比较方式在网页上写作“减小 / 增加”，“PHY 速率降低 / 提高”两行也是同样的意思：英文界面为 Less / Greater，即小于 / 大于。RSSI 这里按意思显示为“小于 / 大于”，两行 PHY 速率沿用网页的名称。")
            Text("“阅览名单”在网页打开客户端列表，这里打开“客户端”页面。网页在这一页修改或恢复默认规则，本应用不提供。")
        }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - MLO

struct MLOView: View {
    @Environment(RouterStore.self) var store
    @StateObject private var reading = RouterReading<MLOOverview>()
    private var connected: Bool { store.phase == .connected }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusPageHeader(title: "多链路操作(MLO)", subtitle: "MLO（多链路操作）允许设备同时连接到不同频段的多个频道。这提高了数据传输速率，减少了延迟，并提高了可靠性，从而实现了更快更稳定的WiFi连接。",
                                 symbol: "link", readAt: reading.readAt, loading: reading.loading) { await load() }
                ReadErrorLabel(message: reading.error)
                if !connected {
                    ConnectionRequiredView()
                } else if let mlo = reading.value {
                    configuration(mlo)
                    networks(mlo)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("网页上切换 MLO 会让路由器重新启动（博通机型）或重启无线，并改动其他网络的设置；本应用只显示开关状态。")
                        Text("客户端数量取自路由器当前的设备列表；网页打开时会先让路由器刷新一次列表。")
                        Text("剩余时间按读取时路由器的时钟每秒倒数，到 0 时与网页一样重新读取本页。")
                    }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    ReadingPlaceholder(failed: reading.error != nil && !reading.loading, minHeight: 220)
                }
            }.padding(28)
        }
        .task(id: connected) { if connected, reading.value == nil { await load() } }
        .task(id: reading.readAt) {
            // When a countdown reaches 0 the page reads its list again (mlo.js 89–92). A read that is skipped (another
            // router operation, no connection) or fails is tried again 1 s later, then up to 30 s apart, until one goes
            // through: that changes readAt, which ends this task and starts the next.
            guard let readAt = reading.readAt, let left = reading.value?.readsAgainAfter else { return }
            try? await Task.sleep(for: .seconds(max(readAt.addingTimeInterval(TimeInterval(left)).timeIntervalSinceNow, 0)))
            var pause = 1.0
            while !Task.isCancelled, reading.readAt == readAt {
                if connected { await load() }
                guard reading.readAt == readAt else { return }
                try? await Task.sleep(for: .seconds(pause))
                pause = min(pause * 2, 30)
            }
        }
    }

    private func load() async { await reading.load(store: store) { try await $0.mloOverview() } }

    private func configuration(_ mlo: MLOOverview) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 4) {
                KeyValue(key: "MLO", value: mlo.enabled ? "已开启" : "已关闭")
                Text("此主开关控制 MLO（多重连接模式）功能，包括 AiMesh 连接的 MLO 回传以及客户端的 MLO 前传。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.bottom, 4)
                if let bands = mlo.backhaulBands { KeyValue(key: "回程频段", value: bands.isEmpty ? "—" : bands) }
                if mlo.showsWirelessSettings, let section = bandSection(store, "wifi", unit: 0) {
                    ValueRow(key: "无线网络设置") { Button("前往设置") { store.open(section: section) } }
                }
            }
        }
    }

    private func networks(_ mlo: MLOOverview) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("配置文件列表").font(.headline)
                    Spacer()
                    Button("打开“网络”页面") { store.open(.networks) }
                }
                if mlo.networks.isEmpty {
                    Text("目前没有 MLO 网络。").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(mlo.networks) { network in
                    VStack(alignment: .leading, spacing: 4) {
                        // The page's tags above the name, in its order (sdn.js 558–589).
                        if network.vpnClient || network.vpnServer || network.accessTime != nil || network.freeWiFi || network.messageBoard {
                            HStack(spacing: 6) {
                                if network.vpnClient { tag("VPN 客户端") }
                                if network.vpnServer { tag("虚拟专用网 (VPN) 服务器") }
                                if let time = network.accessTime { accessTimeTag(time) }
                                if network.freeWiFi { tag("Free WiFi") }
                                if network.messageBoard { tag("留言板") }
                            }
                        }
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(network.ssid.isEmpty ? "（未命名）" : network.ssid).lineLimit(1)
                                Text(details(network)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: network.secured ? "lock.fill" : "lock.open").foregroundStyle(.secondary)
                                .help(network.secured ? "多链路操作(MLO)：已加密" : "多链路操作(MLO)：开放网络")
                            Label("\(network.onlineDevices)", systemImage: "person.2").monospacedDigit().help("客户端数量")
                            status(network).frame(minWidth: 48, alignment: .trailing)
                        }
                    }.font(.callout).opacity(network.needsReconfiguring ? 0.6 : 1)
                }
            }
        }
    }

    /// The type, then the connection icons (get_conn_type, sdn.js 846–871) and the VLAN ID (756–758) as text.
    private func details(_ network: MLOOverview.Network) -> String {
        var parts = [network.backhaul ? "MLO 回程" : "MLO"]
        if network.wired {
            parts.append("有线连接")
        } else {
            if network.wifi7 { parts.append("WiFi7") }
            parts.append(network.scheduledOff ? "无线连接 (离线)" : "无线连接")
        }
        if let vlan = network.vlanID { parts.append("VLAN \(vlan.isEmpty ? "—" : vlan)") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func status(_ network: MLOOverview.Network) -> some View {
        if network.needsReconfiguring {
            Text("需重新配置").foregroundStyle(.orange)
                .help("网页不显示这个网络的开关，设置中说明：因系统优化，这个网络需要重新配置，请重新建立（Due to system optimization, this network has to be reconfigured.）。")
        } else {
            Text(network.enabled ? "已开启" : "已关闭").foregroundStyle(network.enabled ? .green : .secondary)
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(.caption2.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
    }

    /// 剩余时间, counted down each second from the read while it has time left (mlo.js 79–96).
    private func accessTimeTag(_ time: MLOOverview.AccessTime) -> some View {
        TimelineView(.periodic(from: reading.readAt ?? .now, by: 1)) { context in
            let elapsed = reading.readAt.map { max(Int(context.date.timeIntervalSince($0)), 0) } ?? 0
            Label(time.text(after: elapsed), systemImage: "timer")
                .font(.caption2.weight(.medium).monospacedDigit()).padding(.horizontal, 8).padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
        }.help("剩余时间")
    }
}
