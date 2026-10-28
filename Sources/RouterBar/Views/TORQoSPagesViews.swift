import RouterCore
import SwiftUI

// VPN › TOR 与 带宽管理 QoS › 用户自定义优先级（1.11）：路由器网页打开这两页时显示的内容。
// 只读：不开关 TOR、不改端口与名单，不改优先级与封包，也不保存任何设置。

// MARK: - TOR

struct TORView: View {
    @Environment(RouterStore.self) var store
    @StateObject private var reading = RouterReading<TORSettings>()
    private var connected: Bool { store.phase == .connected }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusPageHeader(title: "TOR", subtitle: "VPN - TOR Settings", symbol: "network.badge.shield.half.filled",
                                 readAt: reading.readAt, loading: reading.loading) { await load() }
                ReadErrorLabel(message: reading.error)
                if !connected {
                    ConnectionRequiredView()
                } else if let tor = reading.value {
                    Panel {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("基本设置").font(.headline).padding(.bottom, 6)
                            KeyValue(key: "TOR", value: tor.enableTitle)
                            if tor.enabled {
                                KeyValue(key: "Socks Port", value: tor.socksPort)
                                KeyValue(key: "Trans Port", value: tor.transPort)
                                KeyValue(key: "DNS Port", value: tor.dnsPort)
                                KeyValue(key: "Redirect all user from", value: tor.specifiedMACs ? "Only Specified MACs" : "LAN(br0)")
                            }
                        }
                    }
                    if tor.enabled, tor.specifiedMACs { macList(tor) }
                    Text("网页在这里开关 TOR、修改端口和名单，保存时重启 TOR；本应用只显示设置。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    ReadingPlaceholder(failed: reading.error != nil && !reading.loading, minHeight: 220)
                }
            }.padding(28)
        }
        .task(id: connected) { if connected, reading.value == nil { await load() } }
    }

    private func load() async { await reading.load(store: store) { try await $0.torSettings() } }

    /// Specified MAC List (show_tor_redir_list 47–113): a device the page's client list has by that exact MAC is shown by
    /// its name, the others by the MAC; both go into the page as HTML.
    private func macList(_ tor: TORSettings) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                Text("Specified MAC List").font(.headline)
                Text("MAC").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if let macs = tor.macs {
                    ForEach(Array(macs.enumerated()), id: \.offset) { _, mac in
                        HStack {
                            Text(tor.names[mac] ?? TORSettings.listText(mac))
                            Spacer()
                            Text(TORSettings.listText(mac)).monospaced().textSelection(.enabled).help(mac)
                        }.font(.callout)
                    }
                } else {
                    Text("目前没有数据").font(.callout).foregroundStyle(.orange)
                }
            }
        }
    }
}

// MARK: - 用户自定义优先级

struct QoSUserPriorityView: View {
    @Environment(RouterStore.self) var store
    @StateObject private var reading = RouterReading<QoSUserPriority>()
    private var connected: Bool { store.phase == .connected }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusPageHeader(title: "用户自定义优先级", subtitle: reading.value?.title ?? "带宽管理 QoS", symbol: "list.number",
                                 readAt: reading.readAt, loading: reading.loading) { await load() }
                ReadErrorLabel(message: reading.error)
                if !connected {
                    ConnectionRequiredView()
                } else if let priority = reading.value {
                    description
                    if priority.showsEnableHint {
                        Label("请先开启的带宽管理后再设定上传与下载速率限制。", systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    limits(priority)
                    packets(priority)
                    Text("网页在这里修改优先级的速率限制与优先封包，保存时重启 QoS 与防火墙；本应用只显示设置。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    ReadingPlaceholder(failed: reading.error != nil && !reading.loading, minHeight: 220)
                }
            }.padding(28)
        }
        .task(id: connected) { if connected, reading.value == nil { await load() } }
    }

    private func load() async { await reading.load(store: store) { try await $0.qosUserPriority() } }

    /// UserQoS_desc, with its list as bullets.
    private var description: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("在使用者定义带宽管理规定下拉列表中，您可以将网络应用程序或装置优先至五个等级。依据优先级，带宽管理使用以下方法传输数据包：")
            ForEach(["更换上行网络数据包的顺序，可参照数据包传输至网络的顺序。", "优先级低的数据包会被忽视以确保高优先级的传输。优先级较高的上行数据包将会产生优先级较高的下行数据包。",
                     "若优先级高的应用程序中无数据包传输，则低优先级的数据包将获得全部的网络传输率。"], id: \.self) { item in
                Text("• " + item)
            }
        }.font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func percent(_ value: String?) -> some View {
        HStack(spacing: 4) {
            SelectionBox(selection: .shown(value), width: 64)
            Text("%").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// 设置上传与下载速率限制: per priority the upload minimum and maximum and the download maximum, with the range each
    /// gives at the bandwidth the router has.
    private func limits(_ priority: QoSUserPriority) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                Text("设置上传与下载速率限制").font(.headline)
                Text("上传带宽").font(.subheadline.weight(.semibold))
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("上传优先顺序"); Text("最小保留带宽"); Text("最大带宽限制"); Text("当前带宽设置范围")
                    }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(priority.levels, id: \.name) { level in
                        GridRow {
                            Text(level.name)
                            percent(level.uploadMin)
                            percent(level.uploadMax)
                            Text(level.uploadRange ?? "").monospacedDigit()
                        }.font(.callout)
                    }
                }
                Divider()
                Text("下载带宽").font(.subheadline.weight(.semibold))
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("下载优先顺序"); Text("最大带宽限制"); Text("当前带宽设置范围")
                    }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(priority.levels, id: \.name) { level in
                        GridRow {
                            Text(level.name)
                            percent(level.downloadMax)
                            Text(level.downloadRange ?? "").monospacedDigit()
                        }.font(.callout)
                    }
                }
            }
        }
    }

    private func packets(_ priority: QoSUserPriority) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                Text("最高优先级封包").font(.headline)
                Text("默认的 ACK、SYN 与 ICMP 封包可提高游戏流畅性。").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    ForEach(priority.packets, id: \.name) { packet in
                        Label(packet.name, systemImage: packet.on ? "checkmark.square.fill" : "square")
                            .accessibilityLabel("\(packet.name)：\(packet.on ? "已勾选" : "未勾选")")
                    }
                }.font(.callout)
            }
        }
    }
}
