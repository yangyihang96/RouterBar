import Foundation
import Testing
@testable import RouterCore

private actor NativeMock: RouterTransport {
    var replies: [Result<String, RouterError>]
    var requests: [URLRequest] = []
    var delayFirst: Bool
    init(_ replies: [Result<String, RouterError>], delayFirst: Bool = false) { self.replies = replies; self.delayFirst = delayFirst }
    func send(_ request: URLRequest) async throws -> RouterHTTPResponse {
        requests.append(request)
        if delayFirst && requests.count == 1 { try await Task.sleep(for: .milliseconds(250)) }
        guard !replies.isEmpty else { throw RouterError.network("No mock response") }
        return try RouterHTTPResponse(data: Data(replies.removeFirst().get().utf8), status: 200)
    }
    nonisolated func cancel() {}
}
private func section(_ id: String) throws -> SettingSection { try #require(SettingsCatalog.sections.first { $0.id == id }) }
private func client(_ mock: NativeMock) throws -> RouterClient { RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: mock, writes: .reference) }

@Test func catalogContainsOnlyStructuredFieldsAndSourceBackedServices() throws {
    #expect(SettingsCatalog.sections.count >= 51)
    let reserved: Set<String> = ["action_mode", "action_script", "rc_service", "wan_unit", "wl_unit", "wgc_unit", "current_page"]
    #expect(Set(SettingsCatalog.sections.map(\.id)).count == SettingsCatalog.sections.count)
    for section in SettingsCatalog.sections {
        #expect(!section.fields.isEmpty)
        #expect(Set(section.fields.map(\.key)).count == section.fields.count)
        #expect(section.source.hasSuffix(".asp"))
        for field in section.fields {
            #expect(!reserved.contains(field.key))
            #expect(field.key.range(of: #"^[A-Za-z][A-Za-z0-9_.]{0,79}$"#, options: .regularExpression) != nil)
            #expect(field.kind != "rules" || !field.columns.isEmpty)
            #expect(Set(field.options.map(\.value)).count == field.options.count)
        }
    }
}
@Test func catalogSavesTheVariablesTheRouterPagesSubmit() throws {
    let fields = Dictionary(SettingsCatalog.sections.flatMap(\.fields).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    // Page-only controls: the router page converts them before saving, and httpd ignores them if posted.
    for helper in ["shell_timeout_x", "reboot_schedule_enable_x", "time_zone_select", "dst_start_m", "dst_end_h"] { #expect(fields[helper] == nil) }
    let timeout = try #require(fields["shell_timeout"])
    try timeout.validate("0"); try timeout.validate("1200")
    #expect(throws: RouterError.self) { try timeout.validate("20") }
    #expect(fields["reboot_schedule_enable"]?.kind == "toggle")
    // applyRule() turns time_zone_select and the dst_* selects into these three variables.
    #expect(fields["time_zone"]?.kind == "timeZone"); #expect(fields["time_zone_dst"]?.kind == "toggle"); #expect(fields["time_zone_dstoff"]?.kind == "dstRule")
    let logout = try #require(fields["http_autologout"])
    try logout.validate("0"); try logout.validate("30")
    #expect(throws: RouterError.self) { try logout.validate("5") }
    let schedule = try #require(fields["reboot_schedule"])
    try schedule.validate("01000000330")
    #expect(throws: RouterError.self) { try schedule.validate("01000002460") }
}
@Test func nativeReadsUsePercentEncodedAsciiHooksWithoutLosingUnicodeOrDelimiters() async throws {
    let mock = NativeMock([.success(#"{"wl0_ssid":"%E6%88%91%E7%9A%84%20WiFi%26%25","vpndirector_rulelist":"%3C1%3EHome%3E192.168.50.2%3E%3EWAN"}"#)])
    let result = try await client(mock).readSettings(["wl0_ssid", "vpndirector_rulelist"])
    #expect(result["wl0_ssid"] == "我的 WiFi&%")
    #expect(result["vpndirector_rulelist"] == "<1>Home>192.168.50.2>>WAN")
    let request = try #require(await mock.requests.first)
    #expect(request.url!.absoluteString.contains("%3B"))
    #expect(request.url!.absoluteString.contains("nvram_char_to_ascii"))
}
@Test func missingSettingsAndInjectedHooksAreRejected() async throws {
    let mock = NativeMock([.success("{}"), .success("{}")]); let c = try client(mock)
    await #expect(throws: (any Error).self) { try await c.readSettings(["wl0_ssid"]) }
    await #expect(throws: (any Error).self) { try await c.readSettings(["a);reboot()"] ) }
    #expect(await mock.requests.count == 2)
}
@Test func saveRejectsStaleConfigurationWithoutPosting() async throws {
    let mock = NativeMock([.success(#"{"firmware_check_enable":"1"}"#)])
    let s = try section("updates"); let field = try #require(s.fields.first)
    await #expect(throws: (any Error).self) { try await client(mock).applySettings(section: s, changes: [.init(field: field, before: "0", after: "1")]) }
    #expect(await mock.requests.allSatisfy { $0.httpMethod == "GET" })
}
@Test func saveUsesJsonUrlEncodingAndVerifiesReadback() async throws {
    let mock = NativeMock([.success(#"{"firmware_check_enable":"0"}"#), .success(#"{"modify":1}"#), .success(#"{"firmware_check_enable":"1"}"#)])
    let s = try section("updates"); let field = try #require(s.fields.first)
    let receipt = try await client(mock).applySettings(section: s, changes: [.init(field: field, before: "0", after: "1")])
    #expect(receipt.isVerified)
    let requests = await mock.requests
    #expect(requests.map(\.httpMethod) == ["GET", "POST", "GET"])
    let raw = String(decoding: try #require(requests[1].httpBody), as: UTF8.self)
    #expect(raw.hasPrefix("%7B"))
    let object = try JSONSerialization.jsonObject(with: Data(try #require(raw.removingPercentEncoding).utf8)) as? [String: String]
    #expect(object == ["action_mode": "apply", "firmware_check_enable": "1"])
    #expect(requests[1].url!.path == "/applyapp.cgi")
}
@Test func saveResponseDoesNotProveChangedSettings() async throws {
    let mock = NativeMock([.success(#"{"firmware_check_enable":"0"}"#), .success(#"{"modify":"0"}"#), .success(#"{"firmware_check_enable":"0"}"#)])
    let s = try section("updates"); let f = try #require(s.fields.first)
    let receipt = try await client(mock).applySettings(section: s, changes: [.init(field: f, before: "0", after: "1")])
    #expect(!receipt.isVerified); #expect(receipt.unverified == [f.key])
}
@Test func uncertainPostIsNeverRetriedOrClaimedSuccessful() async throws {
    let mock = NativeMock([.success(#"{"firmware_check_enable":"0"}"#), .failure(.submissionUncertain("Disconnected after send"))])
    let s = try section("updates"); let f = try #require(s.fields.first)
    let receipt = try await client(mock).applySettings(section: s, changes: [.init(field: f, before: "0", after: "1")])
    #expect(!receipt.isVerified); #expect(await mock.requests.count == 2)
}
@Test func concurrentMutationIsRejectedBeforeDispatch() async throws {
    let mock = NativeMock([.success(#"{"firmware_check_enable":"0"}"#), .success(#"{"modify":"1"}"#), .success(#"{"firmware_check_enable":"1"}"#)], delayFirst: true)
    let c = try client(mock); let s = try section("updates"); let f = try #require(s.fields.first)
    let first = Task { try await c.applySettings(section: s, changes: [.init(field: f, before: "0", after: "1")]) }
    while await mock.requests.isEmpty { await Task.yield() }
    await #expect(throws: (any Error).self) { try await c.reboot() }
    _ = try await first.value
    #expect(await mock.requests.filter { $0.httpMethod == "POST" }.count == 1)
}
@Test func ruleCodecPreservesEmptyColumnsAndRejectsUnknownSchema() throws {
    let source = "<1>Device>192.168.50.2>>OVPN1<0>Other>>203.0.113.0/24>WAN"
    let rows = try RouterRuleCodec.decode(source, columns: 5)
    #expect(try RouterRuleCodec.encode(rows, columns: 5) == source)
    #expect(throws: (any Error).self) { try RouterRuleCodec.decode(source, columns: 4) }
    #expect(throws: (any Error).self) { try RouterRuleCodec.encode([["one\nnext"]], columns: 1) }
    #expect(throws: (any Error).self) { try RouterRuleCodec.encode([["a>b"]], columns: 1) }
}

@Test func encryptedDNSCannotBeEnabledWithoutAServer() async throws {
    let mock = NativeMock([.success(#"{"dnspriv_enable":"0","dnspriv_rulelist":""}"#)])
    let s = try section("dns"); let f = try #require(s.fields.first { $0.key == "dnspriv_enable" })
    await #expect(throws: (any Error).self) { try await client(mock).applySettings(section: s, changes: [.init(field: f, before: "0", after: "1")]) }
    #expect(await mock.requests.allSatisfy { $0.httpMethod == "GET" })
    #expect(s.service == "restart_stubby;restart_dnsmasq")
}

@Test func backupFormatRejectsHTMLAndTruncationAndAcceptsAppendedJFFS() throws {
    let valid = Data(Array("HDR2".utf8) + [4, 0, 0, 9, 1, 2, 3, 4])
    try ConfigurationBackup.validate(valid)
    try ConfigurationBackup.validate(valid + Data([5, 6, 7]))
    #expect(throws: (any Error).self) { try ConfigurationBackup.validate(Data(valid.dropLast())) }
    #expect(throws: (any Error).self) { try ConfigurationBackup.validate(Data("<html>Login</html>".utf8)) }
    #expect(ConfigurationBackup.restoreReply(Data("<script>alert('invalid')</script>".utf8)) == .rejected)
    #expect(ConfigurationBackup.restoreReply(Data("parent.showLoadingBar(90);setTimeout('parent.detect_httpd();',90000)".utf8)) == .accepted)
    #expect(ConfigurationBackup.restoreReply(Data("<html></html>".utf8)) == .unrecognized)
}
@Test func nativeFieldValidationRejectsInvalidAddressAndWeakKey() throws {
    let lan = try #require(section("lan").fields.first { $0.key == "lan_ipaddr" })
    #expect(throws: (any Error).self) { try lan.validate("999.1.1.1") }
    let password = try #require(section("wifi0").fields.first { $0.key == "wl0_wpa_psk" })
    #expect(throws: (any Error).self) { try password.validate("short") }
    try password.validate("local-test-password")
    #expect(throws: (any Error).self) { try password.validate("test\npass") }
}
@Test func firmwareParserUsesObservedBOMResponseAndNeverExecutesScript() throws {
    let fixture = "\u{FEFF}webs_state_update = '1';\nwebs_state_error = '0';\nwebs_state_info = '3006_102_9_0';\nwebs_state_flag = '1';\nif(cfg_sync_support){\ncfg_check = '';\ncfg_upgrade = '';\n}\nmalicious();"
    let state = try FirmwareState.parse(fixture)
    #expect(state.latest == "3006.102.9.0"); #expect(state.available); #expect(!state.checking); #expect(!state.installing)
    #expect(state.progress == nil); #expect(state.error == nil)
    #expect(throws: (any Error).self) { try FirmwareState.parse("malicious();") }
}
@Test func firmwareErrorsDoNotBecomeLatestOrInstalled() throws {
    let state = try FirmwareState.parse("var webs_state_update='1';\nwebs_state_error='3';\nwebs_state_info='';\nwebs_state_flag='0';")
    #expect(state.error != nil); #expect(!state.available); #expect(!state.installing)
}
@Test func multipartSnapshotsFileAndHasPrivatePermissions() throws {
    let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")
    try Data("firmware-content".utf8).write(to: input)
    defer { try? FileManager.default.removeItem(at: input) }
    let multipart = try MultipartUpload.create(file: input, field: "file", fields: ["current_page": "Advanced_FirmwareUpgrade_Content.asp"])
    defer { try? FileManager.default.removeItem(at: multipart.file) }
    try Data("different-file".utf8).write(to: input)
    let body = String(decoding: try Data(contentsOf: multipart.file), as: UTF8.self)
    #expect(body.contains("firmware-content")); #expect(!body.contains("different-file"))
    #expect(body.contains("name=\"file\"; filename=")); #expect(multipart.sha256.count == 64)
    #expect((try FileManager.default.attributesOfItem(atPath: multipart.file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}
@Test func diagnosticTargetsRejectCommandInjectionWithoutNetworkRequest() async throws {
    let mock = NativeMock([]); let c = try client(mock)
    for host in ["-x", "example.com;reboot", "a\nb", "$(id)", "x && y"] {
        await #expect(throws: (any Error).self) { try await c.startDiagnostic(method: "3", host: host, version: "v4") }
    }
    #expect(await mock.requests.isEmpty)
}

@Test func legacyScalarReadsOnlyTheCheckedNamedControl() {
    let html = #"<script>evil();</script><input name="other" value="1" checked><input type="radio" name="jffs2_scripts" value="1" checked="checked"><input type="radio" name="jffs2_scripts" value="0">"#
    #expect(NativeLegacyScalar.checkedRadio(named: "jffs2_scripts", in: html) == "1")
    #expect(NativeLegacyScalar.checkedRadio(named: "http_passwd", in: html) == nil)
    #expect(NativeLegacyScalar.checkedRadio(named: "jffs2_scripts", in: "<script>location='Main_Login.asp'</script>") == nil)
}

@Test func diagnosticArrayParserPreservesBracketsInsideStringsAndDoesNotExecuteCode() throws {
    let source = #"var connarray = Array(); var connarray = [["a]b", "quoted\"value"],[]]; evil();"#
    #expect(try RouterParser.stringRows(named: "connarray", in: source) == [["a]b", "quoted\"value"]])
    #expect(throws: (any Error).self) { try RouterParser.stringRows(named: "connarray", in: "connarray = [run()]") }
}

@Test func administratorProtocolHashesCurrentCredentialsAndKeepsNewValueOutOfURL() throws {
    let fields = try AdministratorProtocol.fields(username: "admin", currentPassword: "current-secret", change: .password("new-test-password"))
    #expect(fields["cur_username"] == "21232f297a57a5a743894a0e4a801fc3")
    #expect(fields["cur_passwd"]?.count == 32)
    #expect(!fields.values.contains("current-secret"))
    #expect(fields["new_passwd"] == Data("new-test-password".utf8).base64EncodedString())
    #expect(throws: (any Error).self) { try AdministratorProtocol.fields(username: "admin", currentPassword: "current-secret", change: .username("root")) }
    #expect(throws: (any Error).self) { try AdministratorProtocol.fields(username: "admin", currentPassword: "current-secret", change: .password("short")) }
}
