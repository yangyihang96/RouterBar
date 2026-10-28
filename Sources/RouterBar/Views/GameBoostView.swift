import RouterCore
import SwiftUI

// 1.13：Game › 游戏加速（GameBoost.asp，Adaptive QoS 的路由器）。“游戏设备优先”开关与游戏设备清单的“应用本页面设置”先请用户
// 确认，再发送网页的同一张表单（start_apply.htm）；硬件加速设置要求重启时（ctf_fa_mode 为 2）确认文字写明会重新启动，重启后
// 等路由器恢复再读取核对。开关在 QoS 关闭且未同意 Trend Micro 条款时与网页一样先显示条款：同意后保存开关并记录同意
// （TM_EULA=1），拒绝时与网页一样记录不同意（TM_EULA=0，路由器随之关闭依赖它的功能），都先确认。

struct GameBoostView: View {
    @Environment(RouterStore.self) var store
    @StateObject private var reading = RouterReading<GameBoostPage>()
    /// gameList as the page holds it, edited in the device list.
    @State private var list = ""
    @State private var showList = false
    @State private var confirming: Pending?
    @State private var terms: PolicyWindow?
    @State private var notice: (message: String, tone: NoticeBanner.Tone)?
    private var connected: Bool { store.phase == .connected }

    /// What was confirmed, with the list as it was then.
    enum Pending: Equatable { case priority(Bool, agreeingTerms: Bool, list: String), list(String), declineTerms }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusPageHeader(title: "Game", subtitle: "游戏加速", symbol: "gamecontroller.fill",
                                 readAt: reading.readAt, loading: reading.loading) { await load() }
                ReadErrorLabel(message: reading.error)
                if let notice { NoticeBanner(message: notice.message, tone: notice.tone) }
                if !connected {
                    ConnectionRequiredView()
                } else if let page = reading.value {
                    if !page.adaptive {
                        NoticeBanner(message: "这台路由器没有 Adaptive QoS：网页改用 ROG 优先（rog_first_qos.cgi）与带宽设置的流程，本应用没有实现这个分支，请在路由器网页中操作。", tone: .attention)
                    } else if page.gameMode {
                        cards(page)
                    } else {
                        Text("这台路由器没有游戏模式（gameMode），网页的这三项都不显示。").font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    ReadingPlaceholder(failed: reading.error != nil && !reading.loading, minHeight: 220)
                }
            }.padding(28).disabled(store.operationTitle != nil || reading.loading)
        }
        .task(id: connected) { if connected, reading.value == nil { await load() } }
        .sheet(isPresented: $showList) {
            if let page = reading.value {
                GameDeviceListSheet(page: page, list: $list) { afterSheetCloses { confirming = .list(list) } }.frame(minWidth: 560, minHeight: 480)
            }
        }
        .sheet(item: $terms) { window in
            PolicyDocumentSheet(window: window, language: reading.value?.values["preferred_lang"] ?? "",
                                onAgree: { afterSheetCloses { confirming = .priority(!(reading.value?.priorityOn ?? false), agreeingTerms: true, list: list) } },
                                onDisagree: { afterSheetCloses { confirming = .declineTerms } })
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
            if let pending = confirming { Button(pending == .declineTerms ? "拒绝" : "确定", role: pending == .declineTerms ? .destructive : nil) { run(pending) } }
        } message: { Text(confirmMessage) }
    }

    /// A read replaces the list only when it brought new values.
    private func load() async {
        let before = reading.readAt
        await reading.load(store: store) { try await $0.gameBoostPage() }
        if reading.readAt != before, let page = reading.value { list = page.gameList }
    }

    private func cards(_ page: GameBoostPage) -> some View {
        VStack(spacing: 12) {
            card(title: "设备加速器", symbol: "speedometer", heading: "游戏设备优先", detail: "优先考虑游戏设备以获得最佳游戏体验。") {
                Button("新增") { showList = true }
                Toggle("游戏设备优先", isOn: Binding(get: { page.priorityOn }, set: { on in
                    if page.asksTrendMicro, let document = PolicyTexts.trendMicro {
                        terms = PolicyWindow(kind: .trendMicro, document: document, buttons: .decide)
                    } else {
                        confirming = .priority(on, agreeingTerms: false, list: list)
                    }
                })).labelsHidden().toggleStyle(.switch)
            }
            card(title: "Mobile Game Mode", symbol: "iphone.gen3", heading: "手机游戏加速", detail: "下载并安装 ASUS Router 应用。在应用中启用手机游戏模式，以确保最佳的手机游戏体验。") {
                Link("Android", destination: page.androidApp)
                Link("iOS", destination: GameBoostPage.iosApp)
            }
            card(title: "Open NAT", symbol: "network", heading: "3 级端口转发设置",
                 detail: "Open NAT 提供了一种方便简捷的方法来创建在线游戏的端口转发规则，并可优化从游戏控制台到调制解调器的路由数据包，从而优化游戏体验。") {
                Button("前往设置") { store.open(NativeFeature.openNAT) }
            }
        }
    }

    private func card(title: String, symbol: String, heading: String, detail: String, @ViewBuilder actions: () -> some View) -> some View {
        Panel {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 6) {
                    Image(systemName: symbol).font(.title2).foregroundStyle(.teal)
                    Text(title).font(.callout.weight(.semibold)).multilineTextAlignment(.center)
                }.frame(width: 120)
                VStack(alignment: .leading, spacing: 6) {
                    Text(heading).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                HStack(spacing: 10) { actions() }
            }
        }
    }

    private var confirmTitle: String {
        switch confirming {
        case .priority(let on, _, _)?: on ? "开启游戏设备优先？" : "关闭游戏设备优先？"
        case .list?: "保存游戏设备清单？"
        case .declineTerms?: "拒绝 Trend Micro 的条款？"
        case nil: ""
        }
    }
    private var confirmMessage: String {
        guard let page = reading.value, let pending = confirming else { return "" }
        // handleClickDisagree (asus_policy.js 1312–1318) and set_TM_EULA.cgi (web.c 21482–21523).
        if pending == .declineTerms {
            return "网页在这里会记录不同意 Trend Micro 的条款（TM_EULA=0，并记下时间）；路由器随之关闭 AiProtection、网页与 Apps 过滤、应用程序分析、网页浏览历史与流量分析的数据库，Adaptive QoS 保持关闭（qos_enable=0），并重启 wrs、QoS 与防火墙。游戏设备优先不会开启。"
        }
        guard let submission = submission(pending, page) else { return "" }
        let action = submission.reboots ? "路由器会重新启动（约 \(submission.wait) 秒，期间所有设备断网），恢复后再读取核对" : "路由器会重启 QoS 与防火墙（约 5 秒）"
        switch pending {
        case .priority(let on, let agreeing, _):
            return (on ? "Adaptive QoS 会开启并设为自适应（qos_enable=1、qos_type=1），" : "Adaptive QoS 会关闭（qos_enable=0），") + "游戏设备清单一起保存；" + action + "。"
                + (agreeing ? "表单发出后接着记录已同意 Trend Micro 的条款（TM_EULA=1），与网页相同。" : "")
        case .list(let list):
            return "游戏设备清单（bwdpi_game_list）会保存为 \(page.devices(list).count) 项；" + action + "。"
        case .declineTerms:
            return ""
        }
    }
    private func submission(_ pending: Pending, _ page: GameBoostPage) -> GameBoostPage.Submission? {
        switch pending {
        case .priority(let on, _, let list): page.priority(on: on, list: list)
        case .list(let list): page.saving(list)
        case .declineTerms: nil
        }
    }

    private func run(_ pending: Pending) {
        confirming = nil
        guard let page = reading.value, store.beginOperation(pending == .declineTerms ? "正在记录不同意 Trend Micro 条款" : "正在保存游戏加速设置") else { return }
        let sending = submission(pending, page)
        var agreeing = false
        if case .priority(_, agreeingTerms: true, _) = pending { agreeing = true }
        Task { @MainActor in
            var readAgain = false
            do {
                let client = try store.connectedClient()
                // The uptime before the write tells the restart afterwards; without one it is read first.
                var uptime = store.snapshot?.sample.uptime ?? 0
                if uptime == 0, sending?.reboots == true, let read = try? await client.sample().uptime { uptime = read }
                if let sending {
                    let receipt = try await client.submitGameBoost(sending, agreeingTrendMicro: agreeing)
                    notice = (receipt.message, receipt.isVerified ? .success : .attention); readAgain = !sending.reboots
                    if sending.reboots {
                        // FormActions(…, "reboot", default_reboot_time): once the router is back, the values are read again.
                        let checks = max(24, ((Int(page.rebootTime) ?? 0) + 60) / 5)
                        switch await store.awaitRestart(client, from: uptime, checks: checks) {
                        case .back:
                            let checked = try await client.checkGameBoost(sending, agreeingTrendMicro: agreeing)
                            notice = ("路由器已重新启动并恢复连接。" + checked.message, checked.isVerified ? .success : .attention); readAgain = true
                        case .signInFailed(let reason): notice = (reason, .attention)
                        case .timedOut, .stayedUp: notice = ("路由器已接收设置并开始重新启动，但还没有确认恢复连接。请稍后重新读取核对。", .attention)
                        }
                    }
                } else {
                    // set_TM_EULA.cgi writes TM_EULA and TM_EULA_time (web.c 21493–21498): both read back.
                    let status = try await client.applyPrivacyPolicy(.withdrawTrendMicro)
                    if status.values["TM_EULA"] == "0", !(status.values["TM_EULA_time"] ?? "").isEmpty {
                        notice = ("已从路由器重新读取：已记录不同意 Trend Micro 的条款。", .success)
                    } else {
                        notice = ("路由器已响应，但读回的条款状态不是“不同意”（TM_EULA=\(status.values["TM_EULA"] ?? "")）。请重新读取并检查。", .attention)
                    }
                    readAgain = true
                }
            } catch RouterError.submissionUncertain(let reason) {
                notice = (reason, .attention); readAgain = true
            } catch {
                notice = ("保存没有完成：\(error.localizedDescription)", .error)
                store.handleManagementError(error)
            }
            store.endOperation()
            if readAgain { await load() }
        }
    }
}

/// The game device list (gameList_block 727–742): the MAC field with the client list, the rows and 应用本页面设置.
struct GameDeviceListSheet: View {
    let page: GameBoostPage
    @Binding var list: String
    let onApply: () -> Void
    @State private var mac = ""
    @State private var alert: String?
    @State private var showsOffline = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("应用本页面设置") { dismiss(); onApply() }.buttonStyle(.borderedProminent).tint(.teal)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
            }
            Text("遊戲裝置清單 (最多限制： 64)").font(.headline)
            HStack {
                Text("客户名称 (MAC 地址)"); Spacer(); Text("添加 / 移除")
            }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                // validator.isHWAddr on key press (maxlength 17, GameBoost.asp 345); pasted text is not filtered.
                TextField("ex: \(page.values["lan_hwaddr"] ?? "")", text: Binding(get: { mac }, set: {
                    mac = WebValidator.edit(mac, $0, typed: KeyPressEvent.typedCharacter, maxLength: 17,
                                           replaced: KeyPressEvent.replacedRange(mac, $0), keyPress: WebValidator.hardwareAddressKeyPress)
                }))
                    .textFieldStyle(.roundedBorder).frame(width: 220).font(.body.monospaced())
                clientMenu
                Spacer()
                Button { add() } label: { Image(systemName: "plus.circle.fill") }.buttonStyle(.borderless)
            }
            Divider()
            let devices = page.devices(list)
            if devices.isEmpty {
                Text("目前没有数据").foregroundStyle(.orange)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(devices) { device in
                            HStack {
                                // genGameList writes the name twice and then the IP (410–413).
                                VStack(alignment: .leading, spacing: 1) { Text(device.name); Text(device.name); Text(device.ip).foregroundStyle(.secondary) }
                                Spacer()
                                Button { list = GameBoostPage.removing(device.mac, from: list); mac = "" } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                            }.font(.callout)
                        }
                    }
                }
            }
            Text("添加、移除只改本页的清单；点“应用本页面设置”并确认后才写入路由器。").font(.caption).foregroundStyle(.secondary)
        }
        .padding(22)
        .alert("注意", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) { Button("好") {} } message: { Text(alert ?? "") }
    }

    /// showDropdownClientList('setClientIP', 'mac', 'all', …) (295): the online clients, then under 显示离线设备 the offline ones
    /// of the network map database; AiMesh nodes are left out. A choice fills in its MAC.
    private var clientMenu: some View {
        let clients = TORSettings.dropdownClients(page.clients)
        return Menu {
            ForEach(clients.online, id: \.mac) { client in
                Button(HTMLText.visible(TORSettings.dropdownName(client), inside: ["strong"])) { mac = client.mac }
            }
            if !clients.offline.isEmpty {
                Toggle("显示离线设备", isOn: $showsOffline)
                if showsOffline {
                    ForEach(clients.offline, id: \.mac) { client in
                        Button(HTMLText.visible(TORSettings.dropdownName(client), inside: ["strong"]) + "（离线）") { mac = client.mac }
                    }
                }
            }
        } label: { Image(systemName: "chevron.up.chevron.down") }.menuStyle(.borderlessButton).fixedSize().help("选择 DHCP 客户端的 MAC 地址。")
    }

    private func add() {
        switch GameBoostPage.adding(mac, to: list) {
        // genGameList draws the table again, the MAC field with it.
        case .success(let updated): list = updated; mac = ""
        case .failure(let failure): alert = failure.message
        }
    }
}
