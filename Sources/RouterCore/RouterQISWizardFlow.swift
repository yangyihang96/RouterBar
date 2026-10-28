import Foundation

// 网络设置向导的状态机：入口（QIS_wizard.htm 76–313）与 handler.js 的 goTo / apply / abort，一个网页函数对应一个方法。
// 发送的请求只记入 outbox，由 App 确认后发出；网页不等回应就继续的（nvramSet 无回调）照样继续，等回调的（协议同意、最终提交）
// 在发送成功后由 QISThen 接着走。

/// What the user does on a page.
public enum QISEvent: Sendable, Equatable {
    /// A selectBar or button by its id.
    case choose(String)
    /// The page's apply button (下一步 / 应用本页面设置 / 同意).
    case next
    /// The page's abort button (上一步).
    case back
    case edit(QISFieldID, String)
    /// A wireless input: the band's unit and whether it is the SSID (otherwise the key).
    case editWireless(unit: String, ssid: Bool, value: String)
    case toggle(String, Bool)
    /// One second of a polling page.
    case tick
}

/// A window.confirm: the event stops here and runs again with the answer.
struct QISAsk: Error { let question: QISQuestion }

extension QISWizard {
    /// window.confirm(text): the answer given for `id`, or the question when there is none yet.
    func confirm(_ id: String, _ text: String) throws -> Bool {
        if let answer = answers[id] { return answer }
        throw QISAsk(question: QISQuestion(id: id, text: text))
    }

    /// goTo.loadPage (handler.js 5404–5434).
    mutating func loadPage(_ target: QISPage, reverse: Bool = false) {
        if reverse { if !history.isEmpty { history.removeLast() } } else { history.append(target.id) }
        page = target
        poll.kind = .none
        if target == .welcome, reverse, !history.isEmpty { history = ["welcome"] }
    }
    /// `goTo.loadPage(systemVariable.historyPage[systemVariable.historyPage.length-2], true)`.
    mutating func loadPreviousPage() {
        let id = history.count >= 2 ? history[history.count - 2] : ""
        loadPage(QISPage.named(id) ?? .welcome, reverse: true)
    }
    mutating func browser(_ branch: QISBranch) { loadPage(.browser(branch)) }
}

// MARK: - Start (QIS_wizard.htm 76–313)

extension QISWizard {
    static let initKeys = ["ASUS_NEW_EULA", "sw_mode", "wlc_psta", "wl_ifnames", "wlnband_list", "wl_version", "productid", "rc_support", "x_Setting",
                           "preferred_lang", "territory_code", "ipv6_service", "reboot_time", "lan_ipaddr", "wlc_dpsta", "wlc_band", "CoBrand",
                           "wans_dualwan", "wans_extwan", "wans_mode", "dslx_transmode", "dsl0_proto", "dsl0_pppoe_username", "dsl0_pppoe_passwd",
                           "dsl0_dnsenable", "dsl8_proto", "dsl8_pppoe_username", "dsl8_pppoe_passwd", "dsl8_dnsenable", "smart_connect_x", "mld_enable"]

    mutating func start(_ c: RouterClient) async throws {
        // isSupport("TS_UI") as the page loads (28) reads get_ui_support, productid/odmpid and amas_bdlkey.
        guard let support = try await c.orderedHook("get_ui_support"), case .object = support else { throw RouterError.invalidResponse("固件功能列表") }
        http.ui = UISupport(support); http.hooks["get_ui_support"] = support
        _ = try await nvramGet(["productid", "odmpid"], c)
        _ = try await nvramGet(["amas_bdlkey"], c)
        // Check_Https_Redirect_Status / Initial_Https_Redirect (40–43) are in js/https_redirect/https_redirect.js, which the
        // materials do not include: nothing is done for them.
        let initNvram = try await nvramGet(Self.initKeys, c)
        func v(_ key: String) -> String { initNvram[key] ?? "" }
        sys.ethWanIf = javaScriptSplit(v("wans_dualwan"), " ").firstIndex(of: "wan") ?? 0
        let wan = try await nvramGetWanByUnit(["wan_proto", "wan_pppoe_username", "wan_pppoe_passwd", "wan_dnsenable_x"], c)
        let dsl = v("dslx_transmode") != ""
        if dsl {
            sys.originWanType = v("dslx_transmode") == "ptm" ? v("dsl8_proto") : v("dsl0_proto")
        } else {
            sys.originWanType = wan["wan_proto"] ?? ""
            if ["pppoe", "pptp", "l2tp"].contains(sys.originWanType) {
                sys.originPppUsername = wan["wan_pppoe_username"] ?? ""; sys.originPppPassword = wan["wan_pppoe_passwd"] ?? ""
            }
            sys.wanDnsenable = wan["wan_dnsenable_x"] ?? ""
        }
        let mode = try await hookGet("get_operation_mode", c)
        let modeText = mode.map(TORSettings.javaScriptString) ?? ""
        sys.originOpMode = (javaScriptTruthy(mode) ? modeText : "RT").uppercased()
        sys.opMode = sys.originOpMode
        sys.wirelessBand = javaScriptSplit(v("wlnband_list"), "&#60").count
        sys.sdkVersion = javaScriptSplit(v("wl_version"), ".")[0]
        sys.productid = v("productid")
        sys.isDefault = v("x_Setting") == "0" || v("x_Setting") == ""
        sys.uiLanguage = v("preferred_lang"); sys.territoryCode = v("territory_code"); sys.ipv6Service = v("ipv6_service")
        sys.lanIpaddr = v("lan_ipaddr"); sys.coBrand = v("CoBrand")
        sys.forceChangePw = javaScriptLooselyEqual(try await hookGet("check_pw", c), .string("1"))
        _ = try await isConnected(c)
        sys.maxPasswordLen = ui.object?["MaxLen_http_passwd"]
        sys.originWansMode = v("wans_mode")
        if isSupport("2p5G_LWAN") { sys.originWansExtwan = try await nvram("wans_extwan", c) }
        if isSupport("10G_LWAN") || isSupport("10GS_LWAN") { sys.originWansDualwan = try await nvram("wans_dualwan", c) }
        if isSupport("autowan") { sys.originAutoWAN = try await nvram("autowan_enable", c) }
        let feat = try await hookGet("get_feat_def", c)
        sys.scMode = "SC_all"
        if case .array(let options)? = feat?["smart_connect_opt"], javaScriptContains(TORSettings.javaScriptString(.array(options)), "3"), wlUnit("6G") != "" {
            sys.scMode = "SC_2g5g"
        }
        if try await nvram("dwb_mode", c) == "1", sys.scMode == "SC_all" { sys.scMode = "SC_dwb_mode" }
        if isSupport("mlo") { sys.scMode = "SC_all" }
        sys.mloSetup = isSupport("mlo") ? (sys.isDefault || flag == "mlo" || v("mld_enable") == "1") : false
        sys.ethWanList = try await hookGet("get_ethernet_wan_list", force: true, c) ?? .object([])
        if ethWanCount > 1 {
            for (_, wanObject) in sys.ethWanList.members {
                for (key, _) in wanObject["extra_settings"]?.members ?? [] where sys.extra[key] == nil {
                    sys.extra[key] = try await nvram(key, force: true, c)
                }
            }
        }
        try await handleSysDep(c)
        // Not handled natively: a router not set up yet (set_cfg_pause, setUpTimeZone and the default Wi-Fi), and DSL.
        if sys.isDefault { browser(.factoryDefault); return }
        if dsl || isSupport("dsl") { browser(.dsl); return }
        // PolicyStatus (asus_policy.js 816–835) decides first (QIS_wizard.htm 250–253).
        let status = try await c.privacyPolicyStatus()
        if status.values["ASUS_NEW_EULA"] == "0" || status.values["ASUS_NEW_EULA_time"] == "" { try await goToEULA(c); return }
        if status.asksPrivacyAfterEULA { try await goToPP(c); return }
        switch flag {
        case "sitesurvey_rep": browser(.repeater)
        case "lanip": try await goToAPMode(c)
        case "sitesurvey_mb": browser(.mediaBridge)
        case "manual": try await goToOpMode(c)
        case "pppoe": try await goToPPPoE(c)
        case "wireless", "mlo": try await goToWireless(c)
        case "amasrole_page": browser(.aimesh("amasrole_page"))
        case "amasnode_page": browser(.aimesh("amasnode_page"))
        case "amas_addNode": browser(.aimesh("amassearch_page"))
        case "site2site": browser(.siteToSite)
        case "changePass": try await goToLogin(c)
        case "EULA": try await goToEULA(c)
        case "PP": try await goToPP(c)
        case "rtMode": sys.advSetting = true; try await goToRTMode(c)
        case "wispMode": sys.advSetting = true; browser(.wisp)
        default: goToWelcome()
        }
    }

    /// handleSysDep (plugins.js 1309–1450): the WAN detection behind `.amasNoWAN`, and when check_pw asks for a new password
    /// it is asked at the end unless the router is BUSINESS or sdn_mwl.
    mutating func handleSysDep(_ c: RouterClient) async throws {
        sys.initNoWAN = try await detwanGetRet(c).type == "NOWAN"
        _ = try await nvram("amas_bdl", c)
        if sys.forceChangePw {
            sys.forceChangePw = false; sys.forceChangePwInTheEnd = true
            if isSupport("BUSINESS") || isSupport("sdn_mwl") { sys.forceChangePw = true; sys.forceChangePwInTheEnd = false }
        }
    }
}

// MARK: - Events

extension QISWizard {
    /// Typing in an input of the current page: its value, and what its keyup does (the password length hint on the login
    /// page). Its change handler runs before the next button.
    public mutating func edit(_ field: QISFieldID, _ value: String) {
        form.values[field] = value
        form.changePending = true
        if page == .login, field == .password { checkPasswordLength() }
    }
    /// The `change` handlers of the page's inputs, as the blur before a click runs them.
    mutating func flushChange(_ c: RouterClient) async throws {
        guard form.changePending else { return }
        form.changePending = false
        switch page {
        case .account, .dhcpOption: try await pppInputChanged(c)
        case .staticIP:
            if form.staticBound { try await insert(QISObject.wanStatic, c); try await insert(QISObject.wanGeneral(sys.ethWanIf), c); post.set("wan_proto", "static") }
        case .wireless: for band in allWlArray { try await insert(QISObject.wireless(band.unit), c) }
        default: break
        }
    }

    mutating func handle(_ event: QISEvent, _ c: RouterClient) async throws {
        alerts = []
        switch event {
        case .edit(let field, let value): edit(field, value)
        case .editWireless(let unit, let ssid, let value): editWireless(unit, ssid: ssid, value)
        default: break
        }
        try await flushChange(c)
        switch page {
        case .eula:
            switch event {
            case .toggle("eulaAge", let on): form.eulaAge = on
            case .next:
                // handleClickApplyBtn (asus_policy.js 2512–2521).
                guard form.eulaAge else { alerts.append(QISText.ageConfirm); return }
                send(.get("set_ASUS_NEW_EULA.cgi", [("ASUS_NEW_EULA", "1")], json: true), ignoresAnswer: false)
                then = .privacy
            default: break
            }
        case .privacy(let status):
            // asus_policy.js has the statement only as HTMLv2 and HTMLv4 (22, 47). For any other version the `.replace` on
            // `HTMLv${ppVersion}` (920) throws inside `new PolicyScrollDiv` (2574), after the buttons were made (2559–2572)
            // but before the page is shown: there is nothing to agree to or refuse, so no event sends anything.
            guard status.privacyDocument != nil else { return }
            switch event {
            case .next:
                // 2497–2511: privateEula.set, and in its callback the security update, the automatic upgrade and Welcome.
                send(.get("set_ASUS_privacy_policy.cgi", [("ASUS_privacy_policy", "1")], json: true), ignoresAnswer: false)
                send(.get("set_security_update.cgi", [("security_update", "1")], json: false), ignoresAnswer: true)
                if status.values["ASUS_PP_AutoWebUpgradeDisable"] != "1" {
                    send(.apply([("webs_update_enable", .number("1")), ("action_mode", .string("apply")), ("rc_service", .string("saveNvram")),
                                 ("skip_modify_flag", .string("1"))]), ignoresAnswer: true)
                }
                then = .welcome
            case .choose("disagree"): form.withdrawing = true
            case .choose("readAgain"): form.withdrawing = false
            case .choose("knowRisk"):
                // handleClickKnowRisk (1551–1559): privateEula.set("0"), then knowRiskCallback = goTo.Welcome.
                send(.get("set_ASUS_privacy_policy.cgi", [("ASUS_privacy_policy", "0")], json: true), ignoresAnswer: false)
                then = .welcome
            default: break
            }
        case .welcome:
            switch event {
            case .choose("create"): try await applyWelcome(c)
            case .choose("advanced"): try await goToAdvSetting(c)
            case .choose("rt"):
                // apply.welcome_rt (76–84).
                if sys.forceChangePw { sys.welcomeRT = true; try await goToLogin(c) } else { try await goToRTMode(c) }
            case .choose("wisp"):
                if sys.forceChangePw { sys.welcomeWISP = true; try await goToLogin(c) } else { browser(.wisp) }
            default: break
            }
        case .advancedSetting:
            switch event {
            case .choose("asNode"): browser(.aimesh("amasnode_page"))
            case .choose("opMode"):
                // apply.changeOpMode (131–134).
                try await insert(QISObject.opMode, c); try await goToOpMode(c)
            case .choose("upload"): browser(.upload)
            case .back:
                // abort.advSetting (1856–1864).
                if sys.forceChangePw { loadPage(.login, reverse: true) } else { sys.advSetting = false; loadPage(.welcome, reverse: true) }
            default: break
            }
        case .login:
            switch event {
            case .toggle("defpass", let on): try await setDefaultPassword(on, c)
            case .next: try await applyLogin(c)
            case .back: try await abortLogin(c)
            default: break
            }
        case .opMode:
            switch event {
            case .choose("rt"): try await goToRTMode(c)
            case .choose("rp"): browser(.repeater)
            case .choose("ap"): try await goToAPMode(c)
            case .choose("mb"): browser(.mediaBridge)
            case .choose("amas"): browser(.aimesh("amasintro_page"))
            case .choose("wisp"): browser(.wisp)
            case .back:
                // abort.opMode (1922–1934).
                if flag == "manual" { exit = .back }
                else if !sys.advSetting { post.remove(QISObject.opMode); loadPage(.noWan, reverse: true) }
                else { post.remove(QISObject.opMode); loadPage(.advancedSetting, reverse: true) }
            default: break
            }
        case .waiting, .resetModem, .noWan:
            switch event {
            case .tick: try await pollTick(c)
            case .choose("manual"):
                // noWan_page's 手动设置 is bound only by goTo.NoWan (5056–5057).
                if page != .noWan || sys.noWanManualBound { try await applyManual(c) }
            case .back where page == .resetModem: try await abortResetModem(c)
            case .back where page == .noWan:
                // abort.nowan (2142–2149).
                if sys.forceChangePw { loadPage(.login, reverse: true) } else if isSupport("amas_bdl") { browser(.aimesh("prelink_desc")) } else { backToStartQIS() }
            default: break
            }
        case .specialISP:
            switch event {
            case .choose("yes"): form.iptv = true; browser(.iptv)
            case .choose("no"): form.iptv = false; try await goToWireless(c)
            case .back: loadPreviousPage()
            default: break
            }
        case .wanSetting:
            switch event {
            case .choose("dhcp"): try await goToDHCP(c)
            case .choose("pppoe"): try await goToPPPoE(c)
            case .choose("static"): try await goToStatic(c)
            case .choose("pptp"), .choose("l2tp"):
                // goTo.PPTP / goTo.L2TP (3648–3668).
                try await insert(QISObject.wanGeneral(sys.ethWanIf), c)
                let proto = event == .choose("pptp") ? "pptp" : "l2tp"
                post.set("wan_proto", proto)
                if sys.manualWanSetup { sys.manualWanType = proto.uppercased() }
                try await goToVPN(c)
            case .choose(let id) where id.hasPrefix("ipv6:"): browser(.japanIPv6)
            case .choose("asNode"): browser(.aimesh("amasnode_page"))
            case .toggle("iptv", let on) where isSupport("IPTV") && !form.iptvOnAccount: form.iptv = on
            case .toggle("dhcpOption", let on): form.dhcpOption = on
            case .back: try await abortWAN(c)
            default: break
            }
        case .wanOption:
            switch event {
            case .choose(let id): try await chooseWANPort(id, c)
            case .back: try await abortWAN(c)
            default: break
            }
        case .account:
            switch event {
            // #iptv_checkbox while goTo.PPPoE has moved it here (handler.js 3411–3420).
            case .toggle("iptv", let on) where isSupport("IPTV") && form.iptvOnAccount: form.iptv = on
            case .next: try await applyPPPoE(c)
            case .back:
                // abort.pppoe (2200–2220).
                post.remove(QISObject.wanAll)
                form.vpnServer = false
                if flag == "pppoe" { exit = .back }
                else if sys.detwanType == "PPPoE" { if !sys.forceChangePw { backToStartQIS() } else { loadPage(.login, reverse: true) } }
                else if sys.detwanType == "PPPDHCP" { loadPreviousPage() }
                else { loadPage(.wanSetting, reverse: true) }
            default: break
            }
        case .getIP:
            switch event {
            case .choose("dhcp"):
                // goTo.vpnDHCP (3719–3723).
                post.remove(QISObject.wanStatic); try await insert(QISObject.wanDHCP, c); try await applyDHCP(c)
            case .choose("static"): try await goToVPNStatic(c)
            case .back: loadPage(.account, reverse: true)
            default: break
            }
        case .staticIP:
            switch event {
            case .next: try await applyStatic(c)
            case .back:
                // abort.static (2226–2235).
                if post.has("wan_heartbeat_x") { post.remove(QISObject.wanStatic); loadPage(.getIP, reverse: true) }
                else { post.remove(QISObject.wanAll); loadPage(.wanSetting, reverse: true) }
            default: break
            }
        case .dhcpOption:
            switch event {
            case .toggle("clientIDType", let on):
                // showDiableDHCPclientID (plugins.js 772–783).
                form.clientIDType = on; form.values[.clientID] = ""
            case .next: try await applyDHCPOption(c)
            case .back:
                // abort.wan_dhcp_option (2256–2265).
                post.remove(QISObject.wanDHCPOption)
                if form.iptv { browser(.iptv) } else { loadPage(.wanSetting, reverse: true) }
            default: break
            }
        case .getLanIP:
            switch event {
            case .choose("dhcp"): try await goToLanDHCP(c)
            case .choose("static"): try await insert(QISObject.lanStatic, c); loadPage(.lanStatic)
            case .back:
                // abort.getLanIp (2267–2292).
                post.remove(QISObject.lanGeneral); post.remove(QISObject.lanStatic)
                if flag == "lanip" { exit = .back }
                else if isOriginSwMode("AP") {
                    if !sys.forceChangePw { backToStartQIS() } else { loadPage(.login, reverse: true) }
                } else { loadPage(.opMode, reverse: true) }
            default: break
            }
        case .lanStatic:
            switch event {
            case .next: try await applyLanStatic(c)
            case .back: post.remove(QISObject.lanStatic); loadPage(.getLanIP, reverse: true)
            default: break
            }
        case .wireless:
            switch event {
            case .toggle("separate", let on): form.separate = on; try await wirelessCheckboxChanged(on, c)
            case .next: try await applyWireless(c)
            case .back: try await abortWireless(c)
            default: break
            }
        case .iot:
            switch event {
            case .toggle("later", let on): try await iotLaterChanged(on)
            case .next: try await applyIoT(c)
            case .back: if sys.forceChangePwInTheEnd { loadPage(.login, reverse: true) } else { loadPage(.wireless, reverse: true) }
            default: break
            }
        case .update:
            if event == .next {
                // abort.update (2475–2478): the next button is the old cancel button (Merlin, goTo.Update 4533–4546).
                sys.isNewFw = .number("0")
                let restart = try await setRestartService(onPost: false, c)
                send(.apply(restart.sent), ignoresAnswer: false)
                then = .finish
            }
        case .summary, .browser: break
        }
    }

    mutating func send(_ request: QISRequest, ignoresAnswer: Bool) { outbox.append(QISOutgoing(request: request, ignoresAnswer: ignoresAnswer)) }
}

// MARK: - Policy, Welcome, login

extension QISWizard {
    /// goTo.EULA (handler.js 5485–5505): PolicyStatus again; the privacy page when the EULA is already agreed.
    mutating func goToEULA(_ c: RouterClient) async throws {
        let status = try await c.privacyPolicyStatus()
        if status.values["ASUS_NEW_EULA"] == "1" { try await goToPP(c); return }
        page = .eula(status)
        form.eulaAge = false
    }
    /// goTo.PP (5508–5524).
    mutating func goToPP(_ c: RouterClient) async throws {
        page = .privacy(try await c.privacyPolicyStatus())
        form.withdrawing = false
    }

    /// goTo.Welcome (2787–2843): the detection the page starts (start_force_autodet, and restart_auto46det for Japan with
    /// IPv6), and a second later the firmware check, as side effects to confirm.
    mutating func goToWelcome() {
        // The withdrawal popup closes once its callback ran (handleClickKnowRisk 1551–1559).
        form.withdrawing = false
        loadPage(.welcome, reverse: true)
        history = ["welcome"]
        if isOriginSwMode("RT"), !sys.isDefault {
            if isSupport("s46"), isSku("JP"), sys.ipv6Service != "disabled" { effects.append(.auto46Detect) }
            effects.append(.autoDetect)
        }
        effects.append(.liveUpdate)
    }
    /// Whether the welcome page shows the WISP pair (the inline script 438–447 adds is_not_default; which buttons that class
    /// hides is in qis.css, not in the materials).
    public var welcomeOffersWISP: Bool { isSupport("wisp") && !sys.isDefault }

    /// apply.welcome (19–64).
    mutating func applyWelcome(_ c: RouterClient) async throws {
        sys.manualWanSetup = false; sys.advSetting = false
        if isSupport("amas_bdl") { browser(.aimesh("prelink_desc")); return }
        if sys.forceChangePw { try await goToLogin(c); return }
        if isOriginSwMode("RP") { browser(.repeater) }
        else if isOriginSwMode("AP") { if isSupport("apMode_detwan") { browser(.apDetectWAN) } else { try await goToAPMode(c) } }
        else if isOriginSwMode("MB") { browser(.mediaBridge) }
        else if isOriginSwMode("Mesh") { browser(.aimesh("amasrole_page")) }
        else if isOriginSwMode("WISP") { browser(.wisp) }
        else { try await goToAutoWAN(c) }
    }
    /// goTo.advSetting (2845–2855).
    mutating func goToAdvSetting(_ c: RouterClient) async throws {
        sys.advSetting = true
        if !sys.forceChangePw { loadPage(.advancedSetting) } else { try await goToLogin(c) }
    }
    /// abort.backToStartQIS (1844–1854) without a mesh role.
    mutating func backToStartQIS() {
        sys.advSetting = false; sys.welcomeWISP = false; sys.welcomeRT = false
        loadPage(.welcome, reverse: true)
    }

    /// goTo.Login (2857–2954).
    mutating func goToLogin(_ c: RouterClient) async throws {
        try await insert(QISObject.user, c)
        if isSupport("defpass") { try await setDefaultPassword(true, c) }
        loadPage(.login)
    }
    /// #defpass_checkbox change (2858–2895).
    mutating func setDefaultPassword(_ on: Bool, _ c: RouterClient) async throws {
        form.defaultPassword = on
        if on {
            form.values[.username] = try await nvramDefaultGet(["http_username"], c)["http_username"] ?? ""
            form.values[.password] = "**************"
            form.values[.passwordConfirm] = ""
            hints[.username] = nil; hints[.password] = nil; hints[.passwordConfirm] = nil
        } else {
            form.values[.password] = ""
        }
    }
    /// Whether the policy text on the login page shows (2936–2938).
    public var showsStrictLoginPolicy: Bool { isSku("KR") || isSku("SG") || isSku("AA") || isSupport("secure_default") }

    /// apply.login (136–292).
    mutating func applyLogin(_ c: RouterClient) async throws {
        let useDefault = form.defaultPassword
        let user = form.value(.username), password = form.value(.password), confirmation = form.value(.passwordConfirm)
        func valid() throws -> Bool {
            if hasBlank([.username]) { return false }
            if !useDefault, hasBlank([.password, .passwordConfirm]) { return false }
            if let reason = QISCheck.hostName(user) { hints[.username] = reason; return false }
            if ["root", "guest", "anonymous"].contains(user) { hints[.username] = QISText.reservedAccount; return false }
            if user == password { hints[.username] = QISText.samePassword; return false }
            guard !useDefault else { return true }
            let strict = showsStrictLoginPolicy
            if strict {
                if let reason = QISCheck.krPassword(password) { hints[.password] = reason; return false }
                if password == user { hints[.password] = QISText.loginPolicy; return false }
            }
            if password != confirmation { hints[.password] = QISText.passwordsMatch; return false }
            if password == sys.defaultHTTPPasswd { hints[.password] = QISText.defaultPassword; return false }
            if password.utf16.count < 5 { hints[.password] = QISText.shortPassword + " " + QISText.passwordLength; return false }
            if password.utf16.count > 32 { hints[.password] = strict ? javaScriptReplace(QISText.maxPassword, "5", "10") : QISText.maxPassword; return false }
            if let reason = QISCheck.invalidChar(password) { hints[.password] = reason; return false }
            if QISCheck.isWeak(password, "httpd_password"), try !confirm("weak-http", QISText.commonPassword) {
                hints[.password] = QISText.usePasswordHarder; return false
            }
            return true
        }
        guard try valid() else { return }
        post.set("http_username", user)
        if !useDefault { post.set("http_passwd", password); post.set("defpass_enable", "0") }
        else { post.set("http_passwd", ""); post.set("defpass_enable", "1") }
        if sys.forceChangePwInTheEnd {
            if isSupport("mainfhSetup"), try await createSDNCompatibleNetwork(c) { try await goToIoT(c) }
            else { try await submitQIS(c) }
            return
        }
        if sys.advSetting { loadPage(.advancedSetting) }
        else if sys.welcomeWISP { browser(.wisp) }
        else if sys.welcomeRT { try await goToRTMode(c) }
        else if post.has("sw_mode") { try await goToOpMode(c) }
        else if isOriginSwMode("RP") { browser(.repeater) }
        else if isOriginSwMode("AP") { if isSupport("apMode_detwan") { browser(.apDetectWAN) } else { try await goToAPMode(c) } }
        else if isOriginSwMode("MB") { browser(.mediaBridge) }
        else if isOriginSwMode("Mesh") { browser(.aimesh("amasrole_page")) }
        else { try await goToAutoWAN(c) }
    }
    /// abort.login (1877–1916).
    mutating func abortLogin(_ c: RouterClient) async throws {
        post.remove(QISObject.user)
        if isSupport("11AX"), !isSupport("qis_hide_he_features") { loadPage(.browser(.axMode), reverse: true); return }
        if sys.forceChangePwInTheEnd {
            loadPage(.wireless, reverse: true)
        } else if post.has("sw_mode") {
            post.remove(QISObject.opMode)
            if sys.welcomeRT { backToStartQIS() } else { loadPage(.advancedSetting, reverse: true) }
        } else if isSupport("amas_bdl"), !sys.advSetting {
            browser(.aimesh("prelink_desc"))
        } else {
            backToStartQIS()
        }
    }
}

// MARK: - Operation mode and WAN

extension QISWizard {
    /// goTo.opMode (3195–3198).
    mutating func goToOpMode(_ c: RouterClient) async throws {
        try await insert(QISObject.opMode, c)
        loadPage(.opMode)
    }
    /// goTo.rtMode (3200–3229).
    mutating func goToRTMode(_ c: RouterClient) async throws {
        post.set("sw_mode", .number("1")); post.set("wlc_psta", .number("0")); post.set("wlc_dpsta", .number("0")); post.set("wlc_band", "")
        post.set("mlo_rp", .number("0")); post.set("mlo_mb", .number("0"))
        sys.opMode = "RT"
        if isSupport("amas") { try await insert(QISObject.aimesh, c); post.set("cfg_master", "1") }
        if sys.advSetting, isSwModeChanged() {
            try await insert(QISObject.lanGeneral, c); try await insert(QISObject.lanStatic, c)
            post.set("lan_proto", "static"); post.set("lan_dnsenable_x", "1")
            let rt = try await nvramDefaultGet(["lan_ipaddr_rt", "lan_netmask_rt"], c)
            post.set("lan_ipaddr", rt["lan_ipaddr_rt"] ?? ""); post.set("lan_netmask", rt["lan_netmask_rt"] ?? "")
            post.set("lan_gateway", rt["lan_ipaddr_rt"] ?? ""); post.set("lan_dns1_x", ""); post.set("lan_dns2_x", "")
        }
        form.wireless = nil
        try await applyManual(c)
    }
    /// goTo.apMode (3277–3292).
    mutating func goToAPMode(_ c: RouterClient) async throws {
        post.set("sw_mode", .number("3")); post.set("wlc_psta", .number("0")); post.set("wlc_dpsta", .number("0"))
        post.set("mlo_rp", .number("0")); post.set("mlo_mb", .number("0"))
        sys.opMode = "AP"
        if isSupport("amas") { try await insert(QISObject.aimesh, c); post.set("cfg_master", "1") }
        form.wireless = nil
        try await insert(QISObject.lanGeneral, c)
        loadPage(.getLanIP)
    }
    /// goTo.autoWan (2969–3078).
    mutating func goToAutoWAN(_ c: RouterClient, skipAuto46: Bool = false) async throws {
        sys.opMode = "RT"
        post.remove(QISObject.wanAll)
        if isSupport("amas") { try await insert(QISObject.aimesh, c); post.set("cfg_master", "1") }
        if !skipAuto46, isSupport("s46"), isSku("JP"), sys.ipv6Service != "disabled" { browser(.japanIPv6); return }
        let result = try await detwanGetRet(c)
        sys.detwanType = result.type; sys.ipConflict = result.conflict
        try await routeDetection(result.type, c)
    }
    mutating func routeDetection(_ type: String, _ c: RouterClient) async throws {
        switch type {
        case "DHCP", "CHECKING", "": try await goToWaiting(c)
        case "DHCPSPECIALISP": loadPage(.specialISP)
        case "PPPoE": try await goToPPPoE(c)
        case "STATIC": try await goToStatic(c)
        case "NOWAN": if isSupport("gobi") { browser(.mobileBroadband) } else { goToNoWan() }
        case "MODEM": browser(.usbModem)
        case "RESETMODEM": try await goToResetModem(c)
        case "CONNECTED": try await goToWireless(c)
        default: try await applyManual(c)
        }
    }
    /// apply.manual (294–324).
    mutating func applyManual(_ c: RouterClient) async throws {
        if isSupport("dsl") { try await goToWireless(c); return }
        if isSupport("apMode_detwan"), isOriginSwMode("AP") { sys.manualWanSetup = true; browser(.apDetectWAN); return }
        sys.manualWanSetup = true
        if isSupport("IPTV") {
            // The IPTV box goes back to the WAN type page (305–313), ticked when the router has an ISP profile.
            form.iptvOnAccount = false
            if try await nvram("switch_wantag", c) != "none" { form.iptv = true }
        }
        if isSupport("2p5G_LWAN") || isSupport("10G_LWAN") || isSupport("10GS_LWAN") || ethWanCount > 1 || isSupport("usb_bk") {
            try await goToWANOption(c)
        } else if isSupport("nowan") {
            browser(.usbModem)
        } else {
            sys.manualWanSetup = true
            loadPage(.wanSetting)
        }
    }
    /// goTo.WANOption (5526–5594): the static rows, or the router's own list when it has more than one Ethernet WAN.
    mutating func goToWANOption(_ c: RouterClient) async throws {
        sys.modemPlugged = try await hadPlugged("modem", c)
        loadPage(.wanOption)
    }
    /// The rows of the WAN port page in order: (id, title).
    public var wanPortChoices: [(id: String, title: String)] {
        var rows: [(id: String, title: String)] = []
        if ethWanCount > 1 {
            rows = sys.ethWanList.members.map { (id: "eth:" + $0.0, title: $0.1["wan_name"].map(TORSettings.javaScriptString) ?? "undefined") }
        } else {
            rows.append((id: "WAN1G", title: "WAN 接口"))
            if isSupport("2p5G_LWAN") { rows.append((id: "WAN2p5G", title: "2.5G 以太网")) }
            if isSupport("10G_LWAN") { rows.append((id: "WAN10G", title: "10G 以太网")) }
            if isSupport("10GS_LWAN") { rows.append((id: "WAN10GS", title: "10G SFP+")) }
            if sys.modemPlugged, !isSupport("usb_bk") { rows.append((id: "WANModem", title: "USB Modem")) }
        }
        if isSupport("usb_bk") { rows.append((id: "usb_bk", title: "4G / 5G 自动移动网络共享")) }
        return rows
    }
    mutating func chooseWANPort(_ id: String, _ c: RouterClient) async throws {
        if id.hasPrefix("eth:") {
            // The rows the hook gives (5536–5560).
            let key = String(id.dropFirst(4))
            guard let wan = sys.ethWanList[key] else { return }
            sys.wanOption = true
            for (name, value) in wan["extra_settings"]?.members ?? [] { post.set(name, value) }
            if isSupport("autowan") { post.set("autowan_enable", "0") }
            sys.manualWanSetup = true; loadPage(.wanSetting)
            return
        }
        switch id {
        case "WAN1G":
            // apply.WAN1G (1515–1528).
            sys.wanOption = true
            if isSupport("2p5G_LWAN") { try await insert(QISObject.lwan2p5G, c); post.set("wans_extwan", "0") }
            if isSupport("10G_LWAN") || isSupport("10GS_LWAN") { try await insert(QISObject.dualWan, c); post.set("wans_dualwan", "wan none") }
        case "WAN2p5G":
            sys.wanOption = true; try await insert(QISObject.lwan2p5G, c); post.set("wans_extwan", "1")
        case "WAN10G":
            sys.wanOption = true; try await insert(QISObject.dualWan, c); post.set("wans_dualwan", "wan2 none")
        case "WAN10GS":
            sys.wanOption = true; try await insert(QISObject.dualWan, c); post.set("wans_dualwan", "sfp+ none")
        case "WANModem":
            sys.wanOption = true
            if isSupport("2p5G_LWAN") { try await insert(QISObject.lwan2p5G, c); post.set("wans_extwan", "0") }
            browser(.usbModem); return
        case "usb_bk":
            sys.wanOption = true; browser(.phoneAsWAN); return
        default: return
        }
        if isSupport("autowan") { post.set("autowan_enable", "0") }
        sys.manualWanSetup = true; loadPage(.wanSetting)
    }
    /// The AutoWAN hint under the WAN port rows (5582–5590).
    public var showsAutoWANHint: Bool { isSupport("autowan") }

    /// abort.wan (1973–2140).
    mutating func abortWAN(_ c: RouterClient) async throws {
        post.remove(QISObject.wanAll)
        sys.manualWanType = nil
        if sys.advSetting, isSwModeChanged(), isSwMode("RT") { post.remove(QISObject.lanGeneral); post.remove(QISObject.lanStatic) }
        if isSupport("autowan") { post.remove("autowan_enable") }
        if sys.wanOption {
            sys.wanOption = false
            if isSupport("2p5G_LWAN") { post.remove(QISObject.lwan2p5G) }
            if isSupport("10G_LWAN") || isSupport("10GS_LWAN") { post.remove(QISObject.dualWan) }
            if ethWanCount > 1 {
                for (_, wan) in sys.ethWanList.members { for (key, _) in wan["extra_settings"]?.members ?? [] { post.remove(key) } }
            }
            loadPage(.wanOption, reverse: true)
        } else if isSwMode("WISP") {
            browser(.wisp)
        } else if post.has("sw_mode") {
            if !sys.advSetting, isSupport("wisp") {
                sys.advSetting = false
                if sys.forceChangePw { loadPage(.login, reverse: true) } else { sys.welcomeRT = false; loadPage(.welcome, reverse: true) }
            } else {
                loadPage(.opMode, reverse: true)
            }
        } else if sys.detwanType == "NOWAN" {
            sys.manualWanSetup = false
            loadPage(.noWan, reverse: true)
            poll = QISPoll(kind: .noWanAfterBack)
        } else if sys.detwanType == "RESETMODEM" {
            loadPage(.resetModem, reverse: true)
            poll = QISPoll(kind: .resetModem)
        } else if sys.detwanType == "CHECKING" {
            sys.manualWanSetup = false
            loadPage(.waiting, reverse: true)
            try await goToWaiting(c)
        } else if !sys.forceChangePw {
            backToStartQIS()
        } else {
            loadPage(.login, reverse: true)
        }
    }

    /// goTo.Waiting (5220–5285).
    mutating func goToWaiting(_ c: RouterClient) async throws {
        sys.manualWanSetup = false
        let interval = try await nvram("wandog_interval", force: true, c)
        let wandog = interval == "" ? 5 : javaScriptParseInt(interval)
        if page != .waiting { loadPage(.waiting) }
        poll = QISPoll(kind: .waiting, errCount: 0, linkCount: 0, wandogInterval: wandog)
    }
    /// goTo.NoWan (4913–5116) on an Ethernet router.
    mutating func goToNoWan() {
        sys.manualWanSetup = false
        sys.noWanManualBound = true
        loadPage(.noWan)
        poll = QISPoll(kind: .noWan)
    }
    /// goTo.ResetModem (5148–5187): only US, CA and U2 show it.
    mutating func goToResetModem(_ c: RouterClient) async throws {
        if !isSku("US"), !isSku("CA"), !isSku("U2") { try await applyManual(c); return }
        loadPage(.resetModem)
        poll = QISPoll(kind: .resetModem)
    }
    /// abort.resetModem (1936–1967): 重新侦测.
    mutating func abortResetModem(_ c: RouterClient) async throws {
        if sys.detwanType == "RESETMODEM" { effects.append(.autoDetect) }
        sys.manualWanSetup = false
        loadPage(.waiting, reverse: true)
        poll = QISPoll(kind: .retry)
    }

    /// One run of the polling page's timer. Each web timer schedules its next run only on the branches that call
    /// `setTimeout(arguments.callee, …)` again; every other branch ends it, which is `poll.kind = .none` here (set before
    /// moving on, since the next page may start a timer of its own). Leaving the page ends it too (loadPage), as the
    /// `isPage` checks do.
    mutating func pollTick(_ c: RouterClient) async throws {
        poll.ticks += 1
        switch poll.kind {
        case .none: return
        case .retry:
            // abort.resetModem's own timer (1947–1963): more than 10 reads is apply.manual; "" or CHECKING reads again;
            // anything else ends the timer, with goTo.autoWan unless manualWanSetup.
            if poll.errCount > 10 { poll.kind = .none; try await applyManual(c); return }
            if sys.detwanType == "" || sys.detwanType == "CHECKING" {
                poll.errCount += 1
                let result = try await detwanGetRet(c); sys.detwanType = result.type; sys.ipConflict = result.conflict
                return
            }
            poll.kind = .none
            if !sys.manualWanSetup { try await goToAutoWAN(c) }
        case .waiting:
            // goTo.Waiting's timer (5229–5280): only "" / CHECKING (5262) and DHCP (5268) read again.
            if sys.manualWanSetup { poll.kind = .none; return }
            if Double(poll.errCount) > poll.wandogInterval * 4 {
                poll.kind = .none
                if isSupport("nowan") { browser(.usbModem) }
                else if isSku("US") || isSku("CA") || isSku("U2") { try await goToResetModem(c) }
                else { try await applyManual(c) }
                return
            }
            if Double(poll.linkCount) > poll.wandogInterval { poll.kind = .none; try await applyManual(c); return }
            let result = try await detwanGetRet(c); sys.detwanType = result.type; sys.ipConflict = result.conflict
            if result.type == "" || result.type == "CHECKING" { poll.errCount += 1; return }
            if result.type == "DHCP" { poll.errCount = 0; poll.linkCount += 1; return }
            poll.kind = .none
            try await goToAutoWAN(c, skipAuto46: isSku("JP") && sys.ipv6Service != "disabled")
        case .noWan:
            // goTo.NoWan's timer (5083–5110): read; 手动设置 chosen ends it (5085); a state it knows moves on and ends it;
            // anything else reads again a second later (5107).
            let result = try await detwanGetRet(c); sys.detwanType = result.type; sys.ipConflict = result.conflict
            if sys.manualWanSetup { poll.kind = .none; return }
            guard ["CONNECTED", "DHCP", "PPPoE", "STATIC", "MODEM", "RESETMODEM"].contains(result.type) else { return }
            poll.kind = .none
            switch result.type {
            case "CONNECTED": try await goToWireless(c)
            case "DHCP": try await goToWaiting(c)
            case "PPPoE": try await goToPPPoE(c)
            case "STATIC": try await goToStatic(c)
            case "MODEM": browser(.usbModem)
            default: try await goToResetModem(c)
            }
        case .noWanAfterBack:
            // abort.wan's NOWAN timer (2063–2089): a state it knows ends the timer, moving on only with manualWanSetup
            // (which abort.wan has just cleared); only the default branch reads again a second later (2086).
            let result = try await detwanGetRet(c); sys.detwanType = result.type; sys.ipConflict = result.conflict
            guard ["CONNECTED", "DHCP", "PPPoE", "STATIC", "RESETMODEM", "CHECKING"].contains(result.type) else { return }
            poll.kind = .none
            guard sys.manualWanSetup else { return }
            switch result.type {
            case "CONNECTED": try await goToWireless(c)
            case "DHCP": try await goToDHCP(c)
            case "PPPoE": try await goToPPPoE(c)
            case "STATIC": try await goToStatic(c)
            case "RESETMODEM": try await goToResetModem(c)
            default: try await goToWaiting(c)
            }
        case .resetModem:
            // abort.wan's RESETMODEM timer (2094–2125) and goTo.ResetModem's (5154–5184): every 1.5 s while on the page.
            let result = try await detwanGetRet(c); sys.detwanType = result.type; sys.ipConflict = result.conflict
            _ = try await nvram("odmpid", c)
            if !["", "CHECKING", "RESETMODEM"].contains(result.type) { try await goToAutoWAN(c) }
        }
    }
    /// Seconds to the next run of the page's timer: the delay before the first run, then between runs.
    public var pollInterval: Double? {
        switch poll.kind {
        case .none: nil
        case .waiting, .noWan: 1                            // 5280; 5110 and 5107
        case .retry: poll.ticks == 0 ? 2 : 1                // 1963, then 1958
        case .noWanAfterBack: poll.ticks == 0 ? 0.5 : 1     // 2089, then 2086
        case .resetModem: 1.5                               // 2125 and 2124; 5184 and 5183
        }
    }

    /// goTo.DHCP (3353–3374).
    mutating func goToDHCP(_ c: RouterClient) async throws {
        if sys.originWanType.lowercased() != "dhcp" {
            post.remove(QISObject.wanAll)
            try await insert(QISObject.wanGeneral(sys.ethWanIf), c)
            try await insert(QISObject.wanDHCP, c)
            post.set("wan_proto", "dhcp")
        }
        if sys.manualWanSetup { sys.manualWanType = "DHCP" }
        try await applyDHCP(c)
    }
    /// apply.dhcp (326–366).
    mutating func applyDHCP(_ c: RouterClient) async throws {
        if form.iptv { browser(.iptv) }
        else if form.dhcpOption { try await insert(QISObject.wanDHCPOption, c); loadPage(.dhcpOption) }
        else if isSupport("gobi") { browser(.mobileBroadband) }
        else if try await hadPlugged("modem", c) { browser(.usbModem) }
        else {
            if isWANChanged() { restartWAN(dnsmasq: false) }
            try await goToWireless(c)
        }
    }
    /// The WAN restart the pages send before Wireless (apply.dhcp 352–361, apply.pppoe 409–421, apply.static 474–483,
    /// apply.wan_dhcp_option 726–735): qisPostData itself with action_mode and rc_service, which stay in it.
    mutating func restartWAN(dnsmasq: Bool) {
        post.set("action_mode", "apply")
        post.set("rc_service", "restart_wan_if \(sys.ethWanIf)" + (dnsmasq && !post.has("ipv6_service") ? ";restart_dnsmasq" : ""))
        send(.apply(post.sent), ignoresAnswer: true)
        sys.restartWanIf = true
        updateOriginWan()
    }

    /// goTo.PPPoE (3376–3517). The ISP suffix list (ajax/pppIspList_V2.json and ASUS's copy) only feeds the user name's
    /// suggestions and is not read.
    mutating func goToPPPoE(_ c: RouterClient) async throws {
        post.remove(QISObject.wanAll)
        try await insert(QISObject.wanGeneral(sys.ethWanIf), c)
        try await insert(QISObject.wanPPPoE, c)
        post.set("wan_proto", "pppoe")
        if isSupport("ENABLE_IPv6") { post.set("ipv6_service", "dhcp6") }
        if sys.manualWanSetup { sys.manualWanType = "PPPoE" }
        if isSupport("IPTV"), !sys.manualWanSetup {
            // The IPTV box moves to this page (3411–3420), ticked when the router has an ISP profile (never unticked here);
            // apply.pppoe hands over to goTo.IPTV while it is ticked, before the WAN restart (385–386).
            form.iptvOnAccount = true
            if try await nvram("switch_wantag", c) != "none" { form.iptv = true }
        }
        let info = try await nvramGetWanByUnit(["wan_pppoe_username", "wan_pppoe_passwd"], c)
        form.values[.pppoeUsername] = info["wan_pppoe_username"] ?? ""
        form.values[.pppoePassword] = info["wan_pppoe_passwd"] ?? ""
        form.pppInputBinding = .pppoe
        loadPage(.account)
    }
    /// goTo.VPN (3670–3713).
    mutating func goToVPN(_ c: RouterClient) async throws {
        try await insert(QISObject.wanPPPoE, c)
        try await insert(QISObject.wanVPN, c)
        form.vpnServer = true
        let info = try await nvramGetWanByUnit(["wan_pppoe_username", "wan_pppoe_passwd", "wan_heartbeat_x"], c)
        form.values[.pppoeUsername] = info["wan_pppoe_username"] ?? ""
        form.values[.pppoePassword] = info["wan_pppoe_passwd"] ?? ""
        form.values[.vpnServer] = info["wan_heartbeat_x"] ?? ""
        form.pppInputBinding = .vpn
        loadPage(.account)
    }
    /// The `.pppInput` change handler that was bound last.
    mutating func pppInputChanged(_ c: RouterClient) async throws {
        switch form.pppInputBinding {
        case .none: break
        case .pppoe:
            try await insert(QISObject.wanGeneral(sys.ethWanIf), c); try await insert(QISObject.wanPPPoE, c); post.set("wan_proto", "pppoe")
        case .vpn:
            try await insert(QISObject.wanPPPoE, c); try await insert(QISObject.wanVPN, c)
        }
    }
    /// apply.pppoe (368–425).
    mutating func applyPPPoE(_ c: RouterClient) async throws {
        let proto = post.text("wan_proto")
        if proto == "l2tp" || proto == "pptp" {
            if hasBlank([.pppoeUsername, .pppoePassword, .vpnServer]) { return }
            post.set("wan_pppoe_username", form.value(.pppoeUsername))
            post.set("wan_pppoe_passwd", form.value(.pppoePassword))
            post.set("wan_heartbeat_x", form.value(.vpnServer))
            loadPage(.getIP)
            return
        }
        if post.has("wan_pppoe_username") {
            if hasBlank([.pppoeUsername, .pppoePassword]) { return }
            post.set("wan_pppoe_username", form.value(.pppoeUsername))
            post.set("wan_pppoe_passwd", form.value(.pppoePassword))
        }
        if form.iptv { browser(.iptv) }
        else if isSupport("gobi") { browser(.mobileBroadband) }
        else if try await hadPlugged("modem", c) { browser(.usbModem) }
        else {
            if isWANChanged() || sys.pppAuthFailChecked { restartWAN(dnsmasq: true) }
            try await goToWireless(c)
        }
    }

    /// goTo.Static (3519–3582).
    mutating func goToStatic(_ c: RouterClient) async throws {
        if sys.originWanType.lowercased() != "static" {
            post.remove(QISObject.wanAll)
            try await insert(QISObject.wanStatic, c)
            try await insert(QISObject.wanGeneral(sys.ethWanIf), c)
            post.set("wan_proto", "static")
        }
        if sys.manualWanSetup { sys.manualWanType = "STATIC" }
        try await prefillStatic(c)
        form.staticBound = true
        loadPage(.staticIP)
    }
    /// goTo.vpnStatic (3725–3771).
    mutating func goToVPNStatic(_ c: RouterClient) async throws {
        try await prefillStatic(c)
        post.remove(QISObject.wanDHCP)
        try await insert(QISObject.wanStatic, c)
        loadPage(.staticIP)
    }
    mutating func prefillStatic(_ c: RouterClient) async throws {
        let info = try await nvramGetWanByUnit(["wan_ipaddr_x", "wan_netmask_x", "wan_gateway_x", "wan_dns1_x", "wan_dns2_x"], c)
        let fields: [(QISFieldID, String)] = [(.staticIP, "wan_ipaddr_x"), (.staticMask, "wan_netmask_x"), (.staticGateway, "wan_gateway_x"),
                                               (.staticDNS1, "wan_dns1_x"), (.staticDNS2, "wan_dns2_x")]
        // `.replace("0.0.0.0", "")`: the first occurrence only.
        for (field, key) in fields { form.values[field] = javaScriptReplace(info[key] ?? "", "0.0.0.0", "") }
    }
    /// apply.static (427–486).
    mutating func applyStatic(_ c: RouterClient) async throws {
        if post.has("wan_ipaddr_x") {
            if hasBlank([.staticIP, .staticMask, .staticGateway, .staticDNS1]) { return }
            if form.value(.staticIP) == form.value(.staticGateway) {
                hints[.staticIP] = QISText.wanIPIsGateway.replacingOccurrences(of: "ZVMODELVZ", with: sys.productid); return
            }
            post.set("wan_dhcpenable_x", "0")
            post.set("wan_ipaddr_x", form.value(.staticIP))
            post.set("wan_netmask_x", form.value(.staticMask))
            post.set("wan_gateway_x", form.value(.staticGateway))
            post.set("wan_dnsenable_x", "0")
            post.set("wan_dns1_x", form.value(.staticDNS1))
            post.set("wan_dns2_x", form.value(.staticDNS2))
        }
        if form.iptv { browser(.iptv) }
        else if isSupport("gobi") { browser(.mobileBroadband) }
        else if try await hadPlugged("modem", c) { browser(.usbModem) }
        else {
            if isWANChanged() { restartWAN(dnsmasq: false) }
            try await goToWireless(c)
        }
    }
    /// apply.wan_dhcp_option (701–740).
    mutating func applyDHCPOption(_ c: RouterClient) async throws {
        post.set("wan_proto", "dhcp")
        post.set("wan_vendorid", form.value(.vendorID))
        post.set("wan_clientid_type", .number(form.clientIDType ? "1" : "0"))
        post.set("wan_clientid", form.value(.clientID))
        if isSupport("gobi") { browser(.mobileBroadband) }
        else if try await hadPlugged("modem", c) { browser(.usbModem) }
        else {
            if isWANChanged() { restartWAN(dnsmasq: false) }
            try await goToWireless(c)
        }
    }

    /// goTo.lanDHCP (3910–3943) outside Media Bridge.
    mutating func goToLanDHCP(_ c: RouterClient) async throws {
        post.set("lan_proto", "dhcp"); post.set("lan_dnsenable_x", "1")
        try await goToWireless(c)
    }
    /// apply.lanStatic (925–972) outside Media Bridge.
    mutating func applyLanStatic(_ c: RouterClient) async throws {
        if post.has("lan_proto") {
            if hasBlank([.lanIP, .lanMask, .lanGateway, .lanDNS1]) { return }
            post.set("lan_proto", "static")
            post.set("lan_ipaddr", form.value(.lanIP))
            post.set("lan_netmask", form.value(.lanMask))
            post.set("lan_gateway", form.value(.lanGateway))
            post.set("lan_dnsenable_x", "0")
            post.set("lan_dns1_x", form.value(.lanDNS1))
            post.set("lan_dns2_x", form.value(.lanDNS2))
        }
        try await goToWireless(c)
    }
}
