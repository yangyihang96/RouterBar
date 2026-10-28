import Foundation
import Testing
@testable import RouterCore

// 1.14：家长管理 › 网页与 Apps 过滤（AiProtection_WebProtector.asp）与时间安排（ParentalControl.asp、js/weekSchedule/weekSchedule.js）。
// 设备、MAC 与名称都是虚构的。

// MARK: - A router for these pages

/// Answers appGet hooks (nvram_char_to_ascii from `nvram`, get_ui_support from `support`, other hooks from `hooks` as JSON),
/// start_apply.htm, applyapp.cgi and set_TM_EULA.cgi like the router, writing what they set into `nvram`. Records every
/// request with its raw body.
private actor ParentalRouter: RouterTransport {
    var nvram: [String: String]
    let support: [String: Any]
    let hooks: [String: String]
    /// What start_apply.htm answers.
    let applyAnswer: String
    private(set) var requests: [(method: String, path: String, query: [String: String], body: String)] = []

    init(nvram: [String: String] = [:], support: [String: Any] = [:], hooks: [String: String] = [:],
         applyAnswer: String = "<script>done_committing();</script>") {
        self.nvram = nvram; self.support = support; self.hooks = hooks; self.applyAnswer = applyAnswer
    }

    func send(_ request: URLRequest) async throws -> RouterHTTPResponse {
        guard let url = request.url else { throw RouterError.network("no url") }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let path = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        requests.append((request.httpMethod ?? "GET", path, query, body))
        switch path {
        case "appGet.cgi":
            let hook = query["hook"] ?? ""
            if hook == "get_ui_support()" { return try Self.reply(["get_ui_support": support]) }
            if let open = hook.firstIndex(of: "("), !hook.hasPrefix("nvram_char_to_ascii(") {
                let name = String(hook[..<open])
                if let answer = hooks[name] { return RouterHTTPResponse(data: Data("{\"\(name)\":\(answer)}".utf8), status: 200) }
                return RouterHTTPResponse(data: Data("{}".utf8), status: 200)
            }
            var object: [String: String] = [:]
            for call in hook.split(separator: ";") {
                guard let open = call.firstIndex(of: "("), let comma = call.firstIndex(of: ",") else { continue }
                let key = String(call[call.index(after: open)..<comma])
                object[key] = nvram[key].map { $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" } ?? ""
            }
            return try Self.reply(object)
        case "applyapp.cgi":
            guard let decoded = body.removingPercentEncoding, let fields = try JSONSerialization.jsonObject(with: Data(decoded.utf8)) as? [String: String] else {
                return RouterHTTPResponse(data: Data(), status: 400)
            }
            for (key, value) in fields where !["action_mode", "rc_service"].contains(key) { nvram[key] = value }
            return try Self.reply(["modify": "1", "run_service": fields["rc_service"] ?? ""])
        case "start_apply.htm":
            for (key, value) in form(body) where !["current_page", "next_page", "action_mode", "action_script", "action_wait", "modified"].contains(key) {
                nvram[key] = value
            }
            return RouterHTTPResponse(data: Data(applyAnswer.utf8), status: 200)
        case "set_TM_EULA.cgi":
            // do_set_TM_EULA_cgi (web.c 21482–21523).
            let value = query["TM_EULA"] ?? ""
            nvram["TM_EULA"] = value; nvram["TM_EULA_time"] = "Tue, 27 Oct 2026 14:05:09 +1100"
            if value == "0" { for key in ["wrs_protect_enable", "wrs_enable", "wrs_app_enable", "apps_analysis", "bwdpi_wh_enable", "bwdpi_db_enable"] { nvram[key] = "0" } }
            return RouterHTTPResponse(data: Data(), status: 200)
        default:
            return RouterHTTPResponse(data: Data(), status: 404)
        }
    }
    nonisolated func cancel() {}
    static func reply(_ object: Any) throws -> RouterHTTPResponse { RouterHTTPResponse(data: try JSONSerialization.data(withJSONObject: object), status: 200) }
    var actions: [(method: String, path: String, query: [String: String], body: String)] { requests.filter { $0.path != "appGet.cgi" } }
    func value(_ key: String) -> String? { nvram[key] }
}

private func client(_ router: ParentalRouter) throws -> RouterClient { RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: router, writes: .reference) }
private func json(_ text: String) -> OrderedJSON { try! OrderedJSON(data: Data(text.utf8)) }
private func form(_ body: String) -> [String: String] {
    Dictionary(body.split(separator: "&").map { pair -> (String, String) in
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map {
            String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
        }
        return (parts[0], parts.count > 1 ? parts[1] : "")
    }, uniquingKeysWith: { first, _ in first })
}
/// The values as nvram_char_to_ascii writes them (only letters and digits kept).
private func encoded(_ values: [String: String]) -> EncodedNvram {
    EncodedNvram(encoded: values.mapValues { $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" })
}
private func names(_ submission: ParentalFormSubmission?) -> [String] { submission?.fields.map(\.0) ?? [] }

private let macA = "AA:BB:CC:DD:EE:01", macB = "AA:BB:CC:DD:EE:02", macC = "AA:BB:CC:DD:EE:03"
private let clients = [TORSettings.ClientEntry(mac: macA, name: "Tablet", nickName: "Kid Tablet", ip: "192.168.50.20", online: true),
                       TORSettings.ClientEntry(mac: macB, name: "Laptop", nickName: "", ip: "192.168.50.21", online: true)]

// MARK: - 共用

@Test func macCheckIsTheUnanchoredPatternOfCheckHwaddrFlag() {
    #expect(ParentalMAC.flag("") == 0 && ParentalMAC.flag("AA:BB:CC:DD:EE:FF") == 0 && ParentalMAC.flag("aa:bb:cc:dd:ee:0f") == 0)
    // Each group ends with ":" or the end of the text, anywhere in it; 'inner' skips the unicast check.
    #expect(ParentalMAC.flag("AA:BB:CC:DD:EE:FF:") == 0 && ParentalMAC.flag("xAA:BB:CC:DD:EE:FF") == 0 && ParentalMAC.flag("01:BB:CC:DD:EE:FF") == 0)
    #expect(ParentalMAC.flag("AA:BB:CC:DD:EE") == 1 && ParentalMAC.flag("AA-BB-CC-DD-EE-FF") == 1 && ParentalMAC.flag("AABBCCDDEEFF") == 1
            && ParentalMAC.flag("AA:BB:CC:DD:EE:FG") == 1)
}

@Test func isSupportKeepsTheValueItself() {
    let support = UISupport(json(#"{"PC_SCHED_V3":"0","MaxRule_parentctrl":16,"MaxRule_PC_DAYTIME":0,"bwdpi":1,"hnd":"1"}"#))
    // A text "0" is truthy (`if(isSupport(…))`), parseInt of it is 0; a missing or zero value is the number 0.
    #expect(support.on("PC_SCHED_V3") && support.integer("PC_SCHED_V3") == 0 && support.value("PC_SCHED_V3") == .string("0"))
    #expect(support.value("MaxRule_PC_DAYTIME") == .number("0") && support.value("missing") == .number("0") && !support.on("missing"))
    #expect(support.text("MaxRule_parentctrl") == "16" && support.integer("missing") == 0)
    #expect(javaScriptParseInt("3E", radix: 16) == 62 && javaScriptParseInt("0A") == 0 && javaScriptParseInt("x1").isNaN && javaScriptParseInt(" -7") == -7)
}

// MARK: - 网页与 Apps 过滤

private func protector(_ values: [String: String] = [:], support: String = #"{"MaxRule_bwdpi_wrs":16,"bwdpi":1,"dualwan":1}"#,
                       reboot: String = "150", dpi: String = #"{"DpiEngine":"1"}"#, mode: String = "rt") -> WebProtectorPage {
    let base = ["wrs_rulelist": "", "wrs_app_rulelist": "", "wrs_enable": "1", "wrs_app_enable": "1", "TM_EULA": "1", "TM_EULA_time": "Mon, 01 Jun 2026 10:00:00 +1000",
                "ctf_disable": "1", "ctf_fa_mode": "0", "productid": "RT-BE88U", "firmver": "3.0.0.6", "preferred_lang": "CN", "lan_hwaddr": "04:42:1A:00:00:01",
                "wlc_band": "", "wans_dualwan": "wan none", "wans_mode": "fo", "reboot_time": "120"]
    return WebProtectorPage(nvram: encoded(base.merging(values) { _, new in new }), support: UISupport(json(support)), clients: clients,
                            rebootTime: reboot, dpiStatus: json(dpi), operationMode: mode)
}
private let ruleA = "1>\(macA)>1,2,3,4,5,6,8>51>>", appA = "1>\(macA)>22>0,6,15>>"

@Test func webProtectorRebuildsTheCategoriesRowByRow() {
    // The spec's example: the two lists become the page's flags.
    #expect(WebProtectorPage.translated(wrs: ruleA, apps: appA) == "1>\(macA)>1,0,0>0,1,0,0,0>0,0>0,0,0")
    // indexOf: "151" holds 51 (即时通讯) and the app column "121" holds 21 (移动设备); rows pair by position, not by MAC.
    #expect(WebProtectorPage.translated(wrs: "1>\(macA)>>151>>", apps: "0>\(macB)>>121>>") == "1>\(macA)>0,0,0>0,1,0,0,1>0,0>0,0,0")
    // Empty lists; a missing app row or an app column the wrs column needs, and a seventh column, throw.
    #expect(WebProtectorPage.translated(wrs: "", apps: "") == "")
    #expect(WebProtectorPage.translated(wrs: ruleA + "<" + ruleA, apps: appA) == nil)
    #expect(WebProtectorPage.translated(wrs: "1>\(macA)>>24", apps: "1>\(macA)>") == nil)
    #expect(WebProtectorPage.translated(wrs: "1>\(macA)>>>>>9", apps: "1>\(macA)>>>>>9") == nil)
    // wrs empty but the app list not: apps_filter_row is "" and its first row undefined.
    #expect(WebProtectorPage.translated(wrs: "", apps: appA) == nil)
    let page = protector(["wrs_rulelist": ruleA + "<" + ruleA, "wrs_app_rulelist": appA])
    let opened = WebProtectorForm(page: page)
    #expect(page.initialFilter == nil && opened.tableFailed && !opened.listShown && opened.switchShownOn)
}

@Test func webProtectorDrawsTheRowsAsGenMainTable() throws {
    // Short rows are padded and switched off; a three-column row needs a 17-character MAC.
    let filter = "1>\(macA)>1,0,0>0,1,0,0,0>0,0>0,0,0<1>aa:bb:cc:dd:ee:02>0,0,1>1,0,0,0,0<1>\(macC)>1,1,1<1>short>1,1,1"
    let rows = try #require(WebProtectorPage.rows(filter, clients: clients))
    #expect(rows.map(\.mac) == [macA, macB, macC] && rows.map(\.name) == ["Kid Tablet", "Laptop", "New device"])
    #expect(rows.map(\.enabled) == [true, false, false])
    #expect(rows[0].parents == [true, true, false, false] && rows[0].children[1] == [false, true, false, false, false])
    #expect(rows[1].children[0] == [false, false, true] && rows[1].children[2] == [false, false] && rows[2].parents == [true, false, false, false])
    // A category's box is `indexOf('1')`, an item `== 1`: "10" checks the box but not the item.
    let odd = try #require(WebProtectorPage.rows("1>\(macA)>0,0,10>01,0,0,0,0>0,0>0,0,0", clients: []))
    #expect(odd[0].parents[0] && odd[0].children[0] == [false, false, false] && odd[0].children[1][0])
    // A row without a MAC column, or two columns, throws: the table is not drawn.
    #expect(WebProtectorPage.rows("1", clients: []) == nil && WebProtectorPage.rows("1>\(macA)", clients: []) == nil)
    #expect(WebProtectorPage.rows("", clients: []) == [])
}

@Test func webProtectorAddsAsAddRowMain() {
    var form = WebProtectorForm(page: protector(["wrs_rulelist": ruleA, "wrs_app_rulelist": appA]))
    #expect(form.add() == .alert("栏位不能为空白"))
    form.newRow.mac = "AA:BB:CC:DD:EE"
    #expect(form.add() == .hint && form.macHint)
    // A duplicate in another case clears the field; the hint goes once the format passes.
    form.newRow.mac = macA.lowercased()
    #expect(form.add() == .alert("此项已纳入列表中。") && form.newRow.mac.isEmpty && !form.macHint)
    form.newRow.mac = macB.lowercased()
    #expect(form.add() == .alert("内容类别不能为空。"))
    // An unsaved change on another row goes with the redraw.
    form.rows[0].enabled = false
    form.toggleChild(row: nil, category: 2, item: 1)
    form.newRow.enabled = false
    #expect(form.add() == .added)
    #expect(form.filter == "1>\(macA)>1,0,0>0,1,0,0,0>0,0>0,0,0<0>\(macB)>0,0,0>0,0,0,0,0>0,1>0,0,0")
    #expect(form.rows.count == 2 && form.rows[0].enabled && form.newRow == WebProtectorNewRow())
    // The limit: MaxRule_bwdpi_wrs when above 0 (else 16), against `apps_filter.split("<").length`, so "" counts one.
    var one = WebProtectorForm(page: protector(support: #"{"MaxRule_bwdpi_wrs":1}"#))
    one.newRow.mac = macA
    #expect(one.add() == .alert("本表仅允许 1 项目！"))
    var unlimited = WebProtectorForm(page: protector(["wrs_rulelist": Array(repeating: ruleA, count: 16).joined(separator: "<"),
                                                      "wrs_app_rulelist": Array(repeating: appA, count: 16).joined(separator: "<")], support: "{}"))
    unlimited.newRow.mac = macB
    #expect(unlimited.add() == .alert("本表仅允许 16 项目！") && unlimited.page.listTitle == "用户名单 (最多限制： 0)")
}

@Test func webProtectorDeletesByTheRowTitle() {
    var form = WebProtectorForm(page: protector(["wrs_rulelist": ruleA + "<1>aa:bb:cc:dd:ee:02>>>>", "wrs_app_rulelist": appA + "<1>aa:bb:cc:dd:ee:02>>>>"]))
    #expect(form.rows.count == 2)
    form.delete(form.rows[0])
    // The lower-case row is kept by deleteRow_main (its MAC is not the title) and drawn again.
    #expect(form.rows.map(\.mac) == [macB] && form.filter == "1>aa:bb:cc:dd:ee:02>0,0,0>0,0,0,0,0>0,0>0,0,0")
    form.delete(form.rows[0])
    #expect(form.rows.count == 1)
}

@Test func webProtectorCategoryBoxesFollowSetCategory() {
    var form = WebProtectorForm(page: protector())
    form.toggleParent(row: nil, category: 1)
    #expect(form.newRow.children[1] == [true, true, true, true, true])
    form.toggleChild(row: nil, category: 1, item: 0)
    #expect(form.newRow.parents[1])
    form.toggleParent(row: nil, category: 1)
    #expect(form.newRow.children[1] == [false, false, false, false, false] && !form.newRow.parents[1])
    form.toggleChild(row: nil, category: 3, item: 2)
    #expect(form.newRow.parents[3])
    form.toggleChild(row: nil, category: 3, item: 2)
    #expect(!form.newRow.parents[3])
    // One category is open at a time on the whole table.
    form.toggleExpanded(WebProtectorCategoryPosition(row: nil, category: 0))
    form.toggleExpanded(WebProtectorCategoryPosition(row: 2, category: 1))
    #expect(form.expanded == WebProtectorCategoryPosition(row: 2, category: 1))
    form.toggleExpanded(WebProtectorCategoryPosition(row: 2, category: 1))
    #expect(form.expanded == nil)
}

@Test func webProtectorApplySendsTheFormInDocumentOrder() throws {
    let form = WebProtectorForm(page: protector(["wrs_rulelist": ruleA, "wrs_app_rulelist": appA]))
    let (_, step) = form.running(.apply, answers: [])
    guard case .finished(nil, let writes) = step, let submission = writes.form else { Issue.record("\(step)"); return }
    #expect(writes.trendMicro == nil)
    #expect(submission.fields.map(\.0) == ["productid", "current_page", "next_page", "modified", "action_wait", "action_mode", "action_script", "firmver",
                                           "wrs_enable", "wrs_enable_ori", "wrs_app_enable", "wrs_rulelist", "wrs_app_rulelist", "TM_EULA", "PC_devicename"])
    #expect(submission.value("wrs_rulelist") == ruleA && submission.value("wrs_app_rulelist") == appA && submission.value("action_script") == "restart_wrs;restart_firewall"
            && submission.value("action_wait") == "5" && submission.value("preferred_lang") == nil)
    let body = String(decoding: RouterAuthentication.orderedForm(submission.fields, .formSubmission), as: UTF8.self)
    #expect(body == "productid=RT-BE88U&current_page=AiProtection_WebProtector.asp&next_page=&modified=0&action_wait=5&action_mode=apply"
            + "&action_script=restart_wrs%3Brestart_firewall&firmver=3.0.0.6&wrs_enable=1&wrs_enable_ori=1&wrs_app_enable=1"
            + "&wrs_rulelist=1%3EAA%3ABB%3ACC%3ADD%3AEE%3A01%3E1%2C2%2C3%2C4%2C5%2C6%2C8%3E51%3E%3E&wrs_app_rulelist=1%3EAA%3ABB%3ACC%3ADD%3AEE%3A01%3E22%3E0%2C6%2C15%3E%3E"
            + "&TM_EULA=1&PC_devicename=")
    // Every item, and an AiMesh router in router mode.
    var all = WebProtectorForm(page: protector(["wrs_rulelist": ruleA, "wrs_app_rulelist": appA], support: #"{"amas":1,"amasRouter":1}"#))
    for category in 0..<4 { all.toggleParent(row: 0, category: category) }
    for category in 0..<4 where !all.rows[0].parents[category] { all.toggleParent(row: 0, category: category) }
    guard case .finished(nil, let every) = all.running(.apply, answers: []).1 else { Issue.record("no submit"); return }
    #expect(every.form?.value("wrs_rulelist") == "1>\(macA)>1,2,3,4,5,6,8,9,10,14,15,16,25,26,11>24,51,53,89,42>56,70,71,57>69,23")
    #expect(every.form?.value("wrs_app_rulelist") == "1>\(macA)>22>24,0,6,15,21>3,1>8,4")
    #expect(every.form?.actionScript == "restart_wrs;restart_firewall;apply_amaslib")
    // A MAC typed but not added, and a row without an item, stop with the page's alerts.
    var typed = form
    typed.newRow.mac = macB
    #expect(typed.running(.apply, answers: []).1 == .finished(alert: "您必须先按添加图标才能添加新规则。", writes: WebProtectorWrites()))
    var empty = form
    empty.toggleChild(row: 0, category: 0, item: 0); empty.toggleChild(row: 0, category: 1, item: 1)
    #expect(empty.running(.apply, answers: []).1 == .finished(alert: "内容类别不能为空。", writes: WebProtectorWrites()))
}

@Test func cancelledQuestionsLeaveTheFormAsBeforeTheClick() {
    // Terms agreed, filter off, hardware acceleration in mode 2: switching on asks about the restart first.
    let page = protector(["wrs_enable": "0", "wrs_app_enable": "0", "TM_EULA": "1", "TM_EULA_time": "2026-10-01 10:00:00",
                          "ctf_disable": "0", "ctf_fa_mode": "2", "wrs_rulelist": ruleA, "wrs_app_rulelist": appA])
    let form = WebProtectorForm(page: page)
    #expect(!page.asksTrendMicro && !page.asksDualWAN && page.accelerationReboots)
    #expect(form.running(.switchOn, answers: []).1 == .confirm(.acceleration))
    let (next, step) = form.running(.switchOn, answers: [false])
    guard case .finished(nil, let writes) = step else { Issue.record("\(step)"); return }
    // The page's script had already set the switch, wrs_enable, TM_EULA and action_wait; 取消 takes the page back.
    #expect(writes.isEmpty && next.switchShownOn && next.wrsEnable == "1" && next.actionWait == "15")
    let shown = form.settled(next, answers: [false], writes: writes)
    #expect(!shown.switchShownOn && shown.wrsEnable == "0" && shown.wrsAppEnable == "0" && shown.actionWait == form.actionWait)
    // A run that sends something, or ends without a question answered 取消, shows the form as the script left it.
    let (sent, done) = form.running(.switchOn, answers: [true, true])
    guard case .finished(nil, let sending) = done else { Issue.record("\(done)"); return }
    #expect(!sending.isEmpty && form.settled(sent, answers: [true, true], writes: sending).wrsEnable == "1")
}

@Test func webProtectorSwitchOnAsksInThePageOrder() throws {
    // DPI off, dual WAN in load balance, terms not agreed, hardware acceleration in mode 2.
    let page = protector(["wrs_enable": "0", "wrs_app_enable": "0", "TM_EULA": "0", "TM_EULA_time": "", "ctf_disable": "0", "ctf_fa_mode": "2",
                          "wans_dualwan": "wan wan2", "wans_mode": "lb", "wrs_rulelist": ruleA, "wrs_app_rulelist": appA],
                         dpi: #"{"DpiEngine":"0"}"#)
    let form = WebProtectorForm(page: page)
    #expect(page.asksDualWAN && page.asksTrendMicro && page.accelerationReboots && form.curState == "0" && !form.listShown)
    #expect(form.running(.switchOn, answers: []).1 == .confirm(.dualWAN))
    #expect(form.running(.switchOn, answers: [true]).1 == .terms)
    #expect(form.running(.switchOn, answers: [true, true]).1 == .confirm(.acceleration))
    #expect(form.running(.switchOn, answers: [true, true, true]).1 == .confirm(.reboot))
    let (after, done) = form.running(.switchOn, answers: [true, true, true, true])
    guard case .finished(nil, let writes) = done, let submission = writes.form else { Issue.record("\(done)"); return }
    // The reboot takes get_default_reboot_time; wans_mode=fo comes last, after PC_devicename.
    #expect(writes.trendMicro == "1" && submission.reboots && submission.value("action_wait") == "150" && submission.value("TM_EULA") == "1")
    #expect(names(submission).suffix(3) == ["TM_EULA", "PC_devicename", "wans_mode"] && submission.value("wans_mode") == "fo")
    #expect(submission.value("wrs_enable") == "1" && submission.value("wrs_enable_ori") == "0" && after.rebootConfirm && after.changeStatus)
    // 取消 on the dual WAN question: cancel(), nothing sent.
    let (cancelled, none) = form.running(.switchOn, answers: [false])
    #expect(none == .finished(alert: nil, writes: WebProtectorWrites()) && !cancelled.switchShownOn && cancelled.curState == "0")
    // 拒绝: cancel() and set_TM_EULA.cgi with 0, no form.
    #expect(form.running(.switchOn, answers: [true, false]).1 == .finished(alert: nil, writes: WebProtectorWrites(trendMicro: "0")))
    // 取消 on the acceleration question still records 同意 (the agree callback returned); on the reboot question too, and the
    // page keeps reboot_confirm and the appended wans_mode.
    #expect(form.running(.switchOn, answers: [true, true, false]).1 == .finished(alert: nil, writes: WebProtectorWrites(trendMicro: "1")))
    let (kept, declined) = form.running(.switchOn, answers: [true, true, true, false])
    #expect(declined == .finished(alert: nil, writes: WebProtectorWrites(trendMicro: "1")) && kept.rebootConfirm && kept.appendedWansMode == "fo"
            && kept.actionScript == "reboot" && kept.actionWait == "120")
    // With reboot_confirm left on, turning the switch the other way asks the reboot question again.
    #expect(kept.running(.switchOff, answers: []).1 == .confirm(.reboot))
}

@Test func webProtectorSwitchWithoutQuestions() throws {
    let on = WebProtectorForm(page: protector(["wrs_enable": "0", "wrs_app_enable": "0"]))
    guard case .finished(nil, let writes) = on.running(.switchOn, answers: []).1, let submission = writes.form else { Issue.record("no submit"); return }
    // eula_confirm: TM_EULA, both enables and action_wait 15; the empty list sends empty rule lists.
    #expect(submission.value("action_wait") == "15" && submission.value("wrs_enable") == "1" && submission.value("wrs_app_enable") == "1"
            && submission.value("wrs_rulelist") == "" && writes.trendMicro == nil)
    // switch_control(0): both rule fields disabled, so not sent.
    let off = WebProtectorForm(page: protector(["wrs_rulelist": ruleA, "wrs_app_rulelist": appA]))
    let (after, step) = off.running(.switchOff, answers: [])
    guard case .finished(nil, let offWrites) = step, let offForm = offWrites.form else { Issue.record("\(step)"); return }
    #expect(!names(offForm).contains("wrs_rulelist") && offForm.value("wrs_enable") == "0" && offForm.value("action_wait") == "5" && !after.listShown)
    // Where the table could not be drawn, turning it on stops at PC_devicename and sends nothing (not even the terms' answer).
    let broken = WebProtectorForm(page: protector(["wrs_enable": "0", "TM_EULA": "0", "wrs_rulelist": ruleA + "<" + ruleA, "wrs_app_rulelist": appA]))
    guard case .stopped = broken.running(.switchOn, answers: [true]).1 else { Issue.record("not stopped"); return }
    guard case .finished(nil, let brokenOff) = broken.running(.switchOff, answers: []).1 else { Issue.record("no submit"); return }
    #expect(!names(brokenOff.form).contains("PC_devicename"))
}

@Test func webProtectorSendsTheFormThenTheTerms() async throws {
    let router = ParentalRouter(nvram: ["wrs_enable": "0", "wrs_app_enable": "0", "wrs_rulelist": "", "wrs_app_rulelist": "", "TM_EULA": "0", "TM_EULA_time": ""])
    let form = WebProtectorForm(page: protector(["wrs_enable": "0", "wrs_app_enable": "0", "TM_EULA": "0", "TM_EULA_time": ""]))
    guard case .finished(nil, let writes) = form.running(.switchOn, answers: [true]).1 else { Issue.record("no writes"); return }
    let receipt = try await client(router).applyWebProtector(writes, settle: .zero)
    let sent = await router.actions
    // The form goes into a hidden frame and the terms' answer right after it: both go out, in either order of arrival.
    #expect(Set(sent.map(\.path)) == ["start_apply.htm", "set_TM_EULA.cgi"] && sent.count == 2)
    #expect(sent.first { $0.path == "set_TM_EULA.cgi" }?.query == ["TM_EULA": "1"])
    #expect(sent.first { $0.path == "start_apply.htm" }?.body == String(decoding: RouterAuthentication.orderedForm(writes.form!.fields, .formSubmission), as: UTF8.self))
    #expect(receipt.isVerified && Set(receipt.verified) == ["wrs_enable", "wrs_app_enable", "wrs_rulelist", "wrs_app_rulelist", "TM_EULA"] && receipt.message.contains("也已发送"))
    // 拒绝 sends only the terms' answer; the router switches the filter off with it.
    let declining = ParentalRouter(nvram: ["wrs_enable": "1", "wrs_app_enable": "1", "TM_EULA": "0", "TM_EULA_time": ""])
    let declined = try await client(declining).applyWebProtector(WebProtectorWrites(trendMicro: "0"), settle: .zero)
    #expect(await declining.actions.map(\.path) == ["set_TM_EULA.cgi"] && declined.isVerified && Set(declined.verified) == ["TM_EULA", "wrs_enable", "wrs_app_enable"])
}

@Test func webProtectorRebootIsCheckedOnceTheRouterIsBack() async throws {
    let page = protector(["wrs_enable": "0", "ctf_disable": "0", "ctf_fa_mode": "2"])
    guard case .finished(nil, let writes) = WebProtectorForm(page: page).running(.switchOn, answers: [true, true]).1 else { Issue.record("no writes"); return }
    let router = ParentalRouter(nvram: ["wrs_enable": "0", "wrs_app_enable": "0", "wrs_rulelist": "", "wrs_app_rulelist": "", "TM_EULA": "1"])
    let receipt = try await client(router).applyWebProtector(writes, settle: .zero)
    #expect(!receipt.isVerified && receipt.message.contains("重新启动") && writes.form?.value("action_script") == "reboot")
    #expect(try await client(router).checkWebProtector(writes).isVerified)
    // An answer without done_committing() / no_changes… is reported as unconfirmed.
    let silent = ParentalRouter(nvram: ["wrs_enable": "1"], applyAnswer: "")
    guard case .finished(nil, let plain) = WebProtectorForm(page: protector()).running(.apply, answers: []).1 else { Issue.record("no writes"); return }
    let unclear = try await client(silent).applyWebProtector(plain, settle: .zero)
    #expect(!unclear.isVerified && unclear.message.contains("不要重复提交"))
    // A read-back that differs is named.
    let differing = ParentalRouter(nvram: [:], applyAnswer: "<script>no_changes_and_no_committing();</script>")
    let checked = try await client(differing).checkWebProtector(WebProtectorWrites(form: ParentalFormSubmission(fields: [("wrs_enable", "1"), ("TM_EULA", "1")])))
    #expect(checked.unverified == ["wrs_enable", "TM_EULA"])
}

@Test func webProtectorProblemsStopTheWrites() {
    #expect(protector().problems.isEmpty)
    #expect(protector(["ctf_fa_mode": "2'"]).problems.count == 1 && protector(["wrs_rulelist": "a\\b"]).problems.count == 1)
    #expect(protector(reboot: "").problems.count == 1)
    #expect(protector().faq?.absoluteString == "https://nw-dlcdnet.asus.com/support/forward.html?model=&type=Faq&lang=CN&kw=&num=140")
    #expect(protector().macPlaceholder == "ex: 04:42:1A:00:00:01")
}

// MARK: - 时间安排

private func parental(_ values: [String: String] = [:], support: String = #"{"MaxRule_parentctrl":16,"MaxRule_PC_DAYTIME":0,"PC_SCHED_V3":3,"bwdpi":1,"hnd":1}"#,
                      uptime: String = "Tue, 27 Oct 2026 14:05:09 +1100(1 day, 02:03:04 since boot)") -> ParentalControlPage {
    let base = ["MULTIFILTER_ALL": "1", "MULTIFILTER_ENABLE": "", "MULTIFILTER_MAC": "", "MULTIFILTER_DEVICENAME": "", "MULTIFILTER_MACFILTER_DAYTIME_V2": "",
                "MULTIFILTER_BLOCK_ALL": "0", "productid": "RT-BE88U", "firmver": "3.0.0.6", "preferred_lang": "CN", "lan_hwaddr": "04:42:1A:00:00:01", "svc_ready": "1"]
    return ParentalControlPage(nvram: encoded(base.merging(values) { _, new in new }), support: UISupport(json(support)), clients: clients, uptime: uptime)
}
private let threeDevices = ["MULTIFILTER_ENABLE": "1>2>>0", "MULTIFILTER_MAC": "\(macA)>\(macB.lowercased())>\(macC)>AA:BB:CC:DD:EE:04",
                            "MULTIFILTER_DEVICENAME": "Stored A>Stored B>Stored C>Stored D", "MULTIFILTER_MACFILTER_DAYTIME_V2": "W03E21000700<W04122000800>M17F08001200>"]

@Test func parentalListFollowsInitial() {
    let page = parental(threeDevices)
    // The empty third enable is skipped; the fourth device has no time entry (undefined); MACs are upper case.
    #expect(page.devices.map(\.mac) == [macA, macB, "AA:BB:CC:DD:EE:04"] && page.devices.map(\.enable) == ["1", "2", "0"])
    #expect(page.devices.map(\.devicename) == ["Kid Tablet", "Laptop", "Stored D"] && page.devices.map(\.offtime) == ["W03E21000700<W04122000800", "M17F08001200", nil])
    let form = ParentalControlForm(page: page)
    #expect(form.switchOn && form.contentShown && !form.blockAllOn && page.listTitle == "用户名单 (最多限制： 16)")
    #expect(page.title == "家长管理 - 时间安排" && page.switchTitle == "开启时间计划" && page.blockAllShown && page.schedulesModes && page.ruleMaximum == .number("128"))
    // V3 with hnd: four steps, no notes at all.
    #expect(page.description.steps.count == 4 && page.description.notes == nil)
    let older = parental(support: #"{"MaxRule_parentctrl":16,"PC_SCHED_V3":"0"}"#)
    // A text "0" is truthy for `if(isSupport("PC_SCHED_V3"))`, but parseInt of it is 0: V3 texts, no block-all, no modes.
    #expect(older.description.title == "此功能能够为特定设备的互联网访问设置预定时间。" && !older.blockAllShown && !older.alternateDays && older.title == "家长管理")
    let plain = parental(support: #"{"MaxRule_parentctrl":16}"#)
    #expect(plain.description.steps.count == 5 && plain.description.notes == ["默认情况下，全时段不允许互联网连接。", "请禁用 NAT 加速 以进行更精确的计划控制。"])
}

@Test func parentalProblemsWhereTheScriptCannotRun() {
    #expect(parental().problems.isEmpty)
    // MULTIFILTER_ALL goes into `if(…)` as code: empty is a syntax error.
    #expect(parental(["MULTIFILTER_ALL": ""]).problems.count == 1 && parental(["MULTIFILTER_MAC": "a'b"]).problems.count == 1)
    let broken = ParentalControlPage(nvram: EncodedNvram(encoded: ["MULTIFILTER_ALL": "1", "MULTIFILTER_DEVICENAME": "%FF"]), support: UISupport(json("{}")), clients: [], uptime: "")
    #expect(broken.problems.contains { $0.contains("decodeURIComponent") })
}

@Test func parentalAddsAsAddRowMain() {
    var form = ParentalControlForm(page: parental(["MULTIFILTER_ALL": "0"].merging(threeDevices) { _, new in new }))
    // addRow_main sets MULTIFILTER_ALL to 1 first when the stored value is not 1, and then counts the rules: a device
    // without its time entry throws.
    #expect(form.add() == .stopped("设备 AA:BB:CC:DD:EE:04 在 MULTIFILTER_MACFILTER_DAYTIME_V2 中没有对应的项（undefined），网页统计规则数时出错。") && form.multifilterAll == "1")
    var clean = ParentalControlForm(page: parental(["MULTIFILTER_ENABLE": "1", "MULTIFILTER_MAC": macA, "MULTIFILTER_DEVICENAME": "A", "MULTIFILTER_MACFILTER_DAYTIME_V2": "W03E21000700"]))
    #expect(clean.add() == .alert("栏位不能为空白"))
    clean.mac = macA.lowercased()
    #expect(clean.add() == .alert("此项已纳入列表中。"))
    clean.mac = "AA:BB"
    #expect(clean.add() == .hint && clean.macHint)
    clean.mac = macB.lowercased(); clean.newEnable = "2"
    #expect(clean.add() == .added && !clean.macHint && clean.mac.isEmpty && clean.newEnable == "1")
    #expect(clean.devices.last == ParentalDevice(enable: "2", mac: macB, devicename: "Laptop", offtime: "W03E21000700<W04122000800"))
    // MaxRule_parentctrl has no fallback; data_max is MaxRule_PC_DAYTIME unless it is `== 0`.
    var none = ParentalControlForm(page: parental(support: "{}"))
    none.mac = macA
    #expect(none.add() == .alert("本表仅允许 0 项目！"))
    var few = ParentalControlForm(page: parental(["MULTIFILTER_ENABLE": "1", "MULTIFILTER_MAC": macA, "MULTIFILTER_DEVICENAME": "A", "MULTIFILTER_MACFILTER_DAYTIME_V2": "W03E21000700<W04122000800"],
                                                 support: #"{"MaxRule_parentctrl":16,"MaxRule_PC_DAYTIME":"3"}"#))
    few.mac = macB
    #expect(few.add() == .alert("规则的最大数量为 3。\n为了添加新规则，您可以删除那些未使用的规则。"))
}

@Test func parentalSwitchAppliesOnlyWhenItWasOn() {
    var off = ParentalControlForm(page: parental(["MULTIFILTER_ALL": "0"]))
    #expect(!off.switchOn && !off.contentShown)
    #expect(off.toggleSwitch(systemTime: "x") == nil && off.switchOn && off.contentShown && off.multifilterAll == "1")
    // Back off: "0" equals the stored value, so nothing is sent.
    #expect(off.toggleSwitch(systemTime: "x") == nil && !off.contentShown && off.multifilterAll == "0")
    var on = ParentalControlForm(page: parental(threeDevices))
    let submission = on.toggleSwitch(systemTime: "Tue, Oct 27  14:05:09  2026")
    #expect(submission?.value("MULTIFILTER_ALL") == "0" && !on.contentShown)
}

@Test func parentalApplySendsTheFormInDocumentOrder() {
    var form = ParentalControlForm(page: parental(threeDevices))
    form.mac = "11:22"
    form.setEnable("0", at: 1)
    let submission = form.submission(systemTime: "Tue, Oct 27  14:05:09  2026")
    #expect(names(submission) == ["productid", "current_page", "next_page", "modified", "action_wait", "action_mode", "action_script", "firmver", "MULTIFILTER_ALL",
                                  "MULTIFILTER_ENABLE", "MULTIFILTER_MAC", "MULTIFILTER_DEVICENAME", "MULTIFILTER_MACFILTER_DAYTIME_V2", "system_time", "PC_mac"])
    // The client list's names; a missing time entry is written as "undefined".
    #expect(submission.value("MULTIFILTER_ENABLE") == "1>0>0" && submission.value("MULTIFILTER_DEVICENAME") == "Kid Tablet>Laptop>Stored D"
            && submission.value("MULTIFILTER_MACFILTER_DAYTIME_V2") == "W03E21000700<W04122000800>M17F08001200>undefined")
    let body = String(decoding: RouterAuthentication.orderedForm(submission.fields, .formSubmission), as: UTF8.self)
    #expect(body == "productid=RT-BE88U&current_page=ParentalControl.asp&next_page=&modified=0&action_wait=5&action_mode=apply&action_script=restart_firewall"
            + "&firmver=3.0.0.6&MULTIFILTER_ALL=1&MULTIFILTER_ENABLE=1%3E0%3E0&MULTIFILTER_MAC=AA%3ABB%3ACC%3ADD%3AEE%3A01%3EAA%3ABB%3ACC%3ADD%3AEE%3A02%3EAA%3ABB%3ACC%3ADD%3AEE%3A04"
            + "&MULTIFILTER_DEVICENAME=Kid+Tablet%3ELaptop%3EStored+D&MULTIFILTER_MACFILTER_DAYTIME_V2=W03E21000700%3CW04122000800%3EM17F08001200%3Eundefined"
            + "&system_time=Tue%2C+Oct+27++14%3A05%3A09++2026&PC_mac=11%3A22")
    // 全选 sets every row; a delete removes every entry of that MAC and draws the table again only once it is empty.
    form.selectAll("2")
    #expect(form.devices.allSatisfy { $0.enable == "2" })
    form.delete(at: 0)
    #expect(form.devices.count == 2 && form.mac == "11:22")
    form.delete(at: 0); form.delete(at: 0)
    #expect(form.devices.isEmpty && form.mac.isEmpty)
}

@Test func parentalApplyIsReadBack() async throws {
    var form = ParentalControlForm(page: parental(["MULTIFILTER_ENABLE": "1", "MULTIFILTER_MAC": macA, "MULTIFILTER_DEVICENAME": "A", "MULTIFILTER_MACFILTER_DAYTIME_V2": "W03E21000700"]))
    form.devices[0].enable = "2"
    let router = ParentalRouter(nvram: ["MULTIFILTER_ALL": "1", "MULTIFILTER_ENABLE": "1"])
    let receipt = try await client(router).applyParentalControl(form.submission(systemTime: "t"), settle: .zero)
    let post = try #require(await router.actions.first)
    #expect(post.path == "start_apply.htm" && post.method == "POST" && receipt.isVerified && receipt.verified.count == 5)
    #expect(await router.value("MULTIFILTER_ENABLE") == "2")
}

@Test func parentalBlockAllKeepsTheMembersOrder() async throws {
    let router = ParentalRouter(nvram: ["MULTIFILTER_BLOCK_ALL": "0"])
    let receipt = try await client(router).setBlockAllDevices(true, settle: .zero)
    let post = try #require(await router.actions.first)
    // httpApi.nvramSet: encodeURIComponent(JSON.stringify({...})) in the page's member order, no action_wait.
    #expect(post.path == "applyapp.cgi" && post.body == "%7B%22action_mode%22%3A%22apply%22%2C%22rc_service%22%3A%22restart_firewall%22%2C%22MULTIFILTER_BLOCK_ALL%22%3A%221%22%7D")
    #expect(receipt.isVerified && receipt.verified == ["MULTIFILTER_BLOCK_ALL"])
}

@Test func parentalClockAndZoneFollowTheUptimeText() throws {
    let page = parental()
    let clock = try #require(page.clock)
    #expect(ParentalControlPage.clockText(clock, elapsed: 0) == "Tue, Oct 27  14:05:09  2026" && ParentalControlPage.clockText(clock, elapsed: 61) == "Tue, Oct 27  14:06:10  2026")
    #expect(ParentalControlPage.weekday(clock, elapsed: 0) == 2)
    let sydney = try #require(TimeZone(secondsFromGMT: 39_600)), utc = try #require(TimeZone(secondsFromGMT: 0))
    #expect(!page.zoneDiffers(from: sydney) && page.zoneDiffers(from: utc))
    #expect(ParentalControlPage.clockText(parental(uptime: "garbage").clock, elapsed: 0) == "Inv, lid Da  NaN:NaN:NaN  NaN")
    #expect(parental(["svc_ready": "0"]).notSynchronised && !page.notSynchronised)
}

@Test func parentalEditorOpensAsGenLantowanTable() throws {
    let form = ParentalControlForm(page: parental(threeDevices))
    // Another device without its time entry, or this device's own, throws; so does a clock without a weekday.
    #expect(throws: ParentalSchedule.Stop.self) { try form.scheduleEditor(for: 0, weekday: 2, previous: .init()).get() }
    #expect(throws: ParentalSchedule.Stop.self) { try form.scheduleEditor(for: 2, weekday: 2, previous: .init()).get() }
    var two = ParentalControlForm(page: parental(["MULTIFILTER_ENABLE": "1>1", "MULTIFILTER_MAC": "\(macA)>\(macB)", "MULTIFILTER_DEVICENAME": "A>B",
                                                  "MULTIFILTER_MACFILTER_DAYTIME_V2": "W03E21000700<W04122000800>W17F08001200"]))
    #expect(throws: ParentalSchedule.Stop.self) { try two.scheduleEditor(for: 0, weekday: nil, previous: .init()).get() }
    // A rule whose numbers do not parse is not edited (the page would write "ll" for them after its JSON round trip).
    let broken = ParentalControlForm(page: parental(["MULTIFILTER_ENABLE": "1", "MULTIFILTER_MAC": macA, "MULTIFILTER_DEVICENAME": "A",
                                                     "MULTIFILTER_MACFILTER_DAYTIME_V2": "W03E21000700<W13EZZ000700"]))
    #expect(ParentalSchedule.unparsableRule("W03E21000700<W13EZZ000700") == "W13EZZ000700" && ParentalSchedule.unparsableRule("W03E21000700") == nil)
    #expect(throws: ParentalSchedule.Stop.self) { try broken.scheduleEditor(for: 0, weekday: 2, previous: .init()).get() }
    let schedule = try two.scheduleEditor(for: 0, weekday: 2, previous: .init()).get()
    #expect(schedule.othersRuleCount == 1 && schedule.count == 2 && schedule.today == 2 && schedule.changesModes && schedule.alternateDays)
    // 应用本页面设置 in the editor: the device's rules, the table drawn again (PC_mac emptied), the whole page sent.
    two.mac = "typed"
    let submission = two.applySchedule("W17F00000100", at: 0, systemTime: "t")
    #expect(submission.value("MULTIFILTER_MACFILTER_DAYTIME_V2") == "W17F00000100>W17F08001200" && submission.value("PC_mac") == "")
}

// MARK: - 时间编辑器

private func schedule(_ offtime: String, modes: Bool = true, alternate: Bool = true, others: Int = 0, maximum: OrderedJSON = .number("128"),
                      carry: ParentalSchedule.Carry = .init()) -> ParentalSchedule {
    ParentalSchedule(offtime: offtime, changesModes: modes, alternateDays: alternate, othersRuleCount: others, maximum: maximum, today: 1, carry: carry)
}

@Test func scheduleReadsAndSortsAsPCInitData() {
    // 12-character rules only; the groups by mask, the ids from 100, and the cards drawn sorted.
    let s = schedule("M11512001300<M07F08001000<x<M13E09001700<M00A06000700<M1410A001100")
    #expect(s.mode == "M" && s.modeText == "在线计划" && s.headerText == "在线计划" && s.currentID == 105)
    #expect(s.groups[0].map(\.id) == ["1017F08001000"] && s.groups[1].map(\.id) == ["1023E09001700"] && s.groups[2].map(\.id) == ["104410A001100"])
    // Other: 0x0A (MON / WED) sorts before 0x15 (SUN / TUE / THU); "0A" parses as 0 for the start hour of the weekend rule.
    #expect(s.groups[3].map(\.id) == ["1030A06000700", "1001512001300"])
    let cards = s.cards
    #expect(cards.map(\.title) == ["每天", "工作日", "周末", "一 / 三", "日 / 二 / 四"] && cards.map(\.start) == ["08:00", "09:00", "00:00", "06:00", "12:00"])
    #expect(cards.map(\.on) == [false, true, true, false, true])
    #expect(s.offtime == "M07F08001000<M13E09001700<M14100001100<M00A06000700<M11512001300")
    // Without modes the letter is always W, and the page's globals carry over.
    var carried = ParentalSchedule.Carry(); carried.text = "在线计划"
    let plain = schedule("M13E09001700", modes: false, carry: carried)
    #expect(plain.mode == "W" && plain.offtime == "W13E09001700" && plain.headerText == "在线计划")
}

@Test func scheduleCardsHideRepeatedTitles() {
    let s = schedule("W13E08000900<W13E10001100<W10A08000900<W10A10001100<W11408000900")
    #expect(s.cards.map(\.title) == ["工作日", nil, "一 / 三", nil, "二 / 四"])
}

@Test func scheduleEditorBlurFollowsTheInputs() {
    var editor = schedule("", alternate: false).newRuleEditor
    #expect(editor.texts == ["08", "00", "12", "00"] && editor.days == [false, true, false, false, false, false, false] && editor.title == "离线计划")
    editor.texts[0] = ""
    editor.blur(.startHour)
    #expect(editor.hint == "* 栏位不能为空白" && editor.errorField == .startHour && !editor.isEnabled(.endHour) && editor.isEnabled(.startHour))
    editor.texts[0] = "25"; editor.blur(.startHour)
    #expect(editor.hint == "* 不正确的时间格式。")
    editor.texts[0] = "13"; editor.blur(.startHour)
    #expect(editor.hint == "* 您所设置的开始时间晚于结束时间。")
    editor.texts[0] = "12"; editor.blur(.startHour)
    #expect(editor.hint == "* Please enter different start and end time.")
    editor.texts[0] = "7"; editor.blur(.startHour)
    #expect(editor.hint == nil && editor.errorField == nil && editor.texts[0] == "07")
    // 24 as a start becomes 00; 00:00–00:00 becomes 00:00–24:00; an end past 24:00 has its hour set to 00.
    editor.texts = ["24", "00", "00", "00"]; editor.blur(.startHour)
    #expect(editor.texts == ["00", "00", "24", "00"] && editor.hint == nil)
    var alternate = schedule("").newRuleEditor
    alternate.texts = ["21", "00", "24", "30"]; alternate.blur(.endMinute)
    #expect(alternate.texts == ["21", "00", "00", "30"] && alternate.hint == nil)
    // A list option clears the hint of its own input, then blurs it.
    editor.texts[1] = "61"; editor.blur(.startMinute)
    #expect(editor.errorField == .startMinute)
    editor.choose(45, for: .startMinute)
    #expect(editor.texts[1] == "45" && editor.hint == nil && ScheduleRuleEditor.options(.endMinute) == [0, 15, 30, 45, 59])
    editor.toggleAllDay()
    #expect(editor.allDay && editor.texts == ["00", "00", "24", "00"] && !editor.isEnabled(.startHour))
}

@Test func scheduleSavesAsTheEditorsDoneButton() {
    var s = schedule("W13E08000900", modes: false, alternate: false)
    // A hint showing (three lists off) fails; so does a start not before the end without alternate days.
    var bad = s.newRuleEditor
    bad.texts[0] = ""; bad.blur(.startHour)
    #expect(s.save(bad) == "格式不正确。 请再次检查并重新输入。")
    var late = s.newRuleEditor
    late.texts = ["21", "00", "07", "00"]
    #expect(s.save(late) == "格式不正确。 请再次检查并重新输入。")
    var noDay = s.newRuleEditor
    noDay.toggleDay(1)
    #expect(s.save(noDay) == "Week field is blank.")
    // A new rule: enabled, id from PC_current_id, the mask and the times.
    var added = s.newRuleEditor
    added.toggleDay(0)
    #expect(s.save(added) == nil && s.groups[3].map(\.id) == ["101030800" + "1200"] && s.currentID == 102 && s.groups[3][0].enable == 1)
    // Editing keeps the id and the enable and moves the rule to its new group; 全天 is legal.
    s.toggle(s.cards[0])
    var edited = s.editor(s.cards[0])
    edited.toggleAllDay()
    for day in 0..<7 where !edited.days[day] { edited.toggleDay(day) }
    #expect(s.save(edited) == nil && s.groups[1].isEmpty && s.groups[0].map(\.id) == ["1003E08000900"] && s.groups[0][0].enable == 0)
    #expect(s.offtime == "W07F00002400<W10308001200")
    // With alternate days, 21:00–07:00 is kept as it is.
    var night = schedule("", alternate: true)
    var overnight = night.newRuleEditor
    overnight.texts = ["21", "00", "07", "00"]
    #expect(night.save(overnight) == nil && night.offtime == "W10221000700")
}

@Test func scheduleClearAllModesAndApplyQuestion() {
    var s = schedule("M13E17002100<M14116002200")
    #expect(!s.asksBeforeApply)
    s.toggle(s.cards[0]); s.toggle(s.cards[1])
    // An online schedule with rules, none on, asks before applying.
    #expect(s.asksBeforeApply)
    // 全部清除 resets the mode to 离线计划 (the header keeps 在线计划).
    s.clearAll()
    #expect(s.count == 0 && s.mode == "W" && s.modeText == "离线计划" && s.headerText == "在线计划" && s.offtime == "" && !s.asksBeforeApply)
    // Another mode resets to its default rules and draws the editor again.
    s.changeMode("M")
    #expect(s.offtime == "M13E17002100<M14116002200" && s.headerText == "在线计划" && !s.overview)
    s.changeMode("M")
    #expect(s.count == 2)
    s.delete(s.cards[0])
    #expect(s.offtime == "M14116002200")
    // The list is full once the other devices' rules, these and one more pass data_max.
    #expect(schedule("W13E08000900", others: 127).isFull && !schedule("W13E08000900", others: 126).isFull)
    #expect(schedule("", maximum: .string("1")).fullAlert == "规则的最大数量为 1。\n为了添加新规则，您可以删除那些未使用的规则。")
}

@Test func scheduleOverviewSplitsAtMidnight() {
    // Monday and Saturday 21:00–07:00: each day to 24:00, the next day from 00:00 (Saturday wraps to Sunday); disabled dimmed.
    let s = schedule("W14221000700<W00209001000")
    let bars = s.bars
    // The cards' order: the Monday-only rule (mask 2) before Monday and Saturday (mask 66).
    #expect(bars[1] == [.init(start: 540, end: 600, disabled: true), .init(start: 1260, end: 1440, disabled: false)])
    #expect(bars[2] == [.init(start: 0, end: 420, disabled: false)] && bars[6] == [.init(start: 1260, end: 1440, disabled: false)]
            && bars[0] == [.init(start: 0, end: 420, disabled: false)])
}

// MARK: - Menu and reads

@Test func parentalPagesHaveNativeHomes() {
    #expect(WebMenuCatalog.location(of: .webProtector) == WebLocation(menu: "menu_ParentalControl", page: "AiProtection_WebProtector.asp", part: "main"))
    #expect(WebMenuCatalog.location(of: .parentalControl) == WebLocation(menu: "menu_ParentalControl", page: "ParentalControl.asp", part: "main"))
}

@Test func parentalPagesReadWhatThePagesRead() async throws {
    let router = ParentalRouter(nvram: ["wrs_rulelist": ruleA, "wrs_app_rulelist": appA, "wrs_enable": "1", "productid": "RT-BE88U", "lan_hwaddr": "04:42:1A:00:00:01",
                                        "MULTIFILTER_ALL": "1", "MULTIFILTER_ENABLE": "1", "MULTIFILTER_MAC": macA, "MULTIFILTER_DEVICENAME": "孩子的平板",
                                        "MULTIFILTER_MACFILTER_DAYTIME_V2": "W03E21000700"],
                                support: ["MaxRule_bwdpi_wrs": 16, "PC_SCHED_V3": 3, "bwdpi": 1],
                                hooks: ["get_default_reboot_time": "150", "bwdpi_engine_status": #"{"DpiEngine":"1"}"#, "get_operation_mode": "\"rt\"",
                                        "uptime": "\"Tue, 27 Oct 2026 14:05:09 +1100(1 day since boot)\""])
    let protectorPage = try await client(router).webProtectorPage()
    #expect(protectorPage.rebootTime == "150" && protectorPage.operationMode == "rt" && protectorPage.initialFilter == "1>\(macA)>1,0,0>0,1,0,0,0>0,0>0,0,0")
    let control = try await client(router).parentalControlPage()
    #expect(control.devices.first?.devicename == "孩子的平板" && control.clock != nil && control.support.integer("PC_SCHED_V3") == 3)
    // Nothing above writes.
    #expect(await router.actions.isEmpty)
}
