import SwiftUI
import RouterCore

struct AdministratorView: View {
    @Environment(RouterStore.self) var store
    @State private var mode = "password"
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmation = ""
    @State private var newUsername = ""
    @State private var notice: String?
    @State private var confirmChange = false
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 16) {
                Label("管理员账号", systemImage: "person.crop.circle.badge.checkmark").font(.headline)
                Text("当前登录名：\(store.username)").font(.callout).foregroundStyle(.secondary)
                Picker("修改项目", selection: $mode) { Text("修改密码").tag("password"); Text("修改登录名").tag("username") }.pickerStyle(.segmented).frame(maxWidth: 320)
                SecureField("当前管理员密码", text: $currentPassword).textFieldStyle(.roundedBorder).frame(maxWidth: 380)
                if mode == "password" {
                    SecureField("新密码（10–32 位）", text: $newPassword).textFieldStyle(.roundedBorder).frame(maxWidth: 380)
                    SecureField("再次输入新密码", text: $confirmation).textFieldStyle(.roundedBorder).frame(maxWidth: 380)
                } else { TextField("新的管理员登录名", text: $newUsername).textFieldStyle(.roundedBorder).frame(maxWidth: 380) }
                if let notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
                HStack { Text("修改成功后，应用会直接恢复连接并按现有偏好更新钥匙串。").font(.caption).foregroundStyle(.secondary); Spacer(); Button("应用修改") { confirmChange = true }.disabled(currentPassword.isEmpty || (mode == "password" ? newPassword.isEmpty || newPassword != confirmation : newUsername.isEmpty)) }
            }.disabled(store.phase != .connected || store.operationTitle != nil)
        }
        .confirmationDialog("确认修改路由器管理员信息？", isPresented: $confirmChange, titleVisibility: .visible) {
            Button("确认修改") { Task { await apply() } }
        } message: { Text("路由器管理服务会重新启动，应用使用新的管理员信息恢复连接。") }
    }
    func apply() async {
        let change: AdministratorChange = mode == "password" ? .password(newPassword) : .username(newUsername)
        do {
            notice = try await store.changeAdministrator(currentPassword: currentPassword, change: change)
            currentPassword = ""; newPassword = ""; confirmation = ""
        } catch { notice = error.localizedDescription }
    }
}
