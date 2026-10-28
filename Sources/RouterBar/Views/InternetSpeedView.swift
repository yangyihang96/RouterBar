import RouterCore
import SwiftUI

// Adaptive QoS › 网络速度（1.12）：internet_speed.html 的原生版本。测速、获取附近服务器、删除历史都先请用户确认；获取服务器
// 在用户点“获取附近的服务器”时才进行（网页打开时就会让路由器运行 Ookla 获取，并写入 ookla_start_time）。离开页面时，
// 读取进度、获取服务器与写回历史的后续请求都停止。

struct InternetSpeedView: View {
    @Environment(RouterStore.self) var store
    @StateObject private var reading = RouterReading<InternetSpeedPage>()

    /// What the page's result fields show (date_div … speed_level, and the detail panel's *_result2).
    struct Display: Equatable {
        var date = "", time = ""
        var host = "", location = "", showsLocation = false
        var download = "--", upload = "--", latency = "--", jitter = "--"
        var level: SpeedLevel?
        var detailDownload = "--", detailUpload = "--", detailTime = ""

        /// Applies what the page wrote; a field it did not write keeps its text.
        mutating func apply(_ written: SpeedTestDisplay) {
            if let value = written.date { date = value }
            if let value = written.time { time = value }
            if let value = written.host { host = value }
            if let value = written.location { location = value; showsLocation = true }
            if let value = written.download { download = value }
            if let value = written.upload { upload = value }
            if let value = written.latency { latency = value }
            if let value = written.jitter { jitter = value }
            if let value = written.detailDownload { detailDownload = value }
            if let value = written.detailUpload { detailUpload = value }
            if let value = written.detailTime { detailTime = value }
            if let value = written.level { level = value }
        }
        /// reset_speedTest_div (363–372).
        mutating func reset() {
            download = "--"; upload = "--"; latency = "--"; jitter = "--"; date = ""; time = ""; level = nil
        }
    }
    enum Button: Equatable { case go, testing, disable }

    @State private var display = Display()
    @State private var button: Button = .go
    @State private var history: [OrderedJSON] = [.object([])]
    @State private var page = 0
    @State private var selected: [String] = []
    /// The rows of this drawing whose details are open, by place: each row's arrow opens its own details (whatever its
    /// id), and show_history_results draws the rows anew, closed, for another page or a changed history.
    @State private var expanded: Set<Int> = []
    @State private var interface = ""
    @State private var autoServer = true
    @State private var server: SpeedTestServer?
    @State private var servers: [SpeedTestServer] = []
    @State private var loadingServers = false
    @State private var showServers = false
    @State private var showLevel = false
    @State private var alert: String?
    @State private var confirmTest = false
    @State private var confirmServers = false
    @State private var confirmDelete = false
    @State private var notice: (message: String, tone: NoticeBanner.Tone)?
    /// The page's running work: following a test, fetching servers, writing history, watching the connection.
    @State private var work: Task<Void, Never>?
    @State private var serverWork: Task<Void, Never>?
    @State private var watcher: Task<Void, Never>?
    /// Changes when the page is left or read again, so a read that comes back afterwards starts nothing.
    @State private var session = 0
    private var connected: Bool { store.phase == .connected }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusPageHeader(title: "网络速度", subtitle: "Adaptive QoS - 网络速度（Ookla Speedtest）", symbol: "speedometer",
                                 readAt: reading.readAt, loading: reading.loading) { await load() }
                ReadErrorLabel(message: reading.error)
                if let notice { NoticeBanner(message: notice.message, tone: notice.tone) }
                if !connected {
                    ConnectionRequiredView()
                } else if let speed = reading.value {
                    if speed.ispControl == .broken {
                        NoticeBanner(message: "路由器的 ispctrl_desc 不是 JSON，或者是 null。网页的测速脚本在读取它时出错，既不显示测速也不显示链路速率；这里同样不提供测速。", tone: .attention)
                    } else if speed.showsLinkRate, let rate = speed.linkRateText {
                        linkRate(rate)
                    } else {
                        tester(speed)
                        if !speed.lite { historyPanel(speed) }
                    }
                } else {
                    ReadingPlaceholder(failed: reading.error != nil && !reading.loading, minHeight: 220)
                }
            }.padding(28)
        }
        .task(id: connected) { if connected, reading.value == nil { await load() } }
        .onDisappear { session += 1; stopWork() }
        .confirmationDialog("开始网络速度测试？", isPresented: $confirmTest, titleVisibility: .visible) {
            SwiftUI.Button("执行") { startTest() }
        } message: {
            Text("路由器会运行 Ookla Speedtest（" + (autoServer ? "自动选择服务器" : "服务器 \(server?.name ?? "")") + "），约一分钟，期间占用网络带宽；结果写入路由器的历史纪录。")
        }
        .confirmationDialog("获取附近的服务器？", isPresented: $confirmServers, titleVisibility: .visible) {
            SwiftUI.Button("获取") { loadServers() }
        } message: { Text("路由器会记录开始时间（ookla_start_time）并运行 Ookla 查询附近的服务器（ookla -L）；读取列表会把测速状态设回空闲。") }
        .confirmationDialog("删除选中的 \(selected.count) 条历史纪录？", isPresented: $confirmDelete, titleVisibility: .visible) {
            SwiftUI.Button("删除", role: .destructive) { deleteSelected() }
        } message: { Text("路由器上的测速历史文件会改写为剩下的纪录，删除后不能恢复。") }
        .alert("注意", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            SwiftUI.Button("网络地图") { store.open(NativeFeature.overview) }
            SwiftUI.Button("关闭", role: .cancel) {}
        } message: { Text(alert ?? "") }
    }

    // MARK: Reading

    private func stopWork() {
        work?.cancel(); work = nil
        serverWork?.cancel(); serverWork = nil
        watcher?.cancel(); watcher = nil
        loadingServers = false
    }

    /// The ready handler (136–157): an ispctrl_desc the script cannot parse stops it before either view starts, and the
    /// link rate view never runs init. init (185–202) draws the history first; when that throws, init stops before the
    /// latest result and the connection check.
    private func load() async {
        stopWork()
        session += 1
        let mine = session
        await reading.load(store: store) { try await $0.internetSpeedPage() }
        // Left the page, or read again, while this read was out: it starts nothing.
        guard session == mine, !Task.isCancelled, let speed = reading.value else { return }
        history = speed.history; page = 0; selected = []; display = Display(); button = .go
        guard speed.ispControl != .broken, !(speed.showsLinkRate && speed.linkRateText != nil) else { return }
        if !speed.lite, InternetSpeed.historyRows(history, page: 0, timezone: speed.timezone).stopped { return }
        if speed.testing {
            // continue_show_result: a test another page started is followed until it ends.
            if speed.connected { button = .testing; follow(start: javaScriptNumberValue(speed.values["ookla_start_time"]), ownTest: false) }
            else { button = .disable }
        } else if history.count > 1 {
            let latest = SpeedTestDisplay.latest(history[0], timezone: speed.timezone, lite: speed.lite)
            display.apply(latest)
            // show_latest_record threw: init stops before check_wan_status.
            if latest.stopped { return }
        }
        if !speed.connected, button != .testing { button = .disable }
        watchConnection()
    }

    /// `get_result_time - test_start_time` turns the stored text into a number: blank is 0, other text NaN.
    private func javaScriptNumberValue(_ text: String?) -> Double {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? 0 : Double(trimmed) ?? .nan
    }

    /// check_wan_status every two seconds while no test runs: 执行 is disabled while link_internet is not "2".
    private func watchConnection() {
        watcher?.cancel()
        watcher = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, connected, button != .testing, !loadingServers, store.operationTitle == nil,
                      let values = try? await store.connectedClient().readSettings(["link_internet"]), !Task.isCancelled else { continue }
                button = values["link_internet"] == "2" ? .go : .disable
            }
        }
    }

    // MARK: Test

    private func startTest() {
        guard let speed = reading.value, !loadingServers, store.beginOperation("正在开始网络速度测试") else { return }
        display.reset()
        button = .testing; notice = nil
        let id = autoServer ? "" : (server?.id ?? "")
        work?.cancel()
        work = Task { @MainActor in
            let start: Double
            do {
                start = try await store.connectedClient().startOokla(list: false, serverID: id, interface: interface)
                store.endOperation()
            } catch {
                store.endOperation(); button = speed.connected ? .go : .disable
                if case RouterError.submissionUncertain(let reason) = error { notice = (reason, .attention) }
                else if !(error is CancellationError) { notice = ("测速没有开始：\(error.localizedDescription)", .error); store.handleManagementError(error) }
                return
            }
            // Left the page while the request was out: the page would not read the result either.
            guard !Task.isCancelled else { return }
            await followResult(start: start, ownTest: true)
        }
    }

    private func follow(start: Double, ownTest: Bool) {
        work?.cancel()
        work = Task { @MainActor in await followResult(start: start, ownTest: ownTest) }
    }

    /// get_speedTest_result (411–533): reads the test's lines until its result, an error or two minutes from the start.
    private func followResult(start: Double, ownTest: Bool) async {
        button = .testing
        var levelErrors = 0
        let began = Date()
        try? await Task.sleep(for: .seconds(1))
        while !Task.isCancelled {
            guard let client = try? store.connectedClient(), let speed = reading.value else { return }
            if Date().timeIntervalSince1970 * 1000 - start >= 120_000 { await fail(state: "3", ownTest: ownTest); return }
            // A start time that is not a number never times out on the page; here following ends after five minutes.
            if Date().timeIntervalSince(began) > 300 {
                button = speed.connected ? .go : .disable
                notice = ("测速超过五分钟没有结束，已停止等待结果。", .attention)
                return
            }
            let progress = SpeedTestProgress.read(try? await client.ooklaResult(), timezone: speed.timezone, lite: speed.lite)
            if Task.isCancelled { return }
            if progress.failed { await fail(state: "4", ownTest: ownTest); return }
            if progress.levelError {
                if levelErrors < 50 { levelErrors += 1 } else { await fail(state: "4", ownTest: ownTest); return }
            }
            display.apply(progress.display)
            if progress.display.stopped {
                // The page's script throws here and reads no more; 测试中 stays until the page is reloaded.
                button = speed.connected ? .go : .disable
                notice = ("路由器返回的测速结果中有网页无法处理的内容，网页会在这里停止读取，结果没有写入历史。", .attention)
                return
            }
            if let result = progress.result { finish(result, speed: speed); return }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// The "result" line: the history (drawn again, then written back to the router) and 执行 again.
    private func finish(_ result: OrderedJSON, speed: InternetSpeedPage) {
        switch InternetSpeed.adding(result, to: history, lite: speed.lite) {
        case .unchanged: break
        case .stopped:
            notice = ("历史纪录中有网页无法比较的纪录，网页会在这里停止，这次结果没有写入历史。", .attention)
            button = speed.connected ? .go : .disable
            return
        case .added(let updated):
            history = updated
            // show_history_results runs before save_speedTest_history; when drawing throws, nothing is saved.
            if !speed.lite, InternetSpeed.historyRows(updated, page: page, timezone: speed.timezone).stopped {
                notice = ("历史纪录中有网页无法显示的纪录，网页会在这里停止，这次结果没有写入路由器。", .attention)
                button = speed.connected ? .go : .disable
                return
            }
            guard !Task.isCancelled else { return }
            Task { @MainActor in
                guard store.beginOperation("正在写入测速纪录") else { notice = ("测速完成，但另一项操作正在进行，历史纪录没有写入路由器。", .attention); return }
                defer { store.endOperation() }
                do { try await store.connectedClient().writeSpeedTestHistory(updated) }
                catch RouterError.submissionUncertain(let reason) { notice = (reason, .attention) }
                catch { notice = ("测速完成，但历史纪录没有写入路由器：\(error.localizedDescription)", .attention) }
            }
        }
        button = .go
    }

    /// error_handling (557–564): records the error state (which also stops Ookla), clears the fields and shows the
    /// failure notice. A test another page started is only stopped being followed.
    private func fail(state: String, ownTest: Bool) async {
        if ownTest { try? await store.connectedClient().setOoklaState(state) }
        display.reset()
        button = reading.value?.connected == false ? .disable : .go
        alert = "无法完成网络速度测试。请通过 网络地图查看网络状态以获取更多信息，然后重试。"
    }

    /// do_speedTest_exe("list") and get_speedTest_servers (280–286): the list is read every second until it has an entry
    /// besides the trailing {}; a failed read is read again. No test starts meanwhile.
    private func loadServers() {
        guard !loadingServers, button != .testing, store.beginOperation("正在获取附近的服务器") else { return }
        loadingServers = true
        serverWork = Task { @MainActor in
            defer { loadingServers = false; store.endOperation() }
            do {
                let client = try store.connectedClient()
                _ = try await client.startOokla(list: true, serverID: "", interface: interface)
                for _ in 0..<30 {
                    try await Task.sleep(for: .seconds(1))
                    let answer: OrderedJSON?
                    do { answer = try await client.ooklaServers() }
                    catch RouterError.authenticationRequired { throw RouterError.authenticationRequired }
                    catch is CancellationError { throw CancellationError() }
                    catch { continue }
                    if case .array(let entries)? = answer, entries.count >= 2 { servers = SpeedTestServer.list(answer); return }
                }
                notice = ("路由器没有在 30 秒内返回附近的服务器。", .attention)
            } catch is CancellationError {
            } catch RouterError.submissionUncertain(let reason) {
                notice = (reason, .attention)
            } catch {
                notice = ("没有取得服务器列表：\(error.localizedDescription)", .error); store.handleManagementError(error)
            }
        }
    }

    // MARK: Layout

    private func linkRate(_ rate: (value: String, unit: String)) -> some View {
        Panel {
            HStack(spacing: 40) {
                ForEach(["接收速率", "传输速率"], id: \.self) { title in
                    VStack(spacing: 6) {
                        Text(title).font(.callout).foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(rate.value).font(.system(size: 34, weight: .semibold, design: .rounded))
                            Text(rate.unit).foregroundStyle(.secondary)
                        }
                    }
                }
            }.frame(maxWidth: .infinity)
        }
    }

    private func tester(_ speed: InternetSpeedPage) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 16) {
                if speed.interfaces.count > 1 {
                    HStack {
                        Text("Select interface to test:")
                        Picker("", selection: $interface) { ForEach(speed.interfaces, id: \.value) { Text($0.title).tag($0.value) } }
                            .labelsHidden().frame(width: 260).disabled(button == .testing || loadingServers)
                    }.font(.callout)
                }
                if button == .disable {
                    HStack(spacing: 6) {
                        Text("由于网络断开，此功能暂时被禁用。")
                        SwiftUI.Button("检查更多信息。") { alert = "您的网络连接有问题。网络速度测试被暂时禁用。请通过网络地图查看网络状态，然后重试。" }.buttonStyle(.link)
                    }.font(.callout).foregroundStyle(.orange)
                }
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(display.date).monospacedDigit()
                        Text(display.time).monospacedDigit().foregroundStyle(.secondary)
                    }.font(.callout).frame(width: 90, alignment: .leading)
                    serverPicker
                    Spacer()
                    SwiftUI.Button { confirmTest = true } label: {
                        Text(button == .testing ? "测试中" : button == .go ? "执行" : "").font(.headline).frame(width: 90, height: 34)
                    }
                    .buttonStyle(.borderedProminent).tint(.teal)
                    .disabled(button != .go || loadingServers || store.operationTitle != nil)
                }
                Divider()
                HStack(alignment: .top, spacing: 30) {
                    metric("下载", display.download, unit: "Mbps", symbol: "arrow.down.circle")
                    metric("上传", display.upload, unit: "Mbps", symbol: "arrow.up.circle")
                    SwiftUI.Button { showLevel = true } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("水平").font(.caption).foregroundStyle(.secondary)
                            Text(display.level?.name ?? " ").font(.headline)
                        }.frame(minWidth: 70, alignment: .leading)
                    }
                    .buttonStyle(.plain).disabled(button == .testing)
                    .popover(isPresented: $showLevel) { levelDetail }
                    metric("Ping", display.latency, unit: "ms", symbol: nil)
                    metric("抖动", display.jitter, unit: "ms", symbol: nil)
                }
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ookla® 和 Speedtest® 是 Ookla，LLC 的联邦注册商标。").font(.caption).foregroundStyle(.secondary)
                    ThirdPartyPolicyLine(policy: .speedtest)
                }
            }
        }
    }

    private func metric(_ title: String, _ value: String, unit: String, symbol: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).foregroundStyle(.teal) }
                Text(title)
            }.font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// cur_server_div and the list it opens: 自动, then 附近的服务器.
    private var serverPicker: some View {
        SwiftUI.Button { showServers.toggle() } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(display.host).lineLimit(1).truncationMode(.tail)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                if display.showsLocation { Text(display.location).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }.frame(maxWidth: 220, alignment: .leading)
        }
        .buttonStyle(.plain).disabled(button == .testing)
        .help(display.host.count > 20 ? display.host : "")
        .popover(isPresented: $showServers) {
            VStack(alignment: .leading, spacing: 8) {
                SwiftUI.Button { chooseAuto() } label: {
                    HStack { Text("自动"); Spacer(); if autoServer { Image(systemName: "checkmark") } }
                }.buttonStyle(.plain)
                Divider()
                Text("附近的服务器").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if servers.isEmpty {
                    HStack {
                        if loadingServers { ProgressView().controlSize(.small) }
                        SwiftUI.Button("获取附近的服务器") { showServers = false; afterSheetCloses { confirmServers = true } }
                            .disabled(loadingServers || button == .testing || store.operationTitle != nil)
                    }
                    Text("网页打开时就会获取；这里在确认后才让路由器运行 Ookla 查询。").font(.caption).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(servers) { item in
                                SwiftUI.Button { choose(item) } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(item.name).lineLimit(1)
                                            Text(item.location).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer()
                                        if !autoServer, server?.id == item.id { Image(systemName: "checkmark") }
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain).help(item.name.count > 20 || item.location.count > 20 ? item.name + " · " + item.location : "")
                            }
                        }
                    }.frame(maxHeight: 280)
                }
            }.font(.callout).padding(14).frame(width: 300)
        }
    }

    /// choose_auto_server (1207–1219): only when another server is chosen.
    private func chooseAuto() {
        guard !autoServer else { return }
        autoServer = true; display.host = "自动"; display.showsLocation = false
    }

    private func choose(_ item: SpeedTestServer) {
        guard autoServer || server?.id != item.id else { return }
        autoServer = false; server = item
        display.host = item.name; display.location = item.location; display.showsLocation = true
    }

    /// speed_level_detail: the last test, its rating and the six ranges.
    private var levelDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("上次速度测试").font(.caption).foregroundStyle(.secondary)
            Text(display.detailTime).monospacedDigit()
            HStack(spacing: 24) {
                VStack(alignment: .leading) { Text("下载").font(.caption).foregroundStyle(.secondary); Text(display.detailDownload + " Mbps") }
                VStack(alignment: .leading) { Text("上传").font(.caption).foregroundStyle(.secondary); Text(display.detailUpload + " Mbps") }
            }
            Divider()
            Text("下载速度等级").font(.caption).foregroundStyle(.secondary)
            if let level = display.level {
                Text(level.name).font(.headline)
                Text(level.title).fontWeight(.semibold)
                Text(level.detail).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(SpeedLevel.all, id: \.name) { level in
                    GridRow {
                        Text(level.range).monospacedDigit().foregroundStyle(.secondary)
                        Text(level.name).fontWeight(.semibold)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(level.title)
                            Text(level.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            Text("Mbps").font(.caption).foregroundStyle(.secondary)
        }.font(.callout).padding(16).frame(width: 460)
    }

    /// 历史纪录 (history_desc, speedTest_history_div): ten records a page, select and delete.
    private func historyPanel(_ speed: InternetSpeedPage) -> some View {
        let range = InternetSpeed.pageRange(page: page, count: history.count)
        let rendering = InternetSpeed.historyRows(history, page: page, timezone: speed.timezone)
        let rows = rendering.rows
        let ids = rows.compactMap(\.id)
        return Panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("历史纪录", systemImage: "clock.arrow.circlepath").font(.headline)
                    Spacer()
                    if let range { Text("\(range.start)-\(range.end) 项目").font(.caption).foregroundStyle(.secondary) }
                    SwiftUI.Button { if page > 0 { page -= 1 } } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                    SwiftUI.Button { if let range, page < range.lastPage { page += 1 } } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless)
                    SwiftUI.Button { toggleAll(ids) } label: {
                        Image(systemName: !ids.isEmpty && ids.allSatisfy(isSelected) ? "checkmark.square.fill" : "square")
                    }.buttonStyle(.borderless).help("选择本页全部")
                    SwiftUI.Button { confirmDelete = true } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        .disabled(!ids.contains(where: isSelected) || store.operationTitle != nil).help("删除选中的纪录")
                }
                if history.count < 2 {
                    Text("No Test Results.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                        GridRow {
                            Text(""); Text("时间"); Text("下载 (Mbps)"); Text("上传 (Mbps)"); Text("")
                        }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(Array(rows.enumerated()), id: \.offset) { place, row in historyRow(row, place) }
                    }
                    if rendering.stopped {
                        Text("下一条纪录的内容网页无法显示，列表在这里停止。").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
        .onChange(of: page) { expanded = [] }
        .onChange(of: history) { expanded = [] }
    }

    @ViewBuilder private func historyRow(_ row: SpeedTestHistoryRow, _ place: Int) -> some View {
        let key = row.id ?? ""
        GridRow {
            SwiftUI.Button { toggle(key) } label: { Image(systemName: isSelected(key) ? "checkmark.square.fill" : "square") }
                .buttonStyle(.borderless).disabled(row.id == nil)
            VStack(alignment: .leading, spacing: 1) { Text(row.date ?? ""); Text(row.time ?? "").foregroundStyle(.secondary) }.monospacedDigit()
            Text(row.download ?? "").monospacedDigit()
            Text(row.upload ?? "").monospacedDigit()
            SwiftUI.Button { if expanded.contains(place) { expanded.remove(place) } else { expanded.insert(place) } } label: {
                Image(systemName: expanded.contains(place) ? "chevron.up" : "chevron.down")
            }.buttonStyle(.borderless).disabled(row.stopped)
        }.font(.callout)
        if expanded.contains(place), !row.stopped {
            GridRow {
                Text("")
                HStack(spacing: 18) {
                    Text("Ping \(row.latency ?? "") ms"); Text("抖动 \(row.jitter ?? "") ms")
                }.font(.caption).foregroundStyle(.secondary).gridCellColumns(4)
            }
        }
    }

    /// The page keeps the ids it has checked, across pages, in delete_array, compared as JavaScript compares text.
    private func isSelected(_ id: String) -> Bool { selected.contains { $0.sameUnits(id) } }
    private func toggle(_ id: String) {
        if let index = selected.firstIndex(where: { $0.sameUnits(id) }) { selected.remove(at: index) } else { selected.append(id) }
    }

    private func toggleAll(_ ids: [String]) {
        if !ids.isEmpty, ids.allSatisfy(isSelected) { selected.removeAll { id in ids.contains { $0.sameUnits(id) } } }
        else { for id in ids where !isSelected(id) { selected.append(id) } }
    }

    private func deleteSelected() {
        let updated: [OrderedJSON]
        switch InternetSpeed.deleting(selected, from: history) {
        case .unchanged:
            selected = []; return
        case .stopped(let partial):
            // delete_history threw at a record without result.id: it writes nothing and keeps the selection, and the
            // records it removed before that stay removed in the page's list.
            history = partial
            notice = ("历史纪录中有缺少 result.id 的纪录，网页的删除脚本在这里出错：没有写回路由器，已删去的纪录只从本页的列表中移除。", .attention)
            return
        case .deleted(let list):
            updated = list
        }
        guard store.beginOperation("正在删除测速纪录") else { return }
        // One write: once sent it is not taken back, so it is not cancelled with the page.
        Task { @MainActor in
            defer { store.endOperation() }
            do {
                try await store.connectedClient().writeSpeedTestHistory(updated)
                // The page keeps its page number; a page past the end then lists nothing until 上一页.
                history = updated; selected = []
                notice = ("已在路由器上删除选中的纪录。", .success)
            } catch RouterError.submissionUncertain(let reason) {
                notice = (reason, .attention)
            } catch {
                notice = ("删除没有完成：\(error.localizedDescription)", .error)
                store.handleManagementError(error)
            }
        }
    }
}
