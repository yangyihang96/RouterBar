import Foundation

// MARK: - 游戏加速

/// Game › 游戏加速 (GameBoost.asp) on a router with gameMode and Adaptive QoS: 设备加速器 (游戏设备优先 and the game device
/// list, bwdpi_game_list), Mobile Game Mode and the way to Open NAT. The ROG-QoS branch (rog_first_qos.cgi, bandwidth
/// defaults) is for routers without adaptive_qos, and WTFast, 腾讯网游加速器, Outfox and GearUP for routers that support them.
public struct GameBoostPage: Sendable, Equatable {
    static let keys = ["fc_disable", "runner_disable", "ctf_disable", "ctf_fa_mode", "bwdpi_game_list", "rog_clientlist", "qos_enable", "qos_type",
                       "rog_enable", "qos_obw", "qos_obw1", "qos_ibw", "qos_ibw1", "lan_hwaddr", "preferred_lang", "firmver", "TM_EULA", "TM_EULA_time",
                       "territory_code", "productid"]
    public let values: [String: String]
    public let support: [String: String]
    public let clients: [TORSettings.ClientEntry]
    /// get_default_reboot_time() (web.c 42278–42293): reboot_time.
    public let rebootTime: String

    public init(values: [String: String], support: [String: String], clients: [TORSettings.ClientEntry], rebootTime: String) {
        self.values = values; self.support = support; self.clients = clients; self.rebootTime = rebootTime
    }

    func supports(_ name: String) -> Bool { !["", "0"].contains(support[name] ?? "") }
    public var adaptive: Bool { supports("adaptive_qos") }
    public var gameMode: Bool { supports("gameMode") }
    /// The game_priority_enable check box (initial 234–245): Adaptive QoS on with the adaptive type.
    public var priorityOn: Bool { values["qos_enable"] == "1" && values["qos_type"] == "1" }
    /// gameList (326–331): bwdpi_game_list with &#60 turned back into "<".
    public var gameList: String { (values["bwdpi_game_list"] ?? "").replacingOccurrences(of: "&#60", with: "<") }
    /// is_CN or the CN interface (248–252): the Android download is the APK on dlcdnets.
    public var androidApp: URL {
        let cn = ["CN", "CT", "GD", "TC"].contains { (values["territory_code"] ?? "").contains($0) } || values["preferred_lang"] == "CN"
        return URL(string: cn ? "https://dlcdnets.asus.com/pub/ASUS/LiveUpdate/Release/Wireless/ASUSRouter_Android_Release.apk"
                              : "https://play.google.com/store/apps/details?id=com.asus.aihome")!
    }
    public static let iosApp = URL(string: "https://itunes.apple.com/tw/app/asus-router/id1033794044")!

    /// One row of the game device list (genGameList 333–416): the client's nickName or name (written twice, as the page
    /// does) and IP, or New device.
    public struct Device: Sendable, Equatable, Identifiable {
        public let id: Int
        public let mac: String
        public let name: String
        public let ip: String
    }
    /// The rows for a list: every entry between "<" (an empty one too); none when the list is empty.
    public func devices(_ list: String) -> [Device] {
        guard !list.isEmpty else { return [] }
        return list.components(separatedBy: "<").enumerated().map { index, mac in
            if let client = clients.first(where: { $0.mac == mac.uppercased() }) {
                return Device(id: index, mac: mac, name: HTMLText.visible(client.nickName.isEmpty ? client.name : client.nickName, inside: ["div"]),
                              ip: HTMLText.visible(client.ip, inside: ["div"]))
            }
            return Device(id: index, mac: mac, name: "New device", ip: "")
        }
    }

    /// addGameList (419–452): blank, the list over 64 entries (`length > "64"`, so a 65th is still taken), and a MAC equal
    /// (as typed, case and all) to an entry after the first.
    public static func adding(_ mac: String, to list: String) -> Result<String, Alert> {
        let entries = list.components(separatedBy: "<")
        if mac.isEmpty { return .failure(Alert("栏位不能为空白")) }
        if entries.count > 64 { return .failure(Alert("本表仅允许 64 项目！")) }
        if entries.dropFirst().contains(where: { $0.sameUnits(mac) }) { return .failure(Alert("此项已纳入列表中。")) }
        return .success(list.isEmpty ? mac : list + "<" + mac)
    }
    public struct Alert: Error, Equatable { public let message: String; init(_ message: String) { self.message = message } }
    /// delGameList (454–489): every entry equal to the MAC goes.
    public static func removing(_ mac: String, from list: String) -> String {
        list.components(separatedBy: "<").filter { !$0.sameUnits(mac) }.joined(separator: "<")
    }

    /// enableGamePriority with Adaptive QoS (517–528): a click while qos_enable is "0" and Trend Micro's terms are not agreed
    /// (`TM == 0 || TM_time == ''`) asks for them first.
    public var asksTrendMicro: Bool {
        values["qos_enable"] == "0" && (javaScriptLooselyEquals(values["TM_EULA"], 0) || values["TM_EULA_time"] == "")
    }

    /// The form `form` (744–759) as eula_confirm (603–633) or applyRule (635–642) sends it.
    public struct Submission: Sendable, Equatable {
        public let fields: [(String, String)]
        public let reboots: Bool
        public let wait: Int
        public static func == (a: Submission, b: Submission) -> Bool {
            a.fields.elementsEqual(b.fields, by: { $0 == $1 }) && a.reboots == b.reboots && a.wait == b.wait
        }
    }
    /// eula_confirm: the switch's qos_enable / qos_type, the service (a reboot for ctf_fa_mode "2" unless hardware
    /// acceleration is off), and the list.
    public func priority(on: Bool, list: String) -> Submission {
        var enable = values["qos_enable"] ?? "", type = values["qos_type"] ?? ""
        if on { enable = "1"; type = "1" } else { enable = "0" }
        let accelerationOff = javaScriptLooselyEquals(values["ctf_disable"], 1) || (!(values["fc_disable"] ?? "").isEmpty && !(values["runner_disable"] ?? "").isEmpty)
        let reboots = !accelerationOff && values["ctf_fa_mode"] == "2"
        return form(qosEnable: enable, qosType: type, list: list, reboots: reboots)
    }
    /// applyRule (635–642): the list with the form as it is.
    public func saving(_ list: String) -> Submission {
        form(qosEnable: values["qos_enable"] ?? "", qosType: values["qos_type"] ?? "", list: list, reboots: false)
    }
    /// What a submission is checked by: the form's three values, and TM_EULA after the terms' 同意.
    static func checkedKeys(agreeingTrendMicro: Bool) -> [String] {
        ["qos_enable", "qos_type", "bwdpi_game_list"] + (agreeingTrendMicro ? ["TM_EULA"] : [])
    }
    func form(qosEnable: String, qosType: String, list: String, reboots: Bool) -> Submission {
        // FormActions("start_apply.htm", "apply", "reboot", default_reboot_time) for a reboot; otherwise the form's 5.
        let wait = reboots ? rebootTime : "5"
        let fields = [("current_page", "GameBoost.asp"), ("next_page", "GameBoost.asp"), ("preferred_lang", values["preferred_lang"] ?? ""),
                      ("firmver", values["firmver"] ?? ""), ("action_mode", "apply"), ("action_script", reboots ? "reboot" : "restart_qos;restart_firewall"),
                      ("action_wait", wait), ("qos_enable", qosEnable), ("qos_type", qosType), ("bwdpi_game_list", list), ("rog_enable", values["rog_enable"] ?? "")]
        return Submission(fields: fields, reboots: reboots, wait: Int(wait) ?? 5)
    }
}

extension RouterClient {
    public func gameBoostPage() async throws -> GameBoostPage {
        let values = try await readSettings(GameBoostPage.keys)
        let support = try await uiCapabilities()
        let clients = TORSettings.clientList(current: try await optionalHook("get_clientlist"), history: try await optionalHook("get_clientlist_from_json_database"),
                                             lanMAC: values["lan_hwaddr"] ?? "", productID: values["productid"] ?? "",
                                             amas: !["", "0"].contains(support["amas"] ?? ""))
        let reboot = try await optionalHook("get_default_reboot_time").map(TORSettings.javaScriptString) ?? ""
        return GameBoostPage(values: values, support: support, clients: clients, rebootTime: reboot)
    }

    /// The form to start_apply.htm; with Trend Micro's terms agreed, enableEula('tm', "1") right after it, as the terms
    /// window's 同意 sends it after its agreeCallback whether or not the form reboots (asus_policy.js 1281–1288). After the
    /// form's wait the variables are read back; a reboot is only reported as sent (checkGameBoost reads them once the router
    /// is back).
    public func submitGameBoost(_ submission: GameBoostPage.Submission, agreeingTrendMicro: Bool = false) async throws -> ApplyReceipt {
        try acquireMutation(); defer { releaseMutation() }
        // eula_confirm submits the form into a hidden frame and returns at once; enableEula('tm', "1") starts right after,
        // without waiting for the form's answer (asus_policy.js 1282–1288, GameBoost.asp 628). The two go out together here
        // too, and each answer is taken on its own.
        let body = RouterAuthentication.orderedForm(submission.fields, .formSubmission)
        async let formAnswer = request("start_apply.htm", method: "POST", body: body, contentType: "application/x-www-form-urlencoded", timeout: 60)
        var termsSent = true
        if agreeingTrendMicro {
            await Task.yield()
            do { _ = try await request("set_TM_EULA.cgi", query: [.init(name: "TM_EULA", value: "1")], changes: true) }
            catch is CancellationError { throw CancellationError() }
            catch { termsSent = false }
        }
        var uncertainty: String?
        do {
            _ = try await formAnswer
        } catch is CancellationError {
            throw CancellationError()
        } catch RouterError.submissionUncertain(let reason) {
            uncertainty = reason
        }
        let keys = GameBoostPage.checkedKeys(agreeingTrendMicro: agreeingTrendMicro)
        let terms = agreeingTrendMicro ? (termsSent ? "Trend Micro 条款的同意也已发送。" : "Trend Micro 条款的同意没有发送成功，请稍后重新读取确认。") : ""
        if submission.reboots {
            return ApplyReceipt(verified: [], unverified: keys, message: (uncertainty ?? "路由器已接收设置并开始重新启动，约 \(submission.wait) 秒后才能重新连接并读取确认。") + terms)
        }
        if let uncertainty { return ApplyReceipt(verified: [], unverified: keys, message: uncertainty + terms) }
        do {
            try await Task.sleep(for: .seconds(max(submission.wait, 1)))
            return try await checkGameBoost(submission, agreeingTrendMicro: agreeingTrendMicro)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ApplyReceipt(verified: [], unverified: keys, message: "路由器已接收请求，正在重新加载 QoS 与防火墙。保存结果仍待重新读取确认。")
        }
    }

    /// The variables the form (and the terms' 同意) set, read back and compared with what was sent.
    public func checkGameBoost(_ submission: GameBoostPage.Submission, agreeingTrendMicro: Bool) async throws -> ApplyReceipt {
        let keys = GameBoostPage.checkedKeys(agreeingTrendMicro: agreeingTrendMicro)
        var sent = Dictionary(submission.fields, uniquingKeysWith: { _, last in last })
        if agreeingTrendMicro { sent["TM_EULA"] = "1" }
        let after = try await readSettings(keys)
        let unverified = keys.filter { after[$0]?.replacingOccurrences(of: "&#60", with: "<") != sent[$0] }
        return ApplyReceipt(verified: keys.filter { !unverified.contains($0) }, unverified: unverified,
                            message: unverified.isEmpty ? "已从路由器重新读取，设置已保存。" : "路由器已响应，但部分设置与提交值不一致。请重新读取并检查。")
    }
}
