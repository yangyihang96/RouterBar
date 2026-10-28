import Foundation

// 网络设置向导每一页显示的内容：标题、说明、选项、输入栏和复选框，文字取自 QIS_wizard.htm 与 CN.dict（简体中文），
// 显示条件照 handleSysDep 与各 goTo 函数。

public struct QISChoice: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
}
public struct QISFieldSpec: Sendable, Equatable, Identifiable {
    public let id: QISFieldID
    public let title: String
    public let maxLength: Int?
    public let secure: Bool
    /// onkeypress="return validator.isIPAddr(this, event);".
    public let ipFilter: Bool
    public let enabled: Bool
}
public struct QISToggle: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let on: Bool
}

/// One page as the router's wizard draws it.
public struct QISScreen: Sendable, Equatable {
    public var title = ""
    public var subtitles: [String] = []
    public var paragraphs: [String] = []
    public var choices: [QISChoice] = []
    public var fields: [QISFieldSpec] = []
    public var toggles: [QISToggle] = []
    /// Yellow notes and hints that belong to no input.
    public var notes: [String] = []
    public var back: String?
    public var next: String?
}

extension QISWizard {
    func dictionary(_ text: String) -> String { text.replacingOccurrences(of: "ZVMODELVZ", with: sys.productid) }
    static let staticDescription = "您的 ISP 已经提供给您 IP 地址，子网掩码，网关和 DNS 地址的信息。如果没有，请联系您的 ISP。" // QIS_SmartConn_StaticDesc
    static let addressTitles = ["IP 地址", "子网掩码", "默认网关", "DNS 服务器1", "DNS 服务器2"]   // IPConnection_* itemnames

    public var screen: QISScreen {
        var s = QISScreen()
        let back = QISText.back
        switch page {
        case .eula:
            s.title = "最终用户许可协议"
            s.paragraphs = ["在使用网络产品之前，请务必阅读本条款。点击“同意”按钮即表示您同意接受本条款的约束。\u{200B}"]   // ASUS_POLICY_QIS_Desc
            s.toggles = [QISToggle(id: "eulaAge", title: "我已满 16 岁。", on: form.eulaAge)]
            s.notes = ["请滚动到底部"]
            s.next = "同意"
        case .privacy(let status):
            // The CN title loses its spaces (asus_policy.js 1671–1672).
            s.title = status.language == "CN" ? "ASUS隐私声明" : "ASUS 隐私声明"
            s.paragraphs = ["在使用网络产品之前，请务必阅读本条款。点击“同意”按钮即表示您同意接受本条款的约束。\u{200B}"]
            if status.privacyDocument != nil {
                s.back = "拒绝"; s.next = "同意"
            } else {
                // No text for this version: the web page stops before it shows (asus_policy.js 920, 2574), so there is no
                // 同意 or 拒绝 to offer.
                s.notes = ["这台路由器的隐私声明版本是 v\(status.privacyVersion)，路由器网页的政策脚本只有 v2 和 v4 的正文（asus_policy.js 22、47）：网页在这里脚本出错、页面空白，没有可以同意或拒绝的正文。App 不发送同意或拒绝。可以在浏览器中打开网页向导查看。"]
            }
        case .welcome:
            s.title = "欢迎使用 " + sys.productid
            s.choices = [QISChoice(id: "create", title: "创建新的网络")]
            if welcomeOffersWISP { s.choices += [QISChoice(id: "rt", title: "无线路由器"), QISChoice(id: "wisp", title: "公共 WiFi 模式 (WISP)")] }
            s.choices.append(QISChoice(id: "advanced", title: "高级设置"))
        case .advancedSetting:
            s.title = QISText.internet; s.subtitles = ["操作模式"]
            if isSupport("amas"), sys.initNoWAN, isSupport("amasNode") {
                s.paragraphs.append("AiMesh 整合多台华硕路由器组成 AiMesh 系统，为您提供强大的家庭网络覆盖和集中式网络管理。")
                s.choices.append(QISChoice(id: "asNode", title: "我想将此台设备设置为 AiMesh 节点。"))
            }
            if !(!isSupport("amasNode") && !isSupport("repeater") && !isSupport("psta") && isSupport("noAP")) {
                s.paragraphs.append(dictionary("ZVMODELVZ 支持多种操作模式，以满足不同需求。请选择您所需的模式。"))
            }
            s.choices.append(QISChoice(id: "opMode", title: "选择操作模式"))
            s.paragraphs.append(dictionary("请将设置文件的路径及名称指定到此字段，然后点选「上传」将文件写入到 ZVMODELVZ 上。请等候约60秒的时间直到系统重新启动完毕。"))
            s.choices.append(QISChoice(id: "upload", title: "上传"))
            s.back = back
        case .login:
            s.title = isSupport("defpass") ? "本地登录" : "登录"
            s.subtitles = ["用户名 / 密码", "设置"]
            s.paragraphs = ["设置本地登录用户名和密码，以防止未经授权的访问 ASUS 网络设备。"]
            if showsStrictLoginPolicy { s.paragraphs.append(QISText.loginPolicy) }
            s.fields = [QISFieldSpec(id: .username, title: isSupport("defpass") ? "帐号" : "路由器登录名称", maxLength: 32, secure: false, ipFilter: false, enabled: true),
                        QISFieldSpec(id: .password, title: "密码", maxLength: 33, secure: true, ipFilter: false, enabled: !form.defaultPassword)]
            if !form.defaultPassword {
                s.fields.append(QISFieldSpec(id: .passwordConfirm, title: "确认密码", maxLength: 33, secure: true, ipFilter: false, enabled: true))
            }
            if isSupport("defpass") {
                s.toggles = [QISToggle(id: "defpass", title: "使用默认本地登录密码", on: form.defaultPassword)]
                s.notes = ["在本地连接该华硕网络设备时，使用默认的加密本地登录密码可以实现安全登录。", "如何找到 本地登录密码：本地登录密码 可以在您的华硕设备背面/底部的标签上找到。"]
            }
            s.back = back; s.next = QISText.next
        case .opMode:
            s.title = QISText.internet; s.subtitles = ["操作模式"]
            s.paragraphs = [dictionary("ZVMODELVZ 支持多种操作模式，以满足不同需求。请选择您所需的模式。")]
            if !isSupport("noRouter") { s.choices.append(QISChoice(id: "rt", title: "无线路由器 (默认)")) }
            if isSupport("repeater") { s.choices.append(QISChoice(id: "rp", title: "中继模式")) }
            if !isSupport("noAP") { s.choices.append(QISChoice(id: "ap", title: "无线访问点 (Access Point)")) }
            if isSupport("psta") { s.choices.append(QISChoice(id: "mb", title: "无线桥接 (Media Bridge)")) }
            if isSupport("amas") { s.choices.append(QISChoice(id: "amas", title: "AiMesh")) }
            if isSupport("wisp") { s.choices.append(QISChoice(id: "wisp", title: "公共 WiFi 模式 (WISP)")) }
            s.back = back
        case .waiting:
            s.title = QISText.internet; s.subtitles = ["自动侦测"]
            s.paragraphs = ["开始搜索您的联网模式..."]
            s.choices = [QISChoice(id: "manual", title: QISText.manualSetting)]
        case .resetModem:
            s.title = QISText.internet; s.subtitles = ["检查连接"]
            s.paragraphs = ["若您使用的是线缆调制解调器或设定为固定 IP 地址的调制解调器，请确认您已尝试下列操作：",
                            "请拔掉调制解调器的电源线。等待约两分钟后，在重新连接电源线。点击重新侦测联机。"]
            s.back = "重新侦测"
            s.choices = [QISChoice(id: "manual", title: QISText.manualSetting)]
        case .noWan:
            s.title = QISText.internet; s.subtitles = ["检查连接"]
            s.paragraphs = ["请将网络线接上 WAN 接口。系统将会自动侦测你的网络设定。"]
            s.back = back
            s.choices = [QISChoice(id: "manual", title: QISText.manualSetting)]
        case .specialISP:
            s.title = QISText.internet; s.subtitles = ["ISP 帐号设置"]
            s.paragraphs = ["网络服务运营商 (ISP) 特殊需求"]
            s.choices = [QISChoice(id: "yes", title: QISText.yes), QISChoice(id: "no", title: QISText.no)]
            s.back = back
        case .wanSetting:
            s.title = QISText.internet; s.subtitles = ["联机类型"]
            s.paragraphs = ["请在以下选项中选择网络连接类型。若您不知道网络连接类型，请咨询您的网络服务供应商（ISP）。"]
            s.choices = [QISChoice(id: "dhcp", title: QISText.dynamicIP), QISChoice(id: "pppoe", title: "PPPoE"), QISChoice(id: "static", title: QISText.staticIP)]
            if isSupport("s46") {
                s.choices.append(QISChoice(id: "ipv6:v6plus", title: "v6plus"))
                if isSupport("ocnvc") { s.choices.append(QISChoice(id: "ipv6:ocnvc", title: "OCN Virtual Connect")) }
                if isSupport("dslite") { s.choices += [QISChoice(id: "ipv6:xpass", title: "Xpass (DS-Lite)"), QISChoice(id: "ipv6:transix", title: "transix (DS-Lite)")] }
                if isSupport("v6option") { s.choices.append(QISChoice(id: "ipv6:v6opt", title: "IPv6 Option")) }
            }
            if isSupport("VPNCLIENT") { s.choices += [QISChoice(id: "pptp", title: "PPTP"), QISChoice(id: "l2tp", title: "L2TP")] }
            if isSupport("amas"), sys.initNoWAN, isSupport("amasNode") { s.choices.append(QISChoice(id: "asNode", title: "我想将此台设备设置为 AiMesh 节点。")) }
            if isSupport("IPTV"), !form.iptvOnAccount { s.toggles.append(iptvToggle) }
            s.toggles.append(QISToggle(id: "dhcpOption", title: "DHCP 选项", on: form.dhcpOption))
            s.back = back
        case .wanOption:
            s.title = QISText.internet; s.subtitles = ["联机类型"]
            s.paragraphs = ["WAN 联机类型"]
            s.choices = wanPortChoices.map { QISChoice(id: $0.id, title: $0.title) }
            if showsAutoWANHint { s.notes = ["WAN 自动检测功能将被停用。 请确保您的 WAN 线正确插入选定的端口。"] }
            s.back = back
        case .account:
            s.title = QISText.internet; s.subtitles = ["ISP 帐号设置"]
            s.paragraphs = ["请输入您的网络服务供应商 (ISP) 提供的 PPPoE 用户名和密码，以连接互联网。"]
            s.fields = [QISFieldSpec(id: .pppoeUsername, title: "PPPoE 用户名", maxLength: 64, secure: false, ipFilter: false, enabled: true),
                        QISFieldSpec(id: .pppoePassword, title: "PPPoE 密码", maxLength: 64, secure: true, ipFilter: false, enabled: true)]
            if form.vpnServer { s.fields.append(QISFieldSpec(id: .vpnServer, title: "虚拟专用网 (VPN) 服务器", maxLength: 64, secure: false, ipFilter: false, enabled: true)) }
            // #pppoe_iptv_checkbox under the inputs (QIS_wizard.htm 1470), holding the box once goTo.PPPoE moved it there.
            if isSupport("IPTV"), form.iptvOnAccount { s.toggles.append(iptvToggle) }
            s.back = back; s.next = QISText.next
        case .getIP, .getLanIP:
            s.title = QISText.internet; s.subtitles = [page == .getIP ? "IP 设置" : "内部网络地址设置"]
            s.paragraphs = ["自动取得内网 IP 地址？"]
            s.choices = [QISChoice(id: "dhcp", title: QISText.dynamicIP), QISChoice(id: "static", title: QISText.manualAssign)]
            s.back = back
        case .staticIP, .lanStatic:
            s.title = QISText.internet; s.subtitles = [QISText.staticIP]
            s.paragraphs = [Self.staticDescription]
            let ids: [QISFieldID] = page == .staticIP ? [.staticIP, .staticMask, .staticGateway, .staticDNS1, .staticDNS2] : [.lanIP, .lanMask, .lanGateway, .lanDNS1, .lanDNS2]
            s.fields = zip(ids, Self.addressTitles).map { QISFieldSpec(id: $0.0, title: $0.1, maxLength: 15, secure: false, ipFilter: true, enabled: true) }
            s.back = back; s.next = QISText.next
        case .dhcpOption:
            s.title = QISText.internet; s.subtitles = ["DHCP 选项"]
            s.paragraphs = ["DHCP 选项"]
            s.fields = [QISFieldSpec(id: .vendorID, title: "分类标识符 (选项 60)", maxLength: 126, secure: false, ipFilter: false, enabled: true),
                        QISFieldSpec(id: .clientID, title: "客户端标识符 (选项 61)", maxLength: 126, secure: false, ipFilter: false, enabled: !form.clientIDType)]
            s.toggles = [QISToggle(id: "clientIDType", title: "IAID/DUID", on: form.clientIDType)]
            s.back = back; s.next = QISText.next
        case .wireless:
            s.title = "无线网络"; s.subtitles = ["设置"]
            s.paragraphs = ["分配唯一的网络名称 (SSID) 以帮助识别您的无线网络。"]
            if sys.bandSteeringShown { s.toggles = [QISToggle(id: "separate", title: separateLabel, on: form.separate)] }
            if let hint = wirelessHints["dwb"] { s.notes = [hint] }
            s.back = isSupport("dsl") ? nil : back
            s.next = QISText.apply
        case .iot:
            s.title = "物联网网络"; s.subtitles = ["设置"]
            s.paragraphs = ["主要无线网络已设置。", "为了更好地兼容 WiFi 7，建议为 IoT 或旧设备创建独立网络，以确保顺畅运行。"]
            s.fields = [QISFieldSpec(id: .iotSSID, title: " " + QISText.ssid, maxLength: 33, secure: false, ipFilter: false, enabled: !form.iotLater),
                        QISFieldSpec(id: .iotKey, title: " " + QISText.networkKey, maxLength: 64, secure: true, ipFilter: false, enabled: !form.iotLater)]
            s.toggles = [QISToggle(id: "later", title: "可能稍后连接", on: form.iotLater)]
            s.back = back; s.next = QISText.apply
        case .update:
            s.title = "固件升级"
            s.paragraphs = ["A newer firmware version is available for download. Upgrading is recommended to improve security and stability."]
            s.next = updateShowsNext ? QISText.next : nil
        case .summary:
            s.title = "概要"
            s.paragraphs = ["您已完成上网设置", "Step 1", "你已更改了 SSID 或无线网络安全性设置，提醒您调整无线网卡设置以重新取得联机。",
                            "Step 2", "当新的 SSID 重新连接后，您可以回到 http://\(QISText.domain) 进行更多进阶的设定。"]
        case .browser(let branch):
            s.title = branch.title
            s.paragraphs = [branch.reason]
        }
        return s
    }

    /// #iptv_check_container (QIS_wizard.htm 1265–1268): PPPConnection_x_HostNameForISP_sectionname and, in red,
    /// PPPConnection_x_certain_WAN.
    var iptvToggle: QISToggle { QISToggle(id: "iptv", title: "网络服务运营商 (ISP) 特殊需求  （仅支持某些 WAN 类型）", on: form.iptv) }

    /// The labels of a wireless input pair: the band's title before 无线名称（SSID） and 网络密码 (plugins.js 1053, 1080).
    public func wirelessTitles(_ input: QISWirelessInput) -> (ssid: String, key: String) {
        (input.title + " " + QISText.ssid, input.title + " " + QISText.networkKey)
    }
    /// What goTo.Finish adds under the main network (handler.js 4691–4696): #wlTitleField_SDN_IoT (GuestNetwork_IoT,
    /// QIS_wizard.htm 3254–3256) and the IoT inputs, once goTo.SDN_IoT built them (6147–6149, titles "" + " " + the item
    /// as plugins.js 1105, 1136 write them) and while the IoT key is not empty; not in Media Bridge mode.
    public var summaryIoT: (title: String, ssidTitle: String, ssid: String, keyTitle: String, key: String)? {
        guard !isSwMode("MB"), sys.iotBuilt, !form.value(.iotKey).isEmpty else { return nil }
        return ("物联网网络", " " + QISText.ssid, form.value(.iotSSID), " " + QISText.networkKey, form.value(.iotKey))
    }
    /// The document of the policy page.
    public var policyDocument: PolicyDocument? {
        switch page {
        case .eula: PolicyTexts.eula
        case .privacy(let status): PolicyTexts.privacy(version: status.privacyVersion)
        default: nil
        }
    }

    /// check_password_length on the password's key up (plugins.js 662–683).
    mutating func checkPasswordLength() {
        let password = form.value(.password)
        if showsStrictLoginPolicy { hints[.password] = nil; return }
        let maximum = javaScriptToNumber(sys.maxPasswordLen)
        if !maximum.isNaN, Double(password.utf16.count) > maximum { hints[.password] = QISText.maxPassword }
        else if !password.isEmpty, password.utf16.count < 5 { hints[.password] = QISText.shortPassword + " " + QISText.passwordLength }
        else { hints[.password] = nil }
    }
}
