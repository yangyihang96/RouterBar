import RouterCore
import SwiftUI

// 1.14：家长管理 › 时间安排（ParentalControl.asp 与 js/weekSchedule/weekSchedule.js）。设备列表的新增、删除、状态选择与时间编辑器里的
// 规则都与网页一样只改本页；“应用本页面设置”、关闭总开关（原先已开启时）和时间编辑器的“应用本页面设置”会提交整页，“启用阻止
// 所有设备”立即写入。每个写入先由本应用写明影响（重启防火墙）并确认，再发送网页的同一请求，之后重新读取核对。点击客户端图标编辑
// 名称与图标的卡片不提供。

struct ParentalControlView: View {
    @Environment(RouterStore.self) var store
    @StateObject private var reading = RouterReading<ParentalControlPage>()
    @State private var form: ParentalControlForm?
    /// The time editor in place of the list (schedule_block_on), for the device at `index`.
    @State private var editing: Editing?
    /// weekScheduleApi's mode and text, which last from one editor to the next until the page is read again.
    @State private var carry = ParentalSchedule.Carry()
    @State private var pending: Pending?
    @State private var alert: String?
    @State private var notice: (message: String, tone: NoticeBanner.Tone)?
    @State private var showsOffline = false
    @State private var session = 0
    @State private var shown = false
    private var connected: Bool { store.phase == .connected }

    struct Editing: Equatable { let index: Int; var schedule: ParentalSchedule }
    /// A write waiting for the app's confirmation, with the page as it will be once it is sent.
    struct Pending: Identifiable {
        let id = UUID()
        let kind: Kind
        let note: String?
        enum Kind { case form(ParentalFormSubmission, next: ParentalControlForm, closesEditor: Bool), blockAll(Bool) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusPageHeader(title: "时间安排", subtitle: reading.value?.title ?? "家长管理", symbol: "clock.badge.checkmark",
                                 readAt: reading.readAt, loading: reading.loading) { await load() }
                ReadErrorLabel(message: reading.error)
                if let notice { NoticeBanner(message: notice.message, tone: notice.tone) }
                if !connected {
                    ConnectionRequiredView()
                } else if let page = reading.value, let form {
                    if !page.problems.isEmpty {
                        NoticeBanner(message: "本应用只显示这一页，不提供写入：\n" + page.problems.joined(separator: "\n"), tone: .attention)
                    }
                    Group {
                        if page.blockAllShown { blockAll(form) }
                        introduction(page)
                        if let editing {
                            ParentalScheduleEditor(schedule: Binding(get: { editing.schedule }, set: { self.editing?.schedule = $0 }),
                                                   deviceName: form.name(form.devices[editing.index]), onCancel: cancelEditor, onApply: applyEditor)
                        } else {
                            switchPanel(page, form)
                            if form.contentShown { list(page, form) }
                        }
                    }.disabled(reading.loading || !page.problems.isEmpty)
                } else {
                    ReadingPlaceholder(failed: reading.error != nil && !reading.loading, minHeight: 220)
                }
            }.padding(28).disabled(store.operationTitle != nil)
        }
        .task(id: connected) { if connected, reading.value == nil { await load() } }
        .onAppear { shown = true }
        .onDisappear { shown = false; session += 1 }
        .alert("注意", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) { Button("确认") {} } message: { Text(alert ?? "") }
        .confirmationDialog(pendingTitle, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible,
                            presenting: pending) { item in
            Button("发送") { send(item.kind) }
            Button("取消", role: .cancel) {}
        } message: { item in Text([item.note, impact(item.kind)].compactMap { $0 }.joined(separator: "\n\n")) }
    }

    /// A read replaces the page only when it brought new values; the editor and weekScheduleApi's state go with it.
    private func load() async {
        guard pending == nil else { return }
        session += 1
        let mine = session, before = reading.readAt
        await reading.load(store: store) { try await $0.parentalControlPage() }
        guard session == mine, !Task.isCancelled, let page = reading.value, reading.readAt != before else { return }
        form = ParentalControlForm(page: page)
        editing = nil; carry = ParentalSchedule.Carry()
    }

    /// The seconds the page's clock has counted since it was read (count_time).
    private var elapsed: Int { Int(Date().timeIntervalSince(reading.readAt ?? Date())) }
    private var systemTime: String { ParentalControlPage.clockText(reading.value?.clock, elapsed: elapsed) }

    // MARK: Sections

    private func blockAll(_ form: ParentalControlForm) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                Text("启用「阻止所有设备」后，所有连接的设备都将被阻止从 Internet 访问。").font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("启用阻止所有设备").font(.headline)
                    Spacer()
                    // The switch writes at once (645–663); the app asks first.
                    Toggle("启用阻止所有设备", isOn: Binding(get: { form.blockAllOn }, set: { on in pending = Pending(kind: .blockAll(on), note: nil) }))
                        .labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }

    private func introduction(_ page: ParentalControlPage) -> some View {
        let description = page.description
        return Panel {
            VStack(alignment: .leading, spacing: 8) {
                Text(description.title)
                ForEach(Array(description.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 6) { Text("\(index + 1).").monospacedDigit(); Text(step) }
                }
                if let notes = description.notes {
                    Text("注意：").foregroundStyle(.secondary)
                    ForEach(Array(notes.enumerated()), id: \.offset) { index, note in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(index + 1).").monospacedDigit()
                            if description.natNote, index == notes.count - 1 {
                                // ParentalCtrl_disable_NAT links Advanced_SwitchCtrl_Content.asp?af=ctf_disable_force (161).
                                HStack(spacing: 0) {
                                    Text("请禁用 ")
                                    Button("NAT 加速") { openSection("switch") }.buttonStyle(.link)
                                    Text(" 以进行更精确的计划控制。")
                                }
                            } else {
                                Text(note)
                            }
                        }.foregroundStyle(.secondary)
                    }
                }
            }.font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func switchPanel(_ page: ParentalControlPage, _ form: ParentalControlForm) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(page.switchTitle).font(.headline)
                    Spacer()
                    Toggle(page.switchTitle, isOn: Binding(get: { form.switchOn }, set: { _ in toggleSwitch() })).labelsHidden().toggleStyle(.switch)
                }
                if form.contentShown {
                    HStack(alignment: .top) {
                        Text("系统时间").frame(width: 120, alignment: .leading)
                        VStack(alignment: .leading, spacing: 4) {
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                Text(systemTime).font(.callout.monospaced())
                            }
                            if page.notSynchronised {
                                Button("* 提醒：您的系统时间未与 NTP 服务器同步。") { openSection("ntp") }.buttonStyle(.link).font(.caption)
                            }
                            if page.zoneDiffers() {
                                Button("* 提醒：目前系统时区与您计算机设置不同，提醒您校正为当地时区。") { openSection("ntp") }.buttonStyle(.link).font(.caption)
                            }
                        }
                    }
                }
            }
        }
    }

    private func list(_ page: ParentalControlPage, _ form: ParentalControlForm) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                Text(page.listTitle).font(.headline)
                HStack(spacing: 10) {
                    // selectAll (350–357): every row takes the choice, then the select shows 全选 again.
                    Menu("全选") {
                        Button("关闭") { self.form?.selectAll("0") }
                        Button("时间") { self.form?.selectAll("1") }
                        Button("封锁") { self.form?.selectAll("2") }
                    }.fixedSize().frame(width: 90, alignment: .leading)
                    Text("客户名称 (MAC 地址)").frame(width: 280, alignment: .leading)
                    Text("时间管理").frame(width: 80)
                    Spacer()
                    Text("添加 / 移除")
                }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                addRow(page, form)
                Divider()
                if form.devices.isEmpty {
                    Text("目前没有数据").foregroundStyle(.orange)
                } else {
                    ForEach(Array(form.devices.enumerated()), id: \.offset) { index, device in
                        deviceRow(form, index, device)
                        Divider()
                    }
                }
                HStack(alignment: .bottom) {
                    Text("新增、删除和状态选择只改本页；点“应用本页面设置”并确认后才写入路由器。点击客户端图标修改名称与图标的卡片本应用不提供，请在路由器网页修改。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("应用本页面设置") { confirmApply() }.buttonStyle(.borderedProminent).tint(.teal)
                }
            }
        }
    }

    private func enablePicker(_ selection: Binding<String>) -> some View {
        Picker("状态", selection: selection) {
            Text("关闭").tag("0"); Text("时间").tag("1"); Text("封锁").tag("2")
        }.labelsHidden().frame(width: 90)
    }

    private func addRow(_ page: ParentalControlPage, _ form: ParentalControlForm) -> some View {
        HStack(alignment: .top, spacing: 10) {
            enablePicker(Binding(get: { form.newEnable }, set: { self.form?.newEnable = $0 }))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    // validator.isHWAddr on key press, maxlength 17 (249); pasted text is not filtered.
                    TextField(page.macPlaceholder, text: Binding(get: { form.mac }, set: { text in
                        let old = self.form?.mac ?? ""
                        self.form?.mac = WebValidator.edit(old, text, typed: KeyPressEvent.typedCharacter, maxLength: 17,
                                                           replaced: KeyPressEvent.replacedRange(old, text), keyPress: WebValidator.hardwareAddressKeyPress)
                    })).textFieldStyle(.roundedBorder).font(.body.monospaced()).frame(width: 220)
                    clientMenu(page)
                }
                if form.macHint { Text(ParentalMAC.formatHint).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true).frame(width: 270, alignment: .leading) }
            }.frame(width: 280, alignment: .leading)
            Text("--").frame(width: 80)
            Spacer()
            Button { add() } label: { Image(systemName: "plus.circle.fill") }.buttonStyle(.borderless).help("添加")
        }
    }

    private func deviceRow(_ form: ParentalControlForm, _ index: Int, _ device: ParentalDevice) -> some View {
        HStack(alignment: .center, spacing: 10) {
            enablePicker(Binding(get: { device.enable }, set: { self.form?.setEnable($0, at: index) }))
            VStack(alignment: .leading, spacing: 2) {
                Text(form.name(device)).font(.callout.weight(.medium))
                Text(HTMLText.visible(device.mac, inside: ["div"])).font(.caption.monospaced()).foregroundStyle(.secondary)
            }.frame(width: 280, alignment: .leading)
            Button { openEditor(index) } label: { Image(systemName: "pencil.circle") }.buttonStyle(.borderless).frame(width: 80).help("编辑时间规则")
            Spacer()
            // deleteRow_main has no confirm() on the page.
            Button { self.form?.delete(at: index) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("移除（应用本页面设置后才保存）")
        }
    }

    /// showDropdownClientList('setClientIP', 'mac', 'all', …) (175, 346).
    private func clientMenu(_ page: ParentalControlPage) -> some View {
        let clients = TORSettings.dropdownClients(page.clients)
        return Menu {
            ForEach(clients.online, id: \.mac) { client in
                Button(HTMLText.visible(TORSettings.dropdownName(client), inside: ["strong"])) { self.form?.mac = client.mac }
            }
            if !clients.offline.isEmpty {
                Toggle("显示离线设备", isOn: $showsOffline)
                if showsOffline {
                    ForEach(clients.offline, id: \.mac) { client in
                        Button(HTMLText.visible(TORSettings.dropdownName(client), inside: ["strong"]) + "（离线）") { self.form?.mac = client.mac }
                    }
                }
            }
        } label: { Image(systemName: "chevron.up.chevron.down") }.menuStyle(.borderlessButton).fixedSize().help("选择 DHCP 客户端。")
    }

    private func openSection(_ id: String) {
        if let location = store.menuSet.location(ofSection: id) { store.navigate(.web(location)) }
    }

    // MARK: Actions

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

    private func toggleSwitch() {
        guard var next = form else { return }
        if let submission = next.toggleSwitch(systemTime: systemTime) {
            // applyRule(1) runs at once on the page; here the app asks first and the switch stays until it is sent.
            pending = Pending(kind: .form(submission, next: next, closesEditor: false), note: "关闭开关时，网页会立即提交整页设置。")
        } else {
            form = next
        }
    }

    private func confirmApply() {
        guard let form else { return }
        pending = Pending(kind: .form(form.submission(systemTime: systemTime), next: form, closesEditor: false), note: nil)
    }

    private func openEditor(_ index: Int) {
        guard let form else { return }
        switch form.scheduleEditor(for: index, weekday: ParentalControlPage.weekday(form.page.clock, elapsed: elapsed), previous: carry) {
        case .success(let schedule): editing = Editing(index: index, schedule: schedule)
        case .failure(let stop): alert = "网页的脚本在这里出错，时间编辑器打不开：" + stop.reason
        }
    }

    private func cancelEditor() {
        guard let editing else { return }
        carry = editing.schedule.carry
        form?.cancelSchedule()
        self.editing = nil
    }

    /// The editor's 应用本页面设置: its own question for an online schedule with every rule off, then the app's.
    private func applyEditor() {
        guard let editing, var next = form else { return }
        let submission = next.applySchedule(editing.schedule.offtime, at: editing.index, systemTime: systemTime)
        let note = editing.schedule.asksBeforeApply ? "网页提示：如果禁用所有时间安排规则，则该组中的客户端将无法连接到 Internet。" : "时间编辑器的“应用本页面设置”会立即提交整页设置。"
        pending = Pending(kind: .form(submission, next: next, closesEditor: true), note: note)
    }

    private var pendingTitle: String {
        switch pending?.kind {
        case .blockAll(let on)?: on ? "启用阻止所有设备？" : "关闭阻止所有设备？"
        case .form?: "应用时间安排设置？"
        case nil: ""
        }
    }

    private func impact(_ kind: Pending.Kind) -> String {
        switch kind {
        case .blockAll(let on):
            return "本应用说明：确认后发送网页的同一请求（applyapp.cgi，MULTIFILTER_BLOCK_ALL=\(on ? "1" : "0")，rc_service=restart_firewall）。路由器会重启防火墙，"
                + (on ? "之后所有连接的设备都无法访问 Internet。" : "恢复按各设备规则控制。") + "约 3 秒后本应用重新读取核对。"
        case .form(let submission, _, _):
            let count = submission.value("MULTIFILTER_MAC").map { $0.isEmpty ? 0 : $0.components(separatedBy: ">").count } ?? 0
            return "本应用说明：确认后发送网页的同一张表单（start_apply.htm）：时间安排开关 MULTIFILTER_ALL=\(submission.value("MULTIFILTER_ALL") ?? "")，\(count) 台设备的状态、名称与时间规则（MULTIFILTER_ENABLE、MULTIFILTER_MAC、MULTIFILTER_DEVICENAME、MULTIFILTER_MACFILTER_DAYTIME_V2）。路由器会重启防火墙（restart_firewall，约 5 秒），之后本应用重新读取核对。"
        }
    }

    private func send(_ kind: Pending.Kind) {
        guard store.beginOperation("正在保存时间安排设置") else { return }
        if case .form(_, let next, let closes) = kind {
            form = next
            if closes, let editing { carry = editing.schedule.carry; self.editing = nil }
        }
        // Once sent a write is not taken back, so it is not cancelled with the page.
        Task { @MainActor in
            var readAgain = false
            do {
                let client = try store.connectedClient()
                switch kind {
                case .form(let submission, _, _):
                    let receipt = try await client.applyParentalControl(submission)
                    notice = (receipt.message, receipt.isVerified ? .success : .attention); readAgain = true
                case .blockAll(let on):
                    // The page only shows three seconds of loading and stays as it is (what is not applied yet stays too);
                    // the switch keeps its new position.
                    let receipt = try await client.setBlockAllDevices(on)
                    notice = (receipt.message, receipt.isVerified ? .success : .attention)
                    form?.blockAllOn = on
                }
            } catch RouterError.submissionUncertain(let reason) {
                notice = (reason, .attention)
                if case .form = kind { readAgain = true }
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

// MARK: - The time editor

/// weekScheduleApi's PC layout (PC_init_layout 1474–1547): the mode title, “+”, the view switch, the rule cards or the
/// one-week overview, and 全部清除 / 取消 / 应用本页面设置.
struct ParentalScheduleEditor: View {
    @Binding var schedule: ParentalSchedule
    let deviceName: String
    let onCancel: () -> Void
    let onApply: () -> Void
    @State private var editor: ScheduleRuleEditor?
    @State private var popup: Popup?
    @State private var choosingMode = false

    struct Popup: Identifiable {
        let id = UUID()
        let text: String
        /// nil: only 确认, which does nothing more.
        let confirm: (() -> Void)?
    }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(deviceName).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                header
                if schedule.overview {
                    overview
                } else {
                    grid
                    // action_btn_bg carries gridview_mode (1532): the overview shows no buttons but the view switch.
                    HStack {
                        Button("全部清除") {
                            popup = Popup(text: "确定要删除所有规则吗？", confirm: { schedule.clearAll() })
                        }
                        Spacer()
                        Button("取消") { onCancel() }
                        Button("应用本页面设置") { onApply() }.buttonStyle(.borderedProminent).tint(.teal)
                    }
                }
                Text("这里的规则改动只在本页；“应用本页面设置”会提交整页（包括设备列表的其他改动）。本页的时间编辑器没有拖拽编辑。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(item: Binding(get: { editor.map { EditorBox(editor: $0) } }, set: { if $0 == nil { editor = nil } })) { _ in
            ScheduleRuleSheet(editor: Binding(get: { editor ?? schedule.newRuleEditor }, set: { editor = $0 }), save: save, close: { editor = nil })
                .frame(width: 460)
        }
        .sheet(isPresented: $choosingMode) {
            ScheduleModeSheet(current: schedule.mode) { chosen in schedule.changeMode(chosen); choosingMode = false } close: { choosingMode = false }
                .frame(width: 460)
        }
        .alert("提示", isPresented: Binding(get: { popup != nil }, set: { if !$0 { popup = nil } }), presenting: popup) { item in
            if let confirm = item.confirm {
                Button("取消", role: .cancel) {}
                Button("确认") { confirm() }
            } else {
                Button("确认") {}
            }
        } message: { Text($0.text) }
    }

    private struct EditorBox: Identifiable { let editor: ScheduleRuleEditor; var id: String { editor.rule.id + (editor.isNew ? "new" : "") } }

    private var header: some View {
        HStack(spacing: 12) {
            if schedule.changesModes {
                Button { choosingMode = true } label: {
                    Label(schedule.headerText, systemImage: schedule.headerMode == "M" ? "wifi" : "wifi.slash").font(.headline)
                }.buttonStyle(.plain).help("选择时间安排模式")
            } else {
                Text(schedule.headerText).font(.headline)
            }
            Spacer()
            if !schedule.overview {
                Button {
                    if schedule.isFull { popup = Popup(text: schedule.fullAlert, confirm: nil) } else { editor = schedule.newRuleEditor }
                } label: { Image(systemName: "plus.circle") }.buttonStyle(.borderless).help("Add a new rule")
            }
            Button { schedule.overview.toggle() } label: { Image(systemName: schedule.overview ? "square.grid.2x2" : "calendar") }
                .buttonStyle(.borderless).help("Switch View")
        }
    }

    private var grid: some View {
        let cards = schedule.cards
        return VStack(alignment: .leading, spacing: 8) {
            if cards.isEmpty {
                Text("目前没有数据").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ForEach(cards) { card in
                    if let title = card.title { Text(title).font(.subheadline.weight(.semibold)).padding(.top, 4) }
                    HStack(spacing: 12) {
                        Button { editor = schedule.editor(card) } label: {
                            HStack(spacing: 8) {
                                Text(card.start).help("开始时间")
                                Text("–")
                                Text(card.end).help("时间结束")
                            }.font(.title3.monospacedDigit()).foregroundStyle(card.on ? Color.primary : Color.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Toggle("启用", isOn: Binding(get: { card.on }, set: { _ in schedule.toggle(card) })).labelsHidden().toggleStyle(.switch)
                        Button {
                            popup = Popup(text: "确定要删除此设置档？", confirm: { schedule.delete(card) })
                        } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("删除")
                    }
                    .padding(10)
                    .background((card.on ? Color.teal : Color.secondary).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    /// overview_a_week_component("view"): the week from SUN, today marked, 4-hour lines, enabled rules drawn and disabled
    /// ones dimmed, with the legend.
    private var overview: some View {
        let bars = schedule.bars
        let days = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                Text("").frame(width: 44)
                GeometryReader { geometry in
                    ForEach([0, 4, 8, 12, 16, 20, 24], id: \.self) { hour in
                        Text(String(format: "%02d:00", hour)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            .position(x: geometry.size.width * CGFloat(hour) / 24, y: 7)
                    }
                }.frame(height: 14)
            }
            ForEach(0..<7, id: \.self) { day in
                HStack(spacing: 0) {
                    Text(days[day]).font(.caption.weight(day == schedule.today ? .bold : .regular))
                        .foregroundStyle(day == schedule.today ? Color.teal : Color.primary).frame(width: 44, alignment: .leading)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.1))
                            ForEach([4, 8, 12, 16, 20], id: \.self) { hour in
                                Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 1).offset(x: geometry.size.width * CGFloat(hour) / 24)
                            }
                            ForEach(Array(bars[day].enumerated()), id: \.offset) { _, bar in
                                let start = geometry.size.width * CGFloat(bar.start / 1440), end = geometry.size.width * CGFloat(bar.end / 1440)
                                RoundedRectangle(cornerRadius: 3).fill(bar.disabled ? Color.secondary.opacity(0.45) : Color.teal)
                                    .frame(width: max(2, end - start)).offset(x: start)
                            }
                        }
                    }.frame(height: 22)
                }
            }
            HStack(spacing: 14) {
                Label { Text(schedule.headerText) } icon: { RoundedRectangle(cornerRadius: 2).fill(Color.teal).frame(width: 14, height: 10) }
                Label { Text("未启用 " + schedule.headerText) } icon: { RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.45)).frame(width: 14, height: 10) }
            }.font(.caption)
        }
    }

    /// 保存: the rule goes in and the window closes, or the popup's text (shown over the window) comes back.
    private func save() -> String? {
        guard let current = editor else { return nil }
        if let failure = schedule.save(current) { return failure }
        editor = nil
        return nil
    }
}

/// The rule window (edit_time_setting_component): 开始时间 and 时间结束 with their lists, the hint, 全天, 时间表 and 保存.
struct ScheduleRuleSheet: View {
    @Binding var editor: ScheduleRuleEditor
    let save: () -> String?
    let close: () -> Void
    @FocusState private var focus: ScheduleRuleEditor.Field?
    /// popupHint over the window, with 确认 only (931–937, 1003–1007).
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(editor.title).font(.title3.weight(.semibold))
                Spacer()
                Button { close() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
            }
            HStack(alignment: .top, spacing: 24) {
                timeGroup("开始时间", hour: .startHour, minute: .startMinute)
                timeGroup("时间结束", hour: .endHour, minute: .endMinute)
            }
            if let hint = editor.hint { Text(hint).font(.callout).foregroundStyle(.orange) }
            Toggle("全天", isOn: Binding(get: { editor.allDay }, set: { _ in leaveInput(); editor.toggleAllDay() })).toggleStyle(.checkbox)
            Divider()
            Text("时间表").font(.subheadline.weight(.semibold))
            HStack(spacing: 6) {
                ForEach(Array(["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"].enumerated()), id: \.offset) { day, title in
                    Toggle(title, isOn: Binding(get: { editor.days[day] }, set: { _ in leaveInput(); editor.toggleDay(day) })).toggleStyle(.button)
                }
            }
            HStack {
                Spacer()
                Button("保存") {
                    // Clicking 保存 leaves the input first: its blur runs before the button's check (914).
                    leaveInput()
                    failure = save()
                }.buttonStyle(.borderedProminent).tint(.teal)
            }
        }
        .padding(22)
        .onChange(of: focus) { old, _ in if let old { editor.blur(old) } }
        .alert("提示", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) { Button("确认") {} } message: { Text(failure ?? "") }
    }

    /// A click elsewhere in the window blurs the input being edited before the click's own handler runs.
    private func leaveInput() {
        guard let current = focus else { return }
        focus = nil
        editor.blur(current)
    }

    private func timeGroup(_ title: String, hour: ScheduleRuleEditor.Field, minute: ScheduleRuleEditor.Field) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            HStack(spacing: 10) {
                timeInput("时", hour)
                timeInput("分", minute)
            }
        }
    }

    /// An input with its list: digits on key press (validator.isNumber), at most two characters; the list sets the value
    /// and blurs the input.
    private func timeInput(_ unit: String, _ field: ScheduleRuleEditor.Field) -> some View {
        HStack(spacing: 4) {
            TextField(unit, text: Binding(get: { editor.texts[field.rawValue] }, set: { text in
                let old = editor.texts[field.rawValue]
                editor.texts[field.rawValue] = WebValidator.edit(old, text, typed: KeyPressEvent.typedCharacter, maxLength: 2,
                                                                 replaced: KeyPressEvent.replacedRange(old, text), keyPress: WebValidator.numberKeyPress)
            })).textFieldStyle(.roundedBorder).frame(width: 40).focused($focus, equals: field).disabled(!editor.isEnabled(field))
            Menu {
                ForEach(ScheduleRuleEditor.options(field), id: \.self) { value in
                    Button(String(format: "%02d", value)) {
                        // The click leaves the input being edited first; a hint it raises closes this list (it only opens
                        // while it is active).
                        leaveInput()
                        if editor.isEnabled(field) { editor.choose(value, for: field) }
                    }
                }
            } label: { Image(systemName: "chevron.down") }.menuStyle(.borderlessButton).fixedSize().disabled(!editor.isEnabled(field))
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The mode window (PC_get_time_schedule_mode_component 1897–1964).
struct ScheduleModeSheet: View {
    let current: String
    let save: (String) -> Void
    let close: () -> Void
    @State private var chosen: String

    init(current: String, save: @escaping (String) -> Void, close: @escaping () -> Void) {
        self.current = current; self.save = save; self.close = close
        _chosen = State(initialValue: current)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("选择时间安排模式").font(.title3.weight(.semibold))
                Spacer()
                Button { close() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
            }
            Text("如果更改时间安排模式，则所有时间安排规则都将重置。").font(.callout).foregroundStyle(.orange)
            option("W", icon: "wifi.slash", title: "设置离线计划", detail: "配置 Internet 不可用时的离线计划时间。")
            Divider()
            option("M", icon: "wifi", title: "设置在线计划", detail: "配置设备 Internet 访问的在线计划时间。")
            HStack { Spacer(); Button("保存") { save(chosen) }.buttonStyle(.borderedProminent).tint(.teal) }
        }.padding(22)
    }

    private func option(_ mode: String, icon: String, title: String, detail: String) -> some View {
        Button { chosen = mode } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title2).frame(width: 36)
                VStack(alignment: .leading, spacing: 3) { Text(title).font(.headline); Text(detail).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Image(systemName: chosen == mode ? "largecircle.fill.circle" : "circle").foregroundStyle(.teal)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
