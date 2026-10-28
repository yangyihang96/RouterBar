import Foundation

// 1.12：网易UU加速器（UUAccelerator.asp）、网络打印机服务器（PrinterServer.asp）与 系统管理 › 政策（Advanced_Privacy.asp），
// 按 Asuswrt-Merlin tag 3006.102.5 的页面源码。政策页的同意与撤销和网页一样写入路由器，由界面先请用户确认。

// MARK: - JavaScript comparisons

/// How the pages compare the values they read.
enum JavaScriptCompare {
    /// The abstract relational comparison (`x < y`, `x > y`): both sides first become primitives (an object
    /// "[object Object]", an array its joined text); two texts compare by UTF-16 code units, anything else as numbers
    /// (a missing value NaN, null 0, booleans 0 or 1). nil when a number is NaN, for which every comparison is false.
    static func relational(_ x: OrderedJSON?, _ y: OrderedJSON?) -> ComparisonResult? {
        func primitive(_ value: OrderedJSON?) -> OrderedJSON? {
            switch value {
            case .object?, .array?: value.map { .string(TORSettings.javaScriptString($0)) }
            default: value
            }
        }
        let px = primitive(x), py = primitive(y)
        if case .string(let a)? = px, case .string(let b)? = py {
            if a == b { return .orderedSame }
            return a.utf16.lexicographicallyPrecedes(b.utf16) ? .orderedAscending : .orderedDescending
        }
        let a = javaScriptToNumber(px), b = javaScriptToNumber(py)
        guard !a.isNaN, !b.isNaN else { return nil }
        return a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    }
    static func order(_ value: OrderedJSON?, _ text: String) -> ComparisonResult? { relational(value, .string(text)) }
    static func atLeast(_ value: OrderedJSON?, _ text: String) -> Bool { [.orderedDescending, .orderedSame].contains(order(value, text)) }
    static func below(_ value: OrderedJSON?, _ text: String) -> Bool { order(value, text) == .orderedAscending }
    /// `value == 0`: text and arrays by their numeric value, booleans as 0 or 1; null, a missing value and objects never.
    static func looselyZero(_ value: OrderedJSON?) -> Bool {
        switch value {
        case .string(let text)?: javaScriptNumber(text) == 0
        case .number(let text)?: javaScriptNumber(text) == 0
        case .bool(let on)?: !on
        case .array(let elements)?: javaScriptNumber(TORSettings.javaScriptString(.array(elements))) == 0
        default: false
        }
    }
    /// `${value}` in a template literal; undefined for a missing value.
    static func text(_ value: OrderedJSON?) -> String { value.map(TORSettings.javaScriptString) ?? "undefined" }
}

// MARK: - Links

/// The ASUS support redirector the pages link with the router's language (state.js 979: ui_lang = preferred_lang).
public enum AsusSupportLink {
    public static func faq(_ number: String, lang: String) -> URL? { forward("model=&type=Faq&lang=\(lang)&kw=&num=\(number)") }
    /// The ASUS privacy policy (asus_policy.js 1071–1073, 1388, Advanced_Privacy.asp 68–72 with kw tm_ppp / tm_ka).
    public static func policy(lang: String, kw: String = "") -> URL? { forward("model=&type=Policy&lang=\(lang)&kw=\(kw)&num=") }
    /// The Trend Micro EULA the TM window links (asus_policy.js 1100).
    public static func trendMicroEULA(lang: String) -> URL? { forward("model=&type=TMeula&lang=\(lang)&kw=&num=") }
    /// A policy window's link target: "policy", "tmeula" or an address ("personal" opens a window instead).
    public static func target(_ url: String, lang: String) -> URL? {
        switch url {
        case "policy": policy(lang: lang)
        case "tmeula": trendMicroEULA(lang: lang)
        case "personal": nil
        default: URL(string: url)
        }
    }
    /// The pages join the language in as it is; a browser escapes what a URL cannot hold, as this does.
    static func forward(_ query: String) -> URL? {
        URL(string: "https://nw-dlcdnet.asus.com/support/forward.html?" + (query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query))
    }
}

// MARK: - 网易UU加速器

/// 网易UU加速器 (UUAccelerator.asp): 前往设置 opens UU's router page for this router's label MAC (uuRegister 25–28).
public struct UUAccelerator: Sendable, Equatable {
    /// `var label_mac = <% get_label_mac(); %>;` (web.c 38447–38451 writes it quoted); nil when it is not text.
    public let labelMAC: String?
    public init(labelMAC: String?) { self.labelMAC = labelMAC }
    /// window.open('https://router.uu.163.com/asus/pc.html#/acce?gwSn=' + mac.toLowerCase() + '&type=asuswrt').
    public var registerURL: URL? {
        guard let labelMAC else { return nil }
        let address = "https://router.uu.163.com/asus/pc.html#/acce?gwSn=" + labelMAC.lowercased() + "&type=asuswrt"
        return URL(string: address) ?? URL(string: address.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? "")
    }
    public static let faq = URL(string: "https://uu.163.com/router/")!
}

// MARK: - Policy texts

/// A document of the policy windows (js/asus_policy.js), as script/generate_policy_texts.py composed it from CN.dict.
public struct PolicyDocument: Sendable, Equatable {
    public let title: String
    public let blocks: [PolicyBlock]
}

public struct PolicyBlock: Sendable, Equatable, Decodable {
    public enum Kind: String, Sendable, Decodable { case title, text, item, end }
    public struct Link: Sendable, Equatable, Decodable {
        public let title: String
        /// An address, "policy" (the ASUS privacy policy in the router's language) or "personal" (the personal data window).
        public let url: String
    }
    public let kind: Kind
    public let html: String
    /// The list number CSS draws, e.g. "1.", "(2)" or "1.1.2"; empty for a paragraph inside an item.
    public let marker: String
    public let depth: Int
    public let bold: Bool
    public let links: [Link]
    /// What the window shows for the block.
    public var text: String { HTMLText.visible(html, inside: [kind == .item ? "li" : "div"]) }
}

public enum PolicyTexts {
    private struct File: Decodable {
        let titles: [String: String]
        let documents: [String: [PolicyBlock]]
    }
    private static let file: File? = {
        guard let url = Bundle.module.url(forResource: "PolicyTexts", withExtension: "json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(File.self, from: data)
    }()
    private static func document(_ key: String, title: String) -> PolicyDocument? {
        guard let file, let blocks = file.documents[key] else { return nil }
        return PolicyDocument(title: file.titles[title] ?? "", blocks: blocks)
    }
    /// Content.PP[`HTMLv${ppVersion}`]: only versions 2 and 4 exist; for another the window throws and stays empty.
    public static func privacy(version: String) -> PolicyDocument? { document("PP" + version, title: "PP") }
    /// Content.PP[`PersonalDataHTMLv${ppVersion}`], titled Content.PP.PersonalData.
    public static func personalData(version: String) -> PolicyDocument? { document("personal" + version, title: "personal") }
    public static var eula: PolicyDocument? { document("EULA", title: "EULA") }
    /// Content.TM, titled 趋势科技（中国）有限公司最终用户许可协议.
    public static var trendMicro: PolicyDocument? { document("TM", title: "TM") }
}

/// The notice 提示 a third-party feature links (ThirdPartyPolicyModalComponent, asus_policy.js 329–389, 1110–1124).
public struct ThirdPartyPolicy: Sendable, Equatable {
    public let party: String
    public let linkTitle: String
    public let url: URL
    public let company: String

    public static let speedtest = ThirdPartyPolicy(party: "Speedtest", linkTitle: "Ookla PRIVACY POLICY", url: URL(string: "https://www.speedtest.net/about/privacy")!, company: "Ookla")
    public static let alexa = ThirdPartyPolicy(party: "Alexa", linkTitle: "Alexa Terms of Use",
                                               url: URL(string: "https://us.amazon.com/gp/help/customer/display.html?ref_=hp_left_v4_sib&nodeId=G201809740")!,
                                               company: "Amazon.com Services LLC")

    /// The line under the page: Thirdparty_PP_Desc1 with %1$@ the party and [aa]%2$@[/aa] the link text.
    public var agreement: (before: String, link: String, after: String) {
        let parts = "通过使用 %1$@ 应用程序，您同意 [aa]%2$@[/aa]。".replacingOccurrences(of: "%1$@", with: party).components(separatedBy: "[aa]%2$@[/aa]")
        return (parts[0], linkTitle, parts.count > 1 ? parts[1] : "")
    }
    /// The window's paragraphs: Thirdparty_PP_Desc2 and Desc3 with %1$@ the company and %2$@ the party.
    public var details: [String] {
        ["请注意，您的信息将由 %1$@ 通过 %2$@ 收集。您还确认并同意，ASUS 对您与 %1$@ 之间的协议或 %1$@ 提供的服务的任何内容概不负责。如果您对 %1$@ 如何收集、处理和使用您的上述信息有任何疑问，请参阅 %1$@ 发布的隐私相关声明或联系 %1$@ 以了解更多详情。",
         "如果您希望停用与%1$@共享信息共享，您可以停用或选择不使用%2$@。"].map {
            $0.replacingOccurrences(of: "%1$@", with: company).replacingOccurrences(of: "%2$@", with: party)
        }
    }
    /// For Speedtest the window puts InternetSpeed_desc above the first paragraph.
    public var introduction: String? { party == "Speedtest" ? "该服务由 Ookla® 提供。它检测路由器的 Internet 下载和上传速度。完成此测试大约需要一分钟。" : nil }
}

// MARK: - 政策

/// 系统管理 › 政策 (Advanced_Privacy.asp): the ASUS privacy statement, the EULA and, once agreed, Trend Micro's terms, with
/// what each 阅读 / 撤销 button opens (initial 64–110; PolicyStatus and the policy windows of js/asus_policy.js).
public struct PrivacyPolicyStatus: Sendable, Equatable {
    /// ASUS_NEW_EULA, ASUS_NEW_EULA_time, TM_EULA, TM_EULA_time, preferred_lang, ASUS_PP_AutoWebUpgradeDisable.
    public let values: [String: String]
    /// get_ASUS_privacy_policy.cgi's ASUS_privacy_policy and _time; when that request fails privateEula.get keeps its
    /// defaults, the number 0 and "" (httpApi.js 1076–1080).
    public let pp: OrderedJSON?
    public let ppTime: OrderedJSON?
    /// get_ui_support's asus_pp: the statement version offered when none is agreed.
    public let ppSupport: OrderedJSON?

    static let keys = ["ASUS_NEW_EULA", "ASUS_NEW_EULA_time", "TM_EULA", "TM_EULA_time", "preferred_lang", "ASUS_PP_AutoWebUpgradeDisable"]

    public init(values: [String: String], pp: OrderedJSON?, ppTime: OrderedJSON?, ppSupport: OrderedJSON?) {
        self.values = values; self.pp = pp; self.ppTime = ppTime; self.ppSupport = ppSupport
    }

    public var language: String { values["preferred_lang"] ?? "" }
    /// `eula_status.PP >= "1"`: the statement block offers 撤销 and the withdrawal texts, otherwise ASUS_PP_Info and 阅读.
    public var privacyAgreed: Bool { JavaScriptCompare.atLeast(pp, "1") }
    /// The Trend Micro block shows only for TM_EULA "1".
    public var showsTrendMicro: Bool { values["TM_EULA"] == "1" }
    /// The window's ppVersion: get_ui_support's asus_pp when `PP == 0`, otherwise PP (asus_policy.js 976–980).
    public var privacyVersion: String { JavaScriptCompare.text(JavaScriptCompare.looselyZero(pp) ? ppSupport : pp) }
    public var privacyDocument: PolicyDocument? { PolicyTexts.privacy(version: privacyVersion) }
    public var personalDataDocument: PolicyDocument? { PolicyTexts.personalData(version: privacyVersion) }
    /// 拒绝 and 同意 instead of 确认 (1090–1095): `PP < "2" || PP_time === "" || ppVersion > PP`, with ppVersion the
    /// value itself (get_ui_support's asus_pp when `PP == 0`, otherwise PP).
    public var privacyAsksAgreement: Bool {
        let version = JavaScriptCompare.looselyZero(pp) ? ppSupport : pp
        return JavaScriptCompare.below(pp, "2") || ppTime == .string("") || JavaScriptCompare.relational(version, pp) == .orderedDescending
    }
    /// The EULA window asks for agreement (with the age check) only for `EULA === "0"` (1077–1086).
    public var eulaAsksAgreement: Bool { values["ASUS_NEW_EULA"] == "0" }
    /// The TM window asks for agreement for `TM === "0" || TM_time === ""` (1101–1108).
    public var trendMicroAsksAgreement: Bool { values["TM_EULA"] == "0" || values["TM_EULA_time"] == "" }

    /// The window checkPolicy opens next: asus_policy.js 1158–1181 after a window's action, and state.js 5212–5238
    /// 1.5 seconds after every page loads, which also asks for Trend Micro's terms.
    public enum FollowUp: Sendable, Equatable {
        case none
        /// `EULA == "0"`: the notice 提示 (ASUS_POLICY_Update_Notice) whose 确认 opens the EULA window.
        case updateNotice
        case privacy
        case trendMicro
    }
    public func followUp(onPageLoad: Bool) -> FollowUp {
        if values["ASUS_NEW_EULA"] == "0" { return .updateNotice }
        if asksPrivacyAfterEULA { return .privacy }
        if onPageLoad, javaScriptNumber(values["TM_EULA"]) == 1, values["TM_EULA_time"] == "" { return .trendMicro }
        return .none
    }
    /// checkPolicy after the EULA is agreed opens the statement window for
    /// `EULA == 1 && ((PP == 1 && PP_time != "") || (PP == 0 && PP_time == ""))` (1159–1180).
    public var asksPrivacyAfterEULA: Bool {
        guard javaScriptNumber(values["ASUS_NEW_EULA"]) == 1 else { return false }
        // A missing time is not == "" (undefined only equals null), so `PP_time != ""` holds for it.
        let timeEmpty = ppTime.map { JavaScriptCompare.looselyEqualsEmptyText($0) } ?? false
        let one: Bool
        switch pp {
        case .string(let text)?: one = javaScriptNumber(text) == 1
        case .number(let text)?: one = javaScriptNumber(text) == 1
        case .bool(let on)?: one = on
        case .array(let elements)?: one = javaScriptNumber(TORSettings.javaScriptString(.array(elements))) == 1
        default: one = false
        }
        return (one && !timeEmpty) || (JavaScriptCompare.looselyZero(pp) && timeEmpty)
    }
    /// The Alexa page opens the statement window before an activation code or remote control when
    /// `data.PP == 0 || data.PP_time == ''` (Advanced_Smart_Home_Alexa.asp 214–227, 300–311).
    public var featureNeedsAgreement: Bool {
        JavaScriptCompare.looselyZero(pp) || (ppTime.map { JavaScriptCompare.looselyEqualsEmptyText($0) } ?? false)
    }
    /// 同意 also turns on automatic security updates and, unless ASUS_PP_AutoWebUpgradeDisable is "1", automatic firmware
    /// upgrades (handleClickAgree 1259–1280).
    public var agreementEnablesAutoUpgrade: Bool { values["ASUS_PP_AutoWebUpgradeDisable"] != "1" }
}

extension JavaScriptCompare {
    /// `value == ""`: text compares as text, a number, boolean or array by its numeric value against 0; null never.
    static func looselyEqualsEmptyText(_ value: OrderedJSON) -> Bool {
        switch value {
        case .string(let text): text.isEmpty
        case .number(let text): javaScriptNumber(text) == 0
        case .bool(let on): !on
        case .array(let elements): TORSettings.javaScriptString(.array(elements)).isEmpty
        default: false
        }
    }
}

/// What the policy windows write (httpApi.js 1035–1072, 1124–1134; asus_policy.js 1239–1290, 1550–1560;
/// Advanced_Privacy.asp withdraw_eula 190–211).
public enum PrivacyPolicyAction: Sendable, Equatable {
    /// 同意 in the statement window: privacy policy 1. Opened from 政策 the window also turns on security updates and, when
    /// allowed, automatic upgrades (`securityUpdate: true, websUpdate: true`); opened from the Alexa page it does not.
    case agreePrivacy(updates: Bool)
    /// 我理解此风险 in the withdrawal window.
    case withdrawPrivacy
    /// 同意 in the EULA window, after the age check.
    case agreeEULA
    /// 撤销 of the Trend Micro block, after its confirm(), and 拒绝 in the TM window (httpApi.enableEula("tm", "0")).
    case withdrawTrendMicro
    /// 同意 in the TM window (httpApi.enableEula("tm", "1"), httpApi.js 1022–1033).
    case agreeTrendMicro
}

extension RouterClient {
    public func privacyPolicyStatus() async throws -> PrivacyPolicyStatus {
        let values = try await readSettings(PrivacyPolicyStatus.keys)
        let support = try await orderedHook("get_ui_support")
        // privateEula.get: an error leaves ASUS_PP 0 and ASUS_PP_time "" (async ajax with no error handler).
        var pp: OrderedJSON? = .number("0"), time: OrderedJSON? = .string("")
        do {
            let answer = try OrderedJSON(data: try await request("get_ASUS_privacy_policy.cgi"))
            pp = answer["ASUS_privacy_policy"]; time = answer["ASUS_privacy_policy_time"]
        } catch RouterError.authenticationRequired { throw RouterError.authenticationRequired }
        catch is CancellationError { throw CancellationError() }
        catch {}
        return PrivacyPolicyStatus(values: values, pp: pp, ppTime: time, ppSupport: support?["asus_pp"])
    }

    /// Sends what the web sends for the action, then reads the page again.
    public func applyPrivacyPolicy(_ action: PrivacyPolicyAction) async throws -> PrivacyPolicyStatus {
        try acquireMutation(); defer { releaseMutation() }
        /// privateEula.set and newEula.set ask for JSON (httpApi.js 1035–1068): only an answer that parses goes on to their
        /// callbacks (the update switches, checkPolicy), so anything else stops here as unconfirmed.
        func get(_ path: String, _ name: String, _ value: String, json: Bool = false) async throws {
            let data = try await request(path, query: [.init(name: name, value: value)], changes: true)
            if json, (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) == nil {
                throw RouterError.submissionUncertain("路由器的回应不是网页等待的 JSON，网页在这里不会继续；同意状态可能已经写入，请重新读取确认，不要重复提交。")
            }
        }
        switch action {
        case .agreePrivacy(let updates):
            let before = try await readSettings(["ASUS_PP_AutoWebUpgradeDisable"])
            try await get("set_ASUS_privacy_policy.cgi", "ASUS_privacy_policy", "1", json: true)
            guard updates else { break }
            try await get("set_security_update.cgi", "security_update", "1")
            if before["ASUS_PP_AutoWebUpgradeDisable"] != "1" {
                try await submitApply(["action_mode": "apply", "rc_service": "saveNvram", "webs_update_enable": "1"])
            }
        case .withdrawPrivacy: try await get("set_ASUS_privacy_policy.cgi", "ASUS_privacy_policy", "0", json: true)
        case .agreeEULA: try await get("set_ASUS_NEW_EULA.cgi", "ASUS_NEW_EULA", "1", json: true)
        case .withdrawTrendMicro: try await get("set_TM_EULA.cgi", "TM_EULA", "0")
        case .agreeTrendMicro: try await get("set_TM_EULA.cgi", "TM_EULA", "1")
        }
        return try await privacyPolicyStatus()
    }

    public func uuAccelerator() async throws -> UUAccelerator {
        UUAccelerator(labelMAC: try await orderedHook("get_label_mac")?.text)
    }
}
