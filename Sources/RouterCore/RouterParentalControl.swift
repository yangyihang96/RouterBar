import Foundation

// 家长管理 › 时间安排（ParentalControl.asp），按 Asuswrt-Merlin 3006.102.5：打开时读取的四条并行列表、设备列表的新增／删除／
// 状态选择、总开关，以及“应用本页面设置”、关闭总开关与时间编辑器“应用本页面设置”按网页脚本构造的同一张表单
// （start_apply.htm），“启用阻止所有设备”的 applyapp.cgi 请求。列表与时间规则的改动只在本页；只有发送请求才写入路由器。

/// What the page reads when it opens (initial 103–199, the form 578–592, state.js) and what follows from it.
public struct ParentalControlPage: Sendable, Equatable {
    static let keys = ["MULTIFILTER_ALL", "MULTIFILTER_ENABLE", "MULTIFILTER_MAC", "MULTIFILTER_DEVICENAME", "MULTIFILTER_MACFILTER_DAYTIME_V2",
                       "MULTIFILTER_BLOCK_ALL", "productid", "firmver", "preferred_lang", "lan_hwaddr", "svc_ready"]
    /// Values the scripts embed between single quotes (104–107, 645, 705, 713; state.js 278, 294, 979).
    static let singleQuoted = ["MULTIFILTER_ENABLE", "MULTIFILTER_MAC", "MULTIFILTER_MACFILTER_DAYTIME_V2", "MULTIFILTER_BLOCK_ALL", "MULTIFILTER_ALL",
                               "productid", "svc_ready", "preferred_lang"]
    /// Hidden inputs the page sends with the value attribute it was served with (579–588).
    static let attributeKeys = ["productid", "firmver", "MULTIFILTER_ALL"]

    public let nvram: EncodedNvram
    public let support: UISupport
    public let clients: [TORSettings.ClientEntry]
    /// `<% uptime(); %>` (state.js 283; web.c ej_uptime): "Tue, 27 Oct 2026 14:05:09 +1100(… since boot)".
    public let uptime: String

    public init(nvram: EncodedNvram, support: UISupport, clients: [TORSettings.ClientEntry], uptime: String) {
        self.nvram = nvram; self.support = support; self.clients = clients; self.uptime = uptime
    }

    // MARK: What the page shows

    var bwdpi: Bool { support.on("bwdpi") }
    /// content_title (138–143, 619): Parental_Control, or with Time_Scheduling where bwdpi is supported.
    public var title: String { bwdpi ? "家长管理 - 时间安排" : "家长管理" }
    /// PC_enable (143, 700).
    public var switchTitle: String { bwdpi ? "开启时间计划" : "开启家长管理" }
    /// `parseInt(isSupport("PC_SCHED_V3"))`.
    var scheduleVersion: Double { support.integer("PC_SCHED_V3") }
    /// `if(isSupport("PC_SCHED_V3"))` (147): the value itself decides, so a text "0" counts.
    public var scheduleV3: Bool { support.on("PC_SCHED_V3") }
    /// block_all_device shows at the end of initial() for `parseInt(isSupport("PC_SCHED_V3")) >= 2` (197–198).
    public var blockAllShown: Bool { scheduleVersion >= 2 }
    /// weekScheduleApi.support_change_schedule_mode and alternate_days (434–437).
    public var schedulesModes: Bool { scheduleVersion >= 3 }
    public var alternateDays: Bool { scheduleVersion >= 1 }
    /// The table's title (229).
    public var listTitle: String { "用户名单 (最多限制： " + support.text("MaxRule_parentctrl") + ")" }
    /// The MAC field's placeholder (249).
    public var macPlaceholder: String { HTMLText.decode("ex: " + nvram.js("lan_hwaddr"), inAttribute: true) }
    /// weekScheduleApi.data_max (132): MaxRule_PC_DAYTIME, 128 where isSupport gives something `== 0`.
    public var ruleMaximum: OrderedJSON {
        let value = support.value("MaxRule_PC_DAYTIME")
        return JavaScriptCompare.looselyZero(value) ? .number("128") : value
    }

    /// The description (134–161, 672–692): its first line, the steps, and the notes under 注意：.
    public struct Description: Sendable, Equatable {
        public let title: String
        public let steps: [String]
        /// nil when the note block is hidden.
        public let notes: [String]?
        /// The NAT note (ParentalCtrl_disable_NAT) is among the notes, linking Advanced_SwitchCtrl_Content.asp?af=ctf_disable_force.
        public let natNote: Bool
    }
    public var description: Description {
        // hnd and these models hide the NAT note (134–136).
        let natHidden = support.on("hnd") || ["RT-AC1200", "RT-AC1200_V2", "RT-AC1200GU", "RT-N19"].contains(nvram.js("productid"))
        let nat = "请禁用 NAT 加速 以进行更精确的计划控制。"
        if scheduleV3 {
            return Description(title: "此功能能够为特定设备的互联网访问设置预定时间。",
                               steps: ["在 [客户名称] 栏，选择您想管理的设备。您也可以在这一栏中手动键入 MAC 地址。", "从「添加 / 移除」栏位点击加号（+）图标新增用户。",
                                       "在 [时间管理] 栏，点击编辑图标，设置时间表。", "点击 [应用] 保存配置。"],
                               notes: natHidden ? nil : [nat], natNote: !natHidden)
        }
        return Description(title: bwdpi ? "时间计划允许您设置客户端的网络使用时间限制。请按照以下步骤使用时间计划：" : "通过家长管理，您可以设置用户使用网络的时间限制，其使用步骤为：",
                           steps: ["从「客户端名称」栏位选择一位您想控制其网络使用的用户。您也可以在「客户端 MAC 地址」栏位输入客户端的 MAC 地址。",
                                   "从「添加 / 移除」栏位点击加号（+）图标新增用户。", "在「时间管理」栏位设置用户的实行计划表。",
                                   "选择允许访问的时间段。拖动并按住可设置更长的时间段。", "点击「确认」保存这些设置。"],
                           notes: ["默认情况下，全时段不允许互联网连接。"] + (natHidden ? [] : [nat]), natNote: !natHidden)
    }

    /// `if(<% nvram_get("MULTIFILTER_ALL"); %>)` (176) and `… != "1"` (458): the value is written into the script as code.
    /// nil when it is not a plain decimal number, for which the app does not guess what the script does.
    var multifilterAllNumber: Double? {
        let text = nvram.js("MULTIFILTER_ALL")
        guard text.range(of: #"^(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil else { return nil }
        return Double(text)
    }

    /// Why the app shows this page without offering its writes.
    public var problems: [String] {
        var problems: [String] = []
        if multifilterAllNumber == nil {
            problems.append("MULTIFILTER_ALL 的值（“\(nvram.raw("MULTIFILTER_ALL"))”）直接写进网页脚本的 if(…)（176、458 行），这样的值会让网页的脚本无法运行或无法按预期运行。")
        }
        for key in Self.singleQuoted where nvram.breaksScript(key, quote: "'") { problems.append("\(key) 的值含有单引号或反斜杠，网页的脚本无法按原样运行。") }
        if SiteSurvey.decodeURIComponent(nvram.encoded["MULTIFILTER_DEVICENAME"] ?? "") == nil {
            problems.append("MULTIFILTER_DEVICENAME 不是有效的 UTF-8，网页初始化第一步的 decodeURIComponent 出错，列表和按钮都不会出现。")
        }
        for key in Self.attributeKeys where nvram.attribute(key) != nvram.raw(key) {
            problems.append("隐藏字段 \(key) 在网页中会按 HTML 实体解码成“\(nvram.attribute(key))”提交，与路由器保存的“\(nvram.raw(key))”不同；本应用不发送这样的请求。")
        }
        return problems
    }

    /// client_time_sche_json as initial() builds it (104–131): one device per non-empty MULTIFILTER_ENABLE entry that has a
    /// MAC and a name entry at its position; the name is the client list's (nickName unless empty) or the stored one (the
    /// script's fallback test, on characters of the unsplit text and joined with ||, always takes the stored one); the
    /// time rules are whatever is at that position, missing (undefined) when the list is shorter.
    public var devices: [ParentalDevice] {
        let enables = javaScriptSplit(javaScriptReplace(nvram.js("MULTIFILTER_ENABLE"), "&#62", ">", all: true), ">")
        let macs = javaScriptSplit(javaScriptReplace(nvram.js("MULTIFILTER_MAC"), "&#62", ">", all: true).uppercased(), ">")
        let names = javaScriptSplit(javaScriptReplace(SiteSurvey.decodeURIComponent(nvram.encoded["MULTIFILTER_DEVICENAME"] ?? "") ?? "", "&#62", ">", all: true), ">")
        let times = javaScriptSplit(WebProtectorPage.unescaped(nvram.js("MULTIFILTER_MACFILTER_DAYTIME_V2")), ">")
        var devices: [ParentalDevice] = []
        for (index, enable) in enables.enumerated() where enable != "" && index < macs.count && index < names.count {
            let mac = macs[index]
            let name = clients.first { $0.mac == mac }.map { $0.nickName.isEmpty ? $0.name : $0.nickName } ?? names[index]
            devices.append(ParentalDevice(enable: enable, mac: mac, devicename: name, offtime: index < times.count ? times[index] : nil))
        }
        return devices
    }

    // MARK: System time

    /// The router's clock (state.js 283–290): "Mon DD HH:MM:SS YYYY" cut from uptime() and parsed by the browser in its own
    /// time zone; nil for a text Date.parse cannot read (the page then shows Invalid Date's pieces).
    public var clock: Date? {
        let units = Array(uptime.utf16)
        func cut(_ start: Int, _ end: Int) -> String { start < units.count ? String(decoding: units[start..<min(end, units.count)], as: UTF16.self) : "" }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let time = cut(17, 25).split(separator: ":").compactMap { Int($0) }
        guard let month = months.firstIndex(of: cut(8, 11)), let day = Int(cut(5, 7)), let year = Int(cut(12, 16)), time.count == 3,
              (1...31).contains(day), (0...23).contains(time[0]), (0...59).contains(time[1]), (0...59).contains(time[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: year, month: month + 1, day: day, hour: time[0], minute: time[1], second: time[2]))
    }
    /// showclock (390–400): `Date.toString()`'s weekday and "Mon DD", then the clock and the year, for the router's clock
    /// counted on by `elapsed` seconds (count_time adds 1000 ms a second).
    public static func clockText(_ clock: Date?, elapsed: Int) -> String {
        guard let clock else { return "Inv, lid Da  NaN:NaN:NaN  NaN" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .current
        formatter.dateFormat = "EEE, MMM dd  HH:mm:ss  yyyy"
        return formatter.string(from: clock.addingTimeInterval(TimeInterval(elapsed)))
    }
    /// The weekday of the router's clock (JS_timeObj, 0 for Sunday), which the schedule editor marks and gives a new rule.
    public static func weekday(_ clock: Date?, elapsed: Int) -> Int? {
        guard let clock else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.component(.weekday, from: clock.addingTimeInterval(TimeInterval(elapsed))) - 1
    }
    /// `svc_ready == "0"` (402–403): the system time is not synchronised with NTP.
    public var notSynchronised: Bool { nvram.js("svc_ready") == "0" }
    /// corrected_timezone (state.js 4151–4169): uptime()'s zone ("+1100") against the computer's own GMT offset now.
    public func zoneDiffers(from zone: TimeZone = .current, at date: Date = Date()) -> Bool {
        let seconds = zone.secondsFromGMT(for: date), minutes = abs(seconds) / 60
        let local = (seconds < 0 ? "-" : "+") + String(format: "%02d%02d", minutes / 60, minutes % 60)
        let units = Array(uptime.utf16)
        let router = units.count > 26 ? String(decoding: units[26..<min(31, units.count)], as: UTF16.self) : ""
        return router != local
    }
}

/// One entry of client_time_sche_json.
public struct ParentalDevice: Sendable, Equatable {
    /// MULTIFILTER_ENABLE: "0" 关闭, "1" 时间, "2" 封锁.
    public var enable: String
    public let mac: String
    public var devicename: String
    /// The device's MULTIFILTER_MACFILTER_DAYTIME_V2 entry; nil where the list had none (undefined).
    public var offtime: String?
    public init(enable: String, mac: String, devicename: String, offtime: String?) {
        self.enable = enable; self.mac = mac; self.devicename = devicename; self.offtime = offtime
    }
}

// MARK: - The page as it runs

/// The page while it is open: client_time_sche_json, the form's MULTIFILTER_ALL, the switches, the add row and what shows.
public struct ParentalControlForm: Sendable, Equatable {
    public let page: ParentalControlPage
    public var devices: [ParentalDevice]
    /// document.form.MULTIFILTER_ALL.
    public var multifilterAll: String
    /// The PC_enable switch's position (the plugin keeps its own state for it).
    public var switchOn: Bool
    /// .switch_on_content shows.
    public var contentShown: Bool
    /// PC_mac.
    public var mac = ""
    /// newrule_Enable, "1" (时间) when drawn.
    public var newEnable = "1"
    /// check_macaddr's hint under the MAC field.
    public var macHint = false
    /// The 启用阻止所有设备 switch's position.
    public var blockAllOn: Bool

    public init(page: ParentalControlPage) {
        self.page = page
        devices = page.devices
        multifilterAll = page.nvram.attribute("MULTIFILTER_ALL")
        switchOn = page.nvram.js("MULTIFILTER_ALL") == "1"
        contentShown = (page.multifilterAllNumber ?? 0) != 0
        blockAllOn = page.nvram.js("MULTIFILTER_BLOCK_ALL") == "1"
    }

    /// The row names (268–269, 316): the client list's name (nickName unless empty) or the device's, as the browser shows it.
    public func name(_ device: ParentalDevice) -> String {
        HTMLText.visible(page.clients.first { $0.mac == device.mac }.map { $0.nickName.isEmpty ? $0.name : $0.nickName } ?? device.devicename, inside: ["div"])
    }

    /// gen_mainTable again: the add row is drawn anew.
    mutating func redraw() { mac = ""; newEnable = "1"; macHint = false }

    /// The PC_enable switch (705–718). Turning it on only shows the list; turning it off hides it and, unless the stored
    /// MULTIFILTER_ALL was "0", applies the page at once (applyRule(1)). Returns that form, if any.
    public mutating func toggleSwitch(systemTime: String) -> ParentalFormSubmission? {
        if switchOn {
            switchOn = false; multifilterAll = "0"; contentShown = false
            if multifilterAll == page.nvram.js("MULTIFILTER_ALL") { return nil }
            return submission(systemTime: systemTime)
        }
        switchOn = true; multifilterAll = "1"; contentShown = true
        return nil
    }

    /// selectAll (350–357): every row's select and entry take the chosen state.
    public mutating func selectAll(_ enable: String) { for index in devices.indices { devices[index].enable = enable } }
    /// genEnableArray_main (545–552): the first entry with the row's MAC takes the row's new state.
    public mutating func setEnable(_ enable: String, at index: Int) {
        if let first = devices.firstIndex(where: { $0.mac == devices[index].mac }) { devices[first].enable = enable }
    }

    public enum AddResult: Sendable, Equatable {
        case added
        case alert(String)
        case hint
        case stopped(String)
    }

    /// addRow_main (455–513).
    public mutating func add() -> AddResult {
        if let stored = page.multifilterAllNumber, stored != 1 { multifilterAll = "1" }
        if javaScriptAtLeast(.number(String(devices.count)), page.support.value("MaxRule_parentctrl")) {
            return .alert("本表仅允许 " + page.support.text("MaxRule_parentctrl") + " 项目！")
        }
        var total = 2
        for device in devices {
            guard let offtime = device.offtime else { return .stopped("设备 \(device.mac) 在 MULTIFILTER_MACFILTER_DAYTIME_V2 中没有对应的项（undefined），网页统计规则数时出错。") }
            if offtime != "" { total += javaScriptSplit(offtime, "<").count }
        }
        if javaScriptAbove(.number(String(total)), page.ruleMaximum) {
            let maximum = TORSettings.javaScriptString(page.ruleMaximum)
            return .alert("规则的最大数量为 \(maximum)。\n为了添加新规则，您可以删除那些未使用的规则。")
        }
        if mac.isEmpty { return .alert("栏位不能为空白") }
        if devices.filter({ $0.mac == mac.uppercased() }).count == 1 { return .alert("此项已纳入列表中。") }
        if ParentalMAC.flag(mac) != 0 { macHint = true; return .hint }
        macHint = false
        let upper = mac.uppercased()
        let name = page.clients.first { $0.mac == upper }.map { $0.nickName.isEmpty ? $0.name : $0.nickName } ?? "New device"
        devices.append(ParentalDevice(enable: newEnable, mac: upper, devicename: name, offtime: "W03E21000700<W04122000800"))
        redraw()
        return .added
    }

    /// deleteRow_main (515–530): every entry with the row's MAC goes; the table is drawn again only once it is empty.
    public mutating func delete(at index: Int) {
        let mac = devices[index].mac
        devices.removeAll { $0.mac == mac }
        if devices.isEmpty { redraw() }
    }

    /// applyRule (359–383): the four lists from client_time_sche_json (the client list's name where it knows the MAC), into
    /// the form (578–592), sent with the named inputs inside it: system_time (725) and the add row's PC_mac (249).
    public func submission(systemTime: String) -> ParentalFormSubmission {
        func joined(_ values: [String]) -> String { values.joined(separator: ">") }
        let names = devices.map { device in page.clients.first { $0.mac == device.mac }.map { $0.nickName.isEmpty ? $0.name : $0.nickName } ?? device.devicename }
        let nvram = page.nvram
        return ParentalFormSubmission(fields: [
            ("productid", nvram.attribute("productid")), ("current_page", "ParentalControl.asp"), ("next_page", ""), ("modified", "0"),
            ("action_wait", "5"), ("action_mode", "apply"), ("action_script", "restart_firewall"), ("firmver", nvram.attribute("firmver")),
            ("MULTIFILTER_ALL", multifilterAll), ("MULTIFILTER_ENABLE", joined(devices.map(\.enable))), ("MULTIFILTER_MAC", joined(devices.map(\.mac))),
            ("MULTIFILTER_DEVICENAME", joined(names)), ("MULTIFILTER_MACFILTER_DAYTIME_V2", joined(devices.map { $0.offtime ?? "undefined" })),
            ("system_time", systemTime), ("PC_mac", mac)
        ])
    }

    /// gen_lantowanTable (430–453): the schedule editor for a device, or why the script stops (a device without its time
    /// entry, or a clock the browser could not read).
    public func scheduleEditor(for index: Int, weekday: Int?, previous: ParentalSchedule.Carry) -> Result<ParentalSchedule, ParentalSchedule.Stop> {
        let device = devices[index]
        var others = 0
        for other in devices where other.mac != device.mac {
            guard let offtime = other.offtime else { return .failure(.init(reason: "设备 \(other.mac) 没有对应的时间规则（undefined），网页统计规则数时出错。")) }
            if offtime != "" { others += javaScriptSplit(offtime, "<").count }
        }
        guard let offtime = device.offtime else { return .failure(.init(reason: "这台设备没有对应的时间规则（undefined），网页读取时出错。")) }
        guard let weekday else { return .failure(.init(reason: "路由器时间无法解析（Invalid Date），网页找不到今天是星期几而出错。")) }
        if let rule = ParentalSchedule.unparsableRule(offtime) {
            return .failure(.init(reason: "这台设备的时间规则“\(rule)”中有无法解析的数字。网页打开编辑器时会把它们变成 null，保存时写成“ll”；本应用不改写这类数据，只显示，请在路由器网页里修改。"))
        }
        return .success(ParentalSchedule(offtime: offtime, changesModes: page.schedulesModes, alternateDays: page.alternateDays,
                                         othersRuleCount: others, maximum: page.ruleMaximum, today: weekday, carry: previous))
    }

    /// The editor's 应用本页面设置 (448–452, saveto_lantowan 532–537): the device takes the editor's rules, the table is drawn
    /// again (the add row with it) and the whole page is applied.
    public mutating func applySchedule(_ offtime: String, at index: Int, systemTime: String) -> ParentalFormSubmission {
        devices[index].offtime = offtime
        redraw()
        return submission(systemTime: systemTime)
    }
    /// The editor's 取消 (cancel_lantowan 539–543).
    public mutating func cancelSchedule() { redraw() }
}

// MARK: - Reading and writing

extension RouterClient {
    /// What the page reads when it opens: its variables, get_ui_support, the client list and uptime().
    public func parentalControlPage() async throws -> ParentalControlPage {
        let nvram = EncodedNvram(encoded: try await readEncodedSettings(ParentalControlPage.keys))
        let support = try await orderedUISupport()
        let clients = TORSettings.clientList(current: try await optionalHook("get_clientlist"), history: try await optionalHook("get_clientlist_from_json_database"),
                                             lanMAC: nvram.raw("lan_hwaddr"), productID: nvram.raw("productid"), amas: support.on("amas"))
        let uptime = try await orderedHook("uptime").map(TORSettings.javaScriptString) ?? ""
        return ParentalControlPage(nvram: nvram, support: support, clients: clients, uptime: uptime)
    }

    /// document.form.submit() (382): the form to start_apply.htm; after its action_wait (5, or `settle`) the five
    /// variables are read back.
    public func applyParentalControl(_ submission: ParentalFormSubmission, settle: Duration? = nil) async throws -> ApplyReceipt {
        try acquireMutation(); defer { releaseMutation() }
        let sent = ["MULTIFILTER_ALL", "MULTIFILTER_ENABLE", "MULTIFILTER_MAC", "MULTIFILTER_DEVICENAME", "MULTIFILTER_MACFILTER_DAYTIME_V2"]
            .compactMap { name in submission.value(name).map { (name, $0) } }
        if try await postParentalForm(submission) == .unrecognized {
            return ApplyReceipt(verified: [], unverified: sent.map(\.0), message: "路由器已接收表单，但回应中没有确认结果。请稍后点“重新读取”核对，不要重复提交。")
        }
        do {
            try await Task.sleep(for: settle ?? .seconds(submission.wait))
            return try await checkSent(sent, success: "已从路由器重新读取，时间安排的设置与提交的一致。")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ApplyReceipt(verified: [], unverified: sent.map(\.0), message: "路由器已接收请求，但暂时读不到设置。请稍后点“重新读取”核对，不要重复提交。")
        }
    }

    /// The 启用阻止所有设备 switch (645–663): httpApi.nvramSet with restart_firewall and no action_wait; the page shows
    /// three seconds of loading, after which (or `settle`) the value is read back.
    public func setBlockAllDevices(_ on: Bool, settle: Duration? = nil) async throws -> ApplyReceipt {
        try acquireMutation(); defer { releaseMutation() }
        let value = on ? "1" : "0"
        try await submitApply(ordered: [("action_mode", "apply"), ("rc_service", "restart_firewall"), ("MULTIFILTER_BLOCK_ALL", value)])
        do {
            try await Task.sleep(for: settle ?? .seconds(3))
            return try await checkSent([("MULTIFILTER_BLOCK_ALL", value)], success: "已从路由器重新读取，阻止所有设备已" + (on ? "启用。" : "关闭。"))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ApplyReceipt(verified: [], unverified: ["MULTIFILTER_BLOCK_ALL"], message: "路由器已接收请求，但暂时读不到设置。请稍后点“重新读取”核对，不要重复提交。")
        }
    }
}
