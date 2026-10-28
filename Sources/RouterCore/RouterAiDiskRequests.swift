import Foundation

// AiDisk 向导发出的请求：进入第三步时载入 Aidisk-3.asp（服务器借此清掉 DDNS 返回码，属有副作用的请求）、华硕 DDNS 注册
// （start_apply.htm）与注册结果的读取（/ajax_ddnscode.asp），以及第四步“保存”按网页先后发出的请求链：重置账户、创建 Family、
// Family 全部文件夹只读、切换 FTP 共享方式、开启 FTP、最后的 DDNS 开关。每个都是网页的普通表单（application/x-www-form-urlencoded，
// 字段按文档顺序），链中每一步要等路由器写回成功回调才发送下一步，之后重新读取核对。行号同 RouterAiDisk.swift。

// MARK: - Requests

public struct AiDiskField: Sendable, Equatable {
    public let name: String
    public let value: String
    public init(_ name: String, _ value: String) { self.name = name; self.value = value }
}

/// One form the wizard submits: where, and its named controls in document order (every control is sent; none is disabled
/// on these paths).
public struct AiDiskRequest: Sendable, Equatable {
    public enum Step: Sendable, Equatable {
        /// Aidisk-2's 下一步 or Aidisk-4's 上一步 loading Aidisk-3.asp.
        case openDDNS
        case registerDDNS
        case initialAccount, createAccount, allFolderPermission
        /// switch_share_mode.asp with mode "share" or "account".
        case shareMode(String)
        case ftpOn
        /// The last form, ddnsForm.
        case ddnsSwitch
    }
    public let step: Step
    /// Below the router's root, e.g. "aidisk/initial_account.asp".
    public let path: String
    public let fields: [AiDiskField]

    init(_ step: Step, path: String, fields: [AiDiskField]) { self.step = step; self.path = path; self.fields = fields }

    /// The browser's form encoding (only alphanumerics and `*-._` as they are, space as "+").
    public var body: Data { RouterAuthentication.orderedForm(fields.map { ($0.name, $0.value) }, .formSubmission) }
    public func value(_ name: String) -> String? { fields.first { $0.name == name }?.value }

    /// The two hooks the step's ej handler writes with insert_hook_func: success, failure.
    var hooks: (success: String, failure: String)? {
        switch step {
        case .initialAccount: ("initial_account_success", "initial_account_error")                      // web.c:29341, 29417
        case .createAccount: ("create_account_success", "create_account_error")                         // web.c:29425, 29461
        case .allFolderPermission: ("set_account_all_folder_permission_success", "set_account_all_folder_permission_error") // web.c:29024, 29110
        case .shareMode: ("set_share_mode_success", "set_share_mode_error")                             // web.c:29843, 29949
        case .ftpOn: ("parent.resultOfSwitchAppStatus", "set_AiDisk_status_error")                      // web.c:30068, 30149
        case .openDDNS, .registerDDNS, .ddnsSwitch: nil
        }
    }

    /// What the router did, as the step's answer tells it.
    enum Answer: Equatable { case succeeded, failed(String), unknown }

    /// insert_hook_func (web.c:893–907) writes "<script>\n" NAME "(" PARAM ");\n</script>\n" into the wrapper page; the
    /// wrapper's own function definitions do not have that form. start_apply.htm answers with update_variables' two calls
    /// (web.c:5954–5962), after which the action_script runs either way.
    func answer(_ text: String) -> Answer {
        if path == "start_apply.htm" {
            return text.contains("<script>done_committing();</script>") || text.contains("<script>no_changes_and_no_committing();</script>") ? .succeeded : .unknown
        }
        guard let hooks else { return .unknown }
        let names = [hooks.success, hooks.failure].map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        guard let call = RouterParser.captures("<script>\n(" + names + #")\(([^\n]*)\);\n</script>"#, in: text).first else { return .unknown }
        return call[0] == hooks.success ? .succeeded : .failed(call[1])
    }

    /// What the step does, for confirmation and reports.
    public var summary: String {
        switch step {
        case .openDDNS: "载入第三步（/aidisk/Aidisk-3.asp）"
        case .registerDDNS: "华硕 DDNS 注册（start_apply.htm，aidisk_asusddns_register）"
        case .initialAccount: "重置账户与权限（/aidisk/initial_account.asp）"
        case .createAccount: "创建帐户 \(value("account") ?? "")（/aidisk/create_account.asp）"
        case .allFolderPermission: "\(value("account") ?? "") 的全部文件夹权限设为 \(value("permission") ?? "")（/aidisk/set_account_all_folder_permission.asp）"
        case .shareMode(let mode): "FTP 共享方式改为 \(mode)（/aidisk/switch_share_mode.asp）"
        case .ftpOn: "开启 FTP（/aidisk/switch_AiDisk_app.asp）"
        case .ddnsSwitch: "DDNS 开关 ddns_enable_x=\(value("ddns_enable_x") ?? "")（start_apply.htm）"
        }
    }
}

/// aidisk.asp's applyForm (251–261): its nine hidden fields in document order.
struct AiDiskApplyForm {
    var dummyShareway: String
    var account = "", password = "", protocolName = "", mode = "", pool = "", folder = "", permission = "", flag = "on"
    var fields: [AiDiskField] {
        [AiDiskField("dummyShareway", dummyShareway), AiDiskField("account", account), AiDiskField("password", password),
         AiDiskField("protocol", protocolName), AiDiskField("mode", mode), AiDiskField("pool", pool), AiDiskField("folder", folder),
         AiDiskField("permission", permission), AiDiskField("flag", flag)]
    }
}

extension AiDiskWizard {
    /// Aidisk-4's 保存 (clickevent 128–139) and aidisk.asp's callbacks that carry it on (85–230): each form is sent with
    /// what earlier steps left in applyForm.
    /// - 0: switchShareMode("ftp", "share") (190–201).
    /// - otherwise initialAccount (85–89); its callback (91–97) creates Family for 1 (99–111) and sets Family's permission
    ///   on every folder (113–115, 172–184), which first empties dummyShareway (175); for any other choice
    ///   submitChangeAllFolderPermission(admin, "3") finds dummyShareway not "1" and sends no permission request (185–187).
    ///   Either way switchShareMode("ftp", "account") follows — after Family's permission through the wrapper page's
    ///   callback, which is not in the source at hand; with dummyShareway now "" the functions that can be called there go
    ///   on to it (152–169, 185–187).
    /// - then switchAppStatus("ftp", "on") (203–215) and switchDDNS's ddnsForm (217–230, 263–269): current_page is
    ///   parameterForm's next_page "/aidisk.asp" (Aidisk-4.asp:132), action_script and action_wait stay empty.
    public var savingChain: [AiDiskRequest] {
        var form = AiDiskApplyForm(dummyShareway: dummyShareway)
        var chain: [AiDiskRequest] = []
        func switchShareMode(_ mode: String) {
            form.account = ""; form.pool = ""; form.folder = ""; form.permission = ""
            form.protocolName = "ftp"; form.mode = mode
            chain.append(AiDiskRequest(.shareMode(mode), path: "aidisk/switch_share_mode.asp", fields: form.fields))
        }
        if dummyShareway == "0" {
            switchShareMode("share")
        } else {
            chain.append(AiDiskRequest(.initialAccount, path: "aidisk/initial_account.asp", fields: form.fields))
            if form.dummyShareway == "1" {
                form.protocolName = ""; form.pool = ""; form.folder = ""; form.permission = ""
                form.account = account1; form.password = passwd1
                chain.append(AiDiskRequest(.createAccount, path: "aidisk/create_account.asp", fields: form.fields))
                form.dummyShareway = ""; form.password = ""
                form.account = account1; form.protocolName = "ftp"; form.permission = permission1; form.flag = "aidisk_wizard"
                chain.append(AiDiskRequest(.allFolderPermission, path: "aidisk/set_account_all_folder_permission.asp", fields: form.fields))
            }
            switchShareMode("account")
        }
        form.mode = ""; form.protocolName = "ftp"; form.flag = "on"
        chain.append(AiDiskRequest(.ftpOn, path: "aidisk/switch_AiDisk_app.asp", fields: form.fields))
        chain.append(AiDiskRequest(.ddnsSwitch, path: "start_apply.htm", fields: [
            AiDiskField("current_page", "/aidisk.asp"), AiDiskField("action_mode", "apply"), AiDiskField("action_script", ""),
            AiDiskField("action_wait", ""), AiDiskField("ddns_enable_x", ddnsEnable)
        ]))
        return chain
    }

    /// What the router keeps once the chain went through, as its handlers write it: set_share_mode stores dummyShareway
    /// ("" as "0", web.c:29845–29849) and st_ftp_mode 1 for share, 2 for account (29864–29905); set_AiDisk_status sets
    /// enable_ftp 1 (30097–30100); start_apply.htm keeps ddns_enable_x. initial_account empties the account list and adds
    /// the administrator again (29343–29393), create_account adds Family, so get_all_accounts then names these.
    public func expectation(adminName: String) -> AiDiskExpectation {
        let chain = savingChain
        var values: [AiDiskField] = []
        for request in chain {
            guard case .shareMode(let mode) = request.step else { continue }
            let stored = request.value("dummyShareway") ?? ""
            values += [AiDiskField("dummyShareway", stored.isEmpty ? "0" : stored), AiDiskField("st_ftp_mode", mode == "share" ? "1" : "2")]
            break
        }
        values += [AiDiskField("enable_ftp", "1"), AiDiskField("ddns_enable_x", ddnsEnable)]
        var accounts: [String]?
        if chain.contains(where: { $0.step == .initialAccount }) {
            accounts = [adminName] + chain.filter { $0.step == .createAccount }.compactMap { $0.value("account") }
        }
        // set_account_all_folder_permission gives the account that right on every folder of every mounted partition
        // (web.c:29068–29085); the pools themselves are not touched.
        let folders = chain.last { $0.step == .allFolderPermission && $0.value("protocol") == "ftp" }
            .map { AiDiskFolderRight(account: $0.value("account") ?? "", right: Int($0.value("permission") ?? "") ?? -1) }
        return AiDiskExpectation(values: values, accounts: accounts, ftpFolders: folders)
    }
}

public struct AiDiskExpectation: Sendable, Equatable {
    public let values: [AiDiskField]
    /// The account names after a reset; nil when the chain does not touch accounts.
    public let accounts: [String]?
    /// The FTP right every folder should have for an account; nil when the chain sets none.
    public var ftpFolders: AiDiskFolderRight? = nil
}

/// Reading back the rights set_account_all_folder_permission gave: the folders the same page lists in
/// get_sharedfolder_in_pool (its get_AiDisk_status, Advanced_AiDisk_ftp.asp:26) against the account's entries in
/// get_permissions_of_account (27). A partition whose folders could not be listed writes no folder entries in either
/// (28455–28465, 28789–28796), which cannot be told from an empty one, so a partition without folders leaves the rights
/// unverified; so does a partition missing on either side or with a different number of entries.
enum AiDiskFolderCheck: Equatable {
    case matched
    case differs(String)

    static func compare(_ expected: AiDiskFolderRight, page: String) -> AiDiskFolderCheck {
        // Folder names go into the page raw (web.c:28474) before the rights (Advanced_AiDisk_ftp.asp:26–27), so text that
        // looks like either function could come from a name: the page's script has to parse, each function has to be there
        // once, and the rights have to start where the folder list ends (the template has a line break between them).
        let rightsHeader = "function get_account_permissions_in_pool(account, pool){"
        guard let script = AiDiskScript.element(containing: rightsHeader, in: page), AiDiskScript.syntaxError(script) == nil else {
            return .differs("FTP 共享页的脚本无法解析，权限无法确定")
        }
        guard page.components(separatedBy: rightsHeader).count == 2,
              page.components(separatedBy: "function get_sharedfolder_in_pool(poolName){").count == 2 else {
            return .differs("FTP 共享页里不止一处像文件夹列表或权限函数的文字（可能来自文件夹名），权限无法确定")
        }
        guard case .success(let shared)? = AiDiskSharedFolders.parse(page) else { return .differs("FTP 共享页的文件夹列表无法读取") }
        guard shared.rest.drop(while: { $0 == "\n" }).hasPrefix(rightsHeader) else {
            return .differs("FTP 共享页的文件夹列表后面不是权限函数（可能有文件夹名改变了脚本），权限无法确定")
        }
        guard let rights = aiDiskFolderRights(of: expected.account, in: page) else { return .differs("FTP 共享页没有这个帐户完整的权限") }
        var wrong = 0, missing: [String] = [], counts: [String] = [], empty: [String] = []
        for pool in shared.pools {
            guard let found = rights[pool.device] else { missing.append(pool.device); continue }
            // A right read back that is not the one sent counts wherever it is.
            wrong += found.filter { $0 != expected.right }.count
            if found.count != pool.folders.count { counts.append(pool.device) }
            if pool.folders.isEmpty { empty.append(pool.device) }
        }
        let extra = rights.keys.filter { device in !shared.pools.contains { $0.device == device } }.sorted()
        if wrong > 0 { return .differs("\(wrong) 个文件夹读回不是 \(expected.right)") }
        if !missing.isEmpty { return .differs("分区 " + missing.joined(separator: "、") + " 没有这个帐户的权限") }
        if !counts.isEmpty || !extra.isEmpty { return .differs("分区 " + (counts + extra).joined(separator: "、") + " 的文件夹与权限条目对不上") }
        if shared.pools.isEmpty { return .differs("没有读到任何分区，无法核对") }
        if !empty.isEmpty { return .differs("分区 " + empty.joined(separator: "、") + " 没有列出文件夹，无法区分确实为空与列举失败") }
        return .matched
    }
}

public struct AiDiskFolderRight: Sendable, Equatable {
    public let account: String
    public let right: Int
}

/// get_permissions_of_account as Advanced_AiDisk_ftp.asp has the server write it (web.c:28865–28920, drawn at
/// 28700–28862): `    else if(account == "NAME"){`, then for each mounted partition `[else ]        if(pool == "DEVICE"){`,
/// `            return [["", cifs, ftp]` with `,\n                    ["FOLDER", cifs, ftp]` for each folder (names
/// HTML-encoded, 28828–28833) and `];`, `        }`. The FTP rights of `account`'s folders in each partition, or nil when the
/// function has no part for the account or a part does not follow this layout.
func aiDiskFolderRights(of account: String, in page: String) -> [String: [Int]]? {
    guard let start = page.range(of: "function get_account_permissions_in_pool(account, pool){"),
          let section = page.range(of: "if(account == \"" + account + "\"){\n", range: start.upperBound..<page.endIndex) else { return nil }
    let entry = #"\["([^"\n]*)", (-?\d+), (-?\d+)(?:, -?\d+)?\]"#
    let block = ##"^(?:else )?        if\(pool == "([^"\n]*)"\)\{\n            return \[(\["", -?\d+, -?\d+(?:, -?\d+)?\](?:,\n                    \["[^"\n]*", -?\d+, -?\d+(?:, -?\d+)?\])*)\];\n        \}\n"##
    guard let re = try? NSRegularExpression(pattern: block, options: [.anchorsMatchLines]) else { return nil }
    var rights: [String: [Int]] = [:]
    var rest = String(page[section.upperBound...])
    while !rest.hasPrefix("    }\n") {
        guard let match = re.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)), match.range.location == 0,
              let device = Range(match.range(at: 1), in: rest), let list = Range(match.range(at: 2), in: rest),
              let whole = Range(match.range, in: rest) else { return nil }
        let entries = RouterParser.captures(entry, in: String(rest[list])).dropFirst()
        rights[String(rest[device])] = entries.compactMap { $0.count == 3 ? Int($0[2]) : nil }
        rest = String(rest[whole.upperBound...])
    }
    return rights
}

/// The outcome of 保存: how far the chain went and what reading back found.
public struct AiDiskSaveReceipt: Sendable {
    /// The requests the router answered with success, in order.
    public let confirmed: Int
    public let total: Int
    public let receipt: ApplyReceipt
}

// MARK: - Router

extension RouterClient {
    /// aidisk.asp and its welcome page as they open: get_AiDisk_status from the page itself (no other read tells a missing
    /// st_ftp_force_mode from an empty one), then Aidisk-1's values and disks. A router without the page has no AiDisk.
    public func aiDiskPage() async throws -> AiDiskPage {
        let status: AiDiskStatus?
        do { status = AiDiskStatus.parse(try await readManagementDocument("aidisk.asp", timeout: 30)) }
        catch RouterError.httpStatus(404) { status = nil }
        return try await aiDiskWelcome(status: status)
    }

    /// Aidisk-1.asp's own reads (16–22, 30–35) with the parent's status kept, as when the wizard goes back to it.
    public func aiDiskWelcome(status: AiDiskStatus?) async throws -> AiDiskPage {
        let values = try await readSettings(AiDiskPage.keys)
        var disks: AiDiskDisks?
        do { disks = AiDiskDisks.parse(try await readManagementDocument("require/modules/diskList.js", timeout: 30)) }
        catch RouterError.authenticationRequired { throw RouterError.authenticationRequired }
        catch is CancellationError { throw CancellationError() }
        catch { disks = nil }
        return AiDiskPage(status: status, values: values, disks: disks)
    }

    /// Aidisk-2.asp's reads (26, 37, 58, 74) and state.js's territory code; the page itself only renders them.
    public func aiDiskShareStep() async throws -> AiDiskShareStep {
        AiDiskShareStep(values: try await readSettings(AiDiskShareStep.keys))
    }

    /// Loads Aidisk-3.asp as the page does on its way to the third step: a POST of the previous step's form (none from
    /// Aidisk-4's redirectForm). Writing the page runs nvram_get_ddns, which clears ddns_return_code unless it is
    /// ddns_query (Aidisk-3.asp:20, web.c:1482–1485); the answer gives the code as it was before.
    public func openAiDiskDDNSStep(_ opening: AiDiskRequest) async throws -> AiDiskDDNSStep {
        guard opening.step == .openDDNS else { throw RouterError.validation("请求与第三步不符") }
        try acquireMutation(); defer { releaseMutation() }
        let data = try await request(opening.path, method: "POST", body: opening.body, contentType: "application/x-www-form-urlencoded", timeout: 30)
        guard let step = AiDiskDDNSStep.parse(String(decoding: data, as: UTF8.self)) else { throw RouterError.invalidResponse("AiDisk 第三步页面") }
        return step
    }

    /// The registration form to start_apply.htm. update_variables writes the DDNS name and server and runs
    /// aidisk_asusddns_register whether or not a value changed (web.c:5954–5962, 6021–6082).
    public func registerAiDiskDDNS(_ registration: AiDiskRequest) async throws {
        guard registration.step == .registerDDNS else { throw RouterError.validation("请求与 DDNS 注册不符") }
        try acquireMutation(); defer { releaseMutation() }
        let data = try await request(registration.path, method: "POST", body: registration.body, contentType: "application/x-www-form-urlencoded", timeout: 60)
        guard registration.answer(String(decoding: data, as: UTF8.self)) == .succeeded else {
            throw RouterError.submissionUncertain("路由器没有确认接收注册请求，注册可能已经开始。请稍后重新读取核对，不要重复提交。")
        }
    }

    /// checkDDNSReturnCode's read (Aidisk-3.asp:191–198): /ajax_ddnscode.asp as jQuery fetches a script, with its
    /// cache-busting "_" parameter. nil when the answer sets no ddns_return_code.
    public func aiDiskDDNSCode(stamp: Int) async throws -> String? {
        let data = try await request("ajax_ddnscode.asp", query: [.init(name: "_", value: String(stamp))], timeout: 12)
        return AiDiskDDNSStep.ajaxCode(String(decoding: data, as: UTF8.self))
    }

    /// Aidisk-4.asp's reads (17–22, 80, 181): enable_ftp, the DDNS name and wanlink_ipaddr().
    public func aiDiskFinishStep() async throws -> AiDiskFinishStep {
        let values = try await readSettings(AiDiskFinishStep.keys)
        let wan = try OrderedJSON(data: try await request("appGet.cgi", query: [.init(name: "hook", value: "wanlink(ipaddr)")]))["wanlink-ipaddr"]
        return AiDiskFinishStep(values: values, wanIP: wan?.text ?? "")
    }

    /// get_all_accounts (web.c:28321–28383) through appGet: the names, as char_to_ascii wrote them on a USB build.
    func aiDiskAccounts() async throws -> [String] {
        guard case .array(let items)? = try await orderedHook("get_all_accounts") else { throw RouterError.invalidResponse("帐户列表") }
        return items.map { item in let text = item.text ?? ""; return text.removingPercentEncoding ?? text }
    }

    /// 保存: the chain in turn, each request only after the router wrote the success hook of the one before, as the
    /// page's callbacks go on. A failure hook, an answer without either hook, or a request whose answer is lost stops it
    /// there; what went through is not taken back. After the last one the router is read again and compared.
    public func saveAiDisk(_ wizard: AiDiskWizard, adminName: String) async throws -> AiDiskSaveReceipt {
        let chain = wizard.savingChain
        try acquireMutation(); defer { releaseMutation() }
        func stopped(_ index: Int, _ reason: String) -> AiDiskSaveReceipt {
            let rest = chain.count - index - 1
            let after = rest > 0 ? "网页在这种情况下不会继续，后面 \(rest) 个请求没有发送。" : ""
            let done = index > 0 ? "前 \(index) 步已完成，不会撤销。" : ""
            return AiDiskSaveReceipt(confirmed: index, total: chain.count, receipt: ApplyReceipt(
                verified: [], unverified: [chain[index].summary],
                message: "第 \(index + 1) 步（\(chain[index].summary)）" + reason + after + done + "请稍后重新读取核对，不要重复提交。"))
        }
        for (index, step) in chain.enumerated() {
            let data: Data
            do {
                data = try await request(step.path, method: "POST", body: step.body, contentType: "application/x-www-form-urlencoded", timeout: 120)
            } catch RouterError.submissionUncertain {
                return stopped(index, "发送后连接中断或回应异常，结果尚未确认。")
            } catch RouterError.httpStatus(let code) where index > 0 {
                return stopped(index, "路由器返回 HTTP \(code)，这一步没有执行。")
            } catch where index > 0 {
                return stopped(index, "没有发出（\(error.localizedDescription)）。")
            }
            switch step.answer(String(decoding: data, as: UTF8.self)) {
            case .succeeded: continue
            case .failed(let code):
                return stopped(index, "路由器返回错误 \(code)（网页错误提示所用的 alert_msg 文字不在固件资料中）。")
            case .unknown:
                return stopped(index, "的回应里没有成功或失败的回调，无法确认结果。")
            }
        }
        let expectation = wizard.expectation(adminName: adminName)
        let names = expectation.values.map(\.name)
        do {
            try await Task.sleep(for: .seconds(1))
            let after = try await readSettings(names)
            var verified = expectation.values.filter { after[$0.name] == $0.value }.map(\.name)
            var unverified = expectation.values.filter { after[$0.name] != $0.value }.map { "\($0.name)（读回 \(after[$0.name] ?? "")，应为 \($0.value)）" }
            if let expected = expectation.accounts {
                let accounts = try await aiDiskAccounts()
                if Set(accounts) == Set(expected) { verified.append("帐户列表") }
                else { unverified.append("帐户列表（读回 " + (accounts.isEmpty ? "无" : accounts.joined(separator: "、")) + "，应为 " + expected.joined(separator: "、") + "）") }
            }
            if let folders = expectation.ftpFolders {
                // The FTP share page is where the web shows these rights; reading it runs only output functions.
                let page = try await readManagementDocument("Advanced_AiDisk_ftp.asp", timeout: 30)
                let name = "\(folders.account) 的 FTP 文件夹权限"
                switch AiDiskFolderCheck.compare(folders, page: page) {
                case .matched: verified.append(name)
                case .differs(let reason): unverified.append(name + "（" + reason + "）")
                }
            }
            let message = unverified.isEmpty
                ? "已按网页的顺序发送 \(chain.count) 个请求，路由器逐一确认；重新读取后 " + verified.joined(separator: "、") + " 都与预期一致。"
                : "已按网页的顺序发送 \(chain.count) 个请求，路由器逐一确认；但重新读取时 " + unverified.joined(separator: "；") + "。请重新读取并检查。"
            return AiDiskSaveReceipt(confirmed: chain.count, total: chain.count, receipt: ApplyReceipt(verified: verified, unverified: unverified, message: message))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return AiDiskSaveReceipt(confirmed: chain.count, total: chain.count, receipt: ApplyReceipt(
                verified: [], unverified: names, message: "已按网页的顺序发送 \(chain.count) 个请求，路由器逐一确认；重新读取没有完成，结果仍待核对。请稍后重新读取，不要重复提交。"))
        }
    }
}
