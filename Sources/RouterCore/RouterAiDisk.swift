import Foundation

// USB 相关应用 › AiDisk（aidisk.asp 在 iframe 中依次载入 aidisk/Aidisk-1～4.asp），按 Asuswrt-Merlin 3006.102.5：父页
// get_AiDisk_status() 给出的 FTP 状态，欢迎页（Aidisk-1）按 diskList.js 判断有无 USB 磁盘及按设置显示的访问地址，共享方式
// （Aidisk-2）、DDNS（Aidisk-3）和最后确认（Aidisk-4）各页的显示、校验与提示。各页发出的请求见 RouterAiDiskRequests.swift。
// 未注明目录的行号指 www/ 下对应文件；web.c 指 httpd/web.c，validator.js、general.js、state.js 指 www/ 下的同名文件。

// MARK: - Parent page (aidisk.asp)

/// What aidisk.asp's `<% get_AiDisk_status(); %>` (aidisk.asp:19) writes for the FTP side, which Aidisk-1 reads through
/// `parent.get_ftp_status()` and `parent.get_share_management_status("ftp")` (Aidisk-1.asp:17–18).
public struct AiDiskStatus: Sendable, Equatable {
    /// get_ftp_status(): `nvram_get_int("enable_ftp")` (web.c:28404–28406), 0 off, 1 on.
    public let ftpStatus: Int
    /// get_share_management_status("ftp"): 2 when st_ftp_force_mode does not exist and st_ftp_mode is 1, otherwise
    /// st_ftp_mode (web.c:28420–28425). appGet answers "" for a missing and an empty variable alike, so the value is taken
    /// from the page the server wrote rather than worked out again.
    public let ftpMode: Int
    /// Why the browser cannot parse the script block these functions are written into, or nil. Then none of the block's
    /// functions exists (get_ftp_status, initial(), the save chain), Aidisk-1's first call throws and the wizard cannot run.
    public let scriptError: String?

    public init(ftpStatus: Int, ftpMode: Int, scriptError: String? = nil) {
        self.ftpStatus = ftpStatus; self.ftpMode = ftpMode; self.scriptError = scriptError
    }

    /// The two functions as websWrite lays them out (web.c:28404–28432); nil when the page has none (no USB support), and
    /// Aidisk-1's first call then throws.
    static func parse(_ page: String) -> AiDiskStatus? {
        guard let status = RouterParser.capture(#"function get_ftp_status\(\)\{\s*return (-?\d+);"#, in: page).flatMap({ Int($0) }),
              let mode = RouterParser.capture(#"else if\(protocol == "ftp"\)\s*return (-?\d+);"#, in: page).flatMap({ Int($0) }) else { return nil }
        return AiDiskStatus(ftpStatus: status, ftpMode: mode, scriptError: scriptError(in: page))
    }

    /// Why the browser cannot run the script element get_AiDisk_status is written into (aidisk.asp:18–241, with initial()
    /// and the save chain), or nil. get_sharedfolder_in_pool puts every folder name between double quotes as it is on the
    /// disk (web.c:28469–28474: 28473 encodes it into folder_name, 28474 writes folder_list[i]), so a name can end its
    /// string early, carry a line break or a bad escape, or hold "</script" and end the element. The element is cut as the
    /// HTML tokenizer cuts it and its text checked by JavaScriptCore's parser, which does not run it.
    static func scriptError(in page: String) -> String? {
        let reason = "网页的 aidisk.asp 把 USB 磁盘上的文件夹名原样写进脚本（web.c 28469–28474），这段脚本按 JavaScript 语法无法解析"
        guard let script = AiDiskScript.element(containing: "function get_ftp_status(){", in: page) else {
            return reason + "（找不到它所在的 script 元素的结尾），网页的 AiDisk 向导无法运行。"
        }
        guard let error = AiDiskScript.syntaxError(script) else { return nil }
        return reason + "（" + error + "），网页的 AiDisk 向导因此无法运行。"
    }
}

/// get_sharedfolder_in_pool exactly as web.c:28433–28480 writes it: `function get_sharedfolder_in_pool(poolName){`, then for
/// each mounted partition `    [else ]if(poolName == "DEVICE"){`, `        return [""` with `, "NAME"` for each folder and
/// `];`, `    }`, and `}` with an empty line; `{}` alone when no disk is read (28434–28437). Used to read back how many folders
/// each partition has (the names are written raw, 28474, so a name with a quote can make one look like more); anything
/// that does not follow this layout with plain string literals is not read.
public struct AiDiskSharedFolders: Sendable, Equatable {
    public struct Pool: Sendable, Equatable { public let device: String; public let folders: [String] }
    public let pools: [Pool]
    /// The page's text after the function's closing line.
    public var rest = ""

    public struct Failure: Error, Sendable, Equatable { public let reason: String }
    static let unreadable = Failure(reason: "文件夹列表不是 web.c 的固定格式")

    /// nil when the page has no get_sharedfolder_in_pool.
    static func parse(_ page: String) -> Result<AiDiskSharedFolders, Failure>? {
        guard let start = page.range(of: "function get_sharedfolder_in_pool(poolName){") else { return nil }
        var scanner = Scanner(units: Array(page[start.upperBound...].utf16))
        if scanner.take("}\n") { return .success(AiDiskSharedFolders(pools: [], rest: scanner.rest)) }
        guard scanner.take("\n") else { return .failure(unreadable) }
        var pools: [Pool] = []
        while !scanner.take("}\n") {
            guard scanner.take(pools.isEmpty ? "    if(poolName == " : "    else if(poolName == "), let device = scanner.literal(),
                  scanner.take("){\n        return [\"\"") else { return .failure(unreadable) }
            var folders: [String] = []
            while !scanner.take("];\n    }\n") {
                guard scanner.take(", "), let name = scanner.literal() else { return .failure(unreadable) }
                folders.append(name)
            }
            pools.append(Pool(device: device, folders: folders))
        }
        return .success(AiDiskSharedFolders(pools: pools, rest: scanner.rest))
    }

    /// The marks of the layout and JavaScript string literals in double quotes, over UTF-16 units.
    struct Scanner {
        let units: [UInt16]
        var index = 0
        var rest: String { String(decoding: units[min(index, units.count)...], as: UTF16.self) }

        mutating func take(_ mark: String) -> Bool {
            let mark = Array(mark.utf16)
            guard index + mark.count <= units.count, Array(units[index..<index + mark.count]) == mark else { return false }
            index += mark.count
            return true
        }

        /// A string literal: no line break, escapes as JavaScript takes them (\x with two hex digits, \u with four or a
        /// code point up to 10FFFF in braces, a backslash before a line break continues the line), and no "</script".
        mutating func literal() -> String? {
            guard take("\"") else { return nil }
            let begin = index
            func hex(_ unit: UInt16) -> UInt32? {
                switch unit {
                case 48...57: UInt32(unit - 48)
                case 65...70: UInt32(unit - 55)
                case 97...102: UInt32(unit - 87)
                default: nil
                }
            }
            while index < units.count {
                let unit = units[index]
                if unit == 34 {
                    let text = String(decoding: units[begin..<index], as: UTF16.self)
                    index += 1
                    return text.range(of: "</script", options: .caseInsensitive) == nil ? text : nil
                }
                if unit == 10 || unit == 13 { return nil }
                guard unit == 92 else { index += 1; continue }
                guard index + 1 < units.count else { return nil }
                switch units[index + 1] {
                case 120:
                    guard index + 3 < units.count, hex(units[index + 2]) != nil, hex(units[index + 3]) != nil else { return nil }
                    index += 4
                case 117:
                    if index + 5 < units.count, (2...5).allSatisfy({ hex(units[index + $0]) != nil }) { index += 6; continue }
                    guard index + 2 < units.count, units[index + 2] == 123 else { return nil }
                    var end = index + 3, value: UInt32 = 0
                    while end < units.count, let digit = hex(units[end]) {
                        value = value * 16 + digit
                        guard value <= 0x10FFFF else { return nil }
                        end += 1
                    }
                    guard end > index + 3, end < units.count, units[end] == 125 else { return nil }
                    index = end + 1
                case 13 where index + 2 < units.count && units[index + 2] == 10:
                    index += 3
                default:
                    index += 2
                }
            }
            return nil
        }
    }
}

// MARK: - USB disks (require/modules/diskList.js)

/// diskList.list() (require/modules/diskList.js:3–143) as far as the welcome page uses it: the storage disks it keeps and
/// their mounted partition counts, which Aidisk-1 adds up (Aidisk-1.asp:30–37).
public struct AiDiskDisks: Sendable, Equatable {
    /// foreign_disk_interface_names(), foreign_disks() and foreign_disk_total_mounted_number() as the server wrote them
    /// (web.c:11777–11880; for no disk, initial_web_hook.c:125–133).
    public let ports: [String]
    public let tags: [String]
    public let mounted: [String]
    /// rc_support as diskList.js wrote it into its usbPortMax line (19).
    public let rcSupport: String

    public init(ports: [String], tags: [String], mounted: [String], rcSupport: String) {
        self.ports = ports; self.tags = tags; self.mounted = mounted; self.rcSupport = rcSupport
    }

    /// `rc_support.charAt(rc_support.indexOf("usbX") + 4)` (19): one UTF-16 unit, nil for "" (indexOf -1 reads unit 3).
    var usbPortMax: UInt16? {
        let units = Array(rcSupport.utf16), mark = Array("usbX".utf16)
        var found = -1
        if units.count >= mark.count {
            for start in 0...(units.count - mark.count) where Array(units[start..<start + mark.count]) == mark { found = start; break }
        }
        let at = found + 4
        return at >= 0 && at < units.count ? units[at] : nil
    }

    /// The mounted counts of the disks list() keeps (61–107): a port whose first character is not above usbPortMax (a text
    /// comparison) and a name that decodes to something; a missing entry reads "undefined".
    var keptCounts: [String] {
        let limit = usbPortMax
        return ports.indices.compactMap { index in
            let first = ports[index].utf16.first
            // `charAt(0) > usbPortMax`: any character is above "", nothing is above anything when it is "".
            if let first, limit.map({ first > $0 }) ?? true { return nil }
            let tag = index < tags.count ? tags[index] : "undefined"
            guard !tag.isEmpty else { return nil }
            return index < mounted.count ? mounted[index] : "undefined"
        }
    }

    /// `mount_num == 0` after `mount_num += usbDevicesList[i].mountNumber` from the number 0 (Aidisk-1.asp:31–37): with a
    /// disk the sum becomes text ("0" followed by each count), which `== 0` reads as a number. Modems and printers add ""
    /// and change nothing, so they are not read.
    public var none: Bool {
        let counts = keptCounts
        guard !counts.isEmpty else { return true }
        return javaScriptNumber("0" + counts.joined()) == 0
    }

    /// The rendered diskList.js; nil when the arrays are not there (the require callback then never runs).
    static func parse(_ script: String) -> AiDiskDisks? {
        func array(_ name: String) -> [String]? {
            // A later declaration of the same function wins, as in JavaScript.
            guard let body = RouterParser.captures(#"function\s+"# + name + #"\s*\(\s*\)\s*\{\s*return\s*\[([^\]]*)\]"#, in: script).last?.first else { return nil }
            return RouterParser.captures(#""([^"]*)""#, in: body).map { $0.first ?? "" }
        }
        guard let ports = array("foreign_disk_interface_names"), let tags = array("foreign_disks"),
              let mounted = array("foreign_disk_total_mounted_number") else { return nil }
        let rc = RouterParser.capture(#""usbPortMax"\s*:\s*'([^'\n]*)'"#, in: script) ?? ""
        return AiDiskDisks(ports: ports, tags: tags, mounted: mounted, rcSupport: rc)
    }
}

// MARK: - Welcome (Aidisk-1.asp)

/// The page texts, from CN.dict under the key named beside each.
public enum AiDiskText {
    public static let welcomeTitle = "欢迎使用 AiDisk 向导"                                     // AiDiskWelcome_title
    public static let usbApplications = "USB 相关应用"                                         // Menu_usb_application
    public static let noDisk = "未检测到 USB 磁盘"                                             // no_usb_found
    public static let introduction = "AiDisk 结合 FTP 设置与华硕 DDNS，让您随时随地轻松分享文件。"   // AiDiskWizard_desp0
    public static let createDDNS = "创建您自己的 DDNS 域名。"                                   // AiDiskWizard_desp1
    public static let setupFTP = "设置 FTP。"                                                 // AiDiskWizard_desp2
    public static let modifyLink = "点击这里"                                                  // web_redirect_suggestion_modify
    public static let modifySuffix = "进行修改。"
    public static let addresses = "您可以使用以下 FTP 地址："                                    // AiDiskWizard_desp3
    public static let internetAddress = "〔互联网 FTP 地址〕"                                    // AiDiskWizard_desp31
    public static let lanAddress = "〔局域网 FTP 地址〕"                                         // AiDiskWizard_desp32
    public static let hostnameNote = "主机名称由您的 DDNS 设置"                                   // AiDiskWizard_desp11
    public static let configuredTitle = "您曾经设置过AiDisk向导，现在可参考以下信息来访问硬盘："     // AiDisk_wizard_text_box_title3
    public static let anonymousHint = "设定为不需要帐号与密码，任何使用者将可能可以不透过认证，存取到您的 FTP 服务!" // AiDisk_shareHint
    public static let ftpOff = ("FTP 服务未开启。若需访问 FTP，请至", "这里", " 开启。")            // linktoFTP_no_1
    public static let ddnsOff = "DDNS 未开启，若需由外部网络以网域名称访问 FTP，请先开启 DDNS。"   // linktoFTP_no_2
    public static let notRegistered = "DDNS 已开启，但网域名称未注册成功，无法由外部网络以网域名称访问 FTP。" // linktoFTP_no_3
    public static let moreConfig = ("若您需要更专业的文件共享设置，例如多组共享权限的规划，共享文件夹的修改，请至 ", "这里", "设置。") // AiDisk_moreconfig
    public static let authorityHint = ("警告：AiDisk 已设置。若您再次设置，之前的帐号/密码与存取 权限都将重置。 欲添加更多帐号，选择 ", "这里", " 以编辑帐户信息。") // Aidisk_authority_hint
    /// alert() of show_share_link's last branch (Aidisk-1.asp:98), in English in the source.
    public static let exception = "FTP and ddns exception"
    public static let shareTitle = "我的 FTP 服务器: 选择您的共享方式。"                         // Step2_method: Step1_desp
    public static let methods = ["0": "不需要帐号密码", "1": "需要帐号才能访问", "2": "只有我可以访问"] // Step2_method1–3
    public static let account = "帐号", password = "密码", read = "读", write = "写"           // AiDisk_Account, HSDPAConfig_Password_itemname, AiDisk_Read/Write
    public static let previous = "上一步", next = "下一步", finish = "保存"                     // CTL_prev, CTL_next, CTL_finish
    public static let ddnsTitle = "使用华硕 DDNS 服务，建立一组您专属的网域名。"                   // Step2_desp
    public static let ddnsAgree = "我愿意使用此服务"                                             // DDNSterm_agreeword
    public static let ddnsOffChoice = "关闭 DDNS。"                                             // neednotDDNS
    public static let finishTitle = "完成设置，立即连接。"                                        // Step3_desp
    public static let shareSetting = "即将设置文件共享方式为："                                    // yoursharesetting
    public static let faq = ("更多细节，请参考", "此常见问题", "。")                               // LANHostConfig_x_DDNSEnable_sectiondesc2
    public static let faqURL = URL(string: "https://www.asus.com/support/FAQ/1050429")!
}

/// What the welcome page shows in the box of an earlier setup (show_share_link, Aidisk-1.asp:58–100).
public struct AiDiskAccessLinks: Sendable, Equatable {
    public enum Hint: Sendable, Equatable { case ftpOff, ddnsOff, notRegistered }
    /// noFTP_Hint, shown for FTP_mode 1 (27–28).
    public var anonymousHint = false
    /// noWAN_link (81–97).
    public var hint: Hint?
    /// ddnslink1/ddnslink2 (61–79): "Internet FTP address: ftp://…" with the DDNS name.
    public var internet: String?
    /// ddnslink*_LAN in desc_2: "LAN FTP address: ftp://…" with lan_ipaddr.
    public var lan: String?
    /// The alert of the last branch (97–98).
    public var exception = false
}

/// aidisk.asp with its welcome page Aidisk-1.asp as they open.
public struct AiDiskPage: Sendable, Equatable {
    /// Aidisk-1.asp:16–22 and the address in its text (148).
    static let keys = ["dummyShareway", "ddns_enable_x", "ddns_server_x", "ddns_hostname_x", "lan_ipaddr"]
    /// nil when aidisk.asp has no get_AiDisk_status output.
    public let status: AiDiskStatus?
    public let values: [String: String]
    /// nil when diskList.js could not be read.
    public let disks: AiDiskDisks?

    public init(status: AiDiskStatus?, values: [String: String], disks: AiDiskDisks?) {
        self.status = status; self.values = values; self.disks = disks
    }

    public enum Content: Sendable, Equatable {
        /// No get_AiDisk_status (`parent.get_ftp_status` is not a function): the script stops at its first line and the
        /// page keeps its markup's default, the introduction (140–153).
        case unsupported
        /// diskList.js unreadable: the require callback never runs and the introduction stays (140–153).
        case unknownDisks
        /// The parent's script block does not parse (AiDiskStatus.scriptError): as `unsupported`, the introduction stays.
        case scriptError(String)
        /// Nodisk_hint alone (37–41).
        case noDisk
        /// AiDiskWelcome_desp, never set up (dummyShareway "", 49–51).
        case introduction
        /// linkdiskbox after an earlier setup (43–48).
        case configured(AiDiskAccessLinks)
    }

    public var content: Content {
        guard let status else { return .unsupported }
        if let reason = status.scriptError { return .scriptError(reason) }
        guard let disks else { return .unknownDisks }
        if disks.none { return .noDisk }
        if (values["dummyShareway"] ?? "").isEmpty { return .introduction }
        return .configured(links(status))
    }

    public var lanAddress: String { "ftp://" + (values["lan_ipaddr"] ?? "") }

    /// show_share_link (58–100) with the page's loose comparisons: text against a number compares as numbers.
    func links(_ status: AiDiskStatus) -> AiDiskAccessLinks {
        var links = AiDiskAccessLinks()
        links.anonymousHint = status.ftpMode == 1
        let enabled = javaScriptNumber(values["ddns_enable_x"]) == 1
        let server = values["ddns_server_x"] ?? "", host = values["ddns_hostname_x"] ?? ""
        let share = values["dummyShareway"] ?? ""
        if status.ftpStatus == 1, enabled, !server.isEmpty, !host.isEmpty {
            // ddnslink1 for FTP_mode 1 or dummyShareway == 0, ddnslink2 for FTP_mode 2 (same text); neither otherwise.
            if status.ftpMode == 1 || javaScriptNumber(share) == 0 || status.ftpMode == 2 {
                links.internet = "Internet FTP address: ftp://" + host
                links.lan = "LAN FTP address: " + lanAddress
            }
        } else if status.ftpStatus != 1 {
            links.hint = .ftpOff
        } else if !enabled {
            links.hint = .ddnsOff
            links.lan = "LAN FTP address: " + lanAddress
        } else if host.isEmpty {
            links.hint = .notRegistered
        } else {
            links.exception = true
        }
        return links
    }

    /// The wizard is offered only where the page found a mounted USB disk; without one (or without being able to tell) the
    /// page has nothing to set up and no request is built.
    public var offersWizard: Bool {
        switch content {
        case .introduction, .configured: true
        case .unsupported, .unknownDisks, .noDisk, .scriptError: false
        }
    }

    /// aidisk.asp's forms as initial() leaves them (24–41, 232, 251–280): dummyShareway from nvram, "" made 0, and
    /// window.ddns_enable_x as nvram_get wrote it. nil without a disk.
    public func startWizard() -> AiDiskWizard? {
        guard offersWizard else { return nil }
        let share = values["dummyShareway"] ?? ""
        return AiDiskWizard(dummyShareway: share.isEmpty ? "0" : share, ddnsEnable: values["ddns_enable_x"] ?? "")
    }
}

/// aidisk.asp's own state the wizard pages change through `parent.`: applyForm's dummyShareway (252), parameterForm's
/// accountNum and Family fields (271–280) and the window's ddns_enable_x (232–240).
public struct AiDiskWizard: Sendable, Equatable {
    public internal(set) var dummyShareway: String
    public internal(set) var accountNum = "0"
    public internal(set) var account1 = ""
    public internal(set) var passwd1 = ""
    public internal(set) var permission1 = ""
    public internal(set) var ddnsEnable: String

    init(dummyShareway: String, ddnsEnable: String) { self.dummyShareway = dummyShareway; self.ddnsEnable = ddnsEnable }

    /// setASUSDDNS_enable (234–236), called by Aidisk-3.
    public mutating func setDDNSEnable(_ flag: String) { ddnsEnable = flag }
}

// MARK: - Share method (Aidisk-2.asp)

/// Aidisk-2.asp as it opens: the name and address it writes (37, 58, 74), dummyShareway (26) and state.js's ttc.
public struct AiDiskShareStep: Sendable, Equatable {
    static let keys = ["dummyShareway", "http_username", "lan_hwaddr", "territory_code"]
    public let values: [String: String]

    public init(values: [String: String]) { self.values = values }

    /// is_KR_sku: `ttc.search("KR") != -1` (state.js:304–309); the page then hides 不需要帐号密码 (30–33).
    public var koreanSKU: Bool { (values["territory_code"] ?? "").contains("KR") }
    public var adminName: String { values["http_username"] ?? "" }
    /// The choices in page order (212–220), without 0 for a Korean SKU.
    public var options: [String] { koreanSKU ? ["2", "1"] : ["2", "1", "0"] }

    /// "family" and the last two groups of lan_hwaddr in lower case (37, 61); nil where `split(':')` leaves fewer than two
    /// parts and `undefined.toLowerCase()` throws.
    public var familyDefaultPassword: String? {
        let parts = (values["lan_hwaddr"] ?? "").components(separatedBy: ":")
        guard parts.count >= 2 else { return nil }
        return "family" + parts[parts.count - 2].lowercased() + parts[parts.count - 1].lowercased()
    }

    /// The form (smartForm, 168–274) and what of it shows.
    public struct Form: Sendable, Equatable {
        /// The checked dummyoption.
        public var option: String
        /// userpasswd2 (245): text, maxlength 32.
        public var password: String
        /// share0_Hint (223–225).
        public var anonymousHint: Bool
        /// share1, the account table (227–250), and its two rows target1 and target2.
        public var table: Bool
        public var adminRow: Bool
        public var familyRow: Bool
        /// The texts showtext put into user1 and user2.
        public var user1: String
        public var user2: String
    }

    /// The markup's default (all shown, empty) and then showTextinWizard(2) from initial() (34): 只有我可以访问, every
    /// time the page opens, whatever was chosen before.
    public func initialForm(_ wizard: inout AiDiskWizard) -> Form {
        var form = Form(option: "", password: "", anonymousHint: true, table: true, adminRow: true, familyRow: true, user1: "", user2: "")
        // initial() first copies nvram's dummyShareway into the parent, "" made 0 (26–28).
        let stored = values["dummyShareway"] ?? ""
        wizard.dummyShareway = stored.isEmpty ? "0" : stored
        select("2", &form, wizard: &wizard)
        return form
    }

    /// showTextinWizard (38–83), run by initial() and by every click on a choice, the checked one included: it sets the
    /// parent's dummyShareway first; choosing 1 fills in the default Family password again, and where that throws the
    /// rows stay as they were.
    public func select(_ option: String, _ form: inout Form, wizard: inout AiDiskWizard) {
        switch option {
        case "0":
            wizard.dummyShareway = option; form.option = option
            form.anonymousHint = true; form.table = false; form.adminRow = false; form.familyRow = false
        case "1":
            wizard.dummyShareway = option; form.option = option
            form.user1 = adminName; form.user2 = "Family"
            guard let password = familyDefaultPassword else { return }
            form.password = password
            form.anonymousHint = false; form.table = true; form.adminRow = true; form.familyRow = true
        case "2":
            wizard.dummyShareway = option; form.option = option
            form.user1 = adminName
            form.anonymousHint = false; form.table = true; form.adminRow = true; form.familyRow = false
        default:
            // alert("System error: No this choice") (82); no choice of the page leads here.
            break
        }
    }

    public enum Next: Sendable, Equatable {
        /// passTheResult's parent fields (86–137) and the smartForm it posts to Aidisk-3.asp (139–140).
        case proceed(accountNum: String, account1: String, passwd1: String, permission1: String, request: AiDiskRequest)
        /// checkPasswdValid's alert (148–163); the page then posts the form back to Aidisk-2.asp (116–118), which opens
        /// again with 只有我可以访问 (34).
        case invalid(String)
    }

    /// 下一步 (passTheResult, 85–141).
    public func next(_ form: Form) -> Next {
        switch form.option {
        case "1":
            if form.password.utf16.isEmpty { return .invalid("密码不能为空!") }  // File_Pop_content_alert_desc6
            if let alert = WebValidator.secretString(form.password) { return .invalid(alert) }
            return .proceed(accountNum: "2", account1: form.user2, passwd1: form.password, permission1: "1", request: openDDNS(form))
        case "0":
            return .proceed(accountNum: "0", account1: "", passwd1: "", permission1: "", request: openDDNS(form))
        default:
            return .proceed(accountNum: "1", account1: "", passwd1: "", permission1: "", request: openDDNS(form))
        }
    }

    /// The smartForm as submitted to Aidisk-3.asp: its own hidden fields (169–175), which passTheResult leaves empty (it
    /// writes the parent's), the checked dummyoption and userpasswd2 (shown or not), in document order.
    func openDDNS(_ form: Form) -> AiDiskRequest {
        let hidden = ["accountNum", "account0", "passwd0", "permission0", "account1", "passwd1", "permission1"].map { AiDiskField($0, "") }
        return AiDiskRequest(.openDDNS, path: "aidisk/Aidisk-3.asp", fields: hidden + [AiDiskField("dummyoption", form.option), AiDiskField("userpasswd2", form.password)])
    }
}

extension AiDiskWizard {
    /// passTheResult's writes to the parent's parameterForm.
    public mutating func accept(_ next: AiDiskShareStep.Next) {
        guard case .proceed(let number, let account, let password, let permission, _) = next else { return }
        accountNum = number; account1 = account; passwd1 = password; permission1 = permission
    }
}

// MARK: - validator.js

extension WebValidator {
    /// validator.string (validator.js:1858–1895) on a field's value: a `"` first or last, or any UTF-16 unit outside
    /// " "…"~" (all of them listed), is refused with the alert's text (JS_validstr1–3).
    static func string(_ value: String) -> String? {
        let units = Array(value.utf16)
        if units.first == 0x22 { return "第一个字符不能是： [\"]" }
        if units.last == 0x22 { return "最后一个字符不能是： [\"]" }
        let invalid = units.filter { $0 < 0x20 || $0 > 0x7E }
        if !invalid.isEmpty { return "本字符串无法包含： '" + String(decoding: invalid, as: UTF16.self) + "' !" }
        return nil
    }
    /// validator.string for a password: the same checks, but the characters the page would list are not shown.
    static func secretString(_ value: String) -> String? {
        guard let alert = string(value) else { return nil }
        return alert.hasPrefix("本字符串无法包含") ? "本字符串无法包含：英文半角可打印字符（空格至 ~）以外的字符。为保护密码，这里不显示具体字符。" : alert
    }

    /// validator.isString (validator.js:942–951) on key press: a key whose code is 0–126 goes in; any other is refused
    /// with alert("无效字符！") (JS_validchar).
    public static func isStringKeyPress(_ key: Character) -> Bool {
        guard let scalar = key.unicodeScalars.first, key.unicodeScalars.count == 1 else { return false }
        return scalar.value <= 126
    }
    public static let invalidCharacter = "无效字符！"

    /// validator.hostNameChar (validator.js:324–332): ASCII letters, digits, "-" and ".".
    static func hostNameChar(_ unit: UInt16) -> Bool {
        (48...57).contains(unit) || (97...122).contains(unit) || (65...90).contains(unit) || unit == 45 || unit == 46
    }
}

// MARK: - DDNS (Aidisk-3.asp)

/// Aidisk-3.asp as the router wrote it when the wizard opened it: the four values its script starts from (17–20). The
/// return code is the one read just before the router cleared it (web.c:1482–1485).
public struct AiDiskDDNSStep: Sendable, Equatable {
    public let server: String
    public let hostname: String
    public let oldName: String
    public let returnCode: String

    public init(server: String, hostname: String, oldName: String, returnCode: String) {
        self.server = server; self.hostname = hostname; self.oldName = oldName; self.returnCode = returnCode
    }

    /// The four `var x = '…';` lines; the text between the quotes is what nvram_get wrote (entities kept, as the script
    /// sees it). nil when one is missing, e.g. a value with a quote, which ends the page's script there.
    static func parse(_ page: String) -> AiDiskDDNSStep? {
        func value(_ name: String) -> String? { RouterParser.capture("var " + name + #" = '([^'\n]*)';"#, in: page) }
        guard let server = value("ddns_server_x"), let host = value("ddns_hostname_x"), let old = value("ddns_old_name"),
              let code = value("ddns_return_code") else { return nil }
        return AiDiskDDNSStep(server: server, hostname: host, oldName: old, returnCode: code)
    }

    /// asusddns_inputhint, the name field's value until it is clicked (cleandef, 219–222).
    public static let inputHint = "请输入名称"

    /// initial() (27–36): with the ASUS service and a name, the part before ".asuscomm.com" (`substring(0, -1)` is ""
    /// when the suffix is missing); otherwise, or when that part is empty, the hint.
    public var initialName: String {
        guard server == "WWW.ASUS.COM", !hostname.isEmpty else { return Self.inputHint }
        let units = Array(hostname.utf16), suffix = Array(".asuscomm.com".utf16)
        var at = -1
        if units.count >= suffix.count {
            for start in 0...(units.count - suffix.count) where Array(units[start..<start + suffix.count]) == suffix { at = start; break }
        }
        let title = String(decoding: units[0..<max(0, at)], as: UTF16.self)
        return title.isEmpty ? Self.inputHint : title
    }

    /// switch_ddns → show_TOS_checkbox → check_return_code at initial() (37, 70–71): only when the router's server is
    /// WWW.ASUS.COM; afterwards the page's return code is "" (97), so switching choices shows nothing new.
    public var initialAlert: String? {
        server == "WWW.ASUS.COM" ? Self.checkReturnCode(returnCode, hostname: hostname, oldName: oldName) : nil
    }
    /// The script's ddns_return_code after initial(): emptied by check_return_code (97) when it ran, otherwise as read.
    /// checkDDNSReturnCode keeps it where /ajax_ddnscode.asp sets nothing.
    public var codeAfterOpening: String { server == "WWW.ASUS.COM" ? "" : returnCode }

    /// check_return_code (84–98): nothing for no_change; Time-out shows LANHostConfig_x_DDNS_alarm_12 instead.
    public static func checkReturnCode(_ code: String, hostname: String, oldName: String) -> String? {
        guard code != "no_change" else { return nil }
        let hint = state(code, hostname: hostname, oldName: oldName)
        guard !hint.isEmpty else { return nil }
        return code == "Time-out" ? "DDNS 服务器没有响应。" : hint
    }

    /// getDDNSState (general.js:2019–2065): the codes are found as parts of the text, in this order.
    public static func state(_ code: String, hostname: String, oldName: String) -> String {
        func has(_ part: String) -> Bool { code.contains(part) }
        if has("-1") { return "注册错误，请再试一次。" }                                      // LANHostConfig_x_DDNS_alarm_2
        if has("200") { return "注册成功。" }                                               // _3
        if has("203") { return "该网域名称 '" + hostname + "' 已有人使用。" }                    // _hostname, _registered
        if has("220") { return "原主机名称更新成功。" }                                        // _4
        if has("230") { return "新主机名称注册成功。" }                                        // _5
        if has("233") { return "该网域名称 '" + hostname + "' 已有人使用，而且您已注册 ： '" + oldName + "'" } // _registered_2
        if has("296") { return "IP与主机名称尚未注册，请先注册。" }                               // _6
        if has("297") { return "主机名不能为数字前缀与 '.'（如 '123abc' 或 'aaa.bbb' ）" }         // _7
        if has("298") { return "网域名称错误，格式须为'xxx.asuscomm.com'。" }                     // _8
        if has("299") { return "注册失败(IP 地址格式不正确)。" }                                  // _9 (CN.dict:460)
        if has("390") { return "Server Error" }
        if has("401") { return "不合法的注册请求。" }                                          // _10
        if has("402") { return "注册被阻止，请将固件更新为最新版本。" }                             // _15
        if has("407") { return "客户端请求错误，客户端经由需要认证的 Proxy 连上网络。" }              // _11
        switch code {
        case "Time-out": return "DDNS 服务器没有响应，请再试一次。"                              // _1
        case "unknown_error": return "注册错误，请再试一次。"
        case "connect_fail": return "无法连接到互联网"                                         // qis_fail_desc7
        case "no_change": return "自上次更新后主机名与 IP 地址都未变更。"                          // _nochange
        case "ddns_query": return "处理中"                                                    // Main_alert_processing
        case "auth_fail": return "授权失败"                                                   // qis_fail_desc1
        case "": return ""
        default: return "注册错误，请再试一次。"
        }
    }

    public enum NameCheck: Sendable, Equatable {
        case valid
        /// show_alert_block: the text under the name field (74–78).
        case block(String)
        /// validator.string's alert().
        case alert(String)
    }

    /// validate_ddns_hostname (140–175): blank, a digit first, validator.string, then each unit: any "." refuses (the dot
    /// count is above 0 at once), then hostNameChar. No maxlength on this field (274).
    public static func validate(_ name: String) -> NameCheck {
        if name.isEmpty { return .block("用户名称不能空白！") }                                  // QKSet_account_nameblank
        let alarm7 = "主机名不能为数字前缀与 '.'（如 '123abc' 或 'aaa.bbb' ）"                      // LANHostConfig_x_DDNS_alarm_7
        if let first = name.utf16.first, (0x30...0x39).contains(first) { return .block(alarm7) }
        if let alert = WebValidator.string(name) { return .alert(alert) }
        for unit in name.utf16 {
            if unit == 46 { return .block(alarm7) }
            if !WebValidator.hostNameChar(unit) { return .block("网域名称包含无效字符 '" + String(decoding: [unit], as: UTF16.self) + "' !") } // _alarm_13
        }
        return .valid
    }

    /// What checkDDNSReturnCode does with a code (191–217): ddns_query reads again after 500 ms, the three registered
    /// codes and no_change go on to the last step with DDNS on, anything else is check_return_code — with the name and
    /// old name the page opened with (the script does not read them again).
    public enum Outcome: Sendable, Equatable { case waiting, registered, failed(String?) }
    public func outcome(_ code: String) -> Outcome {
        if code == "ddns_query" { return .waiting }
        if ["register,200", "register,220", "register,230", "no_change"].contains(code) { return .registered }
        return .failed(Self.checkReturnCode(code, hostname: hostname, oldName: oldName))
    }

    /// verify_ddns_name's form (100–120, 229–239, 269–281) in document order: FormActions keeps action_mode and the
    /// script and changes the wait from 15 to 1; switch_ddns and show_TOS_checkbox put WWW.ASUS.COM and 1 in place for the
    /// first choice; the checked radio has no value attribute and so goes as "on"; the request carries no ddns_enable_x.
    public static func registration(name: String) -> AiDiskRequest {
        AiDiskRequest(.registerDDNS, path: "start_apply.htm", fields: [
            AiDiskField("current_page", "/aidisk/Aidisk-3.asp"), AiDiskField("next_page", ""), AiDiskField("group_id", ""),
            AiDiskField("action_mode", "apply"), AiDiskField("action_script", "aidisk_asusddns_register"), AiDiskField("action_wait", "1"),
            AiDiskField("asusddns_tos_agreement", "1"), AiDiskField("ddns_server_x", "WWW.ASUS.COM"),
            AiDiskField("ddns_hostname_x", name + ".asuscomm.com"), AiDiskField("flag", "nodetect"),
            AiDiskField("check_asus_ddns", "on"), AiDiskField("DDNSName", name)
        ])
    }

    /// The `ddns_return_code = '…'` that /ajax_ddnscode.asp sets (191–198, dataType script). The file is not in the
    /// firmware source at hand, so only this assignment is read; nil when the answer has none.
    static func ajaxCode(_ script: String) -> String? {
        RouterParser.capture(#"ddns_return_code\s*=\s*(['"])([^'"\n]*)\1"#, in: script, group: 2)
    }
}

// MARK: - Finish (Aidisk-4.asp)

/// Aidisk-4.asp as it opens (16–22, 80, 181): enable_ftp, the DDNS name and wanlink_ipaddr().
public struct AiDiskFinishStep: Sendable, Equatable {
    static let keys = ["enable_ftp", "ddns_server_x", "ddns_hostname_x"]
    public let values: [String: String]
    public let wanIP: String

    public init(values: [String: String], wanIP: String) { self.values = values; self.wanIP = wanIP }

    /// show_dummyshareway (35–49): the parent's choice between double quotes; nothing for another value.
    public static func method(_ dummyShareway: String) -> String? {
        AiDiskText.methods[dummyShareway].map { "\"" + $0 + "\"" }
    }

    /// 上一步 (go_pre_page, 100–103): redirectForm posts to Aidisk-3.asp; it holds no named control (the buttons have no
    /// name), so the body is empty. Loading Aidisk-3.asp clears the DDNS return code as on the way from step 2.
    public static let back = AiDiskRequest(.openDDNS, path: "aidisk/Aidisk-3.asp", fields: [])

    /// ddns_hostname_x as this page reads it (18); after a registration it is the name read back.
    public var hostname: String { values["ddns_hostname_x"] ?? "" }

    public struct Display: Sendable, Equatable {
        /// haveDDNS (179–183).
        public var internet: String?
        /// priv_wan_ip (184–186).
        public var privateWAN = false
        /// noDDNS (192–194). noFTP (188–190) is hidden in every branch.
        public var ddnsOff = false
    }

    /// showDDNS (78–98): only with enable_ftp "1" anything shows (FTP off shows no hint at all); with the parent's DDNS
    /// choice "1" the Internet address and, by valid_wan_ip (51–76), the note for an address strictly inside 10/8,
    /// 172.16/12 or 192.168/16 or equal to 0 (inet_network, general.js:7–23).
    public func display(ddnsEnable: String) -> Display {
        guard values["enable_ftp"] == "1" else { return Display() }
        guard ddnsEnable == "1" else { return Display(ddnsOff: true) }
        // valid_wan_ip is valid_is_wan_ip of cloud_main.asp line for line.
        return Display(internet: "Internet FTP address: ftp://" + (values["ddns_hostname_x"] ?? ""), privateWAN: AiCloudPage.validIsWanIP(wanIP) == 0)
    }
}
