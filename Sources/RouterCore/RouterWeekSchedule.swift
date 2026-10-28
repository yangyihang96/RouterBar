import Foundation

// 家长管理 › 时间安排的时间编辑器：js/weekSchedule/weekSchedule.js（3006.102.5）中 ParentalControl.asp 用到的部分（PC_init_data、
// PC_init_layout、规则卡片、只读的一周概览、编辑弹窗的输入校验、全部清除、模式切换与 PC_transform_offtime_json_to_string）。
// 本页 support_draggable 为 false，没有拖拽编辑。这里只改本页的数据；“应用本页面设置”由 ParentalControlForm 提交整页。

/// weekScheduleApi's PC_data for one device: four groups of rules, the schedule mode, the ids, and what the editor does.
public struct ParentalSchedule: Sendable, Equatable {
    /// PC_data's groups in their order (init_PC_data_obj 39–45).
    public enum Group: Int, CaseIterable, Sendable {
        case daily, weekdays, weekend, other
        var key: String { ["Daily", "Weekdays", "Weekend", "Other"][rawValue] }
        /// The grid's group title (1704–1706): weekSche_Everyday, weekSche_Weekdays, weekSche_Weekend.
        var title: String { ["每天", "工作日", "周末", ""][rawValue] }
        /// The group a weekday mask goes to: `switch(weekday)` with 127, 62 and 65.
        static func of(_ weekday: Double) -> Group { weekday == 127 ? .daily : weekday == 62 ? .weekdays : weekday == 65 ? .weekend : .other }
    }
    /// PC_offtime_attr (1401–1410). The numbers are JavaScript numbers: parseInt can leave NaN or a negative value.
    public struct Rule: Sendable, Equatable, Identifiable {
        public var id: String
        public var enable: Double
        public var weekday: Double
        public var startHour: Double
        public var startMinute: Double
        public var endHour: Double
        public var endMinute: Double
        public var title: String
    }
    /// What weekScheduleApi keeps from one editor to the next (globals of the page): PC_schedule_mode and text_Offtime_Sche.
    public struct Carry: Sendable, Equatable {
        public var mode = "W"
        public var text = "离线计划"
        public init() {}
    }
    public struct Stop: Error, Sendable, Equatable { public let reason: String }

    public private(set) var groups: [[Rule]] = Array(repeating: [], count: 4)
    /// PC_schedule_mode: "W" 离线计划, "M" 在线计划.
    public private(set) var mode: String
    /// text_Offtime_Sche.
    public private(set) var modeText: String
    /// The header title and the overview's legend as PC_init_layout drew them (全部清除 does not draw them again).
    public private(set) var headerText = ""
    public private(set) var headerMode = ""
    /// PC_current_id.
    public private(set) var currentID = 100
    public let changesModes: Bool
    public let alternateDays: Bool
    /// PC_others_rule_num: the other devices' rules.
    public let othersRuleCount: Int
    /// data_max.
    public let maximum: OrderedJSON
    /// The router's weekday when the editor opened (0 Sunday), which the overview marks and a new rule starts with.
    public let today: Int
    /// The one-week overview shows instead of the rule cards.
    public var overview = false

    /// gen_lantowanTable: PC_init_data(offtime) then PC_init_layout.
    public init(offtime: String, changesModes: Bool, alternateDays: Bool, othersRuleCount: Int, maximum: OrderedJSON, today: Int, carry: Carry) {
        self.changesModes = changesModes; self.alternateDays = alternateDays; self.othersRuleCount = othersRuleCount
        self.maximum = maximum; self.today = today; mode = carry.mode; modeText = carry.text
        initData(offtime)
        layout()
    }

    public var carry: Carry { var carry = Carry(); carry.mode = mode; carry.text = modeText; return carry }
    public var count: Int { groups.map(\.count).reduce(0, +) }

    /// A rule of twelve characters whose enable, weekday or times do not parse (parseInt gives NaN). PC_init_data keeps each
    /// rule through JSON.parse(JSON.stringify(...)) (1445–1457), which turns NaN into null, and add_left_pad then writes
    /// "ll" (1209–1212) where NaN would give "aN"; the app does not model those nulls, so it does not edit such a rule.
    public static func unparsableRule(_ text: String) -> String? {
        javaScriptSplit(text, "<").first { value in
            guard value.utf16.count == 12 else { return false }
            let numbers = [javaScriptParseInt(javaScriptSubstr(value, 1, 1)), javaScriptParseInt(javaScriptSubstr(value, 2, 2), radix: 16),
                           javaScriptParseInt(javaScriptSubstr(value, 4, 2)), javaScriptParseInt(javaScriptSubstr(value, 6, 2)),
                           javaScriptParseInt(javaScriptSubstr(value, 8, 2)), javaScriptParseInt(javaScriptSubstr(value, 10, 2))]
            return numbers.contains { $0.isNaN }
        }
    }

    /// PC_init_data (1411–1473).
    mutating func initData(_ text: String) {
        groups = Array(repeating: [], count: 4)
        if changesModes { mode = "" }
        var id = 100
        if text != "" {
            for value in javaScriptSplit(text, "<") where value.utf16.count == 12 {
                if changesModes, mode == "" { mode = javaScriptSubstr(value, 0, 1).uppercased() }
                let weekday = javaScriptParseInt(javaScriptSubstr(value, 2, 2), radix: 16)
                let group = Group.of(weekday)
                let rule = Rule(id: String(id) + javaScriptSubstr(value, 2, 10), enable: javaScriptParseInt(javaScriptSubstr(value, 1, 1)), weekday: weekday,
                                startHour: javaScriptParseInt(javaScriptSubstr(value, 4, 2)), startMinute: javaScriptParseInt(javaScriptSubstr(value, 6, 2)),
                                endHour: javaScriptParseInt(javaScriptSubstr(value, 8, 2)), endMinute: javaScriptParseInt(javaScriptSubstr(value, 10, 2)),
                                title: group == .other ? Self.weekTitle(weekday) : group.key)
                id += 1
                groups[group.rawValue].append(rule)
            }
        }
        currentID = id
        if changesModes {
            if mode == "" { mode = "W" }
            if mode == "W" { modeText = "离线计划" } else if mode == "M" { modeText = "在线计划" }
        }
    }

    /// PC_init_layout (1474–1547): the header and legend take the mode's text, the cards are drawn (and so sorted) and the
    /// cards show rather than the overview.
    mutating func layout() {
        headerText = modeText; headerMode = mode
        if count > 0 { sort() }
        overview = false
    }

    /// PC_sort_data (1872–1896): each group by weekday mask, then start, then end time (a stable sort, as the browser's).
    mutating func sort() {
        func order(_ a: Rule, _ b: Rule) -> Int {
            let w1 = javaScriptParseInt(javaScriptText(a.weekday)), w2 = javaScriptParseInt(javaScriptText(b.weekday))
            let s1 = a.startHour * 60 + a.startMinute, s2 = b.startHour * 60 + b.startMinute
            let e1 = a.endHour * 60 + a.endMinute, e2 = b.endHour * 60 + b.endMinute
            if w1 < w2 { return -1 }; if w1 > w2 { return 1 }
            if s1 < s2 { return -1 }; if s1 > s2 { return 1 }
            if e1 < e2 { return -1 }; if e1 > e2 { return 1 }
            return 0
        }
        groups = groups.map { rules in
            rules.enumerated().sorted { a, b in
                let compared = order(a.element, b.element)
                return compared != 0 ? compared < 0 : a.offset < b.offset
            }.map { $0.element }
        }
    }

    /// PC_get_week_title (1669–1681): the days of the mask, "SUN / MON / …".
    static func weekTitle(_ weekday: Double) -> String {
        let bits = javaScriptInt32(javaScriptParseInt(javaScriptText(weekday)))
        return ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"].enumerated().filter { (bits >> Int32($0.offset)) & 1 == 1 }.map { $0.element }.joined(separator: " / ")
    }

    // MARK: The rule cards (PC_get_grid_period_component 1682–1833)

    /// One card as the grid draws it.
    public struct Card: Sendable, Equatable, Identifiable {
        public let id: String
        public let group: Group
        public let index: Int
        /// The group title over the card, nil where the grid hides it (all but the first of a group; for Other, a title
        /// equal to the one before).
        public let title: String?
        public let start: String
        public let end: String
        /// `if(PC_offtime_obj.enable)`: the card and its switch show on.
        public let on: Bool
    }
    public var cards: [Card] {
        var cards: [Card] = []
        for group in Group.allCases {
            var previous: String?
            for (index, rule) in groups[group.rawValue].enumerated() {
                let title: String
                if group == .other {
                    title = [("MON", "一"), ("TUE", "二"), ("WED", "三"), ("THU", "四"), ("FRI", "五"), ("SAT", "六"), ("SUN", "日")]
                        .reduce(rule.title) { javaScriptReplace($0, $1.0, $1.1) }
                } else {
                    title = group.title
                }
                let shown = group == .other ? (title == previous ? nil : title) : (index == 0 ? title : nil)
                previous = title
                cards.append(Card(id: rule.id, group: group, index: index, title: shown,
                                  start: Self.pad(rule.startHour) + ":" + Self.pad(rule.startMinute), end: Self.pad(rule.endHour) + ":" + Self.pad(rule.endMinute),
                                  on: !rule.enable.isNaN && rule.enable != 0))
            }
        }
        return cards
    }

    /// add_left_pad(number, 2) (1209–1212): the number's text with two zeros before it, cut to its last two characters.
    static func pad(_ number: Double) -> String { pad(javaScriptText(number)) }
    static func pad(_ text: String) -> String {
        let units = Array(("00" + text).utf16)
        return String(decoding: units.suffix(2), as: UTF16.self)
    }
    /// Number.prototype.toString(16) for the weekday mask.
    static func hex(_ number: Double) -> String {
        number.javaScriptString(radix: 16)
    }

    func rule(_ card: Card) -> Rule { groups[card.group.rawValue][card.index] }

    /// The card's switch (1757–1771): on becomes 0, off becomes 1.
    public mutating func toggle(_ card: Card) {
        groups[card.group.rawValue][card.index].enable = card.on ? 0 : 1
    }
    /// The trash icon's 确认 (1786–1818, PC_remove_offtime 1834–1841): the first rule of the group with that id goes.
    public mutating func delete(_ card: Card) {
        if let index = groups[card.group.rawValue].firstIndex(where: { $0.id == card.id }) { groups[card.group.rawValue].remove(at: index) }
    }
    /// 全部清除's 确认 (1232–1236): PC_init_data(""), which with modes also sets the mode back to 离线计划 (the header keeps
    /// what it showed).
    public mutating func clearAll() { initData("") }
    /// check_rule_full (1965–1975): another rule would pass data_max.
    public var isFull: Bool { javaScriptAbove(.number(String(othersRuleCount + count + 1)), maximum) }
    /// The alert for a full list (1584–1592).
    public var fullAlert: String { "规则的最大数量为 \(TORSettings.javaScriptString(maximum))。\n为了添加新规则，您可以删除那些未使用的规则。" }

    /// "+" (1581–1611): a new rule on today, 08:00–12:00.
    public var newRuleEditor: ScheduleRuleEditor {
        let rule = Rule(id: "", enable: 1, weekday: pow(2, Double(today)), startHour: 8, startMinute: 0, endHour: 12, endMinute: 0, title: "")
        return ScheduleRuleEditor(rule: rule, isNew: true, title: modeText, alternateDays: alternateDays)
    }
    /// A card (1724–1736): the rule in the editor.
    public func editor(_ card: Card) -> ScheduleRuleEditor {
        ScheduleRuleEditor(rule: rule(card), isNew: false, title: modeText, alternateDays: alternateDays)
    }

    /// 保存 (914–1010): the rule from the editor, or the popup it shows instead.
    public mutating func save(_ editor: ScheduleRuleEditor) -> String? {
        switch editor.result {
        case .failure(let failure): return failure.reason
        case .success(let value):
            var rule = Rule(id: editor.rule.id, enable: editor.rule.enable, weekday: value.weekday, startHour: value.startHour, startMinute: value.startMinute,
                            endHour: value.endHour, endMinute: value.endMinute, title: "")
            if editor.isNew {
                rule.enable = 1
                rule.id = String(currentID) + Self.pad(Self.hex(value.weekday).uppercased()) + Self.pad(value.startHour) + Self.pad(value.startMinute)
                    + Self.pad(value.endHour) + Self.pad(value.endMinute)
                currentID += 1
            } else {
                let old = Group.of(editor.rule.weekday).rawValue
                if let index = groups[old].firstIndex(where: { $0.id == editor.rule.id }) { groups[old].remove(at: index) }
            }
            let group = Group.of(value.weekday)
            // Only an edited Daily rule is titled; the others take their group's name or the days.
            rule.title = group == .other ? Self.weekTitle(value.weekday) : (group == .daily && editor.isNew ? "" : group.key)
            groups[group.rawValue].append(rule)
            sort()
            return nil
        }
    }

    /// The mode window's 保存 (1948–1961): another mode resets the rules to its default and draws the editor again.
    public mutating func changeMode(_ chosen: String) {
        guard chosen != mode else { return }
        mode = chosen
        initData(chosen == "W" ? "W03E21000700<W04122000800" : chosen == "M" ? "M13E17002100<M14116002200" : "")
        layout()
    }

    /// PC_transform_offtime_json_to_string (1842–1871): the groups in order, each rule as mode, enable, the mask in two hex
    /// digits and the four times in two digits; "W" when the mode cannot be changed.
    public var offtime: String {
        groups.joined().map { rule in
            (changesModes ? mode : "W") + javaScriptText(rule.enable) + Self.pad(Self.hex(javaScriptParseInt(javaScriptText(rule.weekday))).uppercased())
                + Self.pad(rule.startHour) + Self.pad(rule.startMinute) + Self.pad(rule.endHour) + Self.pad(rule.endMinute)
        }.joined(separator: "<")
    }

    /// The editor's 应用本页面设置 (1258–1285) asks first when an online schedule has rules and none is on.
    public var asksBeforeApply: Bool { changesModes && mode == "M" && count != 0 && !cards.contains(where: \.on) }

    // MARK: The one-week overview (transform_alternate_days_to_each_day 1995–2035, overview_offtime_component 588–626)

    /// One bar of the overview, in minutes of its day.
    public struct Bar: Sendable, Equatable {
        public let start: Double
        public let end: Double
        /// `enable == "0"`: drawn as disabled.
        public let disabled: Bool
    }
    /// The bars of each day, Sunday first: a rule that ends at or before its start runs to 24:00 and goes on the next day
    /// from 00:00; bars with a missing or reversed time are not drawn.
    public var bars: [[Bar]] {
        var days = Array(repeating: [Bar](), count: 7)
        for rule in groups.joined() {
            var end = (rule.endHour, rule.endMinute), next: (Double, Double)?
            if rule.startHour * 60 + rule.startMinute >= rule.endHour * 60 + rule.endMinute { next = end; end = (24, 0) }
            let mask = javaScriptInt32(rule.weekday)
            for day in 0..<7 where (mask >> Int32(day)) & 1 == 1 {
                func add(_ day: Int, _ start: (Double, Double), _ end: (Double, Double)) {
                    guard !(start.0 > end.0) else { return }
                    days[day].append(Bar(start: start.0 * 60 + start.1, end: end.0 * 60 + end.1, disabled: rule.enable == 0))
                }
                add(day, (rule.startHour, rule.startMinute), end)
                if let next { add(day + 1 > 6 ? 0 : day + 1, (0, 0), next) }
            }
        }
        return days
    }
}

/// The edit window (edit_time_setting_component 627–1067) for a PC rule: the four time inputs with their lists, the hint,
/// 全天, the weekday buttons and 保存.
public struct ScheduleRuleEditor: Sendable, Equatable {
    public enum Field: Int, CaseIterable, Sendable {
        case startHour, startMinute, endHour, endMinute
        public var isHour: Bool { self == .startHour || self == .endHour }
    }
    public let rule: ParentalSchedule.Rule
    public let isNew: Bool
    /// text_Offtime_Sche when the window opened.
    public let title: String
    public let alternateDays: Bool
    public var texts: [String]
    /// valid_hint_bg.
    public var hint: String?
    /// The input the hint is for: the others are disabled and their lists closed to clicks.
    public var errorField: Field?
    /// all_day_checkbox.
    public var allDay = false
    /// The weekday buttons, Sunday first.
    public var days: [Bool]

    init(rule: ParentalSchedule.Rule, isNew: Bool, title: String, alternateDays: Bool) {
        self.rule = rule; self.isNew = isNew; self.title = title; self.alternateDays = alternateDays
        texts = [rule.startHour, rule.startMinute, rule.endHour, rule.endMinute].map(ParentalSchedule.pad)
        let mask = javaScriptInt32(javaScriptParseInt(javaScriptText(rule.weekday)))
        days = (0..<7).map { (mask >> Int32($0)) & 1 == 1 }
    }

    /// The input can be typed in: not with 全天, and only the input with the hint while one shows.
    public func isEnabled(_ field: Field) -> Bool { !allDay && (errorField == nil || errorField == field) }
    /// The list's options (788–822): hours 00–23, minutes 00, 15, 30, 45 and 59.
    public static func options(_ field: Field) -> [Int] { field.isHour ? Array(0...23) : [0, 15, 30, 45, 59] }

    /// The input's blur (700–757).
    public mutating func blur(_ field: Field) {
        let value = javaScriptTrim(texts[field.rawValue])
        texts[field.rawValue] = value
        if value.isEmpty { showHint("* 栏位不能为空白", field); return }
        let number = javaScriptParseInt(value)
        if javaScriptNumber(value) == nil || (field.isHour && number > 24) || (!field.isHour && number > 59) {
            showHint("* 不正确的时间格式。", field); return
        }
        var startHour = javaScriptParseInt(texts[0]), endHour = javaScriptParseInt(texts[2])
        let startMinute = javaScriptParseInt(texts[1]), endMinute = javaScriptParseInt(texts[3])
        if startHour == 24 { startHour = 0; texts[0] = "00" }
        if startHour == 0 && startMinute == 0 && endHour == 0 && endMinute == 0 { endHour = 24; texts[2] = "24" }
        if endHour * 60 + endMinute > 1440 { endHour = 0; texts[2] = "00" }
        if !alternateDays {
            let start = startHour * 60 + startMinute, end = endHour * 60 + endMinute
            if start > end { showHint("* 您所设置的开始时间晚于结束时间。", field); return }
            if end > 1440 { showHint("* 时间结束 : 格式不正确。", field); return }
            if start == end { showHint("* Please enter different start and end time.", field); return }
        }
        hint = nil; errorField = nil
        texts[field.rawValue] = ParentalSchedule.pad(texts[field.rawValue])
    }
    /// show_valid_hint: the hint shows and only this input stays usable.
    mutating func showHint(_ text: String, _ field: Field) { hint = text; errorField = field }

    /// A list option (806–819): the value goes in; on the input with the hint, the hint goes first; then the input's blur.
    public mutating func choose(_ value: Int, for field: Field) {
        texts[field.rawValue] = ParentalSchedule.pad(String(value))
        if errorField == field { hint = nil; errorField = nil }
        blur(field)
    }

    /// 全天 (842–862): on sets 00:00–24:00 and disables the inputs and lists; off enables them again.
    public mutating func toggleAllDay() {
        allDay.toggle()
        if allDay { texts = ["00", "00", "24", "00"]; hint = nil }
        errorField = nil
    }
    public mutating func toggleDay(_ day: Int) { days[day].toggle() }

    struct Value: Sendable, Equatable { let weekday: Double, startHour: Double, startMinute: Double, endHour: Double, endMinute: Double }
    struct Failure: Error, Sendable, Equatable { let reason: String }

    /// 保存's checks (919–958): the inputs with a hint showing (three lists switched off) or a NaN fail, as does a start not
    /// before the end without alternate days; no weekday has its own popup.
    var result: Result<Value, Failure> {
        // `deactivate_len == 4 || deactivate_len == 0`: 全天 switches off all four lists, a hint the three other ones.
        var legal = allDay || errorField == nil
        var startHour = javaScriptParseInt(texts[0]), endHour = javaScriptParseInt(texts[2])
        let startMinute = javaScriptParseInt(texts[1]), endMinute = javaScriptParseInt(texts[3])
        if [startHour, startMinute, endHour, endMinute].contains(where: \.isNaN) { legal = false }
        if startHour == 24 { startHour = 0 }
        if startHour == 0 && startMinute == 0 && endHour == 0 && endMinute == 0 { endHour = 24 }
        if endHour * 60 + endMinute > 1440 { endHour = 0 }
        if !alternateDays {
            let start = startHour * 60 + startMinute, end = endHour * 60 + endMinute
            if start >= end || end > 1440 { legal = false }
        }
        guard legal else { return .failure(Failure(reason: "格式不正确。 请再次检查并重新输入。")) }
        let weekday = days.enumerated().filter { $0.element }.reduce(0.0) { $0 + pow(2, Double($1.offset)) }
        guard weekday != 0 else { return .failure(Failure(reason: "Week field is blank.")) }
        return .success(Value(weekday: weekday, startHour: startHour, startMinute: startMinute, endHour: endHour, endMinute: endMinute))
    }
}
