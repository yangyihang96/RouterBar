import RouterCore
import SwiftUI

// 网络设置向导（QIS_wizard.htm）。页面、文字、显示条件和每一步的读写都由 RouterCore 的 QISWizard 照网页决定，运行顺序、代次和
// 发送由 QISController 负责；这里只负责画出当前一页、把输入和按钮交给它、把每个写入和有副作用的请求先给用户确认。不做原生的
// 分支给出原因和在浏览器打开同一向导的按钮（带同样的 flag）。

struct QISWizardView: View {
    @Environment(RouterStore.self) var store
    @Environment(\.openURL) private var openURL
    @StateObject private var controller = QISController()
    @State private var entry = ""
    @State private var reachedEnd = false
    private var connected: Bool { store.phase == .connected }
    /// The connection the page works with: another one, even without a disconnect in between, is a new session.
    private var connection: ObjectIdentifier? { connected ? (try? store.connectedClient()).map(ObjectIdentifier.init) : nil }

    static let entries: [(flag: String, title: String)] = [
        ("", "从网页菜单进入（欢迎页）"), ("manual", "manual：操作模式"), ("pppoe", "pppoe：PPPoE 帐号"), ("wireless", "wireless：无线设置"),
        ("changePass", "changePass：本地登录（管理员账号）"), ("lanip", "lanip：无线访问点的 LAN IP"), ("mlo", "mlo：MLO 无线设置"),
        ("EULA", "EULA：最终用户许可协议"), ("PP", "PP：ASUS 隐私声明"), ("rtMode", "rtMode：无线路由器模式")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "网络设置向导", subtitle: "按路由器网页向导（QIS_wizard.htm）的步骤设置上网方式、Wi-Fi 和管理员账号。每个写入都先确认。", symbol: "wand.and.stars")
                if let notice = controller.notice { NoticeBanner(message: notice.message, tone: Self.tone(notice.tone)) }
                if !connected {
                    ConnectionRequiredView()
                } else {
                    entryBar
                    if !controller.asked.isEmpty { effectCard }
                    if let busy = controller.busy { ProgressView(busy).frame(maxWidth: .infinity, alignment: .leading) }
                    if let wizard = controller.wizard {
                        page(wizard).disabled(controller.busy != nil || store.operationTitle != nil)
                    } else if controller.loading {
                        ProgressView("正在读取…").frame(maxWidth: .infinity, minHeight: 200)
                    }
                }
            }.padding(28)
        }
        .task(id: connection) {
            controller.host = store
            if connection == nil { controller.disconnected() }
            else if controller.wizard == nil { if !controller.loading { controller.start(flag: entry) } }
            else { controller.resume() }
        }
        // Leaving the page ends what it started, as leaving the web page ends its scripts.
        .onDisappear { controller.stop() }
        // The policy text's scroll state belongs to its page.
        .onChange(of: controller.wizard?.page) { _, _ in reachedEnd = false }
        .alert("注意", isPresented: Binding(get: { !controller.alerts.isEmpty }, set: { if !$0 { controller.dismissAlert() } })) {
            Button("确定") {}
        } message: { Text(controller.alerts.first ?? "") }
        .alert("请确认", isPresented: Binding(get: { controller.question != nil }, set: { _ in })) {
            Button("确定") { controller.answer(true) }
            Button("取消", role: .cancel) { controller.answer(false) }
        } message: { Text(controller.question?.text ?? "") }
        .sheet(item: Binding(get: { controller.submission.map { SubmissionItem(id: controller.submissionID, submission: $0) } },
                             set: { if $0 == nil { controller.cancelSubmission() } })) { item in
            QISSubmitSheet(submission: item.submission, onCancel: { controller.cancelSubmission() }, onSend: { controller.confirmSubmission() })
        }
        .sheet(isPresented: $controller.withdrawShown) {
            // The answer is taken when the button is pressed and runs once the notice has closed, only if the page, the wizard
            // and the connection it was given on are still the ones shown.
            PolicyWithdrawSheet(version: privacyVersion,
                                onKnowRisk: { if let answer = controller.deferAnswer(.choose("knowRisk")) { afterSheetCloses { controller.perform(answer) } } },
                                onReadAgain: { if let answer = controller.deferAnswer(.choose("readAgain")) { afterSheetCloses { controller.perform(answer) } } })
        }
    }

    private struct SubmissionItem: Identifiable { let id: UUID; let submission: QISSubmission }
    private var privacyVersion: String { if case .privacy(let status)? = controller.wizard?.page { status.privacyVersion } else { "" } }
    static func tone(_ tone: QISNotice.Tone) -> NoticeBanner.Tone {
        switch tone {
        case .success: .success
        case .information: .information
        case .attention: .attention
        case .error: .error
        }
    }

    // MARK: Entry

    private var entryBar: some View {
        HStack(spacing: 10) {
            Text("入口").font(.callout).foregroundStyle(.secondary)
            Picker("", selection: $entry) { ForEach(Self.entries, id: \.flag) { Text($0.title).tag($0.flag) } }.labelsHidden().fixedSize()
            Button("重新开始") { controller.start(flag: entry) }.disabled(controller.loading || controller.busy != nil || store.operationTitle != nil)
            Spacer()
            Button("在浏览器中打开网页向导") { openBrowser(flag: controller.wizard?.flag ?? entry) }.buttonStyle(.link)
        }
    }

    private func openBrowser(flag: String?) {
        let query = flag.map { [URLQueryItem(name: "flag", value: $0)] } ?? []
        if let url = store.endpoint?.resource("QIS_wizard.htm", query: query) { openURL(url) }
    }

    // MARK: The page's own requests

    private var effectCard: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                Text("网页在这一步会自动发送以下请求").font(.headline)
                ForEach(controller.asked, id: \.self) { effect in
                    Text("• " + Self.describe(effect)).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                Text("选择“照网页发送”后，本次向导里网页再次自动发送的同类请求（例如侦测结果需要时重新启动侦测）也照样发送；选择“不发送”则本次向导都不发送，自动侦测可能停在“侦测中”，可改用“手动设置”。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("不发送") { controller.decide(send: false) }
                    Button("照网页发送") { controller.decide(send: true) }.buttonStyle(.borderedProminent).tint(.teal)
                }
            }
        }
    }
    static func describe(_ effect: QISEffect) -> String {
        switch effect {
        case .autoDetect: "重新启动 WAN 自动侦测：GET /appGet.cgi?hook=start_force_autodet()（路由器后台重新侦测联机类型；对当前上网的影响未经实机确认）。"
        case .auto46Detect: "重新启动日本 IPv6 侦测：GET /appGet.cgi?hook=restart_auto46det()。"
        case .liveUpdate: "固件在线检查：路由器联网后 POST /applyapp.cgi（action_mode=apply、webs_update_trigger=QIS、rc_service=start_webs_update、skip_modify_flag=1），路由器向 ASUS 服务器检查新固件，只检查、不升级；之后每秒读取检查结果。"
        }
    }

    // MARK: Pages

    @ViewBuilder private func page(_ w: QISWizard) -> some View {
        let screen = w.screen
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(screen.title).font(.title3.weight(.semibold))
                    ForEach(Array(screen.subtitles.enumerated()), id: \.offset) { Text($0.element).font(.callout).foregroundStyle(.secondary) }
                }
                switch w.page {
                case .eula, .privacy: policy(w, screen)
                case .wireless: generic(w, screen, wireless: true)
                case .update: update(w, screen)
                case .summary: summary(w, screen)
                case .browser(let branch): browser(w, branch, screen)
                default: generic(w, screen, wireless: false)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func paragraphs(_ screen: QISScreen) -> some View {
        ForEach(Array(screen.paragraphs.enumerated()), id: \.offset) { Text($0.element).font(.callout).fixedSize(horizontal: false, vertical: true) }
    }

    @ViewBuilder private func generic(_ w: QISWizard, _ screen: QISScreen, wireless: Bool) -> some View {
        paragraphs(screen)
        if wireless, let inputs = w.form.wireless {
            ForEach(inputs) { input in wirelessInputs(w, input) }
        }
        ForEach(screen.fields) { field in fieldRow(w, field) }
        ForEach(screen.toggles) { toggle in
            Toggle(toggle.title, isOn: Binding(get: { toggle.on }, set: { controller.perform(.toggle(toggle.id, $0)) })).toggleStyle(.checkbox)
        }
        if !screen.choices.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(screen.choices) { choice in
                    Button { controller.perform(.choose(choice.id)) } label: {
                        HStack { Text(choice.title); Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
                            .padding(.vertical, 8).padding(.horizontal, 12).contentShape(Rectangle())
                    }.buttonStyle(.plain).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        ForEach(Array(screen.notes.enumerated()), id: \.offset) { Text($0.element).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        buttons(screen)
    }

    @ViewBuilder private func buttons(_ screen: QISScreen) -> some View {
        if screen.back != nil || screen.next != nil {
            HStack {
                if let back = screen.back { Button(back) { controller.perform(.back) } }
                Spacer()
                if let next = screen.next { Button(next) { controller.perform(.next) }.buttonStyle(.borderedProminent).tint(.teal) }
            }.padding(.top, 6)
        }
    }

    /// An input with the page's maxlength and key filter; typing goes to the wizard at once, its change handler runs before
    /// the next button.
    @ViewBuilder private func fieldRow(_ w: QISWizard, _ field: QISFieldSpec) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(field.title).font(.callout)
            let value = w.form.value(field.id)
            let binding = Binding<String>(get: { value }, set: { new in
                let text = String(new.unicodeScalars.filter { $0 != "\n" && $0 != "\r" }.map(Character.init))
                let edited = WebValidator.edit(value, text, typed: KeyPressEvent.typedCharacter, maxLength: field.maxLength,
                                               replaced: KeyPressEvent.replacedRange(value, new),
                                               keyPress: field.ipFilter ? { QISCheck.ipAddressKeyPress($0, $1) } : nil)
                controller.edit(field.id, edited)
            })
            Group {
                if field.secure { SecureField("", text: binding) } else { TextField("", text: binding) }
            }.textFieldStyle(.roundedBorder).frame(maxWidth: 360).disabled(!field.enabled)
            if let hint = w.hints[field.id] { Text(hint).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
    }

    @ViewBuilder private func wirelessInputs(_ w: QISWizard, _ input: QISWirelessInput) -> some View {
        let titles = w.wirelessTitles(input)
        VStack(alignment: .leading, spacing: 4) {
            Text(titles.ssid).font(.callout)
            TextField("", text: Binding(get: { input.ssid }, set: { new in
                controller.editWireless(input.unit, ssid: true, WebValidator.edit(input.ssid, new, typed: KeyPressEvent.typedCharacter, maxLength: 33,
                                                                                  replaced: KeyPressEvent.replacedRange(input.ssid, new)))
            })).textFieldStyle(.roundedBorder).frame(maxWidth: 360)
            if let hint = w.wirelessHints["ssid:" + input.unit] { Text(hint).font(.caption).foregroundStyle(.orange) }
            Text(titles.key).font(.callout)
            SecureField("", text: Binding(get: { input.key }, set: { new in
                controller.editWireless(input.unit, ssid: false, WebValidator.edit(input.key, new, typed: KeyPressEvent.typedCharacter, maxLength: 64,
                                                                                   replaced: KeyPressEvent.replacedRange(input.key, new)))
            })).textFieldStyle(.roundedBorder).frame(maxWidth: 360)
            if let hint = w.wirelessHints["key:" + input.unit] { Text(hint).font(.caption).foregroundStyle(.red) }
        }
    }

    @ViewBuilder private func policy(_ w: QISWizard, _ screen: QISScreen) -> some View {
        paragraphs(screen)
        if let document = w.policyDocument {
            QISPolicyText(document: document, language: w.language, reachedEnd: $reachedEnd).frame(height: 360)
        } else {
            // No text for this version: no 同意 or 拒绝 (RouterCore ignores them too), only the explanation and the browser.
            ForEach(Array(screen.notes.enumerated()), id: \.offset) { NoticeBanner(message: $0.element, tone: .attention) }
            HStack {
                Spacer()
                Button("在浏览器中打开网页向导" + (w.browserFlag.map { "（flag=\($0)）" } ?? "")) { openBrowser(flag: w.browserFlag) }
            }
        }
        if case .eula = w.page {
            if !reachedEnd { Text("请滚动到底部").font(.caption).foregroundStyle(.secondary) }
            Toggle("我已满 16 岁。", isOn: Binding(get: { w.form.eulaAge }, set: { controller.perform(.toggle("eulaAge", $0)) })).toggleStyle(.checkbox)
            HStack { Spacer(); Button("同意") { controller.perform(.next) }.buttonStyle(.borderedProminent).tint(.teal).disabled(!reachedEnd) }
        } else if let refuse = screen.back, let agree = screen.next {
            HStack {
                Spacer()
                Button(refuse) { controller.perform(.choose("disagree")) }
                Button(agree) { controller.perform(.next) }.buttonStyle(.borderedProminent).tint(.teal)
            }
        }
        Text("网页右上角的语言切换会改写路由器的界面语言（preferred_lang），这里不提供。").font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private func update(_ w: QISWizard, _ screen: QISScreen) -> some View {
        paragraphs(screen)
        let versions = w.updateVersions
        LabeledContent("当前版本", value: versions.current)
        LabeledContent("最新版本", value: versions.latest)
        Text("Asuswrt-Merlin 移除了向导的升级按钮；固件升级请在“系统管理 › 固件升级”进行。").font(.caption).foregroundStyle(.secondary)
        buttons(screen)
    }

    @ViewBuilder private func summary(_ w: QISWizard, _ screen: QISScreen) -> some View {
        paragraphs(screen)
        ForEach(w.form.wireless ?? []) { input in
            let titles = w.wirelessTitles(input)
            LabeledContent(titles.ssid, value: input.ssid)
            LabeledContent(titles.key, value: input.key).textSelection(.enabled)
        }
        if let iot = w.summaryIoT {
            Text(iot.title).font(.callout.weight(.semibold)).padding(.top, 4)
            LabeledContent(iot.ssidTitle, value: iot.ssid)
            LabeledContent(iot.keyTitle, value: iot.key).textSelection(.enabled)
        }
        HStack {
            Spacer()
            Button("完成") { controller.close(); store.open(.overview) }.buttonStyle(.borderedProminent).tint(.teal).disabled(!controller.finished)
        }
    }

    @ViewBuilder private func browser(_ w: QISWizard, _ branch: QISBranch, _ screen: QISScreen) -> some View {
        paragraphs(screen)
        Text("这一部分请在路由器网页的网络设置向导中完成。在浏览器中打开时需要在浏览器登录路由器；路由器同一时间只允许一个管理员登录，可能会让 App 的连接失效。")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        HStack {
            if controller.beforeBranch != nil { Button("返回向导上一页") { controller.returnFromBranch() } }
            Spacer()
            Button("在浏览器中打开网页向导" + (w.browserFlag.map { "（flag=\($0)）" } ?? "")) { openBrowser(flag: w.browserFlag) }
                .buttonStyle(.borderedProminent).tint(.teal)
        }
    }
}

/// The app's side of the wizard: the session, the operation lock, the restart wait and the saved login after chpass.cgi.
extension RouterStore: QISHost {
    func qisClient() throws -> RouterClient { try connectedClient() }
    var qisOperationInProgress: Bool { operationTitle != nil }
    func qisBeginOperation(_ title: String) -> Bool { beginOperation(title) }
    func qisEndOperation() { endOperation() }
    func qisSettingsMayHaveChanged() { routerSettingsMayHaveChanged() }
    func qisManagementError(_ error: Error) { handleManagementError(error) }
    func qisAdministratorMayHaveChanged() { wizardMayHaveChangedAdministrator() }
    func qisAdministratorUnchanged() { wizardDidNotChangeAdministrator() }
    func qisAdministratorChanged() { administratorChangedByWizard() }
    var qisUptime: TimeInterval { snapshot?.sample.uptime ?? 0 }
    func qisAwaitRestart(_ client: RouterClient, from uptime: TimeInterval, checks: Int) async -> QISRestartWait {
        switch await awaitRestart(client, from: uptime, checks: checks) {
        case .back: .back
        case .signInFailed(let reason): .signInFailed(reason)
        case .timedOut, .stayedUp: .notConfirmed
        }
    }
    func qisOpenMLOPage() { open(.mlo) }
}


/// The confirmation for an event's requests: what changes, and each request as it will be sent (secrets masked).
struct QISSubmitSheet: View {
    let submission: QISSubmission
    let onCancel: () -> Void
    let onSend: () -> Void
    @State private var showsRequests = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(submission.title).font(.title3.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(submission.impact).font(.callout).fixedSize(horizontal: false, vertical: true)
                    DisclosureGroup("将发送的请求（\(submission.requests.count) 个，按顺序）", isExpanded: $showsRequests) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(submission.requests.enumerated()), id: \.offset) { index, request in
                                Text("\(index + 1). " + request.summary).font(.caption.monospaced()).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    Text("发送后会重新读取核对；读不到时请稍后重新读取，不要重复提交。").font(.caption).foregroundStyle(.secondary)
                }
            }.frame(minHeight: 160, maxHeight: 380)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { onCancel() }.keyboardShortcut(.cancelAction)
                Button("确认发送") { onSend() }.buttonStyle(.borderedProminent).tint(.teal)
            }
        }.padding(22).frame(width: 600)
    }
}

/// The policy text of the QIS policy page, with the end of the scroll reported (PolicyScrollDiv's checkScrollHeight).
struct QISPolicyText: View {
    let document: PolicyDocument
    let language: String
    @Binding var reachedEnd: Bool
    @State private var viewport: CGFloat = 0
    private struct EndOffset: PreferenceKey {
        static let defaultValue: CGFloat = .infinity
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if !block.marker.isEmpty { Text(block.marker).monospacedDigit() }
                        Text(block.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            .fontWeight(block.bold || block.kind == .title ? .semibold : .regular)
                    }
                    .font(.callout)
                    .padding(.leading, CGFloat(block.depth) * 18)
                }
                GeometryReader { geometry in Color.clear.preference(key: EndOffset.self, value: geometry.frame(in: .named("qisPolicy")).minY) }.frame(height: 1)
            }.padding(12)
        }
        .coordinateSpace(name: "qisPolicy")
        .background(GeometryReader { geometry in Color.clear.onAppear { viewport = geometry.size.height }.onChange(of: geometry.size.height) { _, height in viewport = height } })
        .onPreferenceChange(EndOffset.self) { bottom in if viewport > 0, bottom <= viewport + 1 { reachedEnd = true } }
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }
}
