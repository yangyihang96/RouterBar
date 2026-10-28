import RouterCore
import SwiftUI

// 1.13：游戏加速 › Open NAT（GameProfile.asp）。新增、删除只改本页的规则列表，“应用本页面设置”与端口转发开关先请用户确认，
// 再发送网页的同一请求（start_apply.htm / applyapp.cgi，restart_firewall），5 秒后重新读取核对。游戏目录与网页一样，先用
// 路由器的 js/gameProfile.js，再读取华硕网站的在线目录；手动输入名称时的搜索用华硕网站的 opennat_pf.json。

struct OpenNATView: View {
    @Environment(RouterStore.self) var store
    @StateObject private var reading = RouterReading<OpenNATPage>()
    /// vts_rulelist_array: the list as the page now holds it.
    @State private var draft = ""
    /// listTable shows once there were rules, or after 确认 added one; emptyTable otherwise.
    @State private var showsList = false
    /// gameProfile.profile and gameList: the router's records, replaced by the online list once it answers.
    @State private var profiles: [GameProfile] = []
    @State private var games: [OpenNATPage.Game] = []
    @State private var online: Task<Void, Never>?
    @State private var adding: AddSession?
    @State private var confirming: Pending?
    @State private var notice: (message: String, tone: NoticeBanner.Tone)?
    @State private var session = 0
    @State private var shown = false
    private var connected: Bool { store.phase == .connected }

    enum Pending: Equatable { case portForwarding(Bool), save }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                StatusPageHeader(title: "Open NAT", subtitle: "Game - Open NAT", symbol: "gamecontroller",
                                 readAt: reading.readAt, loading: reading.loading) { await load() }
                ReadErrorLabel(message: reading.error)
                if let notice { NoticeBanner(message: notice.message, tone: notice.tone) }
                if !connected {
                    ConnectionRequiredView()
                } else if let page = reading.value {
                    intro(page)
                    if page.softwireStops {
                        NoticeBanner(message: "外部网络使用 v6plus / OCN 虚拟连接 / v6 选项：网页在初始化时读取一个未定义的变量而出错，开关和规则都不显示，新增也没有反应。这里同样只显示说明。", tone: .attention)
                    } else if showsList {
                        ruleList(page)
                    } else {
                        emptyList(page)
                    }
                } else {
                    ReadingPlaceholder(failed: reading.error != nil && !reading.loading, minHeight: 220)
                }
            }.padding(28).disabled(store.operationTitle != nil || reading.loading)
        }
        .task(id: connected) { if connected, reading.value == nil { await load() } }
        .onAppear { shown = true }
        .onDisappear { shown = false; session += 1; online?.cancel(); online = nil }
        .sheet(item: $adding) { opened in
            if let page = reading.value {
                OpenNATAddSheet(page: page, list: draft, rule: opened.rule, profiles: $profiles, games: games) { list in
                    draft = list; showsList = true; adding = nil
                } onCancel: { adding = nil }
                    .frame(minWidth: 640, minHeight: 560)
            }
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
            if let pending = confirming { Button(pending == .save ? "应用" : "确定") { run(pending) } }
        } message: { Text(confirmMessage) }
    }

    /// The open New Game Profile window: one identity from 新增 (or a game card) until it closes, so later reads of the page
    /// or the catalogs keep what is typed in it.
    struct AddSession: Identifiable { let id = UUID(); let rule: OpenNATPage.NewRule }

    private var confirmTitle: String {
        switch confirming {
        case .portForwarding(let on)?: on ? "开启端口转发？" : "关闭端口转发？"
        case .save?: "应用游戏规则？"
        case nil: ""
        }
    }
    private var confirmMessage: String {
        switch confirming {
        case .portForwarding(let on)?: "路由器会把 vts_enable_x 设为 \(on ? "1" : "0")，并重启防火墙（restart_firewall），约 5 秒。尚未应用的游戏规则不会一起保存。"
        case .save?: "路由器会把 game_vts_rulelist 改为本页的 \(OpenNATPage.rules(draft, profiles: profiles, clients: reading.value?.clients ?? [])?.count ?? 0) 条规则，并重启防火墙（restart_firewall），约 5 秒。"
        case nil: ""
        }
    }

    private func load() async {
        online?.cancel(); online = nil
        session += 1
        let mine = session
        let before = reading.readAt
        await reading.load(store: store) { try await $0.openNATPage() }
        // A failed read keeps the list as it is.
        guard session == mine, !Task.isCancelled, reading.readAt != before, let page = reading.value else { return }
        draft = page.stored; showsList = !page.stored.isEmpty
        profiles = page.builtIn; games = OpenNATPage.games(page.builtIn)
        // A read that finishes after the page was left starts nothing.
        if shown, !page.softwireStops { updateOnline() }
    }

    /// updatProfileOnline (141–156): the online list replaces the records; gameList keeps the titles it has and adds new
    /// ids. A failed request is tried again five seconds later while the page is open.
    private func updateOnline() {
        online = Task { @MainActor in
            while !Task.isCancelled {
                if let (data, response) = try? await URLSession.shared.data(from: GameProfile.onlineCatalog),
                   (response as? HTTPURLResponse)?.statusCode == 200, let list = GameProfile.online(data) {
                    if Task.isCancelled { return }
                    profiles = list; games = OpenNATPage.games(list, adding: games)
                    return
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func intro(_ page: OpenNATPage) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                Text("OPEN NAT").font(.headline)
                Text("OpenNAT 可让您轻松创建在线游戏端口转发规则，并优化游戏机至路由器的路由封包，以获得上佳游戏体验。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !page.softwireStops {
                    HStack {
                        Text("开启端口转发")
                        Spacer()
                        Toggle("开启端口转发", isOn: Binding(get: { page.portForwarding }, set: { confirming = .portForwarding($0) }))
                            .labelsHidden().toggleStyle(.switch)
                    }
                }
            }
        }
    }

    private func emptyList(_ page: OpenNATPage) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("游戏设置档").font(.headline)
                    Spacer()
                    Button("新增") { adding = AddSession(rule: OpenNATPage.NewRule()) }
                }
                Text("Game Profile 包含热门的在线游戏的内置规则。请在下方列表中选择游戏并完成基本设置。上佳的游戏体验触手可得。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(games) { game in
                        Button { adding = AddSession(rule: rule(for: game.id)) } label: {
                            Text(HTMLText.visible(game.title, inside: ["div"])).lineLimit(2).frame(maxWidth: .infinity, minHeight: 36)
                        }.buttonStyle(.bordered)
                    }
                }
                Text("** 所有游戏名称、商标和品牌均为其各自所有者的财产。使用这些名称、商标和品牌，不代表任何的背书。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// addNewProfile(target) (439–494) for a game card: its records' platforms checked, the last record's title as the name.
    private func rule(for game: String) -> OpenNATPage.NewRule {
        var rule = OpenNATPage.NewRule()
        rule.game = game
        for profile in profiles where profile.id == game { rule.platforms.insert(profile.platform); rule.name = profile.title }
        return rule
    }

    private func ruleList(_ page: OpenNATPage) -> some View {
        let rules = OpenNATPage.rules(draft, profiles: profiles, clients: page.clients)
        return Panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("游戏设置档").font(.headline)
                    Spacer()
                    Button("应用本页面设置") { confirming = .save }.buttonStyle(.borderedProminent).tint(.teal)
                    Button("新增") { adding = AddSession(rule: OpenNATPage.NewRule()) }
                }
                HStack {
                    Text("游戏列表").font(.subheadline.weight(.semibold))
                    Spacer()
                    if let rules { Text("\(rules.count) Rules (最多限制： 32)").font(.caption).foregroundStyle(.secondary) }
                }
                if let rules {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                        GridRow {
                            Text("游戏"); Text("设备"); Text("通信协议"); Text("Actions")
                        }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(rules) { rule in
                            GridRow {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rule.name).font(.callout.weight(.medium))
                                    HStack(spacing: 6) {
                                        if let platform = rule.platform { Text(platform); Text("|").foregroundStyle(.tertiary) }
                                        Text(rule.port).help(rule.fullPort).monospacedDigit()
                                    }.font(.caption).foregroundStyle(.secondary)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rule.device).font(.callout)
                                    Text(rule.ip).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rule.protocol).font(.callout)
                                    Text(rule.internalPort).font(.caption).foregroundStyle(.secondary)
                                }
                                Button { draft = OpenNATPage.deleting(rule.id, from: draft) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless).help("删除（应用本页面设置后才保存）")
                            }
                        }
                    }
                } else {
                    Text("规则列表中有缺少外部端口的规则：网页在绘制列表时出错，表格保持原样（空白）。")
                        .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if draft != page.stored {
                    Text("规则列表有修改尚未应用。").font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private func run(_ pending: Pending) {
        confirming = nil
        guard let page = reading.value, store.beginOperation(pending == .save ? "正在保存 Open NAT 规则" : "正在切换端口转发") else { return }
        let list = draft
        Task { @MainActor in
            var readAgain = false
            do {
                let client = try store.connectedClient()
                let receipt: ApplyReceipt
                switch pending {
                case .portForwarding(let on): receipt = try await client.setPortForwarding(on)
                case .save: receipt = try await client.saveOpenNATRules(list, page: page)
                }
                notice = (receipt.message, receipt.isVerified ? .success : .attention); readAgain = true
            } catch RouterError.submissionUncertain(let reason) {
                notice = (reason, .attention); readAgain = true
            } catch {
                notice = ("请求没有完成：\(error.localizedDescription)", .error)
                store.handleManagementError(error)
            }
            store.endOperation()
            // The switch does not send the rules: what is not applied yet stays in the list. A page left meanwhile is not read.
            if readAgain, shown {
                let kept = list
                await load()
                if case .portForwarding = pending, kept != reading.value?.stored { draft = kept; showsList = showsList || !kept.isEmpty }
            }
        }
    }
}

/// New Game Profile (addRuleField 776–945): 游戏列表 (Manual first, then gameList), 平台 and 设置.
struct OpenNATAddSheet: View {
    @Environment(RouterStore.self) var store
    let page: OpenNATPage
    /// vts_rulelist_array, which 确认 adds to.
    let list: String
    @State var rule: OpenNATPage.NewRule
    @Binding var profiles: [GameProfile]
    let games: [OpenNATPage.Game]
    let onAdd: (String) -> Void
    let onCancel: () -> Void
    @State private var alert: String?
    /// asusGameProfile (opennat_pf.json); the search only binds once it has loaded.
    @State private var searchList: [GameProfile]?
    @State private var showsOffline = false
    @Environment(\.dismiss) private var dismiss

    static let platformTitles: [(String, String)] = [("PC", "PC"), ("XBOXSerX", "XBOX Series X"), ("XBOXONE", "XBOX ONE"), ("XBOX360", "XBOX 360"),
                                                    ("PS5", "PS 5"), ("PS4", "PS 4"), ("PS3", "PS 3"), ("STEAM", "STEAM"), ("SWITCH", "SWITCH")]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("New Game Profile").font(.title3.weight(.semibold))
                Spacer()
                Button { onCancel(); dismiss() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless)
            }
            Text("游戏列表").font(.headline)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    card("default_game", "Manual")
                    ForEach(games) { card($0.id, HTMLText.visible($0.title, inside: ["div"])) }
                }.padding(.bottom, 6)
            }
            if !rule.manual {
                Text("平台").font(.headline)
                HStack(spacing: 14) {
                    ForEach(Self.platformTitles.filter { shownPlatforms.contains($0.0) }, id: \.0) { platform, title in
                        Toggle(title, isOn: Binding(get: { rule.platforms.contains(platform) },
                                                     set: { if $0 { rule.platforms.insert(platform) } else { rule.platforms.remove(platform) } }))
                    }
                }
            }
            Text("设置").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("服务名称")
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            TextField(searchList == nil ? "" : "Search for games", text: limited(\.name, 30)).disabled(!rule.manual)
                            if searchList != nil, rule.game.hasPrefix("searchResult_") || rule.manual {
                                // The close button (searchOpenNatProfile.js 74–84): Manual's card is clicked, the name cleared.
                                Button { select("default_game") } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).help("清除搜索")
                            }
                        }
                        searchResults
                    }
                }
                if rule.manual {
                    GridRow {
                        Text("通信协议")
                        Picker("", selection: $rule.protocol) {
                            Text("TCP").tag("TCP"); Text("UDP").tag("UDP"); Text("双向").tag("BOTH")
                        }.labelsHidden().frame(width: 140)
                    }
                    GridRow { Text("外部端口"); TextField("", text: limited(\.externalPort, 60)) }
                    GridRow { Text("内部端口"); HStack { TextField("", text: limited(\.internalPort, 5)).frame(width: 90); Text("* 选填").font(.caption).foregroundStyle(.secondary) } }
                }
                GridRow {
                    Text("本地 IP 地址")
                    HStack {
                        TextField("", text: limited(\.localIP, 15)).frame(width: 160)
                        clientMenu
                    }
                }
                if rule.manual {
                    GridRow { Text("来源 IP"); HStack { TextField("", text: limited(\.sourceIP, 15)).frame(width: 160); Text("* 选填").font(.caption).foregroundStyle(.secondary) } }
                }
            }.textFieldStyle(.roundedBorder)
            Spacer()
            HStack {
                Text("“确认”只把规则加入本页的列表；点“应用本页面设置”后才写入路由器。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("确认") { confirm() }.buttonStyle(.borderedProminent).tint(.teal).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .task { await loadSearch() }
        .alert("注意", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) { Button("好") {} } message: { Text(alert ?? "") }
    }

    /// showDropdownClientList('setClientIP', 'ip', 'all', …) (125): the online clients, then under 显示离线设备 the offline ones
    /// of the network map database; AiMesh nodes are left out. A choice fills in its IP; getClientValue (client_function.js
    /// 3863–3868) gives "" for a client whose ip is "offline", whichever list it is in.
    private var clientMenu: some View {
        let clients = TORSettings.dropdownClients(page.clients)
        func choose(_ client: TORSettings.ClientEntry) { rule.localIP = client.ip == "offline" ? "" : client.ip }
        return Menu {
            ForEach(clients.online, id: \.mac) { client in
                Button(HTMLText.visible(TORSettings.dropdownName(client), inside: ["strong"])) { choose(client) }
            }
            if !clients.offline.isEmpty {
                Toggle("显示离线设备", isOn: $showsOffline)
                if showsOffline {
                    ForEach(clients.offline, id: \.mac) { client in
                        Button(HTMLText.visible(TORSettings.dropdownName(client), inside: ["strong"]) + "（离线）") { choose(client) }
                    }
                }
            }
        } label: { Image(systemName: "chevron.up.chevron.down") }.menuStyle(.borderlessButton).fixedSize().help("选择 DHCP 客户端的 IP 地址。")
    }

    /// The platform rows of the game's records (quickAddRule 517–562).
    private var shownPlatforms: Set<String> { Set(profiles.filter { $0.id == rule.game }.map(\.platform)) }

    private func card(_ id: String, _ title: String) -> some View {
        Button { select(id) } label: {
            Text(title).lineLimit(2).frame(width: 120, height: 44)
        }.buttonStyle(.bordered).tint(rule.game == id ? .teal : nil)
    }

    /// quickAddRule (513–563): every platform unchecked, then those of the game's records checked; the name is the last
    /// record's title (blank for Manual, which also enables the name). The other fields keep what they hold, hidden or not,
    /// and 确认 checks them as they are.
    private func select(_ id: String) {
        rule.game = id
        rule.platforms = []
        var name = ""
        for profile in profiles where profile.id == id { rule.platforms.insert(profile.platform); name = profile.title }
        rule.name = name
    }

    private func limited(_ key: WritableKeyPath<OpenNATPage.NewRule, String>, _ length: Int) -> Binding<String> {
        Binding(get: { rule[keyPath: key] }, set: { rule[keyPath: key] = String($0.prefix(length)) })
    }

    /// The search (searchOpenNatProfile.js 10–71): with three characters or more, the titles that contain the text; a
    /// choice adds that record to the profiles under the id searchResult_<n> and selects it.
    @ViewBuilder private var searchResults: some View {
        if rule.manual, let searchList, rule.name.count >= 3 {
            let matches = searchList.indices.filter { searchList[$0].title.uppercased().contains(rule.name.uppercased()) }
            if !matches.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(matches, id: \.self) { index in
                            Button(HTMLText.visible(searchList[index].title, inside: ["div"])) { choose(index) }.buttonStyle(.link)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 140)
            }
        }
    }

    private func choose(_ index: Int) {
        guard var record = searchList?[index] else { return }
        record.id = "searchResult_\(index)"
        profiles.append(record)
        select(record.id)
    }

    /// opennat_pf.json, tried again five seconds after a failure while the window is open.
    private func loadSearch() async {
        while searchList == nil, !Task.isCancelled {
            if let (data, response) = try? await URLSession.shared.data(from: GameProfile.searchCatalog),
               (response as? HTTPURLResponse)?.statusCode == 200, let list = GameProfile.online(data, unwrapping: true) {
                searchList = list; return
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    private func confirm() {
        switch page.adding(rule, to: list, profiles: profiles) {
        case .success(let added): onAdd(added.list); dismiss()
        case .failure(.alert(let message)): alert = message
        case .failure(.invalidIP(let message)): rule.localIP = ""; alert = message
        case .failure(.stopped): break
        }
    }
}
