import Foundation
import Testing
@testable import RouterCore

private func networkFixture() throws -> SDNSnapshot {
    try SDNSnapshot(values: [
        "sdn_rl":"<0>Default>1>0>0>0>0>0>0>0>0>0>0>0>0>0>MAIN-TAIL<1>Guest>1>1>1>1>6>0>0>0>0>0>0>0>1>0>0>0>0>WEB>0>0>0>FUTURE",
        "subnet_rl":"<1>br52>192.168.52.1>255.255.255.0>1>192.168.52.2>192.168.52.254>86400>>,>>0>>0>0>1>1000>2000>,,>0>1>",
        "vlan_rl":"<1>52>0>", "radius_list":"", "sdn_access_rl":"", "vlan_trunklist":"", "qos_enable":"0", "qos_type":"0", "mld_enable":"0",
        "lan_ipaddr":"192.168.50.1", "lan_netmask":"255.255.255.0", "lan_hwaddr":"AA:BB:CC:DD:EE:01",
        "apg1_ssid":"Guest", "apg1_enable":"1", "apg1_security":"<3>psk2sae>aes>test-password>1<13>psk2sae>aes>test-password>1<16>sae>aes>test-password>1<96>sae>aes>test-password>1",
        "apg1_hide_ssid":"0", "apg1_ap_isolate":"1", "apg1_mlo":"0", "apg1_11be":"0", "apg1_dut_list":"<AA:BB:CC:DD:EE:01>3>", "apg1_bw_limit":"<0>>"
    ])
}
@Test func sdnRenamePreservesMainAndEveryUnchangedRule() throws {
    let snapshot = try networkFixture(); var profile = try #require(snapshot.profiles.first)
    profile.ssid = "Guest Updated"
    let plan = try SDNPlanner.edit(profile, snapshot: snapshot)
    #expect(plan.fields == ["apg1_ssid":"Guest Updated"])
    #expect(plan.expected["sdn_rl"] == snapshot.values["sdn_rl"])
    #expect(plan.service == "restart_wireless;restart_sdn 1;")
}
@Test func sdnEnablePreservesUnknownTailAndMainNetworkVerbatim() throws {
    let snapshot = try networkFixture(); var profile = try #require(snapshot.profiles.first); profile.enabled = false
    let plan = try SDNPlanner.edit(profile, snapshot: snapshot)
    #expect(plan.fields["sdn_rl"]?.hasPrefix("<0>Default>1>0>0>0>0>0>0>0>0>0>0>0>0>0>MAIN-TAIL") == true)
    #expect(plan.fields["sdn_rl"]?.hasSuffix(">FUTURE") == true)
    #expect(plan.fields["apg1_enable"] == "0")
}
@Test func sdnVPNBindingKeepsOtherRulesAndKillSwitch() throws {
    let snapshot = try networkFixture(); var profile = try #require(snapshot.profiles.first); profile.vpn = "2"
    let plan = try SDNPlanner.edit(profile, snapshot: snapshot)
    let rows = try LosslessRuleTable(try #require(plan.fields["sdn_rl"]))
    #expect(rows.rows[1][6] == "2"); #expect(rows.rows[1][7] == "0"); #expect(rows.rows[1][14] == "1")
}
@Test func newSDNAllocatesIndependentIndicesAndKeepsMain() throws {
    let snapshot = try networkFixture(); var profile = try SDNPlanner.newGuest(snapshot: snapshot); profile.password = "guest-secret"
    let plan = try SDNPlanner.create(profile, snapshot: snapshot)
    let table = try LosslessRuleTable(try #require(plan.fields["sdn_rl"]))
    #expect(table.rows.count == 3)
    #expect(table.rows[0].last == "MAIN-TAIL"); #expect(table.rows[1].last == "FUTURE")
    #expect(table.rows[2][0] == "2"); #expect(table.rows[2][3] == "2"); #expect(table.rows[2][4] == "2"); #expect(table.rows[2][5] == "2")
    #expect(plan.fields["apg2_ssid"] == "Guest")
    #expect(plan.fields["apg2_security"]?.contains("<16>sae>aes>guest-secret>2") == true)
}
@Test func deleteSDNIncludesFirmwareDeletionMarkersAndPreservesMain() throws {
    let snapshot = try networkFixture(); let profile = try #require(snapshot.profiles.first)
    let plan = try SDNPlanner.delete(profile, snapshot: snapshot)
    #expect(plan.fields["sdn_rl_x"]?.contains("<1>Guest") == true)
    #expect(plan.fields["vlan_rl_x"] == "<1>52>0>")
    #expect(plan.fields["apg1_enable"] == "0")
    #expect(plan.fields["sdn_rl"]?.hasSuffix("MAIN-TAIL") == true)
    #expect(plan.fields["dhcpres1_rl"] == "")
}
@Test func sdnRejectsInvalidNetworkAndRuleDelimiter() throws {
    let snapshot = try networkFixture(); var p = try #require(snapshot.profiles.first)
    p.ssid = "Invalid>Name"
    #expect(throws: (any Error).self) { try SDNPlanner.edit(p, snapshot: snapshot) }
    p = try #require(snapshot.profiles.first); p.mask = "255.0.255.0"
    #expect(throws: (any Error).self) { try SDNPlanner.edit(p, snapshot: snapshot) }
}
@Test func deviceRenamePreservesOtherDevicesAndFutureColumns() throws {
    let original = "<Old>AA:BB:CC:DD:EE:01>0>2>>keep>group>future<Other>AA:BB:CC:DD:EE:02>0>1>>"
    let renamed = try DeviceConfiguration.renamed(original, mac: "aa:bb:cc:dd:ee:01", name: "My Phone")
    #expect(renamed == original.replacingOccurrences(of: "<Old>", with: "<My Phone>"))
    #expect(throws: (any Error).self) { try DeviceConfiguration.renamed(original, mac: "bad", name: "Phone") }
}

@Test func sdnRejectsBroaderSubnetContainingExistingNarrowerNetwork() throws {
    let original = try networkFixture(); var values = original.values
    values["subnet_rl"]! += "<5>br56>192.168.60.129>255.255.255.128>0>>>>>>0>>"
    let snapshot = try SDNSnapshot(values: values)
    var p = try SDNPlanner.newGuest(snapshot: snapshot); p.password = "guest-secret"; p.address = "192.168.60.1"; p.start = "192.168.60.2"; p.end = "192.168.60.254"
    #expect(throws: (any Error).self) { try SDNPlanner.create(p, snapshot: snapshot) }
}
@Test func sdnEditCannotOverlapMainOrClearIndependentAddress() throws {
    let snapshot = try networkFixture(); var p = try #require(snapshot.profiles.first)
    p.address = "192.168.50.1"; p.start = "192.168.50.2"; p.end = "192.168.50.254"
    #expect(throws: (any Error).self) { try SDNPlanner.edit(p, snapshot: snapshot) }
    p = try #require(snapshot.profiles.first); p.address = ""
    #expect(throws: (any Error).self) { try SDNPlanner.edit(p, snapshot: snapshot) }
    p = try SDNPlanner.newGuest(snapshot: snapshot); p.password = "guest-secret"; p.vlan = ""
    #expect(throws: (any Error).self) { try SDNPlanner.create(p, snapshot: snapshot) }
}
@Test func passwordOnlySDNEditPreservesPerBandSecurity() throws {
    var v = try networkFixture().values
    v["apg1_security"] = "<3>psk2sae>aes>test-password>1<13>psk2>aes+gcmp256>test-password>1<16>sae>gcmp256>test-password>1"
    let snapshot = try SDNSnapshot(values: v); var p = try #require(snapshot.profiles.first); p.password = "new-password"
    let plan = try SDNPlanner.edit(p, snapshot: snapshot)
    #expect(plan.fields["apg1_security"] == v["apg1_security"]!.replacingOccurrences(of: "test-password", with: "new-password"))
}
@Test func sdnCannotEditSharedSubnetOrLoseStaticReservations() throws {
    var v = try networkFixture().values
    v["sdn_rl"]! += "<2>Guest>1>2>1>2>0>0>0>0>0>0>0>0>0>0>0>0>0>WEB>0>0>0"
    v["apg2_security"] = "<3>psk2>aes>test-password>2"
    let snapshot = try SDNSnapshot(values: v); var p = try #require(snapshot.profiles.first); p.lease = "7200"
    #expect(throws: (any Error).self) { try SDNPlanner.edit(p, snapshot: snapshot) }
    v = try networkFixture().values; v["dhcpres1_rl"] = "<AA:BB:CC:DD:EE:03>192.168.52.10>>Printer"
    let reserved = try SDNSnapshot(values: v); p = try #require(reserved.profiles.first); p.address = "192.168.60.1"; p.start = "192.168.60.2"; p.end = "192.168.60.254"
    #expect(throws: (any Error).self) { try SDNPlanner.edit(p, snapshot: reserved) }
}
@Test func sdnDeletionPreservesSharedRadiusRecord() throws {
    var v = try networkFixture().values
    v["sdn_rl"]! += "<2>Guest>1>2>2>2>0>0>0>0>0>0>0>0>0>0>0>0>0>WEB>0>0>0"
    v["apg2_security"] = "<3>psk2>aes>test-password>1"
    v["radius_list"] = "<1>shared-radius-record>future>"
    let snapshot = try SDNSnapshot(values: v); let p = try #require(snapshot.profiles.first)
    let plan = try SDNPlanner.delete(p, snapshot: snapshot)
    #expect(plan.fields["radius_list"] == v["radius_list"])
    #expect(plan.fields["radius_list_x"] == "")
}
