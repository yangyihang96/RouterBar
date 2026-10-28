import RouterCore
import SwiftUI

// 1.13：系统管理 › 操作模式。网页的“保存”不直接写入，而是在检查和确认后转到网络设置向导（QIS_wizard.htm）由向导切换模式；
// 这里在同样的检查和确认之后，在浏览器打开路由器上的同一个向导。

struct OperationModeView: View {
    @Environment(RouterStore.self) var store
    @Environment(\.openURL) private var openURL
    @StateObject private var reading = RouterReading<OperationModePage>()
    @State private var chosen: String?
    @State private var alert: String?
    /// The confirm() questions still to answer, then the wizard flag.
    @State private var questions: [String] = []
    @State private var wizard: String?
    @State private var notice: (message: String, tone: NoticeBanner.Tone)?
    private var connected: Bool { store.phase == .connected }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusPageHeader(title: "操作模式", subtitle: "系统管理 - 操作模式", symbol: "switch.2",
                                 readAt: reading.readAt, loading: reading.loading) { await load() }
                ReadErrorLabel(message: reading.error)
                if let notice { NoticeBanner(message: notice.message, tone: notice.tone) }
                if !connected {
                    ConnectionRequiredView()
                } else if let page = reading.value {
                    content(page)
                } else {
                    ReadingPlaceholder(failed: reading.error != nil && !reading.loading, minHeight: 220)
                }
            }.padding(28)
        }
        .task(id: connected) { if connected, reading.value == nil { await load() } }
        .alert("注意", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("好") {}
        } message: { Text(alert ?? "") }
        .alert("请确认", isPresented: Binding(get: { !questions.isEmpty }, set: { if !$0 && !questions.isEmpty { questions = []; wizard = nil } })) {
            Button("确定") { answered() }
            Button("取消", role: .cancel) { questions = []; wizard = nil }
        } message: { Text(questions.first ?? "") }
    }

    private func load() async {
        await reading.load(store: store) { try await $0.operationModePage() }
        if let page = reading.value { chosen = page.initialMode?.id }
    }

    @ViewBuilder private func content(_ page: OperationModePage) -> some View {
        let modes = page.modes
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                // initial() hides the description only without AiMesh node, repeater and Media Bridge and with noAP.
                if !(modes.allSatisfy { ["routerMode", "rp_express_2g", "rp_express_5g", "wispMode"].contains($0.id) }) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(page.model) 支持多种操作模式，以满足不同需求。请选择您所需的模式。")
                        Spacer()
                        Button("Introduction of Operation Mode") { openFAQ(page) }.buttonStyle(.link)
                    }.font(.callout)
                }
                Picker("", selection: Binding(get: { chosen ?? "" }, set: { chosen = $0 })) {
                    ForEach(modes) { mode in Text(mode.label).tag(mode.id) }
                }.pickerStyle(.radioGroup).labelsHidden()
                if let mode = modes.first(where: { $0.id == chosen }) {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(mode.paragraphs, id: \.self) { Text($0).fixedSize(horizontal: false, vertical: true) }
                        if let note = mode.note {
                            (Text(note.before) + Text("[\(note.link)](\(OperationModePage.deviceDiscovery.absoluteString))").underline() + Text(note.after))
                                .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        }
                    }.font(.callout)
                }
            }
        }
        HStack {
            Text("“保存”与网页一样不直接改动路由器：确认后在浏览器打开路由器的网络设置向导，由向导完成切换（需要在浏览器登录路由器）。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("保存") { save(page) }.buttonStyle(.borderedProminent).tint(.teal).disabled(chosen == nil || store.operationTitle != nil)
        }
    }

    private func save(_ page: OperationModePage) {
        guard let mode = page.modes.first(where: { $0.id == chosen }) else { return }
        switch page.save(mode) {
        case .alreadyConfigured(let message): alert = message
        case .wizard(let flag, let confirmations):
            wizard = flag
            questions = confirmations + ["在浏览器打开网络设置向导（QIS_wizard.htm?flag=\(flag)）？切换操作模式会改写路由器的设置并重新启动。"]
        }
    }

    private func answered() {
        // An alert's buttons close it; the next question opens once it has gone.
        let rest = Array(questions.dropFirst())
        let flag = wizard
        questions = []
        if rest.isEmpty {
            wizard = nil
            if let flag, let url = store.endpoint?.resource("QIS_wizard.htm", query: [URLQueryItem(name: "flag", value: flag)]) { openURL(url) }
        } else {
            afterSheetCloses { wizard = flag; questions = rest }
        }
    }

    /// The help icon's FAQ: collected_FAQ.json's entry for this page.
    private func openFAQ(_ page: OperationModePage) {
        Task { @MainActor in
            guard let number = try? await store.connectedClient().faqNumber(page: "Advanced_OperationMode_Content.asp"),
                  let url = AsusSupportLink.faq(number, lang: page.values["preferred_lang"] ?? "") else {
                notice = ("路由器的 FAQ 列表中没有这一页的条目。", .attention); return
            }
            openURL(url)
        }
    }
}
