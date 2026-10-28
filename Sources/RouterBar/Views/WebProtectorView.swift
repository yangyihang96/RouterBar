import RouterCore
import SwiftUI

// 1.14：家长管理 › 网页与 Apps 过滤（AiProtection_WebProtector.asp）。勾选、展开、新增、删除与网页一样只改本页；总开关与“应用本页面设置”
// 按网页脚本依次提出网页自己的确认（原文）和 Trend Micro 条款，最后由本应用写明影响（重启 wrs 与防火墙，或整机重启断网）再发送网页的
// 同一张表单（start_apply.htm）与条款请求（set_TM_EULA.cgi），之后重新读取核对。点击客户端图标编辑名称与图标的卡片不提供。

struct WebProtectorView: View {
    @Environment(RouterStore.self) var store
    @StateObject private var reading = RouterReading<WebProtectorPage>()
    /// The page as it runs, until it is read again.
    @State private var form: WebProtectorForm?
    /// A run of the page's script toward a submit: the form it started from and the answers given so far.
    @State private var run: Run?
    @State private var question: Question?
    @State private var terms: PolicyWindow?
    /// The terms window's button, taken once the window has closed.
    @State private var termsChoice: Bool?
    @State private var alert: String?
    @State private var sending: Sending?
    @State private var notice: (message: String, tone: NoticeBanner.Tone)?
    /// The form went to the router and the router restarts: the page waits for 重新读取.
    @State private var sent = false
    @State private var showsOffline = false
    @State private var session = 0
    @State private var shown = false
    private var connected: Bool { store.phase == .connected }

    struct Run { let action: WebProtectorAction; let start: WebProtectorForm; var answers: [Bool]; var confirmedSending = false }
    struct Question: Identifiable {
        let id = UUID()
        let text: String
        /// OK sends these at once: the app's description of them is in the text.
        let sends: WebProtectorWrites?
    }
    struct Sending: Identifiable {
        let id = UUID()
        let writes: WebProtectorWrites
        /// The form before the action, which a cancelled send goes back to.
        let start: WebProtectorForm
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusPageHeader(title: "网页与 Apps 过滤", subtitle: "家长管理 - 网页与 Apps 过滤", symbol: "figure.and.child.holdinghands",
                                 readAt: reading.readAt, loading: reading.loading) { await load() }
                ReadErrorLabel(message: reading.error)
                if let notice { NoticeBanner(message: notice.message, tone: notice.tone) }
                if !connected {
                    ConnectionRequiredView()
                } else if let page = reading.value, let form {
                    if !page.problems.isEmpty {
                        NoticeBanner(message: "本应用只显示这一页，不提供写入：\n" + page.problems.joined(separator: "\n"), tone: .attention)
                    }
                    introduction(page)
                    Group {
                        switchRow(form)
                        if form.tableFailed {
                            Text("规则列表的格式让网页初始化时出错（translate_category_id 或 genMain_table），网页不显示规则表、新增栏与“应用本页面设置”。")
                                .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        } else if form.listShown {
                            table(form)
                        }
                    }.disabled(sent || run != nil || reading.loading || !page.problems.isEmpty)
                } else {
                    ReadingPlaceholder(failed: reading.error != nil && !reading.loading, minHeight: 220)
                }
            }.padding(28).disabled(store.operationTitle != nil)
        }
        .task(id: connected) { if connected, reading.value == nil { await load() } }
        .onAppear { shown = true }
        .onDisappear { shown = false; session += 1; run = nil; question = nil; terms = nil }
        .alert("请确认", isPresented: Binding(get: { question != nil }, set: { if !$0, question != nil { answer(false) } }), presenting: question) { _ in
            Button("确定") { answer(true) }
            Button("取消", role: .cancel) { answer(false) }
        } message: { Text($0.text) }
        .alert("注意", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) { Button("好") {} } message: { Text(alert ?? "") }
        .sheet(item: $terms, onDismiss: termsClosed) { window in
            PolicyDocumentSheet(window: window, language: reading.value?.language ?? "",
                                onAgree: { termsChoice = true }, onDisagree: { termsChoice = false })
        }
        .confirmationDialog(sendingTitle, isPresented: Binding(get: { sending != nil }, set: { if !$0 { sending = nil } }),
                            titleVisibility: .visible, presenting: sending) { pending in
            Button("发送", role: pending.writes.form?.reboots == true ? .destructive : nil) { send(pending.writes) }
            // Not sending leaves the page as it was before the click.
            Button("取消", role: .cancel) { form = pending.start }
        } message: { Text(impact($0.writes)) }
    }

    // MARK: Reading

    /// A read replaces the page (as reloading it would) only when it brought new values, and none starts during a run.
    private func load() async {
        guard run == nil, sending == nil else { return }
        session += 1
        let mine = session, before = reading.readAt
        await reading.load(store: store) { try await $0.webProtectorPage() }
        guard session == mine, !Task.isCancelled, let page = reading.value, reading.readAt != before else { return }
        form = WebProtectorForm(page: page)
        sent = false
    }

    // MARK: Sections

    private func introduction(_ page: WebProtectorPage) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                Text("家长管理 - 网页与 Apps 过滤").font(.headline)
                Text("网页与 Apps 过滤器允许您禁止访问不必要的网站和应用。请按照以下步骤设定：")
                ForEach(Array(["在 [ 客户端名称 ] 栏位中，选择您想控制网络使用的客户端。客户端名称可以在网络地图客户端列表中修改。", "勾选内容类别",
                               "单击（+）图标添加规则，然后单击 应用本页面设置"].enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 6) { Text("\(index + 1).").monospacedDigit(); Text(step) }
                }
                Text("如果您想要暂时禁用某规则，请取消勾选该规则前的复选框")
                if let faq = page.faq { Link("家长管理 FAQ", destination: faq) }
            }.font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func switchRow(_ form: WebProtectorForm) -> some View {
        Panel {
            HStack {
                Text("网页与 Apps 过滤").font(.headline)
                Spacer()
                // The plugin reads curState for this switch (jquery.iphone-switch.js): "1" runs the off callback, else the on one.
                Toggle("网页与 Apps 过滤", isOn: Binding(get: { form.switchShownOn }, set: { _ in begin(form.curState == "1" ? .switchOff : .switchOn) }))
                    .labelsHidden().toggleStyle(.switch)
            }
        }
    }

    private func table(_ form: WebProtectorForm) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                Text(form.page.listTitle).font(.headline)
                HStack(spacing: 10) {
                    // selectAll(this, 0) (340) is not in the firmware's scripts at hand, so the box does nothing here.
                    Toggle("全选", isOn: .constant(false)).toggleStyle(.checkbox).labelsHidden().disabled(true)
                        .help("全选：网页表头调用的 selectAll(this, 0) 在已有固件脚本中找不到定义，本应用不提供。")
                    Text("客户名称 (MAC 地址)").frame(width: 260, alignment: .leading)
                    Text("内容类别")
                    Spacer()
                    Text("添加 / 移除")
                }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                addRow(form)
                Divider()
                if form.filter.isEmpty {
                    Text("目前没有数据").foregroundStyle(.orange)
                } else {
                    ForEach(form.rows) { row in
                        ruleRow(form, row)
                        Divider()
                    }
                }
                HStack(alignment: .bottom) {
                    Text("勾选、新增和删除只改本页；点“应用本页面设置”并确认后才写入路由器。新增或删除会按网页重画表格，其他行尚未应用的勾选改动随之还原。点击客户端图标修改名称与图标的卡片本应用不提供，请在路由器网页修改。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("应用本页面设置") { begin(.apply) }.buttonStyle(.borderedProminent).tint(.teal)
                }
            }
        }
    }

    private func addRow(_ form: WebProtectorForm) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("启用", isOn: Binding(get: { form.newRow.enabled }, set: { self.form?.newRow.enabled = $0 })).toggleStyle(.checkbox).labelsHidden()
                .help("启用/关闭")
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    // validator.isHWAddr on key press, maxlength 17 (352); pasted text is not filtered.
                    TextField(form.page.macPlaceholder, text: Binding(get: { form.newRow.mac }, set: { text in
                        let old = self.form?.newRow.mac ?? ""
                        self.form?.newRow.mac = WebValidator.edit(old, text, typed: KeyPressEvent.typedCharacter, maxLength: 17,
                                                                  replaced: KeyPressEvent.replacedRange(old, text), keyPress: WebValidator.hardwareAddressKeyPress)
                    })).textFieldStyle(.roundedBorder).font(.body.monospaced()).frame(width: 220)
                    clientMenu(form)
                }
                if form.macHint { Text(ParentalMAC.formatHint).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true).frame(width: 250, alignment: .leading) }
            }.frame(width: 260, alignment: .leading)
            categories(form, row: nil)
            Spacer()
            Button { add() } label: { Image(systemName: "plus.circle.fill") }.buttonStyle(.borderless).help("添加")
        }
    }

    private func ruleRow(_ form: WebProtectorForm, _ row: WebProtectorRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("启用", isOn: Binding(get: { row.enabled }, set: { self.form?.rows[row.id].enabled = $0 })).toggleStyle(.checkbox).labelsHidden()
                .help("启用/关闭")
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.callout.weight(.medium))
                Text(row.macText).font(.caption.monospaced()).foregroundStyle(.secondary)
            }.frame(width: 260, alignment: .leading).help(row.mac)
            categories(form, row: row.id)
            Spacer()
            Button { self.form?.delete(row) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("移除（应用本页面设置后才保存）")
        }
    }

    /// The four categories of a row (nil: the add row): the arrow opens the items (one category on the whole table), the
    /// category box sets all its items; the add row shows each description while its category is closed.
    private func categories(_ form: WebProtectorForm, row: Int?) -> some View {
        let parents = row.map { form.rows[$0].parents } ?? form.newRow.parents
        let children = row.map { form.rows[$0].children } ?? form.newRow.children
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(WebProtectorPage.categories.enumerated()), id: \.offset) { index, category in
                let position = WebProtectorCategoryPosition(row: row, category: index)
                let open = form.expanded == position
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Button { self.form?.toggleExpanded(position) } label: { Image(systemName: open ? "chevron.down" : "chevron.right").frame(width: 12) }
                            .buttonStyle(.borderless)
                        Toggle(category.title, isOn: Binding(get: { parents[index] }, set: { _ in self.form?.toggleParent(row: row, category: index) }))
                            .toggleStyle(.checkbox).font(.callout.weight(.semibold))
                    }
                    if open {
                        ForEach(Array(category.items.enumerated()), id: \.offset) { item, title in
                            Toggle(title, isOn: Binding(get: { children[index][item] }, set: { _ in self.form?.toggleChild(row: row, category: index, item: item) }))
                                .toggleStyle(.checkbox).font(.callout).padding(.leading, 34)
                        }
                    } else if row == nil {
                        Text(category.description).font(.caption).foregroundStyle(.secondary).padding(.leading, 20).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }.frame(minWidth: 220, alignment: .leading)
    }

    /// showDropdownClientList('setClientIP', 'mac', 'all', …) (82, 515): a choice fills in its MAC.
    private func clientMenu(_ form: WebProtectorForm) -> some View {
        let clients = TORSettings.dropdownClients(form.page.clients)
        return Menu {
            ForEach(clients.online, id: \.mac) { client in
                Button(HTMLText.visible(TORSettings.dropdownName(client), inside: ["strong"])) { self.form?.newRow.mac = client.mac }
            }
            if !clients.offline.isEmpty {
                Toggle("显示离线设备", isOn: $showsOffline)
                if showsOffline {
                    ForEach(clients.offline, id: \.mac) { client in
                        Button(HTMLText.visible(TORSettings.dropdownName(client), inside: ["strong"]) + "（离线）") { self.form?.newRow.mac = client.mac }
                    }
                }
            }
        } label: { Image(systemName: "chevron.up.chevron.down") }.menuStyle(.borderlessButton).fixedSize().help("选择 DHCP 客户端。")
    }

    private func add() {
        guard var next = form else { return }
        let result = next.add()
        form = next
        switch result {
        case .added, .hint: break
        case .alert(let text): alert = text
        case .stopped(let reason): alert = "网页的脚本在这里出错：" + reason
        }
    }

    // MARK: Runs of the page's script

    private func begin(_ action: WebProtectorAction) {
        guard let form, run == nil, sending == nil else { return }
        run = Run(action: action, start: form, answers: [])
        step()
    }

    /// The script again from the form it started from, with the answers so far, up to its next question or its end.
    private func step() {
        guard let current = run else { return }
        let (next, outcome) = current.start.running(current.action, answers: current.answers)
        switch outcome {
        case .confirm(let asked):
            // When OK leads straight to the requests, the app's description of them goes into the page's own question.
            if case .finished(nil, let writes) = current.start.running(current.action, answers: current.answers + [true]).1, !writes.isEmpty {
                question = Question(text: asked.text + "\n\n" + impact(writes), sends: writes)
            } else {
                question = Question(text: asked.text, sends: nil)
            }
            return
        case .terms:
            guard let document = PolicyTexts.trendMicro else {
                run = nil; alert = "本应用没有载入 Trend Micro 条款的文本，无法按网页显示条款窗口。"; return
            }
            terms = PolicyWindow(kind: .trendMicro, document: document, buttons: .decide)
            return
        case .stopped(let reason):
            form = next; run = nil
            alert = "网页的脚本在这里出错，没有发送任何设置：" + reason
        case .finished(let shownAlert, let writes):
            form = current.start.settled(next, answers: current.answers, writes: writes)
            let confirmed = current.confirmedSending
            run = nil
            if let shownAlert { alert = shownAlert }
            guard !writes.isEmpty else { return }
            if confirmed { send(writes); return }
            let pending = Sending(writes: writes, start: current.start)
            if shownAlert != nil { afterSheetCloses { waitForAlert(pending) } } else { sending = pending }
        }
    }

    /// The app's own question opens once the page's alert is closed.
    private func waitForAlert(_ pending: Sending) {
        if alert != nil { afterSheetCloses { waitForAlert(pending) } } else { sending = pending }
    }

    private func answer(_ yes: Bool) {
        guard let asked = question else { return }
        question = nil
        run?.answers.append(yes)
        if yes, asked.sends != nil { run?.confirmedSending = true }
        afterSheetCloses { step() }
    }

    /// 同意 or 拒绝 goes on with the script; closing the window otherwise ends the run.
    private func termsClosed() {
        guard let choice = termsChoice else { run = nil; return }
        termsChoice = nil
        run?.answers.append(choice)
        afterSheetCloses { step() }
    }

    private var sendingTitle: String {
        guard let writes = sending?.writes else { return "" }
        if writes.form == nil { return writes.trendMicro == "1" ? "记录同意 Trend Micro 条款？" : "记录不同意 Trend Micro 条款？" }
        return writes.form?.reboots == true ? "应用设置并重新启动路由器？" : "应用网页与 Apps 过滤设置？"
    }

    /// What the requests do, as the confirmation before sending states it.
    private func impact(_ writes: WebProtectorWrites) -> String {
        var parts: [String] = []
        if let form = writes.form {
            let on = form.value("wrs_enable") == "1"
            var what = "本应用说明：确认后发送网页的同一张表单（start_apply.htm）：网页与 Apps 过滤" + (on ? "开启" : "关闭") + "（wrs_enable=\(form.value("wrs_enable") ?? "")）"
            if let rules = form.value("wrs_rulelist") { what += "，规则 \(rules.isEmpty ? 0 : rules.components(separatedBy: "<").count) 条" } else { what += "，规则不随表单发送（保留路由器上的规则）" }
            if form.value("wans_mode") == "fo" { what += "，双 WAN 由“负载均衡”改为“故障转移”（wans_mode=fo）" }
            parts.append(what + "。")
            parts.append(form.reboots
                         ? "路由器会重新启动（action_script=reboot，约 \(form.wait) 秒，期间所有设备断网），恢复后本应用重新读取核对。"
                         : "路由器会重启 wrs 与防火墙（action_script=\(form.actionScript)，约 \(form.wait) 秒），之后本应用重新读取核对。")
        }
        switch writes.trendMicro {
        case "1"?: parts.append(writes.form == nil ? "网页在这里只记录同意 Trend Micro 条款（set_TM_EULA.cgi，TM_EULA=1），不发送表单。" : "表单发出后接着记录同意 Trend Micro 条款（set_TM_EULA.cgi，TM_EULA=1），与网页相同。")
        case "0"?: parts.append("网页在这里记录不同意 Trend Micro 条款（set_TM_EULA.cgi，TM_EULA=0，并记下时间）；路由器随之关闭 AiProtection（wrs_protect_enable）、网页与 Apps 过滤（wrs_enable、wrs_app_enable）、应用程序分析、网页浏览历史与流量分析的数据库，Adaptive QoS 时关闭 QoS（qos_enable=0），并重启 wrs、QoS 与防火墙。")
        default: break
        }
        return parts.joined(separator: "\n")
    }

    // MARK: Sending

    private func send(_ writes: WebProtectorWrites) {
        guard store.beginOperation("正在保存网页与 Apps 过滤设置") else { return }
        // Once sent a write is not taken back, so it is not cancelled with the page.
        Task { @MainActor in
            var readAgain = false
            do {
                let client = try store.connectedClient()
                let reboots = writes.form?.reboots == true
                // The uptime before the write tells the restart afterwards; without one it is read first.
                var uptime = store.snapshot?.sample.uptime ?? 0
                if uptime == 0, reboots, let read = try? await client.sample().uptime { uptime = read }
                let receipt = try await client.applyWebProtector(writes)
                notice = (receipt.message, receipt.isVerified ? .success : .attention)
                if reboots {
                    sent = true
                    switch await store.awaitRestart(client, from: uptime, checks: max(24, ((writes.form?.wait ?? 0) + 60) / 5)) {
                    case .back:
                        let checked = try await client.checkWebProtector(writes)
                        notice = ("路由器已重新启动并恢复连接。" + checked.message, checked.isVerified ? .success : .attention); readAgain = true
                    case .signInFailed(let reason): notice = (reason, .attention)
                    case .timedOut, .stayedUp: notice = ("路由器已接收设置并开始重新启动，但还没有确认恢复连接。请稍后点“重新读取”核对，不要重复提交。", .attention)
                    }
                } else {
                    readAgain = true
                }
            } catch RouterError.submissionUncertain(let reason) {
                notice = (reason, .attention); readAgain = true
            } catch {
                notice = ("没有完成：\(error.localizedDescription)", .error)
                store.handleManagementError(error)
            }
            store.endOperation()
            // A page left meanwhile is not read again.
            if readAgain, shown { await load() }
        }
    }
}
