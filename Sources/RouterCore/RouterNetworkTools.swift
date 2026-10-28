import Foundation

// 网络工具 › 通过网络（LAN）唤醒（Main_WOL_Content.asp）与 Site Survey（Advanced_Wireless_Survey.asp，sysdep/FUNCTION/SITE_SURVEY）
// （1.12）：按 Asuswrt-Merlin tag 3006.102.5 的页面源码。唤醒、保存离线列表和重新扫描与网页发送相同的请求，由界面先请用户确认。

// MARK: - 通过网络（LAN）唤醒

public struct WakeOnLANList: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        /// The key as stored (initial 31–40); the page shows and offers it upper-cased.
        public let key: String
        /// The name as the page writes it into the row (HTML): the client list's name for a device it knows by this
        /// exact key, otherwise the stored name (showwollist 114–192, which also keeps that name for saving).
        public let name: String
        public var mac: String { key.uppercased() }
    }
    /// manually_wol_list_array, which 应用本页面设置 saves.
    public private(set) var entries: [Entry]
    /// The table's rows: the entries as showwollist last drew them, less the rows 移除 took out. del_Row (257–265)
    /// removes the clicked row but deletes the upper-cased key from the list, so a key stored in lower case stays in
    /// the list (and is drawn again by the next showwollist), while a stored upper-case twin would be deleted instead.
    public private(set) var rows: [Entry]

    /// manually_wol_list_array: entries after each "<", name before ">" and key after it (undefined when there is no
    /// ">"); a repeated key keeps its first place and its last name. Object.keys lists index-like keys first, ascending.
    public static func stored(_ wollist: String) -> [(key: String, name: String)] {
        var names: [String: String] = [:], order: [String] = []
        for row in wollist.components(separatedBy: "<").dropFirst() {
            let columns = row.components(separatedBy: ">")
            let key = columns.count > 1 ? columns[1] : "undefined"
            if names[key] == nil { order.append(key) }
            names[key] = columns[0]
        }
        return JavaScriptKeys.ordered(order).map { ($0, names[$0] ?? "") }
    }

    public init(wollist: String, clientNames: [String: String]) {
        entries = Self.stored(wollist).map { Entry(key: $0.key, name: clientNames[$0.key] ?? $0.name) }
        rows = entries
    }
    init(entries: [Entry]) { self.entries = entries; rows = entries }

    /// applyRule (288–303): "<name>key" per entry; "" for nothing.
    public var encoded: String {
        let value = entries.map { "<" + $0.name + ">" + $0.key }.joined()
        return value == "<目前没有数据" || value == "<" ? "" : value
    }
    /// 目前没有数据 shows when showwollist drew an empty list.
    public var showsNoData: Bool { rows.isEmpty && entries.isEmpty }
    /// With every row removed but entries left the table has no first row: addRow_Group and applyRule (288–291) read its
    /// cells first and throw, so neither adds nor saves anything.
    public var tableEmptied: Bool { rows.isEmpty && !entries.isEmpty }

    /// check_hwaddr_flag(obj, 'inner') (general.js 1767–1782): six hex pairs each followed by ":" or the end, anywhere in
    /// the text; empty text passes. The page's fields take at most 17 characters.
    public static func isMAC(_ text: String) -> Bool {
        text.isEmpty || text.range(of: #"([a-fA-F0-9]{2}(:|$)){6}"#, options: .regularExpression) != nil
    }

    /// addRow_Group(32) (194–232): the alert the page gives, or the list with the device added under its client-list
    /// name (nickName, else name) or "New device", drawn again by showwollist.
    public func adding(_ text: String, clientNames: [String: String]) -> Result<WakeOnLANList, WakeOnLANError> {
        // `rule_num` counts the table's rows (目前没有数据 is one).
        if tableEmptied { return .failure(.stopped) }
        if max(rows.count, 1) >= 32 { return .failure(.limit) }
        if text.isEmpty { return .failure(.blank) }
        if !Self.isMAC(text) { return .failure(.format) }
        let key = text.uppercased()
        if !rows.isEmpty, entries.contains(where: { $0.key == key }) { return .failure(.duplicate) }
        let updated = entries + [Entry(key: key, name: clientNames[key] ?? "New device")]
        return .success(WakeOnLANList(entries: JavaScriptKeys.ordered(updated.map(\.key)).compactMap { key in updated.first { $0.key == key } }))
    }

    /// 移除 on the table's row at `index`.
    public func removing(row index: Int) -> WakeOnLANList {
        guard rows.indices.contains(index) else { return self }
        var list = self
        let row = list.rows.remove(at: index)
        list.entries.removeAll { $0.key == row.mac }
        // `if(Object.keys(manually_wol_list_array).length == 0) showwollist();`
        if list.entries.isEmpty { list.rows = [] }
        return list
    }
}

/// Object.keys / for-in order: keys that are array indices (canonical whole numbers below 2³² − 1) first, ascending,
/// then the others in the order they were added.
enum JavaScriptKeys {
    static func index(_ key: String) -> UInt32? {
        guard let value = UInt32(key), value < UInt32.max, String(value) == key else { return nil }
        return value
    }
    static func ordered(_ keys: [String]) -> [String] {
        keys.compactMap { key in index(key).map { (key, $0) } }.sorted { $0.1 < $1.1 }.map(\.0) + keys.filter { index($0) == nil }
    }
}

public enum WakeOnLANError: Error, Equatable, Sendable {
    /// The page's script throws and nothing happens.
    case stopped
    case limit, blank, format, duplicate, invalidTarget
    public var message: String {
        switch self {
        case .stopped: ""
        case .limit: "本表仅允许 32 项目！"
        case .blank: "栏位不能为空白"
        case .format: "MAC 地址的格式为六组十六进制的数元，每组两个，以冒号分隔，按照传送排序。（例如，12:34:56:aa:bc:ef）"
        case .duplicate: "此项已纳入列表中。"
        case .invalidTarget: "MAC 地址无效。"
        }
    }
}

public struct WakeOnLANPage: Sendable, Equatable {
    /// wollist as stored; 应用本页面设置 writes `list.encoded`, which also carries the names the client list gave.
    public let stored: String
    public let list: WakeOnLANList
    /// The client list's names (the HTML the page writes) by upper-case MAC, for the list and the device picker.
    public let clientNames: [String: String]
    /// The target field's placeholder, "ex: " and lan_hwaddr.
    public let lanMAC: String
    /// preferred_lang, firmver and productid, which the page's forms carry.
    public let language: String
    public let firmver: String
    public let productID: String
}

extension RouterClient {
    public func wakeOnLANPage() async throws -> WakeOnLANPage {
        let values = try await readSettings(["wollist", "lan_hwaddr", "productid", "preferred_lang", "firmver"])
        let support = try await uiCapabilities()
        let names = TORSettings.clientNames(current: try await optionalHook("get_clientlist"), history: try await optionalHook("get_clientlist_from_json_database"),
                                            lanMAC: values["lan_hwaddr"] ?? "", productID: values["productid"] ?? "",
                                            amas: !["", "0"].contains(support["amas"] ?? ""))
        return WakeOnLANPage(stored: values["wollist"] ?? "", list: WakeOnLANList(wollist: values["wollist"] ?? "", clientNames: names), clientNames: names,
                             lanMAC: values["lan_hwaddr"] ?? "", language: values["preferred_lang"] ?? "", firmver: values["firmver"] ?? "",
                             productID: values["productid"] ?? "")
    }

    /// 唤醒 (onSubmitCtrl 45–60, updateOptions 62–72): the page's form `form` (310–371) to apply.cgi with
    /// action_mode " Refresh " and "ether-wake -i br0 -b <target>", which httpd runs for this page
    /// (web.c 13279–13404); the target goes as typed, with every field the form submits, in its order.
    public func wakeOnLAN(_ target: String, adding: String, page: WakeOnLANPage) async throws {
        guard !target.isEmpty else { throw WakeOnLANError.blank }
        guard WakeOnLANList.isMAC(target) else { throw WakeOnLANError.invalidTarget }
        try acquireMutation(); defer { releaseMutation() }
        let fields = [("current_page", "Main_WOL_Content.asp"), ("next_page", "Main_WOL_Content.asp"), ("group_id", ""), ("modified", "0"),
                      ("action_mode", " Refresh "), ("action_script", ""), ("action_wait", ""), ("first_time", ""),
                      ("preferred_lang", page.language), ("SystemCmd", "ether-wake -i br0 -b " + target), ("firmver", page.firmver),
                      ("destIP", target), ("wollist_macAddr", adding)]
        _ = try await request("apply.cgi", method: "POST", body: RouterAuthentication.orderedForm(fields, .formSubmission),
                              contentType: "application/x-www-form-urlencoded")
    }

    /// cmdRet_check.htm (checkCmdRet 74–112): /tmp/syscmd.log, which ends with XU6J03M6 once the command succeeded.
    public func commandLog() async throws -> String { try await readManagementDocument("cmdRet_check.htm") }

    /// 应用本页面设置 (applyRule 288–303): the form `wolform` (399–408) to start_apply.htm, which saves wollist without
    /// restarting a service; read back to confirm.
    public func saveWakeOnLANList(_ list: WakeOnLANList, page: WakeOnLANPage) async throws -> ApplyReceipt {
        guard !list.tableEmptied else { throw WakeOnLANError.stopped }
        try acquireMutation(); defer { releaseMutation() }
        let value = list.encoded
        let fields = [("productid", page.productID), ("current_page", "Main_WOL_Content.asp"), ("next_page", "Main_WOL_Content.asp"),
                      ("modified", "0"), ("action_mode", "apply"), ("action_wait", "3"), ("action_script", ""), ("wollist", value)]
        _ = try await request("start_apply.htm", method: "POST", body: RouterAuthentication.orderedForm(fields, .formSubmission),
                              contentType: "application/x-www-form-urlencoded", timeout: 60)
        let after = try await readSettings(["wollist"])
        let saved = after["wollist"] == value
        return ApplyReceipt(verified: saved ? ["wollist"] : [], unverified: saved ? [] : ["wollist"],
                            message: saved ? "已从路由器重新读取，离线列表已保存。" : "路由器已响应，但离线列表与提交的内容不一致。请重新读取并检查。")
    }
}

// MARK: - Site Survey

/// Site Survey (sysdep/FUNCTION/SITE_SURVEY/Advanced_Wireless_Survey.asp): the networks the last scan found, as
/// update_site_info (117–139) reads apscan.asp and showSiteTable (153–231) lists them.
public struct SiteSurvey: Sendable, Equatable {
    /// wlc_scan_state; the list shows only for "5", otherwise 正在搜寻无线网络...
    public let state: String
    /// aplist as the router wrote it: per network band, SSID (URI-encoded), channel, authentication, encryption, signal
    /// (percent), MAC and mode.
    public let rows: [OrderedJSON]
    /// radio_status (web.c 32355–32363): radio_2 / radio_5, 0 when the band's radio is off.
    public let radio2: String
    public let radio5: String

    public init(state: String, rows: [OrderedJSON], radio2: String, radio5: String) {
        self.state = state; self.rows = rows; self.radio2 = radio2; self.radio5 = radio5
    }

    public var finished: Bool { state == "5" }
    /// `radio_2 == 0` / `(band5g_support) && (radio_5 == 0)` (initial 56–59); no warning when radio_status did not answer.
    public var radio2Off: Bool { !radio2.isEmpty && javaScriptNumber(radio2) == 0 }
    public var radio5Off: Bool { !radio5.isEmpty && javaScriptNumber(radio5) == 0 }

    /// One row of the table.
    public struct Network: Sendable, Equatable, Identifiable {
        public let id: Int
        /// decodeURIComponent(handle_show_str(ssid)) written into the cell as HTML; "[hidden]" when empty.
        public let ssid: String
        public let hidden: Bool
        public let channel: String
        public let security: String
        /// Open System with encryption NONE also shows the unlocked padlock.
        public let open: Bool
        public let band: String
        /// The percentage (the icon's title) and bars, Math.ceil(signal / 25); locked unless encryption is NONE.
        public let signal: String
        public let bars: Int?
        public let locked: Bool
        public let mac: String
    }

    public enum Table: Sendable, Equatable {
        case searching
        /// `aplist.length && aplist[0].length == 0`: 侦测不到任何基地台.
        case noResult
        case networks([Network])
        /// The page's code threw on a row (a null row or first row, an SSID that is not text or that decodeURIComponent
        /// cannot decode, a MAC that is not text): it stops and leaves the table as it was.
        case stopped
    }

    /// `row[index]`: an array's element, a text's UTF-16 unit, an object's member, otherwise undefined; reading it from
    /// null throws (nil).
    static func member(_ row: OrderedJSON, _ index: Int) -> OrderedJSON?? {
        switch row {
        case .null: return nil
        case .array(let fields): return .some(index < fields.count ? fields[index] : nil)
        case .string(let text):
            let units = Array(text.utf16)
            return .some(index < units.count ? .string(String(decoding: [units[index]], as: UTF16.self)) : nil)
        case .object: return .some(row[String(index)])
        default: return .some(nil)
        }
    }

    /// The table for rows in the given order (see sorted(by:)).
    public func table(_ rows: [OrderedJSON]) -> Table {
        guard finished else { return .searching }
        // `aplist.length && aplist[0].length == 0`: reading length from a null first row throws.
        if let first = rows.first {
            switch first {
            case .null: return .stopped
            case .array(let fields) where fields.isEmpty: return .noResult
            case .string(let text) where text.isEmpty: return .noResult
            case .object: if JavaScriptCompare.looselyZero(first["length"]) { return .noResult }
            default: break
            }
        }
        var networks: [Network] = []
        for (index, row) in rows.enumerated() {
            // `aplist[i][1]` throws for a null row; `== null` skips undefined and null.
            guard case .some(let ssidValue) = Self.member(row, 1) else { return .stopped }
            guard let ssidValue, ssidValue != .null else { continue }
            func text(_ at: Int) -> String { (Self.member(row, at) ?? nil).map(TORSettings.javaScriptString) ?? "undefined" }
            // `.search("%FFFF")` on a value that is not text throws.
            guard case .string(let raw) = ssidValue else { return .stopped }
            if raw.contains("%FFFF") { continue }
            let shown = raw.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: " ", with: "&nbsp;")
            guard let decoded = Self.decodeURIComponent(shown) else { return .stopped }
            // The SSID cell's onclick then calls `aplist[i][6].toUpperCase()`, which throws for anything but text.
            guard case .string(let mac)?? = Self.member(row, 6) else { return .stopped }
            let ssid = HTMLText.visible(decoded, inside: ["td"])
            let band = text(0), auth = text(3), encryption = text(4)
            let channel = band == "6G" ? "6g" + text(2) + " (ax)" : text(2) + " (" + text(7) + ")"
            let security = auth == "Open System" && encryption == "NONE" ? auth : encryption == "WEP" ? "WEP" : auth + " (" + encryption + ")"
            let percent = javaScriptNumber(text(5))
            networks.append(Network(id: index, ssid: decoded.isEmpty ? "[hidden]" : ssid, hidden: decoded.isEmpty,
                                    channel: HTMLText.visible(channel, inside: ["td"]), security: HTMLText.visible(security, inside: ["td"]),
                                    open: auth == "Open System" && encryption == "NONE",
                                    band: band == "2G" ? "2.4 GHz" : band == "6G" ? "6 GHz" : "5 GHz",
                                    signal: text(5), bars: percent.flatMap { value in
                                        let bars = (value / 25).rounded(.up)
                                        return bars.isFinite && abs(bars) < 1_000_000 ? Int(bars) : nil
                                    }, locked: encryption != "NONE",
                                    mac: mac))
        }
        return .networks(networks)
    }

    /// The columns' sort keys (doSorter / sorter 66–115): 1 name, 2 channel, 3 security, 0 band (text) and 5 signal
    /// (number). The page sorts the stored rows with Array.prototype.sort, which keeps equal rows in order.
    public enum Column: Int, Sendable { case band = 0, ssid = 1, channel = 2, security = 3, signal = 5 }
    /// nil where the page's sort throws, which leaves aplist and the table as they were: a row that is null (`a[flag]`), or,
    /// for a text column, a value that is not text (`toUpperCase`). With two or more rows every row is compared.
    public static func sorted(_ rows: [OrderedJSON], by column: Column, descending: Bool) -> [OrderedJSON]? {
        guard rows.count > 1 else { return rows }
        func key(_ row: OrderedJSON) -> OrderedJSON? { member(row, column.rawValue) ?? nil }
        let numeric = column == .channel || column == .signal
        if rows.contains(.null) { return nil }
        if !numeric, rows.contains(where: { if case .string? = key($0) { false } else { true } }) { return nil }
        func order(_ a: OrderedJSON, _ b: OrderedJSON) -> Double {
            if numeric {
                // parseInt; NaN makes the comparator say "equal".
                let x = parseInt(key(a)), y = parseInt(key(b))
                guard let x, let y else { return 0 }
                return descending ? y - x : x - y
            }
            guard case .string(let first)? = key(a), case .string(let second)? = key(b) else { return 0 }
            let x = first.uppercased(), y = second.uppercased()
            if x == y { return 0 }
            let ascending = x.utf16.lexicographicallyPrecedes(y.utf16)
            return descending ? (ascending ? 1 : -1) : (ascending ? -1 : 1)
        }
        // A stable merge sort with the page's comparator.
        var items = rows
        var width = 1
        while width < items.count {
            var merged: [OrderedJSON] = []
            merged.reserveCapacity(items.count)
            var start = 0
            while start < items.count {
                let middle = min(start + width, items.count), end = min(start + 2 * width, items.count)
                var left = start, right = middle
                while left < middle, right < end {
                    if order(items[right], items[left]) < 0 { merged.append(items[right]); right += 1 } else { merged.append(items[left]); left += 1 }
                }
                merged.append(contentsOf: items[left..<middle]); merged.append(contentsOf: items[right..<end])
                start = end
            }
            items = merged; width *= 2
        }
        return items
    }

    /// parseInt(value) for a JSON value: leading white space, sign, then hex digits after 0x or decimal digits; nil for
    /// NaN (and for a missing value, whose text "undefined" has no digits).
    static func parseInt(_ value: OrderedJSON?) -> Double? {
        let trimmed = javaScriptTrim(value.map(TORSettings.javaScriptString) ?? "undefined")
        var body = Substring(trimmed), sign = 1.0
        if let mark = body.first, mark == "+" || mark == "-" { sign = mark == "-" ? -1 : 1; body = body.dropFirst() }
        if body.hasPrefix("0x") || body.hasPrefix("0X") {
            let digits = body.dropFirst(2).prefix { $0.isHexDigit && $0.isASCII }
            guard !digits.isEmpty else { return nil }
            return sign * digits.reduce(0.0) { $0 * 16 + Double(Int(String($1), radix: 16) ?? 0) }
        }
        let digits = body.prefix { ("0"..."9").contains($0) }
        guard !digits.isEmpty else { return nil }
        return sign * digits.reduce(0.0) { $0 * 10 + Double(Int(String($1)) ?? 0) }
    }

    /// decodeURIComponent: each %XX, or a run of them forming one UTF-8 character, becomes that character; nil where
    /// JavaScript throws URIError (a broken escape, a stray continuation byte, an invalid or overlong sequence).
    static func decodeURIComponent(_ text: String) -> String? {
        let units = Array(text.utf16)
        func escaped(_ at: Int) -> UInt8? {
            guard at + 2 < units.count, units[at] == 0x25, let high = hexDigit(units[at + 1]), let low = hexDigit(units[at + 2]) else { return nil }
            return high << 4 | low
        }
        func hexDigit(_ unit: UInt16) -> UInt8? {
            switch unit {
            case 0x30...0x39: UInt8(unit - 0x30)
            case 0x41...0x46: UInt8(unit - 0x37)
            case 0x61...0x66: UInt8(unit - 0x57)
            default: nil
            }
        }
        var decoded: [UInt16] = [], index = 0
        while index < units.count {
            guard units[index] == 0x25 else { decoded.append(units[index]); index += 1; continue }
            guard let lead = escaped(index) else { return nil }
            index += 3
            if lead < 0x80 { decoded.append(UInt16(lead)); continue }
            let length = lead & 0xE0 == 0xC0 ? 2 : lead & 0xF0 == 0xE0 ? 3 : lead & 0xF8 == 0xF0 ? 4 : 0
            guard length > 0 else { return nil }
            var bytes = [lead]
            for _ in 1..<length {
                guard let next = escaped(index), next & 0xC0 == 0x80 else { return nil }
                bytes.append(next); index += 3
            }
            // Decoding replaces an overlong form, a surrogate or a value past U+10FFFF, so it no longer encodes back.
            let character = String(decoding: bytes, as: UTF8.self)
            guard Array(character.utf8) == bytes else { return nil }
            decoded.append(contentsOf: character.utf16)
        }
        return String(decoding: decoded, as: UTF16.self)
    }

    /// The network's vendor from /ajax/ouiDB.json by the first six hex digits of its MAC (oui_query_full_vendor,
    /// client_function.js 4622–4647).
    public static func vendorKey(_ mac: String) -> String {
        String(mac.uppercased().replacingOccurrences(of: ":", with: "").prefix(6))
    }
}

extension RouterClient {
    /// apscan.asp (wlc_scan_state and `aplist = [<% get_ap_info(); %>][0];`) with radio_status; only reads.
    public func siteSurvey() async throws -> SiteSurvey {
        let script = try await readManagementDocument("apscan.asp")
        let state = RouterParser.capture(#"wlc_scan_state = '([^']*)';"#, in: script) ?? ""
        var rows: [OrderedJSON] = []
        if let start = script.range(of: "aplist = "), let end = script.range(of: "[0];", options: .backwards), start.upperBound <= end.lowerBound {
            let literal = String(script[start.upperBound..<end.lowerBound])
            guard case .array(let outer) = try OrderedJSON(data: Data(literal.utf8)), case .array(let list)? = outer.first else {
                throw RouterError.invalidResponse("扫描结果")
            }
            rows = list
        }
        let radio = try await orderedHook("radio_status")
        return SiteSurvey(state: state, rows: rows, radio2: radio?["radio_2"]?.text ?? "", radio5: radio?["radio_5"]?.text ?? "")
    }

    /// 重新扫描 (rescan 233–243): the page's form (256–270) to start_apply2.htm with action_script restart_wlcscan,
    /// which scans every band and sets wlc_scan_state to 5 when it is done. The two SSID fields are disabled and not sent.
    public func startSiteSurvey() async throws {
        let values = try await readSettings(["preferred_lang", "firmver"])
        try acquireMutation(); defer { releaseMutation() }
        let page = "Advanced_Wireless_Survey.asp"
        let fields = [("current_page", page), ("next_page", page), ("prev_page", page), ("modified", "0"), ("flag", "sitesurvey"),
                      ("action_mode", "apply"), ("action_wait", "1"), ("action_script", "restart_wlcscan"), ("first_time", ""),
                      ("SystemCmd", ""), ("preferred_lang", values["preferred_lang"] ?? ""), ("firmver", values["firmver"] ?? "")]
        _ = try await request("start_apply2.htm", method: "POST", body: RouterAuthentication.orderedForm(fields, .formSubmission),
                              contentType: "application/x-www-form-urlencoded", timeout: 60)
    }

    /// The OUI database the page asks on a click; nil when the router does not have it.
    public func vendorDatabase() async throws -> [String: String]? {
        let data: Data
        do { data = try await request("ajax/ouiDB.json", timeout: 30) }
        catch RouterError.authenticationRequired { throw RouterError.authenticationRequired }
        catch is CancellationError { throw CancellationError() }
        catch { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object.compactMapValues { ($0 as? String).map(javaScriptTrim) }
    }
}
