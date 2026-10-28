import SwiftUI
import RouterCore

/// The main window: the router web interface's menu mirrored one to one (网络设置向导, 一般设置, 高级设置),
/// then this app's own pages under 本机.
struct DashboardView: View {
    @Environment(RouterStore.self) var store
    @State private var query = ""
    @State private var confirmRestart = false

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 220, ideal: 252, max: 300)
        } detail: {
            VStack(spacing: 0) {
                banners
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .background(Theme.canvas)
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if store.isRefreshing { ProgressView().controlSize(.small) }
                    Button { Task { await store.refresh() } } label: { Label("刷新", systemImage: "arrow.clockwise") }
                        .disabled(store.phase != .connected || store.isRefreshing).keyboardShortcut("r").help("刷新路由器状态")
                    Button { confirmRestart = true } label: { Label("重新启动", systemImage: "power") }
                        .disabled(store.phase != .connected || store.operationTitle != nil).help("重新启动路由器")
                }
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "搜索页面或设置")
        .frame(minWidth: 1120, minHeight: 720)
        .confirmationDialog("放弃当前尚未保存的修改？", isPresented: Binding(get: { store.pendingNavigation != nil }, set: { if !$0 { store.pendingNavigation = nil } }), titleVisibility: .visible) {
            Button("放弃并离开", role: .destructive) { store.confirmPendingNavigation() }
            Button("继续编辑", role: .cancel) { store.pendingNavigation = nil }
        } message: {
            Text("这一页的修改尚未保存到路由器，离开后会被丢弃。")
        }
        .confirmationDialog("重新启动路由器？", isPresented: $confirmRestart, titleVisibility: .visible) {
            Button("重新启动", role: .destructive) { Task { await store.restartRouter() } }
        } message: {
            Text("所有设备会暂时断网，路由器通常需要几分钟恢复。应用会等待路由器重新上线并恢复连接。")
        }
    }

    private var title: String {
        switch store.sidebarItem {
        case .menu(let id): store.menuSet.menu(id)?.title ?? "路由器面板"
        case .local(let page): page.rawValue
        }
    }
    /// The router the window manages: model and firmware once read.
    private var subtitle: String {
        if let profile = store.profile { return "\(profile.displayName) · \(profile.firmwareVersion)" }
        return store.snapshot?.sample.identity.model ?? "ASUS 路由器"
    }

    // MARK: Sidebar

    private var sidebar: some View {
        Group {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                menuList
            } else {
                SidebarSearchResults(query: query)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarRouterCard() }
    }

    private var menuList: some View {
        List(selection: Binding(get: { Optional(store.sidebarItem) }, set: { if let item = $0 { store.navigate(.sidebar(item)) } })) {
            // The web lists the setup wizard above its first heading.
            Section { ForEach(store.menuSet.menus.filter { $0.group == nil }) { menuRow($0) } }
            ForEach(WebMenuGroup.allCases, id: \.self) { group in
                let menus = store.menuSet.menus.filter { $0.group == group }
                if !menus.isEmpty { Section(store.menuSet.groupTitle(group)) { ForEach(menus) { menuRow($0) } } }
            }
            Section("本机") {
                ForEach(LocalPage.allCases) { page in
                    Label { Text(page.rawValue) } icon: { SymbolTile(symbol: page.symbol, tint: Theme.tint(local: page)) }
                        .tag(SidebarItem.local(page))
                }
            }
        }.listStyle(.sidebar)
    }

    private func menuRow(_ menu: WebMenu) -> some View {
        Label { Text(menu.title).foregroundStyle(menu.isPending ? .secondary : .primary) } icon: {
            SymbolTile(symbol: menu.symbol, tint: menu.isPending ? .gray : Theme.tint(menu: menu.id))
        }
            .lineLimit(1)
            .tag(SidebarItem.menu(menu.id))
            .help(menu.isPending ? "\(menu.title)：尚未做成原生页面" : menu.title)
    }

    // MARK: Detail

    @ViewBuilder private var banners: some View {
        if let operation = store.operationTitle {
            HStack { ProgressView().controlSize(.small); Text(operation).font(.callout); Spacer(); Text("请保持应用运行").font(.caption).foregroundStyle(.secondary) }.padding(12).background(.teal.opacity(0.08))
        }
        if store.credentialAccess.state.isWaiting && store.phase != .connected && store.sidebarItem != .local(.connection) {
            HStack { Image(systemName: "key.fill").foregroundStyle(.teal); Text("正在等待钥匙串读取，路由器尚未开始连接。系统对话框可能在其他显示器上。").font(.callout); Spacer(); Button("查看连接") { store.open(.connection) } }.padding(12).background(.teal.opacity(0.06))
        }
        if let error = store.errorMessage {
            HStack {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                Text(error).font(.callout)
                if let at = store.reconnectAt { ReconnectCountdown(at: at).font(.callout) }
                Spacer()
                if store.phase != .connecting { Button("连接设置") { store.open(.connection) }.buttonStyle(.link) }
            }.padding(14).background(.orange.opacity(0.08))
        }
        if let notice = store.bannerNotice {
            HStack {
                Image(systemName: "info.circle.fill").foregroundStyle(.teal)
                Text(notice).font(.callout)
                Spacer()
                Button { store.bannerNotice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("关闭")
            }.padding(12).background(.teal.opacity(0.06))
        }
    }

    @ViewBuilder private var content: some View {
        switch store.sidebarItem {
        case .menu(let id):
            if let menu = store.menuSet.menu(id) { WebMenuView(menu: menu) }
        case .local(let page):
            Group {
                switch page {
                case .deviceHistory: DeviceHistoryView(model: store.monitor)
                case .health: NetworkHealthView(model: store.networkHealth)
                case .connection: ConnectionView()
                }
            }.environment(\.webPath, "本机").environment(\.pageTint, Theme.tint(local: page))
        }
    }
}

/// The router the window manages, at the foot of the sidebar: model, state, and the way to the connection settings.
struct SidebarRouterCard: View {
    @Environment(RouterStore.self) var store
    var body: some View {
        Button { store.open(.connection) } label: {
            HStack(spacing: 10) {
                BrandIcon(size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.profile?.displayName ?? store.snapshot?.sample.identity.model ?? "ASUS 路由器")
                        .font(.callout.weight(.semibold)).lineLimit(1)
                    StatusDot(color: store.statusColor, text: store.statusTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(Theme.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).padding(.horizontal, 10).padding(.bottom, 10).padding(.top, 4)
        .help("\(store.address) · 打开连接设置")
    }
}

/// Sidebar search over the mirrored pages, their switch choices and every setting's name.
struct SidebarSearchResults: View {
    @Environment(RouterStore.self) var store
    let query: String

    var body: some View {
        let results = SidebarSearch.results(for: query, store: store)
        List {
            if results.isEmpty {
                Text("没有找到“\(query)”").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(results) { result in
                Button { open(result) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(result.title, systemImage: result.symbol).lineLimit(1)
                        Text(result.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).padding(.leading, 26)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.listStyle(.sidebar)
    }

    private func open(_ result: SidebarSearch.Result) {
        switch result.target {
        case .menu(let id): store.navigate(.sidebar(.menu(id)))
        case .web(let location): store.navigate(.web(location))
        case .vpnSetting(let key): store.openVPN(settingKey: key)
        case .local(let page): store.open(page)
        }
    }
}

@MainActor
enum SidebarSearch {
    struct Result: Identifiable {
        enum Target { case menu(String), web(WebLocation), vpnSetting(String), local(LocalPage) }
        let id: String
        let title: String
        let path: String
        let symbol: String
        let target: Target
    }

    /// Menus, tabs and switch choices first, then this app's pages, then settings; only what the web shows on
    /// this router right now.
    static func results(for query: String, store: RouterStore, limit: Int = 80) -> [Result] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return [] }
        func matches(_ value: String) -> Bool { value.localizedCaseInsensitiveContains(text) }
        var pages: [Result] = []
        var settings: [Result] = []
        for menu in store.menuSet.menus {
            if matches(menu.title) {
                pages.append(Result(id: "menu:\(menu.id)", title: menu.title, path: menu.group?.rawValue ?? "", symbol: menu.symbol, target: .menu(menu.id)))
            }
            for page in menu.pages where store.isVisible(page) {
                let parts = page.parts.filter(store.isVisible)
                let pageNames = page.title == menu.title ? [menu.title] : [menu.title, page.title]
                if page.title != menu.title, matches(page.title) {
                    pages.append(Result(id: "page:\(page.id)", title: page.title, path: menu.title, symbol: menu.symbol,
                                        target: .web(WebLocation(menu: menu.id, page: page.id, part: store.partID(in: page)))))
                }
                for part in parts {
                    let location = WebLocation(menu: menu.id, page: page.id, part: part.id)
                    if parts.count > 1, part.title != page.title, matches(part.title) {
                        pages.append(Result(id: "part:\(page.id)#\(part.id)", title: part.title, path: pageNames.joined(separator: " › "),
                                            symbol: menu.symbol, target: .web(location)))
                    }
                    let path = (parts.count > 1 ? pageNames + [part.title] : pageNames).joined(separator: " › ")
                    let sections = part.content.sectionIDs.filter(store.isVisible(section:)).compactMap(SettingsCatalog.section)
                    for section in sections {
                        let isVPN = VPNCenterDestination(sectionID: section.id) != nil
                        for field in section.fields where store.isVisible(field: field.key) {
                            let label = (isVPN ? VPNPresentation.label(for: field) : field.label).trimmingCharacters(in: .whitespaces)
                            guard matches(label) else { continue }
                            settings.append(Result(id: "field:\(section.id).\(field.key)", title: label,
                                                   path: sections.count > 1 ? "\(path) · \(section.title)" : path,
                                                   symbol: "slider.horizontal.3", target: isVPN ? .vpnSetting(field.key) : .web(location)))
                        }
                    }
                }
            }
        }
        let local = LocalPage.allCases.filter { matches($0.rawValue) }.map { Result(id: "local:\($0.rawValue)", title: $0.rawValue, path: "本机", symbol: $0.symbol, target: .local($0)) }
        return Array((pages + local + settings).prefix(limit))
    }
}
