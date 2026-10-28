import SwiftUI
import RouterCore

// 系统记录 › DHCP 租约, IPv6 and 通信端口转发: what the router reports right now, read on opening and on request.

// MARK: - DHCP 租约

struct DHCPLeasesView: View {
    @Environment(RouterStore.self) var store
    @StateObject private var reading = RouterReading<[RouterDHCPLease]>()
    @State private var query = ""
    @State private var sortOrder = [KeyPathComparator(\LeaseRow.address)]
    private var connected: Bool { store.phase == .connected }

    struct LeaseRow: Identifiable {
        let id: String
        let name: String
        let hasHostname: Bool
        let ip: String
        /// Sorts addresses numerically, as the web's table does.
        let address: UInt64
        let mac: String
        let expires: Date
        let vlan: String
        let online: Bool?
    }

    private var rows: [LeaseRow] {
        guard let leases = reading.value, let readAt = reading.readAt else { return [] }
        let devices = Dictionary((store.snapshot?.sample.devices ?? []).map { ($0.mac, $0) }, uniquingKeysWith: { first, _ in first })
        return leases.map { lease in
            let device = devices[lease.mac]
            return LeaseRow(id: lease.id, name: lease.hostname ?? device?.name ?? "未提供名称", hasHostname: lease.hostname != nil, ip: lease.ip,
                            address: lease.ip.split(separator: ".").reduce(UInt64(0)) { $0 * 256 + (UInt64($1) ?? 0) }, mac: lease.mac,
                            expires: readAt.addingTimeInterval(TimeInterval(lease.secondsLeft)), vlan: lease.vlan ?? "—", online: device?.isOnline)
        }
    }
    private var shown: [LeaseRow] {
        let text = query.trimmingCharacters(in: .whitespaces)
        let list = text.isEmpty ? rows : rows.filter { $0.name.localizedCaseInsensitiveContains(text) || $0.ip.contains(text) || $0.mac.localizedCaseInsensitiveContains(text) }
        return list.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StatusPageHeader(title: "DHCP 租约", subtitle: "DHCP 服务器当前分配的地址、主机名和剩余租期。租约存在不代表设备在线；点击设备查看详情。",
                             symbol: "list.bullet.rectangle", readAt: reading.readAt, loading: reading.loading, subtitleLineLimit: 2) { await load() }
            ReadErrorLabel(message: reading.error)
            if !connected {
                ConnectionRequiredView()
            } else if reading.value == nil {
                ReadingPlaceholder(failed: reading.error != nil && !reading.loading, minHeight: 220)
            } else if rows.isEmpty {
                ContentUnavailableView("目前没有租约", systemImage: "list.bullet.rectangle")
            } else {
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("按名称、IP 或 MAC 筛选", text: $query).textFieldStyle(.plain)
                    }.padding(.horizontal, 10).padding(.vertical, 6).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8)).frame(maxWidth: 320)
                    Spacer()
                    Text(query.isEmpty ? "\(rows.count) 个租约" : "\(shown.count) / \(rows.count) 个租约").font(.callout).foregroundStyle(.secondary)
                }
                Table(shown, sortOrder: $sortOrder) {
                    TableColumn("设备", value: \.name) { row in
                        Button { store.showDevice(row.mac) } label: {
                            HStack(spacing: 6) {
                                Circle().fill(row.online == true ? Color.green : Color.secondary.opacity(0.35)).frame(width: 7, height: 7)
                                    .help(row.online == true ? "在线" : row.online == false ? "离线" : "不在设备列表中")
                                Text(row.name).foregroundStyle(row.hasHostname ? Color.primary : Color.secondary).lineLimit(1)
                            }
                        }.buttonStyle(.plain)
                    }.width(min: 160, ideal: 220)
                    TableColumn("IP 地址", value: \.address) { Text($0.ip).monospacedDigit().textSelection(.enabled) }.width(min: 110, ideal: 130)
                    TableColumn("MAC 地址", value: \.mac) { Text($0.mac).font(.callout.monospaced()).textSelection(.enabled) }.width(min: 150, ideal: 160)
                    TableColumn("剩余租期", value: \.expires) { row in
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let left = row.expires.timeIntervalSince(context.date)
                            Text(left > 0 ? Format.remaining(left) : "已到期，等待续租").monospacedDigit().foregroundStyle(left > 0 ? Color.primary : Color.orange)
                        }
                    }.width(min: 110, ideal: 130)
                    TableColumn("VLAN", value: \.vlan).width(min: 50, ideal: 60)
                }
                .frame(minHeight: 240)
                // This page does not scroll as a whole (the table does), so its notes keep a bounded height.
                Text("剩余租期在本机按读取时间倒数，点击“重新读取”取得路由器的最新数值。主机名由设备在申请地址时提供，未提供时显示路由器设备列表中的名称。")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(28)
        .task(id: connected) { if connected, reading.value == nil { await load() } }
    }

    private func load() async { await reading.load(store: store) { try await $0.dhcpLeases() } }
}

// MARK: - IPv6

struct IPv6StatusView: View {
    @Environment(RouterStore.self) var store
    @StateObject private var reading = RouterReading<RouterIPv6Status>()
    private var connected: Bool { store.phase == .connected }

    private static let labels = ["IPv6 Connection Type": "IPv6 连接类型", "WAN IPv6 Address": "WAN IPv6 地址", "WAN IPv6 Gateway": "WAN IPv6 网关",
                                 "LAN IPv6 Address": "LAN IPv6 地址", "LAN IPv6 Link-Local Address": "LAN IPv6 链路本地地址",
                                 "LAN IPv6 Prefix": "LAN IPv6 前缀", "DNS Address": "DNS 地址"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusPageHeader(title: "IPv6", subtitle: "路由器当前的 IPv6 地址与前缀、使用 IPv6 的设备，以及 IPv6 防火墙 pinhole。",
                                 symbol: "6.circle", readAt: reading.readAt, loading: reading.loading) { await load() }
                ReadErrorLabel(message: reading.error)
                if !connected {
                    ConnectionRequiredView()
                } else if let status = reading.value {
                    configuration(status)
                    if status.enabled { clients(status); pinholes(status) }
                } else {
                    ReadingPlaceholder(failed: reading.error != nil && !reading.loading, minHeight: 220)
                }
            }.padding(28)
        }
        .task(id: connected) { if connected, reading.value == nil { await load() } }
    }

    private func load() async { await reading.load(store: store) { try await $0.ipv6Status() } }

    private func configuration(_ status: RouterIPv6Status) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(title: "IPv6 设置", symbol: "6.circle")
                if status.enabled {
                    ForEach(status.configuration, id: \.self) { fact in
                        HStack(alignment: .firstTextBaseline) {
                            Text(Self.labels[fact.label] ?? fact.label).foregroundStyle(.secondary).help(fact.label)
                            Spacer()
                            Text(fact.value == "Enabled" ? "已启用" : fact.value == "Disabled" ? "已停用" : fact.value)
                                .multilineTextAlignment(.trailing).textSelection(.enabled)
                        }.font(.callout).padding(.vertical, 3)
                    }
                } else {
                    Text("IPv6 未启用。").foregroundStyle(.secondary)
                    Button("前往 IPv6 设置") { store.open(section: "ipv6") }.buttonStyle(.link)
                }
            }
        }
    }

    private func clients(_ status: RouterIPv6Status) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "IPv6 客户端 · \(status.clients.count) 台", symbol: "laptopcomputer.and.iphone")
                if status.clients.isEmpty {
                    Text("没有使用 IPv6 的设备。").foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .topLeading, horizontalSpacing: 20, verticalSpacing: 10) {
                        GridRow { ForEach(["设备", "MAC 地址", "IPv6 地址"], id: \.self) { Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary) } }
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(status.clients) { client in
                            GridRow {
                                Button { store.showDevice(client.mac) } label: { Text(client.hostname ?? deviceName(client.mac) ?? "未提供名称").lineLimit(1) }.buttonStyle(.link)
                                Text(client.mac).font(.caption.monospaced()).textSelection(.enabled)
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(client.addresses, id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func pinholes(_ status: RouterIPv6Status) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "IPv6 防火墙 Pinholes", symbol: "shield.lefthalf.filled")
                if let pinholes = status.pinholes {
                    if pinholes.isEmpty {
                        Text("没有 pinhole。").foregroundStyle(.secondary)
                    } else {
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                            GridRow { ForEach(["协议", "远端 IP", "端口", "本地 IP", "端口", "说明"], id: \.self) { Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary) } }
                            Divider().gridCellUnsizedAxes(.horizontal)
                            ForEach(pinholes, id: \.self) { hole in
                                GridRow {
                                    Text(hole.proto); Text(hole.remoteIP).font(.caption.monospaced()); Text(hole.remotePort).monospacedDigit()
                                    Text(hole.localIP).font(.caption.monospaced()); Text(hole.localPort).monospacedDigit(); Text(hole.description).lineLimit(1)
                                }.font(.callout)
                            }
                        }
                    }
                } else {
                    Text("Pinhole 支持已关闭。").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func deviceName(_ mac: String) -> String? { store.snapshot?.sample.devices?.first { $0.mac == mac }?.name }
}

// MARK: - 通信端口转发

struct PortForwardStatusView: View {
    @Environment(RouterStore.self) var store
    @StateObject private var reading = RouterReading<RouterPortForwardStatus>()
    private var connected: Bool { store.phase == .connected }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusPageHeader(title: "通信端口转发", subtitle: "路由器当前生效的端口转发，以及设备通过 UPnP、NAT-PMP 或 PCP 自动打开的端口。",
                                 symbol: "arrow.left.arrow.right", readAt: reading.readAt, loading: reading.loading) { await load() }
                ReadErrorLabel(message: reading.error)
                if !connected {
                    ConnectionRequiredView()
                } else if let status = reading.value {
                    virtualServers(status)
                    mappings(status)
                } else {
                    ReadingPlaceholder(failed: reading.error != nil && !reading.loading, minHeight: 220)
                }
            }.padding(28)
        }
        .task(id: connected) { if connected, reading.value == nil { await load() } }
    }

    private func load() async { await reading.load(store: store) { try await $0.portForwardStatus() } }

    private func virtualServers(_ status: RouterPortForwardStatus) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Virtual Servers", subtitle: "“端口转发”中设置并已生效的规则", symbol: "arrow.left.arrow.right")
                if status.virtualServers.isEmpty {
                    Text("没有生效的端口转发。").foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                        GridRow { ForEach(["来源", "协议", "端口范围", "转发到", "本地端口", "Chain"], id: \.self) { Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary) } }
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(status.virtualServers, id: \.self) { rule in
                            GridRow {
                                Text(rule.source); Text(rule.proto); Text(rule.portRange).monospacedDigit()
                                destination(rule.redirectTo); Text(rule.localPort).monospacedDigit(); Text(rule.chain).foregroundStyle(.secondary)
                            }.font(.callout)
                        }
                    }
                }
                Button("前往端口转发设置") { store.open(section: "portforward") }.buttonStyle(.link)
            }
        }
    }

    private func mappings(_ status: RouterPortForwardStatus) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "UPnP、NAT-PMP 与 PCP 映射 · \(status.mappings.count) 条", subtitle: "设备自行申请的端口映射，到期后由路由器移除", symbol: "point.3.connected.trianglepath.dotted")
                if status.mappings.isEmpty {
                    Text("没有生效的 UPnP 映射。").foregroundStyle(.secondary)
                } else {
                    let readAt = reading.readAt ?? .now
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                        GridRow { ForEach(["协议", "端口", "转发到", "本地端口", "剩余时间", "说明"], id: \.self) { Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary) } }
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(status.mappings, id: \.self) { mapping in
                            GridRow {
                                Text(mapping.proto); Text(mapping.port).monospacedDigit(); destination(mapping.redirectTo); Text(mapping.localPort).monospacedDigit()
                                if let seconds = mapping.secondsLeft {
                                    TimelineView(.periodic(from: .now, by: 1)) { context in
                                        Text(Format.remaining(readAt.addingTimeInterval(TimeInterval(seconds)).timeIntervalSince(context.date))).monospacedDigit()
                                    }
                                } else {
                                    Text("不过期").foregroundStyle(.secondary)
                                }
                                Text(mapping.description).lineLimit(1).help(mapping.description)
                            }.font(.callout)
                        }
                    }
                }
            }
        }
    }

    /// The address with the device's name when the router lists it.
    private func destination(_ ip: String) -> some View {
        let device = store.snapshot?.sample.devices?.first { $0.ip == ip }
        return VStack(alignment: .leading, spacing: 1) {
            Text(ip).monospacedDigit().textSelection(.enabled)
            if let device { Text(device.name).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
    }
}
