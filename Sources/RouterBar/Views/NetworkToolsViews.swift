import RouterCore
import SwiftUI

// 网络工具 › 通过网络（LAN）唤醒 与 Site Survey（1.12）。唤醒、保存离线列表与重新扫描都先请用户确认，再发送与网页相同的请求。
// Site Survey 打开时不像网页那样自动开始扫描，只读取路由器已有的结果；扫描由“重新扫描”开始。离开页面时轮询停止。

// MARK: - 通过网络（LAN）唤醒

struct WakeOnLANView: View {
    @Environment(RouterStore.self) var store
    @StateObject private var reading = RouterReading<WakeOnLANPage>()
    @State private var draft: WakeOnLANList?
    @State private var target = ""
    @State private var adding = ""
    @State private var fieldMessage: String?
    @State private var addMessage: String?
    @State private var confirmWake = false
    @State private var confirmSave = false
    /// The button is disabled and the loading icon shows while the command log keeps changing (checkCmdRet).
    @State private var waking = false
    @State private var poller: Task<Void, Never>?
    /// _responseLen and noChange belong to the page, not to one wake: a second wake goes on from them.
    @State private var lastLength: Int?
    @State private var unchanged = 0
    /// Changes when the page is left, so a wake answered afterwards does not start reading the log.
    @State private var session = 0
    /// showLoading: from the save until the page has been read again the list is not edited.
    @State private var saving = false
    @State private var notice: (message: String, tone: NoticeBanner.Tone)?
    private var connected: Bool { store.phase == .connected }
    private var changed: Bool { draft.map { $0.encoded != reading.value?.stored } ?? false }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    StatusPageHeader(title: "通过网络（LAN）唤醒", subtitle: "网络工具 - 通过网络（LAN）唤醒", symbol: "power",
                                     readAt: reading.readAt, loading: reading.loading) { await reload(keepDraft: false) }
                    ReadErrorLabel(message: reading.error)
                    if let notice { NoticeBanner(message: notice.message, tone: notice.tone) }
                    if !connected {
                        ConnectionRequiredView()
                    } else if let page = reading.value, let list = draft {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("WOL（Wake-On-LAN）功能允许您通过网络中的设备来唤醒计算机。")
                            HStack(spacing: 0) {
                                Text("什么是 ")
                                if let url = AsusSupportLink.faq("145", lang: page.language) { Link("WOL", destination: url).fontWeight(.bold) }
                                Text(" ?")
                            }
                        }.font(.callout).foregroundStyle(.secondary)
                        targetRow(page)
                        // showLoading covers the page while a request is out; the list is not edited meanwhile.
                        offlineList(page, list).disabled(saving || store.operationTitle != nil)
                    } else {
                        ReadingPlaceholder(failed: reading.error != nil && !reading.loading, minHeight: 220)
                    }
                }.padding(28)
            }
            if draft != nil {
                Divider()
                HStack {
                    Text(changed ? "离线列表有修改尚未保存" : "没有未保存的修改").font(.callout.weight(.medium))
                    Spacer()
                    Button("撤销修改") { draft = reading.value?.list; addMessage = nil }.disabled(!changed)
                    Button("应用本页面设置") {
                        if draft?.tableEmptied == true {
                            notice = ("表格的行都已移除，但列表里还留着小写 MAC 的条目：网页的“应用本页面设置”在这里出错，什么也不保存。可以“撤销修改”后重新编辑。", .attention)
                        } else { confirmSave = true }
                    }.buttonStyle(.borderedProminent).tint(.teal).disabled(!changed)
                }.padding(18).background(.bar).disabled(!connected || saving || store.operationTitle != nil)
            }
        }
        .task(id: connected) { if connected, reading.value == nil { await reload(keepDraft: false) } }
        .onDisappear { session += 1; poller?.cancel(); poller = nil; waking = false }
        .confirmationDialog("向 \(target) 发送唤醒数据包？", isPresented: $confirmWake, titleVisibility: .visible) {
            Button("唤醒") { wake() }
        } message: { Text("路由器会在局域网（br0）广播 Wake-on-LAN 数据包（ether-wake -i br0 -b）。") }
        .confirmationDialog("保存离线列表？", isPresented: $confirmSave, titleVisibility: .visible) {
            Button("保存") { save() }
        } message: { Text("路由器会保存 \(draft?.entries.count ?? 0) 个设备的离线列表（wollist），不会重启服务。名称按客户端列表更新。") }
    }

    /// Reads the page again; a draft that was not confirmed saved is kept, and a read that failed (the old value stays)
    /// leaves the draft as it is.
    private func reload(keepDraft: Bool) async {
        let kept = keepDraft ? draft : nil, before = reading.readAt
        await reading.load(store: store) { try await $0.wakeOnLANPage() }
        guard let page = reading.value, draft == nil || reading.readAt != before else { return }
        draft = kept ?? page.list; addMessage = nil
    }

    private func targetRow(_ page: WakeOnLANPage) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text("目标").frame(width: 70, alignment: .leading)
                    TextField("ex: \(page.lanMAC)", text: Binding(get: { target }, set: { target = String($0.prefix(17)); fieldMessage = nil }))
                        .textFieldStyle(.roundedBorder).frame(width: 220).font(.body.monospaced())
                    Button("唤醒") {
                        if target.isEmpty { fieldMessage = WakeOnLANError.blank.message }
                        else if !WakeOnLANList.isMAC(target) { fieldMessage = WakeOnLANError.invalidTarget.message }
                        else { confirmWake = true }
                    }.disabled(waking || store.operationTitle != nil)
                    if waking { ProgressView().controlSize(.small) }
                }
                if let fieldMessage { Text(fieldMessage).font(.caption).foregroundStyle(.orange) }
            }
            // showLoading covers the whole page while the list is saved (Main_WOL_Content.asp 300), 唤醒 included.
            .disabled(saving)
        }
    }

    private func offlineList(_ page: WakeOnLANPage, _ list: WakeOnLANList) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                Text("离线列表 (最多限制： 32)").font(.headline)
                HStack {
                    Text("客户名称 (MAC 地址)"); Spacer(); Text("添加 / 移除")
                }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("ex: \(page.lanMAC)", text: Binding(get: { adding }, set: { adding = String($0.prefix(17)); addMessage = nil }))
                        .textFieldStyle(.roundedBorder).frame(width: 220).font(.body.monospaced())
                    Menu {
                        ForEach(page.clientNames.sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }, id: \.key) { mac, name in
                            Button("\(TORSettings.listText(name))  \(mac)") { adding = mac; addMessage = nil }
                        }
                    } label: { Image(systemName: "chevron.up.chevron.down") }
                        .menuStyle(.borderlessButton).fixedSize().help("选择设备名称。")
                    Spacer()
                    Button { add(list, page) } label: { Image(systemName: "plus.circle.fill") }.buttonStyle(.borderless).help("添加")
                }
                if let addMessage, !addMessage.isEmpty { Text(addMessage).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                Divider()
                if list.showsNoData {
                    Text("目前没有数据").font(.callout).foregroundStyle(.orange)
                } else {
                    ForEach(Array(list.rows.enumerated()), id: \.offset) { index, entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(TORSettings.listText(entry.name))
                                Button(TORSettings.listText(entry.mac)) { target = String(TORSettings.listText(entry.mac).prefix(17)); fieldMessage = nil }
                                    .buttonStyle(.link).font(.callout.monospaced().weight(.bold)).help("填入目标")
                            }
                            Spacer()
                            Button { draft = list.removing(row: index) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("移除")
                        }.font(.callout)
                    }
                }
            }
        }
    }

    private func add(_ list: WakeOnLANList, _ page: WakeOnLANPage) {
        switch list.adding(adding, clientNames: page.clientNames) {
        case .success(let updated): draft = updated; adding = ""; addMessage = nil
        case .failure(let error): addMessage = error.message
        }
    }

    /// onSubmitCtrl, then checkCmdRet (74–112): the log is read after half a second and then every second until
    /// XU6J03M6 shows; after more than five reads of the same length the button is enabled again while reading goes on.
    private func wake() {
        guard !saving, let page = reading.value else { return }
        let mac = target, field = adding, mine = session
        guard store.beginOperation("正在发送唤醒数据包") else { return }
        poller?.cancel()
        notice = nil
        // One request: once sent it is not taken back, but if the page was left meanwhile nothing follows it.
        Task { @MainActor in
            do {
                try await store.connectedClient().wakeOnLAN(mac, adding: field, page: page)
                store.endOperation()
            } catch {
                store.endOperation()
                if let error = error as? WakeOnLANError { fieldMessage = error.message }
                else if case RouterError.submissionUncertain(let reason) = error { notice = (reason, .attention) }
                else if !(error is CancellationError) { notice = ("请求没有完成：\(error.localizedDescription)", .error); store.handleManagementError(error) }
                return
            }
            guard session == mine else { return }
            waking = true
            poller = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                while !Task.isCancelled {
                    if let log = try? await store.connectedClient().commandLog() {
                        if Task.isCancelled { return }
                        if log.contains("XU6J03M6") {
                            waking = false
                            notice = ("路由器已执行唤醒命令（ether-wake）并报告完成。", .success)
                            return
                        }
                        let length = log.utf16.count
                        unchanged = lastLength == length ? unchanged + 1 : 0
                        lastLength = length
                        waking = unchanged <= 5
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    private func save() {
        guard !saving, let list = draft, !list.tableEmptied, let page = reading.value, store.beginOperation("正在保存离线列表") else { return }
        saving = true
        Task { @MainActor in
            defer { saving = false }
            var verified = false, readAgain = false
            do {
                let receipt = try await store.connectedClient().saveWakeOnLANList(list, page: page)
                notice = (receipt.message, receipt.isVerified ? .success : .attention)
                verified = receipt.isVerified; readAgain = true
            } catch RouterError.submissionUncertain(let reason) {
                notice = (reason, .attention); readAgain = true
            } catch {
                notice = ("保存没有完成：\(error.localizedDescription)", .error)
                store.handleManagementError(error)
            }
            // A page read waits for no operation, so the operation ends first; an unconfirmed save keeps the draft.
            store.endOperation()
            if readAgain { await reload(keepDraft: !verified) }
        }
    }
}

// MARK: - Site Survey

struct SiteSurveyView: View {
    @Environment(RouterStore.self) var store
    @StateObject private var reading = RouterReading<SiteSurvey>()
    /// sorter: the column and direction, changed by a header click even when the sort then throws.
    @State private var column: SiteSurvey.Column = .signal
    @State private var descending = true
    /// aplist: the rows in the order the last successful sort left them.
    @State private var rows: [OrderedJSON] = []
    /// What the table shows: showSiteTable replaces it only when it runs to the end.
    @State private var table: SiteSurvey.Table?
    @State private var scanning = false
    @State private var scanner: Task<Void, Never>?
    @State private var confirmScan = false
    @State private var notice: (message: String, tone: NoticeBanner.Tone)?
    @State private var vendors: [String: String]?
    @State private var shown: Int?
    private var connected: Bool { store.phase == .connected }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusPageHeader(title: "Site Survey", subtitle: "Wireless - Visible Networks", symbol: "dot.radiowaves.left.and.right",
                                 readAt: reading.readAt, loading: reading.loading) { await load() }
                ReadErrorLabel(message: reading.error)
                if let notice { NoticeBanner(message: notice.message, tone: notice.tone) }
                if !connected {
                    ConnectionRequiredView()
                } else if let survey = reading.value {
                    HStack(spacing: 20) {
                        if survey.radio2Off { Text("2.4 GHz radio is disabled - cannot scan that band!").foregroundStyle(.orange) }
                        if survey.radio5Off { Text("5 GHz radio is disabled - cannot scan that band!").foregroundStyle(.orange) }
                    }.font(.callout)
                    HStack {
                        Spacer()
                        if scanning { ProgressView().controlSize(.small) }
                        Button("重新扫描") { confirmScan = true }.disabled(scanning || store.operationTitle != nil)
                    }
                    if scanning {
                        // After 重新扫描 the page sets wlc_scan_state to 0 itself, so it shows 正在搜寻 until the scan finishes.
                        Label("正在搜寻无线网络...", systemImage: "antenna.radiowaves.left.and.right").foregroundStyle(.orange)
                    } else if let table {
                        results(survey, table)
                    }
                } else {
                    ReadingPlaceholder(failed: reading.error != nil && !reading.loading, minHeight: 220)
                }
            }.padding(28)
        }
        .task(id: connected) { if connected, reading.value == nil { await load() } }
        .onDisappear { scanner?.cancel(); scanner = nil; scanning = false }
        .confirmationDialog("开始扫描周边无线网络？", isPresented: $confirmScan, titleVisibility: .visible) {
            Button("重新扫描") { scan() }
        } message: { Text("路由器会在各频段扫描周边网络（restart_wlcscan），扫描期间无线连接可能短暂受影响。完成后自动显示结果。") }
    }

    /// update_site_info: new data replaces aplist; `doSorter(sorter.indexFlag, sorter.lastType, false)` then, with two or
    /// more rows, puts the column back to its first direction (Signal descending, the others ascending) and sorts. A sort
    /// that throws leaves aplist as the new data and the table as it was.
    private func load() async {
        let before = reading.readAt
        await reading.load(store: store) { try await $0.siteSurvey() }
        // The error callback re-sorts nothing: only new data replaces aplist.
        guard let survey = reading.value, reading.readAt != before else { return }
        rows = survey.rows
        if rows.count > 1 {
            descending = column == .signal
            guard let sorted = SiteSurvey.sorted(rows, by: column, descending: descending) else { return }
            rows = sorted
        }
        draw(survey)
    }

    /// showSiteTable: the table only changes when it is drawn to the end.
    private func draw(_ survey: SiteSurvey) {
        let drawn = survey.table(rows)
        if drawn != .stopped { table = drawn }
    }

    /// A header click (doSorter with flip): with two or more rows the same column again flips the order, another column
    /// starts descending for Signal and ascending otherwise, and the rows as they stand are sorted again; with fewer the
    /// sorter stays and the table is only drawn again.
    private func sort(by key: SiteSurvey.Column) {
        guard let survey = reading.value else { return }
        if rows.count > 1 {
            if column == key { descending.toggle() } else { descending = key == .signal; column = key }
            guard let sorted = SiteSurvey.sorted(rows, by: column, descending: descending) else { return }
            rows = sorted
        }
        draw(survey)
    }

    @ViewBuilder private func results(_ survey: SiteSurvey, _ table: SiteSurvey.Table) -> some View {
        switch table {
        case .searching:
            Text("路由器目前没有完成的扫描结果（wlc_scan_state 为 \(survey.state.isEmpty ? "空" : survey.state)）。网页打开时会自动开始扫描；这里请点“重新扫描”开始。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .noResult:
            Text("侦测不到任何基地台").foregroundStyle(.orange)
        case .stopped:
            EmptyView()
        case .networks(let networks):
            Panel {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    GridRow {
                        header("无线网络名称", .ssid); header("频道", .channel); header("无线加密", .security); header("Band", .band); header("Signal", .signal)
                    }
                    Divider()
                    ForEach(networks) { network in
                        GridRow {
                            Button {
                                shown = shown == network.id ? nil : network.id
                                if vendors == nil { Task { await loadVendors() } }
                            } label: {
                                Text(network.ssid).italic(network.hidden).lineLimit(1).truncationMode(.middle)
                            }.buttonStyle(.plain)
                            .popover(isPresented: Binding(get: { shown == network.id }, set: { if !$0 { shown = nil } })) { details(network) }
                            Text(network.channel).monospacedDigit()
                            HStack(spacing: 4) { Text(network.security); if network.open { Image(systemName: "lock.open") } }
                            Text(network.band)
                            signal(network)
                        }.font(.callout)
                    }
                }
            }
        }
    }

    private func header(_ title: String, _ key: SiteSurvey.Column) -> some View {
        Button { sort(by: key) } label: {
            HStack(spacing: 3) {
                Text(title)
                if column == key { Image(systemName: descending ? "chevron.down" : "chevron.up").font(.system(size: 8, weight: .bold)) }
            }
        }.buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func signal(_ network: SiteSurvey.Network) -> some View {
        let bars = max(0, min(network.bars ?? 0, 4))
        return HStack(spacing: 3) {
            Image(systemName: "wifi", variableValue: Double(bars) / 4)
            if network.locked { Image(systemName: "lock.fill").font(.system(size: 8)) }
        }.help("\(network.signal)%").accessibilityLabel("信号 \(network.signal)%")
    }

    /// overlib with the MAC and, once the OUI database answers, the manufacturer.
    private func details(_ network: SiteSurvey.Network) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MAC 地址:").font(.caption.weight(.bold))
            Text(network.mac.uppercased()).font(.callout.monospaced()).textSelection(.enabled)
            if let vendor = vendors?[SiteSurvey.vendorKey(network.mac)] {
                Divider()
                Text("制造商 :").font(.caption.weight(.bold))
                Text(vendor).font(.callout)
            }
        }.padding(12)
    }

    private func loadVendors() async {
        guard connected else { return }
        vendors = (try? await store.connectedClient().vendorDatabase()) ?? [:]
    }

    /// rescan, then update_site_info every two seconds until wlc_scan_state is 5 (at most three minutes here).
    private func scan() {
        guard store.beginOperation("正在开始扫描") else { return }
        scanner?.cancel()
        scanner = Task { @MainActor in
            do {
                try await store.connectedClient().startSiteSurvey()
                store.endOperation()
            } catch {
                store.endOperation()
                if case RouterError.submissionUncertain(let reason) = error { notice = (reason, .attention) }
                else if !(error is CancellationError) { notice = ("扫描没有开始：\(error.localizedDescription)", .error); store.handleManagementError(error) }
                return
            }
            scanning = true; notice = nil
            defer { scanning = false }
            // rc starts the scan a moment after the request, so the previous scan's "5" may still be read at first: a
            // finished state counts once a running one was seen, or after twenty seconds.
            var sawRunning = false
            for attempt in 1...90 {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                await load()
                guard let survey = reading.value else { continue }
                if !survey.finished { sawRunning = true }
                if survey.finished, sawRunning || attempt >= 10 { return }
            }
            notice = ("扫描超过三分钟仍未完成，已停止等待。可以稍后重新读取。", .attention)
        }
    }
}
