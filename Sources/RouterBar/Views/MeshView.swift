import SwiftUI
import RouterCore

struct MeshView: View {
    @Environment(RouterStore.self) var store
    @State private var nodes: [MeshNode] = []
    @State private var loading = false
    @State private var notice: String?
    @State private var selected: MeshNode?
    @State private var action: MeshAction?
    @State private var showAction = false
    @State private var alias = ""
    @State private var showRename = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    PageHeader(title: "AiMesh 网络", subtitle: "查看各个节点的连接情况与运行状态。", symbol: "point.3.connected.trianglepath.dotted", eyebrow: "网络管理")
                    Spacer(); if loading { ProgressView().controlSize(.small) }; Button("重新读取") { Task { await load() } }.disabled(loading || store.operationTitle != nil)
                }
                if store.phase != .connected { ConnectionRequiredView() }
                if let notice { NoticeBanner(message: notice) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 18)], spacing: 18) {
                    ForEach(nodes) { node in
                        Panel {
                            VStack(alignment: .leading, spacing: 18) {
                                HStack { Image(systemName: node.primary ? "wifi.router.fill" : "dot.radiowaves.left.and.right").font(.system(size: 30)).foregroundStyle(.teal); Spacer(); Text(node.online ? "在线" : "离线").font(.caption).foregroundStyle(node.online ? .green : .secondary) }
                                VStack(alignment: .leading, spacing: 7) { Text(node.name).font(.title3.bold()); Text(node.primary ? "主路由器" : "AiMesh 节点").font(.caption).foregroundStyle(.secondary) }
                                VStack(spacing: 7) { KeyValue(key: "型号", value: node.model); KeyValue(key: "IP 地址", value: node.ip.isEmpty ? "—" : node.ip); KeyValue(key: "固件", value: node.firmware.isEmpty ? "—" : node.firmware) }
                                HStack {
                                    Button("修改名称") { selected = node; alias = node.alias.isEmpty ? node.model : node.alias; showRename = true }
                                    if !node.primary {
                                        Menu("维护") { Button("优化连接") { prepare(.optimize, node) }; Button("重启节点") { prepare(.reboot, node) }; Divider(); Button("移除并重置节点", role: .destructive) { prepare(.remove, node) } }
                                    }
                                }.disabled(store.operationTitle != nil)
                            }
                        }
                    }
                }
                if nodes.count == 1 { Text("目前只读取到主路由器，没有已加入的 AiMesh 节点。").font(.callout).foregroundStyle(.secondary) }
                if nodes.isEmpty && !loading { ContentUnavailableView("尚未读取节点", systemImage: "wifi.router", description: Text("连接后点击重新读取。")) }
            }.padding(32)
        }
        .task { await load() }
        .sheet(isPresented: $showRename) {
            VStack(alignment: .leading, spacing: 20) {
                Text("节点名称").font(.title2.bold()); TextField("名称", text: $alias).textFieldStyle(.roundedBorder)
                HStack { Spacer(); Button("取消") { showRename = false }; Button("保存到路由器") { showRename = false; Task { await rename() } }.buttonStyle(.borderedProminent).tint(.teal).disabled(alias.isEmpty) }
            }.padding(28).frame(width: 420)
        }
        .confirmationDialog("确认操作这个 AiMesh 节点？", isPresented: $showAction, titleVisibility: .visible) {
            Button(action == .remove ? "移除并重置" : action == .reboot ? "重启节点" : "优化连接", role: action == .remove ? .destructive : nil) { Task { await perform() } }
        } message: { Text(action == .remove ? "节点的配置将重置，并从 AiMesh 中移除。" : "此节点上的设备可能短暂断开连接。") }
    }
    func load() async {
        guard store.phase == .connected, !loading else { return }; loading = true; defer { loading = false }
        do { nodes = try await store.connectedClient().meshNodes() } catch { notice = error.localizedDescription; store.handleManagementError(error) }
    }
    func prepare(_ requested: MeshAction, _ node: MeshNode) { selected = node; action = requested; showAction = true }
    func rename() async {
        guard let selected, store.beginOperation("正在修改节点名称") else { return }; defer { store.endOperation() }
        do { let confirmed = try await store.connectedClient().setMeshAlias(mac: selected.mac, alias: alias); notice = confirmed ? "已从路由器确认节点名称更新。" : "已提交节点名称，等待节点同步后重新读取确认。"; await load() }
        catch { notice = error.localizedDescription; store.handleManagementError(error) }
    }
    func perform() async {
        guard let selected, let action, store.beginOperation("正在操作 AiMesh 节点") else { return }; defer { store.endOperation() }
        do { try await store.connectedClient().meshAction(action, mac: selected.mac); notice = "节点操作请求已发送，完成情况以重新读取的节点状态为准。"; try await Task.sleep(for: .seconds(5)); await load() }
        catch { notice = error.localizedDescription; store.handleManagementError(error) }
    }
}
