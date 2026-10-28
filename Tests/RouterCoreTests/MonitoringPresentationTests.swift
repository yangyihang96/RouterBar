import Foundation
import Testing
@testable import RouterCore

private let presentationDate = Date(timeIntervalSince1970: 2_000_000)
private let presentationMAC = "AA:BB:CC:DD:EE:01"
private func presentationDevice(_ suffix: String, name: String = "设备", band: Int = 2, rssi: Int? = -80, online: Bool = true) throws -> RouterDevice {
    var fields: [String: String] = ["name": name, "isWL": String(band), "isOnline": online ? "1" : "0"]
    if let rssi { fields["rssi"] = String(rssi) }
    let data = try JSONSerialization.data(withJSONObject: ["get_clientlist": ["AA:BB:CC:DD:EE:" + suffix: fields]])
    return try #require(RouterParser.clients(data).first)
}

@Test func historyFilteringPreservesBaselineAndAppliesWatchSearchAndTimeTogether() throws {
    let other = "AA:BB:CC:DD:EE:02"
    var tracker = PresenceTracker(archive: PresenceArchive(routerKey: "test"))
    tracker.observe([try presentationDevice("01", name: "新名称"), try presentationDevice("02")], at: presentationDate, monotonic: 100, uptime: 10)
    tracker.setWatched(true, mac: presentationMAC)
    var archive = tracker.archive
    let old = PresenceEvent(mac: presentationMAC, name: "旧名称", kind: .offline, at: presentationDate.addingTimeInterval(-86400))
    let changed = PresenceEvent(mac: presentationMAC, name: "旧名称", kind: .online, at: presentationDate.addingTimeInterval(10))
    let observation = PresenceEvent(mac: presentationMAC, name: "新名称", kind: .observedOnline, at: presentationDate.addingTimeInterval(20))
    archive.events.append(contentsOf: [old, changed, observation, .init(mac: other, name: "设备", kind: .offline, at: presentationDate.addingTimeInterval(30))])
    let original = archive.events
    let found = PresenceHistoryQuery.events(archive.events, records: archive.records, watchedOnly: true, search: "新名称", since: presentationDate)
    #expect(found.map(\.id) == [changed.id])
    #expect(PresenceHistoryQuery.events(archive.events, records: archive.records, search: "旧名称", since: presentationDate).map(\.id) == [changed.id])
    #expect(PresenceHistoryQuery.events(archive.events, records: archive.records, mac: presentationMAC, filter: .observations).map(\.id) == [observation.id])
    #expect(PresenceHistoryQuery.events(archive.events, records: archive.records, filter: .all).count == original.count)
    #expect(archive.events == original)
}

@Test func historySearchSupportsAddressesAndEmptyWatchScope() throws {
    var tracker = PresenceTracker(archive: PresenceArchive(routerKey: "test"))
    tracker.observe([try presentationDevice("01")], at: presentationDate, monotonic: 100, uptime: 10)
    var records = tracker.archive.records
    records[presentationMAC]?.ip = "192.168.50.23"
    #expect(PresenceHistoryQuery.events(tracker.archive.events, records: records, watchedOnly: true, filter: .all).isEmpty)
    #expect(PresenceHistoryQuery.events(tracker.archive.events, records: records, search: "  192.168.50.23  ", filter: .discovery).count == 1)
    #expect(PresenceHistoryQuery.events(tracker.archive.events, records: records, search: "aa:bb:cc", filter: .all).count == 1)
}

private func windowReading(_ bytes: UInt64, _ time: Double, source: String = "a", missing: Bool = false, wallOffset: Double = 0) -> DeviceTrafficReading {
    .init(source: source, counters: missing ? [:] : [presentationMAC: .init(upload: bytes, download: bytes * 2)],
        date: presentationDate.addingTimeInterval(time + wallOffset), monotonic: time)
}

@Test func trafficChartNeverBridgesMissingCountersSourceChangesOrResets() {
    for interruption in ["missing", "source", "reset", "gap", "offline", "failure"] {
        var window = DeviceTrafficWindow()
        window.consume(windowReading(100, 10), online: [presentationMAC])
        window.consume(windowReading(200, 20), online: [presentationMAC])
        window.consume(windowReading(300, 30), online: [presentationMAC])
        #expect(window.history[presentationMAC]?.count == 2)
        switch interruption {
        case "missing": window.consume(windowReading(400, 40, missing: true), online: [presentationMAC])
        case "source": window.consume(windowReading(400, 40, source: "b"), online: [presentationMAC])
        case "reset": window.consume(windowReading(1, 40), online: [presentationMAC])
        case "gap": window.consume(windowReading(400, 500), online: [presentationMAC])
        case "offline": window.consume(windowReading(400, 40), online: [])
        default: window.reset()
        }
        #expect(window.rates.isEmpty && window.history.isEmpty)
    }
}

@Test func trafficChartBoundsHistoryAndRestartsAfterClockMovesBack() {
    var window = DeviceTrafficWindow(limit: 3)
    for t in 1...7 { window.consume(windowReading(UInt64(t) * 100, Double(t) * 10), online: [presentationMAC]) }
    #expect(window.history[presentationMAC]?.count == 3)
    window.consume(windowReading(800, 80, wallOffset: -60), online: [presentationMAC])
    #expect(window.history[presentationMAC]?.count == 1)
    #expect(window.rates[presentationMAC]?.upload == 10)
    window.consume(windowReading(800, 90, wallOffset: -60), online: [presentationMAC])
    #expect(window.rates[presentationMAC]?.upload == 0)
}

@Test func trafficRankingKeepsUnknownAfterMeasuredZeroAndUsesStableIdentityTies() throws {
    let a = try presentationDevice("01", name: "同名"), b = try presentationDevice("02", name: "同名"), c = try presentationDevice("03", name: "未知")
    let rates = [a.mac: DeviceTrafficRate(mac: a.mac, upload: 100, download: 0, date: presentationDate),
                 b.mac: DeviceTrafficRate(mac: b.mac, upload: 0, download: 100, date: presentationDate)]
    #expect(DeviceSortOrder.download.sorted([c, a, b], rates: rates).map(\.mac) == [b.mac, a.mac, c.mac])
    #expect(DeviceSortOrder.upload.sorted([c, b, a], rates: rates).map(\.mac) == [a.mac, b.mac, c.mac])
    #expect(DeviceSortOrder.name.sorted([b, a], rates: rates).map(\.mac) == [a.mac, b.mac])
}

@Test func weakSignalFindingsExcludeOfflineWiredUnknownAndShowWeakestFirst() throws {
    let weakest = try presentationDevice("01", rssi: -90), weak = try presentationDevice("02", rssi: -76)
    let wired = try presentationDevice("03", band: 0, rssi: -99), offline = try presentationDevice("04", rssi: -95, online: false)
    let boundary = try presentationDevice("05", rssi: -75), unknown = try presentationDevice("06", rssi: nil)
    let all = [offline, boundary, unknown, weak, wired, weakest]
    #expect(HealthDeviceAnalysis.weakSignalDevices(all).map(\.mac) == [weakest.mac, weak.mac])
    #expect(DeviceSortOrder.weakSignal.sorted(all, rates: [:]).prefix(2).map(\.mac) == [weakest.mac, weak.mac])
}

@Test func incompleteOrCanceledHealthChecksNeverGetSuccessPresentation() throws {
    var report = NetworkHealthReport()
    report.checks = [.init(id: "mac", title: "Mac", severity: .good, summary: "available")]
    #expect(report.severity == .unknown)
    report.completedAt = .now; #expect(report.severity == .good)
    report.canceled = true; #expect(report.severity == .unknown)
    report.canceled = false
    report.checks.append(.init(id: "dns", title: "DNS", severity: .unknown, summary: "unknown"))
    #expect(report.severity == .unknown)
    let target = HealthRelatedDevice(mac: presentationMAC, name: "设备", kind: .computer, detail: "−80 dBm")
    report.checks.append(.init(id: "wifi", title: "Wi-Fi", severity: .attention, summary: "weak", relatedDevices: [target]))
    #expect(report.severity == .attention)
    let saved = try JSONDecoder().decode(NetworkHealthReport.self, from: JSONEncoder().encode(report))
    #expect(saved.checks.last?.relatedDevices?.first?.mac == presentationMAC)
}
