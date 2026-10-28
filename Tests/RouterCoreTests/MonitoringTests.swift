import Foundation
import Testing
@testable import RouterCore

private let fixtureMAC = "AA:BB:CC:DD:EE:01"
private let fixtureDate = Date(timeIntervalSince1970: 1_000_000)
private func fixtureDevice(online: Bool = true, name: String = "NAS", mac: String = fixtureMAC) throws -> RouterDevice {
    let json: [String: Any] = ["get_clientlist": [mac: ["name": name, "isOnline": online ? "1" : "0", "isWL": "0", "ip": "192.168.50.2"]]]
    return try #require(RouterParser.clients(JSONSerialization.data(withJSONObject: json)).first)
}
private func observe(_ tracker: inout PresenceTracker, _ devices: [RouterDevice]?, _ seconds: Double, uptime: Double? = nil, wallOffset: Double = 0) -> [PresenceEvent] {
    tracker.observe(devices, at: fixtureDate.addingTimeInterval(seconds + wallOffset), monotonic: seconds + 100, uptime: uptime)
}

@Test func presenceConfirmsSustainedAbsenceAndOnlyAlertsWatchedDevices() throws {
    var tracker = PresenceTracker(archive: PresenceArchive(routerKey: "router"))
    let device = try fixtureDevice()
    #expect(observe(&tracker, [device], 0).isEmpty)
    tracker.setWatched(true, mac: fixtureMAC)
    #expect(observe(&tracker, [], 10).isEmpty)
    #expect(tracker.pendingOffline[fixtureMAC] != nil)
    #expect(observe(&tracker, [], 70).isEmpty)
    #expect(observe(&tracker, [], 130).isEmpty)
    let alerts = observe(&tracker, [], 190)
    #expect(alerts.count == 1 && alerts.first?.kind == .offline)
    #expect(tracker.archive.records[fixtureMAC]?.state == .offline)
    #expect(observe(&tracker, [], 200).isEmpty)
    #expect(observe(&tracker, [device], 210).isEmpty)
    #expect(tracker.archive.events.last?.kind == .online)
    #expect(tracker.archive.events.first?.kind == .firstSeen)
}

@Test func unobservedIntervalsNeverFabricateAnOutage() throws {
    let device = try fixtureDevice()
    for interruption in ["read-failure", "sleep", "reboot", "restart"] {
        var tracker = PresenceTracker(archive: PresenceArchive(routerKey: "router"))
        _ = observe(&tracker, [device], 0, uptime: 1000)
        tracker.setWatched(true, mac: fixtureMAC)
        _ = observe(&tracker, [], 10, uptime: 1010)
        switch interruption {
        case "read-failure": _ = observe(&tracker, nil, 20)
        case "restart": tracker = PresenceTracker(archive: tracker.archive)
        case "reboot": break
        default: break
        }
        let resume: Double = interruption == "sleep" ? 1000 : 70
        let uptime: Double = interruption == "reboot" ? 2 : 1070
        // Absence before the gap does not count: the confirmation starts again at the first observation after it.
        for offset in [0.0, 60, 120, 170] { #expect(observe(&tracker, [], resume + offset, uptime: uptime + offset).isEmpty) }
        #expect(tracker.archive.events.map(\.kind) == [.firstSeen])
        #expect(tracker.archive.records[fixtureMAC]?.state == .online)
        let alerts = observe(&tracker, [], resume + 180, uptime: uptime + 180)
        #expect(alerts.count == 1)
        let offline = try #require(tracker.archive.events.last)
        #expect(offline.kind == .offline && offline.afterPause == true)
        #expect(offline.absentSince == fixtureDate.addingTimeInterval(resume))
    }
}

@Test func resumingRecordsOnlyDevicesWhoseStateChanged() throws {
    let stays = try fixtureDevice(mac: "AA:BB:CC:DD:EE:01"), returns = try fixtureDevice(mac: "AA:BB:CC:DD:EE:02")
    let leaves = try fixtureDevice(mac: "AA:BB:CC:DD:EE:03")
    var tracker = PresenceTracker(archive: PresenceArchive(routerKey: "router"))
    _ = observe(&tracker, [stays, returns, leaves], 0)
    for t in stride(from: 10.0, through: 190, by: 60) { _ = observe(&tracker, [stays, leaves], t) }
    #expect(tracker.archive.records[returns.mac]?.state == .offline)
    let before = tracker.archive.events.count
    for restart in 1...5 {
        tracker = PresenceTracker(archive: tracker.archive)
        _ = observe(&tracker, [stays, leaves], 200 + Double(restart) * 1000)
    }
    #expect(tracker.archive.events.count == before)
    tracker.pause()
    _ = observe(&tracker, [stays, returns], 9000)
    let back = try #require(tracker.archive.events.last)
    #expect(back.mac == returns.mac && back.kind == .online && back.afterPause == true)
    #expect(tracker.archive.events.count == before + 1)
    #expect(tracker.pendingOffline[leaves.mac] != nil)
    #expect(!tracker.archive.events.contains { $0.kind == .observedOnline || $0.kind == .observedOffline })
}

@Test func collapsedClientListHoldsOfflineJudgementUntilItPersists() throws {
    let devices = try (1...6).map { try fixtureDevice(mac: String(format: "AA:BB:CC:DD:EE:%02X", $0)) }
    for outcome in ["recovers", "persists", "empty"] {
        var tracker = PresenceTracker(archive: PresenceArchive(routerKey: "router"))
        _ = observe(&tracker, devices, 0)
        for mac in devices.map(\.mac) { tracker.setWatched(true, mac: mac) }
        let partial = outcome == "empty" ? [] : [devices[0]]
        for t in stride(from: 10.0, through: 590, by: 60) {
            #expect(observe(&tracker, partial, t).isEmpty)
            #expect(tracker.heldAbsent.count == 6 - partial.count)
        }
        // Each absent device is dated from its own first absence while the list is held; nothing is judged yet.
        #expect(tracker.pendingOffline.count == 6 - partial.count)
        #expect(tracker.pendingOffline.values.allSatisfy { $0 == fixtureDate.addingTimeInterval(10) })
        #expect(tracker.archive.events.allSatisfy { $0.kind == .firstSeen })
        if outcome == "recovers" {
            #expect(observe(&tracker, devices, 600).isEmpty)
            #expect(tracker.heldAbsent.isEmpty && tracker.pendingOffline.isEmpty && tracker.archive.events.allSatisfy { $0.kind == .firstSeen })
        } else {
            // A collapse that lasts is real (a mesh node or band went down) and dates from its start.
            let alerts = observe(&tracker, partial, 610)
            #expect(alerts.count == 6 - partial.count)
            #expect(alerts.allSatisfy { $0.absentSince == fixtureDate.addingTimeInterval(10) && $0.afterPause == nil })
        }
    }
}

@Test func gradualDeparturesAreNotMistakenForACollapsedList() throws {
    let devices = try (1...6).map { try fixtureDevice(mac: String(format: "AA:BB:CC:DD:EE:%02X", $0)) }
    var tracker = PresenceTracker(archive: PresenceArchive(routerKey: "router"))
    _ = observe(&tracker, devices, 0)
    _ = observe(&tracker, Array(devices.prefix(4)), 10)
    #expect(tracker.heldAbsent.isEmpty && tracker.pendingOffline.count == 2)
    for t in [70.0, 130, 190] { _ = observe(&tracker, Array(devices.prefix(4)), t) }
    #expect(tracker.archive.events.filter { $0.kind == .offline }.count == 2)
    _ = observe(&tracker, Array(devices.prefix(2)), 200)
    #expect(tracker.heldAbsent.isEmpty && tracker.pendingOffline.count == 2)
}

@Test func shortAbsenceAndUnwatchedDevicesDoNotNotify() throws {
    var tracker = PresenceTracker(archive: PresenceArchive(routerKey: "router"))
    let device = try fixtureDevice()
    _ = observe(&tracker, [device], 0)
    tracker.setWatched(true, mac: fixtureMAC)
    _ = observe(&tracker, [], 10)
    _ = observe(&tracker, [device], 40)
    #expect(tracker.pendingOffline.isEmpty)
    #expect(tracker.archive.events.count == 1)
    tracker.setWatched(false, mac: fixtureMAC)
    _ = observe(&tracker, [], 50); _ = observe(&tracker, [], 110); _ = observe(&tracker, [], 170)
    #expect(observe(&tracker, [], 230).isEmpty)
    #expect(tracker.archive.events.last?.kind == .offline)
}

@Test func notificationCooldownSurvivesArchiveReload() throws {
    var tracker = PresenceTracker(archive: PresenceArchive(routerKey: "router"))
    let device = try fixtureDevice()
    _ = observe(&tracker, [device], 0); tracker.setWatched(true, mac: fixtureMAC)
    tracker.acknowledgeAlert(mac: fixtureMAC, at: fixtureDate)
    tracker = PresenceTracker(archive: try JSONDecoder().decode(PresenceArchive.self, from: JSONEncoder().encode(tracker.archive)))
    _ = observe(&tracker, [device], 10)
    _ = observe(&tracker, [], 20); _ = observe(&tracker, [], 80); _ = observe(&tracker, [], 140)
    #expect(observe(&tracker, [], 200).isEmpty)
    #expect(tracker.archive.records[fixtureMAC]?.watched == true)
}

@Test func offlineConfirmationUsesMonotonicTimeNotClockJump() throws {
    var tracker = PresenceTracker(archive: PresenceArchive(routerKey: "router"))
    _ = observe(&tracker, [try fixtureDevice()], 0); tracker.setWatched(true, mac: fixtureMAC)
    _ = observe(&tracker, [], 10)
    #expect(observe(&tracker, [], 20, wallOffset: 3600).isEmpty)
    #expect(tracker.archive.records[fixtureMAC]?.state == .online)
}

@Test func presenceNamesUpdateWithoutCreatingNewIdentity() throws {
    var tracker = PresenceTracker(archive: PresenceArchive(routerKey: "router"))
    _ = observe(&tracker, [try fixtureDevice()], 0)
    _ = observe(&tracker, [try fixtureDevice(name: "家庭存储")], 10)
    #expect(tracker.archive.records.count == 1)
    #expect(tracker.archive.records[fixtureMAC]?.name == "家庭存储")
}

@Test func privateHistoryRoundTripsSeparatesRoutersAndRejectsStaleWrites() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let files = MonitoringFileStore(directory: dir)
    var old = PresenceTracker(archive: PresenceArchive(routerKey: "router-a"))
    _ = observe(&old, [try fixtureDevice()], 0)
    let before = old.archive
    old.setWatched(true, mac: fixtureMAC)
    try await files.save(old.archive, revision: 2)
    try await files.save(before, revision: 1)
    let loaded = try await files.load(routerKey: "router-a")
    #expect(loaded.records[fixtureMAC]?.watched == true)
    #expect(try await files.load(routerKey: "router-b").records.isEmpty)
    let entry = try #require(FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first)
    let attributes = try FileManager.default.attributesOfItem(atPath: entry.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let bytes = try Data(contentsOf: entry)
    #expect(!String(decoding: bytes, as: UTF8.self).contains("password"))
    try Data("corrupt".utf8).write(to: entry)
    await #expect(throws: (any Error).self) { try await files.load(routerKey: "router-a") }
    #expect(try String(contentsOf: entry, encoding: .utf8) == "corrupt")
}

@Test func deviceTrafficDecodesOnlyDataAndKeepsUploadDownloadDirection() throws {
    let value = try DeviceTrafficParser.parse(#"router_traffic=[]; array_traffic=[["aa:bb:cc:dd:ee:01","9007199254740993",2000]]; unrelated();"#)
    #expect(value[fixtureMAC]?.upload == 9_007_199_254_740_993)
    #expect(value[fixtureMAC]?.download == 2000)
    #expect(try DeviceTrafficParser.parse("array_traffic=[];").isEmpty)
    for bad in ["array_traffic=[[execute(),1,2]];", "array_traffic=[[\"AA:BB:CC:DD:EE:01\",true,2]];", "array_traffic=[[\"AA:BB:CC:DD:EE:01\",-1,2]];", "array_traffic=[[\"bad\",1,2]];"] {
        #expect(throws: (any Error).self) { try DeviceTrafficParser.parse(bad) }
    }
}

@Test func deviceTrafficNeverConfusesFirstSampleResetGapAndZero() {
    var calculator = DeviceTrafficCalculator()
    func read(_ bytes: UInt64, _ t: Double, source: String = "a") -> DeviceTrafficReading {
        .init(source: source, counters: [fixtureMAC: .init(upload: bytes, download: bytes * 2)], monotonic: t)
    }
    let first = calculator.consume(read(100, 1)); #expect(first.isEmpty)
    let rate = calculator.consume(read(200, 11)); #expect(rate[fixtureMAC]?.upload == 10 && rate[fixtureMAC]?.download == 20)
    let zero = calculator.consume(read(200, 21)); #expect(zero[fixtureMAC]?.download == 0)
    let reset = calculator.consume(read(1, 31)); #expect(reset.isEmpty)
    let gap = calculator.consume(read(1000, 1000)); #expect(gap.isEmpty)
    let switched = calculator.consume(read(1200, 1010, source: "b")); #expect(switched.isEmpty)
    let missing = calculator.consume(.init(source: "b", counters: [:], monotonic: 1020)); #expect(missing.isEmpty)
}

@Test func trafficReadsMomentsApartKeepTheEarlierBaseline() {
    var window = DeviceTrafficWindow()
    func read(_ bytes: UInt64, _ t: Double) -> DeviceTrafficReading {
        .init(source: "a", counters: [fixtureMAC: .init(upload: bytes, download: bytes)], date: fixtureDate.addingTimeInterval(t), monotonic: t)
    }
    window.consume(read(1000, 10), online: [fixtureMAC])
    window.consume(read(2000, 20), online: [fixtureMAC])
    #expect(window.rates[fixtureMAC]?.upload == 100)
    // One counter step read 0.5 s later would otherwise show 2,000 B/s.
    window.consume(read(3000, 20.5), online: [fixtureMAC])
    #expect(window.rates[fixtureMAC]?.upload == 100)
    #expect(window.history[fixtureMAC]?.count == 1)
    window.consume(read(3000, 30), online: [fixtureMAC])
    #expect(window.rates[fixtureMAC]?.upload == 100)
    #expect(window.history[fixtureMAC]?.count == 2)
}

@Test func reconnectBacksOffAndNeverRetriesRejectedLogins() {
    #expect((0...6).map(ReconnectPolicy.delay(beforeAttempt:)) == [0, 30, 90, 300, 600, 600, 600])
    for retry: Error in [RouterError.network("x"), RouterError.httpStatus(502), RouterError.invalidResponse("x"),
                         RouterError.submissionUncertain("x"), RouterError.authenticationRequired, URLError(.timedOut)] {
        #expect(ReconnectPolicy.retries(after: retry))
    }
    for stop: Error in [RouterError.invalidCredentials, RouterError.captchaRequired, RouterError.locked,
                        RouterError.invalidAddress, RouterError.validation("x"), CancellationError()] {
        #expect(!ReconnectPolicy.retries(after: stop))
    }
}

@Test func healthParsersRequireActualResultsNotServerMetadata() {
    #expect(HealthResultParser.ping("5 packets transmitted, 5 received, 0% packet loss\nrtt min/avg/max/mdev = 2.1/3.2/4.3/0.1 ms") == .init(lossPercent: 0, averageMilliseconds: 3.2))
    #expect(HealthResultParser.ping("5 packets transmitted, 0 packets received, 100% packet loss")?.lossPercent == 100)
    #expect(HealthResultParser.ping("PING 1.1.1.1") == nil)
    #expect(HealthResultParser.dns("Server: 192.168.50.1\nAddress: 192.168.50.1#53") == .unknown)
    #expect(HealthResultParser.dns("Server: 192.168.50.1\nName: example.com\nAddress 1: 93.184.216.34") == .resolved)
    #expect(HealthResultParser.dns("Name: example.com\nAddress: 2606:2800:220:1::1") == .resolved)
    #expect(HealthResultParser.dns("NXDOMAIN") == .failed)
    var report = NetworkHealthReport(); report.completedAt = .now
    #expect(report.title != "本次检查通过")
    report.checks = [.init(id: "dns", title: "DNS", severity: .unknown, summary: "unknown")]
    #expect(report.title == "部分结果尚未确认")
}

@Test func malformedClientPresenceIsNotAcceptedAsOffline() {
    for field in ["", ",\"isOnline\":\"unknown\""] {
        let text = "{\"get_clientlist\":{\"AA:BB:CC:DD:EE:01\":{\"name\":\"NAS\"" + field + "}}}"
        #expect(throws: (any Error).self) { try RouterParser.clients(Data(text.utf8)) }
    }
}

private actor TrafficTransport: RouterTransport {
    var texts: [String]; var paths: [String] = []
    init(_ texts: [String]) { self.texts = texts }
    func send(_ request: URLRequest) async throws -> RouterHTTPResponse {
        paths.append(request.url!.path)
        #expect(request.httpMethod == "GET")
        return .init(data: Data(texts.removeFirst().utf8), status: 200)
    }
    nonisolated func cancel() {}
}
@Test func clientTrafficReadsExistingEndpointsAndDoesNotRetryAuthentication() async throws {
    let transport = TrafficTransport(["array_traffic=[];", #"array_traffic=[["AA:BB:CC:DD:EE:01","10","20"]];"#])
    let client = RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: transport, writes: .reference)
    let reading = try await client.deviceTraffic()
    #expect(reading.source == "getTraffic_Dns.asp")
    #expect(await transport.paths == ["/getTraffic.asp", "/getTraffic_Dns.asp"])
    let expired = TrafficTransport(["<script>location='Main_Login.asp'</script>"])
    let second = RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: expired, writes: .reference)
    await #expect(throws: RouterError.authenticationRequired) { try await second.deviceTraffic() }
    #expect(await expired.paths.count == 1)
}
