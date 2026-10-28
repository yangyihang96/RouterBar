import Foundation

// MARK: - 操作模式

/// 系统管理 › 操作模式 (Advanced_OperationMode_Content.asp): the modes the router offers, what each one says, and where
/// 保存 goes. 保存 never writes sw_mode itself: after its checks every path opens the QIS wizard (saveMode 376–442), whose
/// own pages make the change; applyRule after them is never reached.
public struct OperationModePage: Sendable, Equatable {
    static let keys = ["sw_mode", "wlc_express", "productid", "preferred_lang"]
    public let values: [String: String]
    /// get_operation_mode() (web.c 41323–41387): "rt", "ap", "rp", "mb", "ew2", "ew5", "hs" or "wisp".
    public let operationMode: String
    public let support: [String: String]

    public init(values: [String: String], operationMode: String, support: [String: String]) {
        self.values = values; self.operationMode = operationMode; self.support = support
    }

    func supports(_ name: String) -> Bool { !["", "0"].contains(support[name] ?? "") }
    var aiMeshRouter: Bool { supports("amas") && supports("amasRouter") }
    /// ZVMODELVZ in the dictionary texts.
    public var model: String { values["productid"] ?? "" }

    /// sw_mode_orig (106–116): 4, 3, 2 or 6 when isSwMode says MB, AP, RP or WISP, otherwise sw_mode as stored.
    public var originalMode: String {
        switch operationMode {
        case "mb": "4"
        case "ap": "3"
        case "rp": "2"
        case "wisp": "6"
        default: values["sw_mode"] ?? ""
        }
    }

    public struct Mode: Sendable, Equatable, Identifiable {
        public let id: String
        public let mode: String
        public let express: String
        public let label: String
        /// mode_desc: the description paragraphs, then the yellow note with its Device Discovery link.
        public let paragraphs: [String]
        public let note: Note?
    }
    /// A yellow note: the text around its one link.
    public struct Note: Sendable, Equatable {
        public let before: String
        public let link: String
        public let after: String
    }
    public static let deviceDiscovery = URL(string: "http://dlcdnet.asus.com/pub/ASUS/LiveUpdate/Release/Wireless/Discovery.zip")!

    /// The radios initial() appends (276–322), in order, less those it hides: Router unless noRouter, AP unless noAP,
    /// Repeater with repeater, the two Express Ways with rp_express_2g / rp_express_5g, Media Bridge with psta, AiMesh Node
    /// with amas and amasNode, WISP with wisp.
    public var modes: [Mode] {
        var modes: [Mode] = []
        let m = model
        if !supports("noRouter") {
            modes.append(Mode(id: "routerMode", mode: "1", express: "0",
                              label: aiMeshRouter ? "无线路由器模式 / AiMesh 路由器模式（默认）" : "无线路由器 (默认)",
                              paragraphs: aiMeshRouter
                                ? ["AiMesh 路由器模式为具有 AiMesh 随心组网功能的传统模式，可通过 PPPoE、DHCP，PPTP、L2TP 或固定 IP 连接至互联网。成功连接至网络后，路由器将与 LAN 客户端或设备共享无线网络。此模式默认启用 NAT、防火墙和 DHCP 服务器。同时也支持 UPnP 和动态 DNS，为 SOHO 和家庭用户带来便利。若您第一次使用华硕无线路由器，或者您目前没有使用任何有线/无线路由器，请选择此模式。",
                                   "您可以添加 AiMesh 节点以组成 AiMesh 随心组网 WiFi 系统，由此而提供更广范围的 WiFi 覆盖。"]
                                : ["在无线路由器模式中，\(m) 透过 PPPoE、DHCP、PPTP、L2TP 或静态 IP 连接至网络，并且将无线网络分享至 LAN 客户端或设备。",
                                   "在此模式中，NAT、防火墙与 DHCP 服务器默认为开启。支持 UPnP 与动态 DNS 适用于 SOHO 与家庭使用者。",
                                   "若您是第一次使用，或您当前未使用任何有线/无线路由器时，选择此模式。"],
                              note: nil))
        }
        if !supports("noAP") {
            modes.append(Mode(id: "apMode", mode: "3", express: "0",
                              label: aiMeshRouter ? "无线接入点（AP）模式 / AiMesh 路由器（AP 模式）" : "无线访问点 (Access Point)",
                              paragraphs: aiMeshRouter
                                ? ["AP 模式下的 AiMesh 路由器将通过网线连接至另一台无线路由器，以将无线信号扩展至其他网络客户端。此模式下，防火墙、IP 共享和 NAT 功能默认关闭。",
                                   "您可以添加 AiMesh 节点以组成 AiMesh 随心组网 WiFi 系统，由此而提供更广范围的 WiFi 覆盖。"]
                                : ["在无线访问点 (Access Point) 模式中，\(m) 透过以太网口连接制无线路由器，以拓展无线信号覆盖范围。在此模式中，防火墙、IP 分享与 NAT 功能是禁用的。"],
                              note: aiMeshRouter
                                ? Note(before: "当 AiMesh 路由器处于 AP 模式时，DHCP 指定的 IP 地址将会改变。请安装 ", link: "Device Discovery Utility", after: " 应用程序以检测无线路由器的 IP 地址。")
                                : Note(before: "在无线访问点 (AP) 模式中，若由 DHCP 所分配的 IP 地址变动，请安装与使用 ", link: "Device Discovery 程序", after: " 以利获取无线路由器新的 IP 地址。")))
        }
        let repeaterNote = Note(before: "在中继模式中，若由 DHCP 所分配的 IP 地址变动。请安装与使用 ", link: "Device Discovery Utility", after: " 以利获取无线路由器新的 IP 地址。")
        if supports("repeater") {
            modes.append(Mode(id: "repeaterMode", mode: "2", express: "0", label: "中继模式",
                              paragraphs: ["在中继模式下，\(m) 采用无线连接至一个已经存在的无线网络，以扩展无线覆盖范围。在这个模式下，防火墙、IP 分享以及 NAT 功能是禁用的。"],
                              note: repeaterNote))
        }
        if supports("rp_express_2g") {
            modes.append(Mode(id: "rp_express_2g", mode: "2", express: "1", label: "Express Way 2.4GHz",
                              paragraphs: ["在 Express Way 2.4GHz 模式下，\(m) 无线路由器将会连接至现有 2.4GHz WiFi 频道，并且仅可通过 5GHz WiFi 频道扩展无线网络范围。"],
                              note: repeaterNote))
        }
        if supports("rp_express_5g") {
            modes.append(Mode(id: "rp_express_5g", mode: "2", express: "2", label: "Express Way 5GHz",
                              paragraphs: ["在 Express Way 5GHz 模式下，\(m) 无线路由器将会连接至现有 5GHz WiFi 频道，并且仅可通过 2.4GHz WiFi 频道扩展无线网络范围（您的路由器需支持 5GHz WiFi 频道）。"],
                              note: repeaterNote))
        }
        if supports("psta") {
            modes.append(Mode(id: "mbMode", mode: "4", express: "0", label: "无线桥接 (Media Bridge)",
                              paragraphs: ["\(m) 可被设置为无线桥接 (Media Bridge) 模式。无线桥接 (Media Bridge) 模式可同时为多个媒体设备提供快速的 WiFi 连接。要使用无线桥接 (Media Bridge) 模式，您需要两台 \(m)：一台作为 Media Bridge，另一台作为路由器。将一台 \(m) 设置为路由器模式，另一台 \(m) 设置为无线桥接 (Media Bridge)，为您的媒体设备，如电脑、智能电视、游戏终端、DVR 或媒体播放器，提供一个并行的 WiFi 连接。变更到无线桥接 (Media Bridge) 模式为您的媒体设备提供一个并行的 WiFi 连接。",
                                           "在无线桥接 (Media Bridge) 模式中，只有无线设备连接至 Parent-AP。客户端设备需使用网线连接至无线桥接。"],
                              note: Note(before: "在无线桥接 (Media Bridge) 模式中，DHCP 分配的 IP 地址将更改。安装并使用 ", link: "Device Discovery Utility", after: " 来获得无线路由器新的 IP 地址。")))
        }
        if supports("amas"), supports("amasNode") {
            modes.append(Mode(id: "AiMeshMode", mode: "5", express: "0", label: "AiMesh 节点",
                              paragraphs: ["您可以将此路由器设置为 AiMesh 节点以扩展现有 AiMesh 路由器的 WiFi 覆盖范围。",
                                           "1. 出厂重置此路由器将允许其添加至现有的 AiMesh 随心组网网络。", "2. 请至现有路由器的 AiMesh 设置页面添加 AiMesh 节点。"],
                              note: nil))
        }
        if supports("wisp") {
            modes.append(Mode(id: "wispMode", mode: "6", express: "0", label: "公共 WiFi 模式 (WISP)",
                              paragraphs: ["\(m) 通过无线网络连接至您的主要路由器、存取点或公共热点，并与您的有线/无线客户端共享网络。此模式下， NAT、防火墙和 DHCP 服务器默认为开启。",
                                           "连接至 WiFi 热点前，请确认已允许您访问互联网。"],
                              note: nil))
        }
        return modes
    }

    /// The radio checked when the page opens: setScenerion(sw_mode_orig, wlc_express) (536–680), which for the repeater
    /// modes picks Express Way 2.4 / 5 GHz by wlc_express and otherwise the radio of the mode, the router by default.
    public var initialMode: Mode? {
        let express = javaScriptNumber(values["wlc_express"])
        let target = switch originalMode {
        case "2": express == 1 ? "rp_express_2g" : express == 2 ? "rp_express_5g" : "repeaterMode"
        case "3": "apMode"
        case "4": "mbMode"
        case "5": "AiMeshMode"
        case "6": "wispMode"
        default: "routerMode"
        }
        return modes.first { $0.id == target }
    }

    /// What 保存 leads to for the chosen mode (saveMode 376–442).
    public enum Save: Sendable, Equatable {
        /// `<#Web_Title2#> <#op_already_configured#>` and nothing else.
        case alreadyConfigured(String)
        /// Questions answered with confirm(), in order, before the wizard opens.
        case wizard(flag: String, confirmations: [String])
    }
    public func save(_ chosen: Mode) -> Save {
        let original = originalMode
        // `sw_mode_orig == document.form.sw_mode.value`; for the repeater modes wlc_express (as stored) too.
        if javaScriptLooseEquals(original, chosen.mode), chosen.mode != "2" || (values["wlc_express"] ?? "") == chosen.express {
            return .alreadyConfigured(model + " 已经设定为此模式。")
        }
        var confirmations: [String] = []
        // AiMesh_confirm_msg("Operation_Mode", …) (require/modules/amesh.js 78–90) with amas and amasRouter.
        if aiMeshRouter {
            if chosen.mode == "2" { confirmations.append("若您将路由器的操作模式更改为中继模式， AiMesh 随心组网系统将会关闭。\n确定继续？") }
            if chosen.mode == "4" { confirmations.append("若您将路由器的操作模式更改为 Media Bridge 模式， AiMesh 随心组网系统将会关闭。\n确定继续？") }
        }
        switch chosen.mode {
        case "2": return .wizard(flag: chosen.express == "1" ? "sitesurvey_exp2" : chosen.express == "2" ? "sitesurvey_exp5" : "sitesurvey_rep", confirmations: confirmations)
        case "3":
            if supports("mtlancfg"), original == "1" { confirmations.append(sdnHint(chosen.label)) }
            return .wizard(flag: "lanip", confirmations: confirmations)
        case "4": return .wizard(flag: "sitesurvey_mb", confirmations: confirmations)
        case "5": return .wizard(flag: "amasnode_page", confirmations: confirmations)
        case "6": return .wizard(flag: "wispMode", confirmations: confirmations)
        default:
            if supports("mtlancfg"), original == "3" { confirmations.append(sdnHint(chosen.label)) }
            return .wizard(flag: "rtMode", confirmations: confirmations)
        }
    }

    /// sdn_change_mode_hint (377–380) with #OPMODE the target radio's label and Guest_Network_naming (state.js 991–998).
    func sdnHint(_ label: String) -> String {
        let guest = supports("BUSINESS") ? "自定义网络" : supports("SMART_HOME_MASTER_UI") ? "访客网络" : "专业访客网络"
        return "AiProtection 网络神盾, VPN 客户端, 虚拟专用网 (VPN) 服务器, QoS：这些功能不可用。\n"
            + guest + " 的配置文件列表将被清除。请重新配置。\n我们建议您在切换到 " + label + " 之前下载并保存配置文件。\n您确定要继续吗？"
    }

    /// `sw_mode_orig == document.form.sw_mode.value`: sw_mode_orig is a number when isSwMode matched, else the stored text.
    func javaScriptLooseEquals(_ original: String, _ chosen: String) -> Bool {
        ["mb", "ap", "rp", "wisp"].contains(operationMode) ? javaScriptNumber(chosen) == javaScriptNumber(original) : original == chosen
    }
}

extension RouterClient {
    public func operationModePage() async throws -> OperationModePage {
        OperationModePage(values: try await readSettings(OperationModePage.keys),
                          operationMode: try await orderedHook("get_operation_mode")?.text ?? "", support: try await uiCapabilities())
    }
}
