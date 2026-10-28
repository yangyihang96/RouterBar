import RouterCore
import SwiftUI

// 1.13：AiCloud 2.0 与其“设置”页的原生版本。两个开关、“应用本页面设置”与“解锁”都先请用户确认，再发送网页的同一张表单
// （start_apply.htm，等待 3 秒后重新读取核对）。AiCloud 2.0 页打开后与网页一样检查 WAN 是否为私有地址（get_real_ip.asp）。

// MARK: - AiCloud 2.0

struct AiCloudView: View {
    @Environment(RouterStore.self) var store
    @Environment(\.openURL) private var openURL
    @StateObject private var reading = RouterReading<AiCloudPage>()
    @State private var confirming: AiCloudPage.Switch?
    @State private var notice: (message: String, tone: NoticeBanner.Tone)?
    /// AiCloud_privateIP_notes, once show_warning_message has decided.
    @State private var privateNote = false
    @State private var checker: Task<Void, Never>?
    /// Changes when the page is left or read again, so a read that comes back afterwards starts nothing.
    @State private var session = 0
    @State private var shown = false
    private var connected: Bool { store.phase == .connected }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusPageHeader(title: "AiCloud 2.0", subtitle: "AiCloud 2.0 个人云 2.0 应用", symbol: "icloud",
                                 readAt: reading.readAt, loading: reading.loading) { await load() }
                ReadErrorLabel(message: reading.error)
                if let notice { NoticeBanner(message: notice.message, tone: notice.tone) }
                if !connected {
                    ConnectionRequiredView()
                } else if let page = reading.value {
                    if page.redirects {
                        // cloud_main.asp 24–25: the page goes to cloud__main.asp before anything of it runs.
                        NoticeBanner(message: "这台路由器的 start_aicloud 为 0：网页一打开就转到 cloud__main.asp（这一版固件没有这个页面），不会停留在 AiCloud 2.0 页，所以这里也不提供本页的内容与开关。", tone: .attention)
                    } else if page.builtIn {
                        overview(page)
                        functions(page)
                    } else {
                        NoticeBanner(message: "这台路由器的 AiCloud 不是内置功能（没有 cloudsync），网页改用安装 AiCloud 应用到 USB 磁盘的流程；本应用没有实现这个安装流程，请在路由器网页中操作。", tone: .attention)
                    }
                } else {
                    ReadingPlaceholder(failed: reading.error != nil && !reading.loading, minHeight: 220)
                }
            }.padding(28)
        }
        .task(id: connected) { if connected, reading.value == nil { await load() } }
        .onAppear { shown = true }
        .onDisappear { shown = false; session += 1; checker?.cancel(); checker = nil }
        .confirmationDialog(confirming.map(title) ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible) {
            if let target = confirming { Button(reading.value.map { isOn(target, $0) } == true ? "关闭" : "开启") { toggle(target) } }
        } message: { Text(confirming.flatMap { target in reading.value.map { message(target, $0) } } ?? "") }
    }

    private func load() async {
        checker?.cancel(); checker = nil; privateNote = false
        session += 1
        let mine = session
        await reading.load(store: store) { try await $0.aiCloudPage() }
        guard shown, session == mine, !Task.isCancelled, let page = reading.value, page.builtIn, !page.redirects, !page.scriptStops else { return }
        checkPrivateAddress(page)
    }

    /// show_warning_message (172–199), one second after initial(): with realip and no load balancing, get_real_ip.asp up to
    /// five times, three seconds apart, until the router has its answer (a failed read is tried again at once on the page,
    /// here a second later); then the answer, or validator.isPrivateIP of the WAN address.
    private func checkPrivateAddress(_ page: AiCloudPage) {
        checker = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            var answer: (external: Int, answered: Bool)?
            // The check runs getrealip.sh on the router: only where the app may write (RouterClient.realIP).
            if page.checksRealIP, store.writeScope.allowsReferenceWeb {
                var remaining = 5
                while remaining > 0, answer?.answered != true {
                    if remaining < 5 { try? await Task.sleep(for: .seconds(3)) }
                    if Task.isCancelled || !store.writeScope.allowsReferenceWeb { break }
                    guard store.operationTitle == nil, let client = try? store.connectedClient(), let read = try? await client.realIPCheck() else {
                        try? await Task.sleep(for: .seconds(1)); continue
                    }
                    answer = read; remaining -= 1
                }
            }
            if !Task.isCancelled { privateNote = page.showsPrivateNote(realIP: answer) }
        }
    }

    private func overview(_ page: AiCloudPage) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("AiCloud 2.0").font(.headline)
                    Spacer()
                    Button("如何设置") { openFAQ(page) }.buttonStyle(.link)
                }
                Text("华硕 AiCloud 个人云 2.0 应用让您在互联网连接的情况下能够随时随地查看您的数据。它能够连接至您的家庭网络及在线存储服务，并让您通过 iOS 或 Android 移动设备的 AiCloud 移动应用程序或网页浏览器中的个性化网络链接访问您的数据，让您所有数据随时随地尽在掌握。")
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 0) {
                            Text("• 请下载")
                            if let url = store.endpoint?.resource("cert.crt") { Link("证书", destination: url).fontWeight(.bold) } else { Text("证书") }
                            Text("并将其安装到“受信任的根证书授权”存储区。")
                        }
                        access(page)
                        HStack(spacing: 6) {
                            Text("• 查找常见问题解答")
                            Link("GO", destination: AiCloudPage.faq).fontWeight(.bold)
                        }
                    }
                    Spacer()
                    VStack(alignment: .leading, spacing: 8) {
                        Link(page.isCN ? "Android App" : "Google Play", destination: page.androidApp)
                        Link("App Store", destination: AiCloudPage.iosApp)
                    }
                }.font(.callout)
                if privateNote {
                    Text("无线路由器当前正在使用私人 WAN IP 地址。\n此路由器可能处于多 NAT 环境下，并且通过 WAN 访问 AiCloud 功能不可用。")
                        .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// accessMethod (initial 70–129).
    @ViewBuilder private func access(_ page: AiCloudPage) -> some View {
        switch page.access {
        case .local(let url):
            Text("• 进入 AiCloud 个人云 2.0 应用 " + url).textSelection(.enabled)
        case .ddns(let url):
            VStack(alignment: .leading, spacing: 4) {
                Text("• 进入 AiCloud 个人云 2.0 应用 " + url).textSelection(.enabled)
                HStack(spacing: 0) {
                    Text("  要修改动态域名(DDNS) 名称，请点击")
                    Button("这里") { store.open(section: "ddns") }.buttonStyle(.link).fontWeight(.bold)
                    Text("。")
                }
            }
        case .asusDomain(let url, let stopped):
            VStack(alignment: .leading, spacing: 4) {
                Text("• 进入 AiCloud 个人云 2.0 应用 " + url).textSelection(.enabled)
                if stopped {
                    Text("  AiCloud 的 HTTPS 端口不是 443：网页在这里写入一个不存在的链接而出错，注册提示、私有地址检查和隐藏“智能同步”都没有执行。")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 0) {
                        Text("  点击 ")
                        Button("此处") { store.open(section: "ddns") }.buttonStyle(.link).fontWeight(.bold)
                        Text(" 注册一个华硕动态域名，使得您可以从网络上访问你的个人云。")
                    }
                }
            }
        }
    }

    private func functions(_ page: AiCloudPage) -> some View {
        VStack(spacing: 12) {
            row("云端硬盘", symbol: "externaldrive.connected.to.line.below", detail: Text("开启透过互联网分享 USB 已联机的存储设备。")) {
                Toggle("云端硬盘", isOn: Binding(get: { page.cloudDiskOn }, set: { _ in confirming = .cloudDisk })).labelsHidden().toggleStyle(.switch)
            }
            row("智能访问", symbol: "desktopcomputer", detail: Text("开启从远端访问网上邻居的电脑和设备。智能访问同样可以唤醒睡眠的电脑。")) {
                Toggle("智能访问", isOn: Binding(get: { page.smartAccessOn }, set: { _ in confirming = .smartAccess })).labelsHidden().toggleStyle(.switch)
            }
            if page.showsSmartSync {
                row("智能同步", symbol: "arrow.triangle.2.circlepath",
                    detail: Text("开启 USB 存储设备和云服务器同步，如") + Text("[华硕 Webstorage](https://www.asuswebstorage.com/navigate/)") + Text(" 或其他已启用的 AiCloud 2.0 网络。")) {
                    Button("前往设置") { if let url = store.endpoint?.resource("cloud_sync.asp") { openURL(url) } }
                        .help("这台路由器的菜单没有“智能同步”页，按钮在浏览器打开路由器的 cloud_sync.asp")
                }
            }
        }.disabled(store.operationTitle != nil)
    }

    private func row(_ title: String, symbol: String, detail: Text, @ViewBuilder control: () -> some View) -> some View {
        Panel {
            HStack(spacing: 16) {
                VStack(spacing: 6) {
                    Image(systemName: symbol).font(.title2).foregroundStyle(.teal)
                    Text(title).font(.callout.weight(.semibold))
                }.frame(width: 110)
                Divider()
                detail.font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                control()
            }
        }
    }

    private func isOn(_ target: AiCloudPage.Switch, _ page: AiCloudPage) -> Bool {
        target == .cloudDisk ? page.cloudDiskOn : page.smartAccessOn
    }
    private func title(_ target: AiCloudPage.Switch) -> String {
        let on = reading.value.map { isOn(target, $0) } ?? false
        return (on ? "关闭" : "开启") + (target == .cloudDisk ? "云端硬盘？" : "智能访问？")
    }
    private func message(_ target: AiCloudPage.Switch, _ page: AiCloudPage) -> String {
        let fields = Dictionary(page.fields(toggling: target), uniquingKeysWith: { _, last in last })
        return "路由器会把 webdav_aidisk 设为 \(fields["webdav_aidisk"] ?? "")、webdav_proxy 设为 \(fields["webdav_proxy"] ?? "")、enable_webdav 设为 \(fields["enable_webdav"] ?? "")，并重启 AiCloud 服务（restart_webdav）。"
    }

    private func toggle(_ target: AiCloudPage.Switch) {
        confirming = nil
        guard let page = reading.value, !page.redirects, store.beginOperation("正在保存 AiCloud 设置") else { return }
        // One write: once sent it is not taken back, so it is not cancelled with the page; a page left meanwhile is not
        // read again (it would start the page's checks).
        Task { @MainActor in
            var readAgain = false
            do {
                let receipt = try await store.connectedClient().submitAiCloudForm(page.fields(toggling: target), verifying: ["webdav_aidisk", "webdav_proxy", "enable_webdav"])
                notice = (receipt.message, receipt.isVerified ? .success : .attention); readAgain = true
            } catch RouterError.submissionUncertain(let reason) {
                notice = (reason, .attention); readAgain = true
            } catch {
                notice = ("保存没有完成：\(error.localizedDescription)", .error)
                store.handleManagementError(error)
            }
            // A page read waits for no operation, so the operation ends first.
            store.endOperation()
            if readAgain, shown { await load() }
        }
    }

    /// 如何设置 (show_feature_desc(`<#HOWTOSETUP#>`)): the FAQ the router's collected_FAQ.json gives cloud_main.asp.
    private func openFAQ(_ page: AiCloudPage) {
        Task { @MainActor in
            guard let number = try? await store.connectedClient().faqNumber(page: "cloud_main.asp"),
                  let url = AsusSupportLink.faq(number, lang: page.values["preferred_lang"] ?? "") else {
                notice = ("路由器的 FAQ 列表中没有这一页的条目。", .attention); return
            }
            openURL(url)
        }
    }
}

// MARK: - AiCloud 2.0 › 设置

struct AiCloudSettingsView: View {
    @Environment(RouterStore.self) var store
    @StateObject private var reading = RouterReading<AiCloudSettings>()
    @State private var draft: AiCloudSettings.Draft?
    @State private var alert: String?
    @State private var confirming: Pending?
    @State private var notice: (message: String, tone: NoticeBanner.Tone)?
    private var connected: Bool { store.phase == .connected }

    /// What was confirmed, with the form as it was then.
    enum Pending: Equatable { case apply(AiCloudSettings.Draft), unlock(AiCloudSettings.Draft) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusPageHeader(title: "AiCloud 2.0 - 设置", subtitle: "AiCloud 2.0 个人云 2.0 应用", symbol: "lock.icloud",
                                 readAt: reading.readAt, loading: reading.loading) { await load() }
                ReadErrorLabel(message: reading.error)
                if let notice { NoticeBanner(message: notice.message, tone: notice.tone) }
                if !connected {
                    ConnectionRequiredView()
                } else if let settings = reading.value, let draft {
                    protection(settings, draft)
                    ports(draft)
                    HStack {
                        Spacer()
                        Button("应用本页面设置") { apply(settings, draft) }.buttonStyle(.borderedProminent).tint(.teal)
                    }
                } else {
                    ReadingPlaceholder(failed: reading.error != nil && !reading.loading, minHeight: 220)
                }
            }.padding(28).disabled(store.operationTitle != nil || reading.loading)
        }
        .task(id: connected) { if connected, reading.value == nil { await load() } }
        .alert("注意", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("好") {}
        } message: { Text(alert ?? "") }
        .confirmationDialog(confirming?.unlocks == true ? "解锁 AiCloud 帐户？" : "应用 AiCloud 设置？",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
            if let pending = confirming { Button(pending.unlocks ? "解锁" : "应用") { submit(pending) } }
        } message: {
            Text(confirming?.unlocks == true
                 ? "路由器会把 webdav_acc_lock 设为 0，并与网页一样连同本页当前填写的其他栏位一起提交（不做检查），然后重启 AiCloud 服务（\(reading.value?.service ?? "")）。"
                 : "路由器会保存密码保护与两个端口的设置，并重启 AiCloud 服务（\(reading.value?.service ?? "")），约 3 秒。")
        }
    }

    private func load() async {
        let before = reading.readAt
        await reading.load(store: store) { try await $0.aiCloudSettings() }
        if reading.readAt != before, let settings = reading.value { draft = settings.draft }
    }

    private func protection(_ settings: AiCloudSettings, _ draft: AiCloudSettings.Draft) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("密码保护功能：")
                    Text("密码保护功能防止未经授权的客户端访问 AiCloud。")
                    Text("您可以限制登录的账户/密码尝试次数。")
                    Text("例如，设置为 3 次 / 2 分钟表示用户可以在 2 分钟内输入 3 次帐户和密码。一旦超过次数，AiCloud 帐户将被锁定，且需要管理员身份来解锁。")
                }.font(.callout).italic().foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                HStack {
                    Text("开启密码保护功能。")
                    Spacer()
                    Toggle("开启密码保护功能。", isOn: Binding(get: { self.draft?.switchOn ?? false }, set: { self.draft?.setSwitch($0) }))
                        .labelsHidden().toggleStyle(.switch)
                }
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                    GridRow {
                        Text("尝试登录的失败数上限")
                        field(\.lockTimes, limit: 2).disabled(!draft.lockFieldsEnabled)
                    }
                    GridRow {
                        Text("时间间隔")
                        HStack { field(\.lockInterval, limit: 2).disabled(!draft.lockFieldsEnabled); Text("分") }
                    }
                }
                HStack(spacing: 10) {
                    Text("帐户状态")
                    Image(systemName: settings.locked ? "person.crop.circle.badge.xmark" : "person.crop.circle").font(.title2)
                        .foregroundStyle(settings.locked ? .red : .secondary)
                    Text(settings.values["http_username"] ?? "").font(.headline)
                    if settings.locked { Button("解锁") { confirming = .unlock(draft) } }
                }
            }
        }
    }

    private func ports(_ draft: AiCloudSettings.Draft) -> some View {
        Panel {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow { Text("AiCloud 网络访问端口"); field(\.httpsPort, limit: 5, digits: true) }
                GridRow { Text("AiCloud 内容串流端口"); field(\.httpPort, limit: 5, digits: true) }
            }
        }
    }

    /// A text field with the page's maxlength. The port fields filter key presses as validator.isNumber does (cloud_settings.asp
    /// 203–206); pasted text stays as it is and meets the checks of 应用本页面设置.
    private func field(_ key: WritableKeyPath<AiCloudSettings.Draft, String>, limit: Int, digits: Bool = false) -> some View {
        TextField("", text: Binding(get: { draft?[keyPath: key] ?? "" }, set: { new in
            let old = draft?[keyPath: key] ?? ""
            draft?[keyPath: key] = WebValidator.edit(old, new, typed: KeyPressEvent.typedCharacter, maxLength: limit,
                                                     replaced: KeyPressEvent.replacedRange(old, new), keyPress: WebValidator.numberKeyPress(digits))
        })).textFieldStyle(.roundedBorder).frame(width: 90).monospacedDigit()
    }

    private func apply(_ settings: AiCloudSettings, _ draft: AiCloudSettings.Draft) {
        switch settings.applying(draft) {
        case .failure(.alert(let message)): alert = message
        case .failure(.samePorts): break
        case .success: confirming = .apply(draft)
        }
    }

    private func submit(_ pending: Pending) {
        confirming = nil
        guard let settings = reading.value else { return }
        let fields: [(String, String)]
        switch pending {
        case .unlock(let draft): fields = settings.unlocking(draft)
        case .apply(let draft):
            // The checks again on the form as it was confirmed; they rewrite the values the page then submits.
            guard case .success(let checked) = settings.applying(draft) else { return }
            fields = checked
        }
        let checkedKeys = fields.map(\.0).filter { !["preferred_lang", "firmver", "current_page", "next_page", "action_mode", "action_script", "action_wait"].contains($0) }
        guard store.beginOperation(pending.unlocks ? "正在解锁 AiCloud 帐户" : "正在保存 AiCloud 设置") else { return }
        Task { @MainActor in
            var readAgain = false
            do {
                let receipt = try await store.connectedClient().submitAiCloudForm(fields, verifying: checkedKeys)
                notice = (receipt.message, receipt.isVerified ? .success : .attention); readAgain = true
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

extension AiCloudSettingsView.Pending {
    var unlocks: Bool { if case .unlock = self { true } else { false } }
}
