import RouterCore
import SwiftUI

// 1.12：网易UU加速器、网络打印机服务器、系统管理 › 政策与 Amazon Alexa 的原生页面。会改动路由器的按钮
// （同意、撤销、取得激活码、启用远程控制）都先请用户确认，再发送与网页相同的请求，并重新读取页面核对。

/// SwiftUI drops a presentation requested while another one is still closing, so a window opened from a closing sheet
/// waits for the sheet to go first.
@MainActor func afterSheetCloses(_ action: @escaping @MainActor () -> Void) {
    Task { @MainActor in try? await Task.sleep(for: .milliseconds(350)); action() }
}

// MARK: - 网易UU加速器

struct UUAcceleratorView: View {
    @Environment(RouterStore.self) var store
    @Environment(\.openURL) private var openURL
    @StateObject private var reading = RouterReading<UUAccelerator>()
    private var connected: Bool { store.phase == .connected }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusPageHeader(title: "网易 UU 加速器", subtitle: "UU 路由器插件", symbol: "bolt.horizontal",
                                 readAt: reading.readAt, loading: reading.loading) { await load() }
                ReadErrorLabel(message: reading.error)
                if !connected {
                    ConnectionRequiredView()
                } else if let uu = reading.value {
                    Panel {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text("网易 UU 加速器").font(.headline)
                                Link("FAQ", destination: UUAccelerator.faq).font(.callout)
                                Spacer()
                            }
                            Text("UU 路由器插件为三大主机（PS4、Switch、Xbox One）、PC 外服端游提供加速。可实现多设备同时加速，畅享全球联机超快感！")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Spacer()
                                Button("前往设置") { if let url = uu.registerURL { openURL(url) } }
                                    .buttonStyle(.borderedProminent).tint(.teal).disabled(uu.registerURL == nil)
                            }
                        }
                    }
                    Text("“前往设置”和网页一样在浏览器打开网易 UU 的路由器页面，并带上这台路由器的标签 MAC 地址；绑定在 UU 的页面完成，本应用不改路由器设置。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    ReadingPlaceholder(failed: reading.error != nil && !reading.loading, minHeight: 220)
                }
            }.padding(28)
        }
        .task(id: connected) { if connected, reading.value == nil { await load() } }
    }

    private func load() async { await reading.load(store: store) { try await $0.uuAccelerator() } }
}

// MARK: - 网络打印机服务器

/// The description and links PrinterServer.asp shows above its switch (133–168).
struct PrinterServerIntro: View {
    @Environment(RouterStore.self) var store
    @StateObject private var reading = RouterReading<String>()

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("网络打印机服务器支持两种共享方式：（1）华硕 EZ 打印机共享（2）LPR 共享打印机。")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { store.open(.usbApplications) } label: { Label("USB 相关应用", systemImage: "chevron.backward") }
                        .buttonStyle(.link).help("返回 USB 相关应用")
                }
                Divider()
                HStack(spacing: 16) {
                    link("华硕 EZ 打印机共享（仅限 Windows 操作系统） FAQ", number: "146")
                    Link("立即下载！", destination: URL(string: "http://dlcdnet.asus.com/pub/ASUS/LiveUpdate/Release/Wireless/Printer.zip")!)
                }
                Divider()
                link("使用 LPR 协议共享打印 FAQ (Windows)", number: "147")
                Divider()
                link("使用 LPR 协议共享打印 FAQ (MAC)", number: "148")
            }.font(.callout)
        }
        .task(id: store.phase == .connected) {
            if store.phase == .connected, reading.value == nil {
                await reading.load(store: store) { try await $0.readSettings(["preferred_lang"])["preferred_lang"] ?? "" }
            }
        }
    }

    /// The FAQ links carry the router's language (faq_href1–3, 70–72); until it is read they are not offered.
    @ViewBuilder private func link(_ title: String, number: String) -> some View {
        if let lang = reading.value, let url = AsusSupportLink.faq(number, lang: lang) {
            Link(title, destination: url)
        } else {
            Text(title).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Policy windows

/// What a policy window offers at its foot.
enum PolicyWindowButtons: Equatable {
    /// 确认 only.
    case close
    /// 拒绝 and 同意 (the statement, Trend Micro's terms).
    case decide
    /// The EULA: 同意 after scrolling to the end and the age check.
    case agreeWithAge
    /// The personal data window: Understood.
    case understood
}

enum PolicyKind: Equatable { case privacy, eula, trendMicro, personal }

struct PolicyWindow: Identifiable, Equatable {
    var id = UUID()
    let kind: PolicyKind
    let document: PolicyDocument
    let buttons: PolicyWindowButtons
    /// The statement's version, for the personal data window it links and the withdrawal window.
    var version = ""
    /// securityUpdate / websUpdate: set on the 政策 page's own window and checkPolicy's, not on the Alexa page's.
    var updates = true
    /// Opened by the 政策 page's own button, whose callbacks reload the page, so the page's load-time checkPolicy
    /// (state.js 5212–5238, which also asks for Trend Micro's terms) follows a write; otherwise asus_policy.js's.
    var reloadsPage = false
    /// Whether 我理解此风险 in the withdrawal its 拒绝 opens reloads the page (knowRiskCallback); nil: as reloadsPage.
    var withdrawReloadsPage: Bool?
}

/// The policy windows of a page and the writes they lead to (asus_policy.js PolicyModalComponent, PolicyWithdraw…,
/// PolicyUpdate…, checkPolicy). Every write is confirmed first, except 同意 in the window an Alexa action opens, which
/// writes at once as the page does.
@MainActor
final class PolicyFlow: ObservableObject {
    struct Withdrawal: Identifiable {
        let id = UUID()
        let version: String
        let reloadsPage: Bool
        /// What 再次阅读 opens again.
        let readAgain: PolicyWindow?
    }
    struct Confirmation: Equatable {
        let action: PrivacyPolicyAction
        let reloadsPage: Bool
    }
    /// PolicyUpdateModalComponent, made once per showing so the sheet keeps one identity.
    struct UpdateNotice: Identifiable { let id = UUID(); let status: PrivacyPolicyStatus }
    @Published var window: PolicyWindow?
    @Published var withdrawal: Withdrawal?
    @Published var updateNotice: UpdateNotice?
    @Published var confirming: Confirmation?
    @Published var notice: (message: String, tone: NoticeBanner.Tone)?
    var language = ""
    /// What the page does once a write is done: 政策 reads the page again; the action, whether its callbacks reload the
    /// page, and the status read back. It returns the window checkPolicy then opens, as the web would; the window waits
    /// until the write is over.
    var afterWrite: (PrivacyPolicyAction, Bool, PrivacyPolicyStatus?) async -> (PrivacyPolicyStatus.FollowUp, PrivacyPolicyStatus)? = { _, _, _ in nil }
    /// The agreeCallback of the statement window an Alexa action opened (and of the windows 再次阅读 opens from it):
    /// 同意 there writes at once and, only when that succeeded, the action continues.
    private var continuation: (window: UUID, action: () -> Void)?
    /// checkPolicy after such a 同意 runs once the window has closed and the action's own dialog is done; it waits here.
    private var deferredFollowUp: (PrivacyPolicyStatus.FollowUp, PrivacyPolicyStatus)?
    /// Run when the current sheet has closed, so the next window is not dropped.
    private var next: (() -> Void)?

    /// A sheet has closed: what its button chose runs now; a window that waited for the sheet opens once nothing else is.
    func afterDismiss() { let action = next; next = nil; action?(); showDeferred() }

    /// A write the windows started is out (from the confirmation, or from 同意 in an action's window, to the status read
    /// back, and the page's reload after it): the window stays on the page until then (asus_policy.js 1259–1279), so the
    /// page's own buttons cannot open a window from the status read before the write.
    @Published var writing = false
    /// Counts the writes the windows started: a read of the status that began before one drops what it read.
    private(set) var writeGeneration = 0
    /// The page's own dialog that a policy flow led to (Alexa's confirmation) is open.
    var externallyBusy: () -> Bool = { false }
    /// A policy flow is under way: a window, notice or confirmation is open, one is closing to open the next, a write is
    /// out, or the page's own dialog is.
    var busy: Bool { window != nil || withdrawal != nil || updateNotice != nil || confirming != nil || next != nil || writing || externallyBusy() }

    /// checkPolicy's window. asus_policy.js inserts a policy window only when none with its id is shown (1327–1331), so an
    /// open window (with its options and the action waiting on it) is never replaced; here nothing opens while a policy
    /// flow is under way, or while one waits to open.
    func show(_ followUp: PrivacyPolicyStatus.FollowUp, status: PrivacyPolicyStatus) {
        guard !busy, deferredFollowUp == nil else { return }
        language = status.language
        switch followUp {
        case .none: break
        case .updateNotice: updateNotice = UpdateNotice(status: status)
        case .privacy: openPrivacy(status, updates: true, reloadsPage: false)
        case .trendMicro:
            if let document = PolicyTexts.trendMicro {
                window = PolicyWindow(kind: .trendMicro, document: document, buttons: status.trendMicroAsksAgreement ? .decide : .close)
            }
        }
    }

    @discardableResult
    func openPrivacy(_ status: PrivacyPolicyStatus, updates: Bool, reloadsPage: Bool, then action: (() -> Void)? = nil) -> Bool {
        language = status.language
        guard let opened = privacyWindow(status, updates: updates, reloadsPage: reloadsPage) else {
            // asus_policy.js builds the window with ASUS_POLICY.Content.PP[`HTMLv${ppVersion}`] (1071), which has only v2 and
            // v4: for another version the constructor throws and the page shows nothing.
            notice = ("这台路由器的隐私声明版本是 v\(status.privacyVersion)，网页的政策脚本只有 v2 和 v4 的正文：网页打开这个窗口时脚本出错，什么也不显示。这里同样不打开窗口。", .attention)
            return false
        }
        window = opened
        continuation = action.map { (opened.id, $0) }
        return true
    }

    /// The statement window PolicyModalComponent builds for this status, or nil when the version has no text.
    func privacyWindow(_ status: PrivacyPolicyStatus, updates: Bool, reloadsPage: Bool, withdrawReloadsPage: Bool? = nil) -> PolicyWindow? {
        status.privacyDocument.map {
            PolicyWindow(kind: .privacy, document: $0, buttons: status.privacyAsksAgreement ? .decide : .close, version: status.privacyVersion,
                         updates: updates, reloadsPage: reloadsPage, withdrawReloadsPage: withdrawReloadsPage)
        }
    }

    /// The page's own dialog for the action has closed: checkPolicy's window, if one waits, opens now.
    func showDeferred() {
        guard let (followUp, status) = deferredFollowUp, !busy else { return }
        deferredFollowUp = nil
        show(followUp, status: status)
    }

    func openEULA(_ status: PrivacyPolicyStatus, reloadsPage: Bool) {
        language = status.language
        guard let document = PolicyTexts.eula else { return }
        window = PolicyWindow(kind: .eula, document: document, buttons: status.eulaAsksAgreement ? .agreeWithAge : .close, reloadsPage: reloadsPage)
    }

    func agreed(_ window: PolicyWindow) {
        next = { [weak self] in
            guard let self else { return }
            switch window.kind {
            case .privacy:
                if let continuation, continuation.window == window.id {
                    self.continuation = nil
                    self.writing = true
                    // privateEula.set calls back only on success: the feature (agreeCallback), then, the window closed,
                    // checkPolicy, which waits for the feature's own dialog.
                    Task {
                        guard let status = await self.write(.agreePrivacy(updates: window.updates), reloadsPage: false, runsAfterWrite: false) else { return }
                        continuation.action()
                        self.deferredFollowUp = (status.followUp(onPageLoad: false), status)
                    }
                } else { confirming = Confirmation(action: .agreePrivacy(updates: window.updates), reloadsPage: window.reloadsPage) }
            case .eula: confirming = Confirmation(action: .agreeEULA, reloadsPage: false)
            case .trendMicro: confirming = Confirmation(action: .agreeTrendMicro, reloadsPage: false)
            case .personal: break
            }
        }
    }

    func disagreed(_ window: PolicyWindow) {
        next = { [weak self] in
            switch window.kind {
            case .privacy: self?.withdrawal = Withdrawal(version: window.version, reloadsPage: window.withdrawReloadsPage ?? window.reloadsPage, readAgain: window)
            case .trendMicro: self?.confirming = Confirmation(action: .withdrawTrendMicro, reloadsPage: false)
            default: break
            }
        }
    }

    func knowRisk(_ withdrawal: Withdrawal) {
        next = { [weak self] in self?.confirming = Confirmation(action: .withdrawPrivacy, reloadsPage: withdrawal.reloadsPage) }
    }

    /// 再次阅读 (handleClickReadAgain 1563–1578) opens the statement again with the same options and callbacks.
    func readAgain(_ withdrawal: Withdrawal) {
        next = { [weak self] in
            guard let self, var window = withdrawal.readAgain else { return }
            let previous = window.id
            window.id = UUID()
            if let continuation, continuation.window == previous { self.continuation = (window.id, continuation.action) }
            self.window = window
        }
    }

    /// The update notice's 确认 opens the EULA window (handleClickReadEula).
    func readEULA(_ status: PrivacyPolicyStatus) { next = { [weak self] in self?.openEULA(status, reloadsPage: false) } }

    var store: RouterStore?

    /// Sends the action and reads the status back; the status only when the request succeeded. afterWrite (the page's
    /// reload and checkPolicy) follows unless the caller orders it itself.
    @discardableResult
    func write(_ action: PrivacyPolicyAction, reloadsPage: Bool, runsAfterWrite: Bool = true) async -> PrivacyPolicyStatus? {
        writing = true
        writeGeneration += 1
        var followUp: (PrivacyPolicyStatus.FollowUp, PrivacyPolicyStatus)?
        defer {
            writing = false
            // checkPolicy's window opens once the write, the status read back and the page's reload are all done; if a
            // window is still in the way, it waits for it to close.
            if let followUp { deferredFollowUp = followUp; showDeferred() }
        }
        guard let store else { return nil }
        guard store.beginOperation("正在写入政策同意状态") else {
            notice = ("另一项操作正在进行，没有写入。", .attention)
            return nil
        }
        var status: PrivacyPolicyStatus?
        do {
            status = try await store.connectedClient().applyPrivacyPolicy(action)
            notice = ("路由器已接收，并已重新读取当前状态。", .success)
        } catch RouterError.submissionUncertain(let reason) {
            notice = (reason, .attention)
        } catch {
            notice = ("请求没有完成：\(error.localizedDescription)", .error)
            store.handleManagementError(error)
        }
        // A page read waits for no operation, so the operation ends first.
        store.endOperation()
        if runsAfterWrite { followUp = await afterWrite(action, reloadsPage, status) }
        return status
    }

    func confirmTitle(_ action: PrivacyPolicyAction) -> String {
        switch action {
        case .agreePrivacy: "同意 ASUS 隐私声明？"
        case .withdrawPrivacy: "撤销对 ASUS 隐私声明的同意？"
        case .agreeEULA: "同意最终用户许可协议？"
        case .withdrawTrendMicro: "请确认是否关闭？"
        case .agreeTrendMicro: "同意 Trend Micro 的最终用户许可协议？"
        }
    }
    func confirmMessage(_ action: PrivacyPolicyAction, status: PrivacyPolicyStatus?) -> String {
        switch action {
        case .agreePrivacy(let updates):
            updates ? "路由器会记录已同意，并开启安全更新" + ((status?.agreementEnablesAutoUpgrade ?? true) ? "与自动固件升级（webs_update_enable）。" : "。") : "路由器会记录已同意。"
        case .withdrawPrivacy: "路由器会记录不同意，依赖这些信息的功能（账号绑定、DDNS、Alexa、远程连接、通知等）可能受限。"
        case .agreeEULA: "路由器会记录已同意最终用户许可协议。"
        case .withdrawTrendMicro: "路由器会记录不同意 Trend Micro 的条款，并关闭 AiProtection、网页与 Apps 过滤、流量分析、应用程序分析、网页浏览历史等依赖它的功能。"
        case .agreeTrendMicro: "路由器会记录已同意 Trend Micro 的最终用户许可协议（TM_EULA=1）。"
        }
    }
}

/// The sheets and the confirmation of a page's PolicyFlow.
struct PolicyFlowPresenter: ViewModifier {
    @ObservedObject var flow: PolicyFlow
    var status: PrivacyPolicyStatus?

    func body(content: Content) -> some View {
        content
            .sheet(item: $flow.window, onDismiss: flow.afterDismiss) { window in
                PolicyDocumentSheet(window: window, language: flow.language, onAgree: { flow.agreed(window) }, onDisagree: { flow.disagreed(window) })
            }
            .sheet(item: $flow.withdrawal, onDismiss: flow.afterDismiss) { withdrawal in
                PolicyWithdrawSheet(version: withdrawal.version, onKnowRisk: { flow.knowRisk(withdrawal) }, onReadAgain: { flow.readAgain(withdrawal) })
            }
            .sheet(item: $flow.updateNotice, onDismiss: flow.afterDismiss) { notice in
                PolicyUpdateNoticeSheet { flow.readEULA(notice.status) }
            }
            .confirmationDialog(flow.confirming.map { flow.confirmTitle($0.action) } ?? "",
                                isPresented: Binding(get: { flow.confirming != nil }, set: { if !$0 { flow.confirming = nil } }), titleVisibility: .visible) {
                if let confirmation = flow.confirming {
                    let withdrawing = [PrivacyPolicyAction.withdrawPrivacy, .withdrawTrendMicro].contains(confirmation.action)
                    Button(withdrawing ? "撤销" : "同意", role: withdrawing ? .destructive : nil) {
                        flow.confirming = nil
                        flow.writing = true
                        Task { await flow.write(confirmation.action, reloadsPage: confirmation.reloadsPage) }
                    }
                }
            } message: { Text(flow.confirming.map { flow.confirmMessage($0.action, status: status) } ?? "") }
    }
}

/// PolicyUpdateModalComponent (asus_policy.js 1581–1636): 提示, the update notice and 确认, which opens the EULA window.
struct PolicyUpdateNoticeSheet: View {
    let onOK: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("提示").font(.title3.weight(.semibold))
            Text("尊敬的用户，感谢您一直以来对本产品的支持。为了遵守各国的隐私法规并进一步保护您的数据，我们更新了 ASUS 隐私声明。请在使用 ASUS 网络产品前了解并同意最新声明。")
                .fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("确认") { onOK(); dismiss() }.keyboardShortcut(.defaultAction) }
        }.font(.callout).padding(22).frame(width: 520)
    }
}

/// One policy window: the document as the page lays it out, its links in place, and the buttons the page gives it.
struct PolicyDocumentSheet: View {
    let window: PolicyWindow
    let language: String
    var onAgree: () -> Void = {}
    var onDisagree: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var viewport: CGFloat = 0
    @State private var reachedEnd = false
    @State private var ageChecked = false
    @State private var askAge = false
    @State private var personal: PolicyWindow?

    private struct EndOffset: PreferenceKey {
        static let defaultValue: CGFloat = .infinity
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(window.document.title).font(.title3.weight(.semibold)).padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(window.document.blocks.enumerated()), id: \.offset) { _, block in blockView(block) }
                    // handleScroll (1223–1232): the end once scrollTop + offsetHeight reaches scrollHeight, measured here as
                    // the bottom of the text reaching the bottom of the visible area.
                    GeometryReader { geometry in
                        Color.clear.preference(key: EndOffset.self, value: geometry.frame(in: .named("policyScroll")).minY)
                    }.frame(height: 1)
                }.padding(20)
            }
            .coordinateSpace(name: "policyScroll")
            .background(GeometryReader { geometry in Color.clear.onAppear { viewport = geometry.size.height }.onChange(of: geometry.size.height) { _, height in viewport = height } })
            .onPreferenceChange(EndOffset.self) { bottom in if viewport > 0, bottom <= viewport + 1 { reachedEnd = true } }
            .frame(minHeight: 320)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "routerbar-policy" { openPersonalData(); return .handled }
                return .systemAction
            })
            Divider()
            footer.padding(16)
        }
        .frame(width: 640, height: 600)
        .alert("请确认您已满 16 岁。", isPresented: $askAge) { Button("确认") {} }
        .sheet(item: $personal) { PolicyDocumentSheet(window: $0, language: language) }
    }

    /// The block's visible text with each link where the page puts it.
    private func attributed(_ block: PolicyBlock) -> AttributedString {
        var text = AttributedString(block.text)
        for link in block.links {
            let target = link.url == "personal" ? URL(string: "routerbar-policy:personal") : AsusSupportLink.target(link.url, lang: language)
            guard let target, !link.title.isEmpty, let range = text.range(of: link.title) else { continue }
            text[range].link = target
            text[range].underlineStyle = .single
        }
        return text
    }

    @ViewBuilder private func blockView(_ block: PolicyBlock) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if !block.marker.isEmpty { Text(block.marker).monospacedDigit().frame(minWidth: 26, alignment: .leading) }
            Text(attributed(block)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .fontWeight(block.bold || block.kind == .title ? .semibold : .regular)
                .underline(block.kind == .title)
        }
        .font(.callout)
        .padding(.leading, CGFloat(block.depth) * 22 + (block.marker.isEmpty && block.kind == .item ? 32 : 0))
        .padding(block.kind == .end ? 8 : 0)
        .overlay { if block.kind == .end { RoundedRectangle(cornerRadius: 4).stroke(.quaternary) } }
    }

    private func openPersonalData() {
        guard let document = PolicyTexts.personalData(version: window.version) else { return }
        personal = PolicyWindow(kind: .personal, document: document, buttons: .understood)
    }

    @ViewBuilder private var footer: some View {
        switch window.buttons {
        case .close:
            HStack { Spacer(); Button("确认") { dismiss() }.keyboardShortcut(.defaultAction) }
        case .understood:
            HStack { Spacer(); Button("Understood") { dismiss() }.keyboardShortcut(.defaultAction) }
        case .decide:
            HStack {
                Spacer()
                Button("拒绝") { onDisagree(); dismiss() }
                Button("同意") { onAgree(); dismiss() }.buttonStyle(.borderedProminent).tint(.teal)
            }
        case .agreeWithAge:
            VStack(alignment: .leading, spacing: 10) {
                if !reachedEnd { Text("请滚动到底部").font(.caption).foregroundStyle(.secondary) }
                Toggle("我已满 16 岁。", isOn: $ageChecked).toggleStyle(.checkbox)
                HStack {
                    Button("取消") { dismiss() }
                    Spacer()
                    Button("同意") {
                        guard ageChecked else { askAge = true; return }
                        onAgree(); dismiss()
                    }.buttonStyle(.borderedProminent).tint(.teal).disabled(!reachedEnd)
                }
            }
        }
    }
}

/// The withdrawal window (PolicyWithdrawModalComponent with DisagreeNoticeComponent, asus_policy.js 1441–1580).
struct PolicyWithdrawSheet: View {
    let version: String
    let onKnowRisk: () -> Void
    let onReadAgain: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("提示").font(.title3.weight(.semibold))
            Text("请注意，不同意 ASUS 隐私声明 可能会导致无法更新到最新的固件版本，并且无法在您的ASUS 网络产品上获得最新的保护；但是，为了保护您的路由器的安全并确保符合法律规定，对于有关重要安全问题或应法律/监管要求的升级，仍会被自动下载和安装。")
                .fixedSize(horizontal: false, vertical: true)
            Text("拒绝提供某些信息可能会限制依赖此类信息的以下功能。").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(["Account Binding", "Config transfer", "DDNS", "Alexa", "IFTTT", "Google Assistant", "Remote Connection", "Notification"]
                        + (version == "4" ? ["AFC", "ASUS Expert Site Manager"] : []), id: \.self) { Text("• " + $0) }
            }.foregroundStyle(.orange)
            HStack {
                Spacer()
                Button("我理解此风险", role: .destructive) { onKnowRisk(); dismiss() }
                Button("再次阅读") { onReadAgain(); dismiss() }.buttonStyle(.borderedProminent).tint(.teal)
            }
        }
        .font(.callout).padding(22).frame(width: 520)
    }
}

/// The line a third-party feature writes under its page, with the notice window it opens.
struct ThirdPartyPolicyLine: View {
    let policy: ThirdPartyPolicy
    @State private var showing = false
    var body: some View {
        let parts = policy.agreement
        HStack(spacing: 0) {
            Text(parts.before)
            Button(parts.link) { showing = true }.buttonStyle(.link)
            Text(parts.after)
        }
        .font(.caption).foregroundStyle(.secondary)
        .sheet(isPresented: $showing) { ThirdPartyPolicySheet(policy: policy) }
    }
}

struct ThirdPartyPolicySheet: View {
    let policy: ThirdPartyPolicy
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("提示").font(.title3.weight(.semibold))
            if let introduction = policy.introduction { Text(introduction) }
            HStack(spacing: 0) {
                Text(policy.agreement.before)
                Link(policy.linkTitle, destination: policy.url)
                Text(policy.agreement.after)
            }
            ForEach(policy.details, id: \.self) { Text($0).fixedSize(horizontal: false, vertical: true) }
            HStack { Spacer(); Button("确认") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .font(.callout).padding(22).frame(width: 520)
    }
}

// MARK: - 政策

struct PrivacyPolicyView: View {
    @Environment(RouterStore.self) var store
    @StateObject private var reading = RouterReading<PrivacyPolicyStatus>()
    @StateObject private var flow = PolicyFlow()
    @State private var checkedOnLoad = false
    /// The page could not be read again after a write: what it shows is from before the write, so nothing on it is
    /// offered until a read succeeds (the web reloads the page, and shows nothing when that fails).
    @State private var reloadFailed = false
    private var connected: Bool { store.phase == .connected }
    private var actionsBlocked: Bool { flow.busy || reloadFailed }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusPageHeader(title: "政策", subtitle: "系统管理 - 华硕提醒您（关于隐私权）", symbol: "hand.raised",
                                 readAt: reading.readAt, loading: reading.loading) { await load() }
                ReadErrorLabel(message: reading.error)
                if let notice = flow.notice { NoticeBanner(message: notice.message, tone: notice.tone) }
                if reloadFailed {
                    NoticeBanner(message: "写入后重新读取页面没有成功，下面的状态可能已经过时：请先点“重新读取”，读取成功后才能继续操作。", tone: .attention)
                }
                if !connected {
                    ConnectionRequiredView()
                } else if let status = reading.value {
                    block("最终用户许可协议 (EULA)", button: "阅读") { readAndOpen { flow.openEULA($0, reloadsPage: false) } } content: {
                        Text("通过使用华硕网络产品，您同意受到最终用户许可协议中所载明的条款和条件的约束。")
                    }
                    if status.privacyAgreed {
                        block("ASUS 隐私声明", button: "撤销") {
                            // show_policy_withdraw (Advanced_Privacy.asp 153–160): only knowRiskCallback reloads; 再次阅读
                            // opens the statement with the defaults (no update switches, no reload after 同意).
                            flow.withdrawal = PolicyFlow.Withdrawal(version: status.privacyVersion, reloadsPage: true,
                                                                    readAgain: flow.privacyWindow(status, updates: false, reloadsPage: false, withdrawReloadsPage: true))
                        } content: {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("请注意，您的信息将被 ASUS 路由器收集用于固件/安全升级目的。 如果您想禁止与 ASUS 路由器共享您的信息，请点击下面的[撤销]。")
                                Button("ASUS 隐私声明") { readAndOpen { flow.openPrivacy($0, updates: true, reloadsPage: true) } }
                                    .buttonStyle(.link).disabled(store.operationTitle != nil || actionsBlocked)
                                Text("* 请注意：点击“撤销”可能会导致您的 ASUS Router 无法更新到最新的固件版本，无法获得最新的保护；但是，为了保护您的路由器的安全，确保符合法律规定，对于有关重要安全问题或应法律/监管要求的升级，仍会被自动下载和安装。")
                            }
                        }
                    } else {
                        block("ASUS 隐私声明", button: "阅读") { readAndOpen { flow.openPrivacy($0, updates: true, reloadsPage: true) } } content: {
                            Text("感谢您关注有关在使用 ASUS 网络产品时确保您的信息隐私和信息安全的内容。我们邀请您阅读并熟悉 ASUS 隐私声明，该声明概述了我们针对收集、处理和保护您的个人信息而采取的措施。")
                        }
                    }
                    if status.showsTrendMicro { trendMicro(status) }
                    Text("同意、撤销与网页发送相同的请求，每一项先确认：同意隐私声明还会开启安全更新" + (status.agreementEnablesAutoUpgrade ? "和自动固件升级" : "")
                         + "；撤销会停止与华硕共享信息；撤销 Trend Micro 会关闭依赖它的功能。完成后重新读取页面核对。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    ReadingPlaceholder(failed: reading.error != nil && !reading.loading, minHeight: 220)
                }
            }.padding(28)
        }
        .task(id: connected) {
            guard connected, reading.value == nil else { return }
            await load()
            // state.js runs checkPolicy 1.5 seconds after the page loads.
            if !checkedOnLoad, reading.value != nil {
                checkedOnLoad = true
                try? await Task.sleep(for: .milliseconds(1500))
                // Left meanwhile: the page that would run it is gone. state.js reads the status when the check runs; a write
                // that began while it was read makes what it read out of date.
                guard !Task.isCancelled, !flow.busy else { return }
                let generation = flow.writeGeneration
                guard let status = try? await store.connectedClient().privacyPolicyStatus(), !Task.isCancelled, flow.writeGeneration == generation else { return }
                flow.show(status.followUp(onPageLoad: true), status: status)
            }
        }
        .onAppear {
            flow.store = store
            flow.afterWrite = { action, reloadsPage, status in
                // This read replaces one still out from before the write, whose answer would be older than the write.
                let before = reading.readAt
                await load(supersede: true)
                if reading.readAt == before { reloadFailed = true }
                // 撤销 of the block hides it without checkPolicy; Trend Micro's window does not check either.
                guard let status, ![PrivacyPolicyAction.withdrawTrendMicro, .agreeTrendMicro].contains(action) else { return nil }
                return (status.followUp(onPageLoad: reloadsPage), status)
            }
        }
        .modifier(PolicyFlowPresenter(flow: flow, status: reading.value))
    }

    private func load(supersede: Bool = false) async {
        let before = reading.readAt
        await reading.load(store: store, supersede: supersede) { try await $0.privacyPolicyStatus() }
        if reading.readAt != before { reloadFailed = false }
    }

    /// show_policy (Advanced_Privacy.asp 163–187): every 阅读 reads PolicyStatus() again and builds the window from it.
    private func readAndOpen(_ open: @escaping (PrivacyPolicyStatus) -> Void) {
        guard !actionsBlocked, store.beginOperation("正在读取政策状态", readOnly: true) else { return }
        let generation = flow.writeGeneration
        Task { @MainActor in
            defer { store.endOperation() }
            do {
                let status = try await store.connectedClient().privacyPolicyStatus()
                guard !actionsBlocked, flow.writeGeneration == generation else { return }
                open(status)
            } catch {
                flow.notice = ("无法读取政策状态：\(error.localizedDescription)", .error)
                store.handleManagementError(error)
            }
        }
    }

    private func block(_ title: String, button: String, action: @escaping () -> Void, @ViewBuilder content: () -> some View) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                content().font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); Button(button) { if !actionsBlocked { action() } }.disabled(store.operationTitle != nil || actionsBlocked) }
            }
        }
    }

    /// The Trend Micro block (tm_eula, shown for TM_EULA "1") with its two links; 撤销 asks confirm() first.
    private func trendMicro(_ status: PrivacyPolicyStatus) -> some View {
        block("使用 AiProtection 智能安全防护、家长管理（网页与 Apps 过滤）、流量分析、应用程序分析、带宽管理 Adaptive QoS/Game Boost 以及网页浏览历史功能:",
              button: "撤销") { flow.confirming = PolicyFlow.Confirmation(action: .withdrawTrendMicro, reloadsPage: false) } content: {
            VStack(alignment: .leading, spacing: 6) {
                Text("请注意，Trend Micro 将通过以上功能收集您的信息。")
                Text(HTMLText.visible("如果您不想通过以上功能与 Trend Micro 分享信息，请点击下方<span style=\"font-weight: bold;\">[撤销]</span>选项。请注意，一旦您停止与 Trend Micro 间的信息分享，上述功能将被停用。", inside: ["div"]))
                if let url = AsusSupportLink.policy(lang: status.language, kw: "tm_ppp") { Link("TrendMicro 隐私权条款", destination: url) }
                if let url = AsusSupportLink.policy(lang: status.language, kw: "tm_ka") { Link("隐私和个人信息收集披露", destination: url) }
            }
        }
    }
}

// MARK: - Amazon Alexa

struct AlexaView: View {
    @Environment(RouterStore.self) var store
    @Environment(\.openURL) private var openURL
    @StateObject private var reading = RouterReading<AlexaPage>()
    @StateObject private var flow = PolicyFlow()
    @State private var region: AlexaPage.Region?
    @State private var confirming: Pending?
    @State private var code: (value: String, expires: Date)?
    @State private var notice: (message: String, tone: NoticeBanner.Tone)?
    @State private var live: AlexaPage?
    @State private var watcher: Task<Void, Never>?
    @State private var realIP: Task<Void, Never>?
    @State private var checkedOnLoad = false
    /// Changes when the page is left or read again, so a read that comes back afterwards starts nothing.
    @State private var session = 0
    /// Whether the page is on screen: a read started after it was left (by an operation finishing) starts nothing.
    @State private var shown = false
    private var connected: Bool { store.phase == .connected }
    /// The page as last updated by the five-second status reads.
    private var page: AlexaPage? { live ?? reading.value }

    /// What waits for the privacy statement or the confirmation.
    enum Pending: Equatable { case activationCode, remoteControl }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusPageHeader(title: "Amazon Alexa", subtitle: page?.title ?? "Amazon Alexa Skill", symbol: "homepod",
                                 readAt: reading.readAt, loading: reading.loading) { await load() }
                ReadErrorLabel(message: reading.error)
                if let notice { NoticeBanner(message: notice.message, tone: notice.tone) }
                if let notice = flow.notice { NoticeBanner(message: notice.message, tone: notice.tone) }
                if !connected {
                    ConnectionRequiredView()
                } else if let page {
                    description(page)
                    status(page)
                    guide(page)
                    if let code { activation(code) }
                    ThirdPartyPolicyLine(policy: .alexa)
                } else {
                    ProgressView("正在读取…").frame(maxWidth: .infinity, minHeight: 220)
                }
            }.padding(28)
        }
        .task(id: connected) {
            guard connected, reading.value == nil else { return }
            await load()
            if !checkedOnLoad {
                checkedOnLoad = true
                try? await Task.sleep(for: .milliseconds(1500))
                // state.js reads the status when the check runs; a write that began while it was read makes it out of date.
                guard !Task.isCancelled, !flow.busy else { return }
                let generation = flow.writeGeneration
                guard let status = try? await store.connectedClient().privacyPolicyStatus(), !Task.isCancelled, flow.writeGeneration == generation else { return }
                flow.show(status.followUp(onPageLoad: true), status: status)
            }
        }
        .onAppear {
            flow.store = store
            flow.externallyBusy = { confirming != nil }
            flow.afterWrite = { action, _, status in
                guard let status, action != .agreeTrendMicro, action != .withdrawTrendMicro else { return nil }
                return (status.followUp(onPageLoad: false), status)
            }
        }
        .onAppear { shown = true }
        .onDisappear { shown = false; session += 1; watcher?.cancel(); watcher = nil; realIP?.cancel(); realIP = nil }
        .onChange(of: confirming) { _, pending in if pending == nil { afterSheetCloses { flow.showDeferred() } } }
        .modifier(PolicyFlowPresenter(flow: flow, status: nil))
        .confirmationDialog(confirming == .remoteControl ? "确定启用 DDNS 和「从互联网设置 \(page?.model ?? "")」？" : "取得新的激活码？",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
            if let action = confirming { Button(action == .remoteControl ? "启用" : "取得") { run(action) } }
        } message: {
            Text(confirming == .remoteControl
                 ? "路由器会开启 DDNS（未设置主机名时使用 asuscomm.com）和从互联网访问管理网页，并重启 DDNS 与网页服务；当前连接可能短暂中断。"
                 : "路由器会生成一组新的激活码，显示 120 秒，用于在 Amazon 的页面关联这台路由器。")
        }
    }

    private func load() async {
        watcher?.cancel(); watcher = nil; realIP?.cancel(); realIP = nil; live = nil
        session += 1
        let mine = session
        await reading.load(store: store) { try await $0.alexaPage() }
        // Left the page, or read again, while this read was out: it starts nothing.
        guard shown, session == mine, !Task.isCancelled, reading.value != nil else { return }
        watch()
        checkRealIP()
    }

    /// update_acc_link_status every five seconds (only reads): the remote access variables and the token match, put on
    /// the page as it then is.
    private func watch() {
        watcher = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            while !Task.isCancelled {
                if connected, store.operationTitle == nil, let current = page,
                   let fresh = try? await store.connectedClient().alexaLiveStatus(current), !Task.isCancelled {
                    live = (page ?? fresh).refreshed(live: fresh.live, tokenEmpty: fresh.tokenEmpty)
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// get_real_ip (231–249), from one second after the page opens: while link_internet is "2" it reads get_real_ip.asp
    /// (a failed read is tried again three seconds later without counting) until the router has its answer or five
    /// reads are counted; while it is not, every three seconds counts one without reading, so after a long outage the
    /// first read once the internet is back is also the last.
    private func checkRealIP() {
        realIP = Task { @MainActor in
            var remaining = 5
            try? await Task.sleep(for: .seconds(1))
            while !Task.isCancelled {
                // The check runs getrealip.sh on the router: only where the app may write (RouterClient.realIP).
                guard store.writeScope.allowsReferenceWeb else { return }
                if page?.live["link_internet"] == "2" {
                    if store.operationTitle == nil, let real = try? await store.connectedClient().alexaRealIP() {
                        if Task.isCancelled { return }
                        remaining -= 1
                        if let current = page { live = current.refreshed(externalIP: real.external) }
                        if real.answered || remaining <= 0 { return }
                    }
                } else {
                    remaining -= 1
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func description(_ page: AlexaPage) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                Text("使用 Amazon Alexa Skill 操控华硕路由器").font(.headline)
                Text("使用 Amazon Alexa ASUS Router Skill，便可通过简单的语音指令操控您的华硕路由器。与 Amazon Alexa 配对后，您无需登录华硕路由器应用程序或者网页用户界面便可让华硕路由器执行各种任务。例如：")
                Text("请尝试说出下列指令：").italic()
                ForEach(["Alexa, ask MY ROUTER to turn on the Guest Network", "Alexa, ask MY ROUTER to upgrade the firmware", "Alexa, ask MY ROUTER to pause the Internet"], id: \.self) {
                    Text("“\($0)”").italic().padding(.leading, 20)
                }
                Link("更多技巧", destination: page.faqURL).italic()
                if page.showsFilterWarning {
                    Text("WARNING: The current network service filter policy for firewall will be overwritten once you say “Alexa, ask ASUS Router to pause the Internet")
                        .foregroundStyle(.orange)
                }
            }.font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func status(_ page: AlexaPage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("华硕路由器与 Alexa 共同为您打造智能家庭！").font(.headline.italic())
            switch page.status {
            case .enableRemoteControl:
                HStack(spacing: 0) {
                    Text("请点击 ")
                    Button("这里") { start(.remoteControl) }.buttonStyle(.link).disabled(store.operationTitle != nil || flow.busy)
                    Text(" 以启用 DDNS 和「从互联网设置 \(page.model)」，从而实现远程访问控制路由器")
                }.foregroundStyle(.orange)
            default:
                Text(page.status.text).foregroundStyle(.orange)
            }
        }.font(.callout)
    }

    private func guide(_ page: AlexaPage) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                if page.appGuideline {
                    step(1) {
                        Text("Open ASUS Router App and go to “Settings.”")
                        Text("* Please make sure your device connect to ASUS router’s WiFi SSID.").font(.caption).foregroundStyle(.secondary)
                    }
                    step(2) { Text("Click “Connect with Alexa” and enable Alexa Skill.") }
                } else {
                    step(1) {
                        Text("选择并进入您偏好的 Amazon 地区网站")
                        HStack {
                            Picker("", selection: Binding(get: { region ?? page.defaultRegion }, set: { region = $0 })) {
                                ForEach(AlexaPage.regions) { Text($0.name).tag($0) }
                            }.labelsHidden().frame(width: 220)
                            Button("链路") { openURL((region ?? page.defaultRegion).site) }
                        }
                    }
                    step(2) { Button("取得激活码") { start(.activationCode) }.buttonStyle(.link).disabled(store.operationTitle != nil || flow.busy) }
                    step(3) { Text("粘贴激活码以关联 Amazon 帐户和您的 ASUS Router") }
                    if page.showsVoiceStep {
                        step(4) { Text("In order to use Amazon Alexa Skill, Lyra Voice needs to bind with Amazon account first. Please setup/sign-in to Amazon via ASUS Router app") }
                    }
                }
            }.font(.callout)
        }
    }

    private func step(_ number: Int, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)").font(.headline).frame(width: 28, height: 28).background(.teal.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 6) { content() }.fixedSize(horizontal: false, vertical: true)
        }
    }

    /// alert_pin: the code with a 120-second countdown (show_alert_pin, countdownfunc), Copy and 关闭.
    private func activation(_ code: (value: String, expires: Date)) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                Text("欲手动将华硕路由器与 Amazon Alexa 配对，请复制并粘贴下方激活码至「连接华硕路由器与 Alexa」网页。").font(.callout)
                HStack(spacing: 16) {
                    Text(code.value).font(.system(.title2, design: .monospaced)).textSelection(.enabled)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let left = max(0, Int(code.expires.timeIntervalSince(context.date).rounded(.down)))
                        Text(String(format: "%02d:%02d", left / 60, left % 60)).monospacedDigit().foregroundStyle(.secondary)
                            .task(id: left) { if left == 0 { try? await Task.sleep(for: .seconds(2)); if self.code?.value == code.value { self.code = nil } } }
                    }
                    Spacer()
                    Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code.value, forType: .string) }
                    Button("关闭") { self.code = nil }
                }
            }
        }
    }

    /// The page first opens the privacy statement when `PP == 0 || PP_time == ''` (tag_control 209–229,
    /// get_activation_code 297–312); its 同意 writes the agreement and goes on with the action.
    private func start(_ action: Pending) {
        guard !flow.busy, store.beginOperation("正在读取隐私声明状态", readOnly: true) else { return }
        let generation = flow.writeGeneration
        Task { @MainActor in
            defer { store.endOperation() }
            do {
                let status = try await store.connectedClient().privacyPolicyStatus()
                guard !flow.busy, flow.writeGeneration == generation else { return }
                if status.featureNeedsAgreement {
                    flow.openPrivacy(status, updates: false, reloadsPage: false) { confirming = action }
                } else {
                    confirming = action
                }
            } catch {
                notice = ("无法读取隐私声明状态：\(error.localizedDescription)", .error)
                store.handleManagementError(error)
            }
        }
    }

    private func run(_ action: Pending) {
        confirming = nil
        guard store.beginOperation(action == .remoteControl ? "正在启用远程控制" : "正在取得激活码") else { return }
        let mine = session
        // One request: once sent it is not taken back; if the page was left meanwhile, it is not read again.
        Task { @MainActor in
            var reload = false
            do {
                let client = try store.connectedClient()
                switch action {
                case .activationCode:
                    code = (try await client.alexaActivationCode(), Date().addingTimeInterval(120))
                case .remoteControl:
                    _ = try await client.enableAlexaRemoteControl()
                    notice = ("路由器已接收启用请求，页面已重新读取。", .success)
                    reload = true
                }
            } catch RouterError.submissionUncertain(let reason) {
                notice = (reason, .attention); reload = action == .remoteControl
            } catch {
                notice = ("请求没有完成：\(error.localizedDescription)", .error)
                store.handleManagementError(error)
            }
            store.endOperation()
            if reload, shown, session == mine { await load() }
        }
    }
}
