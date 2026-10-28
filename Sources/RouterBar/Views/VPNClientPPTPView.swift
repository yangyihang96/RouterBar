import RouterCore
import SwiftUI

// VPN › VPN 客户端 › PPTP/L2TP（Advanced_VPNClient_Content.asp 载入的 VPN/vpnc.html）：配置列表与每 5 秒的状态、新增与编辑、
// 开关、删除，以及 VPN Fusion 的“适用于所有设备”、设备分配与“互联网”卡。开关、应用、删除和“适用于所有设备”都先请用户确认，
// 再发送网页的同一 httpApi.nvramSet（applyapp.cgi），之后按网页的等待重新读取核对；离开页面即停止定时读取。

struct VPNClientPPTPView: View {
    @Environment(RouterStore.self) var store
    @StateObject private var reading = RouterReading<VPNClientPage>()
    /// The page as the 5-second check and the forms' reads leave it.
    @State private var page: VPNClientPage?
    /// The form beside the list: one of the profiles, or 互联网 (Fusion).
    @State private var form: VPNClientEditor?
    @State private var formHint: VPNClientForm.Invalid?
    /// 添加设置文件, which the page opens as a popup.
    @State private var adding: AddSession?
    @State private var confirming: Pending?
    @State private var alert: String?
    @State private var notice: (message: String, tone: NoticeBanner.Tone)?
    @State private var showsHelp = false
    @State private var poller: Task<Void, Never>?
    /// After a switch without Fusion the check reads the running client again first (614–617); a save or delete ends it.
    @State private var refreshingClient = false
    /// switch_time (68, 394–400): another switch within 4 seconds only shows 请稍候.
    @State private var lastSwitch: Date?
    @State private var opening = false
    /// A switch's NAT check is out (the web reads it synchronously within the click, 464–510): nothing else starts meanwhile.
    @State private var preparing = false
    @State private var session = 0
    @State private var shown = false
    private var connected: Bool { store.phase == .connected }

    struct AddSession: Identifiable { let id = UUID(); let editor: VPNClientEditor }

    /// A write waiting for the user's confirmation, with the page basis it was built on and what the page does afterwards.
    struct Pending: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let button: String
        let requests: [VPNClientRequest]
        let operation: String
        let basis: VPNClientBasis
        let afterwards: Afterwards
        enum Afterwards { case switched(running: Bool), added, saved, deleted, defaultSwitched, internetApplied }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusPageHeader(title: page?.title ?? "VPN 客户端", subtitle: "VPN 客户端 - PPTP/L2TP", symbol: "lock.shield",
                                 readAt: reading.readAt, loading: reading.loading) { await load(keepingForm: false) }
                ReadErrorLabel(message: reading.error)
                if let notice { NoticeBanner(message: notice.message, tone: notice.tone) }
                if !connected {
                    ConnectionRequiredView()
                } else if let page {
                    content(page)
                } else {
                    // A notice before the page was read is the read's error.
                    ReadingPlaceholder(failed: notice?.tone == .error, minHeight: 220)
                }
            }.padding(28).disabled(store.operationTitle != nil || reading.loading || opening || preparing)
        }
        .task(id: connected) { if connected, page == nil { await load(keepingForm: false) } }
        .onAppear { shown = true }
        .onDisappear { shown = false; session += 1; poller?.cancel(); poller = nil }
        .sheet(item: $adding) { opened in
            if let page {
                VPNClientAddSheet(page: page, editor: opened.editor, prepare: prepareSave, pending: { request, editor, built in savePending(request, editor, page: built) },
                                  isCurrent: { basis in self.page?.stillMatches(basis) == true }, run: run, onClose: { adding = nil })
                .frame(minWidth: 560, minHeight: 560)
            }
        }
        .sheet(isPresented: $showsHelp) { VPNClientHelpSheet(fusion: page?.fusion ?? false, faq: page?.troubleshooting) }
        .confirmationDialog(confirming?.title ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { pending in
            Button(pending.button, role: pending.afterwards.isDeletion ? .destructive : nil) { if let refused = run(pending) { alert = refused } }
        } message: { pending in Text(pending.message) }
        .alert("注意", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) { Button("确认") {} } message: { Text(alert ?? "") }
    }

    // MARK: Layout

    @ViewBuilder private func content(_ page: VPNClientPage) -> some View {
        HStack(spacing: 8) {
            Text(page.title).font(.title3.weight(.semibold))
            Button { showsHelp = true } label: { Image(systemName: "questionmark.circle") }.buttonStyle(.borderless).help("关于功能")
        }
        if let stop = page.stop { NoticeBanner(message: Self.text(of: stop), tone: .attention) }
        if reading.error != nil {
            NoticeBanner(message: "最近一次读取没有完成，页面显示的是之前读到的配置；为免用旧的配置列表覆盖路由器，重新读取成功之前不提供写入。", tone: .attention)
        }
        HStack(alignment: .top, spacing: 16) {
            serverList(page).frame(width: 330)
            detail(page).frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    static func text(of stop: VPNClientStop) -> String {
        switch stop {
        case .profiles: "网页读取配置列表时出错（vpnc_clientlist 或 PPTP 选项无法解码，或 VPN Fusion 的默认连接信息不是文本），列表没有绘制，也不读取状态。网页的“＋”此时仍会打开新增，保存时以清空后的列表为基础，会覆盖路由器上原有的配置；本应用对这种数据只显示说明，不提供新增或其他写入。"
        case .policies: "网页读取 VPN Fusion 的设备规则时出错（dhcp_staticlist 或 vpnc_dev_policy_list 无法解码，或 VPN WiFi 规则的 IP 没有 DHCP 绑定），列表没有绘制，也不读取状态。本应用对这种数据只显示说明，不提供写入。"
        case .drawing(let idx): "第 \(idx + 1) 个配置文件没有协议，网页绘制列表时在它这里出错：之前的配置文件已显示，不读取状态，也不显示“开始使用”。网页再写入会把这一条写成 undefined；本应用对这种数据只显示说明，不提供写入。"
        case .status: "网页读取连接状态时出错（get_vpnc_status 无法解码），不显示状态，也不每 5 秒检查。"
        }
    }

    /// show_vpnc_clientlist draws the list unless initial() stopped before it.
    private func listDrawn(_ page: VPNClientPage) -> Bool {
        switch page.stop {
        case .profiles?, .policies?: false
        default: true
        }
    }

    private func serverList(_ page: VPNClientPage) -> some View {
        var drawn = page.profiles
        if case .drawing(let idx)? = page.stop { drawn = drawn.filter { $0.idx < idx } }
        return Panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("server list").font(.headline)
                    Spacer()
                    if listDrawn(page) { Text("\(page.profiles.count)/\(page.maximum)").font(.callout).foregroundStyle(.secondary).monospacedDigit() }
                    Button { add(page) } label: { Image(systemName: "plus.circle.fill") }.buttonStyle(.borderless).help("添加设置文件").disabled(!canWrite(page))
                }
                if listDrawn(page) {
                    if page.profiles.isEmpty {
                        Button { add(page) } label: {
                            HStack { Text("添加设置文件"); Spacer(); Image(systemName: "plus") }.padding(10).frame(maxWidth: .infinity)
                                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain).disabled(!canWrite(page))
                    }
                    ForEach(drawn) { profile in row(page, profile) }
                    if let internet = page.internet {
                        Divider()
                        internetRow(page, internet)
                    }
                }
            }
        }
    }

    private func tags(_ names: [String]) -> some View {
        HStack(spacing: 4) {
            ForEach(names, id: \.self) { Text($0).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2).background(Color.teal.opacity(0.15), in: Capsule()) }
        }
    }

    private func row(_ page: VPNClientPage, _ profile: VPNClientProfile) -> some View {
        let status = page.statuses[profile.idx] ?? .off
        let selected = form?.target == .profile(profile.idx)
        return VStack(alignment: .leading, spacing: 5) {
            if !page.tags(profile).isEmpty { tags(page.tags(profile)) }
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.desc ?? "").font(.callout.weight(.medium)).lineLimit(1)
                    HStack(spacing: 8) {
                        Text(profile.proto ?? "")
                        Text(status.text).foregroundStyle(status.text == "已联机" ? Color.green : Color.secondary)
                    }.font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { open(.profile(profile.idx), page) }
                .help(profile.nameTitle)
                Toggle("连接", isOn: Binding(get: { status.on }, set: { switchProfile(profile.idx, on: $0) })).labelsHidden().toggleStyle(.switch)
                    .disabled(!canWrite(page))
            }
            if let error = status.error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(10)
        .background(selected ? Color.teal.opacity(0.12) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
    }

    private func internetRow(_ page: VPNClientPage, _ item: VPNClientInternetItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if item.isDefault { tags(["默认连接"]) }
            Text("互联网连接").font(.callout.weight(.medium))
            Text(item.wan.statusText).font(.caption).foregroundStyle(item.wan.status == "connected" ? Color.green : Color.secondary)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(form?.target == .internet ? Color.teal.opacity(0.12) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
        .onTapGesture { open(.internet, page) }
    }

    @ViewBuilder private func detail(_ page: VPNClientPage) -> some View {
        if let binding = Binding($form) {
            VPNClientFormView(page: page, editor: binding, hint: $formHint, allowsWrites: canWrite(page), onApply: { apply(page) }, onDelete: { delete(page) },
                              onDefault: { on in switchDefault(on, page) }, onInternetApply: { applyInternet(page) })
        } else if page.stop == nil || page.stop == .status {
            // show_get_start (2533–2536, Get_Component_Get_Start 1003–1029).
            Panel {
                VStack(alignment: .leading, spacing: 10) {
                    Text("开始使用：").font(.title3.weight(.semibold))
                    Text("因为您的在线安全最重要。").foregroundStyle(.secondary)
                    Button("添加设置文件") { add(page) }.buttonStyle(.borderedProminent).tint(.teal).disabled(!canWrite(page))
                    Divider()
                    HStack {
                        Text("如何设置").font(.headline)
                        Button { showsHelp = true } label: { Image(systemName: "questionmark.circle") }.buttonStyle(.borderless)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Reading

    /// A read that leaves the open form (after a write) keeps its inputs, as the page keeps the form it drew.
    private func load(keepingForm: Bool) async {
        poller?.cancel(); poller = nil
        session += 1
        let mine = session
        let before = reading.readAt
        await reading.load(store: store) { try await $0.vpnClientPage() }
        guard session == mine, !Task.isCancelled else { return }
        guard reading.readAt != before, let value = reading.value else {
            // A read that failed keeps the page as it was, and its check goes on.
            if shown, let page, page.stop == nil { startPolling() }
            return
        }
        page = value
        if keepingForm, let open = form {
            switch open.target {
            case .profile(let idx): form = value.profiles.contains { $0.idx == idx } ? value.refreshed(open) : nil
            case .internet: form = value.fusion ? value.refreshed(open) : nil
            case .new: form = nil
            }
        } else {
            form = nil; formHint = nil; refreshingClient = false
        }
        if shown, value.stop == nil { startPolling() }
    }

    /// check_profile_status every 5 seconds (4299–4301). A check that comes back after the page changed is dropped.
    private func startPolling() {
        poller?.cancel()
        poller = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, connected, store.operationTitle == nil, !reading.loading, let current = page,
                      let client = try? store.connectedClient() else { continue }
                guard let fresh = try? await client.vpnClientPoll(current, refreshingClient: refreshingClient), !Task.isCancelled, page == current else { continue }
                page = fresh
            }
        }
    }

    /// Opening a form reads what the page reads again there (Fusion: the rules, the new index, the WAN state). An answer that
    /// comes after the page was left, read again or changed its configuration is dropped; the page itself keeps its state.
    private func open(_ target: VPNClientEditor.Target, _ page: VPNClientPage) {
        guard !opening, !preparing else { return }
        opening = true
        let mine = session
        Task { @MainActor in
            defer { opening = false }
            do {
                let read = try await store.connectedClient().vpnClientFormPage(page, new: target == .new, internet: target == .internet)
                guard shown, !Task.isCancelled, session == mine, self.page?.stillMatches(page.basis) == true else { return }
                var updated = read.page
                let editor: VPNClientEditor
                switch target {
                case .internet: editor = updated.internetEditor()
                case .new: editor = updated.editor(for: nil, newIndex: read.newIndex)
                case .profile(let idx): editor = updated.editor(for: idx)
                }
                formHint = nil
                if target == .new { adding = AddSession(editor: editor) } else { form = editor }
            } catch {
                notice = ("读取设置没有完成：\(error.localizedDescription)", .error)
                store.handleManagementError(error)
            }
        }
    }

    /// The ＋ (4192–4202): refused at the maximum; a new profile replaces the form beside the list with 开始使用 (263).
    private func add(_ page: VPNClientPage) {
        if let refused = refusal(page) { alert = refused; return }
        if page.profiles.count >= page.maximum { alert = page.listLimitNote; return }
        form = nil; formHint = nil
        open(.new, page)
    }

    // MARK: Writing

    /// Writes need a list read without error (VPNClientPage.writable) and a latest read that succeeded.
    private func canWrite(_ page: VPNClientPage) -> Bool { page.writable && reading.error == nil }
    private func refusal(_ page: VPNClientPage) -> String? {
        if !page.writable { return VPNClientAlert.listUnavailable.message }
        if reading.error != nil { return "最近一次读取没有完成，重新读取成功之前不提供写入。" }
        return nil
    }

    /// A switch (390–622). The web reads the NAT check synchronously within the click (464–491; httpApi.js 74 `async: false`)
    /// and sends the list it then serializes (505–510), so nothing changes in between. Here the check is read asynchronously:
    /// nothing else starts meanwhile (preparing), an answer that comes after the page was left or read again is dropped, and
    /// the request is built from the page as it then is, refused when its basis is no longer the one the check started on.
    private func switchProfile(_ idx: Int, on: Bool) {
        guard !preparing, !opening else { return }
        let now = Date()
        if let lastSwitch, now.timeIntervalSince(lastSwitch) < 4 { alert = VPNClientAlert.busy.message; return }
        lastSwitch = now
        guard let current = page else { return }
        if let refused = refusal(current) { alert = refused; return }
        if case .failure(let refused) = current.switching(idx, on: on) { alert = refused.message; return }
        let basis = current.basis, mine = session
        preparing = true
        Task { @MainActor in
            defer { preparing = false }
            do {
                let nat = on ? try await store.connectedClient().vpnClientNAT(current).nat : VPNClientNAT.none
                guard shown, !Task.isCancelled, session == mine, let latest = page else { return }
                let request: VPNClientRequest
                switch latest.switching(idx, on: on, nat: nat, preparedOn: basis) {
                case .success(let built): request = built
                case .failure(let refused): alert = refused.message; return
                }
                let name = latest.profiles.first { $0.idx == idx }?.desc ?? ""
                var message: String
                if latest.fusion {
                    message = on ? "路由器会把这个配置文件标为启用（vpnc_clientlist 的启用栏为 1，vpnc_unit=\(idx)）并启动它（restart_vpnc）。"
                                 : "路由器会把这个配置文件标为停用（启用栏为 0，vpnc_unit=\(idx)）并停止它（stop_vpnc）。"
                } else {
                    message = on ? "路由器的 VPN 客户端会改用这个配置文件（vpnc_proto=\(request.value("vpnc_proto") ?? "")），并重启 VPN 客户端（restart_vpncall）；其他配置文件随之断开。"
                                 : "路由器会停用 VPN 客户端（vpnc_proto=disable）并清空正在使用的连接设置，重启 VPN 客户端（restart_vpncall）。"
                }
                if nat.reboot {
                    message += "\n\n" + VPNClientNAT.confirmation + " 确认后写入 ctf_nonat_force=1 并重新启动路由器" + (latest.rebootTime > 0 ? "（约 \(latest.rebootTime) 秒）" : "") + "，期间所有设备断网。"
                } else if nat.forceOff {
                    message += " 同时写入 ctf_nonat_force=1（关闭 NAT 加速）。"
                }
                confirming = Pending(title: (on ? "启用" : "停用") + "“\(name)”？", message: message + "\n\n" + Self.describe(request), button: on ? "启用" : "停用",
                                     requests: [request], operation: on ? "正在启用 VPN 配置文件" : "正在停用 VPN 配置文件", basis: latest.basis,
                                     afterwards: .switched(running: !latest.fusion))
            } catch {
                notice = ("读取没有完成：\(error.localizedDescription)", .error)
                store.handleManagementError(error)
            }
        }
    }

    /// apply_data's checks (2834–2890) on the page's inputs: the Fusion refusal for an active profile (before validate_format,
    /// so the hints stay), validate_format (which removes the hints, then rewrites the server field) and the duplicate check.
    private func prepareSave(_ editor: VPNClientEditor, _ hint: VPNClientForm.Invalid?) -> VPNClientSaveCheck {
        guard let current = page else { return VPNClientSaveCheck(editor: editor, hint: hint, alert: nil, ready: nil) }
        if let refused = refusal(current) { return VPNClientSaveCheck(editor: editor, hint: hint, alert: refused, ready: nil) }
        var editor = editor
        switch current.saving(editor) {
        case .failure(.alert(let refused)) where refused == .deactivateToEdit:
            return VPNClientSaveCheck(editor: editor, hint: hint, alert: refused.message, ready: nil)
        case .failure(.alert(let refused)):
            editor.form = editor.form.validated().form
            return VPNClientSaveCheck(editor: editor, hint: nil, alert: refused.message, ready: nil)
        case .failure(.invalid(let invalid)):
            editor.form = editor.form.validated().form
            return VPNClientSaveCheck(editor: editor, hint: invalid, alert: nil, ready: nil)
        case .success(let request):
            editor.form = editor.form.validated().form
            return VPNClientSaveCheck(editor: editor, hint: nil, alert: nil, ready: request, page: current)
        }
    }

    /// 应用 of the form beside the list.
    private func apply(_ page: VPNClientPage) {
        guard let open = form else { return }
        if let refused = refusal(page) { alert = refused; return }
        let checked = prepareSave(open, formHint)
        form = checked.editor; formHint = checked.hint; alert = checked.alert
        if let request = checked.ready, let built = checked.page { confirming = savePending(request, checked.editor, page: built) }
    }

    /// The confirmation for 应用 (a new profile reads get_new_vpnc_index again and the 7114 check before it, in the sheet).
    private func savePending(_ request: VPNClientRequest, _ editor: VPNClientEditor, page: VPNClientPage) -> Pending {
        let new = editor.target == .new
        var message = new ? "路由器会在配置列表末尾加入这个配置文件" : "路由器会保存这个配置文件的设置"
        message += "（vpnc_clientlist 与 vpnc_pptp_options_x_list）"
        if request.value("vpnc_proto") != nil { message += "；它正在使用，VPN 客户端会改用新设置并重启（restart_vpncall）" }
        if request.value("vpnc_unit") != nil { message += "；并立即启用它（restart_vpnc）" }
        if request.value("vpnc_default_wan_tmp") != nil { message += "，同时设为默认连接（restart_default_wan）" }
        if request.value("dhcp_staticlist") != nil { message += "；手动指定 IP 的 DHCP 列表有变化，路由器会重启网络（restart_net_and_phy，约 30 秒，期间所有设备断网）" }
        if request.value("vpnc_dev_policy_list") != nil { message += "；设备规则也一并保存" }
        message += "。"
        if request.reboots { message += " 使用 PPPoE 且开启 NAT 加速，路由器会关闭 NAT 加速（ctf_nonat_force=1）并重新启动，期间所有设备断网；网页在这里不再另行询问。" }
        let encoded = page.encodedInputs(editor)
        if !encoded.isEmpty {
            message += "\n\n注意：" + encoded.joined(separator: "、") + " 仍是网页打开设置时写入输入框的 HTML 实体文字（例如 & 显示为 &amp;），会按显示的文字保存。"
        }
        let name = editor.form.desc
        return Pending(title: (new ? "添加" : "保存") + "“\(name)”？", message: message + "\n\n" + Self.describe(request), button: editor.applyTitle,
                       requests: [request], operation: new ? "正在添加 VPN 配置文件" : "正在保存 VPN 配置文件", basis: page.basis,
                       afterwards: new ? .added : .saved)
    }

    private func delete(_ page: VPNClientPage) {
        guard let open = form, case .profile(let idx) = open.target else { return }
        if let refused = refusal(page) { alert = refused; return }
        switch page.deleting(idx, policies: open.policies) {
        case .failure(let refused): alert = refused.message
        case .success(let requests):
            var message = "确定要删除此设置档？"
            if requests.count > 1 { message += " 它是默认连接：网页会先单独把默认连接改回互联网（vpnc_default_wan_tmp=0，restart_default_wan），再保存删除后的列表。" }
            if requests.last?.value("vpnc_proto") == "disable" { message += " 它正在使用，VPN 客户端会停用（vpnc_proto=disable，restart_vpncall）。" }
            if page.fusion { message += " 它的设备规则一并删除（restart_vpnc_dev_policy）。" }
            confirming = Pending(title: "删除配置文件", message: message + "\n\n" + requests.map(Self.describe).joined(separator: "\n"), button: "删除",
                                 requests: requests, operation: "正在删除 VPN 配置文件", basis: page.basis, afterwards: .deleted)
        }
    }

    /// 适用于所有设备 (1526–1574, 2617–2624).
    private func switchDefault(_ on: Bool, _ page: VPNClientPage) {
        guard let open = form else { return }
        if open.defaultSwitch == .unsupported { alert = VPNClientAlert.noDefault.message; return }
        if let refused = refusal(page) { alert = refused; return }
        switch page.defaultConnection(index: open.index, on: on) {
        case .failure(let refused): alert = refused.message
        case .success(let request):
            let message = on ? "路由器会把默认连接改为" + (open.target == .internet ? "互联网" : "这个配置文件") + "（vpnc_default_wan_tmp=\(request.value("vpnc_default_wan_tmp") ?? "undefined")），并重启默认 WAN（restart_default_wan），所有未单独分配的设备都经它上网。"
                : "路由器会把默认连接改回互联网（vpnc_default_wan_tmp=0），并重启默认 WAN（restart_default_wan）。"
            confirming = Pending(title: on ? "设为适用于所有设备？" : "取消适用于所有设备？", message: message + "\n\n" + Self.describe(request), button: "确定",
                                 requests: [request], operation: "正在更改默认连接", basis: page.basis, afterwards: .defaultSwitched)
        }
    }

    /// 互联网's 应用目前所有设置 (930–979).
    private func applyInternet(_ page: VPNClientPage) {
        guard let open = form, let policies = open.policies else { return }
        if let refused = refusal(page) { alert = refused; return }
        let request: VPNClientRequest
        switch page.internetApplying(policies) {
        case .success(let built): request = built
        case .failure(let refused): alert = refused.message; return
        }
        var message = request.value("rc_service") == nil ? "设备设置没有变化，网页仍会发送一个只有 action_mode 的请求。" : "路由器会保存互联网的设备设置"
        if request.value("dhcp_staticlist") != nil { message += "；手动指定 IP 的 DHCP 列表有变化，路由器会重启网络（restart_net_and_phy，约 30 秒，期间所有设备断网）" }
        if request.value("vpnc_dev_policy_list") != nil { message += "；设备规则变化，重新套用（restart_vpnc_dev_policy）" }
        confirming = Pending(title: "应用目前所有设置？", message: message + "\n\n" + Self.describe(request), button: "应用", requests: [request],
                             operation: "正在保存设备设置", basis: page.basis, afterwards: .internetApplied)
    }

    /// Sends a confirmed write, unless the page no longer has what the confirmation was built from (another write or a read
    /// finished while it was open), the list is not writable, or the latest read failed; returns that refusal.
    @discardableResult
    private func run(_ pending: Pending) -> String? {
        confirming = nil
        guard let current = page else { return VPNClientAlert.stale.message }
        if let refused = refusal(current) { return refused }
        guard current.stillMatches(pending.basis) else { return VPNClientAlert.stale.message }
        guard store.beginOperation(pending.operation) else { return nil }
        // The page closes its popup as it sends (3144–3146).
        if case .added = pending.afterwards { adding = nil }
        let uptime = store.snapshot?.sample.uptime ?? 0
        let rebootTime = page?.rebootTime ?? 0
        Task { @MainActor in
            var readAgain = false
            do {
                let client = try store.connectedClient()
                let receipt = try await client.submitVPNClient(pending.requests)
                notice = (receipt.message, receipt.isVerified ? .success : .attention); readAgain = true
                if pending.requests.last?.reboots == true {
                    readAgain = false
                    switch await store.awaitRestart(client, from: uptime, checks: max(24, (rebootTime + 60) / 5)) {
                    case .back:
                        let checked = try await client.checkVPNClient(pending.requests)
                        notice = ("路由器已重新启动并恢复连接。" + checked.message, checked.isVerified ? .success : .attention); readAgain = true
                    case .signInFailed(let reason): notice = (reason, .attention)
                    case .timedOut, .stayedUp: notice = ("路由器已接收设置并开始重新启动，但还没有确认恢复连接。请稍后重新读取核对。", .attention)
                    }
                }
            } catch {
                notice = ("请求没有完成：\(error.localizedDescription)", .error)
                store.handleManagementError(error)
            }
            store.endOperation()
            switch pending.afterwards {
            case .switched(let running): if running { refreshingClient = true }
            case .added: refreshingClient = false
            case .saved: refreshingClient = false
            case .deleted: form = nil; formHint = nil; refreshingClient = false
            // 适用于所有设备 then shows what is read back (VPNClientPage.refreshed), not the state it was asked for.
            case .defaultSwitched, .internetApplied: break
            }
            // A page left meanwhile is not read again.
            if readAgain, shown { await load(keepingForm: true) }
        }
        return nil
    }

    /// The request's members as JSON.stringify writes them, lists by size and passwords hidden.
    static func describe(_ request: VPNClientRequest) -> String {
        let members = request.members.compactMap { member -> String? in
            guard let value = member.value else { return nil }
            let text: String
            switch value { case .string(let string): text = string; default: text = request.value(member.name) ?? "" }
            switch member.name {
            case "vpnc_clientlist": return member.name + "=（\(text.isEmpty ? 0 : text.components(separatedBy: "<").count) 个配置文件）"
            case "vpnc_dev_policy_list", "vpnc_dev_policy_list_tmp": return member.name + "=（\(text.isEmpty ? 0 : text.components(separatedBy: "<").count) 条规则）"
            case "dhcp_staticlist": return member.name + "=（\(text.components(separatedBy: "<").count - 1) 条绑定）"
            case let name where name.hasSuffix("passwd") || name.hasSuffix("password"): return name + "=（\(text.isEmpty ? "空" : "已隐藏")）"
            default:
                if case .string = value { return member.name + "=" + text }
                return member.name + "=" + text + "（数字）"
            }
        }
        return "发送（与网页相同）：" + members.joined(separator: "，")
    }
}

/// What 应用's checks leave: the form as the page's inputs then hold it, the hint, the alert, and the request when it goes on
/// with the page it was built from.
struct VPNClientSaveCheck {
    let editor: VPNClientEditor
    let hint: VPNClientForm.Invalid?
    let alert: String?
    let ready: VPNClientRequest?
    var page: VPNClientPage? = nil
}

private extension VPNClientPPTPView.Pending.Afterwards {
    var isDeletion: Bool { if case .deleted = self { true } else { false } }
}

/// The settings (Get_Component_Setting_Profile 1030–1263) of one profile, a new one, or the 互联网 card.
struct VPNClientFormView: View {
    let page: VPNClientPage
    @Binding var editor: VPNClientEditor
    @Binding var hint: VPNClientForm.Invalid?
    /// False when the list did not read without error or the latest read failed: 应用, 删除 and 适用于所有设备 then do nothing.
    var allowsWrites = true
    let onApply: () -> Void
    var onDelete: () -> Void = {}
    var onDefault: (Bool) -> Void = { _ in }
    var onInternetApply: (() -> Void)?
    @State private var picking: PickSession?
    @State private var alert: String?
    @State private var showsPassword = false

    struct PickSession: Identifiable { let id = UUID(); let choices: [VPNClientPolicies.Choice] }

    private var profile: VPNClientProfile? {
        if case .profile(let idx) = editor.target { return page.profiles.first { $0.idx == idx } }
        return nil
    }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(editor.title).font(.headline)
                    Spacer()
                    if profile != nil, !editor.stopped {
                        Button(role: .destructive) { onDelete() } label: { Label("删除", systemImage: "trash") }.buttonStyle(.borderless).disabled(!allowsWrites)
                    }
                }
                if editor.stopped {
                    Text("网页填写这个表单时脚本出错停止：设置照样显示，但“应用”与“删除”都没有反应。").font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if editor.target == .internet {
                    internetContent
                } else if let profile, !profile.editable {
                    Text("这个配置文件的协议是 \(profile.proto ?? "undefined")。网页编辑它时显示该协议的字段（OpenVPN 的 .ovpn 导入与密钥等）；本页的新增只有 PPTP 与 L2TP，本应用不编辑其他协议的配置文件。它仍可在列表中开关，也可以在这里删除。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    profileContent
                }
            }
        }
        .sheet(item: $picking) { session in
            VPNClientDevicePicker(choices: session.choices) { checked in
                switch editor.policies?.assigning(checked, to: editor.index) {
                case .success(let updated)?: editor.policies = updated; return nil
                case .failure(let refused)?: return refused.message
                case nil: return nil
                }
            }.frame(minWidth: 420, minHeight: 420)
        }
        .alert("注意", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) { Button("确认") {} } message: { Text(alert ?? "") }
    }

    @ViewBuilder private var profileContent: some View {
        field("连接名称", \.desc, limit: 64, check: .desc)
        Text("VPN 身份验证").font(.subheadline.weight(.semibold)).padding(.top, 4)
        row("虚拟专用网 (VPN) 的类型") {
            Picker("", selection: Binding(get: { editor.form.type ?? "" }, set: { editor.form.type = $0 })) {
                if editor.form.type == nil { Text("").tag("") }
                Text("PPTP").tag("pptp"); Text("L2TP").tag("l2tp")
            }.labelsHidden().frame(width: 200).disabled(editor.typeFixed)
        }
        if editor.form.type == "pptp" {
            row("PPTP 选项") {
                Picker("", selection: Binding(get: { editor.form.pptpOptions ?? "" }, set: { editor.form.pptpOptions = $0 })) {
                    if editor.form.pptpOptions == nil { Text("").tag("") }
                    ForEach(VPNClientForm.pptpOptions, id: \.value) { Text($0.title).tag($0.value) }
                }.labelsHidden().frame(width: 200)
            }
        }
        if ["pptp", "l2tp"].contains(editor.form.type ?? "") {
            field("虚拟专用网 (VPN) 服务器", \.server, limit: 64, check: .server)
            field("用户名", \.username, limit: 64, check: .username)
            field("密码", \.password, limit: 128, check: .password, secure: true)
        }
        if page.fusion {
            if let wireless = editor.wireless {
                row("无线接口") {
                    Picker("", selection: Binding(get: { wireless.option ?? "" }, set: { editor.chooseWireless($0) })) {
                        if wireless.option == nil { Text("").tag("") }
                        ForEach(VPNClientForm.wirelessOptions, id: \.value) { Text($0.title).tag($0.value) }
                    }.labelsHidden().frame(width: 200).disabled(wireless.locked)
                }
                ForEach(wireless.hints, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            }
            if let state = editor.defaultSwitch { defaultSwitch(state) }
            devices
        }
        HStack {
            Spacer()
            // validate_blank (3194–3218): 应用 does nothing while a needed field is blank.
            Button(editor.applyTitle) { onApply() }.buttonStyle(.borderedProminent).tint(.teal).disabled(!editor.form.complete || editor.stopped || !allowsWrites)
        }
    }

    @ViewBuilder private var internetContent: some View {
        ForEach(Array(editor.blocks.enumerated()), id: \.offset) { _, block in
            VStack(alignment: .leading, spacing: 4) {
                HStack { Text(block.title).font(.subheadline.weight(.semibold)); Spacer(); Text(block.statusText).foregroundStyle(block.connected ? Color.green : Color.secondary) }
                HStack { Text(block.ipTitle).foregroundStyle(.secondary); Spacer(); Text(block.ip).monospacedDigit() }.font(.callout)
                HStack { Text("联机类型").foregroundStyle(.secondary); Spacer(); Text(block.proto) }.font(.callout)
            }.padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
        }
        if let state = editor.defaultSwitch { defaultSwitch(state) }
        devices
        HStack {
            Spacer()
            Button("应用目前所有设置") { (onInternetApply ?? onApply)() }.buttonStyle(.borderedProminent).tint(.teal).disabled(editor.stopped || !allowsWrites)
        }
    }

    private func defaultSwitch(_ state: VPNClientEditor.DefaultSwitch) -> some View {
        row("适用于所有设备") {
            Toggle("适用于所有设备", isOn: Binding(get: { state == .on }, set: { onDefault($0) })).labelsHidden().toggleStyle(.switch).disabled(!allowsWrites)
                .opacity(state == .unsupported ? 0.5 : 1)
        }
    }

    /// The profile's devices with their switches, and ＋ for the 设备 list.
    @ViewBuilder private var devices: some View {
        let devices = editor.devices(page)
        HStack {
            Text("设备").font(.subheadline.weight(.semibold))
            Spacer()
            Text("\(devices.count)").foregroundStyle(.secondary).monospacedDigit()
            Button {
                if let refused = editor.canAssign(page) { alert = refused.message } else { picking = PickSession(choices: editor.choices(page)) }
            } label: { Image(systemName: "plus.circle") }.buttonStyle(.borderless).help("设备").disabled(editor.policies == nil)
        }.padding(.top, 4)
        if devices.isEmpty {
            Text("将设备分配到此配置文件").font(.callout).foregroundStyle(.secondary)
        } else {
            ForEach(devices) { device in
                HStack {
                    VStack(alignment: .leading, spacing: 1) { Text(device.name).lineLimit(1); Text(device.ip).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Toggle(device.name, isOn: Binding(get: { device.on }, set: { _ in editor.policies?.toggle(device.rule) })).labelsHidden().toggleStyle(.switch)
                }.font(.callout)
            }
            Text("设备的分配与开关只改本页，点“应用”后才写入路由器。").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func row(_ title: String, @ViewBuilder control: () -> some View) -> some View {
        HStack { Text(title); Spacer(); control() }
    }

    /// A text input with the page's maxlength (a typed character past it is refused, pasted text cut); no key filter.
    private func field(_ title: String, _ key: WritableKeyPath<VPNClientForm, String>, limit: Int, check: VPNClientForm.Field, secure: Bool = false) -> some View {
        let text = Binding(get: { editor.form[keyPath: key] }, set: { new in
            let old = editor.form[keyPath: key]
            editor.form[keyPath: key] = WebValidator.edit(old, new, typed: KeyPressEvent.typedCharacter, maxLength: limit,
                                                          replaced: KeyPressEvent.replacedRange(old, new))
        })
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout)
            HStack {
                if secure && !showsPassword { SecureField("", text: text) } else { TextField("", text: text) }
                if secure {
                    Button { showsPassword.toggle() } label: { Image(systemName: showsPassword ? "eye" : "eye.slash") }.buttonStyle(.borderless)
                }
            }.textFieldStyle(.roundedBorder)
            if let hint, hint.field == check { Text(hint.message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// 添加设置文件 (the page's popup): the form for a new profile. 应用 runs the page's checks, then asks to confirm here.
struct VPNClientAddSheet: View {
    @Environment(RouterStore.self) var store
    let page: VPNClientPage
    @State var editor: VPNClientEditor
    let prepare: (VPNClientEditor, VPNClientForm.Invalid?) -> VPNClientSaveCheck
    let pending: (VPNClientRequest, VPNClientEditor, VPNClientPage) -> VPNClientPPTPView.Pending
    /// Whether the page still has a basis (another write or a read may finish while this sheet reads).
    let isCurrent: (VPNClientBasis) -> Bool
    /// Sends a confirmed write, or returns why not.
    let run: (VPNClientPPTPView.Pending) -> String?
    let onClose: () -> Void
    @State private var hint: VPNClientForm.Invalid?
    @State private var working = false
    @State private var alert: String?
    @State private var confirming: VPNClientPPTPView.Pending?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("添加设置文件").font(.title3.weight(.semibold))
                Spacer()
                Button { onClose() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
            }
            ScrollView {
                VPNClientFormView(page: page, editor: $editor, hint: $hint, onApply: apply)
            }
        }
        .padding(22)
        .disabled(working)
        .confirmationDialog(confirming?.title ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { pending in
            Button(pending.button) { if let refused = run(pending) { alert = refused } }
        } message: { pending in Text(pending.message) }
        .alert("注意", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) { Button("确认") {} } message: { Text(alert ?? "") }
    }

    /// apply_data for a new profile: the checks, then (Fusion) get_new_vpnc_index read again (2911) and, when the profile is
    /// switched on at once, the 7114 check (3023–3046), which the web reads synchronously within the click. The request is
    /// built only when the page still has the basis the checks ran on once those reads answer.
    private func apply() {
        let checked = prepare(editor, hint)
        editor = checked.editor; hint = checked.hint; alert = checked.alert
        guard let first = checked.ready, let started = checked.page else { return }
        guard started.fusion else { confirming = pending(first, editor, started); return }
        working = true
        Task { @MainActor in
            defer { working = false }
            do {
                let client = try store.connectedClient()
                let index = try await client.vpnClientNewIndex()
                let nat = editor.autoEnable ? try await client.vpnClientNAT(started).nat : VPNClientNAT.none
                guard isCurrent(started.basis) else { alert = VPNClientAlert.stale.message; return }
                switch started.saving(editor, newIndex: index, nat: nat) {
                case .success(let request): confirming = pending(request, editor, started)
                case .failure(.alert(let refused)): alert = refused.message
                case .failure(.invalid(let invalid)): hint = invalid
                }
            } catch {
                alert = "读取没有完成：\(error.localizedDescription)"
            }
        }
    }
}

/// The 设备 list (Get_Component_Setting_Client_Policy 1393–1525): online devices by IP; another profile's are disabled.
struct VPNClientDevicePicker: View {
    let choices: [VPNClientPolicies.Choice]
    /// 确认: the alert to show, or nil when the list was taken.
    let onConfirm: ([VPNClientPolicies.Choice]) -> String?
    @State private var checked: Set<Int> = []
    @State private var alert: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("设备").font(.title3.weight(.semibold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(choices) { choice in
                        Toggle(isOn: Binding(get: { checked.contains(choice.id) }, set: { if $0 { checked.insert(choice.id) } else { checked.remove(choice.id) } })) {
                            VStack(alignment: .leading, spacing: 1) { Text(choice.name).lineLimit(1); Text(choice.ip).font(.caption).foregroundStyle(.secondary) }
                        }.disabled(choice.taken)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text("“确认”只改本页的设备列表；点“应用”后才写入路由器。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("确认") {
                    if let message = onConfirm(choices.filter { checked.contains($0.id) }) { alert = message } else { dismiss() }
                }.buttonStyle(.borderedProminent).tint(.teal)
            }
        }
        .padding(22)
        .onAppear { checked = Set(choices.filter(\.checked).map(\.id)) }
        .alert("注意", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) { Button("确认") {} } message: { Text(alert ?? "") }
    }
}

/// 关于功能 (Get_Component_Feature_Desc 749–793).
struct VPNClientHelpSheet: View {
    let fusion: Bool
    let faq: URL?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("关于功能").font(.title3.weight(.semibold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
            }
            Text("功能描述").font(.headline)
            Text("虚拟专用网 Virtual Private Network (VPN) 客户端通常用来连接到 VPN 服务器，以安全地通过公共网络访问私人资源。\n\n有些设备，如机顶盒、智能电视机与蓝光播放器等，不支持 VPN 软件。\n\nASUSWRT 虚拟专用网 (VPN) 功能为家庭网络内的所有设备提供 VPN 访问，而无需在每台设备上安装 VPN 软件。")
                .fixedSize(horizontal: false, vertical: true)
            Text("如何设置").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text("1. 添加设置文件"); Text("2. 选择虚拟专用网 (VPN) 连接类型"); Text("3. 输入由虚拟专用网 (VPN) 提供商提供的 VPN 验证信息，然后连接。")
            }
            if fusion, let faq { Link("VPN Fusion 疑难解答", destination: faq) }
            Spacer()
        }
        .padding(22).frame(minWidth: 480, minHeight: 380)
    }
}
