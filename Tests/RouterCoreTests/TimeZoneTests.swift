import Foundation
import Testing
@testable import RouterCore

private actor TimeZoneMock: RouterTransport {
    enum Reply: Sendable { case text(String), failure(any Error & Sendable) }
    var replies: [Reply]
    var requests: [URLRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> RouterHTTPResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw RouterError.network("No mock response") }
        switch replies.removeFirst() {
        case .text(let text): return RouterHTTPResponse(data: Data(text.utf8), status: 200)
        case .failure(let error): throw error
        }
    }
    nonisolated func cancel() {}
    var posts: [[String: String]] {
        requests.filter { $0.httpMethod == "POST" }.compactMap { request in
            request.httpBody.flatMap { String(decoding: $0, as: UTF8.self).removingPercentEncoding }
                .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String] }
        }
    }
}
private func client(_ mock: TimeZoneMock) throws -> RouterClient { RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: mock, writes: .reference) }
private func ntp() throws -> SettingSection { try #require(SettingsCatalog.sections.first { $0.id == "ntp" }) }
private func field(_ key: String) throws -> SettingField { try #require(try ntp().fields.first { $0.key == key }) }
/// The reply lost after dispatch, which ends a save before its readback wait.
private let lost = TimeZoneMock.Reply.failure(URLError(.networkConnectionLost))
private func stored(_ zone: String, _ dst: String, _ rule: String) -> TimeZoneMock.Reply {
    .text(#"{"time_zone":"\#(zone)","time_zone_dst":"\#(dst)","time_zone_dstoff":"\#(rule)"}"#)
}
private func date(_ text: String) throws -> Date { try #require(ISO8601DateFormatter().date(from: text)) }
private let usRule = "M3.2.0/2,M11.1.0/2", australianRule = "M10.1.0/2,M4.1.0/3"

// MARK: The page's list

@Test func zoneListIsThePageListWithItsDefaultRules() throws {
    let zones = RouterTimeZones.all
    #expect(zones.count == 101); #expect(Set(zones.map(\.value)).count == zones.count)
    #expect(zones.first?.value == "UTC12"); #expect(zones.last?.value == "UTC-13")
    #expect(RouterTimeZones.zone("select") == nil)
    let sydney = try #require(RouterTimeZones.zone("UTC-10DST_1"))
    #expect(sydney.label == "(GMT+10:00) 堪培拉，墨尔本，雪梨"); #expect(sydney.dst)
    #expect(sydney.defaultRule == australianRule); #expect(sydney.iana == "Australia/Canberra"); #expect(sydney.labelOffset == 600)
    // tz_db.json has "" for US Central; the page then fills in its own fallback.
    #expect(RouterTimeZones.zone("UTC6DST")?.defaultRule == RouterTimeZones.fallbackRule)
    #expect(RouterTimeZones.zone("UTC-10_6")?.defaultRule == nil)
    for zone in zones {
        #expect(zone.dst == RouterTimeZones.observesDST(zone.value))
        #expect(zone.labelOffset != nil)
    }
    #expect(zones.filter(\.dst).count == 31)
}
@Test func everyListedZoneGivesATZStringTheRouterKeepsWhole() throws {
    for zone in RouterTimeZones.all {
        let clock = try #require(RouterClockRule(zone: zone.value, dst: zone.dst ? "1" : "0", rule: zone.defaultRule ?? "M3.2.0/2,M10.2.0/2"), "\(zone.value)")
        #expect(clock.text.count <= RouterClockRule.maximumLength)
        // The standard offset matches the label: POSIX "UTC-10" is GMT+10.
        #expect(clock.standardOffset == (zone.labelOffset ?? 0) * 60, "\(zone.value)")
        try RouterTimeZoneRules.validate(zone: zone.value, dst: zone.dst ? "1" : "0", rule: zone.defaultRule ?? "")
    }
}
@Test func searchMatchesNamesAndOffsets() {
    #expect(RouterTimeZones.search("").count == RouterTimeZones.all.count)
    #expect(RouterTimeZones.search("雪梨").map(\.value) == ["UTC-10DST_1"])
    #expect(Set(RouterTimeZones.search("+10").map(\.value)) == ["UTC-10DST_1", "UTC-10_2", "UTC-10_4", "TST-10TDT", "UTC-10_6"])
    #expect(RouterTimeZones.search("GMT+5:30").allSatisfy { $0.labelOffset == 330 })
    #expect(RouterTimeZones.search("utc-3").map(\.value) == ["EBST3", "UTC3", "UTC3_1", "UTC3DST"])
    #expect(RouterTimeZones.search("australia").contains { $0.value == "UTC-9.30DST" })
    #expect(RouterTimeZones.search("+10 australia").map(\.value) == ["UTC-10DST_1", "UTC-10_2", "TST-10TDT"])
    #expect(RouterTimeZones.search("没有这个城市").isEmpty)
}

// MARK: time_zone_dstoff and time_zone_x

@Test func daylightSavingRulesUseOnlyThePageFormat() throws {
    let rule = try #require(DaylightSavingRule(australianRule))
    #expect(rule.text == australianRule); #expect(!rule.overlaps)
    #expect(rule.start == .init(month: 10, week: 1, weekday: 0, hour: 2)); #expect(rule.end == .init(month: 4, week: 1, weekday: 0, hour: 3))
    #expect(rule.summary == "10 月第 1 个星期日 2:00 开始，4 月第 1 个星期日 3:00 结束")
    #expect(DaylightSavingRule("M3.5.6/23,M10.4.0/0")?.start.summary == "3 月最后一个星期六 23:00")
    for text in ["", "M13.1.0/2,M4.1.0/3", "M10.0.0/2,M4.1.0/3", "M10.6.0/2,M4.1.0/3", "M10.1.7/2,M4.1.0/3", "M10.1.0/24,M4.1.0/3",
                 "M10.1.0,M4.1.0", "M10.1.0/2", "J60/2,J300/2", "M10.1.0/2,M4.1.0/3,", " M10.1.0/2,M4.1.0/3"] {
        #expect(DaylightSavingRule(text) == nil, "\(text)")
    }
    // validForm() compares month, week and weekday only.
    #expect(DaylightSavingRule("M10.1.0/2,M10.1.0/3")?.overlaps == true)
}
@Test func tzStringFollowsTimeZoneXMapping() throws {
    #expect(RouterClockRule(zone: "UTC-10DST_1", dst: "1", rule: usRule)?.text == "UTC-10DST,M3.2.0/2,M11.1.0/2")
    let adelaide = try #require(RouterClockRule(zone: "UTC-9.30DST", dst: "1", rule: australianRule))
    #expect(adelaide.text == "UTC-9:30DST,M10.1.0/2,M4.1.0/3"); #expect(adelaide.standardOffset == 34_200); #expect(adelaide.daylightOffset == 37_800)
    #expect(RouterClockRule(zone: "NST3.30DST", dst: "1", rule: usRule)?.standardOffset == -12_600)
    // Without daylight saving rc writes gettzoffset()'s GMT form and ignores time_zone_dstoff.
    #expect(RouterClockRule(zone: "UTC-10_6", dst: "0", rule: usRule)?.text == "GMT-10")
    #expect(RouterClockRule(zone: "UTC-3.30", dst: "0", rule: "")?.text == "GMT-3:30")
    #expect(RouterClockRule(zone: "GMT0", dst: "0", rule: "")?.text == "GMT0")
    #expect(RouterClockRule(zone: "UTC-10_6", dst: "0", rule: "")?.standardOffset == 36_000)
    // time_zone_dst has to agree with the zone, and the rule has to be readable.
    #expect(RouterClockRule(zone: "UTC-10DST_1", dst: "0", rule: usRule) == nil)
    #expect(RouterClockRule(zone: "UTC-10_6", dst: "1", rule: usRule) == nil)
    #expect(RouterClockRule(zone: "UTC-10DST_1", dst: "1", rule: "M10.1.0") == nil)
    // rc keeps 31 characters of time_zone_x.
    #expect(RouterClockRule(zone: "UTC-9.30DST", dst: "1", rule: "M12.5.6/23,M11.5.6/23") == nil)
}
@Test func offsetsFollowThePOSIXRule() throws {
    #expect(DaylightSavingRule.Transition(month: 10, week: 1, weekday: 0, hour: 2).day(in: 2026) == 4)
    #expect(DaylightSavingRule.Transition(month: 11, week: 1, weekday: 0, hour: 2).day(in: 2026) == 1)
    #expect(DaylightSavingRule.Transition(month: 3, week: 2, weekday: 0, hour: 2).day(in: 2027) == 14)
    // Week 5 is the last such weekday: March 2027 has four Sundays.
    #expect(DaylightSavingRule.Transition(month: 3, week: 5, weekday: 0, hour: 2).day(in: 2027) == 28)
    #expect(DaylightSavingRule.Transition(month: 10, week: 5, weekday: 0, hour: 2).day(in: 2027) == 31)

    let southern = try #require(RouterClockRule(zone: "UTC-10DST_1", dst: "1", rule: australianRule))
    #expect(southern.secondsFromGMT(for: try date("2027-01-15T00:00:00Z")) == 39_600)
    #expect(southern.secondsFromGMT(for: try date("2027-06-15T00:00:00Z")) == 36_000)
    // Ends 4 April 2027 03:00 daylight time (16:00 UTC the day before); starts 3 October 02:00 standard time.
    #expect(southern.secondsFromGMT(for: try date("2027-04-03T15:59:59Z")) == 39_600)
    #expect(southern.secondsFromGMT(for: try date("2027-04-03T16:00:00Z")) == 36_000)
    #expect(southern.secondsFromGMT(for: try date("2027-10-02T15:59:59Z")) == 36_000)
    #expect(southern.secondsFromGMT(for: try date("2027-10-02T16:00:00Z")) == 39_600)

    let northern = try #require(RouterClockRule(zone: "UTC-10DST_1", dst: "1", rule: usRule))
    #expect(northern.secondsFromGMT(for: try date("2027-01-15T00:00:00Z")) == 36_000)
    #expect(northern.secondsFromGMT(for: try date("2027-06-15T00:00:00Z")) == 39_600)
    #expect(try #require(RouterClockRule(zone: "UTC-10_6", dst: "0", rule: "")).secondsFromGMT(for: .now) == 36_000)
}
@Test func differencesShowWhereARuleMissesTheZone() throws {
    let sydney = try #require(TimeZone(identifier: "Australia/Sydney"))
    let start = try date("2026-10-16T00:00:00Z")
    let us = try #require(RouterClockRule(zone: "UTC-10DST_1", dst: "1", rule: usRule))
    #expect(us.differences(from: sydney, start: start) == [
        ClockDifference(first: try date("2026-11-01T02:00:00Z"), last: try date("2027-03-13T02:00:00Z"), seconds: -3600),
        ClockDifference(first: try date("2027-04-04T02:00:00Z"), last: try date("2027-10-02T02:00:00Z"), seconds: 3600),
    ])
    let firmwareDefault = try #require(RouterClockRule(zone: "UTC-10DST_1", dst: "1", rule: australianRule))
    #expect(firmwareDefault.differences(from: sydney, start: start).isEmpty)
    #expect(firmwareDefault.differences(from: try #require(TimeZone(identifier: "Australia/Canberra")), start: start).isEmpty)
    let guam = try #require(RouterClockRule(zone: "UTC-10_6", dst: "0", rule: ""))
    #expect(guam.differences(from: try #require(TimeZone(identifier: "Pacific/Guam")), start: start).isEmpty)
    #expect(us.differences(from: sydney, start: start, days: 0).isEmpty)
}

@Test func differenceSummaryUsesChineseDatesInTheZone() throws {
    let sydney = try #require(TimeZone(identifier: "Australia/Sydney"))
    let us = try #require(RouterClockRule(zone: "UTC-10DST_1", dst: "1", rule: usRule))
    let differences = us.differences(from: sydney, start: try date("2026-10-16T00:00:00Z"))
    #expect(ClockDifference.summary(differences, in: sydney) == "2026年11月1日至2027年3月13日慢 1 小时；2027年4月4日至2027年10月2日快 1 小时")
    let day = ClockDifference(first: try date("2027-01-01T02:00:00Z"), last: try date("2027-01-01T02:00:00Z"), seconds: 1800)
    #expect(ClockDifference.summary([day], in: sydney) == "2027年1月1日快 30 分钟")
    #expect(ClockDifference.summary(Array(repeating: day, count: 5), in: sydney).hasSuffix("，另有 2 段"))
    #expect(ClockDifference.utc(36_000) == "UTC+10:00"); #expect(ClockDifference.utc(-12_600) == "UTC-03:30"); #expect(ClockDifference.utc(0) == "UTC+00:00")
}

// MARK: Choosing a zone

@Test func choosingAZoneWritesWhatThePageWrites() throws {
    let router = ["time_zone": "UTC-10DST_1", "time_zone_dst": "1", "time_zone_dstoff": usRule]
    func choose(_ value: String) throws -> [String: String] { RouterTimeZoneRules.choosing(try #require(RouterTimeZones.zone(value)), stored: router) }
    // A new daylight saving zone takes its tz_db.json rule, or the page's fallback where tz_db.json has none.
    #expect(try choose("NZST-12DST") == ["time_zone": "NZST-12DST", "time_zone_dst": "1", "time_zone_dstoff": "M9.5.0/2,M4.1.0/3"])
    #expect(try choose("UTC6DST")["time_zone_dstoff"] == RouterTimeZones.fallbackRule)
    // The router's own zone keeps the router's rule; a zone without daylight saving leaves the rule untouched.
    #expect(try choose("UTC-10DST_1") == router)
    #expect(try choose("UTC-10_6") == ["time_zone": "UTC-10_6", "time_zone_dst": "0", "time_zone_dstoff": usRule])
    for zone in RouterTimeZones.all {
        let chosen = RouterTimeZoneRules.choosing(zone, stored: router)
        try RouterTimeZoneRules.validate(chosen, changed: Set(chosen.filter { router[$0.key] != $0.value }.keys))
    }
}
@Test func aChosenZoneIsSavedAsTheChangedVariablesOnly() async throws {
    let router = ["time_zone": "UTC-10DST_1", "time_zone_dst": "1", "time_zone_dstoff": usRule]
    let chosen = RouterTimeZoneRules.choosing(try #require(RouterTimeZones.zone("UTC-9.30DST")), stored: router)
    let changes = try RouterTimeZoneRules.keys.compactMap { key -> SettingChange? in
        router[key] == chosen[key] ? nil : SettingChange(field: try field(key), before: router[key] ?? "", after: chosen[key] ?? "")
    }
    let mock = TimeZoneMock([stored("UTC-10DST_1", "1", usRule), lost])
    _ = try await client(mock).applySettings(section: try ntp(), changes: changes)
    #expect(await mock.posts.first == ["time_zone": "UTC-9.30DST", "time_zone_dstoff": australianRule, "action_mode": "apply", "rc_service": "restart_time;restart_firewall;"])
}

// MARK: The catalog and the page's checks

@Test func systemPageCarriesTheTimeZoneRowsInPageOrder() throws {
    #expect(try ntp().fields.map(\.key).prefix(5) == ["ntpd_enable", "ntpd_server_redir", "time_zone", "time_zone_dst", "time_zone_dstoff"])
    #expect(try field("time_zone").kind == "timeZone"); #expect(try field("time_zone_dst").kind == "toggle"); #expect(try field("time_zone_dstoff").kind == "dstRule")
    try field("time_zone").validate("UTC-10DST_1")
    for value in ["select", "", "UTC-12DST"] { #expect(throws: RouterError.self) { try field("time_zone").validate(value) } }
    try field("time_zone_dstoff").validate(australianRule)
    for value in ["", "M10.1.0/2,M10.1.0/3", "M10.1.0/2"] { #expect(throws: RouterError.self) { try field("time_zone_dstoff").validate(value) } }
    try field("time_zone_dst").validate("1")
    #expect(throws: RouterError.self) { try field("time_zone_dst").validate("2") }
}
@Test func combinationsThePageRejectsAreRejected() throws {
    try RouterTimeZoneRules.validate(zone: "UTC-10DST_1", dst: "1", rule: australianRule)
    // A zone without daylight saving ignores whatever rule is stored.
    try RouterTimeZoneRules.validate(zone: "UTC-10_6", dst: "0", rule: "anything")
    #expect(throws: RouterError.self) { try RouterTimeZoneRules.validate(zone: "select", dst: "0", rule: "") }
    #expect(throws: RouterError.self) { try RouterTimeZoneRules.validate(zone: "UTC-10DST_1", dst: "0", rule: australianRule) }
    #expect(throws: RouterError.self) { try RouterTimeZoneRules.validate(zone: "UTC-10_6", dst: "1", rule: australianRule) }
    #expect(throws: RouterError.self) { try RouterTimeZoneRules.validate(zone: "UTC-10DST_1", dst: "1", rule: "M10.1.0/2,M10.1.0/3") }
    #expect(throws: RouterError.self) { try RouterTimeZoneRules.validate(zone: "UTC-9.30DST", dst: "1", rule: "M12.5.6/23,M11.5.6/23") }
    let guam = ["time_zone": "UTC-10_6", "time_zone_dst": "0", "time_zone_dstoff": usRule]
    #expect(throws: RouterError.self) { try RouterTimeZoneRules.validate(guam.merging(["time_zone_dstoff": australianRule]) { $1 }, changed: ["time_zone_dstoff"]) }
    // Only a save that touches the time zone is checked, so other system settings stay savable.
    try RouterTimeZoneRules.validate(["time_zone": "UTC-10DST_1", "time_zone_dst": "0"], changed: ["ntp_server0"])
}

// MARK: Saving

@Test func aNewRuleIsSavedWithTheSystemPageServices() async throws {
    let mock = TimeZoneMock([stored("UTC-10DST_1", "1", usRule), lost])
    let receipt = try await client(mock).applySettings(section: try ntp(), changes: [.init(field: try field("time_zone_dstoff"), before: usRule, after: australianRule)])
    #expect(!receipt.isVerified)
    let post = try #require(await mock.posts.first)
    #expect(post["time_zone_dstoff"] == australianRule); #expect(post["time_zone"] == nil); #expect(post["time_zone_dst"] == nil)
    #expect(post["action_mode"] == "apply"); #expect(post["rc_service"] == "restart_time;restart_firewall;")
    // The conflict check reads the three variables together before the post.
    let read = try #require(await mock.requests.first?.url?.absoluteString.removingPercentEncoding)
    #expect(RouterTimeZoneRules.keys.allSatisfy { read.contains("nvram_char_to_ascii(\($0),\($0))") })
    #expect(await mock.requests.count == 2)
}
@Test func aNewZoneTakesItsDaylightSavingSwitchAndRule() async throws {
    let auckland = TimeZoneMock([stored("UTC-10DST_1", "1", usRule), lost])
    _ = try await client(auckland).applySettings(section: try ntp(), changes: [
        .init(field: try field("time_zone"), before: "UTC-10DST_1", after: "NZST-12DST"),
        .init(field: try field("time_zone_dstoff"), before: usRule, after: "M9.5.0/2,M4.1.0/3")])
    #expect(await auckland.posts.first == ["time_zone": "NZST-12DST", "time_zone_dstoff": "M9.5.0/2,M4.1.0/3", "action_mode": "apply", "rc_service": "restart_time;restart_firewall;"])

    let guam = TimeZoneMock([stored("UTC-10DST_1", "1", usRule), lost])
    _ = try await client(guam).applySettings(section: try ntp(), changes: [
        .init(field: try field("time_zone"), before: "UTC-10DST_1", after: "UTC-10_6"),
        .init(field: try field("time_zone_dst"), before: "1", after: "0")])
    let post = try #require(await guam.posts.first)
    #expect(post["time_zone"] == "UTC-10_6"); #expect(post["time_zone_dst"] == "0"); #expect(post["time_zone_dstoff"] == nil)
}
@Test func rejectedCombinationsNeverReachTheRouter() async throws {
    let cases: [[SettingChange]] = [
        // Start and end on the same month, week and weekday.
        [.init(field: try field("time_zone_dstoff"), before: usRule, after: "M10.1.0/2,M10.1.0/3")],
        // A zone without daylight saving while time_zone_dst stays 1.
        [.init(field: try field("time_zone"), before: "UTC-10DST_1", after: "UTC-10_6")],
        // A daylight saving zone switched off.
        [.init(field: try field("time_zone_dst"), before: "1", after: "0")],
        // The page placeholder.
        [.init(field: try field("time_zone"), before: "UTC-10DST_1", after: "select")],
    ]
    for changes in cases {
        let mock = TimeZoneMock([stored("UTC-10DST_1", "1", usRule)])
        await #expect(throws: RouterError.self) { try await client(mock).applySettings(section: try ntp(), changes: changes) }
        #expect(await mock.posts.isEmpty)
    }
    // A rule change for a zone without daylight saving.
    let guam = TimeZoneMock([stored("UTC-10_6", "0", usRule)])
    await #expect(throws: RouterError.self) {
        try await client(guam).applySettings(section: try ntp(), changes: [.init(field: try field("time_zone_dstoff"), before: usRule, after: australianRule)])
    }
    #expect(await guam.posts.isEmpty)
    // Changed elsewhere since it was read.
    let moved = TimeZoneMock([stored("UTC-10DST_1", "1", australianRule)])
    await #expect(throws: RouterError.self) {
        try await client(moved).applySettings(section: try ntp(), changes: [.init(field: try field("time_zone_dstoff"), before: usRule, after: "M10.1.0/2,M4.1.0/2")])
    }
    #expect(await moved.posts.isEmpty)
}
@Test func effectiveTimeZoneIsReadFromTimeZoneX() async throws {
    let mock = TimeZoneMock([.text(#"{"time_zone_x":"UTC-10DST,M3.2.0/2,M11.1.0/2"}"#)])
    #expect(try await client(mock).readEffectiveTimeZone() == "UTC-10DST,M3.2.0/2,M11.1.0/2")
    #expect(await mock.posts.isEmpty)
}
