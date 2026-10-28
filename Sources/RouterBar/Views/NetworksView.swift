import SwiftUI
import RouterCore

struct NetworksView: View {
    @Environment(RouterStore.self) var store
    @ObservedObject var model: SDNModel
    @State private var editing: SDNProfile?
    @State private var plan: SDNPlan?
    @State private var showReview = false
    @State private var showInternal = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    PageHeader(title: "网络", subtitle: "为家人、访客和智能设备安排合适的网络。", symbol: "network", eyebrow: "网络管理")
                    Spacer()
                    if model.loading { ProgressView().controlSize(.small) }
                    Button("重新读取") { Task { await model.load(store: store) } }
                    Button { do { if let snapshot = model.snapshot { editing = try SDNPlanner.newGuest(snapshot: snapshot) } } catch { model.notice = error.localizedDescription } } label: { Label("新建访客网络", systemImage: "plus") }.buttonStyle(.borderedProminent).tint(.teal).disabled(model.snapshot == nil)
                }.disabled(store.operationTitle != nil || store.phase != .connected || model.loading)
                if let notice = model.notice {
                    Label(notice, systemImage: model.verified ? "checkmark.circle.fill" : "info.circle").font(.callout).foregroundStyle(model.verified ? .green : .orange).padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.teal.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                }
                if store.phase != .connected { ConnectionRequiredView() }
                else if let snapshot = model.snapshot {
                    Toggle("显示兼容与回程网络", isOn: $showInternal).font(.caption).toggleStyle(.switch).tint(.teal)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 310), spacing: 18)], spacing: 18) {
                        ForEach(snapshot.profiles.filter { showInternal || ($0.listedOnWebPage && $0.kind != "LEGACY") }) { profile in
                            Panel {
                                VStack(alignment: .leading, spacing: 18) {
                                    HStack {
                                        Image(systemName: profile.isMain ? "wifi" : profile.vpn != "0" ? "lock.shield" : "person.2.wave.2").font(.system(size: 26)).foregroundStyle(profile.enabled ? .teal : .secondary)
                                        Spacer(); Text(profile.enabled ? "已启用" : "已关闭").font(.caption.weight(.medium)).foregroundStyle(profile.enabled ? .green : .secondary).padding(.horizontal, 9).padding(.vertical, 5).background(.quaternary.opacity(0.6), in: Capsule())
                                    }
                                    VStack(alignment: .leading, spacing: 7) { Text(profile.ssid.isEmpty ? "网络 \(profile.id)" : profile.ssid).font(.title3.bold()).lineLimit(1); Text(profile.isMain ? "主网络" : "\(profile.kind) · 网络 \(profile.id)").font(.caption).foregroundStyle(.secondary) }
                                    VStack(spacing: 7) {
                                        KeyValue(key: "认证", value: SDNSecurity.authLabel(profile.auth))
                                        if SDNWiFi7.isOffered(profile, supported: snapshot.wifi7Supported) {
                                            KeyValue(key: "WiFi7 模式", value: profile.wifi7 ? (profile.mloFronthaul ? "开启（MLO 前传）" : "开启") : "关闭")
                                        }
                                        KeyValue(key: "网段", value: profile.address.isEmpty ? "共用主局域网" : profile.address)
                                        KeyValue(key: "出口", value: profile.vpn == "0" ? "默认互联网" : vpnLabel(profile.vpn))
                                    }
                                    if profile.listedOnWebPage {
                                        HStack {
                                            Button("管理网络") { editing = profile }.buttonStyle(.borderedProminent).tint(.teal)
                                            Spacer()
                                            if profile.canDelete { Button(role: .destructive) { prepareDelete(profile) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("删除此网络") }
                                        }.disabled(store.operationTitle != nil)
                                    } else {
                                        Text(SDNSecurity.unlistedNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }
                    if snapshot.profiles.isEmpty { ContentUnavailableView("没有独立无线配置", systemImage: "wifi", description: Text("这台路由器尚未返回 SDN 网络配置。")) }
                    Label("这里编辑实际广播的网络名称；无线射频与专业参数可在控制台中调整。", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                } else if model.loading { ProgressView("正在读取网络配置…").frame(maxWidth: .infinity, minHeight: 250) }
            }.padding(30)
        }
        .task { if model.snapshot == nil { await model.load(store: store) } }
        .sheet(item: $editing) { profile in
            NetworkEditor(profile: profile, wifi7Supported: model.snapshot?.wifi7Supported ?? false) { updated in
                do {
                    guard let snapshot = model.snapshot else { return }
                    plan = try updated.id == "new" ? SDNPlanner.create(updated, snapshot: snapshot) : SDNPlanner.edit(updated, snapshot: snapshot)
                    editing = nil; showReview = true
                } catch { model.notice = error.localizedDescription; editing = nil }
            }
        }
        .sheet(isPresented: $showReview) {
            VStack(alignment: .leading, spacing: 20) {
                Text("确认修改网络").font(.title2.bold())
                Text(plan?.summary ?? "")
                if let plan, !plan.changes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("会一起写入的变量").font(.headline)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(plan.changes) { change in
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 8) { Text(change.title).font(.callout.weight(.medium)); Text(change.key).font(.caption.monospaced()).foregroundStyle(.secondary) }
                                        Text("原：\(change.before)").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                        Text("新：\(change.after)").font(.caption).fixedSize(horizontal: false, vertical: true)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }.frame(maxHeight: 240)
                    }
                }
                ForEach(plan?.warnings ?? [], id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if plan?.restartsWholeNetwork == true {
                    Label("此网络绑定了有线端口或 VLAN 中继，路由器需要重启整个局域网和全部无线（与路由器网页相同），所有有线和无线设备都会断开约半分钟。", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else {
                    Text("路由器会重新载入无线和相关网络服务，联网设备可能短暂断开。").foregroundStyle(.secondary)
                }
                Text("主网络与未修改的规则会保留。").foregroundStyle(.secondary)
                HStack { Spacer(); Button("取消") { showReview = false }; Button("确认应用") { showReview = false; if let plan { Task { await model.apply(plan, store: store) } } }.buttonStyle(.borderedProminent).tint(.teal) }
            }.padding(28).frame(width: 500)
        }
    }
    func prepareDelete(_ profile: SDNProfile) {
        do { guard let snapshot = model.snapshot else { return }; plan = try SDNPlanner.delete(profile, snapshot: snapshot); showReview = true }
        catch { model.notice = error.localizedDescription }
    }
    func vpnLabel(_ value: String) -> String { SDNClientRoute(value)?.title ?? "未知出口（\(value)）" }
}

private struct NetworkEditor: View {
    @State var profile: SDNProfile
    let wifi7Supported: Bool
    let save: (SDNProfile) -> Void
    @Environment(\.dismiss) var dismiss
    @State private var showReservations = false
    /// A WPA2-only auth chosen while WiFi7 模式 is on, waiting for the page's question.
    @State private var pendingAuth: String?
    /// The selector shows one 开放网络 choice; the router stores it as open, or as OWE while WiFi7 模式 is on.
    private var authSelection: Binding<String> {
        Binding(get: { ["open", "owe"].contains(profile.auth) ? "open" : profile.auth }, set: { choice in
            if SDNWiFi7.asksBeforeChoosing(choice, in: profile) { pendingAuth = choice } else { profile = SDNWiFi7.choosing(choice, in: profile) }
        })
    }
    private var wifi7: Binding<Bool> {
        Binding(get: { profile.wifi7 }, set: { on in
            if on { profile = SDNWiFi7.switchedOn(profile) } else if let next = try? SDNWiFi7.switchedOff(profile) { profile = next }
        })
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(profile.id == "new" ? "新建访客网络" : "管理网络").font(.title2.bold()); Spacer(); Text(profile.isMain ? "主网络" : profile.kind).foregroundStyle(.secondary) }.padding(24)
            Form {
                Section("无线网络") {
                    Toggle("启用网络", isOn: $profile.enabled).disabled(profile.isMain)
                    if SDNWiFi7.isOffered(profile, supported: wifi7Supported) {
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("WiFi7 模式", isOn: wifi7).disabled(profile.mloFronthaul || SDNSecurity.lockedReason(profile) != nil)
                            Text(profile.mloFronthaul ? SDNWiFi7.mloHint : SDNWiFi7.authHint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    TextField("网络名称", text: $profile.ssid)
                    Picker("安全方式", selection: authSelection) {
                        let choices = SDNWiFi7.authChoices(profile)
                        if !choices.contains(authSelection.wrappedValue) { Text("当前：\(SDNSecurity.authLabel(profile.auth))").tag(authSelection.wrappedValue) }
                        ForEach(choices, id: \.self) { auth in
                            Text(auth == "open" ? (profile.auth == "owe" ? "开放网络（OWE）" : "开放网络") : SDNSecurity.authLabel(auth)).tag(auth)
                        }
                    }.disabled(SDNSecurity.lockedReason(profile) != nil)
                    let cryptos = SDNWiFi7.cryptoChoices(profile)
                    if !cryptos.isEmpty {
                        Picker("加密方式", selection: $profile.crypto) {
                            if !cryptos.contains(profile.crypto) { Text("当前：\(SDNSecurity.cryptoLabel(profile.crypto))").tag(profile.crypto) }
                            ForEach(cryptos, id: \.self) { Text(SDNSecurity.cryptoLabel($0)).tag($0) }
                        }.disabled(SDNSecurity.lockedReason(profile) != nil)
                    }
                    if let locked = SDNSecurity.lockedReason(profile) {
                        Text(locked).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if !["open", "owe"].contains(profile.auth) { SecureField("无线密码", text: $profile.password) }
                    Toggle("隐藏网络名称", isOn: $profile.hidden)
                    Toggle("隔离网络内的无线设备", isOn: $profile.isolated)
                }
                if !profile.address.isEmpty {
                    Section("局域网与 DHCP") {
                        TextField("VLAN ID", text: $profile.vlan)
                        TextField("路由器地址", text: $profile.address)
                        TextField("子网掩码", text: $profile.mask)
                        Toggle("启用 DHCP", isOn: $profile.dhcp)
                        if profile.dhcp { TextField("起始地址", text: $profile.start); TextField("结束地址", text: $profile.end); TextField("租约（秒）", text: $profile.lease) }
                        TextField("DNS 服务器（逗号分隔）", text: $profile.dns)
                        Button("编辑固定地址分配…") { showReservations = true }
                        Toggle("允许访问主局域网", isOn: $profile.allowLAN)
                        Toggle("允许访问路由器服务", isOn: $profile.allowRouter)
                    }
                }
                Section("VPN 出口") {
                    Picker("网络出口", selection: $profile.vpn) {
                        Text("默认互联网").tag("0")
                        ForEach(1...5, id: \.self) { n in Text("WireGuard 客户端 \(n)").tag(String(n)) }
                        ForEach(1...5, id: \.self) { n in Text("OpenVPN 客户端 \(n)").tag(String(n + 5)) }
                    }
                    Toggle("VPN 中断时阻止互联网访问", isOn: $profile.killSwitch)
                }
                if profile.id == "new" { Section { Text("新网络将在当前路由器的 2.4 GHz 和 5 GHz 广播。").font(.caption).foregroundStyle(.secondary) } }
            }.formStyle(.grouped).tint(.teal)
            Divider()
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Button("查看变更") { save(profile) }.buttonStyle(.borderedProminent).tint(.teal) }.padding(20)
        }.frame(width: 640, height: 720)
        // The page's question (sdn.js 6859): 确定 switches WiFi7 模式 off with the new auth, 取消 keeps the old one.
        .alert("WiFi7 模式", isPresented: Binding(get: { pendingAuth != nil }, set: { if !$0 { pendingAuth = nil } }), presenting: pendingAuth) { auth in
            Button("取消", role: .cancel) {}
            Button("确定") { profile = SDNWiFi7.choosing(auth, in: profile) }
        } message: { _ in Text(SDNWiFi7.disableNote) }
        .sheet(isPresented: $showReservations) {
            RuleEditorSheet(field: .rules(key: "reservations", label: "固定地址分配", columns: ["MAC 地址", "IP 地址", "DNS 地址", "主机名"]), original: profile.reservations) { profile.reservations = $0 }
        }
    }
}
