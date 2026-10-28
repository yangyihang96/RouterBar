import Foundation
import Testing
@testable import RouterCore

private actor VPNMock: RouterTransport {
    var replies: [String]
    var requests: [URLRequest] = []
    init(_ replies: [String]) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> RouterHTTPResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw RouterError.network("No mock response") }
        return RouterHTTPResponse(data: Data(replies.removeFirst().utf8), status: 200)
    }
    nonisolated func cancel() {}
}
private func client(_ mock: VPNMock) throws -> RouterClient { RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: mock, writes: .reference) }
private func json(_ object: [String: Any]) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self) }
private func hook(_ instance: VPNInstance, _ values: [OpenVPNKeyField: String], decoy: Int? = nil) -> String {
    guard let prefix = instance.keyPrefix else { return "{}" }
    let name = prefix.hasPrefix("vpn_crt_client") ? "vpn_crt_client" : "vpn_crt_server"
    var table: [String: Any] = ["end": [""]]
    for field in instance.keyFields { table[prefix + field.rawValue] = [values[field] ?? ""] }
    if let decoy { for field in instance.keyFields { table["\(name)\(decoy)_\(field.rawValue)"] = ["DECOY"] } }
    return json([name: table])
}
private func postedFields(_ request: URLRequest) throws -> [String: String] {
    let raw = String(decoding: try #require(request.httpBody), as: UTF8.self)
    let decoded = try #require(raw.removingPercentEncoding)
    return try #require(try JSONSerialization.jsonObject(with: Data(decoded.utf8)) as? [String: String])
}
private func tempFile(_ ext: String, _ contents: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
    try Data(contents.utf8).write(to: url)
    return url
}
private let pem = "-----BEGIN CERTIFICATE-----\nMIIB1\n-----END CERTIFICATE-----\n"

@Test func sectionIdentifiersMapOnlyToSupportedUnits() {
    #expect(VPNInstance(sectionID: "ovpn5") == .openVPNClient(5))
    #expect(VPNInstance(sectionID: "ovpns2") == .openVPNServer(2))
    #expect(VPNInstance(sectionID: "wgc1") == .wireGuardClient(1))
    #expect(VPNInstance(sectionID: "wgs1") == .wireGuardServer)
    for id in ["ovpn0", "ovpn6", "ovpns3", "wgc6", "wgs2", "ovpn01", "ovpn1x", "wan0"] { #expect(VPNInstance(sectionID: id) == nil) }
    for id in (1...5).map({ "ovpn\($0)" }) + ["ovpns1", "ovpns2"] + (1...5).map({ "wgc\($0)" }) + ["wgs1"] {
        #expect(VPNInstance(sectionID: id)?.id == id)
    }
    #expect(VPNInstance.openVPNServer(1).keyFields.contains(.dh))
    #expect(!VPNInstance.openVPNClient(1).keyFields.contains(.dh))
}

@Test func keyEntityDecodingMatchesUnterminatedFirmwareEscapes() throws {
    #expect(try VPNFileRules.decodeKeyEntities("-----BEGIN&#10MII&#101") == "-----BEGIN\nMII\n1")
    #expect(try VPNFileRules.decodeKeyEntities("a&#13&#10b&#38&#34&#60&#62") == "a\r\nb&\"<>")
    #expect(try VPNFileRules.decodeKeyEntities("x&#130") == "x\r0")
    #expect(try VPNFileRules.decodeKeyEntities("&#-61&#-87") == "é")
    #expect(throws: (any Error).self) { try VPNFileRules.decodeKeyEntities("a&b") }
    #expect(throws: (any Error).self) { try VPNFileRules.decodeKeyEntities("a&#x") }
    #expect(try VPNFileRules.decodeKeyEntities("&#99") == "\t9")
}

@Test func keyMaterialUsesRequestedUnitAndFailsClosedOnUnknownNames() async throws {
    let instance = VPNInstance.openVPNClient(2)
    let mock = VPNMock([hook(instance, [.ca: "-----BEGIN CERTIFICATE-----&#10AB&#10-----END CERTIFICATE-----"], decoy: 1), json(["vpn_crt_client": ["vpn_crt_client_ca": ["x"]]])])
    let c = try client(mock)
    let keys = try await c.vpnKeyMaterial(instance)
    #expect(keys[.ca] == "-----BEGIN CERTIFICATE-----\nAB\n-----END CERTIFICATE-----")
    #expect(keys[.key] == "")
    let url = try #require(await mock.requests.first?.url?.absoluteString)
    #expect(url.contains("appGet.cgi")); #expect(url.contains("vpn_crt_client()"))
    await #expect(throws: (any Error).self) { try await c.vpnKeyMaterial(instance) }
}

@Test func keySavePostsIndexedFieldWithoutUnitSelectionAndVerifiesReadback() async throws {
    let instance = VPNInstance.openVPNClient(2)
    let mock = VPNMock([hook(instance, [.ca: "old"]), json(["vpn_client2_state": "0"]), json(["modify": "1"]), hook(instance, [.ca: pem.replacingOccurrences(of: "\n", with: "&#10")])])
    let receipt = try await client(mock).saveVPNKey(instance, field: .ca, before: "old", after: pem, settle: .zero)
    #expect(receipt.verified)
    let requests = await mock.requests
    #expect(requests.map(\.httpMethod) == ["GET", "GET", "POST", "GET"])
    #expect(requests[2].url?.path == "/applyapp.cgi")
    #expect(try postedFields(requests[2]) == ["action_mode": "apply", "vpn_crt_client2_ca": pem])
}

@Test func keySaveRestartsOnlyRunningInstanceAndReportsMismatch() async throws {
    let instance = VPNInstance.openVPNServer(1)
    let mock = VPNMock([hook(instance, [:]), json(["vpn_server1_state": "2"]), json(["modify": "1", "run_service": "restart_vpnserver1"]), hook(instance, [:])])
    let receipt = try await client(mock).saveVPNKey(instance, field: .dh, before: "", after: pem, settle: .zero)
    #expect(!receipt.verified)
    let fields = try postedFields(await mock.requests[2])
    #expect(fields["rc_service"] == "restart_vpnserver1"); #expect(fields["vpn_crt_server1_dh"] == pem)
    #expect(fields["vpn_server_unit"] == nil)
}

@Test func keySaveRejectsStaleOrInvalidContentWithoutPosting() async throws {
    let instance = VPNInstance.openVPNClient(1)
    let mock = VPNMock([hook(instance, [.ca: "changed elsewhere"])])
    let c = try client(mock)
    await #expect(throws: (any Error).self) { try await c.saveVPNKey(instance, field: .ca, before: "old", after: pem, settle: .zero) }
    await #expect(throws: (any Error).self) { try await c.saveVPNKey(instance, field: .key, before: "", after: "密钥", settle: .zero) }
    await #expect(throws: (any Error).self) { try await c.saveVPNKey(instance, field: .extra, before: "", after: String(repeating: "A", count: 8_000), settle: .zero) }
    await #expect(throws: (any Error).self) { try await c.saveVPNKey(instance, field: .dh, before: "", after: pem, settle: .zero) }
    #expect(await mock.requests.allSatisfy { $0.httpMethod == "GET" })
    #expect(await mock.requests.count == 1)
}

@Test func openVPNImportSendsOnlyFormFieldsBeforeFileAndReadsUploadState() async throws {
    let file = try tempFile("ovpn", "client\nremote vpn.example.com 1194\n")
    defer { try? FileManager.default.removeItem(at: file) }
    let mock = VPNMock([json(["vpn_upload_state": "err"]), "", json(["vpn_upload_state": "0", "vpn_upload_type": "ovpn", "vpn_upload_unit": "3"])])
    let outcome = try await client(mock).importOpenVPNClientConfiguration(unit: 3, file: file)
    #expect(outcome == .complete)
    let requests = await mock.requests
    #expect(requests.count == 3); #expect(requests[1].url?.path == "/vpnupload.cgi")
    let body = String(decoding: try #require(requests[1].httpBody), as: UTF8.self)
    #expect(body.components(separatedBy: "Content-Disposition").count == 4)
    let type = try #require(body.range(of: "name=\"vpn_upload_type\"\r\n\r\novpn\r\n"))
    let unit = try #require(body.range(of: "name=\"vpn_upload_unit\"\r\n\r\n3\r\n"))
    let filePart = try #require(body.range(of: "name=\"file\"; filename="))
    #expect(type.lowerBound < filePart.lowerBound); #expect(unit.lowerBound < filePart.lowerBound)
    #expect(body.contains("remote vpn.example.com 1194"))
}

@Test func wireGuardImportUsesSourceFieldName() async throws {
    let file = try tempFile("conf", "[Interface]\nPrivateKey = a\nAddress = 10.0.0.2/32\n[Peer]\nPublicKey = b\nEndpoint = 203.0.113.1:51820\n")
    defer { try? FileManager.default.removeItem(at: file) }
    let mock = VPNMock([json(["wgc_upload_state": "0"]), "", json(["wgc_upload_state": "0", "wgc_upload_unit": "4"])])
    let outcome = try await client(mock).importWireGuardClientConfiguration(unit: 4, file: file)
    if case .unconfirmed = outcome {} else { Issue.record("Unchanged state must not be reported as success") }
    let request = await mock.requests[1]
    #expect(request.url?.path == "/upload_wgc_config.cgi")
    let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
    #expect(body.contains("name=\"wgc_upload_unit\"\r\n\r\n4\r\n")); #expect(!body.contains("vpn_upload"))
}

@Test func importOutcomeNeverTurnsStaleOrForeignStateIntoSuccess() {
    let echo = ["vpn_upload_type": "ovpn", "vpn_upload_unit": "1"]
    func after(_ state: String, unit: String = "1") -> [String: String] { ["vpn_upload_state": state, "vpn_upload_type": "ovpn", "vpn_upload_unit": unit] }
    #expect(RouterClient.importOutcome(before: "err", after: after("0"), stateKey: "vpn_upload_state", echo: echo) == .complete)
    #expect(RouterClient.importOutcome(before: "0", after: after("12"), stateKey: "vpn_upload_state", echo: echo) == .incomplete(state: "12"))
    #expect(RouterClient.importOutcome(before: "0", after: after("err"), stateKey: "vpn_upload_state", echo: echo) == .rejected)
    for (before, result) in [("0", after("0")), ("err", after("err")), ("err", after("0", unit: "2")), ("0", after("x"))] {
        if case .unconfirmed = RouterClient.importOutcome(before: before, after: result, stateKey: "vpn_upload_state", echo: echo) {} else { Issue.record("Expected unconfirmed for \(before) → \(result)") }
    }
}

@Test func invalidImportFilesAreRejectedBeforeAnyRequest() async throws {
    let wrongExt = try tempFile("txt", "remote a 1\n")
    let noRemote = try tempFile("ovpn", "client\n")
    let noPeer = try tempFile("conf", "[Interface]\nPrivateKey = a\n")
    defer { for url in [wrongExt, noRemote, noPeer] { try? FileManager.default.removeItem(at: url) } }
    let mock = VPNMock([]); let c = try client(mock)
    await #expect(throws: (any Error).self) { try await c.importOpenVPNClientConfiguration(unit: 1, file: wrongExt) }
    await #expect(throws: (any Error).self) { try await c.importOpenVPNClientConfiguration(unit: 1, file: noRemote) }
    await #expect(throws: (any Error).self) { try await c.importOpenVPNClientConfiguration(unit: 6, file: noRemote) }
    await #expect(throws: (any Error).self) { try await c.importWireGuardClientConfiguration(unit: 1, file: noPeer) }
    #expect(await mock.requests.isEmpty)
}

private let redirect = "<html><head>\r\n<script>parent.location.href='/Advanced_WireguardServer_Content.asp';</script>\n</head></html>"
private let peerConf = "[Interface]\nPrivateKey = a\nAddress = 10.6.0.2/32\n\n[Peer]\nPublicKey = b\nEndpoint = 203.0.113.1:51820\n"

@Test func wireGuardPeerExportTargetsVerifiedUnitAndRestoresSelection() async throws {
    let mock = VPNMock([json(["wgs1_c2_enable": "1", "wgs_unit": "1", "wgsc_unit": "1"]), redirect,
                        json(["wgs_unit": "1", "wgsc_unit": "2"]), peerConf, json(["wgs_unit": "1", "wgsc_unit": "2"]), redirect])
    let export = try await client(mock).exportWireGuardServerPeer(2)
    #expect(String(decoding: export.data, as: UTF8.self) == peerConf); #expect(export.suggestedName == "wgs1_client2.conf")
    let requests = await mock.requests
    #expect(requests.count == 6)
    #expect(try postedFields(requests[1]) == ["action_mode": "chg_wgsc_unit", "wgsc_unit": "2", "current_page": "Advanced_WireguardServer_Content.asp"])
    #expect(requests[3].url?.path == "/wgs_client.conf")
    #expect(try postedFields(requests[5])["wgsc_unit"] == "1")
}

@Test func wireGuardPeerExportAbortsWhenSelectionIsNotConfirmed() async throws {
    let mock = VPNMock([json(["wgs1_c3_enable": "1", "wgs_unit": "1", "wgsc_unit": "1"]), redirect, json(["wgs_unit": "1", "wgsc_unit": "1"]), redirect])
    let c = try client(mock)
    await #expect(throws: (any Error).self) { try await c.exportWireGuardServerPeer(3) }
    let requests = await mock.requests
    #expect(!requests.contains { $0.url?.path == "/wgs_client.conf" })
    #expect(try postedFields(requests[3])["wgsc_unit"] == "1")
    let disabled = VPNMock([json(["wgs1_c4_enable": "0", "wgs_unit": "1", "wgsc_unit": "1"])])
    await #expect(throws: (any Error).self) { try await client(disabled).exportWireGuardServerPeer(4) }
    #expect(await disabled.requests.count == 1)
}

@Test func wireGuardPeerExportRejectsNonConfigurationResponses() async throws {
    let mock = VPNMock([json(["wgs1_c1_enable": "1", "wgs_unit": "1", "wgsc_unit": "1"]), json(["wgs_unit": "1", "wgsc_unit": "1"]), "", json(["wgs_unit": "1", "wgsc_unit": "1"])])
    await #expect(throws: (any Error).self) { try await client(mock).exportWireGuardServerPeer(1) }
    #expect(await mock.requests.filter { $0.httpMethod == "POST" }.isEmpty)
}

@Test func openVPNServerExportUsesExplicitNumberInFilePath() async throws {
    let transport = VPNMock([json(["vpn_server2_state":"2"]), "client\nremote vpn.example.com 1194\n"])
    let data = try await client(transport).exportOpenVPNServerConfiguration(unit: 2)
    #expect(String(decoding: data, as: UTF8.self).contains("remote vpn.example.com"))
    let requests = await transport.requests
    #expect(requests.last?.url?.path == "/client2.ovpn")
    #expect(requests.allSatisfy { $0.httpMethod == "GET" })
}
@Test func openVPNStartupChangesPreserveOtherInstances() async throws {
    let transport = VPNMock([json(["vpn_clientx_eas":"1,3,"]), json(["modify":"1"]), json(["vpn_clientx_eas":"1,2,3,"])])
    #expect(try await client(transport).setOpenVPNStartup(.openVPNClient(2), before: "1,3,", enabled: true))
    let request = try #require(await transport.requests.first { $0.httpMethod == "POST" })
    #expect(try postedFields(request) == ["action_mode":"apply", "vpn_clientx_eas":"1,2,3,"])
}

@Test func wireGuardAllowedRangesRejectMalformedAndInjectionStrings() throws {
    try IPRangeValidation.validate("10.6.0.2/32,::/0")
    try IPRangeValidation.validate("0.0.0.0/0")
    for value in ["", "10.0.0.1/33", "::/129", "10.0.0.1;reboot", "10.0.0.2,", "x/y"] {
        #expect(throws: (any Error).self) { try IPRangeValidation.validate(value) }
    }
}

@Test func byteOrderMarkedConfigurationImportsUnchanged() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ovpn")
    try (Data([0xEF, 0xBB, 0xBF]) + Data("client\nremote vpn.example.com 1194\n".utf8)).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let mock = VPNMock([json(["vpn_upload_state": "err"]), "", json(["vpn_upload_state": "0", "vpn_upload_type": "ovpn", "vpn_upload_unit": "2"])])
    #expect(try await client(mock).importOpenVPNClientConfiguration(unit: 2, file: file) == .complete)
    // The router receives the file byte for byte, mark included, exactly as its own web page would send it.
    let body = try #require(await mock.requests[1].httpBody)
    #expect(body.range(of: Data([0xEF, 0xBB, 0xBF]) + Data("client".utf8)) != nil)
}
