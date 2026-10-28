import SwiftUI
import ServiceManagement
import RouterCore

struct ConnectionView: View {
    @Environment(RouterStore.self) var store
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var remember = false
    @State private var loginItem = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "连接你的路由器", subtitle: "一次连接，即可查看网络、管理设备和调整设置。", symbol: "wifi.router.fill", eyebrow: "本地连接")
                ConnectionJourney(current: store.phase == .connected ? 2 : store.phase == .connecting ? 1 : 0)
                Panel {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("路由器登录").font(.headline)
                        labeled("管理地址") { TextField("http://192.168.50.1", text: $address) }
                        labeled("用户名") { TextField("路由器管理用户名", text: $username).textContentType(.username) }
                        labeled("密码") { SecureField("路由器管理密码", text: $password).textContentType(.password).onSubmit(connect) }
                        Toggle("将密码保存到这台 Mac 的钥匙串", isOn: $remember).font(.callout)
                        HStack {
                            Button(action: connect) {
                                HStack { if store.phase == .connecting { ProgressView().controlSize(.small) }; Text(store.phase == .connecting ? "正在连接…" : "连接路由器") }
                            }.buttonStyle(.borderedProminent).tint(.teal).controlSize(.large)
                                .disabled(store.phase == .connecting || username.isEmpty || password.isEmpty || address.isEmpty)
                            if store.rememberCredentials && store.phase != .connected { Button("恢复已保存登录") { Task { await store.restoreSavedLogin() } }.disabled(store.phase == .connecting || store.credentialAccess.state.isWaiting) }
                            if store.phase == .connected { Button("断开本机连接") { store.disconnect() } }
                            Spacer()
                            Button("打开网络地图") { store.open(.overview) }.buttonStyle(.link)
                        }
                        Text("账号和密码仅用于连接这台路由器。未勾选保存时，退出程序后需要重新登录。").font(.caption).foregroundStyle(.secondary)
                        if address.lowercased().hasPrefix("http://") {
                            Text("当前使用局域网 HTTP 连接；支持填写已配置信任证书的 HTTPS 地址。").font(.caption).foregroundStyle(.secondary)
                        }
                        CredentialAccessPanel()
                        if let notice = store.credentialNotice { NoticeBanner(message: notice, tone: .attention) }
                    }.textFieldStyle(.roundedBorder)
                }
                Panel {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("菜单栏与刷新").font(.headline)
                        HStack {
                            Text("自动刷新间隔")
                            Spacer()
                            Picker("自动刷新间隔", selection: Binding(get: { store.refreshSeconds }, set: { store.refreshSeconds = $0 })) {
                                Text("5 秒").tag(5.0); Text("10 秒").tag(10.0); Text("30 秒").tag(30.0); Text("60 秒").tag(60.0)
                            }.labelsHidden().frame(width: 130)
                        }
                        Toggle("登录 Mac 时启动", isOn: Binding(get: { loginItem }, set: setLoginItem))
                        if let error = loginItemError { Text(error).font(.caption).foregroundStyle(.orange) }
                        if SMAppService.mainApp.status == .requiresApproval {
                            Button("在系统设置中允许后台启动") { SMAppService.openSystemSettingsLoginItems() }
                        }
                        Divider()
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("已保存的登录信息")
                                Text("移除密码不影响路由器设置。").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(); Button("移除保存的密码") { Task { await store.forgetPassword(); remember = false } }.disabled(store.credentialAccess.state.isWaiting)
                        }
                    }
                }
                Text("路由器面板 \(RouterClient.appVersion) · 本地原生客户端\n状态、历史、网络诊断、设置与固件管理共用一次登录。")
                    .font(.caption).foregroundStyle(.secondary).lineSpacing(4)
            }.padding(28).frame(maxWidth: 750)
        }
        .onAppear { address = store.address; username = store.username; remember = store.rememberCredentials }
    }
    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack { Text(title).frame(width: 68, alignment: .leading).foregroundStyle(.secondary); content() }
    }
    private func connect() {
        guard store.phase != .connecting, !username.isEmpty, !password.isEmpty else { return }
        Task {
            await store.connect(address: address, username: username, password: password, remember: remember)
            if store.phase == .connected { password = "" }
        }
    }
    private func setLoginItem(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItem = SMAppService.mainApp.status == .enabled
            loginItemError = nil
        } catch { loginItemError = "无法更新启动设置：" + error.localizedDescription }
    }
}
