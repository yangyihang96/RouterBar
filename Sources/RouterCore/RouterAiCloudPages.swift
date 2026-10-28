import Foundation

// MARK: - AiCloud 2.0

/// AiCloud 2.0 (cloud_main.asp) on firmware with AiCloud built in (cloudsync_support), where initial() shows the
/// installed area at once (64–68): the access address, the private address note, and the 云端硬盘 and 智能访问
/// switches. The IPK install, switch and remove flow is for routers without cloudsync and is not modelled.
public struct AiCloudPage: Sendable, Equatable {
    static let keys = ["start_aicloud", "webdav_aidisk", "webdav_proxy", "enable_webdav", "enable_cloudsync", "ddns_enable_x",
                       "ddns_hostname_x", "webdav_https_port", "lan_ipaddr", "sw_mode", "wans_mode", "territory_code",
                       "preferred_lang", "firmver"]
    public let values: [String: String]
    /// wanlink_ipaddr(): the address of the WAN unit wanlink() reports (web.c 6524–6668).
    public let wanIP: String
    public let support: [String: String]

    public init(values: [String: String], wanIP: String, support: [String: String]) {
        self.values = values; self.wanIP = wanIP; self.support = support
    }

    func supports(_ name: String) -> Bool { !["", "0"].contains(support[name] ?? "") }
    public var builtIn: Bool { supports("cloudsync") }
    /// `start_aicloud == '0'` sends the browser to cloud__main.asp (24–25), a page this firmware does not have.
    public var redirects: Bool { values["start_aicloud"] == "0" }
    /// is_CN (state.js 306–310): the territory code names CN, CT, GD or TC.
    public var isCN: Bool { ["CN", "CT", "GD", "TC"].contains { (values["territory_code"] ?? "").contains($0) } }
    public var androidApp: URL {
        URL(string: isCN ? "https://m.wandoujia.com/apps/1091409" : "https://play.google.com/store/apps/details?id=com.asustek.aicloud")!
    }
    public static let iosApp = URL(string: "https://itunes.apple.com/us/app/aicloud-lite/id527118674")!
    public static let faq = URL(string: "https://www.asus.com/search/results.aspx?SearchKey=AiCloud&SearchType=FAQ&IsSupport=True&Page=1")!
    /// <#Web_DOMAIN_NAME#>: ZVDOMAIN_NAMEVZ, which httpd replaces with DUT_DOMAIN_NAME (ej.c 141, shared.h 394–397).
    static let domain = "www.asusrouter.com"

    /// The 访问方式 line (initial 70–129) and whether initial() runs past it.
    public enum Access: Sendable, Equatable {
        /// A private WAN address: plain text, the router's name in router mode (cellspot.router with tmo) or lan_ipaddr.
        case local(String)
        /// A public address with DDNS on and a host name: the DDNS address, then the 这里 link to change the name.
        case ddns(String)
        /// A public address without DDNS. With the HTTPS port not 443 the page then writes into a cloud_url element that
        /// is only in a comment and throws: the registration hint, the private address check and the removal of the
        /// 智能同步 row are skipped.
        case asusDomain(String, stopped: Bool)
    }
    public var access: Access {
        let port = values["webdav_https_port"] ?? ""
        // `https_port != 443`: the text compared as a number.
        let suffix = javaScriptNumber(port) == 443 ? "" : ":" + port
        if Self.validIsWanIP(wanIP) == 0 {
            let host = values["sw_mode"] == "1" ? (supports("tmo") ? "cellspot.router" : Self.domain) : values["lan_ipaddr"] ?? ""
            return .local("https://" + host + suffix)
        }
        if values["ddns_enable_x"] == "1", let host = values["ddns_hostname_x"], !host.isEmpty {
            return .ddns("https://" + host + suffix)
        }
        return .asusDomain("https://" + Self.domain, stopped: !suffix.isEmpty)
    }
    /// initial() throws before the private address check: at the cloud_url line, or at rrsLink (an element this page
    /// does not have) without rrsut.
    public var scriptStops: Bool {
        if case .asusDomain(_, stopped: true) = access { return true }
        return !supports("rrsut")
    }
    /// `isSupport("wifi7")` removes the 智能同步 row at the end of initial().
    public var showsSmartSync: Bool { scriptStops || !supports("wifi7") }
    /// show_warning_message (172–199) tries get_real_ip.asp first with realip and without load balancing.
    public var checksRealIP: Bool { !scriptStops && supports("realip") && values["wans_mode"] != "lb" }

    /// The note after the checks: realip_state "2" with external_ip 0, or else (and without realip) a private WAN address
    /// as validator.isPrivateIP sees it.
    public func showsPrivateNote(realIP: (external: Int, answered: Bool)?) -> Bool {
        guard !scriptStops else { return false }
        if checksRealIP, let realIP, realIP.answered { return realIP.external == 0 }
        return WebValidator.isPrivateIP(wanIP)
    }

    /// valid_is_wan_ip (213–232): 0 strictly inside the three private ranges or for 0.0.0.0, otherwise (an invalid text
    /// included) 1.
    static func validIsWanIP(_ text: String) -> Int {
        let number = WebValidator.inetNetwork(text)
        let ranges: [(String, String)] = [("10.0.0.0", "10.255.255.255"), ("172.16.0.0", "172.31.255.255"), ("192.168.0.0", "192.168.255.255")]
        if ranges.contains(where: { number > WebValidator.inetNetwork($0.0) && number < WebValidator.inetNetwork($0.1) }) || number == 0 { return 0 }
        return 1
    }

    public var cloudDiskOn: Bool { values["webdav_aidisk"] == "1" }
    public var smartAccessOn: Bool { values["webdav_proxy"] == "1" }

    public enum Switch: Sendable { case cloudDisk, smartAccess }
    /// The switch callbacks (793–857): 云端硬盘 takes its direction from curState (webdav_aidisk), 智能访问 from its own
    /// state; turning one off turns enable_webdav off only when the other one's form value is `== 0`.
    public func fields(toggling target: Switch) -> [(String, String)] {
        var aidisk = values["webdav_aidisk"] ?? "", proxy = values["webdav_proxy"] ?? "", webdav = values["enable_webdav"] ?? ""
        switch target {
        case .cloudDisk:
            if aidisk == "1" { aidisk = "0"; if javaScriptNumber(proxy) == 0 { webdav = "0" } }
            else { aidisk = "1"; webdav = "1" }
        case .smartAccess:
            if proxy == "1" { proxy = "0"; if javaScriptNumber(aidisk) == 0 { webdav = "0" } }
            else { proxy = "1"; webdav = "1" }
        }
        return [("preferred_lang", values["preferred_lang"] ?? ""), ("firmver", values["firmver"] ?? ""),
                ("current_page", "cloud_main.asp"), ("next_page", "cloud_main.asp"), ("action_mode", "apply"),
                ("action_script", "restart_webdav"), ("action_wait", "3"), ("enable_cloudsync", values["enable_cloudsync"] ?? ""),
                ("enable_webdav", webdav), ("webdav_aidisk", aidisk), ("webdav_proxy", proxy)]
    }
}

// MARK: - AiCloud 2.0 › 设置

/// AiCloud 2.0 设置 (cloud_settings.asp): the password protection, the account lock and the two ports.
public struct AiCloudSettings: Sendable, Equatable {
    static let keys = ["webdav_acc_lock", "enable_webdav_lock", "webdav_lock_times", "webdav_lock_interval", "webdav_https_port",
                       "webdav_http_port", "http_username", "login_port", "dm_http_port", "misc_httpsport_x", "misc_httpport_x",
                       "preferred_lang", "firmver"]
    public let values: [String: String]
    public let support: [String: String]

    public init(values: [String: String], support: [String: String]) { self.values = values; self.support = support }

    func supports(_ name: String) -> Bool { !["", "0"].contains(support[name] ?? "") }
    /// `webdav_acc_lock == 1`: the blocked account icon and 解锁.
    public var locked: Bool { javaScriptNumber(values["webdav_acc_lock"]) == 1 }
    /// action_script: restart_webdav, which initial() changes to restart_setting_webdav with aicloudipk, unless it threw
    /// before at rrsLink (not on this page) without rrsut (38–43).
    public var service: String { supports("rrsut") && supports("aicloudipk") ? "restart_setting_webdav" : "restart_webdav" }

    /// The form as the page holds it: the switch's enable_webdav_lock, whether the two lock fields are enabled (initial
    /// disables them for "0", the switch sets both), and the four text fields as typed.
    public struct Draft: Sendable, Equatable {
        public var lockEnabled: String
        public var lockFieldsEnabled: Bool
        public var lockTimes: String
        public var lockInterval: String
        public var httpsPort: String
        public var httpPort: String
        public init(lockEnabled: String, lockFieldsEnabled: Bool, lockTimes: String, lockInterval: String, httpsPort: String, httpPort: String) {
            self.lockEnabled = lockEnabled; self.lockFieldsEnabled = lockFieldsEnabled; self.lockTimes = lockTimes
            self.lockInterval = lockInterval; self.httpsPort = httpsPort; self.httpPort = httpPort
        }
        /// The iphoneSwitch shows on only for "1"; a click sets the value and both fields.
        public var switchOn: Bool { lockEnabled == "1" }
        public mutating func setSwitch(_ on: Bool) { lockEnabled = on ? "1" : "0"; lockFieldsEnabled = on }
    }
    public var draft: Draft {
        Draft(lockEnabled: values["enable_webdav_lock"] ?? "", lockFieldsEnabled: values["enable_webdav_lock"] != "0",
              lockTimes: values["webdav_lock_times"] ?? "", lockInterval: values["webdav_lock_interval"] ?? "",
              httpsPort: values["webdav_https_port"] ?? "", httpPort: values["webdav_http_port"] ?? "")
    }

    /// applyRule (45–58): the four ranges (disabled fields included), each port against the router's other ports, and the
    /// two ports apart; then both ports go through parseInt. Returns the form to send, or the alert (nil for the silent
    /// stop when the ports are the same).
    public func applying(_ draft: Draft) -> Result<[(String, String)], ApplyStop> {
        var edited = draft
        if let alert = WebValidator.numberRange(&edited.lockTimes, 1, 10) ?? WebValidator.numberRange(&edited.lockInterval, 1, 60)
            ?? WebValidator.numberRange(&edited.httpPort, 1, 65535) ?? WebValidator.numberRange(&edited.httpsPort, 1, 65535)
            ?? conflict(edited.httpPort) ?? conflict(edited.httpsPort) { return .failure(.alert(alert)) }
        guard edited.httpPort != edited.httpsPort else { return .failure(.samePorts) }
        edited.httpPort = javaScriptText(SiteSurvey.parseInt(.string(edited.httpPort)) ?? .nan)
        edited.httpsPort = javaScriptText(SiteSurvey.parseInt(.string(edited.httpsPort)) ?? .nan)
        return .success(fields(edited, accountLock: values["webdav_acc_lock"] ?? ""))
    }
    public enum ApplyStop: Error, Equatable {
        case alert(String)
        /// The last condition only stops the submit; the page shows nothing.
        case samePorts
    }

    /// isPortConflict_webdav (60–85): the field text against login_port, dm_http_port, misc_httpsport_x and
    /// misc_httpport_x, as text.
    func conflict(_ port: String) -> String? {
        let hint = "此端口用于: "
        if port == values["login_port"] ?? "" { return hint + "HTTP LAN port." }
        if port == values["dm_http_port"] ?? "" { return hint + "下载大师." }
        if port == values["misc_httpsport_x"] ?? "" { return hint + "[互联网设置通信端口(HTTPS)]." }
        if port == values["misc_httpport_x"] ?? "" { return hint + "[互联网设置通信端口(HTTP)]." }
        return nil
    }

    /// unlockAcc (87–91): webdav_acc_lock 0 and the form as it is, without applyRule's checks.
    public func unlocking(_ draft: Draft) -> [(String, String)] { fields(draft, accountLock: "0") }

    /// The form `form` (98–107, 166–206) in document order; the lock fields only while enabled.
    func fields(_ draft: Draft, accountLock: String) -> [(String, String)] {
        var fields = [("preferred_lang", values["preferred_lang"] ?? ""), ("firmver", values["firmver"] ?? ""),
                      ("current_page", "cloud_settings.asp"), ("next_page", "cloud_settings.asp"), ("action_mode", "apply"),
                      ("action_script", service), ("action_wait", "3"), ("enable_webdav_lock", draft.lockEnabled),
                      ("webdav_acc_lock", accountLock)]
        if draft.lockFieldsEnabled { fields += [("webdav_lock_times", draft.lockTimes), ("webdav_lock_interval", draft.lockInterval)] }
        return fields + [("webdav_https_port", draft.httpsPort), ("webdav_http_port", draft.httpPort)]
    }
}

extension RouterClient {
    public func aiCloudPage() async throws -> AiCloudPage {
        let values = try await readSettings(AiCloudPage.keys)
        let wan = try OrderedJSON(data: try await request("appGet.cgi", query: [.init(name: "hook", value: "wanlink(ipaddr)")]))["wanlink-ipaddr"]
        return AiCloudPage(values: values, wanIP: wan?.text ?? "", support: try await uiCapabilities())
    }

    /// get_real_ip (201–213): get_real_ip.asp, which runs getrealip.sh on the router while it is connected; the state the
    /// script leaves and external_ip.
    public func realIPCheck() async throws -> (external: Int, answered: Bool) { try await realIP() }

    public func aiCloudSettings() async throws -> AiCloudSettings {
        AiCloudSettings(values: try await readSettings(AiCloudSettings.keys), support: try await uiCapabilities())
    }

    /// The page's form to start_apply.htm (both pages post `form` there with action_wait 3); after the wait the changed
    /// variables are read back.
    public func submitAiCloudForm(_ fields: [(String, String)], verifying keys: [String]) async throws -> ApplyReceipt {
        try acquireMutation(); defer { releaseMutation() }
        _ = try await request("start_apply.htm", method: "POST", body: RouterAuthentication.orderedForm(fields, .formSubmission),
                              contentType: "application/x-www-form-urlencoded", timeout: 60)
        let sent = Dictionary(fields, uniquingKeysWith: { _, last in last })
        do {
            try await Task.sleep(for: .seconds(3))
            let after = try await readSettings(keys)
            let verified = keys.filter { after[$0] == sent[$0] }, unverified = keys.filter { after[$0] != sent[$0] }
            return ApplyReceipt(verified: verified, unverified: unverified,
                                message: unverified.isEmpty ? "已从路由器重新读取，设置已保存。" : "路由器已响应，但部分设置与提交值不一致。请重新读取并检查。")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ApplyReceipt(verified: [], unverified: keys, message: "路由器已接收请求，正在重新加载 AiCloud。保存结果仍待重新读取确认。")
        }
    }
}

extension RouterClient {
    /// get_faq_index (form.js 153–176) on the list updatFAQListOnline reads from /ajax/collected_FAQ.json (131–150): the FAQ
    /// number of a page's help link (the last entry for the page wins), nil when the router does not list it.
    public func faqNumber(page: String, index: Int = 1) async throws -> String? {
        let data: Data
        do { data = try await request("ajax/collected_FAQ.json", timeout: 30) }
        catch RouterError.authenticationRequired { throw RouterError.authenticationRequired }
        catch is CancellationError { throw CancellationError() }
        catch { return nil }
        guard let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              let entry = entries.last(where: { $0["Page"] as? String == page }) else { return nil }
        let key = index == 1 ? "FAQ_Link" : "FAQ_Link\(index)"
        return (entry[key] as? String) ?? (entry[key] as? NSNumber)?.stringValue
    }
}
