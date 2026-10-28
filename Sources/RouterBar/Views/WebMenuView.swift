import SwiftUI
import RouterCore

/// One menu of the router's web interface: its tab bar, the open page's own switch, and the native content
/// that stands for the page. Tabs, switches and names follow the router's own web menu (RouterCore.WebMenuSet).
struct WebMenuView: View {
    @Environment(RouterStore.self) var store
    let menu: WebMenu

    var body: some View {
        let page = store.page(in: menu)
        let parts = page.parts.filter(store.isVisible)
        let partID = store.partID(in: page)
        let part = parts.first { $0.id == partID } ?? page.parts[0]
        VStack(spacing: 0) {
            header(page: page, parts: parts, part: part)
            WebPartView(menu: menu, page: page, part: part, multipart: parts.count > 1)
                .id(WebLocation(menu: menu.id, page: page.id, part: part.id))
                .environment(\.webPath, eyebrow(page: page, multipart: parts.count > 1))
                // A page that does not fill the height (still reading, or a read error) starts at the top.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .environment(\.pageTint, menu.isPending ? .gray : Theme.tint(menu: menu.id))
    }

    /// The page header's eyebrow: where the page sits in the web menu, without repeating the page's own title.
    private func eyebrow(page: WebPage, multipart: Bool) -> String? {
        var names = [menu.title]
        if page.title != menu.title { names.append(page.title) }
        if !multipart { names.removeLast() }
        if names.isEmpty, let group = menu.group { names = [group.rawValue] }
        return names.isEmpty ? nil : names.joined(separator: " › ")
    }

    @ViewBuilder private func header(page: WebPage, parts: [WebPart], part: WebPart) -> some View {
        let tabs = menu.tabs.filter(store.isVisible)
        let showsTabs = page.kind == .tab && tabs.count > 1
        let showsBack = page.kind != .landing && menu.home.kind == .landing
        if showsTabs || showsBack || parts.count > 1 {
            VStack(alignment: .leading, spacing: 10) {
                if showsTabs || showsBack {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            if showsBack {
                                Button { store.open(page: menu.home, in: menu) } label: { Label(menu.home.title, systemImage: "chevron.left") }
                                    .buttonStyle(.link).padding(.trailing, 8)
                            }
                            if showsTabs { ForEach(tabs) { tab in WebTabChip(tab: tab, selected: tab.id == page.id) { store.open(page: tab, in: menu) } } }
                        }.padding(.vertical, 1)
                    }
                }
                if parts.count > 1 {
                    Picker("切换", selection: Binding(get: { part.id }, set: { store.navigate(.web(WebLocation(menu: menu.id, page: page.id, part: $0))) })) {
                        ForEach(parts) { Text($0.title).tag($0.id) }
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
            .padding(.horizontal, Theme.page).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
        }
    }
}

/// A tab of the web menu's tab bar. Tabs without a native page yet are drawn quieter.
struct WebTabChip: View {
    let tab: WebPage
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Text(tab.title).font(.callout.weight(selected ? .semibold : .regular)).lineLimit(1)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .foregroundStyle(selected ? Theme.accent : tab.isPending ? Color.secondary.opacity(0.7) : Color.secondary)
                .background(selected ? Theme.accent.opacity(0.14) : hovering ? Theme.well : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tab.isPending ? "\(tab.title)：尚未做成原生页面" : tab.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The native content of one page or switch choice.
struct WebPartView: View {
    @Environment(RouterStore.self) var store
    let menu: WebMenu
    let page: WebPage
    let part: WebPart
    let multipart: Bool

    private var title: String { multipart ? part.title : page.title }

    var body: some View {
        switch part.content {
        case .settings(let ids, let accessory):
            let visible = ids.filter(store.isVisible(section:))
            // The page keeps its editors for as long as it lives, so a section the web shows later makes a new page.
            SettingsPageView(editors: visible.map(store.settingsModel(for:)), title: title, symbol: menu.symbol, accessory: accessory,
                             note: note(hidden: ids.filter { !visible.contains($0) }) ?? fieldNote(sections: visible))
                .id(visible)
        case .native(let feature):
            NativeFeatureView(feature: feature)
        case .pending(let text, let related):
            PendingPageView(title: title, symbol: menu.symbol, text: text, webPage: part.url ?? page.id, related: related)
        }
    }

    /// Explains a section the web hides on this page right now.
    private func note(hidden: [String]) -> SettingsPageNote? {
        guard !hidden.isEmpty else { return nil }
        switch hidden.compactMap({ WebMenuCatalog.condition(ofSection: $0) }).first {
        case .perBandWireless:
            if store.wirelessModeKnown {
                return SettingsPageNote(text: "这台路由器的主 Wi-Fi 由“网络”页面管理，网页的一般设置也不再显示 Wi-Fi 名称与安全设置；这里只保留频段本身的设置。",
                                        link: ("前往“网络”", .networks))
            }
            return SettingsPageNote(text: "正在确认主 Wi-Fi 的设置方式。确认后，若主 Wi-Fi 按频段设置，这里会显示 Wi-Fi 名称与安全设置。")
        case .dualWAN:
            return SettingsPageNote(text: "双线路未开启，网页不显示第二 WAN 的设置。")
        case nil:
            return nil
        }
    }

    /// Explains rows the web hides inside the sections shown, such as the professional page's AP 隔离 and WiFi7 模式.
    private func fieldNote(sections: [String]) -> SettingsPageNote? {
        let fields = sections.compactMap(SettingsCatalog.section).flatMap(\.fields)
        guard fields.contains(where: { WebMenuCatalog.condition(ofField: $0.key) == .perBandWireless && !store.isVisible(field: $0.key) }) else { return nil }
        if store.wirelessModeKnown {
            return SettingsPageNote(text: "这台路由器的主 Wi-Fi 由“网络”页面管理，网页的专业设置不显示 AP 隔离和 WiFi7 模式；这两项在“网络”页面按网络设置。",
                                    link: ("前往“网络”", .networks))
        }
        return SettingsPageNote(text: "正在确认主 Wi-Fi 的设置方式。确认后，若主 Wi-Fi 按频段设置，这里会显示 AP 隔离和 WiFi7 模式。")
    }
}

/// The native view that stands for a web page or switch choice.
struct NativeFeatureView: View {
    @Environment(RouterStore.self) var store
    let feature: NativeFeature
    var body: some View {
        switch feature {
        case .overview: OverviewView()
        case .clients: DevicesView(monitor: store.monitor)
        case .mesh: MeshView()
        case .networks: NetworksView(model: store.networks)
        case .usbApplications: USBApplicationsView()
        case .radioChannels(let unit): ScrollView { RadioChannelsView(unit: unit).padding(28) }
        case .vpnStatus: VPNStatusView(model: store.vpnCenter)
        case .vpn(let scope): VPNCenterView(model: store.vpnCenter, scope: scope)
        case .administrator: AdministratorPageView()
        case .firmware: FirmwareView(model: store.firmware)
        case .settingBackup: SettingBackupView()
        case .systemLog: DiagnosticsView(mode: .systemLog)
        case .wirelessClients: WirelessClientsView()
        case .routeTable: DiagnosticsView(mode: .routeTable)
        case .connections: DiagnosticsView(mode: .connections)
        case .networkAnalysis: DiagnosticsView(mode: .networkAnalysis)
        case .netstat: DiagnosticsView(mode: .netstat)
        case .systemInfo: SystemInfoView()
        case .trafficMonitor(let mode): TrafficMonitorView(mode: mode)
        case .dhcpLeases: DHCPLeasesView()
        case .ipv6Status: IPv6StatusView()
        case .portForwards: PortForwardStatusView()
        // One view for the three record pages; the identity keeps each page's reading apart.
        case .aiProtection(let kind): AiProtectionRecordsView(kind: kind).id(kind)
        case .bandwidthMonitor: BandwidthMonitorView()
        case .webHistory: WebHistoryView()
        case .trafficStatistics: TrafficStatisticsView()
        case .trafficMonitorSettings: TrafficMonitorSettingsView()
        case .aiCloudLog: AiCloudLogView()
        case .wps: WPSView()
        case .wds: WDSView()
        case .roamingBlock: RoamingBlockListView()
        case .mlo: MLOView()
        case .smartConnectRules: SmartConnectRulesView()
        case .vlanPorts: VLANPortsView()
        case .vlanProfiles: VLANProfilesView()
        case .tor: TORView()
        case .qosUserPriority: QoSUserPriorityView()
        case .internetSpeed: InternetSpeedView()
        case .uuAccelerator: UUAcceleratorView()
        case .printerServer: ScrollView { PrinterServerIntro().padding(28) }
        case .privacy: PrivacyPolicyView()
        case .alexa: AlexaView()
        case .wakeOnLAN: WakeOnLANView()
        case .siteSurvey: SiteSurveyView()
        case .aiCloud: AiCloudView()
        case .aiCloudSettings: AiCloudSettingsView()
        case .operationMode: OperationModeView()
        case .openNAT: OpenNATView()
        case .gameBoost: GameBoostView()
        case .dualWAN: DualWANView()
        case .ipv6SecondWAN: IPv61View()
        case .pptpClient: VPNClientPPTPView()
        case .webProtector: WebProtectorView()
        case .parentalControl: ParentalControlView()
        case .aiDisk: AiDiskView()
        case .setupWizard: QISWizardView()
        }
    }
}

/// A web page without a native page yet: what it is for, the native pages that hold related settings, and a link to
/// the router's own page. Nothing is embedded; the router allows one administrator login at a time, which the link says.
struct PendingPageView: View {
    @Environment(RouterStore.self) var store
    let title: String
    let symbol: String
    let text: String
    let webPage: String
    let related: [WebLink]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: title, subtitle: text, symbol: symbol)
                NoticeBanner(message: "这一页尚未做成原生页面，本应用暂时不能查看或修改这里的设置。网页版对应页面：\(webPage)。", tone: .information)
                if let url = store.endpoint?.resource(webPage) {
                    Panel {
                        VStack(alignment: .leading, spacing: 8) {
                            Link(destination: url) { Label("在浏览器中打开这一页", systemImage: "safari") }.font(.callout.weight(.medium))
                            Text("需要在浏览器中登录路由器。路由器同一时间只允许一个管理员登录，在浏览器登录可能会让本应用的连接失效，之后可在“连接设置”重新连接。")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if !related.isEmpty {
                    Panel {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("相关设置可以在这些页面查看").font(.headline)
                            ForEach(related, id: \.self) { link in
                                if let location = location(of: link) {
                                    Button { store.navigate(.web(location)) } label: {
                                        Label(store.menuSet.names(of: location).joined(separator: " › "), systemImage: "arrow.up.forward.app")
                                    }.buttonStyle(.link)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.padding(28)
        }
    }

    private func location(of link: WebLink) -> WebLocation? {
        switch link {
        case .section(let id): store.menuSet.location(ofSection: id)
        case .feature(let feature): store.menuSet.location(of: feature)
        }
    }
}

/// USB 相关应用 (APP_Installation.asp): the web's list of USB applications, each opening its page.
struct USBApplicationsView: View {
    @Environment(RouterStore.self) var store
    private struct Item: Identifiable {
        let title: String
        let detail: String
        let symbol: String
        /// The page the web opens; nil when the web installs it as a separate download.
        let page: String?
        var id: String { title }
    }
    private let items: [Item] = [
        Item(title: "AiDisk", detail: "通过互联网共享您USB硬盘内的文件。", symbol: "externaldrive.badge.wifi", page: "aidisk.asp"),
        Item(title: "服务器中心", detail: "媒体服务器、网络共享（Samba）与 FTP 共享。", symbol: "server.rack", page: "mediaserver.asp"),
        Item(title: "网络打印机服务器", detail: "共享连接在 USB 端口上的打印机。", symbol: "printer", page: "PrinterServer.asp"),
        Item(title: "Time Machine", detail: "启用 Time Machine 备份功能", symbol: "clock.arrow.circlepath", page: "Advanced_TimeMachine.asp"),
        Item(title: "下载大师", detail: "由路由器直接下载文件。网页版需要先安装到 USB 硬盘，本应用不提供。", symbol: "arrow.down.circle", page: nil)
    ]
    private var menu: WebMenu? { store.menuSet.menu("menu_APP") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "USB 相关应用", subtitle: "通过路由器的 USB 端口共享硬盘、打印机，或作为 Time Machine 备份位置。", symbol: "externaldrive.connected.to.line.below")
                VStack(spacing: 12) {
                    ForEach(items) { item in row(item) }
                }
            }.padding(28)
        }
    }

    private func row(_ item: Item) -> some View {
        let page = item.page.flatMap { menu?.page($0) }
        return Button { if let menu, let page { store.open(page: page, in: menu) } } label: {
            Panel {
                HStack(spacing: 16) {
                    Image(systemName: item.symbol).font(.system(size: 22)).foregroundStyle(page == nil ? Color.secondary : Color.teal).frame(width: 40)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.title).font(.headline)
                        Text(item.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if page == nil {
                        Text("不提供").font(.caption).foregroundStyle(.secondary)
                    } else {
                        if page?.isPending == true { Text("尚未原生").font(.caption).foregroundStyle(.secondary) }
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                }
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(page == nil)
    }
}

/// 系统管理 › 系统设置 › 管理员账号.
struct AdministratorPageView: View {
    @Environment(RouterStore.self) var store
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "管理员账号", subtitle: "修改登录路由器使用的管理员名称或密码。网页版与本应用共用这个账号。", symbol: "person.crop.circle.badge.checkmark")
                if store.phase != .connected { ConnectionRequiredView() }
                AdministratorView()
            }.padding(28)
        }
    }
}
