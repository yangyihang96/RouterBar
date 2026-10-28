import Foundation

// Amazon Alexa（Advanced_Smart_Home_Alexa.asp）（1.12）：按 Asuswrt-Merlin tag 3006.102.5 的页面源码显示连接状态、
// 地区网站、取得激活码与启用远程控制。取得激活码与启用远程控制会写入路由器，由界面先请用户确认。

/// What the Amazon Alexa page shows.
public struct AlexaPage: Sendable, Equatable {
    /// acc_link_status (show_account_state 407–445). 服务器连接失败 never shows: AAE_SIP is always true.
    public enum Status: Sendable, Equatable {
        case noInternet, account, enableRemoteControl, registered
        public var text: String {
            switch self {
            case .noInternet: "与互联网中断连接。请检查您的 WAN 连接以进行远程控制。"
            case .account: "遵循下列步骤配对您的帐号"
            case .enableRemoteControl: "请点击 这里 以启用 DDNS 和「从互联网设置 %@」，从而实现远程访问控制路由器"
            case .registered: "您的 Amazon Alexa 帐号已被注册。"
            }
        }
    }

    /// The Amazon sites of create_AmazonRegion_select (133–144, 183–207).
    public struct Region: Sendable, Hashable, Identifiable {
        public let name: String
        public let site: URL
        public var id: String { name }
    }
    public static let regions: [Region] = [
        ("澳大利亚＆新西兰", "https://www.amazon.com.au/ASUS-ROUTER/dp/B07285G1RK"), ("加拿大", "https://www.amazon.ca/ASUS-ROUTER/dp/B07285G1RK"),
        ("法国", "https://www.amazon.fr/ASUS-ROUTER/dp/B07285G1RK"), ("德国和奥地利", "https://www.amazon.de/ASUS-ROUTER/dp/B07285G1RK"),
        ("印度", "https://www.amazon.in/ASUS-ROUTER/dp/B07285G1RK"), ("意大利", "https://www.amazon.it/ASUS-ROUTER/dp/B07285G1RK"),
        ("日本", "https://www.amazon.co.jp/ASUS-ROUTER/dp/B07285G1RK"), ("西班牙", "https://www.amazon.es/ASUS-ROUTER/dp/B07285G1RK"),
        ("美国", "https://www.amazon.com/ASUS-ROUTER/dp/B07285G1RK"), ("英国和爱尔兰", "https://www.amazon.co.uk/ASUS-ROUTER/dp/B07285G1RK")
    ].map { Region(name: $0.0, site: URL(string: $0.1)!) }

    /// ddns_*, misc_http_x, link_internet, oauth_auth_status, fw_lw_enable_x, territory_code, productid and the DDNS
    /// result variables state.js keeps (ddns_return_code_chk, ddns_updated).
    public let values: [String: String]
    public let support: [String: String]
    /// `nvram_match_x("","ifttt_token","","1")`: "1" while no account is linked, "" otherwise or when the request fails.
    public let tokenEmpty: String
    /// external_ip after get_real_ip.asp: 1 when the WAN address is public, 0 when not, -1 when unknown.
    public let externalIP: Int
    /// update_acc_link_status (397–405) reads the remote access variables again every five seconds; check_ddns_status
    /// keeps the values state.js was loaded with, so only link_internet and misc_http_x change the status.
    public let live: [String: String]
    static let liveKeys = ["ddns_enable_x", "ddns_hostname_x", "ddns_server_x", "misc_http_x", "link_internet"]

    static let keys = ["ddns_enable_x", "ddns_hostname_x", "ddns_server_x", "misc_http_x", "link_internet", "oauth_auth_status",
                       "fw_lw_enable_x", "territory_code", "productid", "ddns_return_code_chk", "ddns_updated", "preferred_lang"]

    public init(values: [String: String], support: [String: String], tokenEmpty: String, externalIP: Int, live: [String: String]? = nil) {
        self.values = values; self.support = support; self.tokenEmpty = tokenEmpty; self.externalIP = externalIP
        self.live = live ?? values.filter { Self.liveKeys.contains($0.key) }
    }
    /// The page after a five-second update, or after get_real_ip.asp answered again.
    public func refreshed(live: [String: String]? = nil, tokenEmpty: String? = nil, externalIP: Int? = nil) -> AlexaPage {
        AlexaPage(values: values, support: support, tokenEmpty: tokenEmpty ?? self.tokenEmpty, externalIP: externalIP ?? self.externalIP, live: live ?? self.live)
    }

    /// 更多技巧 (httpApi.faqURL "1033393", httpApi.js 955–999): the FAQ on the ASUS site of the router's language, which the
    /// page switches to once the site answers; for a language it does not list, the international site.
    public var faqURL: URL {
        let sites = ["EN": "", "TW": "/tw", "CN": ".cn", "BR": "/br", "CZ": "/cz", "DA": "/dk", "DE": "/de", "ES": "/es", "FI": "/fi",
                     "FR": "/fr", "HU": "/hu", "IT": "/it", "JP": "/jp", "KR": "/kr", "MS": "/my", "NL": "/nl", "NO": "/no", "PL": "/pl",
                     "RO": "/ro", "RU": "/ru", "SL": "/sk", "SV": "/se", "TH": "/th", "TR": "/tr", "UK": "/ua"]
        return URL(string: "https://www.asus.com" + (sites[values["preferred_lang"] ?? ""] ?? "") + "/support/FAQ/1033393")!
    }
    /// The model the dictionary names in place of ZVMODELVZ (replaced when the firmware is built).
    public var model: String { values["productid"] ?? "" }
    /// Without IFTTT the page is titled Amazon Alexa Skill and has no IFTTT tab (151–156).
    public var title: String { isSupported("ifttt") ? "Alexa & IFTTT - Amazon Alexa Skill" : "Amazon Alexa Skill" }
    public var showsIFTTTTab: Bool { isSupported("ifttt") }
    /// The English warning shown when the network service filter is on (157–158).
    public var showsFilterWarning: Bool { values["fw_lw_enable_x"] == "1" }
    /// guideline_2 (two steps in the ASUS Router app) for oauth_auth_status "2", guideline_1 otherwise (176–179).
    public var appGuideline: Bool { values["oauth_auth_status"] == "2" }
    /// Step 4 of guideline_1 (Lyra Voice) for amazon_avs (168–170).
    public var showsVoiceStep: Bool { isSupported("amazon_avs") }
    /// The region selected first: 美国, or 澳大利亚＆新西兰 on OP models (`ttc.search("OP")`, state.js 304–314).
    public var defaultRegion: Region { (values["territory_code"] ?? "").contains("OP") ? Self.regions[0] : Self.regions[8] }

    func isSupported(_ key: String) -> Bool { !["", "0"].contains(support[key] ?? "") }

    /// check_ddns_status (state.js 4604–4621) with the values the page was loaded with.
    var ddnsWorks: Bool {
        guard values["ddns_enable_x"] == "1", values["ddns_hostname_x"] != "" else { return false }
        let code = values["ddns_return_code_chk"] ?? ""
        if values["ddns_server_x"] == "WWW.ASUS.COM" { return ["200", "220", "230"].contains { code.contains($0) } }
        return !(values["ddns_updated"] != "1" || code == "unknown_error" || code == "auth_fail")
    }

    public var status: Status {
        let linked = tokenEmpty != "1"
        guard live["link_internet"] == "2" else { return .noInternet }
        if externalIP == 1 {
            let remote = ddnsWorks && live["misc_http_x"] != "0"
            return remote ? (linked ? .registered : .account) : .enableRemoteControl
        }
        return linked ? .registered : .account
    }
}

/// get_real_ip.asp: after `<% get_realip(); %>` (getrealip.sh when link_internet is "2", web.c 37896–37909) the script
/// compares the address found for the active WAN with its own.
public enum RealIPCheck {
    /// (realip_state, external_ip) as the script leaves them; external_ip stays -1 unless the active unit is 0 or 1 and its
    /// state is "2".
    static func evaluate(_ script: String) -> (state: String, external: Int) {
        func value(_ name: String) -> String { RouterParser.capture("var " + name + #" = "([^"]*)";"#, in: script) ?? "" }
        let unit = value("active_wan_unit")
        guard unit == "0" || unit == "1" else { return ("", -1) }
        let state = value("wan\(unit)_realip_state")
        guard state == "2" else { return (state, -1) }
        return (state, value("wan\(unit)_realip_ip") == value("wan\(unit)_ipaddr") ? 1 : 0)
    }
}

extension RouterClient {
    /// Reads the page as it opens; get_real_ip (231–249), which the page starts a second later, is the caller's
    /// (alexaRealIP), so its count and the live connection state stay with the open page.
    public func alexaPage() async throws -> AlexaPage {
        let values = try await readSettings(AlexaPage.keys)
        let support = try await uiCapabilities()
        let token = try await tokenMatch()
        return AlexaPage(values: values, support: support, tokenEmpty: token, externalIP: -1)
    }

    /// update_acc_link_status: the remote access variables and the token match again (only reads).
    public func alexaLiveStatus(_ page: AlexaPage) async throws -> AlexaPage {
        page.refreshed(live: try await readSettings(AlexaPage.liveKeys), tokenEmpty: try await tokenMatch())
    }

    /// One get_real_ip.asp (which runs getrealip.sh on the router while it is connected): external_ip and whether the
    /// router has its answer (realip_state "2").
    public func alexaRealIP() async throws -> (external: Int, answered: Bool) { try await realIP() }

    /// get_real_ip.asp for both pages: it runs getrealip.sh on the router, so it goes through the write checks (the
    /// 3.0.0.6 pages that ask for it, one request at a time) and counts as a change for an answer that is lost.
    func realIP() async throws -> (external: Int, answered: Bool) {
        try acquireMutation(); defer { releaseMutation() }
        let result = RealIPCheck.evaluate(try await managementDocument("get_real_ip.asp", changes: true))
        return (result.external, result.state == "2")
    }

    /// httpApi.nvram_match_x: whether ifttt_token is empty, without reading the token.
    func tokenMatch() async throws -> String {
        do {
            let data = try await request("appGet.cgi", query: [.init(name: "hook", value: #"nvram_match_x("","ifttt_token","","1")"#)])
            return try OrderedJSON(data: data)["nvram_match_x-"]?.text ?? ""
        } catch RouterError.authenticationRequired { throw RouterError.authenticationRequired }
        catch is CancellationError { throw CancellationError() }
        catch { return "" }
    }

    /// get_IFTTTPincode.cgi (web.c 22378–22389): a new activation code, which the page shows for 120 seconds.
    public func alexaActivationCode() async throws -> String {
        try acquireMutation(); defer { releaseMutation() }
        let data = try await request("get_IFTTTPincode.cgi", changes: true)
        guard let code = try? OrderedJSON(data: data)["ifttt_pincode"]?.text else {
            throw RouterError.submissionUncertain("路由器没有返回可识别的激活码。请稍后再取得一次。")
        }
        return code
    }

    /// enable_remote_control.cgi (web.c 22675–22720): turns on DDNS (asuscomm.com when no host name is set) and web access
    /// from the internet, then restarts DDNS and the web server. Waits the page's five seconds and reads the page again.
    public func enableAlexaRemoteControl() async throws -> AlexaPage {
        try acquireMutation()
        do { _ = try await request("enable_remote_control.cgi", changes: true) }
        catch { releaseMutation(); throw error }
        releaseMutation()
        try await Task.sleep(for: .seconds(5))
        return try await alexaPage()
    }
}
