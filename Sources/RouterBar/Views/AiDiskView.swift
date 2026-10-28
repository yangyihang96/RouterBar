import RouterCore
import SwiftUI

// USB 相关应用 › AiDisk（aidisk.asp 及其向导 aidisk/Aidisk-1～4.asp）。欢迎页照网页判断 USB 磁盘和以前的设置；第二至四步照网页的
// 显示、校验和提示。会改变路由器的请求都先请用户确认：进入第三步（载入 Aidisk-3.asp 会清掉 DDNS 返回码）、华硕 DDNS 注册，以及
// 最后的“保存”（重置帐户与权限、创建 Family、切换 FTP 共享方式、开启 FTP、DDNS 开关）。确认后按网页先后发送同样的表单，再重新
// 读取核对；离开页面即不再读取，也不再检查注册结果。没有确认插有 USB 硬盘时只显示网页的说明，不提供向导。

struct AiDiskView: View {
    @Environment(RouterStore.self) var store
    @StateObject private var reading = RouterReading<AiDiskPage>()
    enum Step: Equatable { case welcome, share, ddns, finish }
    @State private var step: Step = .welcome
    /// The welcome page as last read: aidisk.asp with Aidisk-1, or Aidisk-1 again after 上一步.
    @State private var welcome: AiDiskPage?
    /// aidisk.asp's forms and window values, which the steps change through `parent.`.
    @State private var wizard: AiDiskWizard?
    @State private var share: AiDiskShareStep?
    @State private var shareForm: AiDiskShareStep.Form?
    @State private var ddns: AiDiskDDNSStep?
    @State private var ddnsForm: DDNSForm?
    @State private var finish: AiDiskFinishStep?
    @State private var confirming: Pending?
    @State private var alert: String?
    @State private var notice: (message: String, tone: NoticeBanner.Tone)?
    /// A step's own read is running.
    @State private var stepping = false
    /// Changes when the page is left or read again, so an answer that comes back afterwards changes nothing.
    @State private var session = 0
    @State private var shown = false
    @FocusState private var nameFocused: Bool
    private var connected: Bool { store.phase == .connected }

    /// Aidisk-3's form as it stands.
    struct DDNSForm: Equatable {
        /// check_asus_ddns: 我愿意使用此服务 (c1, checked by default) or 关闭 DDNS (c2).
        var agree = true
        var name: String
        /// alert_block under the name (hidden until shown; nothing hides it again).
        var blockAlert: String?
        /// loadingIcon.
        var loading = false
        /// The script's ddns_return_code.
        var code: String
    }

    /// A request waiting for the user's confirmation.
    struct Pending: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let button: String
        let destructive: Bool
        let action: Action
        enum Action {
            /// Loading Aidisk-3.asp, from step 2 with passTheResult's parent fields, or back from step 4.
            case openDDNS(AiDiskRequest, AiDiskShareStep.Next?)
            case register(AiDiskRequest, name: String)
            case save(AiDiskWizard, admin: String)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusPageHeader(title: "AiDisk", subtitle: "USB 相关应用 › AiDisk 向导：以 FTP 与华硕 DDNS 共享 USB 硬盘", symbol: "externaldrive.badge.wifi",
                                 readAt: reading.readAt, loading: reading.loading) { await load() }
                ReadErrorLabel(message: reading.error)
                if let notice { NoticeBanner(message: notice.message, tone: notice.tone) }
                if !connected {
                    ConnectionRequiredView()
                } else if let page = welcome {
                    switch step {
                    case .welcome: welcomeStep(page)
                    case .share: if let share, let shareForm { shareStep(share, shareForm) }
                    case .ddns: if let ddns, let ddnsForm { ddnsStep(ddns, ddnsForm) }
                    case .finish: if let finish, let wizard { finishStep(finish, wizard) }
                    }
                } else {
                    ReadingPlaceholder(failed: notice?.tone == .error, minHeight: 220)
                }
            }.padding(28).disabled(store.operationTitle != nil || reading.loading || stepping)
        }
        .environment(\.openURL, OpenURLAction { url in
            // The page's “这里” links open the DDNS and FTP pages of the web; here their native pages.
            switch url.absoluteString {
            case "routerbar-aidisk:ftp": store.open(section: "ftp"); return .handled
            case "routerbar-aidisk:ddns": store.open(section: "ddns"); return .handled
            default: return .systemAction
            }
        })
        .task(id: connected) { if connected, welcome == nil { await load() } }
        .onAppear { shown = true }
        .onDisappear { shown = false; session += 1 }
        .confirmationDialog(confirming?.title ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { pending in
            Button(pending.button, role: pending.destructive ? .destructive : nil) { run(pending) }
        } message: { pending in Text(pending.message) }
        .alert("注意", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) { Button("好") {} } message: { Text(alert ?? "") }
    }

    // MARK: Reading

    /// aidisk.asp as it opens: the welcome page, with its forms as initial() leaves them.
    private func load() async {
        session += 1
        let mine = session
        let before = reading.readAt
        await reading.load(store: store) { try await $0.aiDiskPage() }
        guard session == mine, !Task.isCancelled, reading.readAt != before, let page = reading.value else { return }
        wizard = page.startWizard()
        showWelcome(page)
    }

    private func showWelcome(_ page: AiDiskPage) {
        welcome = page; step = .welcome
        share = nil; shareForm = nil; ddns = nil; ddnsForm = nil; finish = nil
        if case .configured(let links) = page.content, links.exception { alert = AiDiskText.exception }
    }

    /// A step's read (Aidisk-1, -2 or -4 only render what they read); dropped when the page was left meanwhile.
    private func readStep<Value: Sendable>(_ read: @escaping @Sendable (RouterClient) async throws -> Value, then show: @escaping (Value) -> Void) {
        guard !stepping else { return }
        stepping = true
        let mine = session
        Task { @MainActor in
            do {
                let value = try await read(try store.connectedClient())
                if shown, session == mine { show(value) }
            } catch {
                if shown, session == mine { notice = ("读取没有完成：\(error.localizedDescription)", .error) }
                store.handleManagementError(error)
            }
            stepping = false
        }
    }

    // MARK: Welcome (Aidisk-1.asp)

    @ViewBuilder private func welcomeStep(_ page: AiDiskPage) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(AiDiskText.welcomeTitle).font(.title3.weight(.semibold))
                    Spacer()
                    Button { store.open(.usbApplications) } label: { Image(systemName: "arrow.uturn.backward.circle").font(.title3) }
                        .buttonStyle(.borderless).help(AiDiskText.usbApplications)
                }
                Divider()
                switch page.content {
                case .noDisk:
                    Text(AiDiskText.noDisk).font(.headline).foregroundStyle(.orange)
                case .introduction:
                    introduction(page)
                case .unsupported:
                    introduction(page)
                    NoticeBanner(message: "这台路由器的 aidisk.asp 没有 get_AiDisk_status() 的结果（不支持 USB 应用）：网页欢迎页的脚本在第一行出错，只留下这段介绍。本页不提供设置。", tone: .attention)
                case .scriptError(let reason):
                    introduction(page)
                    NoticeBanner(message: reason + "本页只显示，不提供设置。", tone: .attention)
                case .unknownDisks:
                    introduction(page)
                    NoticeBanner(message: "无法读取 USB 磁盘列表（require/modules/diskList.js），网页的磁盘判断不会执行，只留下这段介绍。没有确认插有 USB 硬盘，本页不提供设置。", tone: .attention)
                case .configured(let links):
                    configured(page, links)
                }
            }.font(.callout)
        }
        if page.offersWizard {
            HStack(alignment: .top, spacing: 16) {
                Text("网页的欢迎页没有显示开始按钮：Aidisk-1.asp 定义了 go_next_page()，但页面上没有按钮调用它，网页要用 aidisk.asp?page=2 打开第二步。这里的“下一步”就是这个入口。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(AiDiskText.next) { startShare() }.buttonStyle(.borderedProminent).tint(.teal)
            }
        }
    }

    /// AiDiskWelcome_desp (140–153).
    private func introduction(_ page: AiDiskPage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AiDiskText.introduction)
            bullet(linked((AiDiskText.createDDNS + " ", AiDiskText.modifyLink, AiDiskText.modifySuffix), "ddns"))
            bullet(linked((AiDiskText.setupFTP + " ", AiDiskText.modifyLink, AiDiskText.modifySuffix), "ftp"))
            bullet(Text(AiDiskText.addresses))
            VStack(alignment: .leading, spacing: 4) {
                Text("◦ " + AiDiskText.internetAddress + " ftp://[hostname].asuscomm.com")
                Text("◦ " + AiDiskText.lanAddress + " " + page.lanAddress)
            }.padding(.leading, 28).textSelection(.enabled)
            Text("*** " + AiDiskText.hostnameNote).padding(.leading, 12)
        }.fixedSize(horizontal: false, vertical: true)
    }

    /// linkdiskbox (155–173) as show_share_link fills it.
    private func configured(_ page: AiDiskPage, _ links: AiDiskAccessLinks) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AiDiskText.configuredTitle)
            if links.anonymousHint { bullet(Text(AiDiskText.anonymousHint)) }
            switch links.hint {
            case .ftpOff?: bullet(linked(AiDiskText.ftpOff, "ftp"))
            case .ddnsOff?: bullet(Text(AiDiskText.ddnsOff))
            case .notRegistered?: bullet(Text(AiDiskText.notRegistered))
            case nil: if let internet = links.internet { bullet(Text(internet).font(.system(.callout, design: .monospaced))) }
            }
            if let lan = links.lan { bullet(Text(lan).font(.system(.callout, design: .monospaced))) }
            bullet(linked(AiDiskText.moreConfig, "ftp"))
            bullet(linked(AiDiskText.authorityHint, "ftp"))
        }.fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }

    private func bullet(_ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) { Text("•"); text.fixedSize(horizontal: false, vertical: true) }
    }

    /// A dictionary text whose middle part is the page's link, opening the native page of `target`.
    private func linked(_ parts: (String, String, String), _ target: String) -> Text {
        linked(parts, url: URL(string: "routerbar-aidisk:" + target))
    }
    private func linked(_ parts: (String, String, String), url: URL?) -> Text {
        var link = AttributedString(parts.1)
        link.link = url
        link.underlineStyle = .single
        return Text(AttributedString(parts.0) + link + AttributedString(parts.2))
    }

    /// The step pictures (step1–3.png), the current one lit.
    private func progress(_ current: Int) -> some View {
        HStack(spacing: 10) {
            ForEach(1...3, id: \.self) { number in
                Text("\(number)").font(.headline).frame(width: 28, height: 28)
                    .background(number == current ? Color.teal : Color.primary.opacity(0.08), in: Circle())
                    .foregroundStyle(number == current ? Color.white : Color.secondary)
                if number < 3 { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
            }
        }
    }

    private func radio(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle").foregroundStyle(selected ? Color.teal : Color.secondary)
                Text(title).foregroundStyle(.primary)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    /// go_next_page (105–108) loads Aidisk-2.asp, which only renders what it reads.
    private func startShare() {
        readStep({ try await $0.aiDiskShareStep() }) { read in
            guard var parent = wizard else { return }
            let form = read.initialForm(&parent)
            wizard = parent; share = read; shareForm = form; step = .share
        }
    }

    // MARK: Share method (Aidisk-2.asp)

    private func shareStep(_ page: AiDiskShareStep, _ form: AiDiskShareStep.Form) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                progress(1)
                Text(AiDiskText.shareTitle).font(.title3.weight(.semibold))
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(page.options, id: \.self) { option in
                        radio(AiDiskText.methods[option] ?? option, selected: form.option == option) { choose(option) }
                    }
                }.padding(.leading, 8)
                if form.anonymousHint { Text(AiDiskText.anonymousHint).foregroundStyle(.yellow).padding(.leading, 33) }
                if form.table { accounts(form) }
                Divider()
                HStack {
                    Spacer()
                    Button(AiDiskText.previous) { backToWelcome() }
                    Button(AiDiskText.next) { shareNext(page) }.buttonStyle(.borderedProminent).tint(.teal)
                }
            }
        }
    }

    /// share1: the account table with target1 and target2 (227–250).
    private func accounts(_ form: AiDiskShareStep.Form) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
            GridRow {
                Text(AiDiskText.account).bold(); Text(AiDiskText.password).bold(); Text(AiDiskText.read).bold(); Text(AiDiskText.write).bold()
            }
            Divider().gridCellColumns(4)
            if form.adminRow {
                GridRow { Text(form.user1); Text("*"); check; check }
            }
            if form.familyRow {
                GridRow {
                    Text(form.user2)
                    TextField("", text: passwordBinding).textFieldStyle(.roundedBorder).frame(width: 220)
                        .autocorrectionDisabled()
                    check
                    Text("")
                }
            }
        }.padding(.leading, 33)
    }
    private var check: some View { Image(systemName: "checkmark.square.fill").foregroundStyle(.teal) }

    /// userpasswd2: a text input with maxlength 32 whose key presses go through validator.isString (245): a key above 126
    /// is refused with its alert; pasted text is not filtered, and the browser drops line breaks from a text input.
    private var passwordBinding: Binding<String> {
        Binding(get: { shareForm?.password ?? "" }, set: { new in
            guard var form = shareForm else { return }
            let old = form.password, typed = KeyPressEvent.typedCharacter
            if let typed, !WebValidator.isStringKeyPress(typed) { alert = WebValidator.invalidCharacter }
            let cleaned = String(String.UnicodeScalarView(new.unicodeScalars.filter { $0 != "\n" && $0 != "\r" }))
            form.password = WebValidator.edit(old, cleaned, typed: typed, maxLength: 32, replaced: KeyPressEvent.replacedRange(old, new)) { value, key in
                WebValidator.isStringKeyPress(key) ? value : nil
            }
            shareForm = form
        })
    }

    /// A click on a choice, the checked one included (onclick → showTextinWizard).
    private func choose(_ option: String) {
        guard let page = share, var form = shareForm, var parent = wizard else { return }
        page.select(option, &form, wizard: &parent)
        shareForm = form; wizard = parent
    }

    /// 上一步 (go_pre_page 143–146) loads Aidisk-1.asp again: its own reads, with the parent's FTP status as it was.
    private func backToWelcome() {
        let status = welcome?.status
        readStep({ try await $0.aiDiskWelcome(status: status) }) { page in showWelcome(page) }
    }

    /// 下一步 (passTheResult 85–141).
    private func shareNext(_ page: AiDiskShareStep) {
        guard let form = shareForm else { return }
        let next = page.next(form)
        switch next {
        case .invalid(let message):
            // The alert, then the form posted back to Aidisk-2.asp, which opens with its defaults again.
            alert = message
            if var parent = wizard { shareForm = page.initialForm(&parent); wizard = parent }
        case .proceed(_, _, _, _, let request):
            confirming = Pending(title: "进入第三步（DDNS）？", message: Self.openingMessage(request), button: "继续", destructive: false,
                                 action: .openDDNS(request, next))
        }
    }

    static func openingMessage(_ request: AiDiskRequest) -> String {
        "与网页一样，进入这一步要载入 /aidisk/Aidisk-3.asp（POST" + (request.fields.isEmpty ? "，无栏位" : "，带上一步表单的栏位") + "）。"
            + "路由器生成这一页时读取 DDNS 注册返回码 ddns_return_code，只要它不是 ddns_query 就把它清空（只改运行状态，不写入闪存）。"
            + "在这个时点发送，是因为第三步要显示上一次注册的结果，而清空后接下来的注册检查不会读到旧结果。不改变任何 DDNS 或共享设置。\n\n"
            + "发送（与网页相同）：" + describe(request)
    }

    // MARK: DDNS (Aidisk-3.asp)

    private func ddnsStep(_ page: AiDiskDDNSStep, _ form: DDNSForm) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                progress(2)
                Text(AiDiskText.ddnsTitle).font(.title3.weight(.semibold))
                VStack(alignment: .leading, spacing: 10) {
                    radio(AiDiskText.ddnsAgree, selected: form.agree) { switchDDNS(true) }
                    if form.agree {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 4) {
                                TextField("", text: nameBinding).textFieldStyle(.roundedBorder).frame(width: 220).focused($nameFocused)
                                    .autocorrectionDisabled()
                                Text(".asuscomm.com")
                            }
                            if let message = form.blockAlert { Text(message).font(.caption).foregroundStyle(.yellow).fixedSize(horizontal: false, vertical: true) }
                        }.padding(.leading, 28)
                    }
                    radio(AiDiskText.ddnsOffChoice, selected: !form.agree) { switchDDNS(false) }
                }.padding(.leading, 8)
                Divider()
                HStack {
                    Spacer()
                    if form.loading { ProgressView().controlSize(.small) }
                    Button(AiDiskText.previous) { backToShare() }
                    Button(AiDiskText.next) { ddnsNext(page) }.buttonStyle(.borderedProminent).tint(.teal)
                }
            }
        }
        // cleandef (219–222) on a click into the name field: the hint text goes.
        .onChange(of: nameFocused) { _, focused in
            if focused, ddnsForm?.name == AiDiskDDNSStep.inputHint { ddnsForm?.name = "" }
        }
    }

    /// DDNSName: no maxlength and no key filter (274); a text input drops line breaks.
    private var nameBinding: Binding<String> {
        Binding(get: { ddnsForm?.name ?? "" }, set: { new in
            ddnsForm?.name = String(String.UnicodeScalarView(new.unicodeScalars.filter { $0 != "\n" && $0 != "\r" }))
        })
    }

    private func showDDNS(_ page: AiDiskDDNSStep) {
        ddns = page
        ddnsForm = DDNSForm(name: page.initialName, blockAlert: page.initialAlert, code: page.codeAfterOpening)
        // initial() → switch_ddns() with the first choice checked (37, 41–43).
        wizard?.setDDNSEnable("1")
        step = .ddns
    }

    /// switch_ddns (40–56) on a click: the parent's DDNS choice, and the name field shown only for the first choice.
    private func switchDDNS(_ agree: Bool) {
        ddnsForm?.agree = agree
        wizard?.setDDNSEnable(agree ? "1" : "0")
    }

    /// 上一步 (go_pre_page 134–138) posts the form to Aidisk-2.asp, which opens with its defaults.
    private func backToShare() {
        readStep({ try await $0.aiDiskShareStep() }) { read in
            guard var parent = wizard else { return }
            let form = read.initialForm(&parent)
            wizard = parent; share = read; shareForm = form; ddns = nil; ddnsForm = nil; step = .share
        }
    }

    /// 下一步 (go_next_page 122–132): the name is checked and registered for the first choice; with 关闭 DDNS the page goes
    /// on to Aidisk-4.asp.
    private func ddnsNext(_ page: AiDiskDDNSStep) {
        guard let form = ddnsForm else { return }
        guard form.agree else { openFinish(); return }
        switch AiDiskDDNSStep.validate(form.name) {
        case .block(let message): ddnsForm?.blockAlert = message
        case .alert(let message): alert = message
        case .valid:
            let request = AiDiskDDNSStep.registration(name: form.name)
            confirming = Pending(title: "注册华硕 DDNS 名称？", message:
                "路由器会把 DDNS 服务器设为 WWW.ASUS.COM、主机名称设为 \(form.name).asuscomm.com，并立即向华硕 DDNS 服务器注册这个名称（aidisk_asusddns_register）。"
                + "注册结果由华硕服务器决定；之后退回上一步或离开向导都不会撤销注册。这一请求不改变 DDNS 开关 ddns_enable_x，开关在最后一步“保存”时写入。"
                + "发送后与网页一样每 0.5 秒读取一次 /ajax_ddnscode.asp，直到得到结果。\n\n发送（与网页相同）：" + Self.describe(request),
                button: "注册", destructive: false, action: .register(request, name: form.name))
        }
    }

    /// Aidisk-4.asp only renders what it reads.
    private func openFinish(registered name: String? = nil) {
        readStep({ try await $0.aiDiskFinishStep() }) { read in
            finish = read; step = .finish
            if let name {
                let wanted = name + ".asuscomm.com"
                notice = read.hostname == wanted
                    ? ("华硕 DDNS 注册成功；重新读取 ddns_hostname_x 为 \(read.hostname)，与提交的一致。", .success)
                    : ("华硕 DDNS 回报注册成功，但重新读取的 ddns_hostname_x 为“\(read.hostname)”，与提交的 \(wanted) 不一致。请稍后重新读取核对。", .attention)
            }
        }
    }

    // MARK: Finish (Aidisk-4.asp)

    private func finishStep(_ page: AiDiskFinishStep, _ parent: AiDiskWizard) -> some View {
        let display = page.display(ddnsEnable: parent.ddnsEnable)
        return Panel {
            VStack(alignment: .leading, spacing: 14) {
                progress(3)
                Text(AiDiskText.finishTitle).font(.title3.weight(.semibold))
                VStack(alignment: .leading, spacing: 8) {
                    bullet(Text(AiDiskText.shareSetting + " " + (AiDiskFinishStep.method(parent.dummyShareway) ?? "")))
                    if let internet = display.internet { bullet(Text(internet).font(.system(.callout, design: .monospaced))) }
                    if display.privateWAN { bullet(linked(AiDiskText.faq, url: AiDiskText.faqURL)) }
                    if display.ddnsOff { bullet(Text(AiDiskText.ddnsOff)) }
                }.font(.callout).textSelection(.enabled)
                Divider()
                HStack {
                    Spacer()
                    Button(AiDiskText.previous) {
                        confirming = Pending(title: "回到第三步（DDNS）？", message: Self.openingMessage(AiDiskFinishStep.back), button: "继续",
                                             destructive: false, action: .openDDNS(AiDiskFinishStep.back, nil))
                    }
                    Button(AiDiskText.finish) { confirmSave(parent) }.buttonStyle(.borderedProminent).tint(.teal)
                }
            }
        }
    }

    /// 保存 (clickevent 128–139): the whole chain, confirmed once with what each request does.
    private func confirmSave(_ parent: AiDiskWizard) {
        let admin = share?.adminName ?? ""
        let chain = parent.savingChain
        var lines: [String] = []
        for (number, request) in chain.enumerated() { lines.append("\(number + 1). " + Self.impact(request, admin: admin)) }
        let resets = chain.contains { $0.step == .initialAccount }
        let message = (resets ? "注意：这会清除路由器上现有的全部 USB 共享帐户、密码和文件夹访问权限。\n\n" : "")
            + "路由器会按网页的先后执行：\n" + lines.joined(separator: "\n")
            + "\n\n前一步由路由器回报成功后才发送下一步；某一步失败或无法确认就停止，已完成的步骤不会撤销。完成后重新读取核对。\n\n发送（与网页相同）：\n"
            + chain.map(Self.describe).joined(separator: "\n")
        confirming = Pending(title: resets ? "重置帐户并保存 AiDisk 设置？" : "保存 AiDisk 设置？", message: message, button: AiDiskText.finish,
                             destructive: resets, action: .save(parent, admin: admin))
    }

    /// What one request of the chain does on the router (web.c handlers named in the core).
    static func impact(_ request: AiDiskRequest, admin: String) -> String {
        switch request.step {
        case .initialAccount:
            return "重置帐户与访问权限（initial_account.asp）：清空全部 USB 共享帐户并写入闪存，删除每个已挂载分区上的权限文件、重建文件夹列表，只重建管理员帐户（\(admin)），然后重启 FTP 与 Samba。"
        case .createAccount:
            return "创建帐户 \(request.value("account") ?? "")（create_account.asp，密码为第二步填写的密码），并重启 FTP 与 Samba。"
        case .allFolderPermission:
            return "把 \(request.value("account") ?? "") 在所有磁盘全部文件夹的 FTP 权限设为只读（set_account_all_folder_permission.asp，permission=\(request.value("permission") ?? "")），并重启 FTP 与 Samba。"
        case .shareMode(let mode):
            let stored = request.value("dummyShareway") ?? ""
            let method = mode == "share" ? "“不需要帐号密码”（st_ftp_mode=1，任何人无需认证即可访问 FTP）" : "按帐户访问（st_ftp_mode=2）"
            return "FTP 共享方式改为\(method)（switch_share_mode.asp），dummyShareway 记为 \(stored.isEmpty ? "0" : stored)，写入闪存并强制重启 FTP；若已是这一方式，只记下 dummyShareway。"
        case .ftpOn:
            return "开启 FTP 服务（switch_AiDisk_app.asp：enable_ftp=1），写入闪存并重启 FTP。"
        case .ddnsSwitch:
            let value = request.value("ddns_enable_x") ?? ""
            return "把 DDNS 开关 ddns_enable_x 设为 \(value)（\(value == "1" ? "开启" : value == "0" ? "关闭" : "原值")，start_apply.htm），action_script 为空，不重启任何服务。"
        case .openDDNS, .registerDDNS:
            return request.summary
        }
    }

    /// The form as it is sent, password fields hidden.
    static func describe(_ request: AiDiskRequest) -> String {
        let fields = request.fields.map { field -> String in
            guard ["password", "userpasswd2", "passwd1"].contains(field.name) else { return field.name + "=" + field.value }
            return field.name + "=" + (field.value.isEmpty ? "（空）" : "（已隐藏）")
        }
        return "POST /" + request.path + (fields.isEmpty ? "（无栏位）" : "：" + fields.joined(separator: "，"))
    }

    // MARK: Writing

    private func run(_ pending: Pending) {
        confirming = nil
        switch pending.action {
        case .openDDNS(let request, let next): openDDNS(request, next)
        case .register(let request, let name): register(request, name: name)
        case .save(let parent, let admin): save(parent, admin: admin)
        }
    }

    /// Loading Aidisk-3.asp, which the router answers after clearing the return code; passTheResult writes the parent's
    /// fields before it submits.
    private func openDDNS(_ request: AiDiskRequest, _ next: AiDiskShareStep.Next?) {
        guard store.beginOperation("正在载入 AiDisk 第三步") else { return }
        if let next { wizard?.accept(next) }
        let mine = session
        Task { @MainActor in
            do {
                let page = try await store.connectedClient().openAiDiskDDNSStep(request)
                if shown, session == mine { showDDNS(page) }
            } catch {
                if shown, session == mine { notice = ("载入第三步没有完成：\(error.localizedDescription)", .error) }
                store.handleManagementError(error)
            }
            store.endOperation()
        }
    }

    /// The registration, then checkDDNSReturnCode a second later (start_apply.htm:859–861).
    private func register(_ request: AiDiskRequest, name: String) {
        guard let page = ddns, store.beginOperation("正在注册华硕 DDNS") else { return }
        ddnsForm?.loading = true
        let mine = session
        Task { @MainActor in
            var registered = false
            do {
                let client = try store.connectedClient()
                try await client.registerAiDiskDDNS(request)
                try? await Task.sleep(for: .seconds(1))
                registered = await checkRegistration(client, page, session: mine)
            } catch RouterError.submissionUncertain(let reason) {
                if shown, session == mine { notice = (reason, .attention) }
            } catch {
                if shown, session == mine { notice = ("注册请求没有完成：\(error.localizedDescription)", .error) }
                store.handleManagementError(error)
            }
            if shown, session == mine { ddnsForm?.loading = false }
            store.endOperation()
            if registered, shown, session == mine {
                wizard?.setDDNSEnable("1")
                openFinish(registered: name)
            }
        }
    }

    /// checkDDNSReturnCode (191–217): /ajax_ddnscode.asp every 500 ms while the code is ddns_query. The page asks again at
    /// once after an error, for ever; here at most 20 times half a second apart, and ddns_query for at most a minute.
    /// Returns whether the router reported the name registered.
    private func checkRegistration(_ client: RouterClient, _ page: AiDiskDDNSStep, session mine: Int) async -> Bool {
        var stamp = Int(Date().timeIntervalSince1970 * 1000), failures = 0, waits = 0
        var code = ddnsForm?.code ?? ""
        while shown, session == mine {
            stamp += 1
            do {
                if let read = try await client.aiDiskDDNSCode(stamp: stamp) { code = read }
                failures = 0
            } catch is CancellationError {
                return false
            } catch RouterError.authenticationRequired {
                notice = ("登录已失效，注册结果尚未读取。请重新连接后在 DDNS 页面核对，不要重复提交。", .attention)
                store.handleManagementError(RouterError.authenticationRequired)
                return false
            } catch {
                failures += 1
                if failures >= 20 { notice = ("注册请求已发送，但读取注册结果失败（\(error.localizedDescription)）。请稍后重新读取核对，不要重复提交。", .attention); return false }
                try? await Task.sleep(for: .milliseconds(500)); continue
            }
            ddnsForm?.code = code
            switch page.outcome(code) {
            case .waiting:
                waits += 1
                if waits >= 120 { notice = ("一分钟后注册结果仍是“处理中”（ddns_query）。请稍后重新读取核对，不要重复提交。", .attention); return false }
                try? await Task.sleep(for: .milliseconds(500))
            case .registered:
                return true
            case .failed(let hint):
                // check_return_code: the hint under the name, and the script's code emptied.
                ddnsForm?.code = ""
                if let hint { ddnsForm?.blockAlert = hint }
                else { notice = ("注册请求已发送，但读到的返回码“\(code)”没有对应提示：网页此时不显示任何内容并停留在本步。注册结果尚未确认，请稍后重新读取核对，不要重复提交。", .attention) }
                return false
            }
        }
        return false
    }

    /// The chain; afterwards start_apply.htm sends the browser to /aidisk.asp, so the page is read again from its start.
    /// Once sent, the chain goes on even if the page is left (stopping halfway would leave the accounts reset).
    private func save(_ parent: AiDiskWizard, admin: String) {
        guard store.beginOperation("正在按 AiDisk 向导保存") else { return }
        Task { @MainActor in
            var readAgain = false
            do {
                let result = try await store.connectedClient().saveAiDisk(parent, adminName: admin)
                notice = (result.receipt.message, result.receipt.isVerified ? .success : .attention); readAgain = true
            } catch {
                notice = ("保存没有完成：\(error.localizedDescription)", .error)
                store.handleManagementError(error)
            }
            store.endOperation()
            if readAgain, shown { await load() }
        }
    }
}
