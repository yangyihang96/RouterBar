import Foundation

/// The menus the app shows for the router it is connected to.
///
/// They come from the router itself: its own menuTree.js evaluated against its own state.js (RouterMenuEvaluator)
/// gives the menus, tabs, names and what the web hides on this router. Each page is then matched by its web address
/// to the native content written for it (the reference catalog, WebMenuCatalog, which mirrors an RT-BE88U on
/// 3006.102.5). A page without native content opens as an explanation. Pages whose native requests follow the
/// 3.0.0.6 web code open as an explanation on other firmware lines, so the app never sends a request that the
/// router's own page would not.
public struct WebMenuSet: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// The reference catalog, until a router has been read.
        case reference
        /// The connected router's own menu.
        case router(model: String, firmware: String)
        /// The router's menu could not be read; the reference catalog stands in.
        case fallback(String)
    }
    public let menus: [WebMenu]
    public let groupTitles: [WebMenuGroup: String]
    public let source: Source

    public init(menus: [WebMenu], groupTitles: [WebMenuGroup: String], source: Source) {
        self.menus = menus; self.groupTitles = groupTitles; self.source = source
    }

    public static let reference = WebMenuSet(menus: WebMenuCatalog.menus,
                                             groupTitles: [.general: WebMenuGroup.general.rawValue, .advanced: WebMenuGroup.advanced.rawValue],
                                             source: .reference)
    /// The reference catalog for a router whose own menu could not be read: its radios as far as they are known, and
    /// every page whose requests follow the reference web code as an explanation, since it is not known whether this
    /// router has that page (RouterClient refuses such requests for this router too).
    public static func fallback(_ reason: String, profile: RouterProfile? = nil) -> WebMenuSet {
        let text = "未能读取这台路由器的网页菜单（\(reason)），无法确认它有这一页、请求是否相同。为避免发出与路由器网页不同的修改，请在浏览器中使用这一页。"
        let menus = reference.menus.map { menu in
            WebMenu(id: menu.id, title: menu.title, group: menu.group, symbol: menu.symbol, pages: menu.pages.map { page in
                WebPage(page.id, page.kind, page.title, condition: page.condition,
                        parts: radioParts(page.parts, profile: profile).map { referenceChecked($0, text: text) })
            }, entry: menu.entry)
        }
        return WebMenuSet(menus: menus, groupTitles: reference.groupTitles, source: .fallback(reason))
    }

    public func groupTitle(_ group: WebMenuGroup) -> String { groupTitles[group] ?? group.rawValue }
    public func menu(_ id: String) -> WebMenu? { menus.first { $0.id == id } }

    /// Where a catalog section is edited natively.
    public func location(ofSection id: String) -> WebLocation? {
        locations { $0.content.sectionIDs.contains(id) }.first
    }
    /// Where a native view lives.
    public func location(of feature: NativeFeature) -> WebLocation? {
        locations { part in
            switch part.content {
            case .native(let native): native == feature
            case .settings(_, let accessory): accessory == feature
            case .pending: false
            }
        }.first
    }
    public func locations(where matches: (WebPart) -> Bool) -> [WebLocation] {
        menus.flatMap { menu in menu.pages.flatMap { page in page.parts.filter(matches).map { WebLocation(menu: menu.id, page: page.id, part: $0.id) } } }
    }
    /// The web's names for a location: the menu, the tab when it is named differently, and the switch choice
    /// when the page has a switch, e.g. ["无线网络", "一般设置", "5 GHz"].
    public func names(of location: WebLocation) -> [String] {
        guard let menu = menu(location.menu), let page = menu.page(location.page) else { return [] }
        var names = [menu.title]
        if page.title != menu.title { names.append(page.title) }
        // A switch choice named like its page (QoS, VLAN) adds nothing to the path.
        if page.parts.count > 1, let part = page.parts.first(where: { $0.id == location.part }), !names.contains(part.title) { names.append(part.title) }
        return names
    }
    /// Pages this router lists that have no native content, in menu order.
    public var webOnlyPages: [WebPage] { menus.flatMap { $0.pages.filter { $0.parts.allSatisfy { if case .pending = $0.content { true } else { false } } } } }

    // MARK: Building

    /// The router's menu with native content matched by web address. `profile` decides the radio switches and
    /// which native pages apply to the firmware line.
    public static func build(entries: [RouterMenuEntry], profile: RouterProfile?) -> WebMenuSet {
        let registry = WebMenuRegistry.shared
        // Every page address the router lists, and whether the web shows it anywhere: a page switch that opens
        // another page shows only when the router lists that page and does not hide it.
        var listed: [String: Bool] = [:]
        for entry in entries { for tab in entry.tabs { listed[tab.url] = (listed[tab.url] ?? false) || (tab.visible && entry.visible) } }
        var group: WebMenuGroup?
        var headings = 0
        var titles: [WebMenuGroup: String] = [:]
        var menus: [WebMenu] = []
        for entry in entries {
            if entry.isGroupHeading {
                guard entry.visible else { continue }
                headings += 1
                let next: WebMenuGroup = headings == 1 ? .general : .advanced
                group = next
                if titles[next] == nil { titles[next] = entry.name }
                continue
            }
            guard entry.visible else { continue }
            // A page that another page opens through its own switch (QoS rules, past 24 hours, VLAN profiles…) is
            // that switch's choice, not a page of its own; a linked page with no native content cannot be reached.
            // The page the menu opens (IFTTT when Alexa is hidden) stays, as an explanation when it has no native content,
            // unless this menu shows the page that offers it as a switch choice.
            let shown = Set(entry.tabs.filter(\.visible).map(\.url))
            let pages = entry.tabs.filter { tab in
                guard tab.visible else { return false }
                if tab.url == entry.entry { return !(registry.host(ofSwitch: tab.url).map(shown.contains) ?? false) }
                return !registry.isSwitchPage(tab.url) && (tab.kind != .subpage || registry.page(tab.url) != nil)
            }.map { tab in page(for: tab, menu: entry, registry: registry, listed: listed, profile: profile) }
            guard !pages.isEmpty else { continue }
            menus.append(WebMenu(id: entry.index, title: entry.name, group: group, symbol: registry.symbol(for: entry.index),
                                 pages: pages, entry: entry.entry))
        }
        let source: Source = profile.map { .router(model: $0.displayName, firmware: $0.firmwareVersion) } ?? .router(model: "", firmware: "")
        return WebMenuSet(menus: menus, groupTitles: titles, source: source)
    }

    static func page(for tab: RouterMenuEntry.Tab, menu entry: RouterMenuEntry, registry: WebMenuRegistry,
                     listed: [String: Bool], profile: RouterProfile?) -> WebPage {
        // A linked page the menu opens first (Alexa when IFTTT is hidden) shows like the menu's own page: no tab bar.
        let kind: WebPage.Kind = switch tab.kind {
        case .page: .landing
        case .tab: .tab
        case .subpage: tab.url == entry.entry ? .landing : .subpage
        }
        guard let known = registry.page(tab.url) else {
            let title = kind == .tab ? tab.name : kind == .landing ? entry.name : (registry.title(for: tab.url) ?? entry.name)
            return WebPage(tab.url, kind, title, .pending(webOnlyText, related: []))
        }
        let title = kind == .tab ? tab.name : kind == .landing ? entry.name : known.title
        var parts = radioParts(known.parts, profile: profile)
        // A choice that opens another web page needs that page listed and shown on this router.
        parts = parts.filter { part in part.url.map { listed[$0] == true } ?? true }
        if let profile, !profile.isReferenceFirmware { parts = parts.map { referenceChecked($0, text: firmwareText(profile)) } }
        return WebPage(tab.url, kind, title, condition: known.condition, parts: parts)
    }

    static let webOnlyText = "这台路由器网页上的这一页还没有对应的原生页面。可以在浏览器中打开路由器网页的这一页；路由器同一时间只允许一个管理员登录，在浏览器登录可能会让 App 的连接失效。"

    /// A native page whose requests follow the 3.0.0.6 web code stays an explanation (`text`) where that code may not
    /// be the router's: other firmware lines, and a router whose menu could not be read.
    static func referenceChecked(_ part: WebPart, text: String) -> WebPart {
        switch part.content {
        case .native(let feature) where feature.followsReferenceWebCode:
            return WebPart(part.id, part.title, url: part.url, condition: part.condition, .pending(text, related: []))
        case .settings(let sections, let accessory?) where accessory.followsReferenceWebCode:
            return WebPart(part.id, part.title, url: part.url, condition: part.condition, .settings(sections, accessory: nil))
        default:
            return part
        }
    }

    static func firmwareText(_ profile: RouterProfile) -> String {
        "这一页的原生实现按 3.0.0.6（3006.102）固件的网页逐项核对过；这台路由器是 \(profile.branch.title) 固件（\(profile.firmwareVersion)），网页的请求可能不同。为避免发出与路由器网页不同的修改，请在浏览器中使用这一页。"
    }

    /// The per-band switches (一般设置, 专业设置, MAC 过滤, RADIUS) follow the router's radios: the reference
    /// catalog's 2.4 GHz and 5 GHz choices stand for every radio of that band, renumbered to its unit.
    static func radioParts(_ parts: [WebPart], profile: RouterProfile?) -> [WebPart] {
        guard let radios = profile?.radios, !radios.isEmpty, Set(parts.map(\.id)) == ["2g", "5g"],
              let low = parts.first(where: { $0.id == "2g" }), let high = parts.first(where: { $0.id == "5g" }) else { return parts }
        let referenceShape = radios.map(\.band) == [.ghz2_4, .ghz5] && radios.map(\.unit) == [0, 1]
        if referenceShape { return parts }
        return radios.map { radio in
            let template = radio.band == .ghz2_4 ? low : high
            let content: WebContent
            switch template.content {
            case .settings(let sections, let accessory):
                let ids = sections.compactMap { SettingsCatalog.radioSectionID(templateID: $0, radio: radio) }
                // The channel control covers wl0 on 2.4 GHz and wl1 on 5 GHz (RouterRadioChannels).
                var channel = accessory
                if case .radioChannels(_)? = accessory {
                    let covered = (radio.unit == 0 && radio.band == .ghz2_4) || (radio.unit == 1 && radio.band == .ghz5)
                    channel = covered ? .radioChannels(radio.unit) : nil
                }
                content = .settings(ids, accessory: channel)
            default:
                content = template.content
            }
            return WebPart("wl\(radio.unit)", radio.title, url: template.url, condition: template.condition, content)
        }
    }
}

extension NativeFeature {
    /// Native pages whose requests were written from the 3.0.0.6 web code and checked against it. On other firmware
    /// lines the same page may send other fields, so these open as an explanation there. Read-only pages, firmware
    /// upload and the settings backup use requests that every firmware line shares.
    public var followsReferenceWebCode: Bool {
        switch self {
        case .overview, .clients, .usbApplications, .vpnStatus, .firmware, .settingBackup,
             .systemLog, .wirelessClients, .routeTable, .connections, .networkAnalysis, .netstat, .systemInfo,
             .trafficMonitor, .dhcpLeases, .ipv6Status, .portForwards, .aiProtection,
             .bandwidthMonitor, .webHistory, .trafficStatistics, .trafficMonitorSettings, .aiCloudLog,
             .wps, .wds, .roamingBlock, .mlo, .smartConnectRules, .vlanPorts, .vlanProfiles, .tor, .qosUserPriority:
            return false
        case .mesh, .networks, .radioChannels, .vpn, .administrator, .internetSpeed, .uuAccelerator, .printerServer,
             .privacy, .alexa, .wakeOnLAN, .siteSurvey, .aiCloud, .aiCloudSettings, .operationMode, .openNAT, .gameBoost,
             .dualWAN, .ipv6SecondWAN, .pptpClient, .webProtector, .parentalControl, .aiDisk, .setupWizard:
            return true
        }
    }
}

/// The reference catalog by web address: the native content written for each page, and each menu's symbol.
struct WebMenuRegistry: Sendable {
    static let shared = WebMenuRegistry(menus: WebMenuCatalog.menus)
    private let pages: [String: WebPage]
    /// Each switch choice's own web page, and the page that offers it.
    private let switchHosts: [String: String]
    private let symbols: [String: String]
    init(menus: [WebMenu]) {
        var pages: [String: WebPage] = [:]
        for menu in menus { for page in menu.pages where pages[page.id] == nil { pages[page.id] = page } }
        self.pages = pages
        var hosts: [String: String] = [:]
        for menu in menus { for page in menu.pages { for url in page.parts.compactMap(\.url) where hosts[url] == nil { hosts[url] = page.id } } }
        self.switchHosts = hosts
        self.symbols = Dictionary(menus.map { ($0.id, $0.symbol) }, uniquingKeysWith: { first, _ in first })
    }
    func page(_ url: String) -> WebPage? { pages[url] }
    /// Opened by another page's switch.
    func isSwitchPage(_ url: String) -> Bool { switchHosts[url] != nil && pages[url] == nil }
    /// The page whose switch opens `url`, when `url` is a switch page.
    func host(ofSwitch url: String) -> String? { isSwitchPage(url) ? switchHosts[url] : nil }
    func title(for url: String) -> String? { pages[url]?.title }
    func symbol(for index: String) -> String { symbols[index] ?? Self.extraSymbols[index] ?? "square.grid.2x2" }
    /// Menus the reference router does not show, as other firmware lines name them.
    static let extraSymbols: [String: String] = [
        "menu_GuestNetwork": "person.2.wave.2", "menu_Guest_network": "person.2.wave.2", "menu_TrafficManager": "speedometer",
        "menu_QoS": "speedometer", "menu_Tools": "wrench.and.screwdriver", "menu_DSL": "phone.connection",
        "menu_Modem": "antenna.radiowaves.left.and.right", "menu_Feedback": "envelope", "menu_SmartHome": "house",
        "menu_Captive_Portal": "rectangle.portrait.and.arrow.right", "menu_InstantGuard": "lock.laptopcomputer"
    ]
}

extension SettingsCatalog {
    /// A section by id, including the per-radio sections of radios the reference catalog does not have
    /// (see `radioSectionID`).
    public static func section(_ id: String) -> SettingSection? {
        if let section = sectionsByID[id] { return section }
        return radioSection(id)
    }
    private static let sectionsByID: [String: SettingSection] = Dictionary(sections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    static let radioPrefixes = ["wifi", "radio", "radius", "acl", "band"]

    /// The section that stands for `templateID` (e.g. "wifi1") on `radio`. The reference catalog's own ids stay for
    /// wl0 on 2.4 GHz and wl1 on 5 GHz; any other radio gets "wifi2@6 GHz", which `section(_:)` builds from the
    /// reference catalog's section of the same band. The 160 MHz option exists only for 5 GHz radios.
    public static func radioSectionID(templateID: String, radio: RouterProfile.Radio) -> String? {
        guard let prefix = radioPrefixes.first(where: { templateID.hasPrefix($0) }) else { return templateID }
        if prefix == "band", radio.band != .ghz5 { return nil }
        if (radio.unit == 0 && radio.band == .ghz2_4) || (radio.unit == 1 && radio.band == .ghz5 && radio.title == "5 GHz") {
            return "\(prefix)\(radio.unit)"
        }
        return "\(prefix)\(radio.unit)@\(radio.title)"
    }

    /// Builds "wifi2@6 GHz" from the reference 5 GHz section ("wifi1"), or a 2.4 GHz one from "wifi0": the same
    /// fields for the radio's unit, with the choices asus.js gives a 6 GHz radio (WPA3 only, Auto or AX only).
    static func radioSection(_ id: String) -> SettingSection? {
        let pieces = id.split(separator: "@", maxSplits: 1).map(String.init)
        guard pieces.count == 2, let prefix = radioPrefixes.first(where: { pieces[0].hasPrefix($0) }),
              let unit = Int(pieces[0].dropFirst(prefix.count)), (0...3).contains(unit) else { return nil }
        let title = pieces[1]
        let lowBand = title.hasPrefix("2.4")
        let sixGHz = title.hasPrefix("6 GHz")
        guard let template = sectionsByID["\(prefix)\(lowBand ? 0 : 1)"] else { return nil }
        let from = "wl\(lowBand ? 0 : 1)_", to = "wl\(unit)_"
        var section = template
        section.id = id
        let bandName = lowBand ? "2.4 GHz" : "5 GHz"
        section.title = template.title.replacingOccurrences(of: bandName, with: title)
        section.subtitle = template.subtitle.replacingOccurrences(of: bandName, with: title)
        section.fields = template.fields.map { field in
            var field = field
            field.key = field.key.replacingOccurrences(of: from, with: to)
            if var packed = field.packed { packed.key = packed.key.replacingOccurrences(of: from, with: to); field.packed = packed }
            if sixGHz, field.key == "wl\(unit)_auth_mode_x" {
                // Enhanced Open only where the router supports Wi-Fi 7 (WirelessSecurityRules.options).
                field.options = [SettingOption(value: "sae", label: "WPA3-Personal"), SettingOption(value: "owe", label: "Enhanced Open (OWE)")]
                field.note = "6 GHz 只能使用 WPA3-Personal，支持 Wi-Fi 7 的路由器另可使用 Enhanced Open（OWE）。"
            }
            // asus.js wlMode: a 6 GHz radio offers Auto and AX only.
            if sixGHz, field.key == "wl\(unit)_nmode_x" { field.options = field.options.filter { ["0", "9"].contains($0.value) } }
            return field
        }
        return section
    }
}
