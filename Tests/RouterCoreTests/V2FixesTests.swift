import Foundation
import Testing
@testable import RouterCore

// Fixes from the 2.0.0 review of the core (scratchpad review-2.0.0-core).

@Test func routerNumbersPastIntRangeNeverStopTheApp() throws {
    #expect(Double.infinity.truncatedInt == nil)
    #expect(Double.nan.truncatedInt == nil)
    #expect(9.3e18.truncatedInt == nil)
    #expect(42.9.truncatedInt == 42)
    #expect(1e300.clampedInt == Int.max)
    #expect((-1e300).clampedInt == Int.min)
    #expect(Double.nan.clampedInt == 0)
    let sysinfo = """
    conn_stats_arr = ["9223372036854775808","365"];
    wlc_0_arr = ["0", "1e400", "6"];
    mem_stats_arr = ["1999.96", "58.20", "45.30", "1200.53", "0.00", "0.00", "106237", "41.62", "629.73", "1290.25"];
    cpu_stats_arr = ["1.35", "1.35", "1.31"];
    """
    let status = try RouterParser.systemStatus(sysinfo: sysinfo, temperatures: #"curr_cpuTemp = "1e400";"#)
    #expect(status.connections == nil)
    #expect(status.wirelessClients[0] == nil)
    var hot = RouterSystemStatus()
    hot.cpuTemperature = .infinity
    _ = HealthSystemAnalysis.temperature(status: hot, radioTitles: [:])
}

@Test func anEmptiedNumberIsJudgedAndSentAsTheWebDoes() throws {
    let port = SettingField(key: "http_lanport", label: "HTTP 端口", kind: "integer", minimum: 1, maximum: 65535)
    #expect(throws: RouterError.self) { try port.validate("") }
    let optional = SettingField(key: "x", label: "X", kind: "integer", minimum: 0, maximum: 10)
    try optional.validate("")
    let zero = SettingField(key: "y", label: "Y", kind: "integer", minimum: 10, maximum: 99, allowsZero: true)
    try zero.validate("")
    #expect(port.submitted("") == "0")
    #expect(port.submitted("0080") == "80")
    #expect(port.submitted("-05") == "-5")
    #expect(port.submitted("abc") == "abc")
    #expect(SettingField(key: "z", label: "Z", kind: "text").submitted("007") == "007")
}

@Test func aLANChangeNeverLeavesAPoolOfOnlyTheRouter() throws {
    let context = ["sw_mode": "1", "lan_ipaddr": "192.168.50.1", "lan_netmask": "255.255.255.0", "http_enable": "0"]
    // A /30 with the router last: network + 2 is the router itself.
    #expect(throws: RouterError.self) {
        try LANAddressRules.dependentFields(changes: ["lan_ipaddr": "10.0.0.2", "lan_netmask": "255.255.255.252"], context: context, support: [:])
    }
    // With the router first the pool is the one other address, as the web computes it.
    let fields = try LANAddressRules.dependentFields(changes: ["lan_ipaddr": "10.0.0.1", "lan_netmask": "255.255.255.252"], context: context, support: [:])
    #expect(fields["dhcp_start"] == "10.0.0.2")
    #expect(fields["dhcp_end"] == "10.0.0.2")
    // Elsewhere the pool is network + 2 to broadcast − 1 wherever the router sits (calculatorIPPoolRange).
    let high = try LANAddressRules.dependentFields(changes: ["lan_ipaddr": "192.168.7.254"], context: context, support: [:])
    #expect(high["dhcp_start"] == "192.168.7.2")
    #expect(high["dhcp_end"] == "192.168.7.254")
}

@Test func historyFollowsTheRouterAcrossAddressesAndKeepsTheOldFile() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RouterBarTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = MonitoringFileStore(directory: folder)
    let old = "http://192.168.50.1|AA:BB:CC:DD:EE:01"
    var archive = PresenceArchive(routerKey: old)
    archive.events = [PresenceEvent(mac: "11:22:33:44:55:66", name: "Phone", kind: .firstSeen, at: Date(timeIntervalSince1970: 1_000))]
    try await store.save(archive)
    let key = MonitoringFileStore.routerKey(endpoint: "https://192.168.50.1:8443", hardwareAddress: "aa:bb:cc:dd:ee:01", model: "RT-BE88U")
    #expect(key == "router|AA:BB:CC:DD:EE:01")
    #expect(try await store.adopt(old, as: key))
    #expect(try await store.load(routerKey: key).events.count == 1)
    #expect(try await store.load(routerKey: old).events.count == 1)
    // Once adopted, the new history is never replaced from the old one again.
    #expect(try await !store.adopt(old, as: key))
    #expect(MonitoringFileStore.routerKey(endpoint: "http://192.168.50.1", hardwareAddress: nil, model: "RT-BE88U") == "http://192.168.50.1|RT-BE88U")
}

@Test func aDeviceThatLeftDuringACollapsedListIsTimedFromItsOwnAbsence() throws {
    var tracker = PresenceTracker(archive: PresenceArchive(routerKey: "test"), offlineDelay: 180, listDropDelay: 600)
    func device(_ n: Int) throws -> RouterDevice {
        let mac = String(format: "AA:BB:CC:DD:EE:%02X", n)
        let json: [String: Any] = ["get_clientlist": [mac: ["name": "D\(n)", "isOnline": "1", "isWL": "0", "ip": "192.168.50.\(n + 10)"]]]
        return try #require(RouterParser.clients(JSONSerialization.data(withJSONObject: json)).first)
    }
    let start = Date(timeIntervalSince1970: 1_000_000)
    let all = try (1...6).map(device)
    _ = tracker.observe(all, at: start, monotonic: 0, uptime: 100)
    // The list collapses to one device for the whole hold; that device leaves only near its end.
    var t: TimeInterval = 0
    while t < 590 { t += 10; _ = tracker.observe([all[0]], at: start.addingTimeInterval(t), monotonic: t, uptime: 100 + t) }
    t += 10; _ = tracker.observe([], at: start.addingTimeInterval(t), monotonic: t, uptime: 100 + t)
    t += 10; _ = tracker.observe([], at: start.addingTimeInterval(t), monotonic: t, uptime: 100 + t)
    // The others have been away since the collapse began and are confirmed; the last one has been away 20 s.
    #expect(tracker.archive.records[all[1].mac]?.state == .offline)
    #expect(tracker.archive.records[all[0].mac]?.state == .online)
    #expect(tracker.pendingOffline[all[0].mac] != nil)
}

@Test func settingsArriveInFewRequestsWithinTheRequestLine() {
    let keys = (1...5).flatMap { unit in (1...27).map { "vpn_client\(unit)_field\($0)" } }
    let batches = RouterClient.settingBatches(keys)
    #expect(batches.flatMap { $0 } == keys)
    #expect(batches.count <= 7)
    // Every request line stays far below httpd's 10000-byte buffer.
    for batch in batches {
        let hook = batch.map { "nvram_char_to_ascii(\($0),\($0))" }.joined(separator: "%3B")
        #expect(hook.utf8.count < 3200)
    }
    #expect(RouterClient.settingBatches([]).isEmpty)
    #expect(RouterClient.settingBatches(["a"]) == [["a"]])
}
