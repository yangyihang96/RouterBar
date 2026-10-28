import SwiftUI
import RouterCore
import UniformTypeIdentifiers

/// 系统管理 › 恢复/导出/上传设置, in the web page's order: 原厂默认值, 导出设置, 恢复设置.
struct SettingBackupView: View {
    @Environment(RouterStore.self) var store
    @State private var removePasswords = false
    @State private var message: String?
    @State private var action: BackupAction?
    @State private var restoreBackup: ConfigurationBackup?
    @State private var resetConfirmation = ""
    enum BackupAction: String, Identifiable { case restore = "恢复设置", reset = "恢复原厂默认值"; var id: String { rawValue } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: "恢复/导出/上传设置", subtitle: "恢复原厂默认值、导出配置备份，或用备份文件恢复路由器设置。", symbol: "externaldrive.badge.timemachine")
                if store.phase != .connected { ConnectionRequiredView() }
                if let message { Label(message, systemImage: "info.circle").font(.callout).padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 12)) }
                Panel {
                    HStack(spacing: 18) {
                        Image(systemName: "arrow.counterclockwise.circle").font(.largeTitle).foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 7) { Text("原厂默认值").font(.headline); Text("清除路由器配置，需要重新设置网络与管理员账号。请先导出设置。").font(.callout).foregroundStyle(.secondary) }
                        Spacer(); Button("恢复…", role: .destructive) { resetConfirmation = ""; action = .reset }
                    }
                }
                Panel {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("导出设置", systemImage: "square.and.arrow.up").font(.headline)
                        Text("将这台路由器的配置保存为 .CFG 文件，日后可以在“恢复设置”中使用。").font(.callout).foregroundStyle(.secondary)
                        Toggle("从备份中移除密码", isOn: $removePasswords).toggleStyle(.switch).tint(.teal)
                        Button("导出配置备份…", action: export)
                    }
                }
                Panel {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("恢复设置", systemImage: "square.and.arrow.down").font(.headline)
                        Text("上传之前导出的 .CFG 文件并替换路由器配置。路由器会重新启动，管理地址和密码也可能改变。").font(.callout).foregroundStyle(.secondary)
                        Button("选择配置并恢复…", action: chooseRestore)
                    }
                }
                NoticeBanner(message: "网页上这一页还有 JFFS 分区的备份与恢复（Merlin），本应用尚未提供。", tone: .information)
            }.padding(32).disabled(store.phase != .connected || store.operationTitle != nil)
        }
        .sheet(item: $action) { selected in
            VStack(alignment: .leading, spacing: 20) {
                Text(selected.rawValue).font(.title2.bold())
                Text(selected == .restore ? "将上传 \(restoreBackup?.url.lastPathComponent ?? "所选文件") 并替换路由器配置。路由器会重启，管理地址和密码也可能改变。" : "路由器的网络与管理员配置将恢复默认值。请先导出设置。")
                if selected == .reset { TextField("输入“恢复出厂”确认", text: $resetConfirmation).textFieldStyle(.roundedBorder) }
                HStack { Spacer(); Button("取消") { action = nil }; Button("确认\(selected.rawValue)", role: .destructive) { action = nil; Task { await perform(selected) } }.buttonStyle(.borderedProminent).tint(.red).disabled(selected == .reset && resetConfirmation != "恢复出厂") }
            }.padding(28).frame(width: 500)
        }
    }
    private func export() {
        let panel = NSSavePanel(); panel.title = "保存路由器配置"; panel.nameFieldStringValue = "Settings_\(store.snapshot?.sample.identity.model ?? "Router").CFG"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            guard store.beginOperation("正在导出路由器配置", readOnly: true) else { return }; defer { store.endOperation() }
            do {
                let data = try await store.connectedClient().exportConfiguration(model: store.snapshot?.sample.identity.model ?? "", removePasswords: removePasswords)
                try PrivateFile.write(data, to: url)
                message = "备份已保存：\(url.lastPathComponent)"
            } catch { message = error.localizedDescription; store.handleManagementError(error) }
        }
    }
    private func chooseRestore() {
        let panel = NSOpenPanel(); panel.title = "选择路由器配置备份"; panel.allowedContentTypes = [UTType(filenameExtension: "cfg")!]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            do { restoreBackup = try ConfigurationBackup.inspect(url); action = .restore }
            catch { message = error.localizedDescription }
        }
    }
    private func perform(_ selected: BackupAction) async {
        guard store.beginOperation(selected.rawValue) else { return }; defer { store.endOperation() }
        let client: RouterClient
        do { client = try store.connectedClient() } catch { message = error.localizedDescription; return }
        do {
            switch selected {
            case .reset: try await client.factoryReset()
            case .restore: guard let restoreBackup else { return }; try await client.restoreConfiguration(restoreBackup) { _ in }
            }
            message = selected == .restore ? "路由器已接受配置文件，正在恢复并重新启动。网络恢复后，请在连接设置中核对新的管理地址和账号。" : "路由器已接收\(selected.rawValue)请求。正在等待网络恢复；完成状态以重新读取结果为准。"
            store.endSessionAfterReset(message ?? "")
        } catch RouterError.submissionUncertain(let reason) {
            message = reason
            store.endSessionAfterReset(reason)
        } catch { message = error.localizedDescription }
    }
}
