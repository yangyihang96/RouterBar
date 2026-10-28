import SwiftUI
import RouterCore

/// VPN › VPN Status: every VPN server, the configured clients and VPN Director with their state. A row opens
/// the VPN tab that holds it.
struct VPNStatusView: View {
    @Environment(RouterStore.self) var store
    @ObservedObject var model: VPNCenterModel

    private var connected: Bool { store.phase == .connected }
    private var loading: Bool { model.overview.values.contains(where: \.isLoading) || model.director.isLoading }
    private var clients: [VPNCenterDestination] { (model.listedClients + model.failedClients).map { .instance($0) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 15) {
                    PageHeader(title: "VPN Status", subtitle: "VPN 服务器、客户端和 VPN Director 的当前状态。点击一项即可打开它所在的分页。", symbol: "lock.shield")
                    Spacer()
                    if loading { ProgressView().controlSize(.small) }
                    Button("重新读取") { Task { await model.loadOverview(store: store) } }
                        .disabled(!connected || loading || model.isPreview || store.operationTitle != nil)
                }
                if !connected {
                    ConnectionRequiredView()
                } else {
                    group("虚拟专用网 (VPN) 服务器", VPNInstance.serverSlots.map { .instance($0) })
                    group("VPN 客户端", clients, empty: model.pendingClientCount > 0 ? "客户端设置尚未读取完成。" : "还没有配置 VPN 客户端。")
                    group("VPN Director", [.routing])
                    if let at = model.overviewReadAt { Text("读取于 \(VPNPresentation.time(at))").font(.caption).foregroundStyle(.secondary) }
                    NoticeBanner(message: "WireGuard 只显示路由器的启用开关，路由器未提供隧道状态，因此不会显示为已建立连接。PPTP 与 IPSec VPN 服务器尚未做成原生页面，不在此列出。", tone: .information)
                }
            }.padding(28)
        }
        .task(id: connected) { if connected, model.needsOverview { await model.loadOverview(store: store) } }
    }

    private func group(_ title: String, _ destinations: [VPNCenterDestination], empty: String? = nil) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                if destinations.isEmpty, let empty { Text(empty).font(.callout).foregroundStyle(.secondary) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 8, alignment: .topLeading)], alignment: .leading, spacing: 4) {
                    ForEach(destinations, id: \.self) { destination in
                        VPNDestinationRow(model: model, destination: destination) { store.openVPN(destination) }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
