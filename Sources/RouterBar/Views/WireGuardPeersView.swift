import SwiftUI
import RouterCore

struct WireGuardPeersView: View {
    @Environment(RouterStore.self) var store
    let onChanged: () -> Void
    @State private var peers: [WireGuardPeer] = []
    @State private var editing: WireGuardPeer?
    @State private var notice: String?
    @State private var loading = false
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Label("WireGuard 客户端", systemImage: "person.2.fill").font(.headline); Spacer(); if loading { ProgressView().controlSize(.small) }; Button("重新读取") { Task { await load() } } }
                if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                ForEach(peers) { peer in
                    HStack {
                        Circle().fill(peer.enabled ? Color.teal : .secondary.opacity(0.3)).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 4) { Text(peer.name.isEmpty ? "客户端 \(peer.unit)" : peer.name).font(.callout); Text(peer.address.isEmpty ? "尚未设置" : peer.address).font(.caption).foregroundStyle(.secondary) }
                        Spacer(); Text(peer.enabled ? "已启用" : "已关闭").font(.caption).foregroundStyle(.secondary)
                        Button("编辑…") { editing = peer }
                    }
                    if peer.unit != peers.last?.unit { Divider() }
                }
            }.disabled(store.operationTitle != nil || store.phase != .connected)
        }.task { await load() }
        .sheet(item: $editing) { peer in
            WireGuardPeerEditor(original: peer) { updated in Task { await save(peer, updated) } }
        }
    }
    func load() async {
        guard !loading else { return }; loading = true; defer { loading = false }
        do { peers = try await store.connectedClient().wireGuardPeerConfigurations() }
        catch { notice = error.localizedDescription; store.handleManagementError(error) }
    }
    func save(_ old: WireGuardPeer, _ new: WireGuardPeer) async {
        guard store.beginOperation("正在更新 WireGuard 客户端") else { return }; defer { store.endOperation() }
        do { let receipt = try await store.connectedClient().saveWireGuardPeer(before: old, after: new); notice = receipt.message; if receipt.isVerified { await load(); onChanged() } }
        catch { notice = error.localizedDescription; store.handleManagementError(error) }
    }
}
private struct WireGuardPeerEditor: View {
    let original: WireGuardPeer
    let save: (WireGuardPeer) -> Void
    @State private var draft: WireGuardPeer
    @Environment(\.dismiss) var dismiss
    init(original: WireGuardPeer, save: @escaping (WireGuardPeer) -> Void) { self.original = original; self.save = save; _draft = State(initialValue: original) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("WireGuard 客户端 \(draft.unit)").font(.title2.bold())
            Form {
                Toggle("启用客户端", isOn: $draft.enabled)
                TextField("名称", text: $draft.name)
                TextField("隧道地址（IP / 前缀）", text: $draft.address)
                TextField("服务器允许的 IP", text: $draft.serverAllowedIPs)
                TextField("客户端允许的 IP", text: $draft.clientAllowedIPs)
            }.formStyle(.grouped).frame(height: 250)
            Text("保存会重载 WireGuard 服务，现有连接可能暂时中断。允许的 IP 可用逗号分隔多个范围。").font(.callout).foregroundStyle(.secondary)
            HStack { Spacer(); Button("取消") { dismiss() }; Button("保存到路由器") { save(draft); dismiss() }.buttonStyle(.borderedProminent).tint(.teal).disabled(draft == original) }
        }.padding(24).frame(width: 580)
    }
}
