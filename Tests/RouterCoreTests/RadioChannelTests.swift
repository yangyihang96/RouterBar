import Foundation
import Testing
@testable import RouterCore

// All tests run against a mock transport. No live router write has been exercised by these tests.
private actor RadioMock: RouterTransport {
    var replies: [Result<String, RouterError>]
    var requests: [URLRequest] = []
    init(_ replies: [Result<String, RouterError>]) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> RouterHTTPResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw RouterError.network("No mock response") }
        return try RouterHTTPResponse(data: Data(replies.removeFirst().get().utf8), status: 200)
    }
    var posts: [URLRequest] { requests.filter { $0.httpMethod == "POST" } }
    nonisolated func cancel() {}
}
private func client(_ mock: RadioMock) throws -> RouterClient { RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: mock, writes: .reference) }
private func nvram(unit: Int, bw: String, chanspec: String, product: String = "RT-BE88U", nband: String? = nil) -> String {
    let encoded = chanspec.replacingOccurrences(of: "/", with: "%2F")
    return #"{"wl1_bw_160":"1","odmpid":"","productid":"\#(product)","wl\#(unit)_bw":"\#(bw)","wl\#(unit)_chanspec":"\#(encoded)","wl\#(unit)_nband":"\#(nband ?? (unit == 0 ? "2" : "1"))"}"#
}
private let hook2g = #"{"chanspecs_2g":["0","1","6","11","1l","5u","7l","11u"]}"#
private let hook5g = #"{"chanspecs_5g":["0","36","40","149","36l","40u","36/80","149/80","36/160","100/240"]}"#
private func capabilities(_ json: String, _ band: RadioBand) throws -> (choices: [RadioChanspec], auto: Bool, unsupported: [String]) {
    let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    return try RadioChannelParser.capabilities(object?[band.hook], band: band)
}
private func snapshot(_ json: String, _ band: RadioBand, bw: String = "0", chanspec: String = "0") throws -> RadioChannelSnapshot {
    let parsed = try capabilities(json, band)
    return RadioChannelSnapshot(unit: band.rawValue, band: band, bandwidth: bw, chanspec: chanspec, choices: parsed.choices, offersAutoChannel: parsed.auto, unsupportedChanspecs: parsed.unsupported)
}
private func postedFields(_ request: URLRequest) throws -> [String: String] {
    let raw = String(decoding: try #require(request.httpBody), as: UTF8.self)
    let decoded = try #require(raw.removingPercentEncoding)
    let object = try JSONSerialization.jsonObject(with: Data(decoded.utf8)) as? [String: String]
    return try #require(object)
}

@Test func firmwareAutoChoiceDoesNotRequireAZeroInDriverCapabilities() async throws {
    let mock = RadioMock([.success(nvram(unit: 1, bw: "0", chanspec: "0")), .success(#"{"chanspecs_5g":["36","36/80"]}"#)])
    let radio = try await client(mock).readRadioChannels(unit: 1)
    try radio.validate(bandwidth: "0", chanspec: "0")
    #expect(radio.offersAutoChannel)
}

@Test func disabled160MHzIsExcludedUntilItsRouterSettingIsEnabled() async throws {
    let values = nvram(unit: 1, bw: "0", chanspec: "0").replacingOccurrences(of: "\"wl1_bw_160\":\"1\"", with: "\"wl1_bw_160\":\"0\"")
    let mock = RadioMock([.success(values), .success(hook5g)])
    let radio = try await client(mock).readRadioChannels(unit: 1)
    #expect(!radio.widths.contains(.mhz160))
    #expect(throws: RouterError.self) { try radio.validate(bandwidth: "0", chanspec: "36/160") }
}

@Test func twoGigahertzWidthsAreDerivedFromRouterChanspecs() throws {
    let s = try snapshot(hook2g, .ghz24)
    #expect(s.widths == [.auto, .mhz20, .mhz40])
    #expect(s.offersAutoChannel)
    #expect(s.options(for: .mhz20).map(\.raw) == ["0", "1", "6", "11"])
    #expect(s.options(for: .mhz40).map(\.raw) == ["0", "1l", "5u", "7l", "11u"])
    #expect(s.options(for: .auto).count == 1 + s.choices.count)
    #expect(s.choices.first { $0.raw == "1l" }?.label == "信道 1 · 40 MHz（扩展至 5）")
    #expect(s.choices.first { $0.raw == "5u" }?.label == "信道 5 · 40 MHz（扩展至 1）")
}
@Test func fiveGigahertzWidthsAndUnsupportedWidthsAreSeparated() throws {
    let s = try snapshot(hook5g, .ghz5)
    #expect(s.widths == [.auto, .mhz20, .mhz40, .mhz80, .mhz160])
    #expect(s.options(for: .mhz80).map(\.raw) == ["0", "36/80", "149/80"])
    #expect(s.options(for: .mhz160).map(\.raw) == ["0", "36/160"])
    #expect(s.unsupportedChanspecs == ["100/240"])
    #expect(!s.options(for: .auto).contains { $0.raw == "100/240" })
}
@Test func widthsNeverIncludeOptionsTheRouterDidNotList() throws {
    let s = try snapshot(#"{"chanspecs_5g":["36","40","44","48"]}"#, .ghz5)
    #expect(s.widths == [.auto, .mhz20])
    #expect(!s.offersAutoChannel)
    #expect(s.options(for: .auto).map(\.raw) == ["36", "40", "44", "48"])
}
@Test func everyWidthHasAFriendlyLabelAndBroadcomValue() throws {
    #expect(RadioBandwidth.allCases.map(\.rawValue) == ["0", "1", "2", "3", "5"])
    #expect(RadioBandwidth.allCases.map(\.label) == ["自动", "20 MHz", "40 MHz", "80 MHz", "160 MHz"])
    #expect(Set(RadioBandwidth.allCases.map(\.label)).count == RadioBandwidth.allCases.count)
    #expect(try snapshot(hook5g, .ghz5).label(for: .auto) == "自动（20/40/80/160 MHz）")
    #expect(try snapshot(hook2g, .ghz24).label(for: .auto) == "自动（20/40 MHz）")
    let odd = try snapshot(hook2g, .ghz24, bw: "4", chanspec: "13")
    #expect(odd.currentBandwidthLabel.contains("4"))
    #expect(odd.currentChanspecLabel.contains("不在路由器当前提供的列表中"))
}
@Test func malformedCapabilitiesAreRejectedAsAWhole() throws {
    let bad: [(String, RadioBand)] = [
        (#"{"chanspecs_2g":"1,6,11"}"#, .ghz24),          // not an array
        (#"{"chanspecs_2g":["1",{"x":1}]}"#, .ghz24),      // non-scalar entry
        (#"{"chanspecs_2g":["1","6","abc"]}"#, .ghz24),    // garbage
        (#"{"chanspecs_2g":["1","36/80"]}"#, .ghz24),      // 5 GHz format on 2.4 GHz
        (#"{"chanspecs_2g":["1","1u"]}"#, .ghz24),         // impossible sideband
        (#"{"chanspecs_5g":["36","36/60"]}"#, .ghz5),      // unknown width
        (#"{"chanspecs_5g":["36","200"]}"#, .ghz5),        // out of band
        (#"{"chanspecs_5g":["36","036"]}"#, .ghz5),        // non-canonical number
        (#"{"chanspecs_5g":[true]}"#, .ghz5),              // boolean
        (#"{"other":["36"]}"#, .ghz5),                     // missing hook
    ]
    for (json, band) in bad { #expect(throws: RouterError.self) { try capabilities(json, band) } }
    #expect(throws: RouterError.self) { try capabilities(#"{"chanspecs_5g":["0"]}"#, .ghz5) }  // nothing selectable
}
@Test func unsupportedChanspecCombinationsFailValidation() throws {
    let s = try snapshot(hook5g, .ghz5)
    #expect(throws: RouterError.self) { try s.validate(bandwidth: "3", chanspec: "36/160") } // width mismatch
    #expect(throws: RouterError.self) { try s.validate(bandwidth: "2", chanspec: "36") }
    #expect(throws: RouterError.self) { try s.validate(bandwidth: "0", chanspec: "100/240") } // listed but not writable
    #expect(throws: RouterError.self) { try s.validate(bandwidth: "0", chanspec: "52") }      // never listed
    #expect(throws: RouterError.self) { try s.validate(bandwidth: "4", chanspec: "36/80") }   // 80+80 not offered
    #expect(throws: RouterError.self) { try s.validate(bandwidth: "", chanspec: "0") }
    try s.validate(bandwidth: "0", chanspec: "36/160")  // auto pairs with any legal chanspec
    try s.validate(bandwidth: "5", chanspec: "36/160")
    try s.validate(bandwidth: "3", chanspec: "0")
    let noAuto = try snapshot(#"{"chanspecs_5g":["36"]}"#, .ghz5)
    #expect(throws: RouterError.self) { try noAuto.validate(bandwidth: "1", chanspec: "0") }
}
@Test func readUsesNvramAndChanspecHookAndDecodesValues() async throws {
    let mock = RadioMock([.success(nvram(unit: 1, bw: "3", chanspec: "36/80")), .success(hook5g)])
    let s = try await client(mock).readRadioChannels(unit: 1)
    #expect(s.bandwidth == "3"); #expect(s.chanspec == "36/80"); #expect(s.band == .ghz5)
    let urls = await mock.requests.map { $0.url!.absoluteString }
    #expect(urls.count == 2)
    #expect(urls[1].contains("chanspecs_5g()") || urls[1].contains("chanspecs_5g%28%29"))
    #expect(await mock.posts.isEmpty)
}
@Test func identityAndRadioGuardsStopBeforeCapabilitiesOrWrites() async throws {
    await #expect(throws: RouterError.self) { try await client(RadioMock([])).readRadioChannels(unit: 2) }
    // Another model is read like this one: the radio's band decides, not the model name.
    let other = RadioMock([.success(nvram(unit: 0, bw: "0", chanspec: "0", product: "RT-AX86U")), .success(hook2g)])
    #expect(try await client(other).readRadioChannels(unit: 0).band == .ghz24)
    #expect(await other.requests.count == 2)
    let swapped = RadioMock([.success(nvram(unit: 1, bw: "0", chanspec: "0", nband: "2"))])
    await #expect(throws: RouterError.self) { try await client(swapped).readRadioChannels(unit: 1) }
    #expect(await swapped.requests.count == 1)
}
@Test func saveSubmitsOnlyBandwidthAndChanspecThenVerifiesReadback() async throws {
    let before = try snapshot(hook5g, .ghz5, bw: "3", chanspec: "36/80")
    let mock = RadioMock([.success(nvram(unit: 1, bw: "3", chanspec: "36/80")), .success(hook5g),
                          .success(#"{"modify":"1","run_service":"restart_wireless"}"#),
                          .success(#"{"wl1_bw":"5","wl1_chanspec":"36%2F160"}"#)])
    let receipt = try await client(mock).applyRadioChannels(.init(snapshot: before, bandwidth: "5", chanspec: "36/160"), settleSeconds: 0)
    #expect(receipt.outcome == .verified)
    let requests = await mock.requests
    #expect(requests.map(\.httpMethod) == ["GET", "GET", "POST", "GET"])
    #expect(requests[2].url!.path == "/applyapp.cgi")
    #expect(try postedFields(requests[2]) == ["action_mode": "apply", "rc_service": "restart_wireless", "wl1_bw": "5", "wl1_chanspec": "36/160"])
}
@Test func staleCurrentValuesAreRejectedWithoutPosting() async throws {
    let before = try snapshot(hook2g, .ghz24, bw: "1", chanspec: "6")
    let mock = RadioMock([.success(nvram(unit: 0, bw: "1", chanspec: "11")), .success(hook2g)])
    await #expect(throws: RouterError.self) { try await client(mock).applyRadioChannels(.init(snapshot: before, bandwidth: "2", chanspec: "1l"), settleSeconds: 0) }
    #expect(await mock.posts.isEmpty)
}
@Test func capabilitiesAreRevalidatedAtSave() async throws {
    let before = try snapshot(hook5g, .ghz5, bw: "0", chanspec: "0")
    let shrunk = #"{"chanspecs_5g":["0","36","36l","36/80"]}"#
    let mock = RadioMock([.success(nvram(unit: 1, bw: "0", chanspec: "0")), .success(shrunk)])
    await #expect(throws: RouterError.self) { try await client(mock).applyRadioChannels(.init(snapshot: before, bandwidth: "5", chanspec: "36/160"), settleSeconds: 0) }
    #expect(await mock.posts.isEmpty)
    let malformed = RadioMock([.success(nvram(unit: 1, bw: "0", chanspec: "0")), .success(#"{"chanspecs_5g":["36","bogus"]}"#)])
    await #expect(throws: RouterError.self) { try await client(malformed).applyRadioChannels(.init(snapshot: before, bandwidth: "1", chanspec: "36"), settleSeconds: 0) }
    #expect(await malformed.posts.isEmpty)
}
@Test func unchangedRequestIsRejected() async throws {
    let before = try snapshot(hook2g, .ghz24, bw: "1", chanspec: "6")
    let mock = RadioMock([])
    await #expect(throws: RouterError.self) { try await client(mock).applyRadioChannels(.init(snapshot: before, bandwidth: "1", chanspec: "6"), settleSeconds: 0) }
    #expect(await mock.requests.isEmpty)
}
@Test func uncertainSubmissionIsNotSuccessAndNotRetried() async throws {
    let before = try snapshot(hook2g, .ghz24, bw: "1", chanspec: "6")
    let mock = RadioMock([.success(nvram(unit: 0, bw: "1", chanspec: "6")), .success(hook2g), .failure(.submissionUncertain("Disconnected after send"))])
    let receipt = try await client(mock).applyRadioChannels(.init(snapshot: before, bandwidth: "1", chanspec: "11"), settleSeconds: 0)
    #expect(receipt.outcome == .uncertain); #expect(!receipt.isVerified)
    #expect(await mock.requests.count == 3); #expect(await mock.posts.count == 1)
}
@Test func unconfirmedRouterReplyIsUncertain() async throws {
    let before = try snapshot(hook2g, .ghz24, bw: "1", chanspec: "6")
    let mock = RadioMock([.success(nvram(unit: 0, bw: "1", chanspec: "6")), .success(hook2g), .success(#"{"modify":"1"}"#)])
    let receipt = try await client(mock).applyRadioChannels(.init(snapshot: before, bandwidth: "1", chanspec: "11"), settleSeconds: 0)
    #expect(receipt.outcome == .uncertain)
    #expect(await mock.posts.count == 1)
}
@Test func readbackMismatchIsNotSuccess() async throws {
    let before = try snapshot(hook2g, .ghz24, bw: "1", chanspec: "6")
    let mock = RadioMock([.success(nvram(unit: 0, bw: "1", chanspec: "6")), .success(hook2g),
                          .success(#"{"modify":"1","run_service":"restart_wireless"}"#), .success(#"{"wl0_bw":"1","wl0_chanspec":"6"}"#)])
    let receipt = try await client(mock).applyRadioChannels(.init(snapshot: before, bandwidth: "1", chanspec: "11"), settleSeconds: 0)
    #expect(receipt.outcome == .mismatch); #expect(!receipt.isVerified)
}
@Test func cancellationAfterDispatchReportsUncertain() async throws {
    let before = try snapshot(hook2g, .ghz24, bw: "1", chanspec: "6")
    let mock = RadioMock([.success(nvram(unit: 0, bw: "1", chanspec: "6")), .success(hook2g),
                          .success(#"{"modify":"1","run_service":"restart_wireless"}"#), .success(#"{"wl0_bw":"1","wl0_chanspec":"11"}"#)])
    let c = try client(mock)
    let task = Task { try await c.applyRadioChannels(.init(snapshot: before, bandwidth: "1", chanspec: "11"), settleSeconds: 30) }
    while await mock.posts.isEmpty { await Task.yield() }
    task.cancel()
    let receipt = try await task.value
    #expect(receipt.outcome == .uncertain)
    #expect(await mock.posts.count == 1)
}
@Test func radioSaveSharesTheMutationGate() async throws {
    let before = try snapshot(hook2g, .ghz24, bw: "1", chanspec: "6")
    let mock = RadioMock([.success(nvram(unit: 0, bw: "1", chanspec: "6")), .success(hook2g),
                          .success(#"{"modify":"1","run_service":"restart_wireless"}"#), .success(#"{"wl0_bw":"1","wl0_chanspec":"11"}"#)])
    let c = try client(mock)
    let first = Task { try await c.applyRadioChannels(.init(snapshot: before, bandwidth: "1", chanspec: "11"), settleSeconds: 0.3) }
    while await mock.posts.isEmpty { await Task.yield() }
    await #expect(throws: RouterError.self) { try await c.applyRadioChannels(.init(snapshot: before, bandwidth: "1", chanspec: "1"), settleSeconds: 0) }
    #expect(try await first.value.outcome == .verified)
    #expect(await mock.posts.count == 1)
}
