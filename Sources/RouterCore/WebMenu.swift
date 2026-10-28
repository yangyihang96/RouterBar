import Foundation

/// The router web interface's own navigation, which the app mirrors one to one. `WebMenuCatalog` is the reference:
/// the menus, tabs and in-page switches that Asuswrt-Merlin 3006.102.5 shows on an RT-BE88U, with the native content
/// written for each page; it was captured from that router's `require/modules/menuTree.js` evaluated with its
/// `ui_support` (see audit/web-menu/), names as its Simplified Chinese interface shows them. For the connected
/// router, WebMenuSet builds the same structure from the router's own menu.
public enum WebMenuGroup: String, CaseIterable, Sendable {
    case general = "一般设置"
    case advanced = "高级设置"
}

public struct WebMenu: Identifiable, Hashable, Sendable {
    /// menuTree.js `index`, e.g. "menu_Wireless".
    public let id: String
    public let title: String
    /// nil for the setup wizard, which the web lists above the 一般设置 heading.
    public let group: WebMenuGroup?
    public let symbol: String
    /// In web order.
    public let pages: [WebPage]
    /// The page the web opens when the menu is clicked: the first one it does not hide. nil means the first page.
    public let entry: String?
    init(id: String, title: String, group: WebMenuGroup?, symbol: String, pages: [WebPage], entry: String? = nil) {
        self.id = id; self.title = title; self.group = group; self.symbol = symbol; self.pages = pages; self.entry = entry
    }
    public var tabs: [WebPage] { pages.filter { $0.kind == .tab } }
    public var home: WebPage { entry.flatMap(page) ?? pages[0] }
    public func page(_ id: String) -> WebPage? { pages.first { $0.id == id } }
}

public struct WebPage: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Opens when the menu is clicked and shows no tab bar (`__HIDE__`).
        case landing
        /// A named tab of the menu.
        case tab
        /// Reached from a link on the landing page (`__INHERIT__`).
        case subpage
    }
    /// The web page's file name, e.g. "Advanced_Wireless_Content.asp".
    public let id: String
    public let kind: Kind
    public let title: String
    /// The page's own switch (band, WAN, protocol, view…) in web order; a page without one has a single part.
    public let parts: [WebPart]
    /// Shown only while this holds; nil means always.
    public let condition: WebCondition?
    init(_ id: String, _ kind: Kind, _ title: String, condition: WebCondition? = nil, parts: [WebPart]) {
        self.id = id; self.kind = kind; self.title = title; self.condition = condition; self.parts = parts
    }
    init(_ id: String, _ kind: Kind, _ title: String, condition: WebCondition? = nil, _ content: WebContent) {
        self.init(id, kind, title, condition: condition, parts: [WebPart("main", title, content)])
    }
}

public struct WebPart: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    /// The separate web page this switch choice opens, when it is not the tab's own page.
    public let url: String?
    public let content: WebContent
    public let condition: WebCondition?
    init(_ id: String, _ title: String, url: String? = nil, condition: WebCondition? = nil, _ content: WebContent) {
        self.id = id; self.title = title; self.url = url; self.condition = condition; self.content = content
    }
}

public enum WebContent: Hashable, Sendable {
    /// Catalog sections in page order, with an optional native control shown after them.
    case settings([String], accessory: NativeFeature? = nil)
    case native(NativeFeature)
    /// Not native yet: what the web page is for, and native pages that hold related settings.
    case pending(String, related: [WebLink] = [])

    public var sectionIDs: [String] {
        switch self {
        case .settings(let ids, _): ids
        case .native(let feature): feature.sectionIDs
        case .pending: []
        }
    }
}

/// Runtime facts the web itself uses to show or hide a page, part or section.
public enum WebCondition: Hashable, Sendable {
    /// The main Wi-Fi is configured per band, not as an SDN network: the web shows SSID and security on
    /// 一般设置 and the MAC filter and RADIUS tabs only then (menuTree.js and the page check `sdn_mainfh`).
    case perBandWireless
    /// Dual WAN is switched on, so the WAN and IPv6 pages offer the second WAN.
    case dualWAN
}

public enum WebLink: Hashable, Sendable {
    case section(String)
    case feature(NativeFeature)
}

/// Native views that stand for a web page or part.
public enum NativeFeature: Hashable, Sendable {
    case overview, clients, mesh, networks, usbApplications
    case radioChannels(Int)
    case vpnStatus
    case vpn(VPNScope)
    case administrator, firmware, settingBackup
    case systemLog, wirelessClients, routeTable, connections
    case networkAnalysis, netstat
    case systemInfo
    case trafficMonitor(TrafficMonitorMode)
    case dhcpLeases, ipv6Status, portForwards
    case aiProtection(AiProtectionKind)
    case bandwidthMonitor, webHistory, trafficStatistics, trafficMonitorSettings, aiCloudLog
    case wps, wds, roamingBlock, mlo, smartConnectRules
    case vlanPorts, vlanProfiles, tor, qosUserPriority
    case internetSpeed, uuAccelerator, printerServer, privacy, alexa, wakeOnLAN, siteSurvey
    case aiCloud, aiCloudSettings, operationMode, openNAT, gameBoost, dualWAN
    /// 外部网络 › IPv6 › 第二 WAN (Advanced_IPv61_Content.asp).
    case ipv6SecondWAN
    /// VPN › VPN 客户端 › PPTP/L2TP (Advanced_VPNClient_Content.asp, which loads VPN/vpnc.html).
    case pptpClient
    /// 家长管理 › 网页与 Apps 过滤 (AiProtection_WebProtector.asp) and 时间安排 (ParentalControl.asp).
    case webProtector, parentalControl
    /// USB 相关应用 › AiDisk (aidisk.asp with its wizard aidisk/Aidisk-1–4.asp).
    case aiDisk
    /// 网络设置向导 (QIS_wizard.htm, QIS_V3).
    case setupWizard

    public var sectionIDs: [String] {
        if case .vpn(let scope) = self { return scope.sectionIDs }
        return []
    }
}

/// The views of Traffic Analyzer › 流量监控, one per switch choice of the web page.
public enum TrafficMonitorMode: Hashable, Sendable {
    case realtime, last24, daily, monthly
}

/// The VPN slots one VPN tab or switch choice shows, split the way the web splits them.
public enum VPNScope: Hashable, Sendable {
    /// VPN Director.
    case routing
    /// 虚拟专用网 (VPN) 服务器 › OpenVPN: server instances 1 and 2.
    case openVPNServers
    /// 虚拟专用网 (VPN) 服务器 › Others: PPTP and IPSec VPN (not native) and WireGuard VPN.
    case otherServers
    /// VPN 客户端 › OpenVPN or Wireguard: client instances 1–5.
    case clients(VPNProtocolFamily)

    public var destinations: [VPNCenterDestination] {
        switch self {
        case .routing: [.routing]
        case .openVPNServers: [.instance(.openVPNServer(1)), .instance(.openVPNServer(2))]
        case .otherServers: [.instance(.wireGuardServer)]
        case .clients(let family): VPNInstance.outboundSlots.filter { $0.family == family }.map { .instance($0) }
        }
    }
    public var sectionIDs: [String] { destinations.map(\.sectionID) }
    public static func containing(_ destination: VPNCenterDestination) -> VPNScope {
        switch destination {
        case .routing: .routing
        case .instance(.wireGuardServer): .otherServers
        case .instance(.openVPNServer): .openVPNServers
        case .instance(let client): .clients(client.family)
        }
    }
}

/// A place in the mirrored web interface: menu, page and switch choice.
public struct WebLocation: Hashable, Sendable {
    public let menu: String
    public let page: String
    public let part: String
    public init(menu: String, page: String, part: String) { self.menu = menu; self.page = page; self.part = part }
}

public enum WebMenuCatalog {
    public static let model = "RT-BE88U"
    public static let firmware = "Asuswrt-Merlin 3006.102.5"

    /// Catalog sections the web does not show on this router, with the reason.
    public static let hiddenSections: [String: String] = [
        "nfs": "这台路由器的固件不支持 NFS（ui_support 没有 nfsd），网页不显示 NFS Exports 分页。"
    ]
    /// Pages the menu lists that the web never links on this router, with the reason.
    public static let unlinkedPages: [String: String] = [
        "Advanced_TencentDownloadAcceleration.asp": "USB 相关应用页面在这台路由器上不显示腾讯下载加速入口（不支持）。"
    ]
    /// Sections the web shows only under a runtime condition.
    public static let sectionConditions: [String: WebCondition] = ["wifi0": .perBandWireless, "wifi1": .perBandWireless, "wan1": .dualWAN]
    /// Rows the web shows only under a runtime condition, by catalog key without the unit number. The professional page
    /// hides its `.mainBH` rows AP 隔离 and WiFi7 模式 when the main Wi-Fi is an SDN network (sysdep/GT-AXE11000
    /// Advanced_WAdvanced_Content.asp:808–810, rows 1720 and 1793); the 网络 page sets both per network instead.
    public static let fieldConditions: [String: WebCondition] = ["wl_ap_isolate": .perBandWireless, "wl_11be": .perBandWireless]
    /// A section's condition, including the per-radio sections of other radios ("wifi2@6 GHz").
    public static func condition(ofSection id: String) -> WebCondition? {
        if let condition = sectionConditions[id] { return condition }
        return id.hasPrefix("wifi") && id.contains("@") ? .perBandWireless : nil
    }
    public static func condition(ofField key: String) -> WebCondition? {
        fieldConditions[key.replacingOccurrences(of: #"^wl\d+_"#, with: "wl_", options: .regularExpression)]
    }

    // The reference catalog answers like any menu set (WebMenuSet.reference).
    public static func menu(_ id: String) -> WebMenu? { menus.first { $0.id == id } }
    public static func location(ofSection id: String) -> WebLocation? { WebMenuSet.reference.location(ofSection: id) }
    public static func location(of feature: NativeFeature) -> WebLocation? { WebMenuSet.reference.location(of: feature) }
    public static func locations(where matches: (WebPart) -> Bool) -> [WebLocation] { WebMenuSet.reference.locations(where: matches) }
    public static func names(of location: WebLocation) -> [String] { WebMenuSet.reference.names(of: location) }

    // MARK: Menu

    public static let menus: [WebMenu] = general + advanced

    static let general: [WebMenu] = [
        WebMenu(id: "menu_QIS", title: "网络设置向导", group: nil, symbol: "wand.and.stars", pages: [
            WebPage("QIS_wizard.htm", .landing, "网络设置向导", .native(.setupWizard))
        ]),
        WebMenu(id: "menu_Index", title: "网络地图", group: .general, symbol: "map", pages: [
            WebPage("index.asp", .landing, "网络地图", parts: [WebPart("overview", "概览", .native(.overview)), WebPart("clients", "客户端", .native(.clients))])
        ]),
        WebMenu(id: "menu_AiMesh", title: "AiMesh", group: .general, symbol: "point.3.connected.trianglepath.dotted", pages: [
            WebPage("AiMesh.asp", .tab, "AiMesh", .native(.mesh))
        ]),
        WebMenu(id: "menu_GuestNetwork", title: "网络", group: .general, symbol: "network", pages: [
            WebPage("SDN.asp", .tab, "网络", .native(.networks))
        ]),
        WebMenu(id: "menu_AiProtection", title: "AiProtection 网络神盾", group: .general, symbol: "shield.lefthalf.filled", pages: [
            WebPage("AiProtection_HomeProtection.asp", .tab, "网络保护", .settings(["aiprotection"])),
            WebPage("AiProtection_MaliciousSitesBlocking.asp", .tab, "恶意网站拦截", .native(.aiProtection(.maliciousSites))),
            WebPage("AiProtection_IntrusionPreventionSystem.asp", .tab, "双向 IPS", .native(.aiProtection(.intrusionPrevention))),
            WebPage("AiProtection_InfectedDevicePreventBlock.asp", .tab, "受感染设备防止及拦截", .native(.aiProtection(.infectedDevices)))
        ]),
        WebMenu(id: "menu_ParentalControl", title: "家长管理", group: .general, symbol: "figure.and.child.holdinghands", pages: [
            WebPage("AiProtection_WebProtector.asp", .tab, "网页与 Apps 过滤", .native(.webProtector)),
            WebPage("ParentalControl.asp", .tab, "时间安排", .native(.parentalControl))
        ]),
        WebMenu(id: "menu_BandwidthMonitor", title: "Adaptive QoS 智能场景加速", group: .general, symbol: "speedometer", pages: [
            WebPage("AdaptiveQoS_Bandwidth_Monitor.asp", .tab, "带宽监控", .native(.bandwidthMonitor)),
            WebPage("QoS_EZQoS.asp", .tab, "带宽管理 QoS", parts: [
                WebPart("qos", "带宽管理 QoS", .settings(["qos"])),
                WebPart("rules", "用户自定义带宽管理规则", url: "Advanced_QOSUserRules_Content.asp", .settings(["qosrules"])),
                WebPart("priority", "用户自定义优先级", url: "Advanced_QOSUserPrio_Content.asp", .native(.qosUserPriority))
            ]),
            WebPage("AdaptiveQoS_WebHistory.asp", .tab, "网页浏览历史", .native(.webHistory)),
            WebPage("AdaptiveQoS_InternetSpeed.asp", .tab, "网络速度", .native(.internetSpeed))
        ]),
        WebMenu(id: "menu_UU", title: "网易UU加速器", group: .general, symbol: "bolt.horizontal", pages: [
            WebPage("UUAccelerator.asp", .tab, "网易UU加速器", .native(.uuAccelerator))
        ]),
        WebMenu(id: "menu_TrafficAnalyzer", title: "Traffic Analyzer 流量分析", group: .general, symbol: "chart.bar.xaxis", pages: [
            WebPage("Main_TrafficMonitor_realtime.asp", .tab, "流量监控", parts: [
                WebPart("realtime", "即时流量图", .native(.trafficMonitor(.realtime))),
                WebPart("last24", "过去24小时流量图", url: "Main_TrafficMonitor_last24.asp", .native(.trafficMonitor(.last24))),
                WebPart("daily", "单日流量表", url: "Main_TrafficMonitor_daily.asp", .native(.trafficMonitor(.daily))),
                WebPart("monthly", "Monthly", url: "Main_TrafficMonitor_monthly.asp", .native(.trafficMonitor(.monthly)))
            ]),
            WebPage("Main_TrafficMonitor_settings.asp", .tab, "Monitoring Settings", .native(.trafficMonitorSettings)),
            WebPage("TrafficAnalyzer_Statistic.asp", .tab, "统计数值", .native(.trafficStatistics))
        ]),
        WebMenu(id: "menu_GameBoost", title: "Game", group: .general, symbol: "gamecontroller", pages: [
            WebPage("GameBoost.asp", .tab, "游戏加速", .native(.gameBoost))
        ]),
        WebMenu(id: "menu_OpenNAT", title: "Open NAT", group: .general, symbol: "arrow.left.arrow.right.circle", pages: [
            WebPage("GameProfile.asp", .tab, "Open NAT", .native(.openNAT))
        ]),
        WebMenu(id: "menu_APP", title: "USB 相关应用", group: .general, symbol: "externaldrive.connected.to.line.below", pages: [
            WebPage("APP_Installation.asp", .landing, "USB 相关应用", .native(.usbApplications)),
            WebPage("aidisk.asp", .subpage, "AiDisk", .native(.aiDisk)),
            WebPage("mediaserver.asp", .tab, "媒体服务器", .settings(["media"])),
            WebPage("Advanced_AiDisk_samba.asp", .tab, "网络共享（Samba） / 云端硬盘", .settings(["samba"])),
            WebPage("Advanced_AiDisk_ftp.asp", .tab, "以 FTP 共享硬盘", .settings(["ftp"])),
            WebPage("PrinterServer.asp", .subpage, "网络打印机服务器", .settings(["printer"], accessory: .printerServer)),
            WebPage("Advanced_TimeMachine.asp", .subpage, "Time Machine", .settings(["timemachine"]))
        ]),
        WebMenu(id: "menu_AiCloud", title: "AiCloud 2.0 个人云 2.0 应用", group: .general, symbol: "icloud", pages: [
            WebPage("cloud_main.asp", .tab, "AiCloud 2.0", .native(.aiCloud)),
            WebPage("cloud_settings.asp", .tab, "设置", .native(.aiCloudSettings)),
            WebPage("cloud_syslog.asp", .tab, "日志", .native(.aiCloudLog))
        ]),
        WebMenu(id: "menu_Sysinfo", title: "System Info", group: .general, symbol: "info.circle", pages: [
            WebPage("Tools_Sysinfo.asp", .tab, "Sysinfo", .native(.systemInfo))
        ])
    ]

    static let advanced: [WebMenu] = [
        WebMenu(id: "menu_Wireless", title: "无线网络", group: .advanced, symbol: "wifi", pages: [
            WebPage("Advanced_Wireless_Content.asp", .tab, "一般设置", parts: [
                WebPart("2g", "2.4 GHz", .settings(["wifi0"], accessory: .radioChannels(0))),
                WebPart("5g", "5 GHz", .settings(["wifi1", "band1"], accessory: .radioChannels(1)))
            ]),
            WebPage("Advanced_WWPS_Content.asp", .tab, "WPS", .native(.wps)),
            WebPage("Advanced_WMode_Content.asp", .tab, "WDS", .native(.wds)),
            WebPage("Advanced_ACL_Content.asp", .tab, "无线 MAC 地址过滤器", condition: .perBandWireless, parts: [
                WebPart("2g", "2.4 GHz", .settings(["acl0"])), WebPart("5g", "5 GHz", .settings(["acl1"]))
            ]),
            WebPage("Advanced_WSecurity_Content.asp", .tab, "RADIUS 设置", condition: .perBandWireless, parts: [
                WebPart("2g", "2.4 GHz", .settings(["radius0"])), WebPart("5g", "5 GHz", .settings(["radius1"]))
            ]),
            WebPage("Advanced_WAdvanced_Content.asp", .tab, "专业设置", parts: [
                WebPart("2g", "2.4 GHz", .settings(["radio0"])), WebPart("5g", "5 GHz", .settings(["radio1"]))
            ]),
            WebPage("Advanced_Roaming_Block_Content.asp", .tab, "漫游阻止列表", .native(.roamingBlock)),
            WebPage("MLO.asp", .tab, "MLO", .native(.mlo))
        ]),
        WebMenu(id: "menu_LAN", title: "内部网络(LAN)", group: .advanced, symbol: "cable.connector.horizontal", pages: [
            WebPage("Advanced_LAN_Content.asp", .tab, "内网地址设置", .settings(["lan"])),
            WebPage("Advanced_DHCP_Content.asp", .tab, "DHCP 服务器", .settings(["dhcp"])),
            WebPage("DNSDirector.asp", .tab, "DNS Director", .settings(["dnsdirector"])),
            WebPage("Advanced_GWStaticRoute_Content.asp", .tab, "路由设置", .settings(["routes"])),
            WebPage("Advanced_IPTV_Content.asp", .tab, "IPTV", .settings(["iptv"])),
            WebPage("Advanced_SwitchCtrl_Content.asp", .tab, "交换机控制", .settings(["switch"])),
            WebPage("Advanced_VLAN_Switch_Content.asp", .tab, "VLAN", parts: [
                WebPart("ports", "VLAN", .native(.vlanPorts)),
                WebPart("profiles", "VLAN 配置文件", url: "Advanced_VLAN_Profile_Content.asp", .native(.vlanProfiles))
            ])
        ]),
        WebMenu(id: "menu_WAN", title: "外部网络(WAN)", group: .advanced, symbol: "globe", pages: [
            WebPage("Advanced_WAN_Content.asp", .tab, "互联网连接", parts: [
                WebPart("wan0", "首选 WAN", .settings(["wan0"])),
                WebPart("wan1", "第二 WAN", condition: .dualWAN, .settings(["wan1"])),
                WebPart("dns", "DNS 安全与加密", .settings(["dns"]))
            ]),
            WebPage("Advanced_WANPort_Content.asp", .tab, "双线路", .native(.dualWAN)),
            WebPage("Advanced_PortTrigger_Content.asp", .tab, "通信端口触发程序", .settings(["trigger"])),
            WebPage("Advanced_VirtualServer_Content.asp", .tab, "端口转发", .settings(["portforward"])),
            WebPage("Advanced_Exposed_Content.asp", .tab, "DMZ", .settings(["dmz"])),
            WebPage("Advanced_ASUSDDNS_Content.asp", .tab, "DDNS", .settings(["ddns"])),
            WebPage("Advanced_NATPassThrough_Content.asp", .tab, "NAT Passthrough", .settings(["nat"]))
        ]),
        WebMenu(id: "menu_Alexa_IFTTT", title: "Amazon Alexa", group: .advanced, symbol: "homepod", pages: [
            WebPage("Advanced_Smart_Home_Alexa.asp", .landing, "Amazon Alexa", .native(.alexa))
        ]),
        WebMenu(id: "menu_IPv6", title: "IPv6", group: .advanced, symbol: "6.circle", pages: [
            WebPage("Advanced_IPv6_Content.asp", .tab, "IPv6", parts: [
                WebPart("ipv6", "首选 WAN", .settings(["ipv6"])),
                WebPart("ipv6-2", "第二 WAN", url: "Advanced_IPv61_Content.asp", condition: .dualWAN, .native(.ipv6SecondWAN))
            ])
        ]),
        WebMenu(id: "menu_VPN", title: "VPN", group: .advanced, symbol: "lock.shield", pages: [
            WebPage("Advanced_VPNStatus.asp", .tab, "VPN Status", .native(.vpnStatus)),
            WebPage("Advanced_VPNDirector.asp", .tab, "VPN Director", .native(.vpn(.routing))),
            WebPage("Advanced_VPN_OpenVPN.asp", .tab, "虚拟专用网 (VPN) 服务器", parts: [
                WebPart("openvpn", "OpenVPN", .native(.vpn(.openVPNServers))),
                WebPart("others", "Others", url: "Advanced_VPNServer_Content.asp", .native(.vpn(.otherServers)))
            ]),
            WebPage("Advanced_OpenVPNClient_Content.asp", .tab, "VPN 客户端", parts: [
                WebPart("openvpn", "OpenVPN", .native(.vpn(.clients(.openVPN)))),
                WebPart("pptp", "PPTP/L2TP", url: "Advanced_VPNClient_Content.asp", .native(.pptpClient)),
                WebPart("wireguard", "Wireguard", url: "Advanced_WireguardClient_Content.asp", .native(.vpn(.clients(.wireGuard))))
            ]),
            WebPage("Advanced_TOR_Content.asp", .tab, "TOR", .native(.tor))
        ]),
        WebMenu(id: "menu_Firewall", title: "防火墙", group: .advanced, symbol: "flame", pages: [
            WebPage("Advanced_BasicFirewall_Content.asp", .tab, "一般设置", .settings(["firewall"])),
            WebPage("Advanced_URLFilter_Content.asp", .tab, "网址过滤", .settings(["urlfilter"])),
            WebPage("Advanced_KeywordFilter_Content.asp", .tab, "关键词过滤器", .settings(["keywords"])),
            WebPage("Advanced_Firewall_Content.asp", .tab, "网络服务过滤", .settings(["networkfilter"]))
        ]),
        WebMenu(id: "menu_Setting", title: "系统管理", group: .advanced, symbol: "gearshape.2", pages: [
            WebPage("Advanced_OperationMode_Content.asp", .tab, "操作模式", .native(.operationMode)),
            WebPage("Advanced_System_Content.asp", .tab, "系统设置", parts: [
                WebPart("account", "管理员账号", .native(.administrator)),
                WebPart("ntp", "时间与自动重启", .settings(["ntp"])),
                WebPart("admin", "管理访问", .settings(["admin"])),
                WebPart("ssh", "SSH 与系统服务", .settings(["ssh"])),
                WebPart("led", "指示灯与电源", .settings(["led"]))
            ]),
            WebPage("Advanced_FirmwareUpgrade_Content.asp", .tab, "固件升级", parts: [
                WebPart("firmware", "固件版本", .native(.firmware)),
                WebPart("updates", "更新检查偏好", .settings(["updates"]))
            ]),
            WebPage("Advanced_SettingBackup_Content.asp", .tab, "恢复/导出/上传设置", .native(.settingBackup)),
            WebPage("Advanced_SNMP_Content.asp", .tab, "SNMP", .settings(["snmp"])),
            WebPage("Advanced_Privacy.asp", .tab, "政策", .native(.privacy)),
            WebPage("Tools_OtherSettings.asp", .tab, "Tweaks", .settings(["conntrack"]))
        ]),
        WebMenu(id: "menu_Log", title: "系统记录", group: .advanced, symbol: "doc.text.magnifyingglass", pages: [
            WebPage("Main_LogStatus_Content.asp", .tab, "一般记录文件", parts: [
                WebPart("log", "系统记录", .native(.systemLog)),
                WebPart("settings", "记录设置", .settings(["logs"]))
            ]),
            WebPage("Main_WStatus_Content.asp", .tab, "无线用户", .native(.wirelessClients)),
            WebPage("Main_DHCPStatus_Content.asp", .tab, "DHCP 租约", .native(.dhcpLeases)),
            WebPage("Main_IPV6Status_Content.asp", .tab, "IPv6", .native(.ipv6Status)),
            WebPage("Main_RouteStatus_Content.asp", .tab, "路由表", .native(.routeTable)),
            WebPage("Main_IPTStatus_Content.asp", .tab, "通信端口转发", .native(.portForwards)),
            WebPage("Main_ConnStatus_Content.asp", .tab, "连接", .native(.connections))
        ]),
        WebMenu(id: "menu_NekworkTool", title: "网络工具", group: .advanced, symbol: "wrench.and.screwdriver", pages: [
            WebPage("Main_Analysis_Content.asp", .tab, "网络诊断", .native(.networkAnalysis)),
            WebPage("Main_Netstat_Content.asp", .tab, "Netstat", .native(.netstat)),
            WebPage("Main_WOL_Content.asp", .tab, "通过网络（LAN）唤醒", .native(.wakeOnLAN)),
            WebPage("Advanced_Smart_Connect.asp", .tab, "Smart Connect 规则", .native(.smartConnectRules)),
            WebPage("Advanced_Wireless_Survey.asp", .tab, "Site Survey", .native(.siteSurvey))
        ])
    ]
}
