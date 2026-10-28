import RouterCore
import SwiftUI

// 1.13：外部网络(WAN) › 双线路（Advanced_WANPort_Content.asp）。开关、下拉、勾选与网页一样只改本页的表单；“应用本页面设置”按网页
// 脚本依次提出网页自己的确认（原文），并由本应用写明“若设置有变化路由器会重新启动、约 N 秒断网”，确认后才发送网页的同一张表单
// （start_apply.htm）。发送后提示路由器正在重新启动，重启期间不读取。路由规则的新增、点击修改与删除按 js/table/table.js 与
// tableValidator.js（dualWanRoutingRules）的校验、提示和改写进行，只改本页的列表，随“应用本页面设置”一起保存。

struct DualWANView: View {
    @Environment(RouterStore.self) var store
    @Environment(\.openURL) private var openURL
    @StateObject private var reading = RouterReading<DualWANPage>()
    /// The page as it runs: its form and what shows.
    @State private var form: DualWANForm?
    /// An apply under way: the form as it was when 应用本页面设置 was clicked and the confirm() answers so far.
    @State private var run: ApplyRun?
    @State private var question: Question?
    @State private var alert: String?
    /// The app's own question before sending, when the page sends without asking (DPI, hot standby panel).
    @State private var sending: DualWANSubmission?
    @State private var askedReboot = false
    @State private var standbyShown = false
    @State private var notice: (message: String, tone: NoticeBanner.Tone)?
    /// The form went to the router: the page waits for 重新读取.
    @State private var sent = false
    /// A switch callback is reading from the router.
    @State private var busy = false
    /// httpApi.nvramDefaultGet keeps the default it read.
    @State private var defaultMode: String?
    /// Changes when the page is left or read again, so a read that comes back afterwards changes nothing.
    @State private var session = 0
    @State private var shown = false
    /// The rule list's create panel, while it is open.
    @State private var rulePanel: DualWANRulePanel?
    /// The rule row in edit mode, and which of its two text inputs has the focus.
    @State private var ruleEdit: DualWANRuleEdit?
    @FocusState private var editFocus: Int?
    private var connected: Bool { store.phase == .connected }

    struct ApplyRun { var start: DualWANForm; var answers: [Bool] }
    struct Question: Identifiable {
        let id = UUID()
        let text: String
        let kind: Kind
        enum Kind { case web(DualWANQuestion), switchOn, switchOff }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusPageHeader(title: "双线路", subtitle: "外部网络(WAN) - 双线路", symbol: "arrow.triangle.branch",
                                 readAt: reading.readAt, loading: reading.loading) { await load() }
                ReadErrorLabel(message: reading.error)
                if let notice { NoticeBanner(message: notice.message, tone: notice.tone) }
                if !connected {
                    ConnectionRequiredView()
                } else if let page = reading.value, let form {
                    if !page.problems.isEmpty {
                        NoticeBanner(message: "本应用只显示这一页，不提供应用：\n" + page.problems.joined(separator: "\n"), tone: .attention)
                    }
                    Group {
                        intro(page, form)
                        basic(page, form)
                        watchdog(page, form)
                        if form.routingTableShown { routing(form) }
                        if form.routingRulesShown { rules(form) }
                    }.disabled(sent || busy || reading.loading || !page.problems.isEmpty)
                    HStack {
                        Text("页面上的改动只在本页；点“应用本页面设置”并确认后才会写入路由器，写入后路由器通常会重新启动。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("应用本页面设置") { startApply() }.buttonStyle(.borderedProminent).tint(.teal)
                            .disabled(sent || busy || reading.loading || run != nil || !page.problems.isEmpty)
                    }
                } else {
                    ReadingPlaceholder(failed: reading.error != nil && !reading.loading, minHeight: 220)
                }
            }.padding(28).disabled(store.operationTitle != nil)
        }
        .task(id: connected) { if connected, reading.value == nil { await load() } }
        .onAppear { shown = true }
        .onDisappear { shown = false; session += 1; busy = false; run = nil }
        .alert("请确认", isPresented: Binding(get: { question != nil }, set: { if !$0, question != nil { answer(false) } }), presenting: question) { _ in
            Button("确定") { answer(true) }
            Button("取消", role: .cancel) { answer(false) }
        } message: { question in Text(question.text) }
        .alert("注意", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("好") {}
        } message: { Text(alert ?? "") }
        .confirmationDialog("应用双线路设置？", isPresented: Binding(get: { sending != nil }, set: { if !$0 { sending = nil } }), titleVisibility: .visible) {
            if let submission = sending { Button("应用设置", role: .destructive) { sending = nil; send(submission) } }
        } message: { Text(sending.map(impact) ?? "") }
        .onChange(of: editFocus) { old, _ in if let old { leaveEdit(old) } }
        .sheet(isPresented: Binding(get: { rulePanel != nil }, set: { if !$0 { rulePanel = nil } })) {
            DualWANRulePanelSheet(panel: Binding(get: { rulePanel ?? DualWANRulePanel() }, set: { if rulePanel != nil { rulePanel = $0 } }),
                                  confirm: confirmRule, cancel: { rulePanel = nil })
                .frame(minWidth: 420)
        }
        .sheet(isPresented: $standbyShown) {
            if form != nil {
                HotStandbyPanel(form: Binding(get: { form! }, set: { form = $0 })) { changing in
                    standbyShown = false
                    guard var next = form else { return }
                    let submission = next.answerStandby(changing: changing)
                    form = next
                    // The page submits at once; the app asks first.
                    afterSheetCloses { sending = submission }
                }.frame(minWidth: 480)
            }
        }
    }

    /// A read replaces the form only when it brought new values, and none starts while an apply is under way.
    private func load() async {
        guard run == nil, sending == nil else { return }
        session += 1
        let mine = session, before = reading.readAt
        await reading.load(store: store) { try await $0.dualWANPage() }
        guard session == mine, !Task.isCancelled, let page = reading.value, reading.readAt != before else { return }
        form = DualWANForm(page: page)
        sent = false; run = nil; busy = false; defaultMode = nil; askedReboot = false; rulePanel = nil; ruleEdit = nil
    }

    // MARK: Sections

    private func intro(_ page: DualWANPage, _ form: DualWANForm) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("外部网络(WAN) - 双线路").font(.title3.weight(.semibold))
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(page.model) 支持双线路。选择“故障转移”模式设定第二 WAN 为备用网络。选择“负载均衡”模式可以同时为两个网络优化带宽，最大化流通量，最小化响应时间，并防止数据溢出。")
                    .fixedSize(horizontal: false, vertical: true)
            }.font(.callout)
            if let url = page.dualWANFAQ { Link("双线路 FAQ", destination: url).font(.callout) }
            if form.aggregationNoteShown {
                HStack(spacing: 0) {
                    Text("欲启用 WAN Aggregation，请至 ")
                    Button("WAN-互联网连接") { store.open(section: "wan0") }.buttonStyle(.link)
                    Text(" 页面。")
                }.font(.callout).foregroundStyle(.orange)
            }
        }
    }

    private func basic(_ page: DualWANPage, _ form: DualWANForm) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                Text("基本设置").font(.headline)
                row("开启双线路") {
                    Toggle("开启双线路", isOn: Binding(get: { form.curState == "1" }, set: { requestSwitch($0) })).labelsHidden().toggleStyle(.switch)
                }
                if form.primaryRowShown {
                    row("首选 WAN") {
                        HStack {
                            picker(form.primary) { index in update { $0.choose(primary: true, index: index) } }
                            if form.lanport1Shown { picker(form.lanport1) { index in update { $0.chooseLANPort(primary: true, index: index) } } }
                        }
                    }
                }
                if form.secondRowShown {
                    row("第二 WAN") {
                        HStack {
                            picker(form.second) { index in update { $0.choose(primary: false, index: index) } }.disabled(form.second.disabled)
                            if form.lanport2Shown { picker(form.lanport2) { index in update { $0.chooseLANPort(primary: false, index: index) } } }
                        }
                    }
                }
                if form.usbTetheringShown {
                    row("4G / 5G 自动移动网络共享") {
                        if form.usbTetheringHint {
                            Text("切换到 USB 作为主 WAN 时，4G / 5G 自动移动网络共享将不可用。").font(.callout).fixedSize(horizontal: false, vertical: true)
                        } else {
                            Picker("", selection: Binding(get: { form.usbBackup ?? "" }, set: { value in update { $0.setUSBBackup(value) } })) {
                                Text("是").tag("1"); Text("否").tag("0")
                            }.pickerStyle(.radioGroup).horizontalRadioGroupLayout().labelsHidden()
                        }
                    }
                }
                if form.modeRowShown {
                    row("双线路模式") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 12) {
                                Picker("", selection: Binding(get: { form.modeSelect.value }, set: { mode in update { $0.chooseMode(mode) } })) {
                                    ForEach(form.modeSelect.options, id: \.value) { Text($0.text).tag($0.value) }
                                }.labelsHidden().fixedSize()
                                if form.fbSpanShown {
                                    Toggle("允许故障恢复", isOn: Binding(get: { form.fbChecked }, set: { on in update { $0.setFailback(on) } })).toggleStyle(.checkbox)
                                }
                            }
                            if form.lbNoteShown {
                                Text("负载均衡模式能最大限度地优化资源和增加吞吐量， 提高首选 WAN 和第二 WAN 的性能，并提供相同的网络速度。")
                                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                if form.ratioRowShown {
                    row("负载均衡设置") {
                        HStack(spacing: 6) {
                            textField(form.ratio0.value, limit: 1, digits: true, width: 40) { value in update { $0.setRatio(first: true, value) } }
                            Text(":")
                            textField(form.ratio1.value, limit: 1, digits: true, width: 40) { value in update { $0.setRatio(first: false, value) } }
                        }
                    }
                }
            }
        }
    }

    private func watchdog(_ page: DualWANPage, _ form: DualWANForm) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("自动检测网络连接").font(.headline)
                    HStack(spacing: 0) {
                        Text("详细信息请访问")
                        if let url = page.detectionFAQ { Link("华硕支持网站常见问题解答", destination: url) } else { Text("华硕支持网站常见问题解答") }
                        Text("，帮助您有效使用此功能。")
                    }.font(.callout).italic()
                }
                row("时间间隔") {
                    HStack(spacing: 6) {
                        Text("每")
                        textField(form.interval, limit: 2, digits: true, width: 50, placeholder: "5") { value in update { $0.interval = value } }
                        Text("秒")
                    }
                }
                row(form.failoverWording ? "故障转移触发条件" : "Internet 连接诊断") {
                    sentence(form.failoverWording ? "当前 WAN 网络连续尝试连接网络 $WANDOG_MAXFAIL 次失败后，将会转移至备用 WAN 网络。"
                                                  : "当目前的广域网络连续 $WANDOG_MAXFAIL 次失败时，将被视为断线。", placeholder: "$WANDOG_MAXFAIL") {
                        textField(form.maxfail, limit: 2, digits: true, width: 50, placeholder: "5") { value in update { $0.maxfail = value } }
                    }
                }
                if form.fbCountRowShown {
                    row("故障恢复触发条件") {
                        if let count = form.fbCount {
                            sentence("当首选 WAN 被连续 $WANDOG_FB_COUNT 次检测为使用物理网线成功连接至网络，则会切换至首选WAN。", placeholder: "$WANDOG_FB_COUNT") {
                                textField(count, limit: 2, digits: true, width: 50, placeholder: "5") { value in update { $0.setFailbackCount(value) } }
                            }
                        } else {
                            Text("当首选 WAN 被连续 $WANDOG_FB_COUNT 次检测为使用物理网线成功连接至网络，则会切换至首选WAN。").font(.callout)
                        }
                    }
                }
                row("网络监控") {
                    HStack(spacing: 16) {
                        Toggle("DNS 查询", isOn: Binding(get: { form.dnsProbeChecked }, set: { on in update { $0.setDNSProbe(on) } })).toggleStyle(.checkbox)
                        Toggle("Ping", isOn: Binding(get: { form.pingChecked }, set: { on in update { $0.setPing(on) } })).toggleStyle(.checkbox)
                    }
                }
                if form.dnsProbeHostShown {
                    row("分析目标") {
                        textField(form.dnsProbeHost.value, limit: 255, digits: false, width: 300) { value in update { $0.setDNSProbeHost(value) } }
                    }
                }
                if form.wandogTargetShown {
                    row("Ping 目标") {
                        HStack(spacing: 6) {
                            textField(form.wandogTarget.value, limit: 100, digits: false, width: 260, placeholder: "ex: www.google.com") { value in
                                update { $0.setPingTarget(value) }
                            }
                            Menu {
                                if form.pingTargets.isEmpty { Text("（列表为空）") }
                                ForEach(form.pingTargets) { target in
                                    Button(target.label) { update { $0.setPingTarget(target.address) } }.disabled(!target.selectable)
                                }
                            } label: { Image(systemName: "chevron.up.chevron.down") }
                                .menuStyle(.borderlessButton).fixedSize().help("选择互联网服务。")
                        }
                    }
                }
            }
        }
    }

    private func routing(_ form: DualWANForm) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                Text("双线路路由规则").font(.headline)
                row("开启路由规则") {
                    Picker("", selection: Binding(get: { form.routingEnable.checked ?? "" }, set: { value in update { $0.setRoutingEnabled(value) } })) {
                        Text("是").tag("1"); Text("否").tag("0")
                    }.pickerStyle(.radioGroup).horizontalRadioGroupLayout().labelsHidden().disabled(form.routingEnable.disabled)
                }
            }
        }
    }

    private func rules(_ form: DualWANForm) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("路由规则 ( 最多限制： \(DualWANRuleField.maximum) )").font(.headline)
                    Spacer()
                    Button { addRule() } label: { Image(systemName: "plus.circle") }.buttonStyle(.borderless).help("新增")
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("来源 IP"); Text("目的 IP"); Text("WAN 模块"); Text("删除")
                    }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if form.rules.isEmpty {
                        GridRow { Text("目前没有数据").foregroundStyle(.orange).gridCellColumns(4) }
                    }
                    ForEach(Array(form.rules.enumerated()), id: \.offset) { index, rule in
                        GridRow(alignment: .top) {
                            if let edit = ruleEdit, edit.row == index {
                                editCell(edit, 0)
                                editCell(edit, 1)
                                editUnit(edit, rule)
                            } else {
                                ForEach(0..<3, id: \.self) { column in
                                    cell(rule, column, select: column == 2).contentShape(Rectangle()).onTapGesture { beginEdit(index, column) }
                                }
                            }
                            HStack(spacing: 8) {
                                Button { deleteRule(index) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless).help("删除（应用本页面设置后才保存）")
                                if ruleEdit?.row == index {
                                    Button("完成") { finishEdit() }.buttonStyle(.borderless).disabled(!(ruleEdit?.canFinish ?? true) && editFocus == nil)
                                }
                            }
                        }
                    }
                }
                Text("点击规则的栏位可修改；离开栏位时与网页一样检查并改写（地址去掉前导零、改为小写）。新增、修改、删除只改本页的列表，点“应用本页面设置”后才写入路由器。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// genContent_frame (table.js 991–1078): the WAN 模块 column shows the option's name for 0 and 1, every column is cut to
    /// 26 characters and ".." past 28, with the whole text as its hint.
    private func cell(_ rule: [String], _ column: Int, select: Bool) -> some View {
        var text = column < rule.count ? rule[column] : ""
        if select { text = ["0": "首选 WAN", "1": "第二 WAN"][text] ?? text }
        let units = Array(text.utf16)
        let shown = units.count > 28 ? String(decoding: units.prefix(26), as: UTF16.self) + ".." : text
        return Text(shown).font(.callout).monospacedDigit().help(units.count > 28 ? text : "")
    }

    /// A text input of the row in edit mode (genEditRuleText, table.js 1197–1258) with its hint.
    @ViewBuilder private func editCell(_ edit: DualWANRuleEdit, _ column: Int) -> some View {
        if column < edit.values.count {
            VStack(alignment: .leading, spacing: 3) {
                TextField("", text: Binding(get: { ruleEdit?.values[column] ?? "" }, set: { typed in
                    guard var current = ruleEdit, current.values.indices.contains(column) else { return }
                    current.values[column] = DualWANRuleField.edited(current.values[column], typed, key: KeyPressEvent.typedCharacter,
                                                                      replaced: KeyPressEvent.replacedRange(current.values[column], typed))
                    ruleEdit = current
                // Return does nothing here: keyPress refuses it (tableValidator.js 413–475).
                })).textFieldStyle(.roundedBorder).frame(width: 170).monospacedDigit().focused($editFocus, equals: column)
                if let hint = edit.hints[column] { Text(hint).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            }
        } else {
            Text("")
        }
    }

    /// The row's WAN 模块 list (genEditRuleSelect, table.js 1260–1326).
    @ViewBuilder private func editUnit(_ edit: DualWANRuleEdit, _ rule: [String]) -> some View {
        if edit.values.count > 2 {
            Picker("", selection: Binding(get: { ruleEdit?.values[2] ?? "" }, set: { value in
                guard var current = ruleEdit, var next = form else { return }
                let refused = next.changeRuleUnit(&current, value)
                form = next; ruleEdit = current
                if let refused { alert = refused }
            })) {
                ForEach(DualWANRuleField.units, id: \.value) { Text($0.text).tag($0.value) }
            }.labelsHidden().fixedSize()
        } else {
            cell(rule, 2, select: true)
        }
    }

    /// A click on a cell (table.js 1154–1172): the row goes into edit mode with that input focused; while a row is in edit
    /// mode, a click on another row's cell only takes the focus from the input being edited (its blur).
    private func beginEdit(_ row: Int, _ column: Int) {
        if ruleEdit != nil, let focused = editFocus { editFocus = nil; leaveEdit(focused) }
        guard ruleEdit == nil, let edit = form?.editRule(at: row) else { return }
        ruleEdit = edit
        if column < 2, column < edit.values.count { editFocus = column }
    }

    /// Leaving a text input of the row in edit mode: the page's blur checks, and the value into the list when they pass.
    private func leaveEdit(_ column: Int) {
        guard var edit = ruleEdit, var next = form else { return }
        next.leaveRuleEdit(&edit, column: column)
        form = next; ruleEdit = edit
    }
    /// What clicking elsewhere does: the focused input is left first (its blur), then edit mode ends unless a hint shows
    /// (registerBodyEvent, table.js 1088–1112).
    private func finishEdit() {
        if let column = editFocus { editFocus = nil; leaveEdit(column) }
        if ruleEdit?.canFinish ?? false { ruleEdit = nil }
    }
    private func deleteRule(_ index: Int) {
        if let column = editFocus { editFocus = nil; leaveEdit(column) }
        update { $0.deleteRule(at: index) }
        ruleEdit = nil
    }
    /// 新增 (genAddRule_frame, table.js 437–479): nothing while a row shows a hint, the limit alert, or the create panel. The
    /// click then reaches the page's body handler, which ends an edit (registerBodyEvent).
    private func addRule() {
        if let column = editFocus { editFocus = nil; leaveEdit(column) }
        guard let form, ruleEdit?.canFinish ?? true else { return }
        ruleEdit = nil
        if let text = form.ruleAddAlert { alert = text } else { rulePanel = DualWANRulePanel() }
    }
    /// The create panel's 确认: the rule goes into the list and the list is drawn again (ending an edit), or the panel stays.
    private func confirmRule() -> DualWANRuleOutcome {
        guard var panel = rulePanel, var next = form else { return .hint }
        let outcome = next.addRule(&panel)
        form = next; rulePanel = panel
        if outcome == .done { rulePanel = nil; ruleEdit = nil }
        return outcome
    }

    // MARK: Controls

    private func row(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label).font(.callout).frame(width: 180, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    /// A select by option index; nothing shows selected when the page selected no option.
    private func picker(_ select: DualWANSelect, choose: @escaping (Int) -> Void) -> some View {
        Picker("", selection: Binding(get: { select.selected ?? -1 }, set: { if $0 >= 0 { choose($0) } })) {
            ForEach(Array(select.options.enumerated()), id: \.offset) { index, option in Text(option.text).tag(index) }
        }.labelsHidden().fixedSize()
    }

    /// A text field with the page's maxlength (typing past it is refused; a longer value as read stays). Where the page
    /// filters key presses with validator.isNumber a typed key that is not a digit does nothing; pasted text stays and meets
    /// the checks of 应用本页面设置. Line breaks are dropped as an input drops them.
    private func textField(_ value: String, limit: Int, digits: Bool, width: CGFloat, placeholder: String = "",
                           set: @escaping (String) -> Void) -> some View {
        TextField(placeholder, text: Binding(get: { value }, set: { new in
            let text = String(new.unicodeScalars.filter { $0 != "\n" && $0 != "\r" }.map(Character.init))
            set(WebValidator.edit(value, text, typed: KeyPressEvent.typedCharacter, maxLength: limit,
                                 replaced: KeyPressEvent.replacedRange(value, new), keyPress: WebValidator.numberKeyPress(digits)))
        })).textFieldStyle(.roundedBorder).frame(width: width).monospacedDigit()
    }

    /// A dictionary sentence with an input in place of its placeholder.
    private func sentence(_ text: String, placeholder: String, @ViewBuilder field: () -> some View) -> some View {
        let parts = text.components(separatedBy: placeholder)
        return HStack(spacing: 4) {
            Text(parts[0])
            field()
            if parts.count > 1 { Text(parts.dropFirst().joined(separator: placeholder)).fixedSize(horizontal: false, vertical: true) }
        }.font(.callout)
    }

    private func update(_ change: (inout DualWANForm) -> Void) {
        guard var next = form else { return }
        change(&next)
        form = next
    }

    // MARK: The switch (2126–2196)

    private func requestSwitch(_ on: Bool) {
        guard let form, !busy, run == nil else { return }
        if on, form.curState != "1" {
            if let text = form.switchOnQuestion { question = Question(text: text, kind: .switchOn) } else { proceedSwitch(on: true) }
        } else if !on, form.curState == "1" {
            if form.switchOffStops { alert = "网页的脚本在这里出错（以太网 WAN 列表中没有默认 WAN），开关没有变化。"; return }
            if let text = form.switchOffQuestion { question = Question(text: text, kind: .switchOff) } else { proceedSwitch(on: false) }
        }
    }

    /// The callback past its question: the default wans_mode (and, turning off with usb_bk, wans_usb_bk_act) is read as the
    /// page reads it, then the form changes. Only reads; nothing is written.
    private func proceedSwitch(on: Bool) {
        guard let start = form else { return }
        let mine = session
        busy = true
        Task { @MainActor in
            defer { if session == mine { busy = false } }
            do {
                let client = try store.connectedClient()
                var mode = ""
                if !on || start.switchOnReadsDefaultMode {
                    if let cached = defaultMode { mode = cached } else {
                        mode = try await client.dualWANDefaultMode()
                        if !mode.isEmpty { defaultMode = mode }
                    }
                }
                let active = !on && start.page.usbBackupSupported ? try await client.dualWANUSBBackupActive() : ""
                guard session == mine, !Task.isCancelled, var next = form else { return }
                if on { next.switchOn(defaultMode: mode) } else { next.switchOff(defaultMode: mode, usbBackupActive: active) }
                form = next
                // form_show(1) draws the rule list again (show_wans_rules), which ends an edit.
                if on { ruleEdit = nil }
            } catch {
                guard session == mine else { return }
                notice = ("开关没有完成：\(error.localizedDescription)", .error)
                store.handleManagementError(error)
            }
        }
    }

    // MARK: 应用本页面设置 (700–1262)

    private func startApply() {
        // Clicking the button leaves the rule input being edited first (its blur runs before applyRule); the click then ends
        // the edit unless a hint shows (registerBodyEvent).
        if let column = editFocus { editFocus = nil; leaveEdit(column) }
        if ruleEdit?.canFinish ?? false { ruleEdit = nil }
        guard let form, !busy, run == nil else { return }
        run = ApplyRun(start: form, answers: [])
        askedReboot = false
        step()
    }

    /// applyRule again from the form as it was, with the answers given so far, up to the next question or its end.
    private func step() {
        guard let current = run else { return }
        let (next, outcome) = current.start.applying(current.answers)
        switch outcome {
        case .confirm(let text, let kind):
            // The page's own text; before the reboot question the app adds what it means here.
            let shown = kind == .reboot ? text + "\n\n" + rebootImpact(wait: reading.value?.rebootWait ?? "", dpi: false) : text
            question = Question(text: shown, kind: .web(kind))
            return
        case .cancelled:
            break
        case .alert(let text):
            alert = text
        case .stopped(let reason):
            alert = "网页的脚本在这里停止，没有发送任何设置：" + reason
        case .hotStandby:
            standbyShown = true
        case .submit(let submission):
            if askedReboot { send(submission) } else { sending = submission }
        }
        // What applyRule changed before it ended stays in the form, as on the page.
        form = next
        run = nil
    }

    private func answer(_ yes: Bool) {
        guard let asked = question else { return }
        question = nil
        switch asked.kind {
        case .web(let kind):
            if kind == .reboot { askedReboot = yes }
            run?.answers.append(yes)
            // An alert closes before the next one can open.
            afterSheetCloses { step() }
        case .switchOn: if yes { proceedSwitch(on: true) }
        case .switchOff: if yes { proceedSwitch(on: false) }
        }
    }

    private func rebootImpact(wait: String, dpi: Bool) -> String {
        "本应用说明：确认后发送网页的同一张表单（start_apply.htm）。若设置有变化，路由器会" + (dpi ? "先停用 AiProtection 网络神盾（DPI 引擎），再" : "")
            + "重新启动，约 \(wait) 秒内所有连接的设备断网，恢复后本应用重新读取核对。例外：只改了线路组合（其他设置都没变），并且是移除作为第二 WAN 的 USB 线路、保留原来的主 WAN，或在没有插 USB 调制解调器时给单条线路加上 USB 线路，路由器只重启多路连接（start_multipath，约 10 秒），不整机重启（web.c 4813–4831、4888、5993–6016）；USB 原本是主 WAN 时移除它仍会整机重启。设置没有变化时路由器什么也不执行。"
    }
    private func impact(_ submission: DualWANSubmission) -> String {
        "网页在这一步不再询问就提交（action_script=\(submission.actionScript)）。" + rebootImpact(wait: "\(submission.wait)", dpi: submission.disablesDPI)
    }

    private func send(_ submission: DualWANSubmission) {
        guard store.beginOperation("正在应用双线路设置") else { return }
        // One write: once sent it is not taken back, so it is not cancelled with the page.
        Task { @MainActor in
            var readAgain = false, wentOut = false
            do {
                let client = try store.connectedClient()
                // The uptime before the write tells a restart from none afterwards; without one it is read first.
                var uptime = store.snapshot?.sample.uptime ?? 0
                if uptime == 0, let read = try? await client.sample().uptime { uptime = read }
                switch try await client.submitDualWAN(submission) {
                case .restarting:
                    // done_committing(): the variables changed; the router then runs the form's reboot, or only
                    // start_multipath when nothing but wans_dualwan changed and that removed a second-WAN USB line, or added
                    // one with no USB modem plugged in (web.c 4813–4831, 4888, 5962, 5993–6016).
                    notice = ("路由器已接收设置，正在应用（通常会重新启动，约 \(submission.wait) 秒，期间所有设备断网）；恢复后会重新读取核对。", .information)
                    sent = true; wentOut = true
                    switch await store.awaitRestart(client, from: uptime, checks: max(24, (submission.wait + 60) / 5), upFor: 9) {
                    case .back:
                        let checked = try await client.checkDualWAN(submission)
                        notice = ("路由器已重新启动并恢复连接。" + checked.message, checked.isVerified ? .success : .attention); readAgain = true
                    case .stayedUp:
                        let checked = try await client.checkDualWAN(submission)
                        notice = ("连续读取期间运行时长一直在增加，没有观察到重新启动（符合固件的 USB 线路例外时，路由器只重启多路连接）。" + checked.message, checked.isVerified ? .success : .attention); readAgain = true
                    case .signInFailed(let reason): notice = (reason, .attention)
                    case .timedOut: notice = ("路由器已接收设置，但还没有确认恢复连接。请稍后点“重新读取”核对，不要重复提交。", .attention)
                    }
                case .unchanged:
                    notice = ("路由器回复设置没有变化，没有执行重新启动。", .information)
                    readAgain = true
                case .unconfirmed:
                    notice = ("路由器已接收请求，但回复中没有确认结果，可能正在重新启动。请稍后点“重新读取”核对，不要重复提交。", .attention)
                    sent = true; wentOut = true
                }
            } catch RouterError.submissionUncertain(let reason) {
                notice = (reason, .attention); sent = true; wentOut = true
            } catch {
                notice = ("没有发送：\(error.localizedDescription)", .error)
                store.handleManagementError(error)
            }
            // What went out may have changed the WANs: the second WAN and the traffic tabs wait for them to be read again.
            if wentOut { store.wanSettingsMayHaveChanged() }
            store.endOperation()
            // A page left meanwhile is not read again.
            if readAgain, shown { await load() }
        }
    }
}

/// The hot standby panel (detect_time_confirm 2061–2094): the two texts, 重试间隔 and 重试次数 with the detection time, and
/// 是 / 否, both of which submit.
struct HotStandbyPanel: View {
    @Binding var form: DualWANForm
    let onAnswer: (Bool) -> Void
    @State private var alert: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("当启用双线路热机待命保护模式时， 一旦正常工作的线路中断或无法访问时，备份线路马上接替正常线路开始传送数据。")
                .fixedSize(horizontal: false, vertical: true)
            Text("系统将保持当前 WAN 待机状态，并将监测时间间隔缩短为 : \(form.standbyDetectionTime) 秒.")
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("重试间隔")
                    HStack(spacing: 6) {
                        // detect_interval: maxlength 1 and validator.isNumber on key press (2069).
                        TextField("5", text: Binding(get: { form.detectInterval }, set: {
                            form.detectInterval = WebValidator.edit(form.detectInterval, $0, typed: KeyPressEvent.typedCharacter, maxLength: 1,
                                                                    replaced: KeyPressEvent.replacedRange(form.detectInterval, $0),
                                                                    keyPress: WebValidator.numberKeyPress)
                        })).textFieldStyle(.roundedBorder).frame(width: 38).monospacedDigit()
                            .onSubmit { alert = form.updateStandbyTime() }
                        Text("秒")
                    }
                }
                GridRow {
                    Text("重试次数")
                    HStack(spacing: 6) {
                        Picker("", selection: Binding(get: { form.detectCount.selected ?? -1 }, set: { index in
                            guard index >= 0 else { return }
                            form.chooseDetectCount(index); alert = form.updateStandbyTime()
                        })) {
                            ForEach(Array(form.detectCount.options.enumerated()), id: \.offset) { index, option in Text(option.text).tag(index) }
                        }.labelsHidden().fixedSize()
                        Text("( Detection Time: \(form.standbyDetectionTime)  秒)")
                    }
                }
            }
            HStack {
                Spacer()
                Button("是") { onAnswer(true) }.buttonStyle(.borderedProminent).tint(.teal)
                Button("否") { onAnswer(false) }
                Spacer()
            }
            Text("网页的“是”和“否”都会提交本页设置（“是”另外把重试间隔和次数写入检测设置）；本应用在发送前会再请您确认。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .interactiveDismissDisabled()
        .alert("注意", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) { Button("好") {} } message: { Text(alert ?? "") }
    }
}

/// The rule list's create panel (genCreateRule, table.js 504–649): Create New Policy, 来源 IP and 目的 IP (maxlength 18,
/// with keyPress and the blur check of tableValidator.dualWanRoutingRules), WAN 模块, 取消 and 确认.
struct DualWANRulePanelSheet: View {
    @Binding var panel: DualWANRulePanel
    let confirm: () -> DualWANRuleOutcome
    let cancel: () -> Void
    @FocusState private var focus: Int?
    @State private var alert: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Create New Policy").font(.headline)
                Spacer()
                Button { cancel() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
            }
            Divider()
            field("来源 IP", 0, text: $panel.source, hint: panel.sourceHint)
            field("目的 IP", 1, text: $panel.destination, hint: panel.destinationHint)
            VStack(alignment: .leading, spacing: 4) {
                Text("WAN 模块").font(.callout)
                Picker("", selection: $panel.unit) {
                    ForEach(DualWANRuleField.units, id: \.value) { Text($0.text).tag($0.value) }
                }.labelsHidden().fixedSize()
            }
            Divider()
            HStack {
                Spacer()
                Button("取消") { cancel() }
                Button("确认") { submit() }.buttonStyle(.borderedProminent).tint(.teal)
            }
            Text("确认只把规则加入本页的列表；点“应用本页面设置”后才写入路由器。").font(.caption).foregroundStyle(.secondary)
        }
        .padding(22)
        // Leaving a field runs its blur check, as the page's blur handler does.
        .onChange(of: focus) { old, _ in if let old { panel.leave(old) } }
        .alert("注意", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) { Button("好") {} } message: { Text(alert ?? "") }
    }

    private func field(_ title: String, _ tag: Int, text: Binding<String>, hint: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout)
            TextField(DualWANRuleField.placeholder, text: Binding(get: { text.wrappedValue }, set: {
                text.wrappedValue = DualWANRuleField.edited(text.wrappedValue, $0, key: KeyPressEvent.typedCharacter,
                                                            replaced: KeyPressEvent.replacedRange(text.wrappedValue, $0))
            }))
                .textFieldStyle(.roundedBorder).frame(width: 330).monospacedDigit().focused($focus, equals: tag)
            if let hint { Text(hint).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
    }

    /// Clicking 确认 leaves the focused field first (its blur), then the panel's checks run.
    private func submit() {
        if let field = focus { panel.leave(field) }
        if case .alert(let text) = confirm() { alert = text }
    }
}
