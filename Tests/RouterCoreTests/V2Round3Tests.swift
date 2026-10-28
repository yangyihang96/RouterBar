import Foundation
import Testing
@testable import RouterCore

/// Counts every request; answers appGet.cgi from `nvram` and get_ui_support() from `support`, anything else with "{}".
private actor CountingRouter: RouterTransport {
    var nvram: [String: String]
    var support: [String: String]
    var sent = 0
    init(_ nvram: [String: String] = [:], support: [String: String] = [:]) { self.nvram = nvram; self.support = support }
    func send(_ request: URLRequest) async throws -> RouterHTTPResponse {
        sent += 1
        let hook = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "hook" }?.value ?? ""
        if hook.contains("get_ui_support") {
            return RouterHTTPResponse(data: try JSONSerialization.data(withJSONObject: ["get_ui_support": support]), status: 200)
        }
        let keys = hook.split(separator: ";").compactMap { item -> String? in
            guard let open = item.firstIndex(of: "("), let close = item.firstIndex(of: ",") ?? item.firstIndex(of: ")") else { return nil }
            return String(item[item.index(after: open)..<close])
        }
        return RouterHTTPResponse(data: try JSONSerialization.data(withJSONObject: Dictionary(uniqueKeysWithValues: keys.map { ($0, nvram[$0] ?? "") })), status: 200)
    }
    nonisolated func cancel() {}
}

private func client(_ router: CountingRouter, _ writes: WriteScope) throws -> RouterClient {
    RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: router, writes: writes)
}

// MARK: Every request that changes the router passes the write checks

@Test func wizardDetectionAndSpeedTestStateWaitForTheWriteChecks() async throws {
    let router = CountingRouter()
    let unverified = try client(router, .unverified)
    for effect in [QISEffect.autoDetect, .auto46Detect] {
        await #expect(throws: RouterError.self) { try await unverified.qisSend(effect: effect) }
    }
    await #expect(throws: RouterError.self) { try await unverified.qisSend(.apply([("action_mode", .string("apply")), ("rc_service", .string("start_webs_update"))])) }
    await #expect(throws: RouterError.self) { try await unverified.ooklaServers() }
    await #expect(throws: RouterError.self) { try await unverified.setOoklaState("0") }
    // Another firmware line: these follow the 3.0.0.6 web code too.
    let older = try client(router, .verified(branch: .v388, model: "RT-AX86U", menuRead: true))
    await #expect(throws: RouterError.self) { try await older.qisSend(effect: .autoDetect) }
    await #expect(throws: RouterError.self) { try await older.setOoklaState("0") }
    #expect(await router.sent == 0)
    // The reference router sends them.
    try await client(router, .reference).qisSend(effect: .autoDetect)
    #expect(await router.sent == 1)
}

@Test func maintenanceWritesNeedAKnownFirmwareLineAndTheRoutersMenu() async throws {
    let router = CountingRouter()
    for scope in [WriteScope.verified(branch: .unknown, model: "RT-X", menuRead: true),
                  .verified(branch: .legacy, model: "RT-AC66U", menuRead: true),
                  .verified(branch: .v388, model: "RT-AX86U", menuRead: false)] {
        let client = try client(router, scope)
        await #expect(throws: RouterError.self) { try await client.reboot() }
        await #expect(throws: RouterError.self) { try await client.factoryReset() }
        #expect(scope.refusal(for: .identified) != nil)
    }
    #expect(await router.sent == 0)
    for branch in [RouterProfile.Branch.v384, .v386, .v388, .v3006] {
        #expect(WriteScope.verified(branch: branch, model: "RT-X", menuRead: true).refusal(for: .identified) == nil)
    }
    // Renaming and pausing devices follow the 3.0.0.6 web code.
    let older = try client(router, .verified(branch: .v388, model: "RT-AX86U", menuRead: true))
    await #expect(throws: RouterError.self) { try await older.renameDevice(mac: "02:00:5E:00:00:10", name: "x") }
    #expect(await router.sent == 0)
}

// MARK: The main Wi-Fi as an SDN network

@Test func perBandWirelessIsRefusedWhenTheRouterManagesTheMainWiFiAsANetwork() async throws {
    let section = try #require(SettingsCatalog.section("wifi1"))
    let field = try #require(section.fields.first { $0.key == "wl1_ssid" })
    let change = SettingChange(field: field, before: "home", after: "home-5g")
    let base = ["wl1_ssid": "home", "wl1_auth_mode_x": "psk2", "wl1_crypto": "aes", "wl1_mfp": "1", "wl1_wpa_psk": "correct-horse"]
    let mainfh = CountingRouter(base, support: ["sdn_mainfh": "1"])
    await #expect(throws: RouterError.self) { try await client(mainfh, .reference).applySettings(section: section, changes: [change]) }
    let profiles = CountingRouter(base.merging(["sdn_rl": "<1>MAINFH>1>"]) { _, new in new })
    await #expect(throws: RouterError.self) { try await client(profiles, .reference).applySettings(section: section, changes: [change]) }
    // AP isolation on the professional page is such a row too.
    let radio = try #require(SettingsCatalog.section("radio1"))
    let isolate = try #require(radio.fields.first { $0.key == "wl1_ap_isolate" })
    let isolated = CountingRouter(["wl1_ap_isolate": "0"], support: ["sdn_mainfh": "1"])
    await #expect(throws: RouterError.self) {
        try await client(isolated, .reference).applySettings(section: radio, changes: [SettingChange(field: isolate, before: "0", after: "1")])
    }
}

// MARK: Choices the section can save

@Test func bandChoicesAreOnlyWhatTheSectionCanSave() throws {
    let section = try #require(SettingsCatalog.section("wifi1"))
    let crypto = try #require(section.fields.first { $0.key == "wl1_crypto" })
    let context = WirelessSecurityRules.BandContext(sixGHz: false, wifi7Router: true, wifi7Mode: false)
    let saved = Set(crypto.options.map(\.value))
    for auth in ["psk", "psk2", "sae", "psk2sae", "pskpsk2", "wpa2", "suite-b", "owe"] {
        let offered = WirelessSecurityRules.options(for: crypto, values: ["wl1_auth_mode_x": auth], unit: 1, context: context)?.map(\.value) ?? []
        #expect(Set(offered).isSubset(of: saved), "\(auth)")
        for value in offered { try crypto.validate(value) }
    }
    // WPA-Personal would offer TKIP, which the section does not save; Suite B offers nothing the section saves.
    #expect(WirelessSecurityRules.options(for: crypto, values: ["wl1_auth_mode_x": "psk"], unit: 1, context: context)?.map(\.value) == ["aes"])
    #expect(WirelessSecurityRules.options(for: crypto, values: ["wl1_auth_mode_x": "suite-b"], unit: 1, context: context)?.isEmpty == true)
    // A new auth brings a saveable choice.
    let adjusted = WirelessSecurityRules.adjusted(["wl1_auth_mode_x": "psk", "wl1_crypto": "aes+gcmp256", "wl1_mfp": "2"], section: section, context: context)
    #expect(adjusted["wl1_crypto"] == "aes")
}

// MARK: The menu's entry page

@Test func menuEntryThatIsASwitchChoiceStaysUnlessItsPageIsShown() throws {
    let host = try #require(WebMenuCatalog.menus.flatMap(\.pages).first { page in page.parts.contains { $0.url != nil } })
    let switchURL = try #require(host.parts.compactMap(\.url).first)
    let registry = WebMenuRegistry.shared
    #expect(registry.host(ofSwitch: switchURL) == host.id)
    // The host page is excluded on this router: the menu opens at the switch page, which stays as a page of its own.
    let alone = RouterMenuEntry(index: "menu_X", name: "X", visible: true,
                                tabs: [.init(url: host.id, name: "Host", kind: .tab, visible: false), .init(url: switchURL, name: "Switch", kind: .tab, visible: true)],
                                entry: switchURL)
    #expect(WebMenuSet.build(entries: [alone], profile: nil).menu("menu_X")?.pages.map(\.id) == [switchURL])
    // The host page is shown: the switch page is its choice, not a page of its own.
    let both = RouterMenuEntry(index: "menu_X", name: "X", visible: true,
                               tabs: [.init(url: host.id, name: "Host", kind: .tab, visible: true), .init(url: switchURL, name: "Switch", kind: .tab, visible: true)],
                               entry: host.id)
    #expect(WebMenuSet.build(entries: [both], profile: nil).menu("menu_X")?.pages.map(\.id) == [host.id])
}
