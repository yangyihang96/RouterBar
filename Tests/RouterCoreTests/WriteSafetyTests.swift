import Foundation
import Testing
@testable import RouterCore

private actor ReplyMock: RouterTransport {
    enum Reply: Sendable { case text(String, status: Int = 200), failure(any Error & Sendable) }
    var replies: [Reply]
    var requests: [URLRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> RouterHTTPResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw RouterError.network("No mock response") }
        switch replies.removeFirst() {
        case .text(let text, let status): return RouterHTTPResponse(data: Data(text.utf8), status: status)
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
private func client(_ mock: ReplyMock) throws -> RouterClient { RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: mock, writes: .reference) }
private func catalogField(_ section: String, _ key: String) throws -> (SettingSection, SettingField) {
    let s = try #require(SettingsCatalog.sections.first { $0.id == section })
    return (s, try #require(s.fields.first { $0.key == key }))
}

// MARK: Replies after dispatch

@Test func replyThatCannotVouchForTheSaveIsReportedUnconfirmed() async throws {
    let (s, f) = try catalogField("updates", "firmware_check_enable")
    let anomalies: [ReplyMock.Reply] = [.text("<html>busy</html>"), .text(#"{"other":"1"}"#), .text("", status: 502),
                                        .failure(URLError(.badServerResponse)), .failure(URLError(.networkConnectionLost))]
    for anomaly in anomalies {
        let mock = ReplyMock([.text(#"{"firmware_check_enable":"0"}"#), anomaly])
        let receipt = try await client(mock).applySettings(section: s, changes: [.init(field: f, before: "0", after: "1")])
        #expect(!receipt.isVerified); #expect(receipt.unverified == [f.key])
        #expect(receipt.message.contains("不要重复提交"))
        #expect(await mock.requests.count == 2)
    }
}
@Test func unconfirmedServiceReloadIsNotCalledAFailure() async throws {
    let (s, f) = try catalogField("ntp", "ntp_server0")
    let mock = ReplyMock([.text(#"{"ntp_server0":"pool.ntp.org"}"#), .text(#"{"modify":"1"}"#)])
    let receipt = try await client(mock).applySettings(section: s, changes: [.init(field: f, before: "pool.ntp.org", after: "time.cloudflare.com")])
    #expect(!receipt.isVerified); #expect(receipt.message.contains("没有确认重新加载"))
    #expect(await mock.posts.first?["rc_service"] == "restart_time;restart_firewall;")
}
@Test func unreachableRouterIsAnOrdinaryFailure() async throws {
    let (s, f) = try catalogField("updates", "firmware_check_enable")
    for code in [URLError.Code.cannotConnectToHost, .notConnectedToInternet] {
        let mock = ReplyMock([.text(#"{"firmware_check_enable":"0"}"#), .failure(URLError(code))])
        await #expect(throws: RouterError.network("无法连接路由器，请检查当前 Wi-Fi、地址和本地网络权限。")) {
            try await client(mock).applySettings(section: s, changes: [.init(field: f, before: "0", after: "1")])
        }
    }
    // A rejected session never applied anything and stays a sign-in problem.
    let expired = ReplyMock([.text(#"{"firmware_check_enable":"0"}"#), .text("", status: 403)])
    await #expect(throws: RouterError.authenticationRequired) {
        try await client(expired).applySettings(section: s, changes: [.init(field: f, before: "0", after: "1")])
    }
}

// MARK: Firmware and restore uploads

@Test func firmwareRepliesFollowTheRouterPages() {
    // Shapes of Merlin's Updating.asp, UpdateError.asp and UpdateError_reboot.asp as rendered by httpd.
    let flashing = #"<script>var reboot_needed_time = eval("190"); parent.showLoadingBar(270); setTimeout("parent.detect_httpd();", 272000);</script>"#
    let rejected = #"<script>var upgrade_fw_status = '6'; parent.cancel_dr_advise(); parent.confirm_asus({ title: "Invalid Firmware Upload" });</script>"#
    let restarting = #"<script>var reboottime = eval("190"); var upgrade_fw_status = '2'; parent.showLoadingBar(reboottime); setTimeout("parent.detect_httpd();", reboottime*1000);</script>"#
    #expect(FirmwareUploadReply(flashing) == .flashing)
    #expect(FirmwareUploadReply(rejected) == .rejected)
    #expect(FirmwareUploadReply(restarting) == .rejectedRestarting)
    #expect(FirmwareUploadReply("<html></html>") == .unrecognized)
}
@Test func firmwareFailuresBeforeTheRouterTakesTheImageAreOrdinary() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("RT-AX86U_3004_388.8_2.w")
    try Data(repeating: 0x5A, count: 1_100_000).write(to: file)
    let image = try FirmwareImage.inspect(file, model: "RT-AX86U")
    func install(_ reply: ReplyMock.Reply) async throws {
        let mock = ReplyMock([.text(#"{"productid":"RT-AX86U"}"#), reply])
        try await client(mock).installFirmware(image, model: "RT-AX86U") { _ in }
    }
    await #expect(throws: RouterError.network("无法连接路由器，文件尚未上传。请检查网络后重试。")) { try await install(.failure(URLError(.cannotConnectToHost))) }
    do { try await install(.text(#"<script>var upgrade_fw_status = '6';</script>"#)) } catch RouterError.validation {} catch { Issue.record("rejection should be a plain failure, got \(error)") }
    for unconfirmed in [ReplyMock.Reply.failure(URLError(.networkConnectionLost)), .text("<html></html>"), .text("", status: 500)] {
        do { try await install(unconfirmed); Issue.record("expected an unconfirmed upload") }
        catch RouterError.submissionUncertain {} catch { Issue.record("expected submissionUncertain, got \(error)") }
    }
    try await install(.text(#"parent.showLoadingBar(270); setTimeout("parent.detect_httpd();", 272000);"#))
}
@Test func restoreRepliesFollowTheRouterPages() {
    #expect(ConfigurationBackup.restoreReply(Data(#"<script>alert("Unable to restore");</script>"#.utf8)) == .rejected)
    #expect(ConfigurationBackup.restoreReply(Data(#"parent.showLoadingBar(reboot_needed_time); setTimeout("parent.detect_httpd();", 1000);"#.utf8)) == .accepted)
}

// MARK: LAN address rules

private let lanContext = ["sw_mode": "1", "lan_hostname": "RT-BE88U", "lan_ipaddr": "192.168.50.1", "lan_netmask": "255.255.255.0",
                          "wan0_ipaddr": "203.0.113.7", "wan0_netmask": "255.255.255.0", "subnet_rl": "", "subnet_rulelist_ext": "",
                          "http_enable": "2", "le_enable": "0"]

@Test func lanAddressChangeCarriesTheFirmwareDependentFields() throws {
    let moved = try LANAddressRules.dependentFields(changes: ["lan_ipaddr": "192.168.60.1"], context: lanContext, support: [:])
    #expect(moved == ["lan_ipaddr_rt": "192.168.60.1", "lan_netmask_rt": "255.255.255.0", "dhcp_start": "192.168.60.2", "dhcp_end": "192.168.60.254", "https_crt_gen": "1"])
    let wider = try LANAddressRules.dependentFields(changes: ["lan_netmask": "255.255.254.0"], context: lanContext, support: [:])
    #expect(wider["dhcp_start"] == "192.168.50.2"); #expect(wider["dhcp_end"] == "192.168.51.254"); #expect(wider["lan_netmask_rt"] == "255.255.254.0")
    #expect(try LANAddressRules.dependentFields(changes: ["lan_hostname": "home"], context: lanContext, support: [:]) == ["https_crt_gen": "1"])
    var letsEncrypt = lanContext; letsEncrypt["le_enable"] = "1"
    #expect(try LANAddressRules.dependentFields(changes: ["lan_hostname": "home"], context: letsEncrypt, support: [:]).isEmpty)
    var httpOnly = lanContext; httpOnly["http_enable"] = "0"
    #expect(try LANAddressRules.dependentFields(changes: ["lan_ipaddr": "192.168.60.1"], context: httpOnly, support: [:])["https_crt_gen"] == nil)
    #expect(try LANAddressRules.dependentFields(changes: ["lan_domain": "home.arpa"], context: lanContext, support: [:]).isEmpty)
}
@Test func lanAddressChangeRefusesWhatTheRouterPageRefuses() throws {
    func refuses(_ changes: [String: String], _ context: [String: String] = lanContext, support: [String: String] = [:]) -> Bool {
        (try? LANAddressRules.dependentFields(changes: changes, context: context, support: support)) == nil
    }
    #expect(refuses(["lan_ipaddr": "203.0.113.1"]))
    #expect(refuses(["lan_ipaddr": "192.168.60.0"])); #expect(refuses(["lan_ipaddr": "192.168.60.255"]))
    #expect(refuses(["lan_netmask": "255.0.255.0"])); #expect(refuses(["lan_netmask": "255.255.255.254"]))
    var ap = lanContext; ap["sw_mode"] = "3"
    #expect(refuses(["lan_ipaddr": "192.168.60.1"], ap))
    #expect(refuses(["lan_ipaddr": "192.168.60.1"], support: ["tagged_based_vlan": "1"]))
    var tagged = lanContext; tagged["subnet_rulelist_ext"] = "<br0>192.168.50.1/24>"
    #expect(refuses(["lan_ipaddr": "192.168.60.1"], tagged))
    var guest = lanContext
    guest["subnet_rl"] = "<1>br0>192.168.50.1>255.255.255.0>1>192.168.50.2>192.168.50.254>86400>>,>>><2>br52>192.168.52.1>255.255.255.0>1>192.168.52.2>192.168.52.254>86400>>,>>>"
    #expect(refuses(["lan_ipaddr": "192.168.52.1"], guest))
    #expect(refuses(["lan_ipaddr": "192.168.52.200"], guest))
    #expect(refuses(["lan_netmask": "255.255.0.0"], guest))
    // The row that carries the current LAN address is the main network itself.
    #expect(!refuses(["lan_netmask": "255.255.255.128"], guest))
    #expect(!refuses(["lan_ipaddr": "192.168.60.1"], guest))
}
@Test func dhcpPoolMustStayInsideTheLAN() throws {
    try LANAddressRules.validatePool(start: "192.168.50.2", end: "192.168.50.254", lanIP: "192.168.50.1", mask: "255.255.255.0")
    for (start, end) in [("192.168.51.2", "192.168.51.9"), ("192.168.50.0", "192.168.50.9"), ("192.168.50.9", "192.168.50.255"), ("192.168.50.20", "192.168.50.10"), ("x", "192.168.50.10")] {
        #expect(throws: RouterError.self) { try LANAddressRules.validatePool(start: start, end: end, lanIP: "192.168.50.1", mask: "255.255.255.0") }
    }
}
@Test func savingANewLANAddressSendsDependentFieldsAndPointsToTheNewAddress() async throws {
    let (s, f) = try catalogField("lan", "lan_ipaddr")
    let context = String(decoding: try JSONSerialization.data(withJSONObject: lanContext), as: UTF8.self)
    // The ten context keys arrive in one request (RouterClient.settingBatches).
    let mock = ReplyMock([.text(#"{"lan_ipaddr":"192.168.50.1"}"#), .text(context), .text(#"{"get_ui_support":{"mtlancfg":1}}"#),
                          .failure(URLError(.networkConnectionLost))])
    let receipt = try await client(mock).applySettings(section: s, changes: [.init(field: f, before: "192.168.50.1", after: "192.168.60.1")])
    #expect(!receipt.isVerified); #expect(receipt.message.contains("http://192.168.60.1"))
    let post = try #require(await mock.posts.first)
    #expect(post["lan_ipaddr"] == "192.168.60.1"); #expect(post["lan_ipaddr_rt"] == "192.168.60.1")
    #expect(post["dhcp_start"] == "192.168.60.2"); #expect(post["dhcp_end"] == "192.168.60.254")
    #expect(post["rc_service"] == "restart_net_and_phy")
}

// MARK: Pausing a device

private func pauseReplies(enable: String, mac: String = "AA:BB:CC:DD:EE:01", readback: String? = nil) -> [ReplyMock.Reply] {
    let lists = #"{"MULTIFILTER_ALL":"1","MULTIFILTER_MAC":"\#(mac)","MULTIFILTER_ENABLE":"\#(enable)","MULTIFILTER_DEVICENAME":"Tablet","MULTIFILTER_MACFILTER_DAYTIME_V2":"W03E21000700"}"#
    var replies: [ReplyMock.Reply] = [.text(#"{"get_ui_support":{"PC_SCHED_V3":1}}"#), .text(lists)]
    if let readback { replies += [.text(#"{"modify":"1","run_service":"restart_firewall"}"#), .text(readback)] }
    return replies
}
@Test func resumingRestoresTheScheduleThatWasPaused() async throws {
    let after = #"{"MULTIFILTER_ALL":"1","MULTIFILTER_MAC":"AA:BB:CC:DD:EE:01","MULTIFILTER_ENABLE":"1","MULTIFILTER_DEVICENAME":"Tablet","MULTIFILTER_MACFILTER_DAYTIME_V2":"W03E21000700"}"#
    let mock = ReplyMock(pauseReplies(enable: "2", readback: after))
    let result = try await client(mock).setInternetPaused(mac: "aa:bb:cc:dd:ee:01", name: "Tablet", paused: false, resumeState: "1")
    #expect(result.receipt.isVerified); #expect(result.priorState == "2")
    #expect(await mock.posts.first?["MULTIFILTER_ENABLE"] == "1")
}
@Test func resumingADeviceThatIsNotPausedChangesNothing() async throws {
    for enable in ["0", "1"] {
        let mock = ReplyMock(pauseReplies(enable: enable))
        let result = try await client(mock).setInternetPaused(mac: "AA:BB:CC:DD:EE:01", name: "Tablet", paused: false)
        #expect(result.priorState == enable); #expect(result.receipt.message.contains("没有被暂停"))
        #expect(await mock.posts.isEmpty)
    }
    let paused = ReplyMock(pauseReplies(enable: "2"))
    #expect(try await client(paused).setInternetPaused(mac: "AA:BB:CC:DD:EE:01", name: "Tablet", paused: true).receipt.message.contains("已处于暂停"))
    #expect(await paused.posts.isEmpty)
}
@Test func longOrUnusualDeviceNamesStillPause() async throws {
    let label = DeviceConfiguration.ruleLabel("Living <Room> iPad Pro 12.9-inch (6th generation)\r\n", mac: "aa:bb:cc:dd:ee:02")
    #expect(label.utf8.count <= 32); #expect(!label.contains("<")); #expect(!label.contains(">")); #expect(!label.containsLineBreak)
    #expect(DeviceConfiguration.ruleLabel("客厅的平板电脑客厅的平板电脑客厅的平板", mac: "aa:bb:cc:dd:ee:02").utf8.count <= 32)
    #expect(DeviceConfiguration.ruleLabel("<>", mac: "aa:bb:cc:dd:ee:02") == "AA:BB:CC:DD:EE:02")
    let readback = #"{"MULTIFILTER_ALL":"1","MULTIFILTER_MAC":"AA:BB:CC:DD:EE:01>AA:BB:CC:DD:EE:02","MULTIFILTER_ENABLE":"0>2","MULTIFILTER_DEVICENAME":"Tablet>\#(label)","MULTIFILTER_MACFILTER_DAYTIME_V2":"W03E21000700>W03E21000700<W04122000800"}"#
    let mock = ReplyMock(pauseReplies(enable: "0", readback: readback))
    let result = try await client(mock).setInternetPaused(mac: "aa:bb:cc:dd:ee:02", name: "Living <Room> iPad Pro 12.9-inch (6th generation)\r\n", paused: true)
    #expect(result.priorState == nil); #expect(result.receipt.isVerified)
    #expect(await mock.posts.first?["MULTIFILTER_DEVICENAME"] == "Tablet>" + label)
}

// MARK: Field types

@Test func typedFieldsFollowTheFirmwareRules() throws {
    let timeout = SettingField(key: "shell_timeout", label: "闲置超时", kind: "integer", minimum: 600, maximum: 59940, allowsZero: true)
    for value in ["0", "600", "59940", ""] { try timeout.validate(value) }
    for value in ["599", "59941", "-1", "1e3", "10 "] { #expect(throws: RouterError.self) { try timeout.validate(value) } }
    #expect(timeout.rangeText == "0 或 600–59940")
    let overhead = SettingField(key: "qos_overhead", label: "开销", kind: "integer", minimum: -64, maximum: 256)
    try overhead.validate("-64"); #expect(throws: RouterError.self) { try overhead.validate("-65") }
    let v6 = SettingField(key: "ipv6_dns1", label: "DNS", kind: "ipv6")
    try v6.validate("2001:db8::1"); #expect(throws: RouterError.self) { try v6.validate("192.168.50.1") }
    let either = SettingField(key: "wl0_radius_ipaddr", label: "RADIUS", kind: "ip")
    try either.validate("192.168.50.10"); try either.validate("fd00::10"); #expect(throws: RouterError.self) { try either.validate("radius.lan") }
    let host = SettingField(key: "log_ipaddr", label: "日志服务器", kind: "host")
    try host.validate("syslog.home.arpa"); try host.validate("192.168.50.20"); try host.validate("fd00::20")
    #expect(throws: RouterError.self) { try host.validate("bad host") }; #expect(throws: RouterError.self) { try host.validate("-bad.example") }
    let prefix = SettingField(key: "vpn_server1_sn6", label: "前缀", kind: "ipv6Prefix")
    try prefix.validate("fd00:1::/64"); #expect(throws: RouterError.self) { try prefix.validate("fd00:1::/129") }; #expect(throws: RouterError.self) { try prefix.validate("fd00:1::") }
    let zone = SettingField(key: "time_zone", label: "时区", kind: "readonly")
    #expect(throws: RouterError.self) { try zone.validate("UTC0") }
    let schedule = SettingField(key: "reboot_schedule", label: "重启时间表", kind: "text", pattern: #"^[01]{7}([01][0-9]|2[0-3])[0-5][0-9]$"#)
    try schedule.validate("01111100300"); #expect(throws: RouterError.self) { try schedule.validate("01111102400") }
}
@Test func windowsLineBreaksAreCaughtLikeAnyOther() throws {
    let text = SettingField(key: "ntp_server0", label: "NTP", kind: "text")
    #expect(throws: RouterError.self) { try text.validate("pool.ntp.org\r\nx") }
    #expect(throws: RouterError.self) { try text.validate("pool.ntp.org\r") }
    #expect(throws: (any Error).self) { try RouterRuleCodec.encode([["a\r\nb", "c"]], columns: 2) }
    #expect(throws: (any Error).self) { try DeviceConfiguration.renamed("", mac: "AA:BB:CC:DD:EE:01", name: "Tablet\r\n") }
}

// MARK: Accounts

@Test func administratorChangeWithAnUnreadableReplyIsUnconfirmed() async throws {
    let change = AdministratorChange.password("correct-horse-42")
    // chpass.cgi answers after changing the account: anything but its two refusals leaves the result open.
    for reply in [ReplyMock.Reply.text("<html>"), .failure(URLError(.networkConnectionLost)), .text("", status: 500),
                  .text("{}"), .text(#"{"statusCode":"500"}"#), .text(#"{"statusCode":"x"}"#)] {
        do {
            try await client(ReplyMock([reply])).changeAdministrator(username: "admin", currentPassword: "old-password", change: change)
            Issue.record("an unreadable reply must not count as saved")
        } catch RouterError.submissionUncertain {
        } catch { Issue.record("an unreadable reply was reported as \(error)") }
    }
    await #expect(throws: RouterError.locked) {
        try await client(ReplyMock([.text(#"{"statusCode":"402"}"#)])).changeAdministrator(username: "admin", currentPassword: "old-password", change: change)
    }
    try await client(ReplyMock([.text(#"{"statusCode":"200"}"#)])).changeAdministrator(username: "admin", currentPassword: "old-password", change: change)
}
@Test func loginThatFailsInTransitIsAnOrdinaryNetworkFailure() async throws {
    let page = #"<form action="login_v2.cgi"></form><script>fetch("get_Nonce.cgi")</script>"#
    for code in [URLError.Code.timedOut, .networkConnectionLost] {
        let mock = ReplyMock([.text(page), .failure(URLError(code))])
        await #expect(throws: RouterError.network("无法连接路由器，请检查当前 Wi-Fi、地址和本地网络权限。")) {
            try await client(mock).login(username: "admin", password: "test-only")
        }
    }
}
@Test func systemPageSavesRestartWhatTheRouterPageRestarts() async throws {
    let (admin, port) = try catalogField("admin", "http_lanport")
    let portMock = ReplyMock([.text(#"{"http_lanport":"80"}"#), .failure(URLError(.networkConnectionLost))])
    let moved = try await client(portMock).applySettings(section: admin, changes: [.init(field: port, before: "80", after: "8080")])
    #expect(await portMock.posts.first?["rc_service"] == "restart_time;restart_httpd;restart_firewall;")
    #expect(!moved.isVerified); #expect(moved.message.contains("重启管理网页服务"))

    let (_, captcha) = try catalogField("admin", "captcha_enable")
    let captchaMock = ReplyMock([.text(#"{"captcha_enable":"1"}"#), .text(#"{"modify":"1","run_service":"restart_time;restart_firewall;"}"#), .text(#"{"captcha_enable":"0"}"#)])
    let saved = try await client(captchaMock).applySettings(section: admin, changes: [.init(field: captcha, before: "1", after: "0")])
    #expect(saved.isVerified)

    let (ntp, ntpd) = try catalogField("ntp", "ntpd_enable")
    let ntpMock = ReplyMock([.text(#"{"ntpd_enable":"0"}"#), .text(#"{"modify":"1"}"#)])
    _ = try await client(ntpMock).applySettings(section: ntp, changes: [.init(field: ntpd, before: "0", after: "1")])
    #expect(await ntpMock.posts.first?["rc_service"] == "restart_time;restart_firewall;restart_dnsmasq;")

    let (led, button) = try catalogField("led", "btn_ez_radiotoggle")
    let buttonMock = ReplyMock([.text(#"{"btn_ez_radiotoggle":"0"}"#), .text(#"{"modify":"1"}"#)])
    _ = try await client(buttonMock).applySettings(section: led, changes: [.init(field: button, before: "0", after: "1")])
    #expect(await buttonMock.posts.first?["btn_ez_mode"] == "0")
}
