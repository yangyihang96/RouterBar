import Foundation
import Testing
@testable import RouterCore

// Synthetic data only: documentation addresses and invented MAC addresses.
private let mainSecurity = "<3>psk2>aes>main-password>1<13>psk2>aes>main-password>1<16>sae>aes>main-password>1<96>sae>aes>main-password>1"
private func values(_ extra: [String: String] = [:]) -> [String: String] {
    var values = [
        "sdn_rl": "<0>Default>1>0>0>0>0>0>0>0>0>0>0>0>0>0>MAIN-TAIL<1>MAINFH>1>0>0>1>0>0>0>0>0>0>0>0>0>0>0>0>0>WEB>0>0>0<2>Guest>1>1>1>1>0>0>0>0>0>0>0>0>0>0>0>0>0>WEB>0>0>0",
        "subnet_rl": "<1>br53>192.168.52.1>255.255.255.0>1>192.168.52.2>192.168.52.254>86400>>,>>0>>0>0>2>1000>2000>,,>0>1>",
        "vlan_rl": "<1>52>0>", "radius_list": "", "sdn_access_rl": "", "vlan_trunklist": "", "qos_enable": "0", "qos_type": "0", "mld_enable": "0",
        "lan_ipaddr": "192.168.50.1", "lan_netmask": "255.255.255.0", "lan_hwaddr": "AA:BB:CC:DD:EE:01",
        "wan0_ipaddr": "192.0.2.10", "wan0_netmask": "255.255.255.0", "wan1_ipaddr": "", "wan1_netmask": "",
        "apm1_ssid": "Home", "apm1_enable": "1", "apm1_security": mainSecurity, "apm1_hide_ssid": "0", "apm1_ap_isolate": "0",
        "apm1_mlo": "0", "apm1_11be": "0", "apm1_dut_list": "<AA:BB:CC:DD:EE:01>3>", "apm1_bw_limit": "<0>>",
        "apg1_ssid": "Guest", "apg1_enable": "1", "apg1_hide_ssid": "0", "apg1_ap_isolate": "1", "apg1_mlo": "0", "apg1_11be": "0",
        "apg1_security": "<3>psk2sae>aes>guest-password>2<13>psk2sae>aes>guest-password>2<16>sae>aes>guest-password>2<96>sae>aes>guest-password>2",
        "apg1_dut_list": "<AA:BB:CC:DD:EE:01>3>", "apg1_bw_limit": "<0>>",
    ]
    for suffix in ["timesched", "sched", "expiretime", "macmode", "maclist", "iot_max_cmpt", "disabled"] { values["apm1_" + suffix] = ""; values["apg1_" + suffix] = "" }
    values.merge(extra) { _, new in new }
    return values
}
private func snapshot(_ extra: [String: String] = [:], wifi7: Bool = true) throws -> SDNSnapshot {
    var snapshot = try SDNSnapshot(values: values(extra)); snapshot.wifi7Supported = wifi7; return snapshot
}
private func main(_ snapshot: SDNSnapshot) throws -> SDNProfile { try #require(snapshot.profiles.first { $0.kind == "MAINFH" }) }
private func guest(_ snapshot: SDNSnapshot) throws -> SDNProfile { try #require(snapshot.profiles.first { $0.kind == "Guest" }) }

// MARK: The switch and what it changes (sdn.js)

@Test func profilesReadTheSwitchMLOAndBands() throws {
    let plain = try snapshot()
    #expect(try main(plain).wifi7 == false); #expect(try main(plain).hasWiFi); #expect(try main(plain).mlo == "0")
    let on = try snapshot(["apm1_11be": "1"]); #expect(try main(on).wifi7)
    // MLO 前传 keeps WiFi7 模式 on whatever _11be holds.
    let mlo = try snapshot(["apm1_mlo": "2"]); #expect(try main(mlo).mloFronthaul); #expect(try main(mlo).wifi7)
    // A network without a Wi-Fi band hides every Wi-Fi setting.
    let wired = try snapshot(["apg1_dut_list": "<AA:BB:CC:DD:EE:01>0>1"]); #expect(try guest(wired).hasWiFi == false)
    #expect(!SDNWiFi7.isOffered(try guest(wired), supported: true))
    #expect(SDNWiFi7.isOffered(try main(plain), supported: true))
    #expect(!SDNWiFi7.isOffered(try main(plain), supported: false))
    var mloNetwork = try main(plain); mloNetwork.kind = "MLO"
    #expect(!SDNWiFi7.isOffered(mloNetwork, supported: true))
}
@Test func switchingOnMovesWPA2AndOpenNetworksToWiFi7Choices() throws {
    var profile = try main(snapshot())
    var on = SDNWiFi7.switchedOn(profile)
    #expect(on.wifi7); #expect(on.auth == "psk2sae"); #expect(on.crypto == "aes")
    profile.auth = "pskpsk2"; profile.crypto = "tkip+aes"
    on = SDNWiFi7.switchedOn(profile); #expect(on.auth == "psk2sae"); #expect(on.crypto == "aes")
    profile.auth = "sae"; profile.crypto = "aes"
    on = SDNWiFi7.switchedOn(profile); #expect(on.auth == "sae"); #expect(on.crypto == "aes")
    // An open network is saved as OWE while WiFi7 模式 is on (sdn.js 9152).
    profile.auth = "open"; profile.password = ""
    on = SDNWiFi7.switchedOn(profile); #expect(on.auth == "owe"); #expect(on.crypto == "aes")
    #expect(SDNWiFi7.cryptoChoices(on).isEmpty)
    // RADIUS auths move to the first WPA3 choice of their selector.
    profile.auth = "wpa2"; #expect(SDNWiFi7.switchedOn(profile).auth == "wpa2wpa3")
}
@Test func switchingOffDropsGCMP256AndOWEAndStopsForMLO() throws {
    var profile = try main(snapshot(["apm1_11be": "1"]))
    profile.auth = "psk2sae"; profile.crypto = "aes+gcmp256"
    #expect(SDNWiFi7.cryptoChoices(profile) == ["aes", "aes+gcmp256"])
    let off = try SDNWiFi7.switchedOff(profile)
    #expect(!off.wifi7); #expect(off.auth == "psk2sae"); #expect(off.crypto == "aes")
    #expect(SDNWiFi7.cryptoChoices(off) == ["aes"])
    profile.auth = "owe"; profile.crypto = "aes"
    #expect(try SDNWiFi7.switchedOff(profile).auth == "open")
    let mlo = try main(snapshot(["apm1_mlo": "2", "apm1_11be": "1"]))
    #expect(throws: RouterError.self) { try SDNWiFi7.switchedOff(mlo) }
    #expect(SDNWiFi7.mloHint == "由于目前已启用 MLO，因此对这些 WiFi 设置进行任何调整都需要先关闭 MLO。")
}
@Test func choosingWPA2WhileWiFi7IsOnAsksAndThenSwitchesItOff() throws {
    let on = SDNWiFi7.switchedOn(try main(snapshot()))
    #expect(SDNWiFi7.asksBeforeChoosing("psk2", in: on))
    #expect(!SDNWiFi7.asksBeforeChoosing("sae", in: on)); #expect(!SDNWiFi7.asksBeforeChoosing("open", in: on))
    let wpa2 = SDNWiFi7.choosing("psk2", in: on)
    #expect(wpa2.auth == "psk2"); #expect(!wpa2.wifi7); #expect(wpa2.crypto == "aes")
    #expect(SDNWiFi7.choosing("sae", in: on).wifi7)
    #expect(SDNWiFi7.choosing("open", in: on).auth == "owe")
    #expect(SDNWiFi7.choosing("open", in: wpa2).auth == "open")
    #expect(!SDNWiFi7.asksBeforeChoosing("psk2", in: wpa2))
}
@Test func authChoicesFollowTheNetworkType() throws {
    let s = try snapshot()
    #expect(SDNWiFi7.authChoices(try main(s)) == ["open", "psk2", "psk2sae", "sae"])
    #expect(SDNWiFi7.authChoices(try guest(s)) == ["open", "psk2", "psk2sae", "sae"])
    var kids = try guest(s); kids.kind = "Kids"
    #expect(SDNWiFi7.authChoices(kids) == ["psk2", "psk2sae", "sae"])
    #expect(SDNWiFi7.authChoices(try main(snapshot(["apm1_mlo": "2"]))) == ["open", "psk2sae", "sae"])
    // get_elem_attr_wifi_auth(): 6 GHz alone gets the 6G selector, 6 GHz with another band the MLO one.
    let sixGHz = try guest(snapshot(["apg1_dut_list": "<AA:BB:CC:DD:EE:01>80>"]))
    #expect(sixGHz.bands == 80); #expect(SDNWiFi7.authChoices(sixGHz) == ["open", "sae"])
    #expect(SDNWiFi7.authChoices(try guest(snapshot(["apg1_dut_list": "<AA:BB:CC:DD:EE:01>17>"]))) == ["open", "psk2sae", "sae"])
}
@Test func authOutsideTheBandsSelectorIsRefused() throws {
    let s = try snapshot(["apg1_dut_list": "<AA:BB:CC:DD:EE:01>80>", "apg1_security": "<3>sae>aes>guest-password>2<13>sae>aes>guest-password>2<16>sae>aes>guest-password>2<96>sae>aes>guest-password>2"])
    var profile = try guest(s); profile.auth = "psk2sae"
    #expect(throws: RouterError.validation("按这个网络使用的频段，路由器网页的认证选单只有 WPA3-Personal。")) { try SDNPlanner.edit(profile, snapshot: s) }
    profile = SDNWiFi7.switchedOn(try guest(s))
    #expect(try SDNPlanner.edit(profile, snapshot: s).fields == ["apg1_11be": "1"])
    let mixed = try snapshot(["apg1_dut_list": "<AA:BB:CC:DD:EE:01>17>"])
    var wpa2 = try guest(mixed); wpa2.auth = "psk2"
    #expect(throws: RouterError.self) { try SDNPlanner.edit(wpa2, snapshot: mixed) }
}

// MARK: The plan

@Test func turningWiFi7OnWritesTheSwitchAndEveryBandInOneSave() throws {
    let s = try snapshot()
    let plan = try SDNPlanner.edit(SDNWiFi7.switchedOn(try main(s)), snapshot: s)
    #expect(plan.fields["apm1_11be"] == "1")
    #expect(plan.fields["apm1_security"] == mainSecurity.replacingOccurrences(of: "<3>psk2>", with: "<3>psk2sae>").replacingOccurrences(of: "<13>psk2>", with: "<13>psk2sae>"))
    #expect(Set(plan.fields.keys) == ["apm1_11be", "apm1_security"])
    #expect(plan.expected["apm1_11be"] == "0"); #expect(plan.expected["apm1_mlo"] == "0"); #expect(plan.expected["apm1_security"] == mainSecurity)
    #expect(plan.service == "restart_wireless;restart_sdn 1;")
    let wifi7 = try #require(plan.changes.first { $0.key == "apm1_11be" })
    #expect(wifi7.title == "WiFi7 模式"); #expect(wifi7.before == "关闭"); #expect(wifi7.after == "开启")
    let security = try #require(plan.changes.first { $0.key == "apm1_security" })
    #expect(security.before.hasPrefix("2.4 GHz + 5 GHz：WPA2-Personal · AES"))
    #expect(security.after.hasPrefix("2.4 GHz + 5 GHz：WPA2/WPA3-Personal · AES"))
    #expect(plan.changes.allSatisfy { !$0.before.contains("main-password") && !$0.after.contains("main-password") })
    #expect(plan.warnings.count == 2)
    // Already WPA3-capable: only the switch changes.
    let wpa3 = try snapshot(["apm1_security": mainSecurity.replacingOccurrences(of: ">psk2>", with: ">psk2sae>")])
    #expect(try SDNPlanner.edit(SDNWiFi7.switchedOn(try main(wpa3)), snapshot: wpa3).fields == ["apm1_11be": "1"])
}
@Test func turningWiFi7OffNormalizesEveryBand() throws {
    let s = try snapshot(["apm1_11be": "1", "apm1_security": "<3>psk2sae>aes+gcmp256>main-password>1<13>psk2sae>aes>main-password>1<16>sae>aes+gcmp256>main-password>1<96>sae>aes+gcmp256>main-password>1"])
    let plan = try SDNPlanner.edit(try SDNWiFi7.switchedOff(try main(s)), snapshot: s)
    #expect(plan.fields["apm1_11be"] == "0")
    #expect(plan.fields["apm1_security"] == "<3>psk2sae>aes>main-password>1<13>psk2sae>aes>main-password>1<16>sae>aes>main-password>1<96>sae>aes>main-password>1")
    // An OWE network becomes open again on 2.4 / 5 GHz; 6 GHz keeps OWE.
    let owe = try snapshot(["apm1_11be": "1", "apm1_security": "<3>owe>aes>>1<13>owe>aes>>1<16>owe>aes>>1<96>owe>aes>>1"])
    #expect(try SDNPlanner.edit(try SDNWiFi7.switchedOff(try main(owe)), snapshot: owe).fields["apm1_security"] == "<3>open>aes>>1<13>open>aes>>1<16>owe>aes>>1<96>owe>aes>>1")
}
@Test func securityRowsThePageWouldRewriteAreLeftToThePage() throws {
    // A firmware-made single <127> row: the page saves it as <3><13><16><96> and rebuilds the device list
    // (get_legacy_dut_list), so the app refuses auth, encryption and WiFi7 模式 changes there but keeps password edits.
    let s = try snapshot(["apg1_security": "<127>psk2>aes>guest-password>2"])
    let legacy = try guest(s)
    #expect(!legacy.standardSecurity); #expect(try guest(snapshot()).standardSecurity)
    #expect(throws: RouterError.validation(SDNSecurity.nonstandardNote)) { try SDNPlanner.edit(SDNWiFi7.switchedOn(legacy), snapshot: s) }
    var sae = legacy; sae.auth = "sae"
    #expect(throws: RouterError.validation(SDNSecurity.nonstandardNote)) { try SDNPlanner.edit(sae, snapshot: s) }
    var password = legacy; password.password = "new-guest-password"
    #expect(try SDNPlanner.edit(password, snapshot: s).fields == ["apg1_security": "<127>psk2>aes>new-guest-password>2"])
}
@Test func newGuestNetworkCanStartWithWiFi7() throws {
    let s = try snapshot()
    var profile = try SDNPlanner.newGuest(snapshot: s); profile.password = "guest-secret"
    profile = SDNWiFi7.switchedOn(profile)
    let plan = try SDNPlanner.create(profile, snapshot: s)
    #expect(plan.fields["apg2_11be"] == "1")
    #expect(plan.fields["apg2_security"]?.hasPrefix("<3>psk2sae>aes>guest-secret>") == true)
    #expect(throws: RouterError.self) { try SDNPlanner.create(profile, snapshot: try snapshot(wifi7: false)) }
}
@Test func planRefusesWhatTheSDNPageCannotSave() throws {
    let s = try snapshot()
    // No switch on this firmware, on an MLO network, or while MLO 前传 holds it on.
    #expect(throws: RouterError.self) { try SDNPlanner.edit(SDNWiFi7.switchedOn(try main(s)), snapshot: try snapshot(wifi7: false)) }
    let mlo = try snapshot(["apm1_mlo": "2", "apm1_security": mainSecurity.replacingOccurrences(of: ">psk2>", with: ">psk2sae>")])
    var forced = try main(mlo); forced.wifi7 = false
    #expect(throws: RouterError.self) { try SDNPlanner.edit(forced, snapshot: mlo) }
    // WiFi7 模式 on with WPA2, or an open network that is not saved as OWE.
    var wpa2 = SDNWiFi7.switchedOn(try main(s)); wpa2.auth = "psk2"
    #expect(throws: RouterError.self) { try SDNPlanner.edit(wpa2, snapshot: s) }
    var open = SDNWiFi7.switchedOn(try main(s)); open.auth = "open"; open.password = ""
    #expect(throws: RouterError.self) { try SDNPlanner.edit(open, snapshot: s) }
    // OWE only with WiFi7 模式; GCMP-256 only with WiFi7 模式 and never alone.
    var owe = try main(s); owe.auth = "owe"; owe.password = ""
    #expect(throws: RouterError.self) { try SDNPlanner.edit(owe, snapshot: s) }
    var gcmp = try guest(s); gcmp.crypto = "aes+gcmp256"
    #expect(throws: RouterError.self) { try SDNPlanner.edit(gcmp, snapshot: s) }
    gcmp.wifi7 = true; _ = try SDNPlanner.edit(gcmp, snapshot: s)
    gcmp.crypto = "gcmp256"
    #expect(throws: RouterError.self) { try SDNPlanner.edit(gcmp, snapshot: s) }
    // Only the main and guest networks offer an open network.
    var kids = try snapshot(["sdn_rl": values()["sdn_rl"]!.replacingOccurrences(of: "<2>Guest>", with: "<2>Kids>")])
    kids.wifi7Supported = true
    var child = try #require(kids.profiles.first { $0.kind == "Kids" }); child.auth = "open"; child.password = ""
    #expect(throws: RouterError.self) { try SDNPlanner.edit(child, snapshot: kids) }
}
@Test func networksThePageDoesNotListOfferNoSwitch() throws {
    // show_sdn_profilelist() skips MAINBH and MLO backhaul networks (_mlo "1" with a "*" dut_list entry), so their
    // settings, WiFi7 模式 included, are never on the page.
    var backhaul = try main(snapshot()); backhaul.kind = "MAINBH"
    #expect(!backhaul.listedOnWebPage); #expect(!SDNWiFi7.isOffered(backhaul, supported: true))
    let mloBackhaul = try guest(snapshot(["apg1_mlo": "1", "apg1_dut_list": "<*>3>"]))
    #expect(mloBackhaul.mloBackhaul); #expect(!SDNWiFi7.isOffered(mloBackhaul, supported: true))
    // `_mlo` "1" without a "*" entry is still listed.
    let listed = try guest(snapshot(["apg1_mlo": "1"]))
    #expect(!listed.mloBackhaul); #expect(SDNWiFi7.isOffered(listed, supported: true))
    // The page removes their apply and delete buttons too (7443–7448): every save or deletion is refused before
    // anything is sent, and the editor locks auth, encryption and WiFi7 模式.
    let s = try snapshot(["sdn_rl": values()["sdn_rl"]!.replacingOccurrences(of: "<1>MAINFH>", with: "<1>MAINBH>")])
    let bh = try #require(s.profiles.first { $0.kind == "MAINBH" })
    #expect(bh.hasWiFi); #expect(SDNSecurity.lockedReason(bh) == SDNSecurity.unlistedNote)
    #expect(throws: RouterError.validation(SDNSecurity.unlistedNote)) { try SDNPlanner.edit(SDNWiFi7.switchedOn(bh), snapshot: s) }
    var renamed = bh; renamed.ssid = "Backhaul"
    #expect(throws: RouterError.validation(SDNSecurity.unlistedNote)) { try SDNPlanner.edit(renamed, snapshot: s) }
    let mlo = try snapshot(["apg1_mlo": "1", "apg1_dut_list": "<*>3>"])
    var disabled = try guest(mlo); disabled.enabled = false
    #expect(throws: RouterError.validation(SDNSecurity.unlistedNote)) { try SDNPlanner.edit(disabled, snapshot: mlo) }
    #expect(throws: RouterError.validation(SDNSecurity.unlistedNote)) { try SDNPlanner.delete(try guest(mlo), snapshot: mlo) }
}
@Test func passwordsFollowThePagesRules() throws {
    // valid_psk: an 8–63 character passphrase or a 64-digit hexadecimal key.
    let s = try snapshot()
    var profile = try guest(s)
    profile.password = String(repeating: "0123456789abcdef", count: 4)
    #expect(try SDNPlanner.edit(profile, snapshot: s).fields["apg1_security"]?.contains(">\(profile.password)>") == true)
    profile.password = String(repeating: "0123456789abcdeg", count: 4)
    #expect(throws: RouterError.self) { try SDNPlanner.edit(profile, snapshot: s) }
    profile.password = String(repeating: "a", count: 65)
    #expect(throws: RouterError.self) { try SDNPlanner.edit(profile, snapshot: s) }
    // A network with an enterprise or WPA/WPA2 auth is left to the web page as a whole.
    var radius = try guest(snapshot(["apg1_security": "<3>wpa2wpa3>aes>>2<13>wpa2wpa3>aes>>2<16>wpa3>aes>>2<96>wpa3>aes>>2"]))
    #expect(SDNSecurity.lockedReason(radius)?.contains("WPA2/WPA3-Enterprise") == true)
    radius.ssid = "Office"
    #expect(throws: RouterError.self) { try SDNPlanner.edit(radius, snapshot: try snapshot(["apg1_security": "<3>wpa2wpa3>aes>>2<13>wpa2wpa3>aes>>2<16>wpa3>aes>>2<96>wpa3>aes>>2"])) }
    #expect(SDNSecurity.lockedReason(try guest(s)) == nil)
}
@Test func professionalPageRowsHiddenUnderSDNExist() throws {
    for unit in 0...1 {
        let radio = try #require(SettingsCatalog.sections.first { $0.id == "radio\(unit)" })
        #expect(radio.fields.contains { $0.key == "wl\(unit)_11be" && $0.kind == "readonly" })
        #expect(radio.fields.contains { $0.key == "wl\(unit)_ap_isolate" })
        #expect(WebMenuCatalog.condition(ofField: "wl\(unit)_11be") == .perBandWireless)
        #expect(WebMenuCatalog.condition(ofField: "wl\(unit)_ap_isolate") == .perBandWireless)
    }
    #expect(WebMenuCatalog.condition(ofField: "wl0_nmode_x") == nil)
}

// MARK: The save, against a mock router

private actor SDNRouter: RouterTransport {
    var nvram: [String: String]
    let support: [String: Int]
    var dropsApplyReply = false
    var requests: [URLRequest] = []
    init(_ nvram: [String: String], support: [String: Int] = ["wifi7": 1, "mlo": 1, "sdn_mainfh": 1]) { self.nvram = nvram; self.support = support }
    func set(_ key: String, _ value: String) { nvram[key] = value }
    func dropApplyReply() { dropsApplyReply = true }
    func send(_ request: URLRequest) async throws -> RouterHTTPResponse {
        requests.append(request)
        guard let url = request.url else { throw RouterError.network("No URL") }
        if url.path.hasSuffix("applyapp.cgi") {
            let fields = Self.fields(request) ?? [:]
            for (key, value) in fields where !["action_mode", "rc_service"].contains(key) && !key.hasSuffix("_x") { nvram[key] = value }
            if dropsApplyReply { throw URLError(.networkConnectionLost) }
            return try Self.reply(["modify": "1", "run_service": fields["rc_service"] ?? ""])
        }
        let hook = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "hook" }?.value ?? ""
        if hook == "get_ui_support()" { return try Self.reply(["get_ui_support": support]) }
        var object: [String: String] = [:]
        for call in hook.split(separator: ";") {
            guard let open = call.firstIndex(of: "("), let comma = call.firstIndex(of: ",") else { continue }
            let key = String(call[call.index(after: open)..<comma]); object[key] = nvram[key] ?? ""
        }
        return try Self.reply(object)
    }
    nonisolated func cancel() {}
    var posts: [[String: String]] { requests.filter { $0.httpMethod == "POST" }.compactMap(Self.fields) }
    static func fields(_ request: URLRequest) -> [String: String]? {
        request.httpBody.flatMap { String(decoding: $0, as: UTF8.self).removingPercentEncoding }
            .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String] }
    }
    static func reply(_ object: Any) throws -> RouterHTTPResponse { RouterHTTPResponse(data: try JSONSerialization.data(withJSONObject: object), status: 200) }
}
private func client(_ router: SDNRouter) throws -> RouterClient { RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: router, writes: .reference) }
/// The planner's plan without the wait for the router to restart its Wi-Fi.
private func immediate(_ plan: SDNPlan) -> SDNPlan { SDNPlan(fields: plan.fields, expected: plan.expected, service: plan.service, summary: plan.summary, wait: 0) }

@Test func wifi7SaveIsCheckedSentOnceAndReadBack() async throws {
    let router = SDNRouter(values())
    let client = try client(router)
    let s = try await client.sdnSnapshot()
    #expect(s.wifi7Supported)
    let plan = try SDNPlanner.edit(SDNWiFi7.switchedOn(try main(s)), snapshot: s)
    let receipt = try await client.applySDN(immediate(plan))
    #expect(receipt.isVerified)
    let posts = await router.posts
    #expect(posts.count == 1)
    #expect(posts.first?["apm1_11be"] == "1"); #expect(posts.first?["apm1_security"] == plan.fields["apm1_security"])
    #expect(posts.first?["action_mode"] == "apply"); #expect(posts.first?["rc_service"] == "restart_wireless;restart_sdn 1;")
    #expect(Set(try #require(posts.first).keys) == ["apm1_11be", "apm1_security", "action_mode", "rc_service"])
}
@Test func wifi7SaveStopsWhenTheRouterChangedMeanwhile() async throws {
    let router = SDNRouter(values())
    let client = try client(router)
    let s = try await client.sdnSnapshot()
    let plan = try SDNPlanner.edit(SDNWiFi7.switchedOn(try main(s)), snapshot: s)
    await router.set("apm1_mlo", "2")
    await #expect(throws: RouterError.self) { try await client.applySDN(immediate(plan)) }
    #expect(await router.posts.isEmpty)
}
@Test func wifi7SaveWithALostReplyIsReportedUnconfirmed() async throws {
    let router = SDNRouter(values())
    let client = try client(router)
    let s = try await client.sdnSnapshot()
    let plan = try SDNPlanner.edit(SDNWiFi7.switchedOn(try main(s)), snapshot: s)
    await router.dropApplyReply()
    let receipt = try await client.applySDN(immediate(plan))
    #expect(!receipt.isVerified); #expect(receipt.verified.isEmpty)
    #expect(Set(receipt.unverified) == ["apm1_11be", "apm1_security"])
    #expect(await router.posts.count == 1)
}
@Test func firmwareWithoutWiFi7HidesTheSwitch() async throws {
    let router = SDNRouter(values(), support: ["mlo": 0, "sdn_mainfh": 1])
    let s = try await client(router).sdnSnapshot()
    #expect(!s.wifi7Supported)
    #expect(!SDNWiFi7.isOffered(try main(s), supported: s.wifi7Supported))
}
