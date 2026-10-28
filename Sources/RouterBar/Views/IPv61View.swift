import RouterCore
import SwiftUI

// 1.13：外部网络 › IPv6 › 第二 WAN（Advanced_IPv61_Content.asp）。表格、行与栏位按网页的显示与启用规则（RouterCore 的
// IPv61Form）出现；“应用本页面设置”先做网页的检查（失败时显示网页的提示并回到该栏位），再请用户确认会写入的内容和重启的服务，
// 然后发送网页的同一张表单（start_apply.htm），等待后重新读取核对。读取期间不能编辑；离开页面后不再启动后续读取。

struct IPv61View: View {
    @Environment(RouterStore.self) var store
    @StateObject private var reading = RouterReading<IPv61Page>()
    /// The page's form as the user edits it.
    @State private var form: IPv61Form?
    @State private var alert: IPv61Form.Stop?
    @State private var confirming: IPv61Form.Submission?
    @State private var notice: (message: String, tone: NoticeBanner.Tone)?
    /// Changes when the page is left or read again, so a read that comes back afterwards starts nothing.
    @State private var session = 0
    /// Whether the page is on screen: a save that ends after the page was left reads nothing again.
    @State private var shown = false
    /// The read after a save, cancelled with the page.
    @State private var reread: Task<Void, Never>?
    @FocusState private var focus: String?
    private var connected: Bool { store.phase == .connected }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusPageHeader(title: "第二 WAN", subtitle: "设置 \(reading.value?.model ?? "") IPv6 互联网。", symbol: "6.circle",
                                 readAt: reading.readAt, loading: reading.loading) { await load() }
                ReadErrorLabel(message: reading.error)
                if let notice { NoticeBanner(message: notice.message, tone: notice.tone) }
                if !connected {
                    ConnectionRequiredView()
                } else if let page = reading.value, let form {
                    Link("IPv6 FAQ", destination: page.faqURL).font(.callout)
                    ForEach(IPv61Form.layout) { section in
                        if form.isShown(section.table) { table(section, form) }
                    }
                    HStack {
                        Spacer()
                        Button("应用本页面设置") { apply() }.buttonStyle(.borderedProminent).tint(.teal)
                    }
                } else {
                    ReadingPlaceholder(failed: reading.error != nil && !reading.loading, minHeight: 220)
                }
            }.padding(28).disabled(store.operationTitle != nil || reading.loading)
        }
        .task(id: connected) { if connected, reading.value == nil { await load() } }
        .task(id: PollKey(session: session, polling: form?.updatesState ?? false)) { await poll() }
        .onAppear { shown = true }
        .onDisappear { shown = false; session += 1; reread?.cancel(); reread = nil }
        // ipv61_rtr_addr's onBlur (1207). Running it twice in a row gives the same form.
        .onChange(of: focus) { old, new in if old == "ipv61_rtr_addr", new != old { form?.blurLANAddress() } }
        // After the alert the page focuses and selects the field (focus() / select()); the alert closes first.
        .alert("注意", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } }), presenting: alert) { stop in
            Button("好") { afterSheetCloses { focus = stop.field } }
        } message: { stop in Text(stop.alert) }
        .confirmationDialog("应用第二 WAN 的 IPv6 设置？", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible) {
            if let submission = confirming { Button("应用") { submit(submission) } }
        } message: { Text(confirming.flatMap { submission in reading.value.map { confirmMessage(submission, $0) } } ?? "") }
    }

    private struct PollKey: Equatable { let session: Int; let polling: Bool }

    private func load() async {
        session += 1
        let mine = session, before = reading.readAt
        await reading.load(store: store) { try await $0.ipv61Page() }
        guard session == mine, !Task.isCancelled, let page = reading.value, reading.readAt != before else { return }
        form = page.form
    }

    /// update_info (885–901): update_IPv6state.asp right away and every 1.5 seconds while the selected type is the saved
    /// one; a failed read is tried again after 1.5 seconds. Leaving the page or choosing another type stops it.
    private func poll() async {
        guard form?.updatesState == true else { return }
        while !Task.isCancelled {
            if connected, store.operationTitle == nil, let state = try? await store.connectedClient().ipv61State(), !Task.isCancelled {
                form?.showInfo(state)
            }
            try? await Task.sleep(for: .milliseconds(1500))
        }
    }

    private func table(_ section: IPv61Form.Section, _ form: IPv61Form) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                Text(section.title).font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                    ForEach(section.rows.filter { form.isShown($0) }) { row in
                        GridRow {
                            Text(row.label).font(.callout).gridColumnAlignment(.leading)
                            cell(row, form)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func cell(_ row: IPv61Form.Row, _ form: IPv61Form) -> some View {
        switch row.content {
        case .select("wan_selection"):
            // changeWANUnit (919–931) writes ipv6_unit through apply.cgi; the app switches with the page's own picker instead.
            let selection = form.control("wan_selection")
            VStack(alignment: .leading, spacing: 3) {
                Text(selection.selected.map { selection.options[$0].label } ?? "（未选择）")
                Text("切换 WAN 请用页面上方的“首选 WAN / 第二 WAN”。网页在这里切换时会写入 ipv6_unit，本应用不写入。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .select(let name):
            let control = form.control(name)
            Picker(row.label, selection: Binding(get: { control.current }, set: { value in
                if name == "ipv61_service" { self.form?.chooseService(value) } else { self.form?.chooseInterface(value) }
            })) {
                ForEach(control.options, id: \.self) { Text($0.label).tag($0.value) }
            }.labelsHidden().pickerStyle(.menu).fixedSize().disabled(control.disabled)
        case .radios(let name):
            HStack(spacing: 16) {
                ForEach(Array(form.radios(name).enumerated()), id: \.offset) { index, radio in
                    Button { self.form?.click(name, index) } label: {
                        Label(radio.label, systemImage: radio.checked ? "largecircle.fill.circle" : "circle")
                    }.buttonStyle(.plain).disabled(radio.disabled)
                }
            }
        case .text(let name):
            field(name, form)
        case .span(let span):
            Text(HTMLText.visible(form.text(span), inside: ["div"])).textSelection(.enabled).monospaced()
        case .pool(let prefix, let name):
            HStack(spacing: 6) {
                Text(form.control(prefix).value).monospaced().foregroundStyle(.secondary)
                    .frame(minWidth: 140, alignment: .trailing)
                Text("::")
                field(name, form)
            }
        }
    }

    private func field(_ name: String, _ form: IPv61Form) -> some View {
        let control = form.control(name)
        let width: CGFloat = switch control.maxLength ?? 0 { case 30...: 300; case 10...: 150; case 5...: 90; default: 64 }
        return TextField("", text: Binding(get: { control.value }, set: {
            self.form?.type(name, $0, key: KeyPressEvent.typedCharacter, replaced: KeyPressEvent.replacedRange(control.value, $0))
        }))
            .textFieldStyle(.roundedBorder).monospaced().frame(width: width)
            .focused($focus, equals: name).disabled(control.disabled)
    }

    /// 应用本页面设置: the click blurs ipv61_rtr_addr first, then applyRule's validForm (its rewrites stay on the form).
    private func apply() {
        guard var form else { return }
        if focus == "ipv61_rtr_addr" { form.blurLANAddress() }
        let result = form.apply()
        self.form = form
        switch result {
        case .failure(let stop): alert = stop
        case .success(let submission): confirming = submission
        }
    }

    private func confirmMessage(_ submission: IPv61Form.Submission, _ page: IPv61Page) -> String {
        let shownValue = { (value: String) in value.isEmpty ? "（空）" : value }
        let lines = submission.changes(from: page.values).map { change in
            (IPv61Form.label(of: change.key).map { $0 + " " } ?? "") + change.key + "：" + shownValue(change.before) + " → " + shownValue(change.after)
        }
        let restart = "重启网络（restart_net）" + (submission.script.contains("restart_ftpd") ? "和 FTP 服务（restart_ftpd）" : "")
        if lines.isEmpty {
            return "按读取时的值，本页没有设置会改变。与网页一样仍提交整张表单；路由器确认没有变更时不会\(restart)。"
        }
        return "会写入：\n" + lines.joined(separator: "\n") + "\n\n与网页相同，表单提交到 start_apply.htm（apply_new），路由器保存后会\(restart)，"
            + "约 \(submission.wait) 秒，期间网络连接会中断。"
    }

    private func submit(_ submission: IPv61Form.Submission) {
        confirming = nil
        guard let page = reading.value, store.beginOperation("正在保存第二 WAN 的 IPv6 设置") else { return }
        Task { @MainActor in
            var readAgain = false
            do {
                let receipt = try await store.connectedClient().submitIPv61(submission, page: page)
                notice = (receipt.message, receipt.isVerified ? .success : .attention); readAgain = true
            } catch RouterError.submissionUncertain(let reason) {
                notice = (reason, .attention); readAgain = true
            } catch {
                notice = ("保存没有完成：\(error.localizedDescription)", .error)
                store.handleManagementError(error)
            }
            store.endOperation()
            // The page was left while saving: nothing more starts; leaving during the read stops it.
            if readAgain, shown { reread = Task { await load() } }
        }
    }
}
