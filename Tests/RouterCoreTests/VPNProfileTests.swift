import Foundation
import Testing
@testable import RouterCore

// MARK: Fixtures

private let t0 = Date(timeIntervalSince1970: 1_000)
private let t1 = Date(timeIntervalSince1970: 1_010)

/// Values a factory-reset slot is assumed to hold: defaults such as port 1194/51820 and NAT on, nothing user-entered.
private func emptyValues(_ instance: VPNInstance) -> [String: String] {
    var values: [String: String] = [:]
    for key in instance.overviewKeys {
        if key.hasSuffix("_port") { values[key] = instance.family == .openVPN ? "1194" : "51820" }
        else if key.hasSuffix("_state") || key.hasSuffix("_enable") || key.hasSuffix("_userauth") || key.hasSuffix("_enforce") { values[key] = "0" }
        else if key.hasSuffix("_proto") { values[key] = "udp" }
        else { values[key] = "" }
    }
    return values
}

private func configuredValues(_ instance: VPNInstance) -> [String: String] {
    var values = emptyValues(instance)
    let p = instance.settingPrefix
    switch instance {
    case .openVPNClient:
        values[p + "addr"] = "vpn.example.com"; values[p + "desc"] = "出口"
    case .wireGuardClient:
        values[p + "addr"] = "10.6.0.2/32"; values[p + "priv"] = "PRIVATE-KEY-SECRET"; values[p + "ppub"] = "pub"
        values[p + "ep_addr"] = "203.0.113.1"; values[p + "aips"] = "0.0.0.0/0"; values[p + "enable"] = "1"
    case .openVPNServer, .wireGuardServer:
        break
    }
    return values
}

private func reading(_ instance: VPNInstance, _ raw: String, list: String = "") throws -> VPNRuntimeReading {
    var values = [instance.statusKey: raw]
    if let key = instance.startupListKey { values[key] = list }
    return try VPNRuntimeReading(instance: instance, values: values)
}

/// Tracker with a successful read of `raw`.
private func loadedTracker(_ instance: VPNInstance, _ raw: String) throws -> VPNRuntimeTracker {
    var tracker = VPNRuntimeTracker(instance: instance)
    let transition1 = tracker.beginRead(at: t0)
    let ticket = try #require(transition1)
    let transition2 = tracker.finishRead(ticket, .success(try reading(instance, raw)), at: t0)
    #expect(transition2)
    return tracker
}

// MARK: Inventory and catalog coverage

@Test func vpnCenterCoversEveryCatalogVPNSectionExactlyOnce() {
    #expect(VPNInstance.allSlots.count == 13)
    #expect(VPNInstance.outboundSlots.count == 10)
    #expect(Set(VPNInstance.allSlots.map(\.id)).count == 13)
    let catalog = Set(SettingsCatalog.sections.filter { $0.category == "VPN" }.map(\.id))
    let center = Set(VPNCenterDestination.all.map(\.sectionID))
    #expect(!catalog.isEmpty)
    #expect(catalog == center)
    for id in catalog { #expect(VPNCenterDestination(sectionID: id)?.sectionID == id) }
    #expect(VPNInstance.serverSlots.allSatisfy { $0.purpose == .remoteAccess })
    #expect(VPNInstance.outboundSlots.allSatisfy { $0.purpose == .outbound })
}

@Test func slotLabelsKeepProtocolAndNumber() {
    #expect(VPNInstance.openVPNClient(2).slotLabel == "OpenVPN 客户端 · 槽位 2")
    #expect(VPNInstance.wireGuardClient(5).slotLabel == "WireGuard 客户端 · 槽位 5")
    #expect(VPNInstance.openVPNServer(1).slotLabel.contains("槽位 1"))
}

@Test func statusKeysFollowFirmwareNames() {
    #expect(VPNInstance.openVPNClient(3).statusKey == "vpn_client3_state")
    #expect(VPNInstance.openVPNServer(2).statusKey == "vpn_server2_state")
    #expect(VPNInstance.wireGuardClient(4).statusKey == "wgc4_enable")
    #expect(VPNInstance.wireGuardServer.statusKey == "wgs1_enable")
    #expect(VPNInstance.wireGuardClient(1).runtimeServiceKind == nil)
    #expect(VPNInstance.wireGuardServer.runtimeServiceKind == nil)
    #expect(VPNInstance.openVPNClient(1).runtimeServiceKind == "vpnclient")
    #expect(VPNRuntimeReading.keys(for: .openVPNClient(1)) == ["vpn_client1_state", "vpn_clientx_eas"])
    #expect(VPNRuntimeReading.keys(for: .wireGuardClient(1)) == ["wgc1_enable"])
}

@Test func overviewKeysExistInCatalogExceptOpenVPNState() {
    for instance in VPNInstance.allSlots {
        let section = SettingsCatalog.sections.first { $0.id == instance.id }
        let fields = Set(section?.fields.map(\.key) ?? [])
        for key in instance.overviewKeys where key != instance.statusKey || instance.family == .wireGuard {
            #expect(fields.contains(key), "\(key) missing from catalog section \(instance.id)")
        }
    }
}

// MARK: Field roles and layout

@Test func fieldRolesParseOnlyIndexedVPNKeys() {
    #expect(VPNFieldRole(key: "vpn_client3_addr") == VPNFieldRole(family: .openVPNClient, suffix: "addr"))
    #expect(VPNFieldRole(key: "vpn_server2_ncp_ciphers") == VPNFieldRole(family: .openVPNServer, suffix: "ncp_ciphers"))
    #expect(VPNFieldRole(key: "wgc5_ep_port") == VPNFieldRole(family: .wireGuardClient, suffix: "ep_port"))
    #expect(VPNFieldRole(key: "wgs1_port") == VPNFieldRole(family: .wireGuardServer, suffix: "port"))
    #expect(VPNFieldRole(key: "vpndirector_rulelist") == VPNFieldRole(family: .director, suffix: "rulelist"))
    for key in ["vpn_clientx_eas", "vpn_serverx_start", "vpn_client6_addr", "vpn_client01_addr", "vpn_server3_port",
                "wgc0_addr", "wgc1_", "wgc1addr", "wgs2_port", "wan0_proto", "vpn_client1"] {
        #expect(VPNFieldRole(key: key) == nil, "\(key)")
    }
}

@Test func everyVPNFieldStaysReachableAfterPartition() throws {
    for section in SettingsCatalog.sections where section.category == "VPN" {
        let roles = section.fields.map { VPNFieldRole(key: $0.key) }
        #expect(roles.allSatisfy { $0 != nil }, "unlabelled field in \(section.id)")
        #expect(Set(roles.compactMap { $0 }).count == section.fields.count, "duplicate role in \(section.id)")
        let parts = VPNFieldLayout.partition(section.fields)
        #expect(parts.primary.count + parts.advanced.count == section.fields.count)
        #expect(Set((parts.primary + parts.advanced).map(\.key)) == Set(section.fields.map(\.key)))
        #expect(!parts.primary.isEmpty)
        // The split must hand back the catalog definitions themselves, untouched.
        for field in parts.primary + parts.advanced { #expect(section.fields.contains(field)) }
    }
}

@Test func commonFieldsMatchEachProfileType() throws {
    func primaryKeys(_ id: String) throws -> [String] {
        let section = try #require(SettingsCatalog.sections.first { $0.id == id })
        return VPNFieldLayout.partition(section.fields).primary.map(\.key)
    }
    #expect(try primaryKeys("ovpn2") == ["vpn_client2_desc", "vpn_client2_addr", "vpn_client2_port", "vpn_client2_proto",
                                         "vpn_client2_userauth", "vpn_client2_username", "vpn_client2_password", "vpn_client2_enforce"])
    let wg = try primaryKeys("wgc1")
    #expect(wg.first == "wgc1_desc")
    #expect(wg.contains("wgc1_enforce") && wg.contains("wgc1_ep_addr") && wg.contains("wgc1_ep_port"))
    #expect(!wg.contains("wgc1_priv") && !wg.contains("wgc1_psk") && !wg.contains("wgc1_mtu"))
    #expect(try primaryKeys("ovpns1") == ["vpn_server1_port", "vpn_server1_proto", "vpn_server1_igncrt"])
    #expect(try primaryKeys("vpndirector") == ["vpndirector_rulelist"])
    #expect(VPNFieldLayout.tier(forKey: "vpn_client1_hmac") == .advanced)
    #expect(VPNFieldLayout.tier(forKey: "vpn_client1_addr") == .primary)
    #expect(VPNFieldLayout.tier(forKey: "unknown_key") == .advanced)
}

@Test func searchJumpResolvesOwningDestination() {
    #expect(VPNCenterDestination(settingKey: "wgc3_aips") == .instance(.wireGuardClient(3)))
    #expect(VPNCenterDestination(settingKey: "vpn_server2_hmac") == .instance(.openVPNServer(2)))
    #expect(VPNCenterDestination(settingKey: "wgs1_port") == .instance(.wireGuardServer))
    #expect(VPNCenterDestination(settingKey: "vpndirector_rulelist") == .routing)
    #expect(VPNCenterDestination(settingKey: "wl0_ssid") == nil)
    #expect(VPNCenterDestination(settingKey: "vpn_client1_state") == nil)
}

// MARK: Classification

@Test func defaultValuesAloneNeverCountAsConfigured() {
    for instance in VPNInstance.outboundSlots {
        #expect(VPNProfileClassifier.presence(of: instance, values: emptyValues(instance)) == .unused, "\(instance.id)")
    }
    // NAT/firewall defaults, MTU, DNS and keepalive are not evidence either.
    var wg = emptyValues(.wireGuardClient(1))
    wg["wgc1_aips"] = "0.0.0.0/0"
    #expect(VPNProfileClassifier.presence(of: .wireGuardClient(1), values: wg) == .unused)
}

@Test func openVPNClientPartialConfigurationsAreFlagged() {
    let i = VPNInstance.openVPNClient(1)
    var v = emptyValues(i)
    v["vpn_client1_username"] = "alice"
    #expect(VPNProfileClassifier.presence(of: i, values: v) == .incomplete(missing: ["服务器地址"]))

    v = emptyValues(i); v["vpn_client1_enforce"] = "1"
    #expect(VPNProfileClassifier.presence(of: i, values: v) == .incomplete(missing: ["服务器地址"]))

    v = emptyValues(i); v["vpn_client1_state"] = "-1"
    #expect(VPNProfileClassifier.presence(of: i, values: v) == .incomplete(missing: ["服务器地址"]), "a non-stopped slot is never folded away")

    v = emptyValues(i); v["vpn_client1_addr"] = " vpn.example.com "; v["vpn_client1_port"] = ""
    #expect(VPNProfileClassifier.presence(of: i, values: v) == .incomplete(missing: ["服务器端口"]))

    v["vpn_client1_port"] = "1194"; v["vpn_client1_userauth"] = "1"
    #expect(VPNProfileClassifier.presence(of: i, values: v) == .incomplete(missing: ["用户名"]))

    v["vpn_client1_username"] = "alice"
    #expect(VPNProfileClassifier.presence(of: i, values: v) == .configured)

    v["vpn_client1_addr"] = "   "
    #expect(VPNProfileClassifier.presence(of: i, values: v) == .incomplete(missing: ["服务器地址"]))
}

@Test func namedOrCredentialOnlySlotsAreNeverOfferedAsUnused() {
    for instance in VPNInstance.outboundSlots {
        var values = emptyValues(instance)
        values[instance.settingPrefix + "desc"] = "公司连接"
        #expect(!VPNProfileClassifier.presence(of: instance, values: values).foldsIntoAddMenu)
        values.removeValue(forKey: instance.settingPrefix + "desc")
        #expect(VPNProfileClassifier.presence(of: instance, values: values) == .unread)
    }
    var openVPN = emptyValues(.openVPNClient(1)); openVPN["vpn_client1_password"] = "fixture-only"
    #expect(!VPNProfileClassifier.presence(of: .openVPNClient(1), values: openVPN).foldsIntoAddMenu)
    var wireGuard = emptyValues(.wireGuardClient(1)); wireGuard["wgc1_psk"] = "fixture-only"
    #expect(!VPNProfileClassifier.presence(of: .wireGuardClient(1), values: wireGuard).foldsIntoAddMenu)
}

@Test func startPreflightRequiresReadAndCompleteClientDetails() {
    let client = VPNInstance.openVPNClient(2)
    #expect(VPNProfileClassifier.startBlockReason(for: client, presence: nil) != nil)
    #expect(VPNProfileClassifier.startBlockReason(for: client, presence: .unread) != nil)
    #expect(VPNProfileClassifier.startBlockReason(for: client, presence: .unused) != nil)
    #expect(VPNProfileClassifier.startBlockReason(for: client, presence: .incomplete(missing: ["服务器地址"]))?.contains("服务器地址") == true)
    #expect(VPNProfileClassifier.startBlockReason(for: client, presence: .configured) == nil)
    #expect(VPNProfileClassifier.startBlockReason(for: .openVPNServer(1), presence: .service) == nil)
}

@Test func wireGuardClientNeedsKeysEndpointAndAddress() {
    let i = VPNInstance.wireGuardClient(2)
    var v = emptyValues(i); v["wgc2_enable"] = "1"
    #expect(VPNProfileClassifier.presence(of: i, values: v) == .incomplete(missing: ["隧道地址", "私钥", "服务器公钥", "端点地址", "允许的 IP"]))
    v = configuredValues(i)
    #expect(VPNProfileClassifier.presence(of: i, values: v) == .configured)
    v["wgc2_ep_port"] = "70000"
    #expect(VPNProfileClassifier.presence(of: i, values: v) == .incomplete(missing: ["端点端口"]))
    v = configuredValues(i); v["wgc2_priv"] = ""
    #expect(VPNProfileClassifier.presence(of: i, values: v) == .incomplete(missing: ["私钥"]))
}

@Test func missingKeysClassifyAsUnreadNotEmpty() {
    for instance in VPNInstance.outboundSlots {
        var values = emptyValues(instance)
        values.removeValue(forKey: instance.settingPrefix + "addr")
        #expect(VPNProfileClassifier.presence(of: instance, values: values) == .unread, "\(instance.id)")
        #expect(VPNProfileClassifier.presence(of: instance, values: [:]) == .unread)
    }
    // The OpenVPN state key is optional evidence: a full catalog section read (without it) still classifies.
    var section = emptyValues(.openVPNClient(4)); section.removeValue(forKey: "vpn_client4_state")
    #expect(VPNProfileClassifier.presence(of: .openVPNClient(4), values: section) == .unused)
}

@Test func thirteenSlotsInEmptyMixedAndFullStates() {
    func folded(_ make: (VPNInstance) -> [String: String]) -> [VPNInstance] {
        VPNInstance.allSlots.filter { VPNProfileClassifier.presence(of: $0, values: make($0)).foldsIntoAddMenu }
    }
    #expect(folded(emptyValues) == VPNInstance.outboundSlots)
    #expect(folded(configuredValues).isEmpty)
    let mixed = folded { instance in
        switch instance {
        case .openVPNClient(1), .wireGuardClient(3): configuredValues(instance)
        case .openVPNClient(2): emptyValues(instance).merging(["vpn_client2_username": "bob"]) { _, b in b }
        default: emptyValues(instance)
        }
    }
    #expect(mixed == [.openVPNClient(3), .openVPNClient(4), .openVPNClient(5), .wireGuardClient(1), .wireGuardClient(2), .wireGuardClient(4), .wireGuardClient(5)])
    for server in VPNInstance.serverSlots {
        #expect(VPNProfileClassifier.presence(of: server, values: [:]) == .service)
    }
}

// MARK: Summaries

@Test func summariesMergeEndpointAndDropSecrets() {
    let wg = VPNProfileSummary(instance: .wireGuardClient(1), values: configuredValues(.wireGuardClient(1)))
    #expect(wg.connectionLine == "203.0.113.1:51820 · UDP")
    #expect(wg.allowedIPs == .allTraffic(includesIPv6: false))
    #expect(wg.condition == .enabledUnconfirmed)
    #expect(!String(describing: wg).contains("PRIVATE-KEY-SECRET"))
    #expect(wg.displayName == "WireGuard 客户端 1")

    var ovpn = configuredValues(.openVPNClient(2)); ovpn["vpn_client2_proto"] = "tcp-client"; ovpn["vpn_client2_state"] = "2"
    let summary = VPNProfileSummary(instance: .openVPNClient(2), values: ovpn, startupList: "1,2,")
    #expect(summary.connectionLine == "vpn.example.com:1194 · TCP")
    #expect(summary.displayName == "出口")
    #expect(summary.condition == .running)
    #expect(summary.autoStart == true)
    #expect(VPNProfileSummary(instance: .openVPNClient(3), values: ovpn, startupList: "1,2,").autoStart == false)
    #expect(VPNProfileSummary(instance: .openVPNClient(2), values: ovpn, startupList: "x").autoStart == nil)
}

@Test func endpointAndAllowedIPsFormatting() {
    #expect(VPNEndpointText.make(host: "2001:db8::1", port: "51820") == "[2001:db8::1]:51820")
    #expect(VPNEndpointText.make(host: "host", port: "") == "host")
    #expect(VPNEndpointText.make(host: " ", port: "1") == nil)
    #expect(VPNEndpointText.transport("udp") == "UDP")
    #expect(VPNEndpointText.transport("tcp-server") == "TCP")
    #expect(VPNAllowedIPsSummary("0.0.0.0/0, ::/0") == .allTraffic(includesIPv6: true))
    #expect(VPNAllowedIPsSummary("10.0.0.0/8,192.168.1.0/24,") == .ranges(2))
    #expect(VPNAllowedIPsSummary("  ") == .empty)
}

@Test func startupListParsingMatchesWriterFormat() {
    #expect(VPNStartupList.units("1,3,", maximum: 5) == [1, 3])
    #expect(VPNStartupList.units("", maximum: 5) == [])
    #expect(VPNStartupList.units("1,6,", maximum: 5) == nil)
    #expect(VPNStartupList.units("1,a,", maximum: 5) == nil)
    #expect(VPNStartupList.contains(.openVPNServer(2), in: "2,") == true)
    #expect(VPNStartupList.contains(.openVPNServer(2), in: "3,") == nil)
    #expect(VPNStartupList.contains(.wireGuardClient(1), in: "1,") == nil)
}

@Test func directorReferencesUseOnlyDocumentedTokens() throws {
    let summary = try VPNDirectorSummary(raw: "<1>TV>192.168.50.20>>OVPN1<0>NAS>192.168.50.3>>OVPN1<1>Work>192.168.50.9>>WGC1<1>All>>>WAN")
    #expect(summary.total == 4)
    #expect(summary.enabled == 3)
    #expect(summary.interfaces.map(\.name) == ["OVPN1", "WGC1", "WAN"])
    let first = try #require(summary.references(to: .openVPNClient(1)))
    #expect(first.total == 2 && first.enabled == 1)
    let second = try #require(summary.references(to: .openVPNClient(2)))
    #expect(second.total == 0 && second.enabled == 0)
    #expect(summary.references(to: .wireGuardClient(1)) == nil, "WireGuard tokens are listed verbatim, not attributed")
    #expect(try VPNDirectorSummary(raw: "").total == 0)
    #expect(throws: (any Error).self) { try VPNDirectorSummary(raw: "<1>only>three") }
}

// MARK: Runtime state

@Test func runtimeConditionsParseBothSources() {
    #expect(VPNRuntimeCondition(raw: "2", source: .openVPNState) == .running)
    #expect(VPNRuntimeCondition(raw: "1", source: .openVPNState) == .connecting)
    #expect(VPNRuntimeCondition(raw: "0", source: .openVPNState) == .stopped)
    #expect(VPNRuntimeCondition(raw: "-1", source: .openVPNState) == .error)
    #expect(VPNRuntimeCondition(raw: "", source: .openVPNState) == .unrecognized(""))
    #expect(VPNRuntimeCondition(raw: "7", source: .openVPNState) == .unrecognized("7"))
    #expect(VPNRuntimeCondition(raw: "1", source: .enableFlag) == .enabledUnconfirmed)
    #expect(VPNRuntimeCondition(raw: "", source: .enableFlag) == .disabled)
    #expect(VPNRuntimeCondition(raw: "2", source: .enableFlag) == .unrecognized("2"))
}

@Test func runtimeReadingRejectsPartialReplies() {
    #expect(throws: VPNReadFailure.self) { try VPNRuntimeReading(instance: .openVPNClient(1), values: ["vpn_client1_state": "2"]) }
    #expect(throws: VPNReadFailure.self) { try VPNRuntimeReading(instance: .openVPNClient(1), values: ["vpn_clientx_eas": ""]) }
    #expect((try? VPNRuntimeReading(instance: .wireGuardClient(1), values: ["wgc1_enable": "1"]))?.condition == .enabledUnconfirmed)
}

@Test func switchingInstanceThenFailedReadNeverShowsPreviousRunningState() throws {
    var tracker = try loadedTracker(.openVPNClient(1), "2")
    #expect(tracker.status(connected: true).title == "运行中")
    #expect(tracker.primaryAction == .stop)

    tracker.select(.openVPNClient(2))
    #expect(tracker.reading == .notRead)
    #expect(tracker.primaryAction == nil)
    let transition3 = tracker.beginRead(at: t1)
    let ticket = try #require(transition3)
    let transition4 = tracker.finishRead(ticket, .failure(VPNReadFailure("超时")), at: t1)
    #expect(transition4)

    let status = tracker.status(connected: true)
    #expect(status.title == "读取失败")
    #expect(status.at == t1)
    #expect(status.tone == .failure)
    #expect(!status.title.contains("运行"))
    #expect(tracker.primaryAction == nil)
    #expect(!tracker.writeAvailability(connected: true, otherOperationRunning: false).isAllowed)
}

@Test func lateReadForPreviousInstanceIsDropped() throws {
    var tracker = VPNRuntimeTracker(instance: .openVPNClient(1))
    let transition5 = tracker.beginRead(at: t0)
    let stale = try #require(transition5)
    tracker.select(.openVPNClient(2))
    let transition6 = tracker.finishRead(stale, .success(try reading(.openVPNClient(1), "2")), at: t1)
    #expect(!transition6)
    #expect(tracker.reading == .notRead)
    #expect(tracker.instance == .openVPNClient(2))

    // A newer read of the same instance also supersedes an older one.
    let transition7 = tracker.beginRead(at: t0)
    let first = try #require(transition7)
    let transition8 = tracker.beginRead(at: t1)
    let second = try #require(transition8)
    let transition9 = tracker.finishRead(first, .success(try reading(.openVPNClient(2), "2")), at: t1)
    #expect(!transition9)
    let transition10 = tracker.finishRead(second, .success(try reading(.openVPNClient(2), "0")), at: t1)
    #expect(transition10)
    #expect(tracker.reading.value?.condition == .stopped)
}

@Test func startIsConfirmedOnlyByRouterState() throws {
    var tracker = try loadedTracker(.openVPNClient(1), "0")
    #expect(tracker.primaryAction == .start)
    let transition11 = tracker.beginOperation(.stop, connected: true, otherOperationRunning: false)
    #expect(transition11 == nil, "only the offered action may be sent")
    let transition12 = tracker.beginOperation(.start, connected: true, otherOperationRunning: true)
    #expect(transition12 == nil)
    let transition13 = tracker.beginOperation(.start, connected: true, otherOperationRunning: false)
    let ticket = try #require(transition13)
    let transition14 = tracker.beginRead(at: t0)
    #expect(transition14 == nil, "no manual read while an operation is active")
    let transition15 = tracker.observe(ticket, rawState: "2", at: t0)
    #expect(transition15 == .ignored, "nothing is observed before submission is accepted")
    tracker.submissionAccepted(ticket, at: t0)
    #expect(tracker.status(connected: true).title.contains("等待路由器确认"))
    let transition16 = tracker.observe(ticket, rawState: "1", at: t1)
    #expect(transition16 == .keepWaiting)
    tracker.pollFailed(ticket, message: "重启中")
    #expect(tracker.operation?.lastPollError == "重启中")
    let transition17 = tracker.observe(ticket, rawState: "2", at: t1)
    #expect(transition17 == .finished)
    #expect(tracker.operation?.phase == .confirmed)
    #expect(tracker.status(connected: true).title == "运行中")
    #expect(tracker.reading.value?.startupList == "", "startup list from the full read is preserved by polls")
    #expect(tracker.writeAvailability(connected: true, otherOperationRunning: false).isAllowed)
    #expect(tracker.primaryAction == .stop)
}

@Test func routerReportedErrorEndsWaiting() throws {
    var tracker = try loadedTracker(.openVPNServer(1), "0")
    let transition18 = tracker.beginOperation(.start, connected: true, otherOperationRunning: false)
    let ticket = try #require(transition18)
    tracker.submissionAccepted(ticket, at: t0)
    let transition19 = tracker.observe(ticket, rawState: "-1", at: t1)
    #expect(transition19 == .finished)
    #expect(tracker.operation?.phase == .reportedError)
    #expect(tracker.status(connected: true).tone == .failure)
}

@Test func stopWaitingNeitherUndoesNorAllowsResubmitBeforeFreshRead() throws {
    var tracker = try loadedTracker(.openVPNClient(3), "0")
    let transition20 = tracker.beginOperation(.start, connected: true, otherOperationRunning: false)
    let ticket = try #require(transition20)
    let transition21 = tracker.stopWaiting(ticket)
    #expect(!transition21, "cannot stop waiting before the request is sent")
    tracker.submissionAccepted(ticket, at: t0)
    let transition22 = tracker.stopWaiting(ticket)
    #expect(transition22)
    #expect(tracker.requiresFreshRead)
    let status = tracker.status(connected: true)
    #expect(status.title.contains("结果未确认"))
    #expect(status.detail?.contains("不会撤销") == true)
    #expect(!tracker.writeAvailability(connected: true, otherOperationRunning: false).isAllowed)
    let transition23 = tracker.beginOperation(.start, connected: true, otherOperationRunning: false)
    #expect(transition23 == nil)
    let transition24 = tracker.observe(ticket, rawState: "2", at: t1)
    #expect(transition24 == .ignored, "a poll arriving after stop-wait is ignored")

    let transition25 = tracker.beginRead(at: t1)
    let read = try #require(transition25)
    let transition26 = tracker.finishRead(read, .success(try reading(.openVPNClient(3), "1")), at: t1)
    #expect(transition26)
    #expect(!tracker.requiresFreshRead)
    #expect(tracker.operation == nil)
    #expect(tracker.primaryAction == .stop)
    #expect(tracker.writeAvailability(connected: true, otherOperationRunning: false).isAllowed)
}

@Test func timeoutAndUncertainSubmissionRequireFreshRead() throws {
    var tracker = try loadedTracker(.openVPNClient(1), "2")
    let transition27 = tracker.beginOperation(.stop, connected: true, otherOperationRunning: false)
    var ticket = try #require(transition27)
    tracker.submissionAccepted(ticket, at: t0)
    tracker.timedOut(ticket)
    #expect(tracker.requiresFreshRead)
    #expect(tracker.primaryAction == .stop)
    #expect(!tracker.writeAvailability(connected: true, otherOperationRunning: false).isAllowed)

    tracker = try loadedTracker(.openVPNClient(1), "2")
    let transition28 = tracker.beginOperation(.stop, connected: true, otherOperationRunning: false)
    ticket = try #require(transition28)
    tracker.submissionFailed(ticket, message: "路由器未确认重载服务")
    #expect(tracker.requiresFreshRead)
    #expect(tracker.status(connected: true).title.contains("结果未确认"))

    // A request that never reached the router leaves the last reading in force.
    tracker = try loadedTracker(.openVPNClient(1), "2")
    let transition28b = tracker.beginOperation(.stop, connected: true, otherOperationRunning: false)
    ticket = try #require(transition28b)
    tracker.submissionNotSent(ticket)
    #expect(tracker.operation == nil)
    #expect(!tracker.requiresFreshRead)
    #expect(tracker.status(connected: true).title == "运行中")
    #expect(tracker.writeAvailability(connected: true, otherOperationRunning: false).isAllowed)
}

@Test func switchingInstanceDiscardsOperationTickets() throws {
    var tracker = try loadedTracker(.openVPNClient(1), "0")
    let transition29 = tracker.beginOperation(.start, connected: true, otherOperationRunning: false)
    let ticket = try #require(transition29)
    tracker.submissionAccepted(ticket, at: t0)
    tracker.select(.openVPNClient(2))
    let transition30 = tracker.observe(ticket, rawState: "2", at: t1)
    #expect(transition30 == .ignored)
    let transition31 = tracker.stopWaiting(ticket)
    #expect(!transition31)
    #expect(tracker.operation == nil)
    #expect(tracker.reading == .notRead)
}

@Test func disconnectedTrackerNeverReportsIdle() throws {
    let tracker = try loadedTracker(.openVPNClient(1), "0")
    let status = tracker.status(connected: false)
    #expect(status.title.contains("未知"))
    #expect(status.title != "已停止")
    #expect(!tracker.writeAvailability(connected: false, otherOperationRunning: false).isAllowed)
    let overview = VPNStatusDescription.overview(.loaded(VPNProfileSummary(instance: .openVPNClient(1), values: configuredValues(.openVPNClient(1))), at: t0), connected: false)
    #expect(overview.title.contains("未知"))
}

@Test func unrecognizedStateBlocksWrites() throws {
    let tracker = try loadedTracker(.openVPNClient(1), "9")
    #expect(tracker.primaryAction == nil)
    #expect(!tracker.writeAvailability(connected: true, otherOperationRunning: false).isAllowed)
    #expect(tracker.status(connected: true).tone == .attention)
}

@Test func wireGuardIsNeverShownAsConnected() throws {
    for instance in [VPNInstance.wireGuardClient(1), .wireGuardServer] {
        let tracker = try loadedTracker(instance, "1")
        let status = tracker.status(connected: true)
        #expect(status.title == "已启用 · 连接待确认")
        #expect(status.tone == .pending)
        #expect(tracker.primaryAction == nil)
        #expect(!tracker.writeAvailability(connected: true, otherOperationRunning: false).isAllowed)
    }
    let conditions: [VPNRuntimeCondition] = [.stopped, .connecting, .running, .error, .enabledUnconfirmed, .disabled, .unrecognized("x")]
    for condition in conditions {
        let text = VPNStatusDescription.condition(condition, at: nil)
        #expect(!text.title.contains("已连接") && !(text.detail ?? "").contains("已连接"))
    }
}

@Test func overviewStatusDistinguishesReadStates() {
    let summary = VPNProfileSummary(instance: .wireGuardClient(1), values: { var v = emptyValues(.wireGuardClient(1)); v["wgc1_enable"] = "1"; return v }())
    #expect(VPNStatusDescription.overview(.notRead, connected: true).title == "尚未读取")
    #expect(VPNStatusDescription.overview(.loading(since: t0), connected: true).title == "正在读取…")
    #expect(VPNStatusDescription.overview(.failed("超时", at: t0), connected: true).tone == .failure)
    let incomplete = VPNStatusDescription.overview(.loaded(summary, at: t0), connected: true)
    #expect(incomplete.title == "配置不完整")
    #expect(incomplete.detail?.contains("私钥") == true)
}

// MARK: Draft protection and import placement

@Test func selectionPolicyProtectsDraftsAndInFlightWork() {
    let a = VPNCenterDestination.instance(.openVPNClient(1)), b = VPNCenterDestination.instance(.wireGuardClient(1))
    #expect(VPNSelectionPolicy.decide(current: a, target: a, pendingChanges: 3, saving: true, operationRunning: true) == .alreadySelected)
    #expect(VPNSelectionPolicy.decide(current: nil, target: a, pendingChanges: 0, saving: false, operationRunning: false) == .proceed)
    #expect(VPNSelectionPolicy.decide(current: a, target: b, pendingChanges: 2, saving: false, operationRunning: false) == .confirmDiscard(changes: 2))
    if case .blocked = VPNSelectionPolicy.decide(current: a, target: b, pendingChanges: 0, saving: true, operationRunning: false) {} else { Issue.record("saving must block switching") }
    if case .blocked = VPNSelectionPolicy.decide(current: a, target: .routing, pendingChanges: 0, saving: false, operationRunning: true) {} else { Issue.record("an operation must block switching") }
}

@Test func importIsOnlyRecommendedForFreshlyEmptyClientSlots() {
    #expect(VPNImportPlacement.decide(.openVPNClient(1), presence: .unused) == .recommended)
    #expect(VPNImportPlacement.decide(.wireGuardClient(1), presence: .unused) == .recommended)
    for presence: VPNSlotPresence? in [nil, .unread, .configured, .incomplete(missing: ["私钥"])] {
        #expect(VPNImportPlacement.decide(.openVPNClient(1), presence: presence) == .replacement)
    }
    #expect(VPNImportPlacement.decide(.openVPNServer(1), presence: .service) == .unavailable)
    #expect(VPNImportPlacement.decide(.wireGuardServer, presence: .unused) == .unavailable)
}
