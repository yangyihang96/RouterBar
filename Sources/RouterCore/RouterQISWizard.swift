import Foundation

// 网络设置向导（QIS_wizard.htm，QIS_V3，Asuswrt-Merlin 3006.102.5）：入口的读取与分流、协议页、欢迎页、本地登录、操作模式
// （无线路由器与无线访问点）、以太网 WAN 的自动侦测与手动设置（DHCP、PPPoE、静态 IP、PPTP/L2TP、DHCP 选项、WAN 端口）、LAN IP、
// 无线（Smart Connect、分频、MLO、SDN 主网络）、最终提交与完成页。照网页做成条件状态机：qisPostData 按网页的时点插入与移除，
// 中途的 WAN 提交、协议同意、自动侦测和改管理员密码都在网页同样的时点产生，由 App 先确认再发送。
// 行号：QIS_wizard.htm 与 mobile/js/handler.js、mobile/js/qisData.js 指 spec-batch3/fw/www；mobile/js/plugins.js 指补取的
// QIS_V3 plugins.js；js/httpApi.js、js/asus_policy.js 指 fw/www/js；validator.js 指 fw-3006.102.5/www；CN.dict 行号为字典。
// 其他分支（DSL、4G/5G 与 SIM、USB Modem、AiMesh、中继／媒体桥接／WISP 的无线扫描、Instant Guard、恢复配置文件、IPTV、
// 日本 IPv6、出厂状态）只给说明和在浏览器打开同一向导的入口。

// MARK: - qisPostData

/// qisPostData (qisData.js 1): a JavaScript object. A member set again keeps its place, a deleted one goes, and a member set to
/// undefined (nil) exists for hasOwnProperty while JSON.stringify leaves it out.
public struct QISPostData: Sendable, Equatable {
    public private(set) var members: [(name: String, value: OrderedJSON?)] = []

    public static func == (a: QISPostData, b: QISPostData) -> Bool {
        a.members.count == b.members.count && zip(a.members, b.members).allSatisfy { $0.name == $1.name && $0.value == $1.value }
    }
    public init() {}
    /// `qisPostData.hasOwnProperty(name)`.
    public func has(_ name: String) -> Bool { members.contains { $0.name == name } }
    /// The member's value; nil both for undefined and for a missing member.
    public subscript(_ name: String) -> OrderedJSON? { members.first { $0.name == name }?.value }
    /// String(value), "undefined" for a missing or undefined member.
    func text(_ name: String) -> String { self[name].map(TORSettings.javaScriptString) ?? "undefined" }
    mutating func set(_ name: String, _ value: OrderedJSON?) {
        if let at = members.firstIndex(where: { $0.name == name }) { members[at].value = value } else { members.append((name, value)) }
    }
    mutating func set(_ name: String, _ text: String) { set(name, .string(text)) }
    mutating func remove(_ name: String) { members.removeAll { $0.name == name } }
    /// postDataModel.remove (plugins.js 1934–1936).
    mutating func remove(_ object: [(String, OrderedJSON)]) { for (name, _) in object { remove(name) } }
    /// The members JSON.stringify writes.
    public var sent: [(String, OrderedJSON)] { members.compactMap { member in member.value.map { (member.name, $0) } } }
    /// JSON.stringify(qisPostData).
    public var json: String { OrderedJSON.object(sent).javaScriptJSON }
}

/// The objects of qisData.js that postDataModel inserts and removes, in their declared order.
enum QISObject {
    static func text(_ pairs: [(String, String)]) -> [(String, OrderedJSON)] { pairs.map { ($0.0, .string($0.1)) } }
    /// opModeObj (qisData.js 3–8).
    static let opMode = text([("sw_mode", ""), ("wlc_psta", ""), ("wlc_dpsta", ""), ("wlc_band", "")])
    /// generalObj (10–14).
    static let general = text([("x_Setting", "1"), ("w_Setting", "1"), ("qis_Setting", "1")])
    /// wanObj.general (17–20); wan_unit becomes the Ethernet WAN unit, a number, at start (QIS_wizard.htm 119–121).
    static func wanGeneral(_ unit: Int) -> [(String, OrderedJSON)] { [("wan_unit", .number(String(unit))), ("wan_proto", .string(""))] }
    static let wanDHCP = text([("wan_dhcpenable_x", "1"), ("wan_dnsenable_x", "1")])
    static let wanPPPoE = text([("wan_dhcpenable_x", "1"), ("wan_dnsenable_x", "1"), ("wan_pppoe_username", ""), ("wan_pppoe_passwd", "")])
    static let wanStatic = text([("wan_dhcpenable_x", "0"), ("wan_dnsenable_x", "0"), ("wan_ipaddr_x", ""), ("wan_netmask_x", ""),
                                 ("wan_gateway_x", ""), ("wan_dns1_x", ""), ("wan_dns2_x", "")])
    static let wanVPN = text([("wan_heartbeat_x", "")])
    /// wanObj.all (74–88); only removed, so its values do not matter.
    static let wanAll = text(["wan_unit", "wan_proto", "wan_dhcpenable_x", "wan_dnsenable_x", "wan_pppoe_username", "wan_pppoe_passwd",
                              "wan_ipaddr_x", "wan_netmask_x", "wan_gateway_x", "wan_dns1_x", "wan_dns2_x", "wan_heartbeat_x", "ipv6_service"].map { ($0, "") })
    static let lwan2p5G = text([("wans_extwan", "0")])
    static let dualWan = text([("wans_dualwan", "")])
    /// lanObj (99–116).
    static let lanGeneral = text([("lan_proto", ""), ("lan_dnsenable_x", "")])
    static let lanStatic = text([("lan_ipaddr", ""), ("lan_gateway", ""), ("lan_netmask", ""), ("lan_dns2_x", ""), ("lan_dns1_x", "")])
    /// wirelessObj.wlN (118–147).
    static func wireless(_ unit: String) -> [(String, OrderedJSON)] {
        text(["ssid", "wpa_psk", "auth_mode_x", "crypto", "mfp"].map { ("wl\(unit)_\($0)", "") })
    }
    static let fronthaul = text([("fh_ap_enabled", "2"), ("acs_unii4", "0")])
    static let user = text([("http_username", ""), ("http_passwd", "")])
    static let aimesh = text([("cfg_master", "1")])
    static let wanDHCPOption = text([("wan_vendorid", ""), ("wan_clientid_type", ""), ("wan_clientid", "")])
    /// sdnObj (548–564).
    static let sdn = text([("sdn_rl", ""), ("apg_enable", "1"), ("apg_ssid", ""), ("apg_hide_ssid", ""), ("apg_security", ""), ("apg_bw_limit", "<0>>"),
                           ("apg_timesched", "0"), ("apg_sched", "0"), ("apg_expiretime", "0"), ("apg_ap_isolate", "0"), ("apg_macmode", ""),
                           ("apg_mlo", "0"), ("apg_maclist", ""), ("apg_iot_max_cmpt", ""), ("apg_dut_list", "")])
}

// MARK: - Pages

/// The page the wizard shows (the `data-role="page"` divs of QIS_wizard.htm, by their id in `history`).
public enum QISPage: Sendable, Equatable {
    /// QisPolicyPageComponent (asus_policy.js 1645–2592) for the EULA and the privacy statement, in #policy_page.
    case eula(PrivacyPolicyStatus)
    case privacy(PrivacyPolicyStatus)
    case welcome, advancedSetting, login, opMode
    /// waiting_page (QIS_wizard.htm 788–838), resetModem_page (748–787), noWan_page (985–1025).
    case waiting, resetModem, noWan
    case specialISP, wanSetting, wanOption
    /// pppoe_setting (1431–1490): PPPoE, or PPTP/L2TP with the VPN server row.
    case account
    case getIP, staticIP, dhcpOption, getLanIP, lanStatic
    case wireless
    /// SDN_IoT_setting (3238–3302).
    case iot
    case update, summary
    /// A branch the app does not do natively: what it is and the wizard to open in the browser.
    case browser(QISBranch)

    /// The page's id as goTo.loadPage pushes it onto historyPage.
    public var id: String {
        switch self {
        case .eula, .privacy: "policy_page"
        case .welcome: "welcome"
        case .advancedSetting: "advanced_setting"
        case .login: "login_name"
        case .opMode: "opMode_page"
        case .waiting: "waiting_page"
        case .resetModem: "resetModem_page"
        case .noWan: "noWan_page"
        case .specialISP: "special_isp_requirement"
        case .wanSetting: "wan_setting"
        case .wanOption: "wanOption_setting"
        case .account: "pppoe_setting"
        case .getIP: "getIp_setting"
        case .staticIP: "static_setting"
        case .dhcpOption: "wan_dhcp_option_setting"
        case .getLanIP: "getLanIp_setting"
        case .lanStatic: "lanStatic_setting"
        case .wireless: "wireless_setting"
        case .iot: "SDN_IoT_setting"
        case .update: "update_page"
        case .summary: "summary_page"
        case .browser(let branch): "browser:" + branch.page
        }
    }
    static func named(_ id: String) -> QISPage? {
        let pages: [QISPage] = [.welcome, .advancedSetting, .login, .opMode, .waiting, .resetModem, .noWan, .specialISP, .wanSetting, .wanOption,
                                .account, .getIP, .staticIP, .dhcpOption, .getLanIP, .lanStatic, .wireless, .iot, .update, .summary]
        return pages.first { $0.id == id }
    }
}

/// The branches the app leaves to the router's own wizard, with the page the web would show and why.
public enum QISBranch: Sendable, Equatable {
    case factoryDefault, dsl, mobileBroadband, usbModem, phoneAsWAN, aimesh(String), repeater, mediaBridge, wisp, apDetectWAN
    case siteToSite, upload, iptv, japanIPv6, sdnScenario, upgrade, axMode
    /// The page id the web opens for it.
    var page: String {
        switch self {
        case .factoryDefault: "welcome"
        case .dsl: "dsl"
        case .mobileBroadband: "simpin_setting"
        case .usbModem: "modem_setting"
        case .phoneAsWAN: "phone_as_modem"
        case .aimesh(let page): page
        case .repeater, .mediaBridge, .wisp: "siteSurvey_page"
        case .apDetectWAN: "waiting_page"
        case .siteToSite: "site2site_wlSet"
        case .upload: "uploading_page"
        case .iptv: "iptv_setting"
        case .japanIPv6: "wan46_page"
        case .sdnScenario: "SDN_Scenarios_page"
        case .upgrade: "upgrading_page"
        case .axMode: "axMode_page"
        }
    }
    /// The URL flag that leads the web wizard straight to this branch (QIS_wizard.htm 254–308); nil when none does, and the
    /// wizard is opened with the flag the app was given.
    public var flag: String? {
        switch self {
        case .repeater: "sitesurvey_rep"
        case .mediaBridge: "sitesurvey_mb"
        case .wisp: "wispMode"
        case .siteToSite: "site2site"
        case .aimesh(let page):
            switch page {
            case "amasrole_page": "amasrole_page"
            case "amasnode_page": "amasnode_page"
            case "amassearch_page": "amas_addNode"
            default: nil
            }
        default: nil
        }
    }
    public var title: String {
        switch self {
        case .factoryDefault: "出厂状态的首次设置"
        case .dsl: "DSL 上网设置"
        case .mobileBroadband: "移动宽带（4G / 5G、SIM PIN / PUK）"
        case .usbModem: "USB Modem"
        case .phoneAsWAN: "4G / 5G 自动移动网络共享"
        case .aimesh: "AiMesh"
        case .repeater: "中继模式"
        case .mediaBridge: "无线桥接 (Media Bridge)"
        case .wisp: "公共 WiFi 模式 (WISP)"
        case .apDetectWAN: "无线访问点的 WAN 侦测"
        case .siteToSite: "Instant Guard site-to-site"
        case .upload: "恢复设置文件"
        case .iptv: "网络服务运营商 (ISP) 特殊需求（IPTV）"
        case .japanIPv6: "日本 IPv6（v6plus / OCN / DS-Lite / IPv6 Option）"
        case .sdnScenario: "专业访客网络场景"
        case .upgrade: "固件升级"
        case .axMode: "802.11ax"
        }
    }
    /// Why the app does not do it here.
    public var reason: String {
        switch self {
        case .factoryDefault: "这台路由器尚未完成初始设置（x_Setting 为 0 或空）。出厂状态的向导会设置时区（require/modules/timeZone.js，资料中没有）、每 10 分钟写入 cfg_pause 并走另一套无线默认值，App 只做已完成初始设置的路由器。"
        case .dsl: "这台路由器是以太网 WAN，没有 DSL；DSL 的侦测与 PVC/PTM 设置不适用。"
        case .mobileBroadband: "这台路由器没有内置 4G / 5G 模块（gobi）；SIM PIN / PUK 不适用。"
        case .usbModem: "USB Modem 需要插入的 USB 网卡及国家／ISP／APN 资料列表，App 不提供。"
        case .phoneAsWAN: "以手机或 USB 设备做备援 WAN 的设置未做成原生页面。"
        case .aimesh: "AiMesh 节点搜索、入网与恢复为节点需要无线扫描和逐台入网流程，App 不提供。"
        case .repeater, .mediaBridge, .wisp: "这一模式要先扫描附近的无线网络并对上游 AP 预认证（restart_wlcscan、start_wpasupp_qis），App 不提供无线扫描。"
        case .apDetectWAN: "这类机型（apMode_detwan）的 AP 模式先侦测 WAN，网页另有一套流程，App 不提供。"
        case .siteToSite: "Instant Guard 邀请需要邀请链接里的参数和 enable_ig_s2s_client.cgi，App 不提供。"
        case .upload: "恢复设置文件需要选择并上传 .CFG 文件（upload.cgi），之后路由器重新启动，App 不在向导里上传文件。"
        case .iptv: "IPTV 需要 ISP 设置档列表与 VLAN／端口设置，且可能改动 WAN 端口，未做成原生页面。"
        case .japanIPv6: "日本 IPv6 的侦测（restart_auto46det）与 v6plus、OCN、DS-Lite、IPv6 Option 只用于日本 SKU，未做成原生页面。"
        case .sdnScenario: "专业访客网络场景依赖 SDN 组件，未做成原生页面。"
        case .upgrade: "固件在线升级不在向导里进行；Asuswrt-Merlin 也已移除向导的升级按钮。"
        case .axMode: "在“本地登录”页按“上一步”时，支持 11AX 的机型（未设 qis_hide_he_features）会进入 802.11ax 页（mobile/pages/axMode_page.html，abort.login 1882–1885）；该页的“下一步”会写入 wl0/1/2_11ax 并提交整个向导，未做成原生页面。"
        }
    }
}

// MARK: - Form

/// The inputs of the wizard's pages; like the page's DOM they keep their values between visits.
public enum QISFieldID: String, Sendable, Hashable, CaseIterable {
    case username, password, passwordConfirm
    case pppoeUsername, pppoePassword, vpnServer
    case staticIP, staticMask, staticGateway, staticDNS1, staticDNS2
    case vendorID, clientID
    case lanIP, lanMask, lanGateway, lanDNS1, lanDNS2
    case iotSSID, iotKey
}

/// A wireless input pair (Get_Component_WirelessInput, plugins.js 955–1097): the band's unit, its title and suffix.
public struct QISWirelessInput: Sendable, Equatable, Identifiable {
    public let unit: String
    public let title: String
    public var ssid: String
    public var key: String
    public var id: String { unit }
}

public struct QISForm: Sendable, Equatable {
    public var values: [QISFieldID: String] = [:]
    /// #defpass_checkbox, #iptv_checkbox, #wan_dhcp_option_checkbox, #wan_clientid_type, #wireless_checkbox,
    /// #wireless_sync_checkbox (inside the hidden #syncSSID), #sdn_iot_checkbox.
    public var defaultPassword = false
    public var iptv = false
    /// Where #iptv_check_container is: QIS_wizard.htm puts it in #wan_iptv_checkbox on the WAN type page (1264–1268);
    /// goTo.PPPoE moves it to #pppoe_iptv_checkbox on the account page (handler.js 3411–3420, QIS_wizard.htm 1470) and
    /// apply.manual moves it back (305–313). The same box, so its state goes with it.
    public var iptvOnAccount = false
    public var dhcpOption = false
    public var clientIDType = false
    public var separate = true
    public var sync = true
    public var iotLater = false
    /// #vpnServerContainer shows for PPTP/L2TP (goTo.VPN 3676) until abort.pppoe hides it.
    public var vpnServer = false
    /// #wlInputField: nil until goTo.Wireless first builds it.
    public var wireless: [QISWirelessInput]?
    /// The EULA page's age box.
    public var eulaAge = false
    /// The privacy statement's withdrawal popup (PolicyWithdrawModalComponent).
    public var withdrawing = false
    /// What the `.pppInput` change handler does: goTo.PPPoE (3486–3492) and goTo.VPN (3708–3712) unbind and bind their own,
    /// and the DHCP option inputs share the class.
    var pppInputBinding: PPPBinding = .none
    enum PPPBinding: Sendable, Equatable { case none, pppoe, vpn }
    /// goTo.Static binds `.staticInput` change (3572–3577) and never unbinds it.
    var staticBound = false
    /// An input was edited since the last button: its `change` handler runs (as the blur before a click does) first.
    var changePending = false
    public func value(_ field: QISFieldID) -> String { values[field] ?? "" }
}

/// A window.confirm the flow waits on.
public struct QISQuestion: Sendable, Equatable, Identifiable {
    public let id: String
    public let text: String
}

/// A side effect a page starts on its own, which the app asks about before sending.
public enum QISEffect: Sendable, Hashable {
    /// httpApi.startAutoDet (httpApi.js 512–514): GET appGet.cgi?hook=start_force_autodet().
    case autoDetect
    /// httpApi.startWan46AutoDet (520–522): GET appGet.cgi?hook=restart_auto46det(), for Japan with IPv6 on.
    case auto46Detect
    /// startLiveUpdate (plugins.js 2274–2304): once the router is online, the firmware check request.
    case liveUpdate
}

/// Where the wizard sends the user away from itself.
public enum QISExit: Sendable, Equatable {
    /// window.history.back() (flags manual, pppoe and lanip).
    case back
    /// top.location.href = "/MLO.asp" (abort.wireless with flag mlo, handler.js 2403–2410).
    case mloPage
    /// goTo.leaveQIS: location.href = "/".
    case done
}

// MARK: - The wizard

public struct QISWizard: Sendable, Equatable {
    /// The URL flag the wizard was opened with ("" for none).
    public let flag: String
    public internal(set) var page: QISPage = .welcome
    /// systemVariable.historyPage.
    var history: [String] = []
    public internal(set) var post = QISPostData()
    var sys = QISSystem()
    var http = QISHttp()
    public internal(set) var form = QISForm()
    /// The hints under the inputs (showTextHint); `$(".hint").remove()` clears them.
    public internal(set) var hints: [QISFieldID: String] = [:]
    /// Hints that belong to no input: the SSID check under a wireless input, the WAN port choice.
    public internal(set) var wirelessHints: [String: String] = [:]
    /// window.alert texts raised by the last event, in order.
    public internal(set) var alerts: [String] = []
    /// Side effects waiting for the user's answer, in the order the page starts them.
    public internal(set) var effects: [QISEffect] = []
    /// Answers to window.confirm questions while an event is run again.
    var answers: [String: Bool] = [:]
    /// Requests the current event sends (the page's nvramSet / chpass / policy GETs), in order.
    var outbox: [QISOutgoing] = []
    /// What the event does once the outbox went out (the requests' callbacks).
    var then: QISThen = .nothing
    /// The polling of waiting_page, noWan_page and resetModem_page.
    var poll = QISPoll()
    /// The event a window.confirm interrupted, run again with the answer.
    var pending: QISEvent?
    /// window.history.back() or a jump to another page of the router.
    var exit: QISExit?
    /// The firmware check startLiveUpdate runs in the background, once the user allowed it.
    public var liveUpdate = QISLiveUpdateLink(actor: nil)

    init(flag: String) { self.flag = flag }

    /// What the page under the policy pages reads: the statement's version (privateEula / asus_pp) and language.
    public var language: String { sys.uiLanguage }
    public var model: String { sys.productid }
    public var isDefault: Bool { sys.isDefault }
    public var restartWANDone: Bool { sys.restartWanIf }
}

struct QISSystem: Sendable, Equatable {
    var ethWanIf = 0
    var originWanType = ""
    var originPppUsername = "", originPppPassword = ""
    var wanDnsenable = ""
    var originOpMode = "RT", opMode = "RT"
    var wirelessBand = 0
    var productid = "", territoryCode = "", ipv6Service = "", lanIpaddr = "", uiLanguage = "", coBrand = "", sdkVersion = ""
    var isDefault = false
    var forceChangePw = false, forceChangePwInTheEnd = false
    var maxPasswordLen: OrderedJSON?
    var originWansMode = "", originWansExtwan = "", originWansDualwan = "", originAutoWAN = ""
    var scMode = "SC_all"
    var mloSetup = false
    /// systemVariable.eth_wan_list: get_ethernet_wan_list as read at start.
    var ethWanList: OrderedJSON = .object([])
    /// systemVariable[key] for the extra_settings keys (QIS_wizard.htm 233–245).
    var extra: [String: String] = [:]
    /// systemVariable.detwanResult.
    var detwanType = "", ipConflict = false
    var manualWanSetup = false
    var manualWanType: String?
    var restartWanIf = false
    var advSetting = false
    var welcomeRT = false, welcomeWISP = false
    var wanOption = false
    var isNewFw: OrderedJSON = .number("0")
    var newFwVersion = "", forceLevel = ""
    var websStateUpdate: String?
    var sdnIdx = 0, apgIdx = 0
    /// systemVariable.default_http_passwd (qisData.js 336).
    var defaultHTTPPasswd = "admin"
    /// window.pppAuthFailChecked (httpApi.js 895–909).
    var pppAuthFailChecked = false
    /// httpApi.detRetryCnt: `this.detRetryCnt_MAX` in the object literal is undefined (httpApi.js 12–13).
    var detRetryCnt: Int?
    /// handleSysDep's isNoWAN, which keeps `.amasNoWAN` (plugins.js 1310, 1342).
    var initNoWAN = false
    /// noWan_page's 手动设置 has a handler once goTo.NoWan bound one (5056–5057).
    var noWanManualBound = false
    /// hadPlugged("modem") when goTo.WANOption ran (5527–5528).
    var modemPlugged = false
    /// smartConnectObj.smart_connect_selif_x, which goTo.Wireless sets on the shared object (4205–4207).
    var selifInObject: String?
    /// The #wireless_checkbox change handler, bound when the inputs are first built (4269–4306).
    var wirelessHandlerBound = false
    /// #wireless_key_IoT exists (goTo.SDN_IoT builds it once, 6147).
    var iotBuilt = false
    /// `.bandStreeringSupport`: the 个别设定 box shows with Smart Connect in RT, AP and WISP (4202–4213).
    var bandSteeringShown = false
}

/// The caches of httpApi.js: nvramGet (cachedData), hookGet, nvramDefaultGet and the nvram_char_to_ascii answers read so far.
struct QISHttp: Sendable, Equatable {
    var nvram = NvramGetCache()
    var encoded: [String: String] = [:]
    var hooks: [String: OrderedJSON] = [:]
    var defaults: [String: String] = [:]
    var ui = UISupport(nil)
}

/// One request of an event, and whether the event goes on when it fails.
struct QISOutgoing: Sendable, Equatable {
    let request: QISRequest
    /// The page does not look at this request's answer (an async nvramSet without callback, chpass), so a failure does not
    /// stop what follows.
    let ignoresAnswer: Bool
}

/// What a request's callback runs.
enum QISThen: Sendable, Equatable {
    case nothing
    /// httpApi.newEula.set's callback: goTo.PP() (asus_policy.js 2518–2520).
    case privacy
    /// privateEula.set's callback (2497–2511), apply.Policy, knowRisk: goTo.Welcome().
    case welcome
    /// nvramSet's callback in submitQIS / abort.update: goTo.Update or goTo.Finish.
    case update, finish
}

/// The timers of the polling pages: goTo.Waiting (5220–5285), goTo.NoWan (5056–5114), goTo.ResetModem (5148–5187) and the
/// NOWAN / RESETMODEM / CHECKING branches of abort.wan (2028–2133).
struct QISPoll: Sendable, Equatable {
    /// `retry` is abort.resetModem's own timer on waiting_page (1946–1964).
    enum Kind: Sendable, Equatable { case none, waiting, retry, noWan, noWanAfterBack, resetModem }
    var kind: Kind = .none
    var errCount = 0
    var linkCount = 0
    /// parseInt(wandog_interval), 5 when it is empty; NaN makes the limits never reached, as in the page.
    var wandogInterval: Double = 5
    /// Ticks run so far: some timers wait longer before their first run than between runs.
    var ticks = 0
}

// MARK: - Texts (CN.dict)

/// The dictionary texts the pages show, with the line of CN.dict.
public enum QISText {
    static let internet = "互联网"                                   // Internet 2716
    static let back = "上一步"                                       // CTL_prev 297
    static let next = "下一步"                                       // CTL_next 296
    static let apply = "应用本页面设置"                              // CTL_apply 287
    static let fieldBlank = "栏位不能为空白"                         // JS_fieldblank 424
    static let yes = "是", no = "否"                                // checkbox_Yes / checkbox_No
    static let dynamicIP = "动态 IP"                                 // BOP_ctype_title1
    static let staticIP = "静态 IP"                                  // BOP_ctype_title5
    static let manualAssign = "手动分配"                             // Manual_Setting_assign
    static let manualSetting = "手动设置"                            // Manual_Setting_btn
    static let ssid = "无线名称（SSID）"                             // QIS_finish_wireless_item1
    static let networkKey = "网络密码"                               // QIS_finish_wireless_item3
    static let pskInvalid = "WPA 无线密码应为 8~63 个字符的字符串或 64 个十六进制字符。"   // JS_PSK64Hex 432
    static let pskWhiteSpace = "WPA金钥不能包含空格字符！"           // JS_PSK64Hex_whiteSpace 434
    static let pskKR = "WPA 无线密码应为 8~63 个字符的字符串。"      // JS_PSK64Hex_kr 433
    static let validPWD = "依据韩国法规，登入密码长度必须 8 个字元以上且至少包含 1 个英文字母、1 个数字以及 1 个特殊字元。" // JS_validPWD 441
    static let maxSSID = "网络名称的长度已经达到最大值。"             // JS_max_ssid 429
    static let validSSID1 = "SSID不能包含「", validSSID2 = "」这个字符。" // 446–447
    static let validStr1 = "第一个字符不能是：", validStr2 = "本字符串无法包含：", validStr3 = "最后一个字符不能是：" // 448–450
    static let invalidChars = "是无效字符。"                         // JS_invalid_chars 2876
    static let commonPassword = "常见的密码组合很容易让他人猜到，是否继续？" // JS_common_passwd 420
    static let usePasswordHarder = "为保障您的网络安全，请使用更复杂的密码。" // AiProtection_scan_note11 1549
    /// JS_validhostname 2886, as the page's JavaScript string reads its \" escapes.
    static let validHostname = "路由器登录名仅允许使用字母与数字、下划线和横线。首字符不能为 \"-\" 或 \"_\"。"
    static let shortUsername = "您的登录名称长度太短啰! 这样很不安全。"  // JS_short_username 437
    static let reservedAccount = "用户帐号不能为'root','guest','anonymous' 请输入有效的帐号名称！" // USB_Application_account_alert 1013
    static let samePassword = "登录用户名和密码不得相同。"            // JS_validLoginPWD_same 443
    static let loginPolicy = "密码长度必须至少包含 10 个字符，其中包括 1 个字母、1 个特殊字符和 1 个数字字符。不得有连续相同的字符。登录用户名和密码不得相同。" // JS_validLoginPWD 442
    static let passwordsMatch = "密码应匹配。"                       // File_Pop_content_alert_desc7 365
    static let defaultPassword = "新密码与系统默认密码相同，强烈建议您设置一个更严谨的密码。" // QIS_adminpass_confirm0 614
    static let shortPassword = "您的密码长度太短，这样不太安全！"    // JS_short_password 436
    static let passwordLength = "密码需在 5-32 个字符间。"           // JS_password_length 430
    static let maxPassword = "你的密码设置过长。密码需在 5-32 个字符间。" // JS_max_password 427
    static let pppFail = "帐号或密码有误，请重新输入帐号密码。"       // QKSet_Internet_Setup_fail_reason2 922
    static let wanIPIsGateway = "你已将互联网IP设置为网关IP，ZVMODELVZ 也许因此无法正确的连接到互联网，请重新设置正确的网关IP。" // IPConnection_warning_WANIPEQUALGatewayIP
    static let duplicate = "主要无线网络已设置。 此项已纳入列表中。" // qis_wireless_set_done + JS_duplicate
    static let ageConfirm = "请确认您已满 16 岁。"                    // ASUS_eula_age_confirm 187
    /// Said instead of the characters a password may not contain. The page lists them after JS_validstr2 (plugins.js 2346,
    /// 2376, 2398; validator.js 1716, 1882, 1938), which would show part of the admin password, Wi-Fi key or IoT key; the
    /// app states the rule only. The checks themselves are the page's.
    static let passwordCharacters = validStr2 + "英文半角可打印字符（空格至 ~）以外的字符。为保护密码，这里不显示具体字符。"
    /// The same for validator.string_KR and psk_KR, which also refuse the space (`<= ' '`).
    static let passwordCharactersNoSpace = validStr2 + "空格，以及英文半角可打印字符（! 至 ~）以外的字符。为保护密码，这里不显示具体字符。"
    /// ZVDOMAIN_NAMEVZ (ej.c 141).
    static let domain = "www.asusrouter.com"
}
