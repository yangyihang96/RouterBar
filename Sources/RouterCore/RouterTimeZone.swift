import Foundation

/// One choice of the router page's time zone list (`var timezones` in Advanced_System_Content.asp). The list, its labels
/// and default rules come from Asuswrt-Merlin 3006.102.5 through script/generate_time_zones.py.
public struct RouterTimeZone: Codable, Sendable, Hashable, Identifiable {
    public var value: String
    public var label: String
    /// select_time_zone(): the page shows the daylight saving rows and sends time_zone_dst=1 when the value contains DST or TDT.
    public var dst: Bool
    /// tz_db.json's rule for the zone, absent where it has none.
    public var rule: String?
    /// rc/common.c tz_list: the zoneinfo file the router links /etc/localtime to.
    public var iana: String?
    public var id: String { value }
    /// The rule the page puts in the start and end selects when this zone is chosen: tz_db.json's, else M3.2.0/2,M11.1.0/2.
    public var defaultRule: String? {
        guard dst else { return nil }
        return rule.flatMap { $0.isEmpty ? nil : $0 } ?? RouterTimeZones.fallbackRule
    }
    /// Minutes east of UTC as the label states it: "(GMT+09:30)" is 570, "(GMT)" is 0.
    public var labelOffset: Int? {
        if label.hasPrefix("(GMT)") { return 0 }
        guard let match = label.firstMatch(of: /^\(GMT([+-])(\d{2}):(\d{2})\)/), let hours = Int(match.2), let minutes = Int(match.3) else { return nil }
        return (match.1 == "-" ? -1 : 1) * (hours * 60 + minutes)
    }
}

public enum RouterTimeZones {
    /// select_time_zone()'s rule when tz_db.json has none for a daylight saving zone.
    public static let fallbackRule = "M3.2.0/2,M11.1.0/2"
    public static let all: [RouterTimeZone] = {
        struct File: Decodable { var zones: [RouterTimeZone] }
        guard let url = Bundle.module.url(forResource: "TimeZones", withExtension: "json"), let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.zones
    }()
    public static func zone(_ value: String) -> RouterTimeZone? { all.first { $0.value == value } }
    /// select_time_zone() and applyRule(): a zone observes daylight saving when its value contains DST or TDT.
    public static func observesDST(_ value: String) -> Bool { value.contains("DST") || value.contains("TDT") }
    /// The zones matching every word of the query, in the page's order. A word such as "+10", "GMT+5:30" or "UTC-3"
    /// matches the offset in the label; any other word matches the label, the router value or the zoneinfo name.
    public static func search(_ query: String) -> [RouterTimeZone] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return all.filter { zone in
            words.allSatisfy { word in
                if let offset = offset(in: word) { return zone.labelOffset == offset }
                return [zone.label, zone.value, zone.iana ?? ""].contains { $0.localizedCaseInsensitiveContains(word) }
            }
        }
    }
    private static func offset(in word: String) -> Int? {
        guard let match = word.uppercased().wholeMatch(of: /(?:GMT|UTC)?([+-])(\d{1,2})(?::?(\d{2}))?/), let hours = Int(match.2) else { return nil }
        return (match.1 == "-" ? -1 : 1) * (hours * 60 + (match.3.flatMap { Int($0) } ?? 0))
    }
}

/// time_zone_dstoff: "Mm.w.d/h,Mm.w.d/h", the POSIX TZ rule for when daylight saving starts and ends.
public struct DaylightSavingRule: Hashable, Sendable {
    public struct Transition: Hashable, Sendable {
        /// 1–12.
        public var month: Int
        /// 1–5: the week-th such weekday of the month, 5 being the last one.
        public var week: Int
        /// 0 (Sunday) – 6 (Saturday).
        public var weekday: Int
        /// 0–23, local time.
        public var hour: Int
        public init(month: Int, week: Int, weekday: Int, hour: Int) { self.month = month; self.week = week; self.weekday = weekday; self.hour = hour }
        /// The page's dst_month, dst_week, dst_day and dst_hour selects.
        public static let months = 1...12, weeks = 1...5, weekdays = 0...6, hours = 0...23
        var isValid: Bool { Self.months.contains(month) && Self.weeks.contains(week) && Self.weekdays.contains(weekday) && Self.hours.contains(hour) }
        public var text: String { "M\(month).\(week).\(weekday)/\(hour)" }
        public static func weekName(_ week: Int) -> String { week == 5 ? "最后一个" : "第 \(week) 个" }
        public static func weekdayName(_ day: Int) -> String { "星期" + ["日", "一", "二", "三", "四", "五", "六"][min(max(day, 0), 6)] }
        /// "3 月第 2 个星期日 2:00".
        public var summary: String { "\(month) 月\(Self.weekName(week))\(Self.weekdayName(weekday)) \(hour):00" }
        /// The day of the month in `year`; week 5 falls back a week when the month has no fifth such weekday.
        func day(in year: Int) -> Int {
            let calendar = RouterClockRule.calendar
            guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
                  let length = calendar.range(of: .day, in: .month, for: first)?.count else { return 1 }
            var day = 1 + (weekday - (calendar.component(.weekday, from: first) - 1) + 7) % 7 + (week - 1) * 7
            while day > length { day -= 7 }
            return day
        }
        /// The moment this transition happens in `year` for a clock `offset` seconds east of UTC.
        func moment(in year: Int, offset: Int) -> Date {
            let local = RouterClockRule.calendar.date(from: DateComponents(year: year, month: month, day: day(in: year), hour: hour)) ?? .distantPast
            return local.addingTimeInterval(TimeInterval(-offset))
        }
    }
    public var start: Transition
    public var end: Transition
    public init(start: Transition, end: Transition) { self.start = start; self.end = end }
    /// Only the form the page writes; parse_dstoffset() keeps a select unchanged for any part outside its range.
    public init?(_ text: String) {
        guard let match = text.wholeMatch(of: /M(\d{1,2})\.(\d)\.(\d)\/(\d{1,2}),M(\d{1,2})\.(\d)\.(\d)\/(\d{1,2})/) else { return nil }
        let numbers = [match.1, match.2, match.3, match.4, match.5, match.6, match.7, match.8].compactMap { Int($0) }
        let start = Transition(month: numbers[0], week: numbers[1], weekday: numbers[2], hour: numbers[3])
        let end = Transition(month: numbers[4], week: numbers[5], weekday: numbers[6], hour: numbers[7])
        guard start.isValid, end.isValid else { return nil }
        self.init(start: start, end: end)
    }
    public var text: String { start.text + "," + end.text }
    /// validForm(): start and end may not share month, week and weekday, whatever the hours.
    public var overlaps: Bool { start.month == end.month && start.week == end.week && start.weekday == end.weekday }
    public var summary: String { "\(start.summary) 开始，\(end.summary) 结束" }
}

/// The TZ string rc builds from time_zone, time_zone_dst and time_zone_dstoff (rc/common.c time_zone_x_mapping), and the
/// clock it gives. rc stores it in time_zone_x and /etc/TZ and exports it as TZ; httpd's rfctime() uses time_zone_x too.
public struct RouterClockRule: Sendable, Equatable {
    /// rc builds time_zone_x in a 32-byte buffer, so it keeps at most 31 characters.
    public static let maximumLength = 31
    public let text: String
    /// Seconds east of UTC outside daylight saving.
    public let standardOffset: Int
    /// Seconds east of UTC during daylight saving: one hour ahead unless the zone names another offset.
    public let daylightOffset: Int?
    public let rule: DaylightSavingRule?

    /// nil when the values give no TZ string this can evaluate: an unreadable zone or rule, time_zone_dst disagreeing with
    /// the zone, or a string rc would cut short.
    public init?(zone: String, dst: String, rule ruleText: String) {
        let base = Self.base(of: zone)
        guard let match = base.wholeMatch(of: /([A-Za-z]{3,})([+-]?)(\d{1,2})(?::(\d{2}))?(?::(\d{2}))?(?:([A-Za-z]{3,})(?:([+-]?)(\d{1,2})(?::(\d{2}))?)?)?/),
              let hours = Int(match.3) else { return nil }
        func east(_ sign: Substring, _ hours: Int, _ minutes: Substring?, _ seconds: Substring? = nil) -> Int {
            // POSIX offsets count west of UTC: "UTC-10" is ten hours east.
            -(sign == "-" ? -1 : 1) * (hours * 3600 + (minutes.flatMap { Int($0) } ?? 0) * 60 + (seconds.flatMap { Int($0) } ?? 0))
        }
        standardOffset = east(match.2, hours, match.4, match.5)
        let daylight = RouterTimeZones.observesDST(zone)
        // nvram_get_int("time_zone_dst") decides whether the rule is appended.
        guard ((Int(dst) ?? 0) != 0) == daylight else { return nil }
        if daylight {
            guard match.6 != nil, let rule = DaylightSavingRule(ruleText) else { return nil }
            self.rule = rule
            daylightOffset = match.8.flatMap { Int($0) }.map { east(match.7 ?? "", $0, match.9) } ?? standardOffset + 3600
            text = base + "," + ruleText
        } else {
            guard match.6 == nil else { return nil }
            rule = nil; daylightOffset = nil
            text = Self.gmtForm(base)
        }
        guard text.count <= Self.maximumLength else { return nil }
    }

    /// '.' becomes ':' and the "_n" suffix is dropped: "UTC-9.30DST" → "UTC-9:30DST", "UTC-10DST_1" → "UTC-10DST".
    static func base(of zone: String) -> String { String(zone.replacingOccurrences(of: ".", with: ":").prefix { $0 != "_" }) }

    /// gettzoffset(): without daylight saving rc rewrites the zone as GMT plus its offset, e.g. "UTC-5" → "GMT-5".
    static func gmtForm(_ base: String) -> String {
        var offset = "", started = false, named = false
        for character in base {
            if "+-:".contains(character) || (character.isASCII && character.isWholeNumber) { offset.append(character); started = true }
            else if started { named = character.isLetter; break }
        }
        return started ? "GMT" + offset + (named ? "DST" : "") : base
    }

    public func secondsFromGMT(for date: Date) -> Int {
        guard let rule, let daylightOffset else { return standardOffset }
        let year = Self.calendar.component(.year, from: date.addingTimeInterval(TimeInterval(standardOffset)))
        let start = rule.start.moment(in: year, offset: standardOffset), end = rule.end.moment(in: year, offset: daylightOffset)
        // A southern rule (end before start in the year) is in daylight saving across the new year.
        let daylight = start < end ? (date >= start && date < end) : (date >= start || date < end)
        return daylight ? daylightOffset : standardOffset
    }

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()
}

/// Consecutive days on which the router's clock differs from a reference zone by the same amount.
public struct ClockDifference: Sendable, Equatable {
    /// Noon, router standard time, of the first and the last such day.
    public var first: Date
    public var last: Date
    /// The router's offset minus the reference's: negative when the router is behind.
    public var seconds: Int

    /// "2026年11月1日至2027年3月13日慢 1 小时；…", dates in `zone`, at most three ranges.
    public static func summary(_ differences: [ClockDifference], in zone: TimeZone) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "zh_CN"); format.timeZone = zone; format.dateFormat = "y年M月d日"
        let parts = differences.prefix(3).map { difference in
            let amount = abs(difference.seconds)
            let size = amount % 3600 == 0 ? "\(amount / 3600) 小时" : "\(amount / 60) 分钟"
            let dates = difference.first == difference.last ? format.string(from: difference.first)
                : "\(format.string(from: difference.first))至\(format.string(from: difference.last))"
            return "\(dates)\(difference.seconds < 0 ? "慢" : "快") \(size)"
        }
        return parts.joined(separator: "；") + (differences.count > 3 ? "，另有 \(differences.count - 3) 段" : "")
    }

    /// "UTC+10:00".
    public static func utc(_ seconds: Int) -> String {
        let minutes = abs(seconds) / 60
        return "UTC" + (seconds < 0 ? "-" : "+") + String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }
}

extension RouterClockRule {
    /// Compares the clocks at noon (router standard time) of each of `days` days from `start`. Transition hours are not
    /// compared, only whole days.
    public func differences(from reference: TimeZone, start: Date, days: Int = 366) -> [ClockDifference] {
        let day = 86_400.0, shift = Double(standardOffset)
        let firstNoon = (((start.timeIntervalSince1970 + shift) / day).rounded(.down) * day) + day / 2 - shift
        var result: [ClockDifference] = []
        for index in 0..<max(days, 0) {
            let moment = Date(timeIntervalSince1970: firstNoon + Double(index) * day)
            let seconds = secondsFromGMT(for: moment) - reference.secondsFromGMT(for: moment)
            guard seconds != 0 else { continue }
            if let last = result.last, last.seconds == seconds, moment.timeIntervalSince(last.last) <= day {
                result[result.count - 1].last = moment
            } else {
                result.append(ClockDifference(first: moment, last: moment, seconds: seconds))
            }
        }
        return result
    }
}

/// Advanced_System_Content.asp's validForm() and applyRule() for the three time zone variables, checked on the values the
/// router would hold after a save.
public enum RouterTimeZoneRules {
    public static let keys = ["time_zone", "time_zone_dst", "time_zone_dstoff"]

    /// select_time_zone(): the three values after choosing `zone`. A new daylight saving zone takes its default rule;
    /// choosing the router's own zone again keeps the router's rule, and a zone without daylight saving leaves
    /// time_zone_dstoff as the router has it, as applyRule() does.
    public static func choosing(_ zone: RouterTimeZone, stored: [String: String]) -> [String: String] {
        let keepsRule = zone.value == stored["time_zone"] || !zone.dst
        return ["time_zone": zone.value, "time_zone_dst": zone.dst ? "1" : "0",
                "time_zone_dstoff": keepsRule ? stored["time_zone_dstoff"] ?? "" : zone.defaultRule ?? ""]
    }

    public static func validate(zone: String, dst: String, rule: String) throws {
        // validForm(): the "select" placeholder is rejected as an empty field; only listed zones can be chosen.
        guard let entry = RouterTimeZones.zone(zone) else { throw RouterError.validation("时区：请从列表中选择时区") }
        guard dst == (entry.dst ? "1" : "0") else {
            throw RouterError.validation("夏令时：须与所选时区一致（\(entry.label)\(entry.dst ? "使用" : "不使用")夏令时）")
        }
        guard entry.dst else { return }
        guard let parsed = DaylightSavingRule(rule) else { throw RouterError.validation("夏令时规则：格式应为 Mm.w.d/h,Mm.w.d/h") }
        guard !parsed.overlaps else { throw RouterError.validation("夏令时规则：指定的时段不可重叠。开始与结束不能在同一个月的同一周、同一天。") }
        let length = RouterClockRule.base(of: zone).count + 1 + rule.count
        guard length <= RouterClockRule.maximumLength else {
            throw RouterError.validation("夏令时规则：路由器把时区和这条规则合成 \(length) 个字符的时区设置，超过它能保存的 \(RouterClockRule.maximumLength) 个字符，生效时会被截断。")
        }
    }

    /// Checks `values` (the router's values with the edits applied) when an edit touches the time zone.
    public static func validate(_ values: [String: String], changed: Set<String>) throws {
        guard !changed.isDisjoint(with: keys) else { return }
        let zone = values["time_zone"] ?? ""
        // applyRule() rewrites time_zone_dstoff only for a daylight saving zone.
        if changed.contains("time_zone_dstoff"), !RouterTimeZones.observesDST(zone) {
            throw RouterError.validation("夏令时规则：所选时区不使用夏令时，路由器网页不会修改这条规则。")
        }
        try validate(zone: zone, dst: values["time_zone_dst"] ?? "", rule: values["time_zone_dstoff"] ?? "")
    }
}

extension RouterClient {
    /// time_zone_x: the TZ string the router built at its last time zone setup.
    public func readEffectiveTimeZone() async throws -> String {
        try await readSettings(["time_zone_x"])["time_zone_x"] ?? ""
    }
}
