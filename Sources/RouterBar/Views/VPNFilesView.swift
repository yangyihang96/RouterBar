import SwiftUI
import RouterCore
import UniformTypeIdentifiers

/// Native VPN file import/export and OpenVPN certificate editing for one explicitly addressed unit.
struct VPNFilesView: View {
    @Environment(RouterStore.self) var store
    let instance: VPNInstance
    /// Called after a request that may have changed this instance's settings on the router.
    var onRouterChanged: (() -> Void)? = nil
    @State private var keys: [OpenVPNKeyField: String]?
    @State private var keysReadAt: Date?
    @State private var loading = false
    @State private var editing: OpenVPNKeyField?
    @State private var importURL: URL?
    @State private var confirmImport = false
    @State private var peers: [Int]?
    @State private var peer = 1
    @State private var exportURL: URL?
    @State private var confirmExport = false
    @State private var message: String?
    @State private var verified = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let message {
                Label(message, systemImage: verified ? "checkmark.circle.fill" : "info.circle")
                    .font(.callout).foregroundStyle(verified ? .green : .orange).padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading).background((verified ? Color.green : .orange).opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
            switch instance {
            case .openVPNClient:
                importPanel(title: "导入 OpenVPN 配置", detail: "上传 .ovpn 文件，路由器会先重置该客户端，再按文件内容写入设置与内嵌证书。")
                keysPanel
            case .openVPNServer:
                keysPanel
                Panel {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) { Text("客户端连接配置").font(.headline); Text("导出此服务器生成的 .ovpn 文件。").font(.caption).foregroundStyle(.secondary) }
                        Spacer(); Button("导出配置…") { exportOpenVPN() }
                    }
                }
            case .wireGuardClient:
                importPanel(title: "导入 WireGuard 配置", detail: "上传 .conf 文件，路由器会解析并替换该客户端的接口与对端设置。")

            case .wireGuardServer:
                peersPanel
            }
        }
        .disabled(store.phase != .connected || store.operationTitle != nil)
        .task(id: instance) { await reset() }
        .sheet(item: $editing) { field in
            VPNKeyEditorSheet(instance: instance, field: field, original: keys?[field] ?? "") { text in
                Task { await saveKey(field, before: keys?[field] ?? "", after: text) }
            }
        }
        .confirmationDialog("替换\(instance.title)的配置？", isPresented: $confirmImport) {
            Button("上传并替换", role: .destructive) { Task { await performImport() } }
        } message: {
            Text("将上传 \(importURL?.lastPathComponent ?? "所选文件")。该实例现有设置会被替换，此操作无法撤销；若实例正在运行，需要重新启动后才会使用新配置。")
        }
        .confirmationDialog("导出 WireGuard 客户端 \(peer) 的配置？", isPresented: $confirmExport) {
            Button("导出") { Task { await performExport() } }
        } message: {
            Text("文件包含所选客户端的连接私钥，将保存到你选择的位置。请妥善保管。")
        }
    }

    private func exportOpenVPN() {
        guard case .openVPNServer(let unit) = instance else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "client\(unit).ovpn"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            guard store.beginOperation("正在导出 OpenVPN 客户端配置", readOnly: true) else { return }; defer { store.endOperation() }
            do {
                let data = try await store.connectedClient().exportOpenVPNServerConfiguration(unit: unit)
                try PrivateFile.write(data, to: url)
                message = "配置文件已保存。"; verified = true
            } catch { message = error.localizedDescription; verified = false; store.handleManagementError(error) }
        }
    }
    private func importPanel(title: String, detail: String) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                Label(title, systemImage: "square.and.arrow.down").font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                Button("选择配置文件…", action: chooseImport)
            }
        }
    }

    private var keysPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label("证书与密钥", systemImage: "key.viewfinder").font(.headline)
                    Spacer()
                    if loading { ProgressView().controlSize(.small) }
                    Button("重新读取") { Task { await loadKeys() } }
                }.padding(.bottom, 12)
                if let keys {
                    ForEach(Array(instance.keyFields.enumerated()), id: \.element) { index, field in
                        if index > 0 { Divider().padding(.vertical, 10) }
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(field.label).font(.callout)
                                Text(keys[field].map { $0.isEmpty ? "未设置" : "已设置 · \($0.utf8.count) 字节" } ?? "未读取").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("编辑…") { editing = field }
                        }
                    }
                    if let keysReadAt { Text("读取于 \(MonitoringDate.time(keysReadAt))").font(.caption).foregroundStyle(.secondary).padding(.top, 12) }
                } else if !loading {
                    Text("尚未读取证书。").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var peersPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("导出客户端配置", systemImage: "square.and.arrow.up").font(.headline)
                    Spacer()
                    if loading { ProgressView().controlSize(.small) }
                    Button("重新读取") { Task { await loadPeers() } }
                }
                if let peers, !peers.isEmpty {
                    Picker("客户端", selection: $peer) { ForEach(peers, id: \.self) { Text("客户端 \($0)").tag($0) } }.frame(width: 240)
                    Button("导出配置文件…", action: chooseExport)
                } else if peers != nil {
                    Text("没有已启用的 WireGuard 服务器客户端。").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func unsupportedNote(_ text: String) -> some View {
        Label(text, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
    }

    private func reset() async {
        keys = nil; keysReadAt = nil; peers = nil; message = nil; verified = false
        if !instance.keyFields.isEmpty { await loadKeys() }
        if instance == .wireGuardServer { await loadPeers() }
    }

    private func loadKeys() async {
        guard store.phase == .connected else { return }
        loading = true; defer { loading = false }
        do { keys = try await store.connectedClient().vpnKeyMaterial(instance); keysReadAt = Date() }
        catch { keys = nil; message = error.localizedDescription; verified = false; store.handleManagementError(error) }
    }

    private func loadPeers() async {
        guard store.phase == .connected else { return }
        loading = true; defer { loading = false }
        do {
            let list = try await store.connectedClient().wireGuardServerPeers()
            peers = list
            if !list.contains(peer), let first = list.first { peer = first }
        } catch { peers = nil; message = error.localizedDescription; verified = false; store.handleManagementError(error) }
    }

    private func chooseImport() {
        let wireGuard: Bool
        if case .wireGuardClient = instance { wireGuard = true } else { wireGuard = false }
        let panel = NSOpenPanel(); panel.title = wireGuard ? "选择 WireGuard 配置" : "选择 OpenVPN 配置"
        panel.allowedContentTypes = (wireGuard ? ["conf"] : ["ovpn", "conf"]).compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { _ = try VPNFileRules.readConfiguration(url, wireGuard: wireGuard) }
        catch { message = error.localizedDescription; verified = false; return }
        importURL = url; confirmImport = true
    }

    private func performImport() async {
        guard let url = importURL, store.beginOperation("正在导入\(instance.title)配置") else { return }
        defer { store.endOperation() }
        do {
            let client = try store.connectedClient()
            let outcome: VPNFileImportOutcome
            switch instance {
            case .openVPNClient(let n): outcome = try await client.importOpenVPNClientConfiguration(unit: n, file: url)
            case .wireGuardClient(let n): outcome = try await client.importWireGuardClientConfiguration(unit: n, file: url)
            default: return
            }
            verified = outcome == .complete
            if case .wireGuardClient = instance, case .incomplete(let state) = outcome {
                message = "路由器返回导入状态 \(state)，该状态码的含义未知。请在设置中核对该客户端。"
            } else {
                message = outcome.message
            }
        } catch { message = error.localizedDescription; verified = false; store.handleManagementError(error) }
        if !instance.keyFields.isEmpty { await loadKeys() }
        onRouterChanged?()
    }

    private func saveKey(_ field: OpenVPNKeyField, before: String, after: String) async {
        guard store.beginOperation("正在保存\(field.label)") else { return }
        defer { store.endOperation() }
        do {
            let receipt = try await store.connectedClient().saveVPNKey(instance, field: field, before: before, after: after)
            message = receipt.message; verified = receipt.verified
        } catch { message = error.localizedDescription; verified = false; store.handleManagementError(error) }
        await loadKeys()
        onRouterChanged?()
    }

    private func chooseExport() {
        let panel = NSSavePanel(); panel.title = "保存 WireGuard 客户端配置"; panel.nameFieldStringValue = "wgs1_client\(peer).conf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportURL = url; confirmExport = true
    }

    private func performExport() async {
        guard let url = exportURL, store.beginOperation("正在导出 WireGuard 客户端配置") else { return }
        defer { store.endOperation() }
        do {
            let export = try await store.connectedClient().exportWireGuardServerPeer(peer)
            try PrivateFile.write(export.data, to: url)
            message = "配置已保存：\(url.lastPathComponent)。" + export.note; verified = true
        } catch { message = error.localizedDescription; verified = false; store.handleManagementError(error) }
    }
}

struct VPNKeyEditorSheet: View {
    let instance: VPNInstance
    let field: OpenVPNKeyField
    let original: String
    let save: (String) -> Void
    @Environment(\.dismiss) var dismiss
    @State private var draft = ""
    @State private var reveal = false
    @State private var confirming = false
    @State private var error: String?
    private var validation: String? {
        guard draft != original else { return "内容没有变化" }
        do { try VPNFileRules.validateKey(draft, field: field); return nil } catch { return error.localizedDescription }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Label(field.label, systemImage: "key").font(.title2.bold()); Spacer(); Text("\(draft.utf8.count) / \(VPNFileRules.maxKeyBytes) 字节").font(.caption).foregroundStyle(.secondary) }
            Text(instance.title).foregroundStyle(.secondary)
            if field.isSecret && !reveal && !original.isEmpty {
                Button("查看并编辑密钥") { reveal = true }.frame(maxWidth: .infinity, minHeight: 280)
            } else {
                TextEditor(text: $draft).font(.system(.caption, design: .monospaced)).frame(minHeight: 280).overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
            }
            if let error { Text(error).foregroundStyle(.orange).font(.callout) }
            else if let validation, draft != original { Text(validation).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("从文件载入…", action: load)
                Button("导出到文件…", action: export).disabled(original.isEmpty)
                Button("清空", role: .destructive) { reveal = true; draft = "" }.disabled(draft.isEmpty)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存到路由器…") { confirming = true }.buttonStyle(.borderedProminent).tint(.teal).disabled(validation != nil)
            }
        }
        .padding(26).frame(width: 640)
        .onAppear { draft = original }
        .confirmationDialog(draft.isEmpty ? "清空\(field.label)？" : "替换\(field.label)？", isPresented: $confirming) {
            Button(draft.isEmpty ? "清空" : "保存并替换", role: .destructive) { save(draft); dismiss() }
        } message: {
            Text("路由器中\(instance.title)现有的\(field.label)会被替换。若该实例正在运行，路由器会重启它，连接会短暂中断。")
        }
    }
    private func load() {
        let panel = NSOpenPanel(); panel.title = "选择\(field.label)文件"; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? .max) <= VPNFileRules.maxKeyBytes else { throw RouterError.validation("请选择不超过 \(VPNFileRules.maxKeyBytes) 字节的文本文件") }
            guard let text = String(data: try Data(contentsOf: url), encoding: .utf8) else { throw RouterError.validation("文件不是 UTF-8 文本") }
            reveal = true; draft = text; error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func export() {
        let panel = NSSavePanel(); panel.title = "导出\(field.label)"; panel.nameFieldStringValue = "\(instance.id)_\(field.rawValue).pem"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PrivateFile.write(Data(original.utf8), to: url)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
