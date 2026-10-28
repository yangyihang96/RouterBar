import Foundation
import Testing
@testable import RouterCore

// 1.9 read-only pages: AiProtection records, 统计数值, 带宽监控, 网页浏览历史, Monitoring Settings and AiCloud 日志.
// Fixtures follow the shape of Asuswrt-Merlin 3006.102.5's data pages (a byte-order mark first, as the router sends
// them) with made-up values: documentation addresses and invented MACs.

private let bom = "\u{FEFF}"
private let macA = "AA:BB:CC:DD:EE:01", macB = "AA:BB:CC:DD:EE:02"

// MARK: AiProtection

@Test func protectionCountsAndEmptyAnswers() throws {
    let counts = try RouterParser.aiProtectionCounts(bom + #"event_count = {"mals_n":"3","vp_n":"0","cc_n":"12"}"# + "\n\n")
    #expect(counts == [.maliciousSites: 3, .intrusionPrevention: 0, .infectedDevices: 12])
    // A router with nothing recorded answers `data = '';` on every page.
    let empty = bom + "data = '';\n\n"
    #expect(try RouterParser.aiProtectionDevices(empty).isEmpty)
    #expect(try RouterParser.aiProtectionChart(empty) == nil)
    #expect(try RouterParser.aiProtectionEvents(empty, kind: .intrusionPrevention).isEmpty)
    #expect(throws: RouterError.self) { try RouterParser.aiProtectionCounts("event_count = ") }
    #expect(throws: RouterError.self) { try RouterParser.aiProtectionCounts(#"event_count = {"mals_n":"-1"}"#) }
    #expect(throws: RouterError.self) { try RouterParser.aiProtectionDevices("data = '[[\"x\"]]';") }
    #expect(throws: RouterError.self) { try RouterParser.aiProtectionDevices("nothing here") }
}

@Test func protectionDevicesRankByHits() throws {
    let devices = try RouterParser.aiProtectionDevices(bom + "data = '[[\"aa:bb:cc:dd:ee:01\",\"2\"],[\"\(macB)\",5],[\"unknown\",\"2\"]]';\n")
    #expect(devices.map(\.device) == [macB, macA, "unknown"])
    #expect(devices.map(\.hits) == [5, 2, 2])
}

@Test func protectionChartsReadThreeSeverities() throws {
    let ips = try #require(try RouterParser.aiProtectionChart(bom + "data = '[[0,1,0,0,2,0,3],[\"1\",\"0\",\"0\",\"0\",\"0\",\"0\",\"0\"],[0,0,0,0,0,0,4]]';"))
    #expect(ips.high == [0, 1, 0, 0, 2, 0, 3]); #expect(ips.medium.first == 1); #expect(ips.low.last == 4)
    // The two other pages draw only the first series; an answer with that series alone is still read.
    let single = try #require(try RouterParser.aiProtectionChart("data = '[[5,0,0,0,0,0,1]]';"))
    #expect(single.high == [5, 0, 0, 0, 0, 0, 1]); #expect(single.medium.isEmpty)
    #expect(throws: RouterError.self) { try RouterParser.aiProtectionChart("data = '[]';") }
    #expect(throws: RouterError.self) { try RouterParser.aiProtectionChart("data = '[[1,\"x\"]]';") }
}

@Test func intrusionEventsGroupLikeTheWebPage() throws {
    let rows = """
    [["2026-10-14 08:00:01","H","\(macA)","192.0.2.40","EXPLOIT Example remote code execution","2","x","1001"],
     ["2026-10-15 21:09:44","M","\(macB)","198.51.100.7","Malware Example beacon","1","x","1002"],
     ["2026-10-14 09:30:00","H","\(macB)","192.0.2.40","EXPLOIT Other signature","2","x","1001"]]
    """.replacingOccurrences(of: "\n", with: "")
    let events = try RouterParser.aiProtectionEvents(bom + "data = '\(rows)';\n", kind: .intrusionPrevention)
    #expect(events.count == 3)
    #expect(events[0].severity == "H"); #expect(events[0].direction == 2); #expect(events[0].category == "1001")
    #expect(events[0].threat == "EXPLOIT Example remote code execution")
    // Grouped by the threat's first word and the destination; each row shows its first event; newest first.
    let groups = RouterParser.aiProtectionGroups(events, kind: .intrusionPrevention)
    #expect(groups.map(\.id) == ["Malware_198.51.100.7", "EXPLOIT_192.0.2.40"])
    #expect(groups[1].first.source == macA)
    #expect(groups[1].times == ["2026-10-14 08:00:01", "2026-10-14 09:30:00"])
    // An opened row lists every event with its own source, as showDetailEvent() does.
    #expect(groups[1].events.map(\.source) == [macA, macB])
    #expect(throws: RouterError.self) { try RouterParser.aiProtectionEvents("data = '[[\"2026-10-14 08:00:01\",\"H\"]]';", kind: .intrusionPrevention) }
}

@Test func siteAndDeviceEventsGroupByDestinationAndSource() throws {
    let rows = "[[\"2026-10-15 7:05:09\",\"75\",\"\(macA)\",\"phishing.example\"],[\"2026-10-16 10:00:00\",\"92\",\"\(macB)\",\"bad.example\"],[\"2026-10-15 07:10:00\",\"75\",\"\(macA)\",\"phishing.example\"]]"
    let events = try RouterParser.aiProtectionEvents("data = '\(rows)';", kind: .maliciousSites)
    #expect(events.map(\.category) == ["75", "92", "75"])
    #expect(events.allSatisfy { $0.severity == nil && $0.threat == nil })
    let groups = RouterParser.aiProtectionGroups(events, kind: .maliciousSites)
    #expect(groups.map(\.id) == ["bad.example_\(macB)", "phishing.example_\(macA)"])
    #expect(groups[1].times.count == 2)
    // Unpadded times sort by their numbers, not as text.
    #expect(RouterParser.aiProtectionGroups([events[0], AiProtectionEvent(time: "2026-10-15 10:00:00", source: "s", destination: "d", category: "2")], kind: .maliciousSites).first?.id == "d_s")
    // Category names are the pages' own lists; only 恶意网站拦截 names "2" Illegal.
    #expect(AiProtectionKind.maliciousSites.categoryName("75") == "Phishing")
    #expect(AiProtectionKind.maliciousSites.categoryName("2") == "Illegal")
    #expect(AiProtectionKind.infectedDevices.categoryName("2") == nil)
    #expect(AiProtectionKind.infectedDevices.categoryName("91") == "C&C Server")
    #expect(AiProtectionKind.intrusionPrevention.categoryName("75") == nil)
}

// MARK: Reading through the client

private actor DataPageRouter: RouterTransport {
    var nvram: [String: String]
    let support: [String: Int]
    var pages: [String: String]
    private(set) var requests: [URLRequest] = []
    init(nvram: [String: String] = [:], support: [String: Int] = [:], pages: [String: String] = [:]) { self.nvram = nvram; self.support = support; self.pages = pages }
    func send(_ request: URLRequest) async throws -> RouterHTTPResponse {
        requests.append(request)
        guard let url = request.url, request.httpMethod == "GET" else { throw RouterError.network("Only reads are expected") }
        let name = url.lastPathComponent
        if name == "appGet.cgi" {
            let hook = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "hook" }?.value ?? ""
            if hook == "get_ui_support()" { return try Self.reply(["get_ui_support": support]) }
            var object: [String: String] = [:]
            for call in hook.split(separator: ";") {
                guard let open = call.firstIndex(of: "("), let comma = call.firstIndex(of: ",") else { continue }
                let key = String(call[call.index(after: open)..<comma]); object[key] = nvram[key] ?? ""
            }
            return try Self.reply(object)
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let key = ([name] + query.filter { $0.name != "date" }.map { "\($0.name)=\($0.value ?? "")" }).joined(separator: "&")
        guard let page = pages[key] ?? pages[name] else { return RouterHTTPResponse(data: Data(), status: 404) }
        return RouterHTTPResponse(data: Data(page.utf8), status: 200)
    }
    nonisolated func cancel() {}
    func set(_ page: String, _ content: String) { pages[page] = content }
    static func reply(_ object: Any) throws -> RouterHTTPResponse { RouterHTTPResponse(data: try JSONSerialization.data(withJSONObject: object), status: 200) }
}
private func client(_ router: DataPageRouter) throws -> RouterClient { RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: router, writes: .reference) }

@Test func protectionRecordsReadWhatThePageReads() async throws {
    let now = Date(timeIntervalSince1970: 1_760_600_000)
    let router = DataPageRouter(nvram: ["wrs_protect_enable": "0", "wrs_vp_enable": "1", "wrs_vp_t": "1760000000"], pages: [
        "getAiProtectionEvent.asp": bom + #"event_count = {"mals_n":"0","vp_n":"2","cc_n":"0"}"#,
        "getIPSEvent.asp&type=vp&event=mac": "data = '[[\"\(macA)\",\"2\"]]';",
        "getIPSChart.asp&type=vp": "data = '[[0,0,0,0,0,1,1],[0,0,0,0,0,0,0],[0,0,0,0,0,0,0]]';",
        "getIPSDetailEvent.asp&type=vp&event=all": "data = '[[\"2026-10-15 08:00:00\",\"H\",\"\(macA)\",\"192.0.2.9\",\"EXPLOIT Example\",\"2\"]]';"
    ])
    let records = try await client(router).aiProtectionRecords(.intrusionPrevention, now: now)
    #expect(records.blocked == 2)
    #expect(records.masterEnabled == false && records.featureEnabled && !records.isOn)
    #expect(records.since == Date(timeIntervalSince1970: 1_760_000_000))
    #expect(records.devices == [AiProtectionDeviceHits(device: macA, hits: 2)])
    #expect(records.chart?.high.last == 1); #expect(records.chartEnd == now)
    #expect(records.groups.count == 1)
    let requests = await router.requests
    #expect(requests.allSatisfy { $0.httpMethod == "GET" && $0.httpBody == nil })
    let chart = try #require(requests.first { $0.url?.lastPathComponent == "getIPSChart.asp" }?.url)
    #expect(URLComponents(url: chart, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "date", value: "1760600000")) == true)
    // The two other pages chart with getNonIPSChart.asp, and a counter that never started has no "since".
    await router.set("getNonIPSChart.asp&type=cc", "data = '';")
    await router.set("getIPSEvent.asp&type=cc&event=mac", "data = '';")
    await router.set("getIPSDetailEvent.asp&type=cc&event=all", "data = '';")
    let cc = try await client(router).aiProtectionRecords(.infectedDevices, now: now)
    #expect(cc.since == nil && cc.chart == nil && cc.groups.isEmpty && cc.blocked == 0)
}

@Test func dataPagesTakeOnlyTheWebsParameters() async throws {
    let router = DataPageRouter(pages: ["getIPSEvent.asp": "data = '';"])
    let client = try client(router)
    await #expect(throws: RouterError.self) { try await client.readDataPage(.protectionEvents, [("action", "del")]) }
    await #expect(throws: RouterError.self) { try await client.readDataPage(.protectionEvents, [("type", "vp&event=all")]) }
    await #expect(throws: RouterError.self) { try await client.readDataPage(.protectionEvents, [("type", "")]) }
    await #expect(throws: RouterError.self) { try await client.webHistory(page: 0) }
    await #expect(throws: RouterError.self) { try await client.trafficStatistics(apps: "all", period: .daily, dnsBased: true) }
    #expect(await router.requests.isEmpty)
    _ = try await client.readDataPage(.protectionEvents, [("type", "vp"), ("event", "mac")])
    #expect(await router.requests.count == 1)
    // None of the pages the white list, log clearing or event deletion use is reachable; the others are WPS's status and
    // the VLAN page's port status (not the cable test next to it).
    let paths = Set(RouterDataPage.allCases.map(\.rawValue))
    #expect(paths.allSatisfy { ($0.hasPrefix("get") && $0.hasSuffix(".asp")) || ["WPS_info.xml", "get_port_status.cgi"].contains($0) })
}

// MARK: 统计数值

@Test func statisticsReadDevicesAppsAndTimeline() async throws {
    let clients = "var array_statistics = new Array();\narray_statistics = [[\"\(macA.lowercased())\", 100, 900], [\"\(macB)\", \"5000\", \"1\"]];\n"
    let apps = "array_statistics = [[\"Video streaming\", 10, 20], [\"Web\", 300, 400]];"
    let hours = "array_statistics = [" + Array(repeating: "[0, 0]", count: 23).joined(separator: ", ") + ", [1024, 2048]];"
    let router = DataPageRouter(support: ["dns_dpi": 3], pages: [
        "getAppTraffic_Dns.asp&client=all&mode=detail&dura=24": bom + clients,
        "getWanTraffic_Dns.asp&client=all&mode=detail&dura=24": bom + apps,
        "getWanTraffic_Dns.asp&client=all&mode=hour&dura=24": bom + hours
    ])
    let stats = try await client(router).trafficStatistics(.daily, dnsBased: true)
    #expect(stats.clients.map(\.id) == [macB, macA])
    #expect(stats.clients[1].volume == TrafficVolume(upload: 100, download: 900))
    #expect(stats.apps.map(\.id) == ["Web", "Video streaming"])
    #expect(stats.timeline.count == 24); #expect(stats.timeline.last == TrafficVolume(upload: 1024, download: 2048))
    #expect(await router.requests.allSatisfy { $0.url?.lastPathComponent.contains("_Dns") == true })
    // Without dns_dpi the web reads the Trend Micro engine's pages instead.
    let plain = DataPageRouter(pages: ["getAppTraffic.asp": "array_statistics = [];", "getWanTraffic.asp&client=all&mode=detail&dura=7": "array_statistics = [];",
                                       "getWanTraffic.asp&client=all&mode=day&dura=7": "array_statistics = [[0, 0], [0, 0], [0, 0], [0, 0], [0, 0], [0, 0], [0, 0]];"])
    let weekly = try await client(plain).trafficStatistics(.weekly, dnsBased: false)
    #expect(weekly.clients.isEmpty && weekly.timeline.count == 7)
    let items = await plain.requests.compactMap { $0.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } }
    #expect(items.allSatisfy { $0.contains(URLQueryItem(name: "dura", value: "7")) })
    #expect(items.contains { $0.contains(URLQueryItem(name: "mode", value: "day")) })
    #expect(throws: RouterError.self) { try RouterParser.trafficStatisticsItems("array_statistics = [[\"x\", -1, 2]];") }
    #expect(throws: RouterError.self) { try RouterParser.trafficTimeline("array_statistics = new Array();") }
    // Counts beyond what the page's numbers hold exactly are refused, so no sum can overflow.
    #expect(throws: RouterError.self) { try RouterParser.trafficStatisticsItems("array_statistics = [[\"x\", \"18446744073709551615\", \"1\"]];") }
    #expect(try RouterParser.trafficTimeline("array_statistics = [[9007199254740992, 0]];").first?.upload == 9_007_199_254_740_992)
}

@Test func timelineAlwaysHasThePagesPoints() async throws {
    // draw_flow(): point i is entry i, oldest first; missing entries are zero and extra ones are not drawn.
    let router = DataPageRouter(pages: ["getAppTraffic.asp": "array_statistics = [];", "getWanTraffic.asp&client=all&mode=detail&dura=31": "array_statistics = [];",
                                        "getWanTraffic.asp&client=all&mode=day&dura=31": "array_statistics = [[100, 0], [0, 200]];",
                                        "getWanTraffic.asp&client=all&mode=detail&dura=24": "array_statistics = [];",
                                        "getWanTraffic.asp&client=all&mode=hour&dura=24": "array_statistics = [" + (1...26).map { "[\($0), 0]" }.joined(separator: ", ") + "];"])
    let monthly = try await client(router).trafficStatistics(.monthly, dnsBased: false)
    #expect(monthly.timeline.count == 31)
    #expect(monthly.timeline[0] == TrafficVolume(upload: 100, download: 0)); #expect(monthly.timeline[1] == TrafficVolume(upload: 0, download: 200))
    #expect(monthly.timeline.dropFirst(2).allSatisfy { $0 == TrafficVolume(upload: 0, download: 0) })
    let daily = try await client(router).trafficStatistics(.daily, dnsBased: false)
    #expect(daily.timeline.count == 24); #expect(daily.timeline.last?.upload == 24)
}

@Test func switchesFollowTheEngineTheWebUses() async throws {
    let values = ["dns_dpi_trf_analysis": "0", "bwdpi_db_enable": "1", "dns_dpi_apps_analysis": "1", "apps_analysis": "0", "bwdpi_wh_enable": "0", "TM_EULA": "0"]
    let dns = TrafficAnalyzerSwitches(dnsBased: true, values: values)
    #expect(!dns.statistics && dns.appAnalysis && !dns.webHistory && !dns.trendMicroAgreed)
    let engine = TrafficAnalyzerSwitches(dnsBased: false, values: values)
    #expect(engine.statistics && !engine.appAnalysis)
    let router = DataPageRouter(nvram: values, support: ["dns_dpi": 3, "bwdpi": 2])
    #expect(try await client(router).trafficAnalyzerSwitches() == dns)
    #expect(try await client(DataPageRouter(nvram: values, support: ["dns_dpi": 0])).trafficAnalyzerSwitches() == engine)
}

// MARK: 带宽监控

@Test func bandwidthMonitorRatesDevicesAndTheRouter() async throws {
    func page(_ a: (UInt64, UInt64), _ b: (UInt64, UInt64), router: (UInt64, UInt64)) -> String {
        bom + "var array_traffic = new Array();\nvar router_traffic = new Array();\narray_traffic = [[\"\(macA)\", \"\(a.0)\", \"\(a.1)\"], [\"\(macB)\", \"\(b.0)\", \"\(b.1)\"]];\nrouter_traffic = [\"\(router.0)\", \"\(router.1)\"];\n"
    }
    let first = page((1000, 2000), (50, 60), router: (10_000, 20_000)), second = page((4000, 14_000), (50, 60), router: (40_000, 140_000))
    // The page polls getTraffic_Dns.asp when the router uses DNS DPI and getTraffic.asp otherwise.
    let router = DataPageRouter(pages: ["getTraffic_Dns.asp": first, "getTraffic.asp": second])
    let dns = try await client(router).bandwidthTraffic(dnsBased: true)
    #expect(dns.source == "getTraffic_Dns.asp"); #expect(dns.counters[macA]?.upload == 1000); #expect(dns.router?.upload == 10_000)
    #expect(try await client(router).bandwidthTraffic(dnsBased: false).counters[macA]?.upload == 4000)
    #expect(await router.requests.compactMap { $0.url?.lastPathComponent } == ["getTraffic_Dns.asp", "getTraffic.asp"])
    #expect(DeviceTrafficParser.routerTotal(first) == DeviceTrafficCounters(upload: 10_000, download: 20_000))
    #expect(DeviceTrafficParser.routerTotal("router_traffic = new Array();") == nil)
    func reading(_ source: String, at seconds: TimeInterval) throws -> DeviceTrafficReading {
        DeviceTrafficReading(source: "getTraffic.asp", counters: try DeviceTrafficParser.parse(source), router: DeviceTrafficParser.routerTotal(source),
                             date: Date(timeIntervalSince1970: 1_760_600_000 + seconds), monotonic: 100 + seconds)
    }
    var monitor = BandwidthMonitor()
    #expect(monitor.consume(try reading(first, at: 0)) == nil)
    // Readings closer than the router's counter step are skipped, not turned into a spike.
    #expect(monitor.consume(try reading(second, at: 1)) == nil)
    let sample = try #require(monitor.consume(try reading(second, at: 3)))
    #expect(sample.devices.map(\.mac) == [macA, macB])
    #expect(sample.devices[0].upload == 1000 && sample.devices[0].download == 4000)
    #expect(sample.router?.upload == 10_000 && sample.router?.download == 40_000)
    // A router counter that went back gives no rate for that interval, as on the web page.
    let wrapped = try #require(monitor.consume(try reading(page((4000, 14_000), (50, 60), router: (5, 140_100)), at: 6)))
    #expect(wrapped.router == nil)
}

// MARK: 网页浏览历史, Monitoring Settings, AiCloud 日志

@Test func webHistoryDropsRepeatsLikeThePage() async throws {
    let source = bom + "var array_temp = new Array();\narray_temp = [[\"\(macA)\", \"1760600000\", \"www.example.com\"], [\"\(macA)\", 1760600000, \"WWW.EXAMPLE.COM\"], [\"\(macB)\", \"1760600060\", \"example.org\"]];\n"
    let page = try RouterParser.webHistory(source)
    #expect(page.entries.map(\.host) == ["www.example.com", "example.org"])
    #expect(page.entries[1].date == Date(timeIntervalSince1970: 1_760_600_060))
    #expect(page.received == 3 && !page.hasNextPage)
    #expect(try RouterParser.webHistory("array_temp = [];").entries.isEmpty)
    #expect(throws: RouterError.self) { try RouterParser.webHistory("array_temp = [[\"\(macA)\", \"soon\", \"x\"]];") }
    // A full page of 50 offers the next one even when a repeat leaves 49 to show (getWebHistory() 200–213).
    let full = "array_temp = [" + (0..<49).map { "[\"\(macA)\", \"\(1_760_600_000 + $0)\", \"site\($0).example\"]" }.joined(separator: ", ") + ", [\"\(macA)\", \"1760600000\", \"SITE0.EXAMPLE\"]];"
    let fifty = try RouterParser.webHistory(full)
    #expect(fifty.entries.count == 49 && fifty.received == 50 && fifty.hasNextPage)
    let router = DataPageRouter(pages: ["getWebHistory.asp&client=all&page=2": source])
    #expect(try await client(router).webHistory(page: 2).entries.count == 2)
}

@Test func monitoringSettingsShowWhereHistoryIsKept() async throws {
    #expect(TrafficMonitorSettings(values: ["rstats_path": "", "rstats_stime": "1", "rstats_new": "0", "rstats_offset": "1"]).location == .ram)
    let nvram = TrafficMonitorSettings(values: ["rstats_path": "*nvram", "rstats_stime": "24", "rstats_new": "1", "rstats_offset": "15"])
    #expect(nvram.location == .nvram && nvram.saveHours == 24 && nvram.resetFiles && nvram.monthStartDay == 15)
    let router = DataPageRouter(nvram: ["rstats_path": "/mnt/usb/rstats/", "rstats_stime": "6", "rstats_new": "0", "rstats_offset": "3"])
    let custom = try await client(router).trafficMonitorSettings()
    #expect(custom.location == .custom("/mnt/usb/rstats/") && custom.saveHours == 6 && !custom.resetFiles && custom.monthStartDay == 3)
}

@Test func aiCloudLogIsTheReadOnlyBox() async throws {
    let page = "<td><textarea cols=\"63\" rows=\"27\" wrap=\"off\" readonly=\"readonly\" id=\"textarea\" class=\"content_bg\">Oct 16 09:00:00 lighttpd: 192.0.2.5 GET /file &amp; more &lt;ok&gt;\n</textarea></td>"
    #expect(try RouterParser.aiCloudLog(page) == "Oct 16 09:00:00 lighttpd: 192.0.2.5 GET /file & more <ok>\n")
    #expect(try RouterParser.aiCloudLog("<textarea readonly id=\"textarea\"></textarea>") == "")
    #expect(throws: RouterError.self) { try RouterParser.aiCloudLog("<html></html>") }
    let router = DataPageRouter(pages: ["cloud_syslog.asp": page])
    #expect(try await client(router).aiCloudLog().contains("lighttpd"))
}

// MARK: Navigation

@Test func readOnlyPagesHaveNativeHomes() {
    let expected: [(NativeFeature, String)] = [
        (.aiProtection(.maliciousSites), "AiProtection_MaliciousSitesBlocking.asp"), (.aiProtection(.intrusionPrevention), "AiProtection_IntrusionPreventionSystem.asp"),
        (.aiProtection(.infectedDevices), "AiProtection_InfectedDevicePreventBlock.asp"), (.bandwidthMonitor, "AdaptiveQoS_Bandwidth_Monitor.asp"),
        (.webHistory, "AdaptiveQoS_WebHistory.asp"), (.trafficMonitorSettings, "Main_TrafficMonitor_settings.asp"),
        (.trafficStatistics, "TrafficAnalyzer_Statistic.asp"), (.aiCloudLog, "cloud_syslog.asp")
    ]
    for (feature, page) in expected { #expect(WebMenuCatalog.location(of: feature)?.page == page, "\(page)") }
    // 1.12: the pages that act on the network or record consent are native too; their actions ask first.
    let acting: [(NativeFeature, String)] = [(.internetSpeed, "AdaptiveQoS_InternetSpeed.asp"), (.wakeOnLAN, "Main_WOL_Content.asp"),
                                            (.siteSurvey, "Advanced_Wireless_Survey.asp"), (.privacy, "Advanced_Privacy.asp"),
                                            (.uuAccelerator, "UUAccelerator.asp"), (.alexa, "Advanced_Smart_Home_Alexa.asp"),
                                            (.printerServer, "PrinterServer.asp")]
    for (feature, page) in acting { #expect(WebMenuCatalog.location(of: feature)?.page == page, "\(page)") }
    #expect(WebMenuCatalog.location(ofSection: "printer")?.page == "PrinterServer.asp")
}
