import Foundation

// 家长管理 › 网页与 Apps 过滤（AiProtection_WebProtector.asp），按 Asuswrt-Merlin 3006.102.5：打开时由两条后端规则串还原的
// 类别矩阵、规则表、新增／删除／勾选对本页数据的影响，以及总开关与“应用本页面设置”按网页脚本构造的同一张表单
// （start_apply.htm）和 Trend Micro 条款（set_TM_EULA.cgi）。勾选、新增、删除只改本页；只有发送表单或条款请求才写入路由器。

/// What the page reads when it opens (1–84, the form 835–850) and what follows from it.
public struct WebProtectorPage: Sendable, Equatable {
    /// The variables the page (55–57, 69, 352, 574–575, 835–850) and state.js (ui_lang, wans_mode, wans_dualwan, wlc_band,
    /// reboot_time) read for it, and TM_EULA_time for the terms check (asus_policy.js 816–838).
    static let keys = ["wrs_rulelist", "wrs_app_rulelist", "wrs_enable", "wrs_app_enable", "TM_EULA", "TM_EULA_time", "ctf_disable", "ctf_fa_mode",
                       "productid", "firmver", "preferred_lang", "lan_hwaddr", "wlc_band", "wans_dualwan", "wans_mode", "reboot_time"]
    /// Values the page's scripts embed between single quotes (69, 77, 574–575, 922; state.js 255, 278, 945, 4433, 4481, 979).
    static let singleQuoted = ["wrs_enable", "ctf_disable", "ctf_fa_mode", "wans_mode", "wlc_band", "wans_dualwan", "preferred_lang", "productid", "reboot_time"]
    /// Values between double quotes (55–57); nvram_get escapes `"` itself, so only a backslash matters.
    static let doubleQuoted = ["wrs_rulelist", "wrs_app_rulelist"]
    /// Hidden inputs whose value attribute is `<% nvram_get(name); %>` (836–850).
    static let attributeKeys = ["productid", "firmver", "wrs_enable", "wrs_app_enable", "TM_EULA"]

    public let nvram: EncodedNvram
    public let support: UISupport
    public let clients: [TORSettings.ClientEntry]
    /// get_default_reboot_time() (web.c 42278–42293), the reboot's action_wait (675).
    public let rebootTime: String
    /// `<%bwdpi_engine_status();%>` in state.js (4416–4425; web.c 32699–32716).
    public let dpiStatus: OrderedJSON?
    /// get_operation_mode() (web.c 41323–41387) for isSwMode (state.js 266–270).
    public let operationMode: String

    public init(nvram: EncodedNvram, support: UISupport, clients: [TORSettings.ClientEntry], rebootTime: String, dpiStatus: OrderedJSON?, operationMode: String) {
        self.nvram = nvram; self.support = support; self.clients = clients; self.rebootTime = rebootTime; self.dpiStatus = dpiStatus; self.operationMode = operationMode
    }

    // MARK: Categories (59–67, 321–329)

    public struct Category: Sendable, Equatable {
        public let title: String
        public let description: String
        public let items: [String]
    }
    /// category_name, category_desc and sub_category_name in page order (CN.dict 1491–1521).
    public static let categories = [
        Category(title: "成人", description: "禁用成人内容可以防止孩子访问色情、暴力和非法的相关内容。", items: ["色情", "非法活动及暴力", "赌博"]),
        Category(title: "即时信息和通信", description: "禁用即时信息和通信内容可以防止孩子沉迷于社交网络的使用。", items: ["网络电话", "即时通讯", "虚拟社区", "博客", "移动设备"]),
        Category(title: "P2P 和文件传输", description: "禁用 P2P 和文件传输能够让您的网络拥有更好的传输质量", items: ["文件传输", "点对点 (P2P)"]),
        Category(title: "流媒体和娱乐", description: "禁用互联网广播和电视能够避免您的小孩花费过长时间在互联网上的娱乐", items: ["游戏", "影音直播串流", "互联网广播和电视"])
    ]
    /// wrs_id_array and apps_id_array (59–67): the IDs each item stands for in wrs_rulelist and wrs_app_rulelist; "" for none.
    static let wrsIDs = [["1,2,3,4,5,6,8", "9,10,14,15,16,25,26", "11"], ["24", "51", "53,89", "42", ""], ["56,70,71", "57"], ["", "69", "23"]]
    static let appIDs = [["22", "", ""], ["24", "0,6,15", "", "", "21"], ["3", "1"], ["8", "4", ""]]

    // MARK: What the page shows

    /// ui_lang (state.js 979), which the FAQ link carries (70).
    public var language: String { nvram.js("preferred_lang") }
    /// faq_href (70): FAQ number 140.
    public var faq: URL? { AsusSupportLink.faq("140", lang: language) }
    /// The placeholder of the MAC field (352): "ex: " and lan_hwaddr, read as HTML.
    public var macPlaceholder: String { HTMLText.decode("ex: " + nvram.js("lan_hwaddr"), inAttribute: true) }
    /// The table's title (336): ConnectedClient and List_limit with MaxRule_bwdpi_wrs as the script joins it.
    public var listTitle: String { "用户名单 (最多限制： " + support.text("MaxRule_bwdpi_wrs") + ")" }
    /// apps_filter / wrs_filter and wrs_app_filter (55–57): the stored lists with &#62 and &#60 turned back.
    var wrsFilter: String { Self.unescaped(nvram.js("wrs_rulelist")) }
    var appFilter: String { Self.unescaped(nvram.js("wrs_app_rulelist")) }
    static func unescaped(_ text: String) -> String { javaScriptReplace(javaScriptReplace(text, "&#62", ">", all: true), "&#60", "<", all: true) }
    /// `'<% nvram_get("wrs_enable"); %>' == 1` (77): the list shows once initial() gets that far.
    var listOnLoad: Bool { javaScriptLooselyEquals(nvram.js("wrs_enable"), 1) }

    /// translate_category_id (687–762) on the stored lists: the list the page edits, or nil where it throws (a missing
    /// wrs_app_rulelist row or column, a row with more than six columns), which stops initial() before the table.
    public var initialFilter: String? { Self.translated(wrs: wrsFilter, apps: appFilter) }

    // MARK: Conditions of the switch and applyRule

    /// `amesh_support && (isSwMode("RT") || isSwMode("WISP")) && ameshRouter_support` (580).
    var appliesAiMesh: Bool { support.on("amas") && ["rt", "wisp"].contains(operationMode) && support.on("amasRouter") }
    /// `ctf_disable == 0 && ctf_fa_mode == 2` (659): hardware acceleration in this mode restarts the router.
    public var accelerationReboots: Bool { javaScriptLooselyEquals(nvram.js("ctf_disable"), 0) && javaScriptLooselyEquals(nvram.js("ctf_fa_mode"), 2) }
    /// check_bwdpi_engine_status (state.js 4416–4425): bwdpi and `DpiEngine == 1`.
    var dpiEngineOn: Bool { support.on("bwdpi") && javaScriptToNumber(dpiStatus?["DpiEngine"]) == 1 }
    /// dualwan_enabled (state.js 565, 945, 968): dualWAN_support (no wlc_band and isSupport("dualwan")) with "none" nowhere
    /// in wans_dualwan.
    var dualWANEnabled: Bool { nvram.js("wlc_band") == "" && support.on("dualwan") && !javaScriptContains(nvram.js("wans_dualwan"), "none") }
    /// reset_wan_to_fo.check_bwdpi_dual_wan (state.js 4444–4447): DPI not running and dual WAN in load balance.
    public var asksDualWAN: Bool { !dpiEngineOn && dualWANEnabled && nvram.js("wans_mode") == "lb" }
    /// `policy_status.TM == 0 || policy_status.TM_time == ''` (800), on the values PolicyStatus() read.
    public var asksTrendMicro: Bool { javaScriptLooselyEquals(nvram.raw("TM_EULA"), 0) || nvram.raw("TM_EULA_time") == "" }

    /// Why the app shows this page without offering its writes: values that change how the page's scripts run.
    public var problems: [String] {
        var problems: [String] = []
        for key in Self.singleQuoted where nvram.breaksScript(key, quote: "'") { problems.append("\(key) 的值含有单引号或反斜杠，网页的脚本无法按原样运行。") }
        for key in Self.doubleQuoted where nvram.breaksScript(key, quote: "\"") { problems.append("\(key) 的值含有反斜杠，网页脚本读到的规则会与保存的不同。") }
        for key in Self.attributeKeys where nvram.attribute(key) != nvram.raw(key) {
            problems.append("隐藏字段 \(key) 在网页中会按 HTML 实体解码成“\(nvram.attribute(key))”提交，与路由器保存的“\(nvram.raw(key))”不同；本应用不发送这样的请求。")
        }
        if rebootTime.range(of: #"^(0|[1-9][0-9]*)$"#, options: .regularExpression) == nil {
            problems.append("路由器没有给出有效的默认重启时间（get_default_reboot_time）。")
        }
        return problems
    }

    // MARK: The lists

    /// translate_category_id: each wrs_rulelist row with its enable and MAC, and for each category the items whose ID
    /// appears in the row's wrs_rulelist or wrs_app_rulelist column (indexOf, so a part of a longer ID counts). Rows are
    /// paired by position, not by MAC.
    static func translated(wrs: String, apps: String) -> String? {
        guard !(wrs.isEmpty && apps.isEmpty) else { return "" }
        // apps_filter_row is apps_filter (still the wrs list) split at "<", or "" when it is empty; wrs_filter_row and
        // wrs_app_filter_row split both lists.
        let appsRows: [String]? = wrs.isEmpty ? nil : javaScriptSplit(wrs, "<")
        let wrsRows = javaScriptSplit(wrs, "<"), appRows = javaScriptSplit(apps, "<")
        var out = ""
        for i in wrsRows.indices {
            // `apps_filter_row[i].split` and `wrs_app_filter_row[i].split` throw for a row that is not there.
            guard let appsRows, i < appsRows.count, i < appRows.count else { return nil }
            let appsColumns = javaScriptSplit(appsRows[i], ">"), wrsColumns = javaScriptSplit(wrsRows[i], ">"), appColumns = javaScriptSplit(appRows[i], ">")
            for j in wrsColumns.indices {
                if j == 0 { out += (out.isEmpty ? "" : "<") + wrsColumns[j] + ">"; continue }
                if j == 1 { out += wrsColumns[j] + ">"; continue }
                // mapping_array_init[j-2].length throws past the fourth category.
                guard j - 2 < WebProtectorPage.categories.count else { return nil }
                let wrsColumn = wrsColumns[j], appColumn: String? = j < appColumns.count ? appColumns[j] : nil
                for k in WebProtectorPage.categories[j - 2].items.indices {
                    let wrsID = wrsIDs[j - 2][k], appID = appIDs[j - 2][k]
                    var mapped = false
                    // `wrs_app_filter_col[j] != ""` is also true for a column that is not there (undefined).
                    if wrsColumn != "" && appColumn != "" {
                        if wrsID != "" && javaScriptContains(wrsColumn, wrsID) { mapped = true }
                        if appID != "" {
                            guard let appColumn else { return nil }
                            if javaScriptContains(appColumn, appID) { mapped = true }
                        }
                    } else if wrsColumn != "" {
                        if wrsID != "" && javaScriptContains(wrsColumn, wrsID) { mapped = true }
                    } else if appColumn != "" {
                        if appID != "" {
                            guard let appColumn else { return nil }
                            if javaScriptContains(appColumn, appID) { mapped = true }
                        }
                    }
                    out += (k == 0 ? "" : ",") + (mapped ? "1" : "0")
                }
                if j != appsColumns.count - 1 { out += ">" }
            }
        }
        return out
    }

    /// genMain_table (374–503): the rows the table draws from apps_filter, or nil where the loop throws (a row without a
    /// MAC column, or without a category column after the padding), so the table is not drawn.
    public static func rows(_ filter: String, clients: [TORSettings.ClientEntry]) -> [WebProtectorRow]? {
        guard !filter.isEmpty else { return [] }
        var rows: [WebProtectorRow] = []
        for row in javaScriptSplit(filter, "<") {
            var columns = javaScriptSplit(row, ">")
            // The exception handling (381–402): short rows are padded and switched off; a three-column row needs a MAC of
            // 17 characters or is left out.
            if columns.count < 6 {
                if columns.count == 5 { columns.append("0,0,0") }
                else if columns.count == 4 { columns += ["0,0", "0,0,0"] }
                else if columns.count == 3 {
                    if columns[1].utf16.count != 17 { continue }
                    columns += ["0,0,0,0,0", "0,0", "0,0,0"]
                }
                columns[0] = "0"
            }
            guard columns.count > 1 else { return nil }
            let mac = columns[1].uppercased()
            let client = clients.first { $0.mac == mac }
            // `'<div>' + clientName + '</div>'`, the nickName unless it is empty, or New device.
            let name = client.map { HTMLText.visible($0.nickName.isEmpty ? $0.name : $0.nickName, inside: ["div"]) } ?? "New device"
            var parents: [Bool] = [], children: [[Bool]] = []
            for (i, category) in categories.enumerated() {
                // `new Array(col)[0].split(",")` throws for a column that is not there.
                guard i + 2 < columns.count else { return nil }
                let flags = javaScriptSplit(columns[i + 2], ",")
                parents.append(javaScriptContains(columns[i + 2], "1"))
                children.append(category.items.indices.map { $0 < flags.count && javaScriptLooselyEquals(flags[$0], 1) })
            }
            rows.append(WebProtectorRow(id: rows.count, enabled: javaScriptLooselyEquals(columns[0], 1), mac: mac,
                                        name: name, macText: HTMLText.visible(mac, inside: ["div"]), parents: parents, children: children))
        }
        return rows
    }

    /// The two rule lists applyRule builds (597–658) from apps_filter's rows: for each row the enable, the MAC, then per
    /// category the IDs of the checked items (`== 1`) that have one, joined by ",".
    static func ruleLists(_ rows: [String]) -> (wrs: String, apps: String) {
        var wrs = "", apps = ""
        for row in rows {
            let columns = javaScriptSplit(row, ">")
            for (j, column) in columns.enumerated() {
                if j == 0 {
                    let prefix = wrs.isEmpty ? "" : "<"
                    wrs += prefix + column + ">"; apps += prefix + column + ">"
                } else if j == 1 {
                    wrs += column + ">"; apps += column + ">"
                } else {
                    let flags = javaScriptSplit(column, ",")
                    var wrsFirst = true, appsFirst = true
                    for (k, flag) in flags.enumerated() where javaScriptLooselyEquals(flag, 1) {
                        // An ID past the table is undefined, which `!= ""` lets through as "undefined".
                        let wrsID = j - 2 < wrsIDs.count && k < wrsIDs[j - 2].count ? wrsIDs[j - 2][k] : "undefined"
                        let appID = j - 2 < appIDs.count && k < appIDs[j - 2].count ? appIDs[j - 2][k] : "undefined"
                        if wrsID != "" { wrs += (wrsFirst ? "" : ",") + wrsID; wrsFirst = false }
                        if appID != "" { apps += (appsFirst ? "" : ",") + appID; appsFirst = false }
                    }
                    if j != columns.count - 1 { wrs += ">"; apps += ">" }
                }
            }
        }
        return (wrs, apps)
    }
}

/// One row of the table as it stands: its check boxes as the user left them since the table was last drawn.
public struct WebProtectorRow: Sendable, Equatable, Identifiable {
    public let id: Int
    public var enabled: Bool
    /// The row's title: the MAC in upper case, which edit_table and deleteRow_main use.
    public let mac: String
    /// What the row shows: the client's name (or New device) and the MAC, as the browser shows the HTML written for them.
    public let name: String
    public let macText: String
    /// The category check boxes and their items' check boxes.
    public var parents: [Bool]
    public var children: [[Bool]]
}

/// The table's add row (main_element, 347–373): checked enable box, the MAC field, unchecked categories.
public struct WebProtectorNewRow: Sendable, Equatable {
    public var enabled = true
    /// PC_devicename.
    public var mac = ""
    public var parents = Array(repeating: false, count: WebProtectorPage.categories.count)
    public var children = WebProtectorPage.categories.map { Array(repeating: false, count: $0.items.count) }
    public init() {}
}

/// Where a category's items are open (show_subCategory 109–141): one at a time on the whole table.
public struct WebProtectorCategoryPosition: Sendable, Equatable, Hashable {
    /// nil for the add row.
    public let row: Int?
    public let category: Int
    public init(row: Int?, category: Int) { self.row = row; self.category = category }
}

// MARK: - The page as it runs

/// The page while it is open: its form (835–850), the script's variables (apps_filter, curState, reboot_confirm,
/// reset_wan_to_fo.change_status) and what shows. It lasts until the page is read again.
public struct WebProtectorForm: Sendable, Equatable {
    public let page: WebProtectorPage
    public var actionWait = "5"
    public var actionScript = ""
    public var wrsEnable: String
    public var wrsAppEnable: String
    public var wrsRulelist = ""
    public var wrsAppRulelist = ""
    /// switch_control(0) disables both rule fields, so they are not sent (818–819).
    public var rulesDisabled = false
    public var trendMicro: String
    /// The hidden wans_mode reset_wan_to_fo.change_wan_mode appends (state.js 4460–4483).
    public var appendedWansMode: String?
    /// apps_filter.
    public var filter: String
    public var curState: String
    public var rebootConfirm = false
    public var changeStatus = false
    /// genMain_table has drawn the table (and PC_devicename exists in the form).
    public var tableDrawn: Bool
    /// list_table is shown.
    public var listShown: Bool
    /// The switch's position as drawn.
    public var switchShownOn: Bool
    public var rows: [WebProtectorRow]
    public var newRow = WebProtectorNewRow()
    /// check_macaddr's hint under the MAC field.
    public var macHint = false
    public var expanded: WebProtectorCategoryPosition?

    /// initial() (72–84) and the form's initial values.
    public init(page: WebProtectorPage) {
        self.page = page
        wrsEnable = page.nvram.attribute("wrs_enable"); wrsAppEnable = page.nvram.attribute("wrs_app_enable")
        trendMicro = page.nvram.attribute("TM_EULA"); curState = page.nvram.js("wrs_enable")
        switchShownOn = page.nvram.js("wrs_enable") == "1"
        let filter = page.initialFilter
        let rows = filter.flatMap { WebProtectorPage.rows($0, clients: page.clients) }
        self.filter = filter ?? page.wrsFilter
        self.rows = rows ?? []
        tableDrawn = rows != nil
        listShown = rows != nil && page.listOnLoad
    }

    /// translate_category_id or genMain_table threw when the page opened: no table, no list, no add row.
    public var tableFailed: Bool { !tableDrawn }

    // MARK: Editing

    /// set_category(obj, 0) (146–158): a category box sets all its items.
    public mutating func toggleParent(row: Int?, category: Int) {
        if let row {
            rows[row].parents[category].toggle()
            rows[row].children[category] = rows[row].children[category].map { _ in rows[row].parents[category] }
        } else {
            newRow.parents[category].toggle()
            newRow.children[category] = newRow.children[category].map { _ in newRow.parents[category] }
        }
    }
    /// set_category(obj, 1) (159–179): checking an item checks its category; unchecking the last one clears it.
    public mutating func toggleChild(row: Int?, category: Int, item: Int) {
        var parents = row.map { rows[$0].parents } ?? newRow.parents, children = row.map { rows[$0].children } ?? newRow.children
        children[category][item].toggle()
        if children[category][item] { parents[category] = true } else if !children[category].contains(true) { parents[category] = false }
        if let row { rows[row].parents = parents; rows[row].children = children } else { newRow.parents = parents; newRow.children = children }
    }
    /// show_subCategory: opening a category closes the one open before; clicking the open one closes it.
    public mutating func toggleExpanded(_ position: WebProtectorCategoryPosition) {
        expanded = expanded == position ? nil : position
    }

    /// genMain_table again from apps_filter: the check boxes go back to it, the add row is reset.
    mutating func redraw() {
        guard let drawn = WebProtectorPage.rows(filter, clients: page.clients) else { return }
        rows = drawn; newRow = WebProtectorNewRow(); macHint = false; expanded = nil; tableDrawn = true
    }

    public enum AddResult: Sendable, Equatable {
        case added
        case alert(String)
        /// check_macaddr's hint under the field.
        case hint
        /// A statement threw; nothing changed.
        case stopped(String)
    }

    /// addRow_main (228–318).
    public mutating func add() -> AddResult {
        let maximum = page.support.value("MaxRule_bwdpi_wrs")
        let upper: OrderedJSON = javaScriptAbove(maximum, .number("0")) ? maximum : .number("16")
        if javaScriptAtLeast(.number(String(javaScriptSplit(filter, "<").count)), upper) {
            return .alert("本表仅允许 " + TORSettings.javaScriptString(upper) + " 项目！")
        }
        if newRow.mac.isEmpty { return .alert("栏位不能为空白") }
        if ParentalMAC.flag(newRow.mac) != 0 { macHint = true; return .hint }
        macHint = false
        let checked = newRow.children.joined().contains(true)
        for row in javaScriptSplit(filter, "<") where row != "" {
            let columns = javaScriptSplit(row, ">")
            guard columns.count > 1 else { return .stopped("规则列表中有一行没有 MAC 栏（apps_filter_col[1] 为 undefined），网页的新增在这里出错。") }
            if columns[1].uppercased() == newRow.mac.uppercased() { newRow.mac = ""; return .alert("此项已纳入列表中。") }
        }
        if !checked { return .alert("内容类别不能为空。") }
        let entry = (newRow.enabled ? "1" : "0") + ">" + newRow.mac.uppercased() + ">"
            + newRow.children.map { $0.map { $0 ? "1" : "0" }.joined(separator: ",") }.joined(separator: ">")
        filter += (filter.isEmpty ? "" : "<") + entry
        redraw()
        return .added
    }

    /// deleteRow_main (182–203): every row of apps_filter whose MAC is the row's title goes (as written, so a row stored in
    /// lower case stays and is drawn again); the table is drawn again.
    public mutating func delete(_ row: WebProtectorRow) {
        var kept = ""
        for entry in javaScriptSplit(filter, "<") {
            let columns = javaScriptSplit(entry, ">")
            // `apps_filter_col[1] != target_mac`: a row without a MAC column (undefined) stays.
            if columns.count > 1 && columns[1] == row.mac { continue }
            // The first row is joined without "<" for as long as the kept text is still empty.
            kept += kept.isEmpty ? entry : "<" + entry
        }
        filter = kept
        redraw()
    }

    /// edit_table (520–572): the drawn rows as their boxes stand; the alert when one has no item checked.
    static func serialized(_ rows: [WebProtectorRow]) -> Result<String, AlertText> {
        var out = ""
        for (index, row) in rows.enumerated() {
            out += (index == 0 ? "" : "<") + (row.enabled ? "1" : "0") + ">" + row.mac + ">"
                + row.children.map { $0.map { $0 ? "1" : "0" }.joined(separator: ",") }.joined(separator: ">")
            if !row.children.joined().contains(true) { return .failure(AlertText("内容类别不能为空。")) }
        }
        return .success(out)
    }
    struct AlertText: Error, Equatable { let text: String; init(_ text: String) { self.text = text } }
}

// MARK: - The switch and 应用本页面设置

/// What the user does that runs the page's script toward a submit.
public enum WebProtectorAction: Sendable, Equatable {
    /// The switch while curState is not "1" (the iphoneSwitch plugin reads curState for this switch): switch_control(1).
    case switchOn
    /// The switch while curState is "1": switch_control(0).
    case switchOff
    /// 应用本页面设置: applyRule().
    case apply
}

/// A confirm() the script asks, with the page's text.
public enum WebProtectorQuestion: Sendable, Equatable {
    /// reset_wan_to_fo.show_confirm_hint (state.js 4448–4455).
    case dualWAN
    /// ctf_fa_hint (660).
    case acceleration
    /// AiMesh_Node_Reboot (674).
    case reboot
    public var text: String {
        switch self {
        case .dualWAN: "启用 AiProtection 网络神盾 时，双 WAN \"负载均衡\" 模式将切换为 \"故障转移\"，您确定要继续吗？"
        case .acceleration: "开启 AiProtection 后系统会自动重启，功能正常。请单击「应用」以启用此功能，或单击「取消」返回页面。"
        case .reboot: "重启路由器可能会使所有已联网的路由器中断网络连接。重启后，所有设备将会重新进行网络连接，确认继续？"
        }
    }
}

/// Where the script got to with the answers given so far.
public enum WebProtectorStep: Sendable, Equatable {
    /// It asks a confirm(): the next answer is OK (true) or Cancel (false).
    case confirm(WebProtectorQuestion)
    /// It opens Trend Micro's terms (PolicyModalComponent, 801–806): the next answer is 同意 (true) or 拒绝 (false).
    case terms
    /// It ended: the alert it showed on the way, if any, and what it sends.
    case finished(alert: String?, writes: WebProtectorWrites)
    /// A statement threw: the script stops there and sends nothing more.
    case stopped(String)
}

/// The requests a run sends, in the page's order: the form, then (the terms window's buttons) set_TM_EULA.cgi.
public struct WebProtectorWrites: Sendable, Equatable {
    public var form: ParentalFormSubmission?
    /// TM_EULA for set_TM_EULA.cgi: "1" after 同意, "0" after 拒绝.
    public var trendMicro: String?
    public init(form: ParentalFormSubmission? = nil, trendMicro: String? = nil) { self.form = form; self.trendMicro = trendMicro }
    public var isEmpty: Bool { form == nil && trendMicro == nil }
}

extension WebProtectorForm {
    /// The form to show after a run of the script from this one: as the script left it, except that a run which ended
    /// without anything to send because one of its questions was answered 取消 goes back to this form, as it was before
    /// the click (the page keeps what its script changed before the question, e.g. the switch shown on and wrs_enable,
    /// TM_EULA and action_wait set by eula_confirm 789–795 when 取消 on the acceleration question returns at 659).
    public func settled(_ next: WebProtectorForm, answers: [Bool], writes: WebProtectorWrites) -> WebProtectorForm {
        writes.isEmpty && answers.contains(false) ? self : next
    }

    /// The script for `action` from this form, with `answers` to its questions in order. Returns the form as the script
    /// left it (what it changed before it ended stays, as on the page) and where it got to.
    public func running(_ action: WebProtectorAction, answers: [Bool]) -> (WebProtectorForm, WebProtectorStep) {
        var run = WebProtectorRun(form: self, answers: answers[...])
        do {
            switch action {
            case .switchOn: try run.switchOn()
            case .switchOff: try run.switchOff()
            case .apply: try run.applyRule()
            }
            return (run.form, .finished(alert: run.alert, writes: run.writes))
        } catch WebProtectorRun.Halt.ask(let step) {
            return (self, step)
        } catch WebProtectorRun.Halt.stopped(let reason) {
            return (run.form, .stopped(reason))
        } catch {
            return (self, .stopped(error.localizedDescription))
        }
    }

    /// The form as it goes to start_apply.htm: the named controls that are not disabled, in document order (836–850, the
    /// add row's PC_devicename inside the table once it is drawn, then an appended wans_mode). preferred_lang is disabled.
    public var submission: ParentalFormSubmission {
        let nvram = page.nvram
        var fields = [("productid", nvram.attribute("productid")), ("current_page", "AiProtection_WebProtector.asp"), ("next_page", ""),
                      ("modified", "0"), ("action_wait", actionWait), ("action_mode", "apply"), ("action_script", actionScript),
                      ("firmver", nvram.attribute("firmver")), ("wrs_enable", wrsEnable), ("wrs_enable_ori", nvram.attribute("wrs_enable")),
                      ("wrs_app_enable", wrsAppEnable)]
        if !rulesDisabled { fields += [("wrs_rulelist", wrsRulelist), ("wrs_app_rulelist", wrsAppRulelist)] }
        fields.append(("TM_EULA", trendMicro))
        if tableDrawn { fields.append(("PC_devicename", newRow.mac)) }
        if let appendedWansMode { fields.append(("wans_mode", appendedWansMode)) }
        return ParentalFormSubmission(fields: fields)
    }
}

/// One run of the page's script (switch_control, eula_confirm, cancel, applyRule) on a copy of the form.
struct WebProtectorRun {
    var form: WebProtectorForm
    var answers: ArraySlice<Bool>
    var alert: String?
    var writes = WebProtectorWrites()
    enum Halt: Error { case ask(WebProtectorStep), stopped(String) }

    mutating func answer(_ step: WebProtectorStep) throws -> Bool {
        guard let next = answers.popFirst() else { throw Halt.ask(step) }
        return next
    }

    /// switch_control(1) (797–813); the switch shows on before its callback runs.
    mutating func switchOn() throws {
        form.switchShownOn = true
        // reset_wan_to_fo.check_status() (state.js 4430–4443).
        if form.page.asksDualWAN {
            form.changeStatus = try answer(.confirm(.dualWAN))
            if !form.changeStatus { cancel(); return }
        }
        guard form.page.asksTrendMicro else { try eulaConfirm(); return }
        if try answer(.terms) {
            // handleClickAgree (asus_policy.js 1282–1289): agreeCallback first; enableEula('tm', "1") only if it returns.
            try eulaConfirm()
            writes.trendMicro = "1"
        } else {
            // handleClickDisagree (1312–1317): disagreeCallback, then enableEula("tm", "0").
            cancel()
            writes.trendMicro = "0"
        }
    }

    /// switch_control(0) (814–821).
    mutating func switchOff() throws {
        form.switchShownOn = false
        form.wrsEnable = "0"; form.wrsAppEnable = "0"
        form.listShown = false
        form.rulesDisabled = true
        try applyRule()
    }

    /// eula_confirm (789–795).
    mutating func eulaConfirm() throws {
        form.trendMicro = "1"; form.wrsEnable = "1"; form.wrsAppEnable = "1"; form.actionWait = "15"
        try applyRule()
    }

    /// cancel (782–787): the switch back, curState 0, an empty action_script and action_wait 5.
    mutating func cancel() {
        form.switchShownOn = false
        form.curState = "0"; form.actionScript = ""; form.actionWait = "5"
    }

    /// applyRule (577–685).
    mutating func applyRule() throws {
        form.actionScript = "restart_wrs;restart_firewall" + (form.page.appliesAiMesh ? ";apply_amaslib" : "")
        if form.wrsEnable == "1" {
            guard form.tableDrawn else {
                throw Halt.stopped("网页初始化时规则表没有画出，表单里没有 PC_devicename，applyRule 读取它时出错。")
            }
            if !form.newRow.mac.isEmpty { alert = "您必须先按添加图标才能添加新规则。"; return }
            var rows: [String] = []
            if !form.filter.isEmpty {
                switch WebProtectorForm.serialized(form.rows) {
                case .failure(let failure): alert = failure.text; return
                case .success(let text): form.filter = text; rows = javaScriptSplit(text, "<")
                }
            }
            let lists = WebProtectorPage.ruleLists(rows)
            form.wrsRulelist = lists.wrs; form.wrsAppRulelist = lists.apps
            if form.page.accelerationReboots {
                guard try answer(.confirm(.acceleration)) else { return }
                form.rebootConfirm = true
            }
            if form.changeStatus {
                // reset_wan_to_fo.change_wan_mode (state.js 4456–4484).
                form.appendedWansMode = "fo"; form.actionScript = "reboot"; form.actionWait = form.page.nvram.js("reboot_time")
            }
        }
        if form.rebootConfirm {
            guard try answer(.confirm(.reboot)) else { return }
            // FormActions("start_apply.htm", "apply", "reboot", get_default_reboot_time()) (state.js 3979–3987).
            form.actionScript = "reboot"
            if !form.page.rebootTime.isEmpty { form.actionWait = form.page.rebootTime }
        }
        writes.form = form.submission
    }
}

// MARK: - Reading and writing

extension RouterClient {
    /// What the page reads when it opens: its variables, get_ui_support, the client list (client_function.js 244–250),
    /// get_default_reboot_time, bwdpi_engine_status and get_operation_mode.
    public func webProtectorPage() async throws -> WebProtectorPage {
        let nvram = EncodedNvram(encoded: try await readEncodedSettings(WebProtectorPage.keys))
        let support = try await orderedUISupport()
        let clients = TORSettings.clientList(current: try await optionalHook("get_clientlist"), history: try await optionalHook("get_clientlist_from_json_database"),
                                             lanMAC: nvram.raw("lan_hwaddr"), productID: nvram.raw("productid"), amas: support.on("amas"))
        let reboot = try await optionalHook("get_default_reboot_time").map(TORSettings.javaScriptString) ?? ""
        let dpi = try await optionalHook("bwdpi_engine_status")
        let mode = try await orderedHook("get_operation_mode").map(TORSettings.javaScriptString) ?? ""
        return WebProtectorPage(nvram: nvram, support: support, clients: clients, rebootTime: reboot, dpiStatus: dpi, operationMode: mode)
    }

    /// Sends what the run sends, in the page's order: the form to start_apply.htm (into a hidden frame, so the script goes
    /// on at once) and right after it set_TM_EULA.cgi. Unless the form reboots the router, the variables are read back after
    /// the form's action_wait (`settle` overrides it).
    public func applyWebProtector(_ writes: WebProtectorWrites, settle: Duration? = nil) async throws -> ApplyReceipt {
        try acquireMutation(); defer { releaseMutation() }
        var uncertainty: String?, termsSent = true
        if let form = writes.form {
            async let posted = postParentalForm(form)
            if let terms = writes.trendMicro {
                await Task.yield()
                do { _ = try await request("set_TM_EULA.cgi", query: [.init(name: "TM_EULA", value: terms)], changes: true) }
                catch is CancellationError { throw CancellationError() }
                catch { termsSent = false }
            }
            do {
                if try await posted == .unrecognized { uncertainty = "路由器已接收表单，但回应中没有确认结果。请稍后点“重新读取”核对，不要重复提交。" }
            } catch RouterError.submissionUncertain(let reason) { uncertainty = reason }
        } else if let terms = writes.trendMicro {
            _ = try await request("set_TM_EULA.cgi", query: [.init(name: "TM_EULA", value: terms)], changes: true)
        }
        let keys = WebProtectorCheck(writes).keys
        let termsNote = writes.form != nil && writes.trendMicro != nil
            ? (termsSent ? "Trend Micro 条款的答复也已发送。" : "Trend Micro 条款的答复没有发送成功，请稍后重新读取确认。") : ""
        if writes.form?.reboots == true {
            return ApplyReceipt(verified: [], unverified: keys, message: (uncertainty ?? "路由器已接收设置并开始重新启动，约 \(writes.form?.wait ?? 0) 秒后才能重新连接并读取确认。") + termsNote)
        }
        if let uncertainty { return ApplyReceipt(verified: [], unverified: keys, message: uncertainty + termsNote) }
        do {
            try await Task.sleep(for: settle ?? .seconds(max(writes.form?.wait ?? 1, 1)))
            let checked = try await checkWebProtector(writes)
            return ApplyReceipt(verified: checked.verified, unverified: checked.unverified, message: checked.message + termsNote)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ApplyReceipt(verified: [], unverified: keys, message: "路由器已接收请求，但暂时读不到设置。请稍后点“重新读取”核对，不要重复提交。" + termsNote)
        }
    }

    /// The variables the form and the terms' answer set, read back and compared with what was sent.
    public func checkWebProtector(_ writes: WebProtectorWrites) async throws -> ApplyReceipt {
        let check = WebProtectorCheck(writes)
        var receipt = try await checkSent(check.sent, success: "已从路由器重新读取，网页与 Apps 过滤的设置与提交的一致。")
        // set_TM_EULA.cgi records the time with the answer (web.c 21493–21498).
        if writes.trendMicro != nil, (try await readSettings(["TM_EULA_time"]))["TM_EULA_time"]?.isEmpty ?? true {
            receipt.unverified.append("TM_EULA_time")
            receipt.message = "路由器已响应，但没有读到 Trend Micro 条款的答复时间（TM_EULA_time）。请重新读取并检查。"
        }
        return receipt
    }
}

/// What a run's writes leave on the router, as it can be read back.
struct WebProtectorCheck {
    let sent: [(String, String)]
    init(_ writes: WebProtectorWrites) {
        var sent: [(String, String)] = []
        if let form = writes.form {
            for name in ["wrs_enable", "wrs_app_enable", "wrs_rulelist", "wrs_app_rulelist", "wans_mode"] {
                if let value = form.value(name) { sent.append((name, value)) }
            }
        }
        // set_TM_EULA.cgi comes after the form; with "0" it also switches the filter off (web.c 21495–21501).
        if let terms = writes.trendMicro {
            sent.append(("TM_EULA", terms))
            if terms == "0" {
                sent.removeAll { ["wrs_enable", "wrs_app_enable"].contains($0.0) }
                sent += [("wrs_enable", "0"), ("wrs_app_enable", "0")]
            }
        } else if let value = writes.form?.value("TM_EULA") {
            sent.append(("TM_EULA", value))
        }
        self.sent = sent
    }
    var keys: [String] { sent.map(\.0) }
}
