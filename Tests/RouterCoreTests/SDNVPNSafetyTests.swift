import Foundation
import Testing
@testable import RouterCore

private func snapshot(_ extra: [String: String] = [:]) throws -> SDNSnapshot {
    var values = [
        "sdn_rl":"<0>Default>1>0>0>0>0>0>0>0>0>0>0>0>0>0>MAIN-TAIL<1>Guest>1>1>1>1>0>0>0>0>0>0>0>0>0>0>0>0>0>WEB>0>0>0",
        "subnet_rl":"<1>br52>192.168.52.1>255.255.255.0>1>192.168.52.2>192.168.52.254>86400>>,>>0>>0>0>1>1000>2000>,,>0>1>",
        "vlan_rl":"<1>52>0>", "radius_list":"", "sdn_access_rl":"", "vlan_trunklist":"", "qos_enable":"0", "qos_type":"0", "mld_enable":"0",
        "lan_ipaddr":"192.168.50.1", "lan_netmask":"255.255.255.0", "lan_hwaddr":"AA:BB:CC:DD:EE:01",
        "wan0_ipaddr":"192.168.60.10", "wan0_netmask":"255.255.255.0", "wan1_ipaddr":"", "wan1_netmask":"",
        "apg1_ssid":"Guest", "apg1_enable":"1", "apg1_security":"<3>psk2sae>aes>guest-password>1<13>psk2sae>aes>guest-password>1<16>sae>aes>guest-password>1<96>sae>aes>guest-password>1",
        "apg1_hide_ssid":"0", "apg1_ap_isolate":"1", "apg1_mlo":"0", "apg1_11be":"0", "apg1_dut_list":"<AA:BB:CC:DD:EE:01>3>", "apg1_bw_limit":"<0>>"
    ]
    values.merge(extra) { _, new in new }
    return try SDNSnapshot(values: values)
}

@Test func sdnEditCannotMoveOntoTheWANSubnet() throws {
    let s = try snapshot(); var profile = try #require(s.profiles.first)
    (profile.address, profile.start, profile.end) = ("192.168.60.1", "192.168.60.2", "192.168.60.254")
    #expect(throws: RouterError.self) { try SDNPlanner.edit(profile, snapshot: s) }
    (profile.address, profile.start, profile.end) = ("192.168.61.1", "192.168.61.2", "192.168.61.254")
    #expect(try SDNPlanner.edit(profile, snapshot: s).fields["subnet_rl"]?.contains(">192.168.61.1>") == true)
}
@Test func sdnEditOnATrunkedNetworkRestartsTheWholeLANAndWaitsForIt() throws {
    let plain = try snapshot(); var profile = try #require(plain.profiles.first); profile.ssid = "Guest 2"
    let light = try SDNPlanner.edit(profile, snapshot: plain)
    #expect(light.service == "restart_wireless;restart_sdn 1;"); #expect(light.wait == 15); #expect(!light.restartsWholeNetwork)
    let trunked = try snapshot(["vlan_trunklist": "<1>52>"])
    let heavy = try SDNPlanner.edit(profile, snapshot: trunked)
    #expect(heavy.service == "restart_net_and_phy;"); #expect(heavy.wait == 35); #expect(heavy.restartsWholeNetwork)
}
@Test func sdnPasswordsFollowTheFirmwarePSKRules() throws {
    let s = try snapshot(); var profile = try #require(s.profiles.first)
    // 64 characters pass only as a hexadecimal key (sdn.js valid_psk), so 64 × "z" is refused and 64 × "a" is not.
    for password in ["无线密码无线密码", " leading-space", "trailing-space ", "\"quoted-pass", "short", String(repeating: "z", count: 64), String(repeating: "a", count: 65)] {
        profile.password = password
        #expect(throws: RouterError.self) { try SDNPlanner.edit(profile, snapshot: s) }
    }
    profile.password = "new guest pass!"
    #expect(try SDNPlanner.edit(profile, snapshot: s).fields["apg1_security"]?.contains(">new guest pass!>") == true)
}
@Test func wpa2NeverPairsWithGCMP256() throws {
    var s = try snapshot(); var profile = try #require(s.profiles.first)
    // The SDN page offers GCMP-256 only as AES + GCMP-256 and only with WiFi7 模式 on (sdn.js handle_wifi_crypto).
    for (auth, crypto) in [("psk2", "gcmp256"), ("psk2", "aes+gcmp256"), ("psk2sae", "gcmp256"), ("psk2sae", "aes+gcmp256"), ("sae", "gcmp256")] {
        (profile.auth, profile.crypto) = (auth, crypto)
        #expect(throws: RouterError.self) { try SDNPlanner.edit(profile, snapshot: s) }
    }
    for (auth, crypto) in [("sae", "aes"), ("psk2", "aes")] {
        (profile.auth, profile.crypto) = (auth, crypto)
        _ = try SDNPlanner.edit(profile, snapshot: s)
    }
    s.wifi7Supported = true
    (profile.auth, profile.crypto, profile.wifi7) = ("psk2sae", "aes+gcmp256", true)
    _ = try SDNPlanner.edit(profile, snapshot: s)
    #expect(throws: RouterError.self) { try WirelessSecurityRules.validate(auth: "sae", crypto: "tkip+aes", key: "guest-password") }
    #expect(throws: RouterError.self) { try WirelessSecurityRules.validate(auth: "psk2", crypto: "aes", key: "") }
    try WirelessSecurityRules.validate(auth: "psk2", crypto: "tkip+aes", key: "guest-password")
    try WirelessSecurityRules.validate(auth: "open", crypto: "gcmp256", key: "")
    try WirelessSecurityRules.validate(auth: "wpa2", crypto: "aes", key: "")
}
@Test func wirelessPassphraseFieldUsesTheFirmwareRules() throws {
    let field = try #require(SettingsCatalog.sections.first { $0.id == "wifi0" }?.fields.first { $0.key == "wl0_wpa_psk" })
    try field.validate("home network 2024"); try field.validate(String(repeating: "a1", count: 32))
    for value in ["无线密码无线密码", " padded-key", "padded-key ", "\"quoted\"key", String(repeating: "g", count: 64)] {
        #expect(throws: RouterError.self) { try field.validate(value) }
    }
}

@Test func vpnDirectorRulesFollowTheRouterPage() throws {
    let field = try #require(SettingsCatalog.sections.first { $0.id == "vpndirector" }?.fields.first { $0.key == "vpndirector_rulelist" })
    try field.validate("<1>Feeder>192.168.50.30>>OVPN1<0>Robot vacuum>192.168.50.0/24>8.8.8.8>WAN<1>Lab>>10.0.0.0/8>WGC2")
    try field.validate("")
    let invalid = ["<>>>>", "<2>Feeder>192.168.50.30>>OVPN1", "<1>Feeder's>192.168.50.30>>OVPN1", "<1>100%>192.168.50.30>>OVPN1",
                   "<1>Feeder>192.168.50.300>>OVPN1", "<1>Feeder>>10.0.0.0/33>OVPN1", "<1>Feeder>192.168.50.30>>OVPN6",
                   "<1>Feeder>192.168.50.30>>wan", "<1>Feeder>fd00::1>>WAN", "<1>\(String(repeating: "x", count: 33))>>>WAN",
                   "<1>Feeder>10.0.0.0/+8>>WAN", "<1>Feeder>10.0.0.0/>>WAN"]
    for value in invalid { #expect(throws: RouterError.self) { try field.validate(value) } }
    let many = String(repeating: "<1>Feeder>192.168.50.30>>OVPN1", count: 201)
    #expect(throws: RouterError.self) { try field.validate(many) }
    // Each row is 79 characters: 101 rows fit the page's 7999-character limit, 102 do not.
    let row = "<1>\(String(repeating: "d", count: 32))>192.168.150.130/32>192.168.150.130/32>OVPN1"
    try field.validate(String(repeating: row, count: 101))
    #expect(throws: RouterError.self) { try field.validate(String(repeating: row, count: 102)) }
}
@Test func emptyRulesAreRejectedInEveryList() throws {
    let field = try #require(SettingsCatalog.sections.first { $0.id == "dhcp" }?.fields.first { $0.key == "dhcp_staticlist" })
    try field.validate("<AA:BB:CC:DD:EE:01>192.168.50.20>>printer")
    #expect(throws: RouterError.self) { try field.validate("<AA:BB:CC:DD:EE:01>192.168.50.20>>printer<>>>") }
}

@Test func privateFilesAreNeverReadableByOthers() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("client.conf")
    try Data("old".utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    try PrivateFile.write(Data("[Interface]\nPrivateKey = secret\n".utf8), to: file)
    #expect(try String(contentsOf: file, encoding: .utf8) == "[Interface]\nPrivateKey = secret\n")
    #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["client.conf"])
    #expect(throws: (any Error).self) { try PrivateFile.write(Data("x".utf8), to: directory.appendingPathComponent("missing/inner.conf")) }
}
