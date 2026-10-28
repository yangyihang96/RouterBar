import SwiftUI
import RouterCore

extension VPNScope {
    var title: String {
        switch self {
        case .routing: "VPN Director"
        case .openVPNServers: "OpenVPN 服务器"
        case .otherServers: "其他 VPN 服务器"
        case .clients(let family): "\(family.title) 客户端"
        }
    }
    var subtitle: String {
        switch self {
        case .routing: "按设备选择经由哪个 VPN 客户端或 WAN 上网。"
        case .openVPNServers: "在外面通过 OpenVPN 访问家中网络。选择左侧的服务器查看状态和修改设置。"
        case .otherServers: "在外面通过 WireGuard 访问家中网络。PPTP 与 IPSec VPN 服务器尚未做成原生页面。"
        case .clients(let family): "让路由器连接外部 \(family.title) VPN。选择左侧的配置查看状态和修改设置；尚未填写连接信息的位置收在“添加配置”。"
        }
    }
    var symbol: String {
        switch self {
        case .routing: "arrow.triangle.branch"
        case .openVPNServers, .otherServers: "house.and.flag"
        case .clients: "arrow.up.right.circle"
        }
    }
}

/// One VPN tab or switch choice of the web's VPN menu: the slots it holds and the editor of the selected one.
/// Configured client slots are listed; slots read as empty fold into "添加配置"; every slot stays reachable.
struct VPNCenterView: View {
    @Environment(RouterStore.self) var store
    @ObservedObject var model: VPNCenterModel
    let scope: VPNScope

    private var connected: Bool { store.phase == .connected }
    /// The selection while this tab holds it; a slot selected on another VPN tab is not shown here.
    private var shown: VPNCenterDestination? { model.selection.flatMap { scope.destinations.contains($0) ? $0 : nil } }
    private var family: VPNProtocolFamily? { if case .clients(let family) = scope { family } else { nil } }

    var body: some View {
        Group {
            if scope == .routing {
                detail
            } else {
                HStack(spacing: 0) {
                    sidebar.frame(width: 280).background(.bar)
                    Divider()
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: connected) { if connected, model.needsOverview { await model.loadOverview(store: store) } }
        .onAppear(perform: syncSelection)
        .confirmationDialog("放弃当前尚未保存的修改？", isPresented: Binding(get: { model.pendingSelection != nil }, set: { if !$0 { model.cancelPendingSelection() } }), titleVisibility: .visible) {
            Button("放弃并切换", role: .destructive) { model.confirmPendingSelection(store: store) }
            Button("继续编辑", role: .cancel) { model.cancelPendingSelection() }
        } message: {
            Text("\(model.editor.changes.count) 项修改尚未保存到路由器，切换后会被丢弃。")
        }
        .sheet(isPresented: $model.showingAddSheet) {
            VPNAddProfileSheet(model: model, families: family.map { [$0] } ?? [.openVPN, .wireGuard]) { instance in
                model.showingAddSheet = false
                model.requestSelection(.instance(instance), store: store)
            }
        }
    }

    /// VPN Director has a single editor, which the tab opens directly; other tabs start from their list.
    private func syncSelection() {
        if scope == .routing {
            if model.selection != .routing { model.requestSelection(.routing, store: store) }
        } else if model.selection != nil, shown == nil {
            model.clearSelection()
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(scope.title).font(.headline)
                    Group {
                        if model.overview.values.contains(where: \.isLoading) { Text("正在读取…") }
                        else if let at = model.overviewReadAt { Text("读取于 \(VPNPresentation.time(at))") }
                        else { Text(connected ? "尚未读取" : "未连接路由器") }
                    }.font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await model.loadOverview(store: store) } } label: { Image(systemName: "arrow.clockwise") }
                    .help("重新读取全部 VPN 设置").buttonStyle(.borderless)
                    .disabled(!connected || model.isPreview || model.overview.values.contains(where: \.isLoading))
            }.padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 10)
            if let blocked = model.blockedMessage {
                Text(blocked).font(.caption).foregroundStyle(.orange).padding(.horizontal, 16).padding(.bottom, 6)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) { rows }.padding(.horizontal, 9).padding(.bottom, 18)
            }
            .disabled(store.operationTitle != nil)
        }
    }

    @ViewBuilder private var rows: some View {
        switch scope {
        case .clients(let family):
            let listed = (model.listedClients + model.failedClients).filter { $0.family == family }
            let unused = model.unusedClients.filter { $0.family == family }
            let pending = VPNInstance.outboundSlots.filter { $0.family == family && unread($0) }.count
            ForEach(listed, id: \.self) { row(.instance($0)) }
            if pending > 0 {
                Label("\(pending) 个客户端位置尚未读取", systemImage: "hourglass")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 11).padding(.vertical, 6)
            }
            Button { model.showingAddSheet = true } label: {
                Label(unused.isEmpty ? "暂无未配置的连接位置" : "添加配置（\(unused.count) 个位置）", systemImage: "plus.circle")
                    .font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 11).padding(.vertical, 8)
            }.buttonStyle(.plain).foregroundStyle(.teal).disabled(unused.isEmpty)
        case .openVPNServers:
            ForEach(scope.destinations, id: \.self) { row($0) }
        case .otherServers:
            unavailableRow("PPTP", symbol: "network.badge.shield.half.filled")
            unavailableRow("IPSec VPN", symbol: "network.badge.shield.half.filled")
            ForEach(scope.destinations, id: \.self) { row($0) }
        case .routing:
            EmptyView()
        }
    }

    private func unread(_ instance: VPNInstance) -> Bool {
        switch model.state(instance) { case .notRead, .loading: true; default: false }
    }

    private func row(_ destination: VPNCenterDestination) -> some View {
        VPNDestinationRow(model: model, destination: destination, selected: shown == destination) { model.requestSelection(destination, store: store) }
    }

    private func unavailableRow(_ title: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).frame(width: 20).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                Text("尚未做成原生页面").font(.caption)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary).padding(.horizontal, 11).padding(.vertical, 9)
        .help("网页版“虚拟专用网 (VPN) 服务器 › Others”中的 \(title) 服务器，本应用尚未提供。")
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let shown {
            VPNProfileEditor(center: model, editor: model.editor, destination: shown).id(shown)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PageHeader(title: scope.title, subtitle: scope.subtitle, symbol: scope.symbol)
                    if model.selection != nil, model.editor.saving {
                        // The save keeps its slot selected, so its result waits on the VPN tab that holds the slot.
                        NoticeBanner(message: "另一个 VPN 分页的配置正在保存，完成后回到该分页即可查看结果。", tone: .information)
                    }
                    if !connected {
                        ConnectionRequiredView()
                    } else if scope == .routing {
                        // Only reached when the editor could not switch, e.g. while another operation runs.
                        if let blocked = model.blockedMessage { NoticeBanner(message: blocked, tone: .attention) }
                        Button("打开 VPN Director") { model.requestSelection(.routing, store: store) }.disabled(store.operationTitle != nil)
                    } else {
                        if let family {
                            let listed = model.listedClients.filter { $0.family == family }.count
                            let unused = model.unusedClients.filter { $0.family == family }.count
                            Panel { SectionTitle(title: "\(listed) 个配置", subtitle: "\(unused) 个位置尚未填写连接信息，可以通过“添加配置”导入或填写。", symbol: scope.symbol) }
                        }
                        if family == .wireGuard || scope == .otherServers {
                            NoticeBanner(message: "WireGuard 只显示路由器的启用开关，路由器未提供隧道状态，因此不会显示为已建立连接。", tone: .information)
                        }
                    }
                }.padding(28)
            }
        }
    }
}

/// A VPN slot or VPN Director as the VPN tabs and VPN Status list it: name, slot, connection and status.
struct VPNDestinationRow: View {
    @Environment(RouterStore.self) var store
    @ObservedObject var model: VPNCenterModel
    let destination: VPNCenterDestination
    var selected = false
    let action: () -> Void

    private var connected: Bool { store.phase == .connected }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: destination.symbol).frame(width: 20).padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.callout.weight(.medium)).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    VPNStatusLabel(status: status, compact: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .foregroundStyle(selected ? Color.teal : Color.primary)
            .background(selected ? Color.teal.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var title: String {
        guard let instance = destination.instance else { return destination.title }
        return model.state(instance).value?.displayName ?? instance.title
    }

    private var subtitle: String {
        switch destination {
        case .routing:
            switch model.director {
            case .loaded(let summary, _): return "\(summary.total) 条规则 · \(summary.enabled) 条启用"
            case .failed(let message, _): return message
            default: return "VPN Director"
            }
        case .instance(let instance):
            var parts = [instance.slotLabel]
            if let line = model.state(instance).value?.connectionLine { parts.append(line) }
            if let refs = model.directorReferences(instance), refs.total > 0 { parts.append("分流规则 \(refs.total) 条") }
            return parts.joined(separator: " · ")
        }
    }

    private var status: VPNStatusDescription {
        switch destination {
        case .instance(let instance): return .overview(model.state(instance), connected: connected)
        case .routing:
            guard connected else { return .init("未连接路由器", tone: .neutral) }
            switch model.director {
            case .loaded(_, let at): return .init("已读取", tone: .neutral, at: at)
            case .failed(_, let at): return .init("读取失败", tone: .failure, at: at)
            case .loading(let since): return .init("正在读取…", tone: .neutral, at: since)
            default: return .init("尚未读取", tone: .neutral)
            }
        }
    }
}

/// Lists only slots freshly read as unused. Choosing one opens its editor, which re-reads the slot before
/// offering import as the recommended step.
struct VPNAddProfileSheet: View {
    @ObservedObject var model: VPNCenterModel
    var families: [VPNProtocolFamily] = [.openVPN, .wireGuard]
    let choose: (VPNInstance) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("添加 VPN 配置", systemImage: "plus.circle").font(.title2.bold())
            Text("以下位置尚未填写连接信息。打开后会重新读取设置；旧证书等内容未在列表中检查，导入仍会替换所选位置的设置。").font(.callout).foregroundStyle(.secondary)
            ForEach(families, id: \.self) { family in
                let slots = model.unusedClients.filter { $0.family == family }
                VStack(alignment: .leading, spacing: 8) {
                    Text(family.title).font(.headline)
                    if slots.isEmpty {
                        Text("没有未配置的连接位置。").font(.caption).foregroundStyle(.secondary)
                    } else {
                        HStack { ForEach(slots, id: \.self) { slot in Button("槽位 \(slot.unit)") { choose(slot) } } }
                    }
                }
            }
            if let at = model.overviewReadAt { Text("依据 \(VPNPresentation.time(at)) 的读取结果。").font(.caption).foregroundStyle(.secondary) }
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(26).frame(width: 520)
    }
}

#if DEBUG
#Preview("VPN 客户端") {
    VPNCenterView(model: .preview(), scope: .clients(.openVPN))
        .environment(RouterStore(autoStart: false))
        .frame(width: 1060, height: 700)
}
#endif
