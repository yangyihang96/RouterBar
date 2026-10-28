import Foundation
import Testing
@testable import RouterCore

private actor CatalogMock: RouterTransport {
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
private func client(_ mock: CatalogMock) throws -> RouterClient { RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: mock, writes: .reference) }
private func catalogField(_ section: String, _ key: String) throws -> (SettingSection, SettingField) {
    let s = try #require(SettingsCatalog.sections.first { $0.id == section })
    return (s, try #require(s.fields.first { $0.key == key }))
}
/// The reply lost after dispatch, which ends a save before its readback wait.
private let lost = CatalogMock.Reply.failure(URLError(.networkConnectionLost))

// MARK: Values kept inside list variables

@Test func conntrackTimeoutsAreReadAndSavedInsideTheRouterLists() async throws {
    let (conntrack, established) = try catalogField("conntrack", "tcp_established")
    let (_, assured) = try catalogField("conntrack", "udp_assured")
    #expect(established.packed == PackedSetting(key: "ct_tcp_timeout", index: 1, count: 10))
    let tcp = "0 1200 120 60 120 120 10 60 30 0"
    let stored = #"{"ct_max":"300000","ct_tcp_timeout":"\#(tcp)","ct_udp_timeout":"30 180","http_dut_redir":"1","ipv6_ns_drop":"0","aae_disable_force":"0","dhcpd_send_wpad":"0"}"#
    let reader = CatalogMock([.text(stored), .text(stored)])
    let values = try await client(reader).readSettings(section: conntrack)
    #expect(values["tcp_established"] == "1200"); #expect(values["tcp_last_ack"] == "30")
    #expect(values["udp_unreplied"] == "30"); #expect(values["udp_assured"] == "180"); #expect(values["ct_max"] == "300000")
    // The page inputs do not exist on the router; only the lists are asked for.
    let asked = await reader.requests.compactMap { $0.url?.absoluteString.removingPercentEncoding }.joined()
    #expect(asked.contains("ct_tcp_timeout") && !asked.contains("tcp_established"))

    let writer = CatalogMock([.text(#"{"ct_tcp_timeout":"\#(tcp)","ct_udp_timeout":"30 180"}"#),
                              .text(#"{"modify":"1","run_service":"restart_conntrack"}"#),
                              .text(#"{"ct_tcp_timeout":"0 2400 120 60 120 120 10 60 30 0","ct_udp_timeout":"30 300"}"#)])
    let receipt = try await client(writer).applySettings(section: conntrack, changes: [.init(field: established, before: "1200", after: "2400"),
                                                                                       .init(field: assured, before: "180", after: "300")])
    #expect(receipt.isVerified)
    let post = try #require(await writer.posts.first)
    #expect(post["ct_tcp_timeout"] == "0 2400 120 60 120 120 10 60 30 0"); #expect(post["ct_udp_timeout"] == "30 300")
    #expect(post["tcp_established"] == nil); #expect(post["udp_assured"] == nil); #expect(post["rc_service"] == "restart_conntrack")
}
@Test func aListInAnUnexpectedShapeIsShownEmptyAndNeverRebuilt() async throws {
    let (conntrack, established) = try catalogField("conntrack", "tcp_established")
    let stored = #"{"ct_max":"300000","ct_tcp_timeout":"","ct_udp_timeout":"30 180 5","http_dut_redir":"1","ipv6_ns_drop":"0","aae_disable_force":"0","dhcpd_send_wpad":"0"}"#
    let values = try await client(CatalogMock([.text(stored), .text(stored)])).readSettings(section: conntrack)
    #expect(values["tcp_established"] == ""); #expect(values["udp_assured"] == ""); #expect(values["ct_max"] == "300000")
    let writer = CatalogMock([.text(#"{"ct_tcp_timeout":""}"#)])
    await #expect(throws: RouterError.self) {
        try await client(writer).applySettings(section: conntrack, changes: [.init(field: established, before: "", after: "2400")])
    }
    #expect(await writer.posts.isEmpty)
}

// MARK: Types from the firmware validators

@Test func catalogFieldsCarryTheFirmwareTypes() throws {
    let fields = Dictionary(SettingsCatalog.sections.flatMap(\.fields).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    func field(_ key: String) throws -> SettingField { try #require(fields[key], "\(key)") }
    #expect(fields["sip_server"] == nil)
    try field("dhcp_lease").validate("86400"); #expect(throws: RouterError.self) { try field("dhcp_lease").validate("60") }
    try field("dhcp_start").validate("192.168.50.2"); #expect(throws: RouterError.self) { try field("dhcp_start").validate("192.168.50") }
    try field("wan0_mtu").validate("1500"); #expect(throws: RouterError.self) { try field("wan0_mtu").validate("1600") }
    try field("ipv6_ipaddr").validate("2001:db8::2"); #expect(throws: RouterError.self) { try field("ipv6_ipaddr").validate("192.168.1.2") }
    try field("vpn_server1_sn6").validate("fd00:1::/64"); #expect(throws: RouterError.self) { try field("vpn_server1_sn6").validate("fd00:1::") }
    try field("wan0_hwaddr_x").validate("02:11:22:33:44:55"); try field("wan0_hwaddr_x").validate("")
    #expect(throws: RouterError.self) { try field("wan0_hwaddr_x").validate("01:11:22:33:44:55") }
    for value in ["102400", "102.4"] { try field("qos_obw").validate(value) }
    for value in ["1e3", "-5", "10."] { #expect(throws: RouterError.self) { try field("qos_obw").validate(value) } }
    try field("tm_vol_size").validate("0"); try field("tm_vol_size").validate("512000")
    try field("wl0_user_rssi").validate("0"); try field("wl0_user_rssi").validate("-70")
    #expect(throws: RouterError.self) { try field("wl0_user_rssi").validate("-30") }
    try field("vpn_client1_reneg").validate("-1"); try field("udpxy_enable_x").validate("0")
    #expect(throws: RouterError.self) { try field("udpxy_enable_x").validate("80") }
    try field("log_ipaddr").validate("syslog_box.home.arpa")
    // Coupled or never-submitted controls stay in the router page.
    #expect(try field("wl0_11be").kind == "readonly"); #expect(try field("misc_httpport_x").kind == "readonly")
    #expect(try field("wl1_nmode_x").options.map(\.value) == ["0", "9", "8", "2"])
    #expect(try field("wl0_nmode_x").options.map(\.value) == ["0", "1", "2"])
}
@Test func masksMustBeContiguousAndWithinTheirRange() throws {
    let lan = SettingField(key: "lan_netmask", label: "子网掩码", kind: "netmask")
    for mask in ["255.255.255.0", "255.255.0.0", "255.255.255.252", "0.0.0.0", "255.255.255.255", ""] { try lan.validate(mask) }
    for mask in ["255.0.255.0", "255.255.255.1", "255.255.256.0", "24", "abc"] { #expect(throws: RouterError.self) { try lan.validate(mask) } }
    let (_, vpn) = try catalogField("ovpns1", "vpn_server1_nm")
    for mask in ["255.255.0.0", "255.255.255.0", "255.255.255.248"] { try vpn.validate(mask) }
    for mask in ["255.254.0.0", "255.255.255.252"] { #expect(throws: RouterError.self) { try vpn.validate(mask) } }
    #expect(SettingField.prefixLength(ofMask: "255.255.255.0") == 24); #expect(SettingField.prefixLength(ofMask: "0.0.0.0") == 0)
}
@Test func hostNamesMayCarryUnderscoresInsideALabel() throws {
    let host = SettingField(key: "log_ipaddr", label: "日志服务器", kind: "host")
    for value in ["my_host.example.com", "nas_1", "syslog.home.arpa"] { try host.validate(value) }
    for value in ["_dmarc.example.com", "bad_.example.com", "bad host"] { #expect(throws: RouterError.self) { try host.validate(value) } }
}

// MARK: Rules the router applies around a save

@Test func staticAndTunnelIPv6SaveTheCopiesTheRouterRestoresFrom() async throws {
    let (ipv6, router) = try catalogField("ipv6", "ipv6_rtr_addr")
    let manual = CatalogMock([.text(#"{"ipv6_rtr_addr":"2001:db8:1::1"}"#),
                              .text(#"{"ipv6_service":"other","ipv6_prefix":"","ipv6_prefix_length":"64","ipv6_rtr_addr":"2001:db8:1::1"}"#), lost])
    let receipt = try await client(manual).applySettings(section: ipv6, changes: [.init(field: router, before: "2001:db8:1::1", after: "2001:db8:2::1")])
    #expect(!receipt.isVerified)
    let post = try #require(await manual.posts.first)
    #expect(post["ipv6_rtr_addr"] == "2001:db8:2::1"); #expect(post["ipv6_rtr_addr_s"] == "2001:db8:2::1")
    #expect(post["ipv6_prefix_length_s"] == "64"); #expect(post["ipv6_prefix_s"] == nil)

    let (_, prefix) = try catalogField("ipv6", "ipv6_prefix")
    let tunnel = CatalogMock([.text(#"{"ipv6_prefix":"2001:470:1::"}"#),
                              .text(#"{"ipv6_service":"6in4","ipv6_prefix":"2001:470:1::","ipv6_prefix_length":"48","ipv6_rtr_addr":""}"#), lost])
    _ = try await client(tunnel).applySettings(section: ipv6, changes: [.init(field: prefix, before: "2001:470:1::", after: "2001:470:2::")])
    let tunnelPost = try #require(await tunnel.posts.first)
    #expect(tunnelPost["ipv6_prefix_s"] == "2001:470:2::"); #expect(tunnelPost["ipv6_prefix_length_s"] == "48"); #expect(tunnelPost["ipv6_rtr_addr_s"] == nil)

    let automatic = CatalogMock([.text(#"{"ipv6_rtr_addr":""}"#),
                                 .text(#"{"ipv6_service":"dhcp6","ipv6_prefix":"","ipv6_prefix_length":"64","ipv6_rtr_addr":""}"#), lost])
    _ = try await client(automatic).applySettings(section: ipv6, changes: [.init(field: router, before: "", after: "2001:db8:3::1")])
    #expect(await automatic.posts.first?.keys.contains { $0.hasSuffix("_s") } == false)
}
@Test func wirelessModeStaysAutoWhenTheMainNetworkIsAnSDNProfile() async throws {
    let (radio, mode) = try catalogField("radio1", "wl1_nmode_x")
    let managed = CatalogMock([.text(#"{"get_ui_support":{"sdn_mainfh":1,"mlo":1}}"#)])
    await #expect(throws: RouterError.self) {
        try await client(managed).applySettings(section: radio, changes: [.init(field: mode, before: "0", after: "8")])
    }
    #expect(await managed.posts.isEmpty)
    let classic = CatalogMock([.text(#"{"get_ui_support":{"mlo":1}}"#), .text(#"{"wl1_nmode_x":"0"}"#), lost])
    _ = try await client(classic).applySettings(section: radio, changes: [.init(field: mode, before: "0", after: "8")])
    #expect(await classic.posts.first?["wl1_nmode_x"] == "8")
    // Auto is always offered, so returning to it needs no capability read.
    let back = CatalogMock([.text(#"{"wl1_nmode_x":"8"}"#), lost])
    _ = try await client(back).applySettings(section: radio, changes: [.init(field: mode, before: "8", after: "0")])
    #expect(await back.requests.count == 2)
}
