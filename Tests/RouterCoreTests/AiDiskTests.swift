import Foundation
import Testing
@testable import RouterCore

// USB 相关应用 › AiDisk（aidisk.asp 与 aidisk/Aidisk-1～4.asp）：父页与磁盘列表的读取、各步的显示与校验，以及每个写入的完整请求、
// 先后与读回。所有数值均为虚构。

// MARK: - A router for this page

/// nvram_char_to_ascii's answer: every byte but ASCII letters and digits as %XX.
private func ascii(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")) ?? value
}
private func form(_ body: String) -> [(String, String)] {
    body.isEmpty ? [] : body.split(separator: "&", omittingEmptySubsequences: false).map { pair in
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map {
            String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
        }
        return (parts[0], parts.count > 1 ? parts[1] : "")
    }
}
private func atoi(_ text: String?) -> Int { Int(String((text ?? "").prefix { $0.isNumber })) ?? 0 }

/// The server side of the wizard as web.c writes it: aidisk.asp's get_AiDisk_status, diskList.js, Aidisk-3.asp (clearing the
/// return code after writing it), the five ej handlers behind the wrapper pages with insert_hook_func's answer, start_apply.htm
/// and /ajax_ddnscode.asp. Records every request with its raw body and content type.
private actor AiDiskRouter: RouterTransport {
    struct Record { let method: String; let path: String; let query: [String: String]; let body: String; let contentType: String? }
    var nvram: [String: String]
    var accounts: [String]
    let disks: String?
    let usb: Bool
    /// The answers /ajax_ddnscode.asp gives in turn after a registration; the last one stays.
    var codes: [String]
    /// A wrapper page's whole answer, instead of what its handler writes.
    var answers: [String: String]
    /// A path whose request is lost after it arrives.
    var dropped: String?
    /// Fail every appGet read after the chain's last request (the read-back).
    var failReadBack = false
    /// Keep st_ftp_mode as it was (a handler that did not do its job).
    var ignoresShareMode = false
    /// The FTP right each account has on every folder (the one folder "Share" of sda1); the administrator has 3.
    var folderRights: [String: Int] = [:]
    /// Answer set_account_all_folder_permission with success without changing the rights.
    var ignoresPermission = false
    private(set) var records: [Record] = []

    init(nvram: [String: String], accounts: [String] = ["admin"], disks: String? = diskScript(), usb: Bool = true, codes: [String] = []) {
        self.nvram = nvram; self.accounts = accounts; self.disks = disks; self.usb = usb; self.codes = codes; self.answers = [:]
    }
    func answer(_ path: String, with text: String) { answers[path] = text }
    func drop(_ path: String) { dropped = path }
    func failingReadBack() { failReadBack = true }
    func ignoringShareMode() { ignoresShareMode = true }
    func ignoringPermission() { ignoresPermission = true }

    func send(_ request: URLRequest) async throws -> RouterHTTPResponse {
        guard let url = request.url else { throw RouterError.network("no url") }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let path = String(url.path.drop { $0 == "/" })
        records.append(Record(method: request.httpMethod ?? "GET", path: path, query: query, body: body, contentType: request.value(forHTTPHeaderField: "Content-Type")))
        if path == dropped { throw URLError(.networkConnectionLost) }
        if let text = answers[path] { return page(text) }
        let fields = Dictionary(form(body), uniquingKeysWith: { first, _ in first })
        switch path {
        case "appGet.cgi":
            if failReadBack, records.contains(where: { $0.path == "start_apply.htm" && $0.body.hasPrefix("current_page=%2Faidisk.asp") }) { throw URLError(.timedOut) }
            var parts: [String] = []
            for call in (query["hook"] ?? "").split(separator: ";").map(String.init) {
                guard let open = call.firstIndex(of: "(") else { continue }
                let name = String(call[..<open]), argument = String(call[call.index(after: open)..<call.index(before: call.endIndex)])
                switch name {
                case "nvram_char_to_ascii":
                    let key = String(argument.split(separator: ",").first ?? "")
                    parts.append("\"\(key)\":\"" + ascii(nvram[key] ?? "") + "\"")
                case "nvram_get": parts.append("\"\(argument)\":\"" + (nvram[argument] ?? "") + "\"")
                case "get_all_accounts": parts.append("\"get_all_accounts\":[" + accounts.map { "\"" + ascii($0) + "\"" }.joined(separator: ", ") + "]")
                case "wanlink": parts.append("\"wanlink-ipaddr\":\"" + (nvram["wan0_ipaddr"] ?? "") + "\"")
                default: break
                }
            }
            return RouterHTTPResponse(data: Data(("{\n" + parts.joined(separator: ",\n") + "\n}\n").utf8), status: 200)
        case "aidisk.asp":
            return page(parentPage())
        case "require/modules/diskList.js":
            guard let disks else { return RouterHTTPResponse(data: Data(), status: 404) }
            return page(disks)
        case "aidisk/Aidisk-3.asp":
            let text = ddnsPage()
            if nvram["ddns_return_code"] != "ddns_query" { nvram["ddns_return_code"] = "" }
            return page(text)
        case "aidisk/initial_account.asp":
            accounts = [nvram["http_username"] ?? ""]
            folderRights = [:]
            return page(wrapper("initial_account", "initial_account_success"))
        case "aidisk/create_account.asp":
            accounts.append(fields["account"] ?? "")
            return page(wrapper("create_account", "create_account_success"))
        case "aidisk/set_account_all_folder_permission.asp":
            if !ignoresPermission, fields["protocol"] == "ftp" { folderRights[fields["account"] ?? ""] = Int(fields["permission"] ?? "") }
            return page(wrapper("set_account_all_folder_permission", "set_account_all_folder_permission_success"))
        case "Advanced_AiDisk_ftp.asp":
            // get_AiDisk_status (Advanced_AiDisk_ftp.asp:26) and get_permissions_of_account (27; web.c:28865–28920,
            // 28700–28862) for each account and the one partition with its folder "Share".
            var text = "<html><head><script type=\"text/javascript\">\n" + statusOutput() + "\nfunction get_account_permissions_in_pool(account, pool){\n    if(account == null){\n        if(pool == \"sda1\"){\n            return [[\"\", 0, 0],\n                    [\"Share\", 0, 0]];\n        }\n    }\n"
            for account in accounts {
                let right = account == nvram["http_username"] ? 3 : folderRights[account] ?? 0
                text += "    else if(account == \"\(account)\"){\n        if(pool == \"sda1\"){\n            return [[\"\", 0, 0],\n                    [\"Share\", 0, \(right)]];\n        }\n    }\n"
            }
            return page(text + "}\n\n\nvar PROTOCOL = \"ftp\";\n</script></head><body></body></html>")
        case "aidisk/switch_share_mode.asp":
            let share = fields["dummyShareway"] ?? ""
            nvram["dummyShareway"] = share.isEmpty ? "0" : share
            if !ignoresShareMode { nvram["st_ftp_mode"] = fields["mode"] == "share" ? "1" : "2" }
            return page(wrapper("set_share_mode", "set_share_mode_success"))
        case "aidisk/switch_AiDisk_app.asp":
            nvram["enable_ftp"] = "1"
            return page(wrapper("set_AiDisk_status", "parent.resultOfSwitchAppStatus"))
        case "start_apply.htm":
            for (key, value) in fields where ["ddns_enable_x", "ddns_server_x", "ddns_hostname_x"].contains(key) { nvram[key] = value }
            if fields["action_script"] == "aidisk_asusddns_register" { nvram["ddns_return_code"] = "ddns_query" }
            return page("<html><head><script>function done_committing(){}\nfunction no_changes_and_no_committing(){}</script></head><body>\n<script>done_committing();</script>\n</body></html>")
        case "ajax_ddnscode.asp":
            if !codes.isEmpty { nvram["ddns_return_code"] = codes.count > 1 ? codes.removeFirst() : codes[0] }
            return page("ddns_return_code = '\(nvram["ddns_return_code"] ?? "")';\nddns_updated = '1';\n")
        default:
            return RouterHTTPResponse(data: Data(), status: 404)
        }
    }
    nonisolated func cancel() {}
    private func page(_ text: String) -> RouterHTTPResponse { RouterHTTPResponse(data: Data(text.utf8), status: 200) }

    /// A wrapper page: its own callbacks (definitions the answer must not be mistaken for), then the handler's
    /// insert_hook_func output.
    private func wrapper(_ handler: String, _ call: String) -> String {
        "<html><head><script>\nfunction \(handler)_error(error_msg){ parent.alert_error_msg(error_msg); }\nfunction \(handler)_success(){ }\n</script></head><body>\n<script>\n\(call)();\n</script>\n</body></html>"
    }

    /// aidisk.asp with get_AiDisk_status as web.c:28391–28489 writes it.
    private func parentPage() -> String {
        "<html><head><script>\n" + statusOutput() + "var account_num;\nvar pools = [];\n</script></head><body></body></html>"
    }

    /// get_AiDisk_status's output (web.c:28391–28489) for the one partition sda1 with its folder "Share"; nothing without USB.
    private func statusOutput() -> String {
        var text = ""
        if usb {
            let mode = nvram["st_ftp_force_mode"] == nil && atoi(nvram["st_ftp_mode"]) == 1 ? 2 : atoi(nvram["st_ftp_mode"])
            text += "function get_cifs_status(){\n    return 1;\n}\n\nfunction get_ftp_status(){\n    return \(atoi(nvram["enable_ftp"]));\n}\n\n"
            text += "function get_dms_status(){\n    return 0;\n}\n\nfunction get_share_management_status(protocol){\n    if(protocol == \"cifs\")\n        return 4;\n"
            text += "    else if(protocol == \"ftp\")\n        return \(mode);\n    else\n        return -1;\n}\n\nfunction get_sharedfolder_in_pool(poolName){\n    if(poolName == \"sda1\"){\n        return [\"\", \"Share\"];\n    }\n}\n\n"
        }
        return text
    }

    /// Aidisk-3.asp's script values (17–20).
    private func ddnsPage() -> String {
        "<html><head><script>\nvar ddns_server_x = '\(nvram["ddns_server_x"] ?? "")';\nvar ddns_hostname_x = '\(nvram["ddns_hostname_x"] ?? "")';\n"
            + "var ddns_old_name = '\(nvram["ddns_old_name"] ?? "")';\nvar ddns_return_code = '\(nvram["ddns_return_code"] ?? "")';\nvar ddns_hostname_title;\n</script></head></html>"
    }

    var actions: [Record] { records.filter { $0.path != "appGet.cgi" } }
    var posts: [Record] { records.filter { $0.method == "POST" } }
    func value(_ key: String) -> String? { nvram[key] }
}

/// diskList.js as the router writes it (web.c:11754–11880, initial_web_hook.c:125–133).
private func diskScript(ports: [String] = ["1"], tags: [String] = ["Disk%20One"], mounted: [String] = ["1"], rc: String = "usbX2 mssid") -> String {
    func list(_ items: [String]) -> String { items.map { "\"" + $0 + "\"" }.joined(separator: ", ") }
    return "\u{FEFF}define([], function(){\n\tvar diskList = {\n\t\tlist: function(){\n\t\t\tvar usb_port_storage_status = [[\"0\"]][0];\n"
        + "function available_disks(){ return [];}\n\nfunction claimed_disks(){ return [];}\n\n"
        + "function foreign_disks(){\n    return [\(list(tags))];\n}\n\n"
        + "function foreign_disk_interface_names(){\n    return [\(list(ports))];\n}\n\n"
        + "function foreign_disk_model_info(){\n    return [\(list(tags.map { _ in "Vendor Model" }))];\n}\n\n"
        + "function foreign_disk_total_mounted_number(){\n    return [\(list(mounted))];\n}\n\n"
        + "function total_disk_sizes(){\n    return [];\n}\n"
        + "\t\t\tvar initialValue = {\n\t\t\t\t\"usbPortMax\" :  '\(rc)'.charAt('\(rc)'.indexOf(\"usbX\")+4),\n\t\t\t\t\"apps_dev\" : ''\n\t\t\t};\n"
}

private func client(_ router: AiDiskRouter) throws -> RouterClient { RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: router, writes: .reference) }

/// A router with one mounted disk and AiDisk set up before, the FTP side on, ASUS DDNS registered.
private let base: [String: String] = [
    "dummyShareway": "2", "ddns_enable_x": "1", "ddns_server_x": "WWW.ASUS.COM", "ddns_hostname_x": "example-name.asuscomm.com",
    "lan_ipaddr": "192.168.50.1", "http_username": "admin", "lan_hwaddr": "02:00:00:00:AB:CD", "territory_code": "AU/01",
    "enable_ftp": "1", "st_ftp_mode": "2", "st_ftp_force_mode": "2", "ddns_old_name": "", "ddns_return_code": "", "wan0_ipaddr": "100.64.10.20"
]
private func welcomePage(_ values: [String: String] = [:], status: AiDiskStatus? = AiDiskStatus(ftpStatus: 1, ftpMode: 2),
                         disks: AiDiskDisks? = AiDiskDisks(ports: ["1"], tags: ["Disk"], mounted: ["1"], rcSupport: "usbX2")) -> AiDiskPage {
    AiDiskPage(status: status, values: base.filter { AiDiskPage.keys.contains($0.key) }.merging(values) { $1 }, disks: disks)
}
private func shareStep(_ values: [String: String] = [:]) -> AiDiskShareStep {
    AiDiskShareStep(values: base.filter { AiDiskShareStep.keys.contains($0.key) }.merging(values) { $1 })
}
private func names(_ records: [AiDiskRouter.Record]) -> [String] { records.map(\.path) }

// MARK: - Opening

@Test func theParentPageAndTheDiskListReadAsThePageReadsThem() async throws {
    // get_AiDisk_status as written: st_ftp_mode 1 without st_ftp_force_mode is reported as 2 (web.c:28424).
    let router = AiDiskRouter(nvram: base.merging(["st_ftp_mode": "1", "enable_ftp": "0"]) { $1 }.filter { $0.key != "st_ftp_force_mode" })
    let page = try await client(router).aiDiskPage()
    #expect(page.status == AiDiskStatus(ftpStatus: 0, ftpMode: 2))
    #expect(page.disks == AiDiskDisks(ports: ["1"], tags: ["Disk%20One"], mounted: ["1"], rcSupport: "usbX2 mssid"))
    // Opening reads only: aidisk.asp and diskList.js by GET, the rest through appGet.
    #expect(await router.records.allSatisfy { $0.method == "GET" })
    #expect(names(await router.actions) == ["aidisk.asp", "require/modules/diskList.js"])
    // With st_ftp_force_mode present, st_ftp_mode as it is.
    let forced = AiDiskRouter(nvram: base.merging(["st_ftp_mode": "1", "st_ftp_force_mode": "1"]) { $1 })
    #expect(try await client(forced).aiDiskPage().status == AiDiskStatus(ftpStatus: 1, ftpMode: 1))
    // No get_AiDisk_status (no USB): nothing to set up.
    let noUSB = try await client(AiDiskRouter(nvram: base, usb: false)).aiDiskPage()
    #expect(noUSB.status == nil && noUSB.content == .unsupported && noUSB.startWizard() == nil)
    // An unreadable disk list: the require callback never runs.
    let noList = try await client(AiDiskRouter(nvram: base, disks: nil)).aiDiskPage()
    #expect(noList.disks == nil && noList.content == .unknownDisks && noList.startWizard() == nil)
}

@Test func aFolderNameTheScriptCannotHoldStopsTheWizard() {
    func page(_ arrays: String) -> String {
        "<script>\nfunction get_ftp_status(){\n    return 1;\n}\n\nfunction get_share_management_status(protocol){\n    if(protocol == \"cifs\")\n        return 4;\n"
            + "    else if(protocol == \"ftp\")\n        return 2;\n    else\n        return -1;\n}\n\nfunction get_sharedfolder_in_pool(poolName){\n"
            + "    if(poolName == \"sda1\"){\n        return [\"\"" + arrays + "];\n    }\n}\n\nvar account_num;\n</script>"
    }
    // Names JavaScript takes, also ones that only look odd (a quote that leaves a valid expression, a line continued by a backslash).
    for good in [#", "Share", "Music""#, "", #", "a\b", "\x41", "\u0041", "\u{1F600}", "\u{10FFFF}", "100%""#, ", \"a\\\r\nb\"", #", "a" || "b""#] {
        #expect(AiDiskStatus.scriptError(in: page(good)) == nil, "\(good)")
    }
    // A quote, a line break, an escape that is not one, a backslash before the closing quote, or "</script" do not.
    for bad in [#", "a"b""#, ", \"a\nb\"", #", "\x4G""#, #", "\u12""#, #", "\u{}""#, #", "end\""#, #", "x</SCRIPT>y""#,
                #", "a"];b""#, #", "\u{110000}""#,
                // A name that writes a whole end of the function and the partition, then more.
                ", \"a\"];\n    }\n}\n@\""] {
        #expect(AiDiskStatus.scriptError(in: page(bad)) != nil, "\(bad)")
    }
    // The element ends only at a whole end tag: one cut off before its ">" (or inside a quoted attribute) does not end it.
    #expect(AiDiskStatus.scriptError(in: "<script>\nfunction get_ftp_status(){\n    return 1;\n}\n</script\n") != nil)
    #expect(AiDiskScript.element(containing: "function get_ftp_status(){", in: "<script>\nfunction get_ftp_status(){}\n</script x=\"a>b\">")
            == "\nfunction get_ftp_status(){}\n")
    #expect(AiDiskScript.element(containing: "function get_ftp_status(){", in: "<script>\nfunction get_ftp_status(){}\n</script x=\"a>b") == nil)
    let status = try? #require(AiDiskStatus.parse(page(#", "a"b""#)))
    #expect(status?.ftpStatus == 1 && status?.ftpMode == 2 && status?.scriptError != nil)
    let blocked = AiDiskPage(status: status, values: ["dummyShareway": "1"], disks: AiDiskDisks(ports: ["1"], tags: ["Disk"], mounted: ["1"], rcSupport: "usbX2"))
    #expect(!blocked.offersWizard && blocked.startWizard() == nil)
    if case .scriptError = blocked.content {} else { Issue.record("\(blocked.content)") }
}

@Test func theDiskCountFollowsTheWelcomePagesScript() {
    func none(_ ports: [String], _ tags: [String], _ mounted: [String], rc: String = "usbX2") -> Bool {
        AiDiskDisks(ports: ports, tags: tags, mounted: mounted, rcSupport: rc).none
    }
    #expect(!none(["1"], ["A"], ["1"]) && none(["1"], ["A"], ["0"]) && none([], [], []))
    // `mount_num += "0"` then `+= "1"`: "001" is 1.
    #expect(!none(["1", "2"], ["A", "B"], ["0", "1"]) && none(["1", "2"], ["A", "B"], ["0", "0"]))
    // A port above usbPortMax (text comparison) and a disk without a name are left out.
    #expect(none(["3"], ["A"], ["1"]) && none(["1"], [""], ["1"]) && !none(["2.1"], ["A"], ["1"]))
    // Without "usbX" the script reads rc_support's fourth character; past its end usbPortMax is "" and every port is above it.
    #expect(!none(["1"], ["A"], ["1"], rc: "abc9") && none(["1"], ["A"], ["1"], rc: "ab"))
    // A count that is no number makes the sum NaN, which is not 0.
    #expect(!none(["1"], ["A"], ["x"]))
    // The server's answer without disks (initial_web_hook.c:125–133).
    let empty = AiDiskDisks.parse("function foreign_disks() { return [];}\nfunction foreign_disk_interface_names() { return [];}\nfunction foreign_disk_model_info() { return [];}\nfunction foreign_disk_total_size() { return [];}\nfunction foreign_disk_total_mounted_number() { return [];}\n")
    #expect(empty?.none == true)
    #expect(AiDiskDisks.parse("define([], function(){});") == nil)
}

@Test func theWelcomePageShowsWhatShowShareLinkShows() throws {
    #expect(welcomePage(disks: AiDiskDisks(ports: ["1"], tags: ["Disk"], mounted: ["0"], rcSupport: "usbX2")).content == .noDisk)
    #expect(welcomePage(["dummyShareway": ""]).content == .introduction)
    #expect(welcomePage().lanAddress == "ftp://192.168.50.1")
    func links(_ values: [String: String], ftp: Int = 1, mode: Int = 2) throws -> AiDiskAccessLinks {
        guard case .configured(let links) = welcomePage(values, status: AiDiskStatus(ftpStatus: ftp, ftpMode: mode)).content else { throw RouterError.validation("not configured") }
        return links
    }
    let shown = try links([:])
    #expect(shown.internet == "Internet FTP address: ftp://example-name.asuscomm.com" && shown.lan == "LAN FTP address: ftp://192.168.50.1" && !shown.anonymousHint)
    // FTP_mode 1 adds the anonymous hint; dummyShareway 0 shows the addresses whatever the mode; mode 3 with 2 shows neither.
    let modeOne = try links([:], mode: 1), zero = try links(["dummyShareway": "0"], mode: 3)
    #expect(modeOne.anonymousHint && zero.internet != nil)
    let neither = try links([:], mode: 3)
    #expect(neither.internet == nil && neither.lan == nil && neither.hint == nil)
    let ftpOff = try links([:], ftp: 0)
    #expect(ftpOff.hint == .ftpOff && ftpOff.lan == nil)
    let ddnsOff = try links(["ddns_enable_x": "0"])
    #expect(ddnsOff.hint == .ddnsOff && ddnsOff.lan == "LAN FTP address: ftp://192.168.50.1")
    #expect(try links(["ddns_hostname_x": ""]).hint == .notRegistered)
    // DDNS on with a name but no server: the alert of the last branch.
    #expect(try links(["ddns_server_x": ""]).exception)
    // aidisk.asp's forms: dummyShareway "" made 0, ddns_enable_x as read.
    #expect(welcomePage(["dummyShareway": ""]).startWizard() == AiDiskWizard(dummyShareway: "0", ddnsEnable: "1"))
}

// MARK: - Share method

@Test func theShareStepFollowsShowTextinWizardAndPassTheResult() throws {
    var wizard = try #require(welcomePage().startWizard())
    let page = shareStep()
    var form = page.initialForm(&wizard)
    // initial(): 只有我可以访问 every time, the admin row only.
    #expect(form.option == "2" && wizard.dummyShareway == "2" && form.table && form.adminRow && !form.familyRow && !form.anonymousHint && form.user1 == "admin")
    #expect(page.options == ["2", "1", "0"] && shareStep(["territory_code": "KR/01"]).options == ["2", "1"])
    page.select("1", &form, wizard: &wizard)
    #expect(form.familyRow && form.user2 == "Family" && form.password == "familyabcd" && wizard.dummyShareway == "1")
    // Clicking the checked choice again fills in the default once more.
    form.password = "changed"
    page.select("1", &form, wizard: &wizard)
    #expect(form.password == "familyabcd")
    page.select("0", &form, wizard: &wizard)
    #expect(form.anonymousHint && !form.table && wizard.dummyShareway == "0")
    // A lan_hwaddr without two groups throws at the password: the radio is checked, the rows stay.
    let odd = shareStep(["lan_hwaddr": ""])
    var oddForm = odd.initialForm(&wizard)
    odd.select("1", &oddForm, wizard: &wizard)
    #expect(oddForm.option == "1" && !oddForm.familyRow && oddForm.password == "" && wizard.dummyShareway == "1")

    // passTheResult: the password checks only for Family (the characters it may not hold are not shown back).
    var family = page.initialForm(&wizard)
    page.select("1", &family, wizard: &wizard)
    for (text, alert) in [("", "密码不能为空!"), ("\"pw", "第一个字符不能是： [\"]"), ("pw\"", "最后一个字符不能是： [\"]"), ("pä\tw", "本字符串无法包含：英文半角可打印字符（空格至 ~）以外的字符。为保护密码，这里不显示具体字符。")] {
        family.password = text
        #expect(page.next(family) == .invalid(alert))
    }
    family.password = "Fam pass+1"
    guard case .proceed(let number, let account, let password, let permission, let request) = page.next(family) else { throw RouterError.validation("no request") }
    #expect(number == "2" && account == "Family" && password == "Fam pass+1" && permission == "1")
    // The smartForm as the browser submits it to Aidisk-3.asp: its own hidden fields empty, the radio, the password field.
    #expect(request.path == "aidisk/Aidisk-3.asp" && request.step == .openDDNS)
    #expect(String(decoding: request.body, as: UTF8.self) == "accountNum=&account0=&passwd0=&permission0=&account1=&passwd1=&permission1=&dummyoption=1&userpasswd2=Fam+pass%2B1")
    var only = page.initialForm(&wizard)
    guard case .proceed("1", "", "", "", _) = page.next(only) else { throw RouterError.validation("only me") }
    page.select("0", &only, wizard: &wizard)
    guard case .proceed("0", "", "", "", _) = page.next(only) else { throw RouterError.validation("anyone") }
    // The parent keeps passTheResult's fields.
    wizard.accept(page.next(family))
    #expect(wizard.accountNum == "2" && wizard.account1 == "Family" && wizard.passwd1 == "Fam pass+1" && wizard.permission1 == "1")
}

@Test func theFamilyPasswordFieldFiltersKeysAsValidatorIsString() {
    #expect(WebValidator.isStringKeyPress("a") && WebValidator.isStringKeyPress("~") && WebValidator.isStringKeyPress(" "))
    #expect(!WebValidator.isStringKeyPress("é") && !WebValidator.isStringKeyPress("密") && !WebValidator.isStringKeyPress("😀"))
    let filter: (String, Character) -> String? = { value, key in WebValidator.isStringKeyPress(key) ? value : nil }
    let full = String(repeating: "a", count: 32)
    // maxlength 32: a typed key past it does not go in; a refused key leaves the value.
    #expect(WebValidator.edit(full, full + "b", typed: "b", maxLength: 32, keyPress: filter) == full)
    #expect(WebValidator.edit("ab", "abé", typed: "é", maxLength: 32, keyPress: filter) == "ab")
    // Pasted text is not filtered, only cut to the room left.
    #expect(WebValidator.edit("ab", "abééé", typed: nil, maxLength: 4) == "abéé")
}

// MARK: - DDNS

@Test func openingTheDDNSStepIsTheWriteThatClearsTheReturnCode() async throws {
    let router = AiDiskRouter(nvram: base.merging(["ddns_hostname_x": "oldname.asuscomm.com", "ddns_return_code": "register,203"]) { $1 })
    var wizard = try #require(welcomePage().startWizard())
    let page = shareStep()
    let form = page.initialForm(&wizard)
    guard case .proceed(_, _, _, _, let request) = page.next(form) else { throw RouterError.validation("no request") }
    let opened = try await client(router).openAiDiskDDNSStep(request)
    let post = try #require(await router.posts.first)
    #expect(post.path == "aidisk/Aidisk-3.asp" && post.contentType == "application/x-www-form-urlencoded")
    #expect(post.body == "accountNum=&account0=&passwd0=&permission0=&account1=&passwd1=&permission1=&dummyoption=2&userpasswd2=")
    // The page gives the code as read; the router has cleared it.
    #expect(opened == AiDiskDDNSStep(server: "WWW.ASUS.COM", hostname: "oldname.asuscomm.com", oldName: "", returnCode: "register,203"))
    #expect(await router.value("ddns_return_code") == "")
    #expect(opened.initialName == "oldname" && opened.initialAlert == "该网域名称 'oldname.asuscomm.com' 已有人使用。" && opened.codeAfterOpening == "")
    // ddns_query stays; step 4's 上一步 posts an empty form.
    let querying = AiDiskRouter(nvram: base.merging(["ddns_return_code": "ddns_query"]) { $1 })
    let again = try await client(querying).openAiDiskDDNSStep(AiDiskFinishStep.back)
    let kept = await querying.value("ddns_return_code")
    #expect(again.returnCode == "ddns_query" && kept == "ddns_query")
    #expect(await querying.posts.map(\.body) == [""] && again.initialAlert == "处理中")
    // Another DDNS service: the hint text, no alert, and the script keeps the code.
    let other = AiDiskDDNSStep(server: "WWW.DYNDNS.ORG", hostname: "x.example.org", oldName: "", returnCode: "register,200")
    #expect(other.initialName == AiDiskDDNSStep.inputHint && other.initialAlert == nil && other.codeAfterOpening == "register,200")
    // No suffix, or nothing before it: the hint.
    #expect(AiDiskDDNSStep(server: "WWW.ASUS.COM", hostname: "plain", oldName: "", returnCode: "").initialName == AiDiskDDNSStep.inputHint)
    #expect(AiDiskDDNSStep(server: "WWW.ASUS.COM", hostname: ".asuscomm.com", oldName: "", returnCode: "").initialName == AiDiskDDNSStep.inputHint)
    #expect(AiDiskDDNSStep.parse("var ddns_server_x = 'it's';") == nil)
}

@Test func theDDNSNameIsCheckedAsValidateDDNSHostnameChecksIt() {
    let alarm7 = "主机名不能为数字前缀与 '.'（如 '123abc' 或 'aaa.bbb' ）"
    #expect(AiDiskDDNSStep.validate("") == .block("用户名称不能空白！"))
    #expect(AiDiskDDNSStep.validate("1abc") == .block(alarm7) && AiDiskDDNSStep.validate("a.b") == .block(alarm7))
    #expect(AiDiskDDNSStep.validate("\"ab") == .alert("第一个字符不能是： [\"]"))
    // The hint left in the field fails validator.string with its alert.
    #expect(AiDiskDDNSStep.validate(AiDiskDDNSStep.inputHint) == .alert("本字符串无法包含： '请输入名称' !"))
    #expect(AiDiskDDNSStep.validate("a_b") == .block("网域名称包含无效字符 '_' !") && AiDiskDDNSStep.validate("a b") == .block("网域名称包含无效字符 ' ' !"))
    #expect(AiDiskDDNSStep.validate("Example-Name2") == .valid)
}

@Test func returnCodesReadAsGetDDNSStateReadsThem() {
    func hint(_ code: String) -> String? { AiDiskDDNSStep.checkReturnCode(code, hostname: "a.asuscomm.com", oldName: "b.asuscomm.com") }
    #expect(hint("register,200") == "注册成功。" && hint("register,220") == "原主机名称更新成功。" && hint("register,230") == "新主机名称注册成功。")
    #expect(hint("register,203") == "该网域名称 'a.asuscomm.com' 已有人使用。")
    #expect(hint("register,233") == "该网域名称 'a.asuscomm.com' 已有人使用，而且您已注册 ： 'b.asuscomm.com'")
    #expect(hint("register,299") == "注册失败(IP 地址格式不正确)。" && hint("register,390") == "Server Error" && hint("register,402") == "注册被阻止，请将固件更新为最新版本。")
    // Found as parts of the text, in order: "-1" first, then "200" inside "1200".
    #expect(hint("register,-1") == "注册错误，请再试一次。" && hint("register,1200") == "注册成功。")
    // Time-out shows alarm_12 here (getDDNSState itself says alarm_1); no_change shows nothing; other text the generic error.
    #expect(hint("Time-out") == "DDNS 服务器没有响应。" && AiDiskDDNSStep.state("Time-out", hostname: "", oldName: "") == "DDNS 服务器没有响应，请再试一次。")
    #expect(hint("no_change") == nil && hint("") == nil && hint("ddns_query") == "处理中" && hint("auth_fail") == "授权失败")
    #expect(hint("connect_fail") == "无法连接到互联网" && hint("something") == "注册错误，请再试一次。")
    let step = AiDiskDDNSStep(server: "WWW.ASUS.COM", hostname: "a.asuscomm.com", oldName: "", returnCode: "")
    #expect(step.outcome("ddns_query") == .waiting && step.outcome("register,220") == .registered && step.outcome("no_change") == .registered)
    // register,200 without the prefix is not one of the three and goes through check_return_code.
    #expect(step.outcome("200") == .failed("注册成功。") && step.outcome("") == .failed(nil))
}

@Test func theRegistrationSendsThePagesFormAndTheResultIsReadAsTheScriptReadsIt() async throws {
    let router = AiDiskRouter(nvram: base, codes: ["ddns_query", "register,200"])
    let request = AiDiskDDNSStep.registration(name: "example-name")
    try await client(router).registerAiDiskDDNS(request)
    let post = try #require(await router.posts.first)
    #expect(post.path == "start_apply.htm" && post.contentType == "application/x-www-form-urlencoded")
    #expect(post.body == "current_page=%2Faidisk%2FAidisk-3.asp&next_page=&group_id=&action_mode=apply&action_script=aidisk_asusddns_register"
            + "&action_wait=1&asusddns_tos_agreement=1&ddns_server_x=WWW.ASUS.COM&ddns_hostname_x=example-name.asuscomm.com&flag=nodetect"
            + "&check_asus_ddns=on&DDNSName=example-name")
    #expect(!post.body.contains("ddns_enable_x"))
    #expect(await router.value("ddns_hostname_x") == "example-name.asuscomm.com")
    // checkDDNSReturnCode's reads: a script GET with jQuery's "_" parameter.
    let reader = try client(router)
    #expect(try await reader.aiDiskDDNSCode(stamp: 1) == "ddns_query")
    #expect(try await reader.aiDiskDDNSCode(stamp: 2) == "register,200")
    let reads = await router.records.filter { $0.path == "ajax_ddnscode.asp" }
    #expect(reads.map(\.method) == ["GET", "GET"] && reads.map { $0.query["_"] } == ["1", "2"])
    #expect(AiDiskDDNSStep.ajaxCode("var ddns_return_code = \"register,230\";") == "register,230" && AiDiskDDNSStep.ajaxCode("x = 1;") == nil)
    // An answer start_apply.htm would not give leaves the registration unconfirmed.
    let odd = AiDiskRouter(nvram: base)
    await odd.answer("start_apply.htm", with: "<html></html>")
    await #expect(throws: RouterError.self) { try await client(odd).registerAiDiskDDNS(request) }
}

// MARK: - Finish

@Test func theLastStepShowsWhatAidisk4Shows() async throws {
    #expect(AiDiskFinishStep.method("0") == "\"不需要帐号密码\"" && AiDiskFinishStep.method("1") == "\"需要帐号才能访问\"")
    #expect(AiDiskFinishStep.method("2") == "\"只有我可以访问\"" && AiDiskFinishStep.method("3") == nil)
    let router = AiDiskRouter(nvram: base)
    let page = try await client(router).aiDiskFinishStep()
    #expect(page.values["enable_ftp"] == "1" && page.wanIP == "100.64.10.20" && page.hostname == "example-name.asuscomm.com")
    #expect(page.display(ddnsEnable: "1") == AiDiskFinishStep.Display(internet: "Internet FTP address: ftp://example-name.asuscomm.com", privateWAN: false, ddnsOff: false))
    #expect(page.display(ddnsEnable: "0") == AiDiskFinishStep.Display(ddnsOff: true))
    // FTP off: no hint at all, not even 未开启.
    #expect(AiDiskFinishStep(values: ["enable_ftp": "0"], wanIP: "").display(ddnsEnable: "1") == AiDiskFinishStep.Display())
    // The private note: strictly inside the ranges, or 0.0.0.0.
    for (ip, note) in [("192.168.1.10", true), ("192.168.0.0", false), ("10.255.255.255", false), ("0.0.0.0", true), ("", false), ("100.64.10.20", false)] {
        #expect(AiDiskFinishStep(values: ["enable_ftp": "1"], wanIP: ip).display(ddnsEnable: "1").privateWAN == note, "\(ip)")
    }
}

// MARK: - 保存

/// The wizard as the steps leave it: a choice in step 2 (Family with its password), the DDNS choice in step 3.
private func wizard(choosing option: String, password: String = "Fam pass+1", ddns: String) throws -> AiDiskWizard {
    var wizard = try #require(welcomePage().startWizard())
    let page = shareStep()
    var form = page.initialForm(&wizard)
    page.select(option, &form, wizard: &wizard)
    form.password = option == "1" ? password : form.password
    wizard.accept(page.next(form))
    wizard.setDDNSEnable(ddns)
    return wizard
}

@Test func savingWithoutAccountsSendsTheShareModeTheFTPSwitchAndTheDDNSForm() async throws {
    let router = AiDiskRouter(nvram: base.merging(["enable_ftp": "0", "dummyShareway": ""]) { $1 })
    let result = try await client(router).saveAiDisk(try wizard(choosing: "0", ddns: "0"), adminName: "admin")
    let posts = await router.posts
    #expect(names(posts) == ["aidisk/switch_share_mode.asp", "aidisk/switch_AiDisk_app.asp", "start_apply.htm"])
    #expect(posts.allSatisfy { $0.contentType == "application/x-www-form-urlencoded" })
    #expect(posts.map(\.body) == [
        "dummyShareway=0&account=&password=&protocol=ftp&mode=share&pool=&folder=&permission=&flag=on",
        "dummyShareway=0&account=&password=&protocol=ftp&mode=&pool=&folder=&permission=&flag=on",
        "current_page=%2Faidisk.asp&action_mode=apply&action_script=&action_wait=&ddns_enable_x=0"
    ])
    #expect(result.confirmed == 3 && result.total == 3 && result.receipt.isVerified)
    #expect(result.receipt.verified == ["dummyShareway", "st_ftp_mode", "enable_ftp", "ddns_enable_x"])
    let mode = await router.value("st_ftp_mode"), ftp = await router.value("enable_ftp")
    #expect(mode == "1" && ftp == "1")
}

@Test func savingFamilyResetsAccountsCreatesFamilyAndGivesItEveryFolderReadOnly() async throws {
    let router = AiDiskRouter(nvram: base, accounts: ["admin", "olduser"])
    let chosen = try wizard(choosing: "1", ddns: "1")
    let result = try await client(router).saveAiDisk(chosen, adminName: "admin")
    let posts = await router.posts
    #expect(names(posts) == ["aidisk/initial_account.asp", "aidisk/create_account.asp", "aidisk/set_account_all_folder_permission.asp",
                             "aidisk/switch_share_mode.asp", "aidisk/switch_AiDisk_app.asp", "start_apply.htm"])
    // What earlier steps left in applyForm goes along: Family's permission empties dummyShareway, its flag stays for the share mode.
    #expect(posts.map(\.body) == [
        "dummyShareway=1&account=&password=&protocol=&mode=&pool=&folder=&permission=&flag=on",
        "dummyShareway=1&account=Family&password=Fam+pass%2B1&protocol=&mode=&pool=&folder=&permission=&flag=on",
        "dummyShareway=&account=Family&password=&protocol=ftp&mode=&pool=&folder=&permission=1&flag=aidisk_wizard",
        "dummyShareway=&account=&password=&protocol=ftp&mode=account&pool=&folder=&permission=&flag=aidisk_wizard",
        "dummyShareway=&account=&password=&protocol=ftp&mode=&pool=&folder=&permission=&flag=on",
        "current_page=%2Faidisk.asp&action_mode=apply&action_script=&action_wait=&ddns_enable_x=1"
    ])
    // set_share_mode stores the empty dummyShareway as 0; the reset leaves the administrator and Family.
    #expect(chosen.expectation(adminName: "admin") == AiDiskExpectation(values: [AiDiskField("dummyShareway", "0"), AiDiskField("st_ftp_mode", "2"),
                                                                                 AiDiskField("enable_ftp", "1"), AiDiskField("ddns_enable_x", "1")],
                                                                        accounts: ["admin", "Family"], ftpFolders: AiDiskFolderRight(account: "Family", right: 1)))
    #expect(result.confirmed == 6 && result.receipt.isVerified && result.receipt.verified.contains("帐户列表")
            && result.receipt.verified.contains("Family 的 FTP 文件夹权限"))
    // A success answer that left the folders as they were is found when the rights are read back.
    let lazy = AiDiskRouter(nvram: base, accounts: ["admin", "olduser"])
    await lazy.ignoringPermission()
    let unchanged = try await client(lazy).saveAiDisk(chosen, adminName: "admin")
    #expect(unchanged.confirmed == 6 && !unchanged.receipt.isVerified && unchanged.receipt.unverified.contains { $0.hasPrefix("Family 的 FTP 文件夹权限") })
    #expect(aiDiskFolderRights(of: "Family", in: "function get_account_permissions_in_pool(account, pool){\n}\n") == nil)
    let stored = await router.value("dummyShareway"), accounts = await router.accounts
    #expect(stored == "0" && accounts == ["admin", "Family"])
    #expect(!result.receipt.message.contains("Fam pass"))
}

@Test func folderRightsAreCheckedPartitionByPartition() {
    // Advanced_AiDisk_ftp.asp:25–27: one script element, get_AiDisk_status's output (ending with get_sharedfolder_in_pool),
    // the template's line break, then get_permissions_of_account's.
    func ftpPage(_ shared: String, _ rights: String) -> String {
        "<html><head><script type=\"text/javascript\">\n" + shared + "\n" + rights + "\n\nvar PROTOCOL = \"ftp\";\n</script></head><body></body></html>"
    }
    func rightsText(_ parts: [(String, String?)]) -> String {
        var text = "function get_account_permissions_in_pool(account, pool){\n    if(account == null){\n    }\n    else if(account == \"Family\"){\n"
        for (index, part) in parts.enumerated() {
            guard let entries = part.1 else { continue }
            text += (index == 0 ? "" : "else ") + "        if(pool == \"\(part.0)\"){\n            return [[\"\", 0, 0]" + entries + "];\n        }\n"
        }
        return text + "    }\n}\n\n"
    }
    let shared = "function get_sharedfolder_in_pool(poolName){\n    if(poolName == \"sda1\"){\n        return [\"\", \"A\", \"B\"];\n    }\n"
        + "    else if(poolName == \"sdb1\"){\n        return [\"\", \"C\"];\n    }\n}\n\n"
    func page(_ sda1: String, _ sdb1: String?) -> String { ftpPage(shared, rightsText([("sda1", sda1), ("sdb1", sdb1)])) }
    let family = AiDiskFolderRight(account: "Family", right: 1)
    let two = ",\n                    [\"A\", 0, 1],\n                    [\"B\", 0, 1]", one = ",\n                    [\"C\", 0, 1]"
    #expect(aiDiskFolderRights(of: "Family", in: page(two, one)) == ["sda1": [1, 1], "sdb1": [1]])
    #expect(AiDiskFolderCheck.compare(family, page: page(two, one)) == .matched)
    // A folder left as it was, a partition that wrote only its own entry, or no part for a partition is not matched.
    #expect(AiDiskFolderCheck.compare(family, page: page(two, ",\n                    [\"C\", 0, 3]")) == .differs("1 个文件夹读回不是 1"))
    #expect(AiDiskFolderCheck.compare(family, page: page(two, "")) == .differs("分区 sdb1 的文件夹与权限条目对不上"))
    #expect(AiDiskFolderCheck.compare(family, page: page(two, nil)) == .differs("分区 sdb1 没有这个帐户的权限"))
    // A partition without folders cannot be told from one whose folders could not be listed; a right read back that is
    // not the one sent counts even there, and so does a partition missing on the account's side.
    let withEmpty = "function get_sharedfolder_in_pool(poolName){\n    if(poolName == \"sda1\"){\n        return [\"\", \"A\"];\n    }\n"
        + "    else if(poolName == \"sdb1\"){\n        return [\"\"];\n    }\n}\n\n"
    func rights(_ sdb1: String?) -> String { ftpPage(withEmpty, rightsText([("sda1", ",\n                    [\"A\", 0, 1]"), ("sdb1", sdb1)])) }
    #expect(AiDiskFolderCheck.compare(family, page: rights(",\n                    [\"Secret\", 0, 3]")) == .differs("1 个文件夹读回不是 1"))
    #expect(AiDiskFolderCheck.compare(family, page: rights("")) == .differs("分区 sdb1 没有列出文件夹，无法区分确实为空与列举失败"))
    #expect(AiDiskFolderCheck.compare(family, page: rights(nil)) == .differs("分区 sdb1 没有这个帐户的权限"))
    #expect(AiDiskFolderCheck.compare(family, page: rights(",\n                    [\"Secret\", 0, 1]")) == .differs("分区 sdb1 的文件夹与权限条目对不上"))
    // Nothing listed at all cannot be told from folders that could not be listed.
    let empty = ftpPage("function get_sharedfolder_in_pool(poolName){\n    if(poolName == \"sda1\"){\n        return [\"\"];\n    }\n}\n\n", rightsText([("sda1", "")]))
    #expect(AiDiskFolderCheck.compare(family, page: empty) == .differs("分区 sda1 没有列出文件夹，无法区分确实为空与列举失败"))
    // A part cut short is not read.
    #expect(aiDiskFolderRights(of: "Family", in: String(rightsText([("sda1", two), ("sdb1", one)]).dropLast(12))) == nil)
    // A folder name that ends its string early, writes a whole fake rights function in a template literal and opens a
    // string again (the parent script still parses): the real rights carry the name HTML-encoded but with its line breaks
    // raw, so the page's script does not parse; and the fake function is a second one. Nothing is taken as matched.
    let forged = "a\"];\n    }\n}\n`function get_account_permissions_in_pool(account, pool){\nif(account == \"Family\"){\n        if(pool == \"sda1\"){\n"
        + "            return [[\"\", 0, 0],\n                    [\"A\", 0, 1]];\n        }\n    }\n`\nfunction x(){if(1){void [\""
    let fakeShared = "function get_sharedfolder_in_pool(poolName){\n    if(poolName == \"sda1\"){\n        return [\"\", \"" + forged + "\"];\n    }\n}\n\n"
    let encoded = forged.replacingOccurrences(of: "\"", with: "&quot;")
    for right in ["3", "0"] {
        let real = rightsText([("sda1", ",\n                    [\"" + encoded + "\", 0, " + right + "]")])
        #expect(AiDiskFolderCheck.compare(family, page: ftpPage(fakeShared, real)) != .matched)
    }
    #expect(AiDiskFolderCheck.compare(family, page: ftpPage(fakeShared, "function get_account_permissions_in_pool(account, pool){\n    if(account == null){\n    }\n}\n\n")) != .matched)
    // A name that opens "<!--<script>" leaves the element without an end (script data double escaped to the end of the
    // page, HTML 13.2.5.20–13.2.5.27): the browser does not run it, so nothing on the page is taken as read, nor in the
    // parent page; looking back from the function for the nearest "<script" would have found the one in the name.
    let comment = "<!--<script>if(1){if(1){<!--"
    let commentShared = "function get_sharedfolder_in_pool(poolName){\n    if(poolName == \"sda1\"){\n        return [\"\", \"" + comment + "\"];\n    }\n}\n\n"
    let commentRights = rightsText([("sda1", ",\n                    [\"" + comment.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") + "\", 0, 1]")])
    #expect(AiDiskFolderCheck.compare(family, page: ftpPage(commentShared, commentRights)) == .differs("FTP 共享页的脚本无法解析，权限无法确定"))
    #expect(AiDiskStatus.scriptError(in: "<html><head><script>\nfunction get_ftp_status(){\n    return 1;\n}\n\n" + commentShared + "var account_num;\n</script></head></html>") != nil)
    // Without the line breaks the forged text cannot pass for either function; a second copy of a header is refused too.
    #expect(AiDiskFolderCheck.compare(family, page: page(two, one) + "<script>var s = \"function get_account_permissions_in_pool(account, pool){\";</script>")
            == .differs("FTP 共享页里不止一处像文件夹列表或权限函数的文字（可能来自文件夹名），权限无法确定"))
}

@Test func savingForTheAdministratorAloneSendsNoPermissionRequest() async throws {
    let router = AiDiskRouter(nvram: base.merging(["st_ftp_mode": "1", "st_ftp_force_mode": "1"]) { $1 }, accounts: ["admin", "olduser"])
    let result = try await client(router).saveAiDisk(try wizard(choosing: "2", ddns: "1"), adminName: "admin")
    let posts = await router.posts
    // submitChangeAllFolderPermission(admin, "3") goes straight to the share mode.
    #expect(names(posts) == ["aidisk/initial_account.asp", "aidisk/switch_share_mode.asp", "aidisk/switch_AiDisk_app.asp", "start_apply.htm"])
    #expect(Array(posts.map(\.body)[0...2]) == [
        "dummyShareway=2&account=&password=&protocol=&mode=&pool=&folder=&permission=&flag=on",
        "dummyShareway=2&account=&password=&protocol=ftp&mode=account&pool=&folder=&permission=&flag=on",
        "dummyShareway=2&account=&password=&protocol=ftp&mode=&pool=&folder=&permission=&flag=on"
    ])
    let accounts = await router.accounts, mode = await router.value("st_ftp_mode")
    #expect(result.receipt.isVerified && accounts == ["admin"] && mode == "2")
}

@Test func savingStopsWhereThePageWouldStop() async throws {
    let chosen = try wizard(choosing: "1", ddns: "1")
    // A failure hook: no further request, the error named, what went through not taken back.
    let failing = AiDiskRouter(nvram: base)
    await failing.answer("aidisk/create_account.asp", with: "<html><script>\nfunction create_account_success(){ parent.resultOfCreateAccount(); }\n</script><body>\n<script>\ncreate_account_error(alert_msg.Action2);\n</script>\n</body></html>")
    let failed = try await client(failing).saveAiDisk(chosen, adminName: "admin")
    #expect(names(await failing.posts) == ["aidisk/initial_account.asp", "aidisk/create_account.asp"])
    #expect(failed.confirmed == 1 && failed.total == 6 && !failed.receipt.isVerified)
    #expect(failed.receipt.message.contains("alert_msg.Action2") && failed.receipt.message.contains("后面 4 个请求没有发送") && failed.receipt.message.contains("不要重复提交"))
    // An answer without either hook (the wrapper's definitions alone) stops it too.
    let silent = AiDiskRouter(nvram: base)
    await silent.answer("aidisk/switch_share_mode.asp", with: "<html><script>\nfunction set_share_mode_success(){ }\nset_share_mode_success();</script></html>")
    let unknown = try await client(silent).saveAiDisk(chosen, adminName: "admin")
    #expect(names(await silent.posts).last == "aidisk/switch_share_mode.asp" && unknown.confirmed == 3)
    #expect(unknown.receipt.message.contains("没有成功或失败的回调"))
    // A request lost after it arrived: unconfirmed, nothing after it.
    let lost = AiDiskRouter(nvram: base)
    await lost.drop("aidisk/initial_account.asp")
    let dropped = try await client(lost).saveAiDisk(chosen, adminName: "admin")
    #expect(names(await lost.posts) == ["aidisk/initial_account.asp"] && dropped.confirmed == 0 && dropped.receipt.message.contains("结果尚未确认"))
    // A handler that did not change what it should: the read-back says which and how.
    let stubborn = AiDiskRouter(nvram: base.merging(["st_ftp_mode": "1"]) { $1 })
    await stubborn.ignoringShareMode()
    let mismatch = try await client(stubborn).saveAiDisk(chosen, adminName: "admin")
    #expect(mismatch.confirmed == 6 && !mismatch.receipt.isVerified && mismatch.receipt.unverified == ["st_ftp_mode（读回 1，应为 2）"])
    // No read-back: everything sent and confirmed, the result still to be checked.
    let unread = AiDiskRouter(nvram: base)
    await unread.failingReadBack()
    let pending = try await client(unread).saveAiDisk(chosen, adminName: "admin")
    #expect(pending.confirmed == 6 && !pending.receipt.isVerified && pending.receipt.message.contains("重新读取没有完成"))
}

@Test func withoutAMountedDiskNothingCanBeWritten() async throws {
    // diskList with nothing mounted: only 未检测到 USB 磁盘, no wizard, and opening wrote nothing.
    let router = AiDiskRouter(nvram: base, disks: diskScript(mounted: ["0"]))
    let page = try await client(router).aiDiskPage()
    #expect(page.content == .noDisk && !page.offersWizard && page.startWizard() == nil)
    #expect(await router.posts.isEmpty)
    let mounted = try await client(AiDiskRouter(nvram: base)).aiDiskPage()
    #expect(mounted.offersWizard && mounted.startWizard() != nil)
}

@Test func aiDiskIsANativePageOfTheUSBMenu() {
    #expect(WebMenuCatalog.location(of: .aiDisk) == WebLocation(menu: "menu_APP", page: "aidisk.asp", part: "main"))
    let page = WebMenuCatalog.menu("menu_APP")?.page("aidisk.asp")
    #expect(page?.kind == .subpage && page?.parts.first?.content == .native(.aiDisk))
}
