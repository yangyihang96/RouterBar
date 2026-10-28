import SwiftUI
import RouterCore

struct TrafficPoint: Identifiable {
    let id = UUID()
    let date: Date
    let download: Double
    let upload: Double
    /// Points of different segments are never joined, so a sampling gap breaks the line.
    let segment: Int
}

@MainActor
@Observable
final class RouterStore {
    enum Phase { case disconnected, connecting, connected, needsLogin }
    var snapshot: RouterSnapshot?
    var phase: Phase = .disconnected
    var isRefreshing = false
    var errorMessage: String?
    var credentialNotice: String?
    var credentialAccess = CredentialAccessFlow()
    var history: [TrafficPoint] = []
    var deviceOverrides: [String: DeviceKind] = [:]
    /// When the next automatic reconnect runs, while one is waiting.
    private(set) var reconnectAt: Date?
    let firmware = FirmwareModel()
    let networks = SDNModel()
    let vpnCenter = VPNCenterModel()
    let monitor = DeviceMonitorModel()
    let networkHealth = NetworkHealthModel()
    var operationTitle: String?
    private(set) var operationIsReadOnly = false
    var wirelessUsesProfiles = false
    /// The model's `sdn_mainfh` capability (state.js `ui_support`), which the web itself checks to hide the per-band
    /// Wi-Fi name and security settings and the MAC filter and RADIUS tabs.
    private(set) var mainFronthaulSupported = false
    /// Until `sdn_rl` and the capability have been read, the legacy per-band Wi-Fi pages stay hidden instead of guessing.
    private(set) var wirelessModeKnown = false
    /// Whether `wans_dualwan` names a second WAN; the web then offers 第二 WAN on the WAN and IPv6 pages.
    private(set) var dualWANEnabled = false
    /// The WANs were read in this session. Observed, so a page that hides the second WAN until then shows it once read.
    private(set) var dualWANKnown = false
    /// `wans_dualwan` as listed, e.g. ["wan", "none"], and `wans_lanport`: the web names the traffic tabs after them.
    /// Kept across an automatic reconnect for display only; `currentWANTypes` and `currentWANLANPort` are this session's.
    private var wanTypes: [String] = []
    private var wanLANPort: String?
    /// This session's WANs, or none until this session has read them: traffic is then named generically, never after an
    /// earlier session's WANs.
    var currentWANTypes: [String] { dualWANKnown ? wanTypes : [] }
    var currentWANLANPort: String? { dualWANKnown ? wanLANPort : nil }
    /// The band of each radio unit (`wlN_nband`), e.g. [0: "2.4 GHz", 1: "5 GHz"]; System Info and the traffic tabs name radios by it.
    private(set) var radioBands: [Int: String] = [:]
    /// The sidebar mirrors the web menu; each menu remembers its page and each page its switch choice.
    private(set) var sidebarItem: SidebarItem = .menu("menu_Index")
    private(set) var pageSelection: [String: String] = [:]
    private(set) var partSelection: [String: String] = [:]
    /// A navigation waiting for "放弃修改" confirmation.
    var pendingNavigation: NavigationRequest?
    /// Result of a router-wide action such as a restart, shown above every page.
    var bannerNotice: String?
    var requestedDeviceMAC: String?
    /// One editor per catalog section, so a page can show several sections; drafts never cross pages.
    @ObservationIgnored private var settingsModels: [String: NativeSettingsModel] = [:]
    var address: String
    var username: String
    var rememberCredentials: Bool
    var refreshSeconds: Double {
        didSet { UserDefaults.standard.set(refreshSeconds, forKey: "refreshSeconds") }
    }
    @ObservationIgnored private var client: RouterClient?
    @ObservationIgnored private var calculator = MetricCalculator()
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var recovery: Task<Void, Never>?
    @ObservationIgnored private var recoveryID: UUID?
    @ObservationIgnored private var recoveryInFlight = false
    @ObservationIgnored private var recoveryAttempts = 0
    @ObservationIgnored private var revealConnectionOnKeychainFailure = false
    @ObservationIgnored private var lastRecoveryAttempt = Date.distantPast
    @ObservationIgnored private var savingCredentials = false
    @ObservationIgnored private var historySegment = 0
    @ObservationIgnored private var activity: NSObjectProtocol?
    /// The connected router's own web menu (its menuTree.js), with native content matched to each page; the last
    /// router's until this one has been read.
    private(set) var menuSet: WebMenuSet
    /// Model, firmware line, radios and capabilities of the router, as last read.
    private(set) var profile: RouterProfile?
    /// What this session may write: nothing until this session has identified the router (readRouterModel), and
    /// requests written from the reference web code only on a 3.0.0.6 router whose own menu was read. The client
    /// enforces the same scope (RouterClient.acquireMutation).
    private(set) var writeScope: WriteScope = .unverified
    @ObservationIgnored private var routerModelKnown = false
    /// `profile` was read in this session; until then it is the last router's, shown but not relied on.
    @ObservationIgnored private var profileReadInSession = false
    /// Changes whenever what was read about the router may have stopped being true (a new session, firmware, WAN or
    /// wizard changes). A model, menu, Wi-Fi or WAN read started before such a change is dropped when it returns, so it
    /// cannot mark old answers as known again.
    @ObservationIgnored private var readRevision = 0
    /// Menu evaluations that failed in this session; a router whose menu never evaluates is not asked again and again.
    @ObservationIgnored private var menuFailures = 0

    init(autoStart: Bool = true) {
        let d = UserDefaults.standard
        address = d.string(forKey: "routerAddress") ?? "http://192.168.50.1"
        // The last router's menu, shown until this one has been read; only for the address it was read from.
        let cached = RouterMenuCache.load().flatMap { $0.endpoint == d.string(forKey: "routerAddress") ? $0 : nil }
        menuSet = cached.map { WebMenuSet.build(entries: $0.entries, profile: $0.profile) } ?? .reference
        profile = cached?.profile
        username = d.string(forKey: "routerUsername") ?? ""
        rememberCredentials = d.bool(forKey: "rememberCredentials")
        let seconds = d.double(forKey: "refreshSeconds")
        refreshSeconds = [5.0, 10.0, 30.0, 60.0].contains(seconds) ? seconds : 10
        if let data = d.data(forKey: "deviceIconOverrides"), let saved = try? JSONDecoder().decode([String: DeviceKind].self, from: data) { deviceOverrides = saved }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.polling?.cancel(); self?.monitor.pause(); self?.networkHealth.cancel()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.monitor.pause(); self.calculator.reset()
                if self.phase == .connected { self.beginPolling() }
                else if self.recovery != nil { self.scheduleRecovery(after: 5) }
            }
        }
        networkHealth.onPathAvailable = { [weak self] in self?.networkPathRestored() }
        // Monitoring belongs to the app, not to a window: it starts once even if no view ever appears.
        if autoStart { Task { [weak self] in self?.start() } }
    }
    var onlineCount: String { snapshot?.onlineDevices.map { String($0.count) } ?? "—" }
    var hasLiveSession: Bool { phase == .connected && errorMessage == nil }
    var statusTitle: String {
        switch phase {
        case .connecting: "正在连接"
        case .needsLogin: reconnectAt == nil ? "需要重新登录" : "等待自动重连"
        case .disconnected: reconnectAt == nil ? "尚未连接" : "等待自动重连"
        case .connected: errorMessage == nil ? (snapshot?.sample.internet.title ?? "正在读取") : "连接中断"
        }
    }
    var statusColor: Color {
        if phase == .connecting { return .blue }
        return hasLiveSession && snapshot?.sample.internet == .online ? .green : .orange
    }
    var endpoint: RouterEndpoint? { try? RouterEndpoint(address) }

    func showDevice(_ mac: String) {
        if snapshot?.sample.devices?.contains(where: { $0.mac == mac }) == true {
            requestedDeviceMAC = mac; open(.clients)
        } else {
            monitor.selectedMAC = mac; open(.deviceHistory)
        }
    }

    // MARK: Navigation

    func navigate(_ request: NavigationRequest) {
        var request = request
        // Choosing the open menu again goes back to its first page, as the web's menu link does.
        if case .sidebar(.menu(let id)) = request.target, sidebarItem == .menu(id), let menu = menuSet.menu(id) {
            let first = menu.pages.first(where: isVisible) ?? menu.home
            request.target = .web(WebLocation(menu: id, page: first.id, part: partID(in: first)))
        }
        let here = request.target == currentTarget(of: request.target)
        let vpn = request.vpnDestination != nil || request.vpnSettingKey != nil
        guard !here || vpn else { return }
        // Within the open VPN tab nothing is left behind: the VPN editor confirms its own slot changes.
        if here || !hasUnsavedSettings { apply(request) } else { pendingNavigation = request }
    }
    func navigate(_ target: NavigationTarget) { navigate(NavigationRequest(target: target)) }
    func open(_ feature: NativeFeature) { if let location = menuSet.location(of: feature) { navigate(.web(location)) } }
    func open(section id: String) { if let location = menuSet.location(ofSection: id) { navigate(.web(location)) } }
    func open(_ page: LocalPage) { navigate(.sidebar(.local(page))) }
    func open(page: WebPage, in menu: WebMenu) {
        navigate(.web(WebLocation(menu: menu.id, page: page.id, part: partID(in: page))))
    }
    /// Opens the VPN tab that holds `destination` and selects it there.
    func openVPN(_ destination: VPNCenterDestination) {
        guard let location = menuSet.location(of: .vpn(VPNScope.containing(destination))) else { return }
        navigate(NavigationRequest(target: .web(location), vpnDestination: destination))
    }
    func openVPN(settingKey: String) {
        guard let destination = VPNCenterDestination(settingKey: settingKey),
              let location = menuSet.location(of: .vpn(VPNScope.containing(destination))) else { return }
        navigate(NavigationRequest(target: .web(location), vpnSettingKey: settingKey))
    }
    func confirmPendingNavigation() {
        guard let request = pendingNavigation else { return }
        pendingNavigation = nil
        discardUnsavedSettings()
        apply(request)
    }

    /// The page a menu shows: the remembered one while it is visible, else the menu's first visible page.
    func page(in menu: WebMenu) -> WebPage {
        if let id = pageSelection[menu.id], let page = menu.page(id), isVisible(page) { return page }
        return menu.pages.first(where: isVisible) ?? menu.home
    }
    func partID(in page: WebPage) -> String {
        let visible = page.parts.filter(isVisible)
        if let id = partSelection[page.id], visible.contains(where: { $0.id == id }) { return id }
        return visible.first?.id ?? page.parts[0].id
    }
    func isVisible(_ page: WebPage) -> Bool { page.condition.map(holds) ?? true }
    func isVisible(_ part: WebPart) -> Bool { part.condition.map(holds) ?? true }
    func isVisible(section id: String) -> Bool { WebMenuCatalog.condition(ofSection: id).map(holds) ?? true }
    func isVisible(field key: String) -> Bool { WebMenuCatalog.condition(ofField: key).map(holds) ?? true }
    func holds(_ condition: WebCondition) -> Bool {
        switch condition {
        case .perBandWireless: wirelessModeKnown && !mainFronthaulSupported && !wirelessUsesProfiles
        // Until this session has read the WANs, the second WAN is neither shown nor hidden on the strength of the last one.
        case .dualWAN: dualWANKnown && dualWANEnabled
        }
    }

    private func currentTarget(of target: NavigationTarget) -> NavigationTarget {
        switch target {
        case .sidebar: return .sidebar(sidebarItem)
        case .web(let location):
            guard sidebarItem == .menu(location.menu), let menu = menuSet.menu(location.menu) else { return .sidebar(sidebarItem) }
            let page = page(in: menu)
            return .web(WebLocation(menu: menu.id, page: page.id, part: partID(in: page)))
        }
    }
    private func apply(_ request: NavigationRequest) {
        switch request.target {
        case .sidebar(let item):
            sidebarItem = item
            if case .menu(let id) = item, let menu = menuSet.menu(id) { pageSelection[id] = menu.pages.first(where: isVisible)?.id ?? menu.home.id }
        case .web(let location):
            sidebarItem = .menu(location.menu); pageSelection[location.menu] = location.page; partSelection[location.page] = location.part
        }
        if let key = request.vpnSettingKey { vpnCenter.focus(settingKey: key, store: self) }
        else if let destination = request.vpnDestination { vpnCenter.requestSelection(destination, store: self) }
    }

    // MARK: Settings editors

    func settingsModel(for sectionID: String) -> NativeSettingsModel {
        if let model = settingsModels[sectionID] { return model }
        let model = NativeSettingsModel(sectionID: sectionID)
        settingsModels[sectionID] = model
        return model
    }
    /// A save already under way is not a pending draft: it finishes, and its own result replaces the draft.
    var hasUnsavedSettings: Bool {
        settingsModels.values.contains { !$0.saving && !$0.changes.isEmpty } || (!vpnCenter.editor.saving && !vpnCenter.editor.changes.isEmpty)
    }
    private func discardUnsavedSettings() {
        for model in settingsModels.values where !model.saving { model.discard() }
        if !vpnCenter.editor.saving { vpnCenter.editor.discard() }
    }

    /// Runs the first saved-login connection in a store-owned task, so closing a window cannot cancel it.
    func start() {
        guard !started else { return }; started = true
        if UserDefaults.standard.bool(forKey: "pendingCredentialChange") {
            sidebarItem = .local(.connection); errorMessage = "管理员信息修改结果尚未确认，请使用新的管理员信息连接。"; return
        }
        guard rememberCredentials, endpoint != nil else { sidebarItem = .local(.connection); return }
        revealConnectionOnKeychainFailure = true
        scheduleRecovery(after: 0)
    }

    @discardableResult
    func connect(address input: String, username inputUser: String, password: String, remember: Bool,
                 persistCredentials: Bool = true, automatic: Bool = false) async -> Error? {
        guard phase != .connecting, operationTitle == nil else { return nil }
        let newEndpoint: RouterEndpoint
        do { newEndpoint = try RouterEndpoint(input) }
        catch { errorMessage = error.localizedDescription; return error }
        guard !inputUser.isEmpty, !password.isEmpty else { errorMessage = "请输入路由器账号和密码。"; return RouterError.validation("请输入路由器账号和密码。") }
        guard !savingCredentials else { credentialNotice = "正在保存登录信息，请完成系统授权后再更换连接。"; return nil }
        if !automatic { cancelRecovery() }
        credentialAccess.reset()
        // An automatic reconnect keeps the last readings on screen until fresh ones arrive.
        stopSession(clearSnapshot: !automatic)
        let token = generation
        phase = .connecting; errorMessage = nil; credentialNotice = nil
        let candidate = RouterClient(endpoint: newEndpoint)
        client = candidate
        do {
            try await candidate.login(username: inputUser, password: password)
            try Task.checkCancellation()
            guard generation == token else { return nil }
            let sample = try await candidate.sample()
            guard generation == token else { return nil }
            address = newEndpoint.displayAddress; username = inputUser; rememberCredentials = remember
            UserDefaults.standard.set(address, forKey: "routerAddress")
            UserDefaults.standard.set(username, forKey: "routerUsername")
            UserDefaults.standard.set(remember, forKey: "rememberCredentials")
            await readRouterModel(candidate, session: token)
            guard generation == token else { return nil }
            await readWirelessMode(candidate, session: token)
            guard generation == token else { return nil }
            UserDefaults.standard.set(false, forKey: "pendingCredentialChange")
            await monitor.prepare(endpoint: newEndpoint.displayAddress, identity: sample.identity)
            guard generation == token else { return nil }
            phase = .connected; recoveryAttempts = 0; accept(sample)
            if !automatic, let overview = menuSet.location(of: .overview) { apply(NavigationRequest(target: .web(overview))) }
            if persistCredentials {
                let destination = newEndpoint.displayAddress
                Task { [weak self] in
                    await self?.persistLogin(RouterCredential(username: inputUser, password: password), address: destination, remember: remember, session: token)
                }
            }
            #if ROUTERBAR_AUDIT
            if let index = CommandLine.arguments.firstIndex(of: "--interface-audit"), CommandLine.arguments.count > index + 1 {
                do {
                    try await InterfaceAudit.run(client: candidate, destination: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true))
                } catch { errorMessage = "接口读取审计未完成：" + error.localizedDescription }
                return nil
            }
            if let index = CommandLine.arguments.firstIndex(of: "--native-read-audit"), CommandLine.arguments.count > index + 1 {
                do { try await InterfaceAudit.verifyNative(client: candidate, destination: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
                catch { errorMessage = "原生接口验证未完成：" + error.localizedDescription }
                return nil
            }
            #endif
            beginPolling()
            return nil
        } catch {
            guard generation == token else { return nil }
            await candidate.cancel(); client = nil; phase = .disconnected
            errorMessage = error is CancellationError ? "连接已取消。" : error.localizedDescription
            return error
        }
    }

    func refresh() async {
        guard phase == .connected, !isRefreshing, !pollingPaused, let client else { return }
        let token = generation
        isRefreshing = true
        defer { if generation == token { isRefreshing = false } }
        do {
            let sample = try await client.sample()
            guard generation == token, !pollingPaused else { return }
            errorMessage = nil; failures = 0; accept(sample)
            if !routerModelKnown { await readRouterModel(client, session: token) }
            if !wirelessModeKnown || !dualWANKnown { await readWirelessMode(client, session: token) }
            // Each wait may have ended this session; a later one must not be read into it.
            guard generation == token, !pollingPaused else { return }
            if let devices = sample.devices {
                await monitor.readTraffic(client: client, online: Set(devices.filter(\.isOnline).map(\.mac)))
            }
        } catch {
            guard generation == token else { return }
            if error is CancellationError { return }
            // A maintenance operation that began meanwhile (firmware upload, administrator change, restart) owns the
            // session and decides about it; a refresh that started before it must not close the shared client.
            if pollingPaused { return }
            failures += 1; errorMessage = error.localizedDescription; calculator.reset()
            guard (error as? RouterError) == .authenticationRequired else { monitor.readFailed(); return }
            monitor.pause()
            phase = .needsLogin; polling?.cancel(); polling = nil; keepAwake(false)
            // Let go of the client before waiting, so a connection made meanwhile keeps its own.
            if self.client === client { self.client = nil }
            await client.cancel()
            // A disconnect or another connection meanwhile owns the state now.
            guard generation == token else { return }
            if rememberCredentials { errorMessage = "登录已失效，正在使用已保存的登录恢复连接。" }
            scheduleRecovery(after: 0)
        }
    }
    private func accept(_ sample: RouterSample) {
        snapshot = calculator.consume(sample)
        monitor.consume(sample, refreshSeconds: refreshSeconds)
        guard let down = snapshot?.downloadBytesPerSecond, let up = snapshot?.uploadBytesPerSecond else { historySegment += 1; return }
        // After a long gap the chart starts over instead of stretching across the missing time.
        if let last = history.last, sample.sampledAt.timeIntervalSince(last.date) > 300 { history = [] }
        history.append(TrafficPoint(date: sample.sampledAt, download: down, upload: up, segment: historySegment))
        if history.count > 90 { history.removeFirst(history.count - 90) }
    }
    /// Which router this is and its own web menu; until it has been read in this session nothing is written. A failed
    /// read is tried again on the next refresh. A menu that does not evaluate (no menuTree.js on old firmware) leaves
    /// the reference menu with every page written from the reference web code as an explanation, says so, and is
    /// tried twice more.
    private func readRouterModel(_ client: RouterClient, session: UUID) async {
        let revision = readRevision
        let nvram: [String: String]
        do { nvram = try await client.readSettings(RouterProfile.nvramKeys) } catch { return }
        var facts: RouterWebFacts?
        var entries: [RouterMenuEntry]?
        var failure: String?
        do {
            let state = try await client.readManagementDocument("state.js")
            let tree = try await client.readManagementDocument("require/modules/menuTree.js")
            guard let helper = Bundle.main.executableURL else { throw RouterMenuEvaluator.Failure.script("找不到求值进程") }
            let result = try await RouterMenuEvaluator.evaluate(state: state, menuTree: tree, helper: helper)
            facts = result.facts; entries = result.menus
        } catch RouterError.authenticationRequired { return } catch is CancellationError { return }
        catch { failure = error.localizedDescription }
        guard generation == session, readRevision == revision, let read = RouterProfile.make(nvram: nvram, facts: facts) else { return }
        // What was decided from another profile (an earlier session's, or this session's before its menu evaluated) is
        // read again from this one.
        if !profileReadInSession || profile != read { wirelessModeKnown = false; dualWANKnown = false }
        profile = read
        profileReadInSession = true
        // The radios' names follow this profile at once, whether or not the WANs are read with it.
        if !read.radios.isEmpty { radioBands = Dictionary(uniqueKeysWithValues: read.radios.map { ($0.unit, $0.title) }) }
        if let entries {
            menuSet = WebMenuSet.build(entries: entries, profile: read)
            RouterMenuCache(entries: entries, profile: read, endpoint: address).save()
            routerModelKnown = true
        } else {
            menuFailures += 1
            menuSet = .fallback(failure ?? "未知原因", profile: read)
            bannerNotice = "未能读取这台路由器（\(read.displayName)）的网页菜单：\(failure ?? "未知原因")。侧栏暂时显示参考菜单，其中部分页面这台路由器可能没有；按网页实现的修改页暂不可用。"
            routerModelKnown = menuFailures >= 3
        }
        writeScope = WriteScope(profile: read, menuRead: entries != nil)
        await client.setWriteScope(writeScope)
        keepNavigationTarget()
    }
    /// A menu the router no longer has cannot stay open: its overview, else its first menu, else the connection page.
    private func keepNavigationTarget() {
        guard case .menu(let id) = sidebarItem, menuSet.menu(id) == nil else { return }
        if let overview = menuSet.location(of: .overview) { apply(NavigationRequest(target: .web(overview))) }
        else if let first = menuSet.menus.first { apply(NavigationRequest(target: .sidebar(.menu(first.id)))) }
        else { apply(NavigationRequest(target: .sidebar(.local(.connection)))) }
    }
    /// Why a settings section of this session only shows its values, or nil when it can be saved.
    func readOnlyReason(section id: String) -> String? {
        phase == .connected ? SettingsCompatibility.readOnlyReason(sectionID: id, writes: writeScope) : nil
    }
    /// Whether Wi-Fi is managed through SDN profiles decides which settings pages are safe to show; dual WAN
    /// decides whether the WAN and IPv6 pages offer the second WAN, as the web pages do. Each is read again on
    /// the next refresh until it has been read once in this session.
    private func readWirelessMode(_ client: RouterClient, session: UUID) async {
        let revision = readRevision
        var profiles: Bool?, mainFronthaul: Bool?
        if !wirelessModeKnown {
            if let values = try? await client.readSettings(["sdn_rl"]) { profiles = (values["sdn_rl"] ?? "").contains(">MAINFH>") }
            if let profile, profileReadInSession, !profile.uiSupport.isEmpty { mainFronthaul = profile.supports("sdn_mainfh") }
            else if let state = try? await client.readManagementDocument("state.js") { mainFronthaul = RouterParser.uiSupport("sdn_mainfh", in: state) }
        }
        let wans = dualWANKnown ? nil : try? await client.readSettings(["wans_dualwan", "wans_lanport"] + (0...3).map { "wl\($0)_nband" })
        guard generation == session, readRevision == revision else { return }
        if let profiles, let mainFronthaul {
            wirelessUsesProfiles = profiles; mainFronthaulSupported = mainFronthaul; wirelessModeKnown = true
        }
        if let wans, let dualWAN = wans["wans_dualwan"] {
            wanTypes = dualWAN.split(separator: " ").map(String.init)
            dualWANEnabled = wanTypes.count > 1 && !wanTypes.contains("none")
            wanLANPort = wans["wans_lanport"].flatMap { $0.isEmpty ? nil : $0 }
            radioBands = profile.flatMap { profileReadInSession ? $0 : nil }.map { Dictionary(uniqueKeysWithValues: $0.radios.map { ($0.unit, $0.title) }) }.flatMap { $0.isEmpty ? nil : $0 }
                ?? RouterRadioBands.titles(nband: Dictionary(uniqueKeysWithValues: (0...3).map { ($0, wans["wl\($0)_nband"] ?? "") }))
            dualWANKnown = true
        }
    }
    private func beginPolling() {
        polling?.cancel()
        keepAwake(true)
        polling = Task { [weak self] in
            var first = true
            while !Task.isCancelled {
                guard let self else { return }
                let delay = first ? 2.0 : min(60, self.refreshSeconds * pow(2, Double(min(self.failures, 3))))
                first = false
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }
    func disconnect() { guard operationTitle == nil else { return }; cancelRecovery(); stopSession(clearSnapshot: true); phase = .disconnected; errorMessage = nil }
    private func stopSession(clearSnapshot: Bool) {
        credentialAccess.reset()
        generation = UUID(); polling?.cancel(); polling = nil; keepAwake(false)
        let old = client; client = nil
        if let old { Task { await old.cancel() } }
        calculator.reset(); failures = 0; isRefreshing = false
        // Every session identifies its router again, and reads its Wi-Fi mode and WANs again, before it writes; the last
        // readings stay on screen meanwhile.
        writeScope = .unverified; routerModelKnown = false; menuFailures = 0; profileReadInSession = false; readRevision += 1
        wirelessModeKnown = false; dualWANKnown = false
        if clearSnapshot {
            snapshot = nil; history = []
            // Another address may be another router: nothing of the last one stays.
            profile = nil
            wirelessUsesProfiles = false; mainFronthaulSupported = false
            dualWANEnabled = false; wanTypes = []; wanLANPort = nil; radioBands = [:]
        }
        // Drafts belong to the session they were read in; say so rather than letting them vanish unnoticed.
        if hasUnsavedSettings { bannerNotice = "与路由器的会话已结束，尚未保存的修改已放弃。重新连接后，页面会重新读取路由器当前的设置。" }
        for model in settingsModels.values { model.reset() }
        firmware.reset(); networks.reset(); vpnCenter.reset()
        monitor.pause(); networkHealth.reset()
    }
    func forgetPassword() async {
        guard !credentialAccess.state.isWaiting, !savingCredentials else { return }
        guard let endpoint else { return }
        let target = endpoint.displayAddress, session = generation
        do {
            try await CredentialStore.remove(address: target)
            // A connection made while the keychain answered keeps its own choice to save.
            guard address == target, generation == session else { credentialNotice = "已移除 \(target) 的已保存密码。"; return }
            rememberCredentials = false; UserDefaults.standard.set(false, forKey: "rememberCredentials")
            cancelRecovery()
            credentialNotice = "已移除这台路由器的已保存密码。"
        } catch { credentialNotice = "钥匙串记录未能移除，请稍后重试。" }
    }
    private enum RecoveryStep { case finished, blocked, failed }
    /// Restores a lost session with the saved login: immediately, then after 30 s, 90 s, 5 min and every
    /// 10 min, never twice within 30 s. A wrong password, captcha, lockout or keychain refusal stops it.
    private func scheduleRecovery(after delay: TimeInterval? = nil) {
        guard rememberCredentials, !recoveryInFlight else { return }
        recovery?.cancel()
        let id = UUID(); recoveryID = id
        recovery = Task { [weak self] in
            var wait = delay ?? ReconnectPolicy.delay(beforeAttempt: self?.recoveryAttempts ?? 0)
            while !Task.isCancelled {
                guard let self, self.recoveryID == id else { return }
                wait = max(wait, ReconnectPolicy.minimumSpacing - Date().timeIntervalSince(self.lastRecoveryAttempt))
                self.reconnectAt = wait > 3 ? Date().addingTimeInterval(wait) : nil
                if wait > 0 {
                    do { try await Task.sleep(for: .seconds(wait)) } catch { return }
                    guard self.recoveryID == id else { return }
                }
                self.reconnectAt = nil
                self.recoveryInFlight = true
                let step = await self.attemptRecovery()
                self.recoveryInFlight = false
                switch step {
                case .finished:
                    if self.recoveryID == id { self.recovery = nil; self.recoveryID = nil }
                    return
                case .blocked: wait = 3
                case .failed:
                    self.recoveryAttempts += 1
                    wait = ReconnectPolicy.delay(beforeAttempt: self.recoveryAttempts)
                }
            }
        }
    }
    private func attemptRecovery() async -> RecoveryStep {
        if phase == .connected { return .finished }
        guard rememberCredentials, !UserDefaults.standard.bool(forKey: "pendingCredentialChange"), let endpoint else { return .finished }
        if phase == .connecting || operationTitle != nil || savingCredentials || credentialAccess.state.isWaiting { return .blocked }
        lastRecoveryAttempt = .now
        let token = generation
        let saved = await readSavedCredential(endpoint: endpoint, interactive: false)
        let reveal = revealConnectionOnKeychainFailure; revealConnectionOnKeychainFailure = false
        guard token == generation else { return .finished }
        guard let saved else {
            // Only an unavailable keychain is worth retrying; a refusal or missing item needs the user.
            if case .failed = credentialAccess.state { return .failed }
            if reveal { sidebarItem = .local(.connection) }
            return .finished
        }
        let error = await connect(address: endpoint.displayAddress, username: saved.username, password: saved.password,
                                  remember: true, persistCredentials: false, automatic: true)
        if phase == .connected { return .finished }
        guard let error else { return .finished }
        return ReconnectPolicy.retries(after: error) ? .failed : .finished
    }
    private func cancelRecovery() {
        recovery?.cancel(); recovery = nil; recoveryID = nil; reconnectAt = nil; recoveryAttempts = 0
    }
    private func networkPathRestored() {
        // A network change makes a waiting reconnect worth trying now instead of at its next backoff step.
        if recovery != nil { scheduleRecovery(after: 2) }
    }
    /// A menu-bar app without visible windows gets napped, which stretches polling past the monitor's gap
    /// limit and silently pauses offline detection. Idle system sleep stays allowed.
    private func keepAwake(_ on: Bool) {
        if on, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "定时读取路由器状态并记录设备在线历史")
        } else if !on, let current = activity {
            ProcessInfo.processInfo.endActivity(current); activity = nil
        }
    }
    func restoreSavedLogin() async {
        guard phase != .connecting, operationTitle == nil, !credentialAccess.state.isWaiting, let endpoint else { return }
        cancelRecovery()
        let token = generation
        let saved = await readSavedCredential(endpoint: endpoint, interactive: true)
        guard token == generation else { return }
        guard let saved else { return }
        await connect(address: endpoint.displayAddress, username: saved.username, password: saved.password, remember: true, persistCredentials: false)
    }
    func cancelCredentialWait() { guard credentialAccess.state.canStopWaiting else { return }; credentialAccess.cancel(); credentialNotice = nil }
    private func readSavedCredential(endpoint: RouterEndpoint, interactive: Bool) async -> RouterCredential? {
        guard !credentialAccess.state.isWaiting else { return nil }
        let token = credentialAccess.begin(interactive ? .authorizing(.now) : .reading(.now))
        let result = await CredentialStore.lookup(address: endpoint.displayAddress, allowInteraction: interactive)
        switch result {
        case .credential(let value): return credentialAccess.finish(token, state: .idle) ? value : nil
        case .unavailable(let status): _ = credentialAccess.finish(token, state: status); return nil
        }
    }
    private func persistLogin(_ credential: RouterCredential, address: String, remember: Bool, session: UUID) async {
        guard generation == session else { return }
        savingCredentials = true; defer { savingCredentials = false }
        let token = credentialAccess.begin(.saving(.now))
        do {
            if remember { try await CredentialStore.save(credential, address: address) }
            else { try await CredentialStore.remove(address: address) }
            guard generation == session else { return }
            _ = credentialAccess.finish(token, state: .idle)
        } catch {
            guard generation == session else { return }
            _ = credentialAccess.finish(token, state: .idle)
            credentialNotice = remember ? "当前连接已可使用，但登录信息未能保存。下次需要在本机连接。" : "当前连接已可使用，但旧钥匙串记录未能移除。"
        }
    }
    func connectedClient() throws -> RouterClient {
        guard phase == .connected, let client else { throw RouterError.authenticationRequired }
        return client
    }
    /// Read-only work (checks, diagnostics, exports) keeps polling and device monitoring running. Writes
    /// pause both, so a Wi-Fi or service restart is never recorded as devices leaving.
    func beginOperation(_ title: String, readOnly: Bool = false) -> Bool {
        guard phase == .connected, operationTitle == nil else { return false }
        if !readOnly { monitor.pause() }
        operationTitle = title; operationIsReadOnly = readOnly; return true
    }
    func endOperation() { operationTitle = nil; operationIsReadOnly = false }
    private var pollingPaused: Bool { operationTitle != nil && !operationIsReadOnly }
    func handleManagementError(_ error: Error) {
        guard (error as? RouterError) == .authenticationRequired else { return }
        errorMessage = rememberCredentials ? "当前连接已过期，正在使用同一已保存账号恢复连接。" : "当前连接已过期，请在连接设置中重新登录。"
        // Polling notices the expired session and starts the saved-login recovery.
        if !pollingPaused { Task { await refresh() } }
    }
    func reauthenticateForOperation(_ existing: RouterClient) async throws {
        guard rememberCredentials, let endpoint, let saved = await readSavedCredential(endpoint: endpoint, interactive: false) else { throw RouterError.authenticationRequired }
        try await existing.login(username: saved.username, password: saved.password)
    }
    /// A restarted router has forgotten every session. Returns whether the saved login signed in again; a router
    /// that is still starting returns false so the caller keeps waiting, while a missing or refused login throws.
    func signInAgainAfterRestart(_ client: RouterClient) async throws -> Bool {
        do { try await reauthenticateForOperation(client); return true }
        catch RouterError.authenticationRequired { throw RouterError.validation("路由器已重新响应，但这台 Mac 没有可用的已保存登录。请在连接设置中重新连接后核对结果。") }
        catch where ReconnectPolicy.retries(after: error) { return false }
    }
    func acceptManagementSample(_ sample: RouterSample) { accept(sample); phase = .connected; errorMessage = nil }
    /// The WAN settings may have changed (双线路 sent them): they are read again on the next refresh, and the second WAN
    /// and the traffic tabs' WAN names wait for that read.
    func wanSettingsMayHaveChanged() { dualWANKnown = false; readRevision += 1 }
    /// The setup wizard may have changed the WANs and the Wi-Fi: both are read again on the next refresh.
    func routerSettingsMayHaveChanged() { dualWANKnown = false; wirelessModeKnown = false; readRevision += 1 }
    /// A firmware image went to the router: whatever it runs after the restart is identified again (model, firmware line,
    /// menu, Wi-Fi and WAN) before anything is written, on the next refresh once the maintenance operation has ended.
    func firmwareMayHaveChanged(_ client: RouterClient) async {
        writeScope = .unverified; routerModelKnown = false; menuFailures = 0; profileReadInSession = false; readRevision += 1
        wirelessModeKnown = false; dualWANKnown = false
        await client.setWriteScope(.unverified)
    }
    /// The web's top bar offers 重新启动 on every page; the result shows in the banner above every page.
    func restartRouter() async {
        guard beginOperation("正在重新启动路由器") else { return }; defer { endOperation() }
        let client: RouterClient
        do { client = try connectedClient() } catch { bannerNotice = error.localizedDescription; return }
        do {
            try await client.reboot()
            bannerNotice = "路由器已接收重新启动请求。正在等待网络恢复；完成状态以重新读取结果为准。"
        } catch RouterError.submissionUncertain(let reason) {
            bannerNotice = reason
        } catch { bannerNotice = error.localizedDescription; return }
        await confirmRestart(client)
    }
    private func confirmRestart(_ client: RouterClient) async {
        switch await awaitRestart(client, from: snapshot?.sample.uptime ?? 0) {
        case .back: bannerNotice = "路由器已恢复连接，运行时长确认已重新启动。"
        case .signInFailed(let reason): bannerNotice = reason
        case .timedOut, .stayedUp: bannerNotice = "尚未确认路由器恢复连接。请稍后刷新状态。"
        }
    }
    enum RestartWait { case back, signInFailed(String), timedOut, stayedUp }
    /// Waits (every five seconds, `checks` times) for an uptime lower than `oldUptime` or than the last one read, signing in
    /// again with the saved login once the router has forgotten this session. With `upFor`, that many readings in a row of
    /// an uptime that kept going from a known `oldUptime` mean the router did not restart (a restart takes it off the
    /// network within seconds); a reading without an uptime, or no known starting uptime, is no such evidence.
    func awaitRestart(_ client: RouterClient, from oldUptime: TimeInterval, checks: Int = 24, upFor: Int? = nil) async -> RestartWait {
        var signIns = 0, upInARow = 0, lastUptime = oldUptime
        for _ in 0..<checks {
            try? await Task.sleep(for: .seconds(5))
            do {
                let sample = try await client.sample()
                guard let uptime = sample.uptime else { upInARow = 0; continue }
                if uptime < lastUptime { acceptManagementSample(sample); return .back }
                lastUptime = uptime
                upInARow = oldUptime > 0 ? upInARow + 1 : 0
                if let upFor, upInARow >= upFor { acceptManagementSample(sample); return .stayedUp }
            } catch RouterError.authenticationRequired {
                upInARow = 0
                guard signIns < 3 else { continue }
                signIns += 1
                do { _ = try await signInAgainAfterRestart(client) }
                catch { return .signInFailed(error.localizedDescription) }
            } catch { upInARow = 0 }
        }
        return .timedOut
    }
    func changeAdministrator(currentPassword: String, change: AdministratorChange) async throws -> String {
        guard beginOperation("正在更新管理员信息") else { throw RouterError.validation("请等待当前操作完成") }
        defer { endOperation() }
        let candidate = try connectedClient()
        // httpd changes the account before it answers, so from the moment chpass.cgi may go out the saved login is not
        // tried again: if the app ends while the answer is awaited, the next launch asks for the account instead of
        // retrying one that may be gone. Only an outcome that proves nothing changed puts the flag back.
        let flagBefore = UserDefaults.standard.bool(forKey: "pendingCredentialChange")
        UserDefaults.standard.set(true, forKey: "pendingCredentialChange")
        do { try await candidate.changeAdministrator(username: username, currentPassword: currentPassword, change: change) }
        catch RouterError.submissionUncertain(let reason) { polling?.cancel(); phase = .needsLogin; lastRecoveryAttempt = .now; throw RouterError.submissionUncertain(reason) }
        catch RouterError.locked {
            UserDefaults.standard.set(flagBefore, forKey: "pendingCredentialChange")
            polling?.cancel(); phase = .needsLogin; lastRecoveryAttempt = .now; throw RouterError.locked
        } catch let error as RouterError {
            // A refusal (wrong current password, a rejected value) or a request that never left changed nothing.
            if case .validation = error { UserDefaults.standard.set(flagBefore, forKey: "pendingCredentialChange") }
            if case .network = error { UserDefaults.standard.set(flagBefore, forKey: "pendingCredentialChange") }
            throw error
        } catch is CancellationError {
            UserDefaults.standard.set(flagBefore, forKey: "pendingCredentialChange"); throw CancellationError()
        }
        var nextUsername = username, nextPassword = currentPassword
        switch change { case .username(let value): nextUsername = value; case .password(let value): nextPassword = value }
        username = nextUsername; UserDefaults.standard.set(nextUsername, forKey: "routerUsername")
        if rememberCredentials {
            do { try await CredentialStore.save(RouterCredential(username: nextUsername, password: nextPassword), address: address) }
            catch {
                rememberCredentials = false; UserDefaults.standard.set(false, forKey: "rememberCredentials")
                credentialNotice = "路由器信息已更新，但钥匙串未能保存新信息。下次请使用新信息连接。"
            }
        }
        UserDefaults.standard.set(false, forKey: "pendingCredentialChange")
        try await Task.sleep(for: .seconds(4))
        do {
            try await candidate.login(username: nextUsername, password: nextPassword)
            let sample = try await candidate.sample(); accept(sample); phase = .connected; errorMessage = nil
            return "管理员信息已更新，已使用新信息确认连接成功。"
        } catch {
            polling?.cancel(); phase = .needsLogin; lastRecoveryAttempt = .now
            return "路由器已确认更新管理员信息，但连接尚未恢复。请在连接设置中使用新信息连接。"
        }
    }
    /// A configuration restore or factory reset went out: the router restarts with other settings, perhaps another
    /// address and administrator. The session ends, writes stay unavailable, and the saved login is not tried again
    /// automatically until the user connects with what the router now uses.
    func endSessionAfterReset(_ message: String) {
        UserDefaults.standard.set(true, forKey: "pendingCredentialChange")
        cancelRecovery()
        stopSession(clearSnapshot: false)
        phase = .needsLogin
        errorMessage = message
    }
    /// The pendingCredentialChange the setup wizard found before its chpass.cgi, to put back if that never went out.
    @ObservationIgnored private var credentialFlagBeforeWizard: Bool?
    /// The setup wizard's chpass.cgi is about to go out: from this moment the saved login is not tried again (start and
    /// attemptRecovery check the flag) until the user connects with the new account — even if the app ends while the
    /// answer is awaited (httpd changes the account before it answers) or the wizard's remaining requests fail. The
    /// session stays for those requests; administratorChangedByWizard ends it afterwards.
    func wizardMayHaveChangedAdministrator() {
        if credentialFlagBeforeWizard == nil { credentialFlagBeforeWizard = UserDefaults.standard.bool(forKey: "pendingCredentialChange") }
        UserDefaults.standard.set(true, forKey: "pendingCredentialChange")
        lastRecoveryAttempt = .now
        cancelRecovery()
    }
    /// The wizard's chpass.cgi provably never reached the router: the flag is what it was before.
    func wizardDidNotChangeAdministrator() {
        guard let before = credentialFlagBeforeWizard else { return }
        credentialFlagBeforeWizard = nil
        UserDefaults.standard.set(before, forKey: "pendingCredentialChange")
    }
    /// The setup wizard sent chpass.cgi: the saved login no longer works, so polling and the saved-login recovery stop until
    /// the user connects with the new account. The new password is not saved.
    func administratorChangedByWizard() {
        credentialFlagBeforeWizard = nil
        polling?.cancel(); phase = .needsLogin; lastRecoveryAttempt = .now
        UserDefaults.standard.set(true, forKey: "pendingCredentialChange")
        errorMessage = "网络设置向导已修改管理员账号或密码，原来保存的登录信息不再可用。请在连接设置中用新的账号和密码重新登录。"
    }
    #if ROUTERBAR_PREVIEW
    /// Development builds only: a session with sample data and a client that answers from it (PreviewRenderer).
    func installPreview(client: RouterClient, snapshot: RouterSnapshot, history: [TrafficPoint], profile: RouterProfile, menus: WebMenuSet) {
        self.client = client; self.snapshot = snapshot; self.history = history; self.profile = profile; menuSet = menus
        writeScope = WriteScope(profile: profile, menuRead: true); profileReadInSession = true
        phase = .connected; wirelessModeKnown = true; mainFronthaulSupported = true; dualWANKnown = true; routerModelKnown = true
        radioBands = Dictionary(uniqueKeysWithValues: profile.radios.map { ($0.unit, $0.title) })
    }
    #endif
    func kind(for device: RouterDevice) -> DeviceKind { deviceOverrides[device.mac] ?? device.classification.kind }
    func setKind(_ kind: DeviceKind?, for device: RouterDevice) {
        deviceOverrides[device.mac] = kind
        if let data = try? JSONEncoder().encode(deviceOverrides) { UserDefaults.standard.set(data, forKey: "deviceIconOverrides") }
    }
}
