import Foundation
import Testing
@testable import RouterCore

private let identity = RouterIdentity(model: "RT-BE88U", firmware: "3006.102.5", lanAddress: "192.168.50.1", wanAddress: "203.0.113.1")
private let identityJSON = #"{"productid":"RT-BE88U","firmver":"3.0.0.6","buildno":"102.5","extendno":"0","lan_ipaddr":"192.168.50.1","wan_unit":"0"}"#
private let statusXML = "<devicemap><wan>link_internet=2</wan><wan>active_wan_unit=0</wan><wan>wan0_ipaddr=203.0.113.1</wan><sys>uptimeStr=Thu (2909808 secs since boot)</sys></devicemap>"
private let loginHTML = #"<form action="login_v2.cgi"></form><script>fetch('get_Nonce.cgi'); var login_info={"error_status":0,"error_num":0};</script>"#
private let clientsJSON = #"{"get_clientlist":{"AA:BB:CC:DD:EE:01":{"name":"Phone","nickName":"我的手机","ip":"192.168.50.2","isOnline":"1","isWL":"2","rssi":"-55","curTx":"1200.0","curRx":"864.7","internetState":"1"},"AA:BB:CC:DD:EE:02":{"name":"NAS","ip":"192.168.50.3","isOnline":"1","isWL":"0","rssi":"0"},"AA:BB:CC:DD:EE:03":{"name":"Old device","isOnline":"0","isWL":"1"},"maclist":["AA:BB:CC:DD:EE:01"]}}"#
private let cpuText = #"var cpuInfo, memInfo = new Object(); cpuInfo = {"cpu0":{"total":"1000","usage":"200"},"cpu1":{"total":"1000","usage":"100"}}; memInfo = {"total":"2097152","used":"2029440","simple_used":"692248","simple_free":"1404904"};"#
private let netText = "netdev = {'BRIDGE':{rx:0xFFFF,tx:0xFFF},'INTERNET':{rx:0x17306155e2b,tx:0x1c2eab1eba4}}"

@Test func endpointAcceptsOnlyLocalDestinations() throws {
    #expect(try RouterEndpoint("192.168.50.1").url.absoluteString == "http://192.168.50.1/")
    #expect(try RouterEndpoint("https://router.asus.com:8443").url.port == 8443)
    for bad in ["https://evil.example", "http://192.168.50.1@evil.example", "http://192.168.50.1/path", "http://192.168.50.1?x=1", "http://999.1.1.1", "http://172.32.0.1", "file:///tmp/data"] {
        #expect(throws: RouterError.invalidAddress) { try RouterEndpoint(bad) }
    }
}

@Test func challengeMatchesKnownSHA256Vector() throws {
    #expect(try RouterAuthentication.authorization(username: "admin", password: "test-password", nonce: "server-nonce", clientNonce: "client-nonce") == "c2cfb7df6b0100bb9c506b11a9ae9c60565d238d94e17a554efca0cb2b396824")
    #expect(try RouterAuthentication.mode(from: loginHTML) == .challenge)
}

@Test func batchHooksEncodeSemicolonsForASUSHTTPD() throws {
    let endpoint = try RouterEndpoint("192.168.50.1")
    let url = endpoint.resource("appGet.cgi", query: [.init(name: "hook", value: "nvram_get(productid);nvram_get(firmver)")])
    #expect(url.absoluteString.contains("%3B"))
    #expect(!url.absoluteString.contains(";"))
    #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "nvram_get(productid);nvram_get(firmver)")
}

@Test func formEncodingPreservesSpecialCharacters() {
    let encoded = String(decoding: RouterAuthentication.form(["data": "a+b&c=d /中"]), as: UTF8.self)
    #expect(encoded == "data=a%2Bb%26c%3Dd%20%2F%E4%B8%AD")
}

@Test func lockoutAndCaptchaStopBeforeLogin() {
    #expect(throws: RouterError.locked) { try RouterAuthentication.mode(from: #"{"error_status":7,"error_num":5}"#) }
    #expect(throws: RouterError.captchaRequired) { try RouterAuthentication.checkLoginRestrictions(#"{"error_status":3,"error_num":2}"#) }
    #expect(throws: RouterError.locked) { try RouterAuthentication.checkLoginRestrictions(#"{"error_status":11}"#) }
}

@Test func clientsKeepOfflineAndWirelessSeparate() throws {
    let devices = try RouterParser.clients(Data(clientsJSON.utf8))
    #expect(devices.count == 3)
    #expect(devices.filter(\.isOnline).count == 2)
    let phone = try #require(devices.first { $0.name == "我的手机" })
    #expect(phone.connectionLabel == "5 GHz")
    #expect(phone.rssi == -55)
    #expect(phone.txLinkMbps == 1200)
    #expect(devices.first { $0.name == "NAS" }?.rssi == nil)
    #expect(devices.last?.isOnline == false)
}

@Test func missingClientListIsNotZeroDevices() {
    #expect(throws: RouterError.invalidResponse("设备列表")) { try RouterParser.clients(Data("{}".utf8)) }
    #expect(throws: RouterError.authenticationRequired) { try RouterParser.clients(Data("<script>location='/Main_Login.asp'</script>".utf8)) }
}

@Test func cpuParserUsesSimpleMemoryLikeOriginalDashboard() throws {
    let stats = try RouterParser.cpuAndMemory(cpuText)
    #expect(stats.cpu.count == 2)
    #expect(stats.used == 692248)
    #expect(stats.total == 2097152)
}

@Test func trafficPreservesLargeHexCountersAndRejectsMissingWAN() throws {
    let value = try RouterParser.traffic(netText)
    #expect(value.received == 0x17306155e2b)
    #expect(value.sent == 0x1c2eab1eba4)
    #expect(throws: RouterError.invalidResponse("互联网流量")) { try RouterParser.traffic("netdev={'WIRED':{rx:1,tx:2}}") }
}

@Test func unknownWANDoesNotBecomeOnline() {
    #expect(RouterParser.internet(statusXML) == .online)
    #expect(RouterParser.internet("<devicemap/>") == .unknown)
    #expect(RouterParser.internet("<wan>link_internet=1</wan>") == .offline)
    #expect(RouterParser.uptime(statusXML) == 2909808)
}

@Test func identityMatchesObservedFirmwareAndActiveWAN() throws {
    let data = try RouterParser.json(Data(identityJSON.utf8))
    let model = try RouterParser.identity(data, status: statusXML)
    #expect(model.firmware == "3006.102.5")
    #expect(model.wanAddress == "203.0.113.1")
}

@Test func metricsRequireTwoSamplesAndUseDeltas() {
    var calc = MetricCalculator()
    let a = RouterSample(identity: identity, cpu: ["cpu0": .init(total: 1000, used: 200)], traffic: .init(received: 100, sent: 200), monotonicTime: 10)
    let first = calc.consume(a)
    #expect(first.cpuPercent == nil); #expect(first.downloadBytesPerSecond == nil)
    let b = RouterSample(identity: identity, cpu: ["cpu0": .init(total: 1100, used: 220)], traffic: .init(received: 1100, sent: 2200), monotonicTime: 20)
    let second = calc.consume(b)
    #expect(second.cpuPercent == 20)
    #expect(second.downloadBytesPerSecond == 100)
    #expect(second.uploadBytesPerSecond == 200)
}

@Test func counterResetAndReconnectDoNotProduceSpikes() {
    var calc = MetricCalculator()
    _ = calc.consume(RouterSample(identity: identity, traffic: .init(received: 1_000_000, sent: 1000), uptime: 100, monotonicTime: 10))
    let reset = calc.consume(RouterSample(identity: identity, traffic: .init(received: 10, sent: 10), uptime: 1, monotonicTime: 20))
    #expect(reset.downloadBytesPerSecond == nil)
    calc.reset()
    #expect(calc.consume(RouterSample(identity: identity, traffic: .init(received: 20, sent: 20), monotonicTime: 30)).downloadBytesPerSecond == nil)
}

@Test func jsonObjectsAreParsedWithoutExecutingJavascript() throws {
    let source = #"x = {"nested":{"name":"brace } inside string"},"n":1}; malicious();"#
    let obj = try RouterParser.object(named: "x", in: source)
    #expect(obj["n"] as? Int == 1)
    #expect(throws: (any Error).self) { try RouterParser.object(named: "x", in: "x = {n: execute()};") }
}

@Test func redirectsCannotMoveSessionToAnotherOrigin() throws {
    let url = try RouterEndpoint("192.168.50.1").url
    #expect(RouterRedirectGuard.sameOrigin(url, URL(string: "http://192.168.50.1/index.asp")!))
    #expect(!RouterRedirectGuard.sameOrigin(url, URL(string: "http://192.168.50.2/")!))
    #expect(!RouterRedirectGuard.sameOrigin(url, URL(string: "https://192.168.50.1/")!))
    #expect(!RouterRedirectGuard.sameOrigin(url, URL(string: "http://192.168.50.1:8080/")!))
}

private actor MockTransport: RouterTransport {
    var replies: [RouterHTTPResponse]
    var requests: [URLRequest] = []
    init(_ texts: [String]) { replies = texts.map { RouterHTTPResponse(data: Data($0.utf8), status: 200) } }
    func send(_ request: URLRequest) async throws -> RouterHTTPResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw RouterError.network("Mock exhausted") }
        return replies.removeFirst()
    }
    nonisolated func cancel() {}
}

@Test func challengeLoginSendsHashThenVerifiesProtectedEndpoint() async throws {
    let transport = MockTransport([loginHTML, #"{"nonce":"server-nonce"}"#, "<html>ok</html>", identityJSON])
    let client = RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: transport, writes: .reference)
    try await client.login(username: "admin", password: "test-password")
    let requests = await transport.requests
    #expect(requests.map { $0.url!.path } == ["/Main_Login.asp", "/get_Nonce.cgi", "/login_v2.cgi", "/appGet.cgi"])
    let body = String(decoding: try #require(requests[2].httpBody), as: UTF8.self)
    #expect(!body.contains("test-password")); #expect(!body.contains("admin"))
    #expect(body.contains("login_authorization=")); #expect(body.contains("cnonce="))
}

@Test func login200WithoutAuthenticatedReadIsFailure() async throws {
    let transport = MockTransport([loginHTML, #"{"nonce":"server-nonce"}"#, "ok", "<script>location='/Main_Login.asp'</script>"])
    let client = RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: transport, writes: .reference)
    await #expect(throws: RouterError.invalidCredentials) { try await client.login(username: "admin", password: "bad") }
    #expect(await transport.requests.count == 4)
}

@Test func lockedRouterReceivesNoCredentialAttempt() async throws {
    let transport = MockTransport([#"{"error_status":7,"error_num":5}"#])
    let client = RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: transport, writes: .reference)
    await #expect(throws: RouterError.locked) { try await client.login(username: "admin", password: "any") }
    #expect(await transport.requests.count == 1)
}

@Test func sampleReadsOnlyObservedEndpoints() async throws {
    let transport = MockTransport([identityJSON, statusXML, clientsJSON, cpuText, netText])
    let client = RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: transport, writes: .reference)
    let sample = try await client.sample()
    #expect(sample.devices?.filter(\.isOnline).count == 2)
    #expect(sample.internet == .online)
    #expect(sample.unavailable.isEmpty)
    let requests = await transport.requests
    #expect(requests.allSatisfy { $0.httpMethod == "GET" })
    #expect(!requests.contains { $0.url!.path.contains("apply") || $0.url!.path.contains("reboot") })
}

@Test func partialStatsRemainExplicitlyUnavailable() async throws {
    let transport = MockTransport([identityJSON, statusXML, clientsJSON, "unsupported", netText])
    let client = RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: transport, writes: .reference)
    let sample = try await client.sample()
    #expect(sample.cpu == nil)
    #expect(sample.memoryUsedKiB == nil)
    #expect(sample.unavailable.contains("CPU / 内存"))
    #expect(sample.devices != nil)
}

@Test func expiredSessionNeverReturnsPartialSuccess() async throws {
    let transport = MockTransport([identityJSON, statusXML, "<script>location='/Main_Login.asp'</script>"])
    let client = RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: transport, writes: .reference)
    await #expect(throws: RouterError.authenticationRequired) { try await client.sample() }
}

@Test func jsonAuthenticationFailureAlsoStopsPartialRead() async throws {
    let transport = MockTransport([identityJSON, statusXML, #"{"error_status":"2"}"#])
    let client = RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: transport, writes: .reference)
    await #expect(throws: RouterError.authenticationRequired) { try await client.sample() }
}
