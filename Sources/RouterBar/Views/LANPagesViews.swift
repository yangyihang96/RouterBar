import RouterCore
import SwiftUI

// 内部网络(LAN) › VLAN 与 VLAN 配置文件（1.11）：路由器网页打开这两个分页时显示的内容。
// 只读：不改端口模式与配置文件，不新增或删除配置文件，也不保存任何设置。

/// Opens the native home of a web page the notes point to (e.g. 双线路), by the page's file name.
@MainActor private func openWebPage(_ store: RouterStore, _ file: String) {
    for menu in store.menuSet.menus {
        if let page = menu.pages.first(where: { $0.id == file }) { store.open(page: page, in: menu); return }
    }
}

// MARK: - VLAN（端口）

struct VLANPortsView: View {
    @Environment(RouterStore.self) var store
    @StateObject private var reading = RouterReading<VLANPortTable>()
    private var connected: Bool { store.phase == .connected }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusPageHeader(title: "VLAN", subtitle: VLANPortTable.description, symbol: "cable.connector.horizontal",
                                 readAt: reading.readAt, loading: reading.loading) { await load() }
                ReadErrorLabel(message: reading.error)
                if !connected {
                    ConnectionRequiredView()
                } else if let table = reading.value {
                    Text(VLANPortTable.modeDescription).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ForEach(table.nodes) { node in nodeTable(node) }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("网页在这里为端口选择模式与配置文件，保存时会重启网络；本应用只显示设置。")
                        Text("与网页一样，本页每 3 秒检查一次 AiMesh 节点的数量，数量变化时重新读取本页。")
                    }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    ReadingPlaceholder(failed: reading.error != nil && !reading.loading, minHeight: 220)
                }
            }.padding(28)
        }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "routerbar-page" else { return .systemAction }
            openWebPage(store, String(url.absoluteString.dropFirst("routerbar-page:".count)))
            return .handled
        })
        .task(id: connected) { if connected, reading.value == nil { await load() } }
        .task(id: reading.readAt) {
            // A node that has not reported its ports yet: the page reloads after 30 seconds (1220).
            guard reading.value?.reloadsSoon == true else { return }
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled { await load() }
        }
        .task(id: connected) {
            // check_get_port_status_update (671–687): every 3 seconds the number of nodes reporting their ports; when it
            // changes from the first number seen, the page reloads. A failed request changes nothing.
            var reported = 0
            while connected, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, store.operationTitle == nil, !reading.loading, let client = try? store.connectedClient(),
                      let count = await client.vlanReportedNodeCount() else { continue }
                if reported == 0 {
                    reported = count
                } else if count != reported {
                    reported = 0
                    await load()
                }
            }
        }
    }

    private func load() async { await reading.load(store: store) { try await $0.vlanPortTable() } }

    private func nodeTable(_ node: VLANPortTable.Node) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                Text(node.title).font(.headline)
                Grid(alignment: .center, horizontalSpacing: 14, verticalSpacing: 10) {
                    if node.rows.isEmpty {
                        GridRow {
                            header(node, row: 0)
                            switch node.waiting {
                            case .disconnected: Text("联机中断").foregroundStyle(.orange).gridCellAnchor(.leading)
                            default: ProgressView().controlSize(.small).help("正在等待节点报告端口，30 秒后重新读取").gridCellAnchor(.leading)
                            }
                        }
                        GridRow { rowTitle("模式") }
                        GridRow { rowTitle("SDN (VLAN) Profile") }
                    }
                    ForEach(Array(node.rows.enumerated()), id: \.offset) { index, ports in
                        if index > 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                        GridRow {
                            header(node, row: index)
                            ForEach(ports) { port in PortIcon(port: port) }
                        }
                        GridRow {
                            rowTitle("模式")
                            ForEach(ports) { port in SelectionBox(selection: port.mode) }
                        }
                        GridRow {
                            rowTitle("SDN (VLAN) Profile")
                            ForEach(ports) { port in SelectionBox(selection: port.profile) }
                        }
                    }
                }
                ForEach(Array(node.notes.enumerated()), id: \.offset) { _, note in
                    Text(attributed(note)).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The first header cell: model, MAC address and location on the first row of ports, the MAC address on the others
    /// (785, 1008).
    private func header(_ node: VLANPortTable.Node, row: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if row == 0 { Text(node.model).font(.callout.weight(.medium)) }
            Text(node.mac).font(.caption.monospaced()).textSelection(.enabled)
            if row == 0 { Text(node.location).font(.caption).foregroundStyle(.secondary) }
        }.frame(width: 150, alignment: .leading).gridCellAnchor(.leading)
    }

    private func rowTitle(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).frame(width: 150, alignment: .leading).gridCellAnchor(.leading)
    }

    /// The note as the browser shows its HTML; 点击这里 opens the page it names.
    private func attributed(_ note: VLANPortTable.Note) -> AttributedString {
        var text = AttributedString()
        for run in VLANPortTable.runs(note.html) {
            var part = AttributedString(run.text)
            if run.bold { part.inlinePresentationIntent = .stronglyEmphasized }
            if run.link, let destination = note.destination { part.link = URL(string: "routerbar-page:\(destination.rawValue)") }
            text += part
        }
        return text
    }
}

/// A port as the page draws it (853–878): the icon in the link state's color with the port number, "Aggregation" for a
/// port another feature uses, the port's name or maximum rate under it, and the link rate when pointed at.
private struct PortIcon: View {
    let port: VLANPortTable.Port

    private var color: Color {
        switch port.link {
        case .connected: .green
        case .warning: .orange
        case .unplugged, .unknown: .gray
        }
    }
    private var state: String {
        switch port.link {
        case .connected: "已连接"
        case .warning: "警告"
        case .unplugged, .unknown: "未插入"
        }
    }

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.16)).frame(width: 36, height: 28)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(color, lineWidth: 1.5))
                Text(port.number).font(.caption.weight(.semibold).monospacedDigit())
            }
            if port.aggregation { Text("Aggregation").font(.system(size: 9, weight: .semibold)).foregroundStyle(.orange) }
            if let caption = port.caption {
                Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center)
            }
        }
        .frame(minWidth: 96)
        .help(port.speed ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([port.number.isEmpty ? port.caption : "LAN \(port.number)", state, port.speed].compactMap { $0 }.joined(separator: "，"))
    }
}

/// One of a page's selection lists, read only: the text it shows, dimmed when the page disables the list.
struct SelectionBox: View {
    let selection: VLANPortTable.Selection
    var width: CGFloat = 140

    var body: some View {
        let (text, locked): (String, Bool) = switch selection {
        case .locked(let text): (text, true)
        case .shown(let text): (text ?? "", false)
        }
        HStack(spacing: 4) {
            Text(text).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 2)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
        }
        .font(.caption).padding(.horizontal, 7).padding(.vertical, 4)
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
        .foregroundStyle(locked ? .tertiary : .primary)
        .help(locked ? "\(text)（网页中不可选）" : text)
    }
}

// MARK: - VLAN 配置文件

struct VLANProfilesView: View {
    @Environment(RouterStore.self) var store
    @StateObject private var reading = RouterReading<VLANProfileList>()
    private var connected: Bool { store.phase == .connected }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusPageHeader(title: "VLAN", subtitle: "VLAN 配置文件", symbol: "cable.connector.horizontal",
                                 readAt: reading.readAt, loading: reading.loading) { await load() }
                ReadErrorLabel(message: reading.error)
                if !connected {
                    ConnectionRequiredView()
                } else if let list = reading.value {
                    Text(list.description).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    profiles(list)
                    Text("网页在这里添加、修改与删除 VLAN 配置文件，保存时会重启网络；本应用只显示列表。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    ReadingPlaceholder(failed: reading.error != nil && !reading.loading, minHeight: 220)
                }
            }.padding(28)
        }
        .task(id: connected) { if connected, reading.value == nil { await load() } }
    }

    private func load() async { await reading.load(store: store) { try await $0.vlanProfileList() } }

    /// show_vlan_profile (257–357): one row per profile with the networks that use it, the VLAN ID and 端口隔离.
    private func profiles(_ list: VLANProfileList) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                Text("配置文件列表").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                    GridRow {
                        Text("无线名称（SSID）")
                        Text("VLAN ID").gridColumnAlignment(.center)
                        Text("端口隔离").gridColumnAlignment(.center)
                    }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(list.profiles.enumerated()), id: \.offset) { _, profile in
                        Divider().gridCellUnsizedAxes(.horizontal)
                        GridRow {
                            Text(profile.shownNetworks).lineLimit(nil).frame(maxWidth: .infinity, alignment: .leading)
                            Text(profile.shownVID).monospacedDigit()
                            Image(systemName: profile.isolated ? "checkmark.square.fill" : "square").foregroundStyle(.secondary)
                                .accessibilityLabel(profile.isolated ? "端口隔离：是" : "端口隔离：否")
                        }.font(.callout)
                    }
                }
                if list.profiles.isEmpty {
                    Text("目前没有配置文件。").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}
