import Foundation
import Testing
@testable import RouterCore

extension WriteScope {
    /// The reference router, identified, with its menu read: what the tests' clients may write to.
    static let reference = WriteScope.verified(branch: .v3006, model: RouterProfile.referenceModel, menuRead: true)
}

// MARK: Bounded child processes

private let sh = URL(fileURLWithPath: "/bin/sh")
private func limits(timeout: TimeInterval = 5, output: Int = 1_000_000, memory: UInt64 = 1 << 30) -> BoundedProcess.Limits {
    .init(timeout: timeout, outputLimit: output, memoryLimit: memory)
}

@Test func boundedProcessHandsItsInputToTheChildAndReturnsItsOutput() async throws {
    let input = Data((0..<200_000).map { UInt8($0 % 251) })
    let output = try await BoundedProcess.run(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], input: input, limits: limits())
    #expect(output == input)
}

@Test func boundedProcessKillsAChildThatDoesNotFinish() async {
    let start = Date()
    await #expect(throws: BoundedProcess.Failure.timeout) {
        try await BoundedProcess.run(executable: sh, arguments: ["-c", "while :; do :; done"], input: Data(), limits: limits(timeout: 0.3))
    }
    #expect(Date().timeIntervalSince(start) < 2)
}

@Test func boundedProcessKillsAChildThatWritesTooMuch() async {
    await #expect(throws: BoundedProcess.Failure.outputTooLarge) {
        try await BoundedProcess.run(executable: URL(fileURLWithPath: "/usr/bin/yes"), arguments: [], input: Data(), limits: limits(output: 10_000))
    }
}

@Test func boundedProcessKillsAChildPastItsMemoryLimit() async {
    // Every process uses more than one kilobyte; the limit is what is tested, not an allocation.
    await #expect(throws: BoundedProcess.Failure.memory) {
        try await BoundedProcess.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], input: Data(), limits: limits(memory: 1_024))
    }
}

@Test func boundedProcessReportsExitStatusAndSurvivesAChildThatIgnoresItsInput() async throws {
    await #expect(throws: BoundedProcess.Failure.exit(3)) {
        try await BoundedProcess.run(executable: sh, arguments: ["-c", "exit 3"], input: Data(), limits: limits())
    }
    // Input the child never reads must not end this process with SIGPIPE.
    let output = try await BoundedProcess.run(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [],
                                              input: Data(count: 4_000_000), limits: limits())
    #expect(output.isEmpty)
}

@Test func boundedProcessStopsTheChildWhenTheTaskIsCancelled() async {
    let start = Date()
    let task = Task { try await BoundedProcess.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], input: Data(), limits: limits(timeout: 20)) }
    try? await Task.sleep(for: .milliseconds(200))
    task.cancel()
    await #expect(throws: BoundedProcess.Failure.cancelled) { try await task.value }
    #expect(Date().timeIntervalSince(start) < 3)
}

// MARK: Menu evaluation in a child

private let tinyState = """
var ui_lang = "EN";
function isSupport(name){ return 0; }
var isSwMode = function(mode){ return mode === "RT"; };
"""
private func tinyTree(_ list: String, tabs: String = "") -> String {
    "define(function(){ return { list: [\(list)], exclude: { menus: function(){ return []; }, tabs: function(){ var retArray = []; \(tabs) return retArray; } } }; });"
}
private let tinyList = #"{ menuName: "Tools", index: "menu_Tools", tab: [ {url: "Tools_Sysinfo.asp", tabName: "Sysinfo"} ] }"#

/// A stand-in child that ignores the request and answers `reply`.
private func fakeHelper(_ reply: String) -> [String] { ["-c", "cat > /dev/null; printf '%s' '\(reply)'"] }

@Test func evaluatorTakesTheChildsReplyAndChecksIt() async throws {
    let served = RouterMenuEvaluator.serve(try JSONEncoder().encode(RouterMenuEvaluator.Request(state: tinyState, menuTree: tinyTree(tinyList))))
    let reply = String(decoding: served, as: UTF8.self)
    #expect(!reply.contains("'"))
    let result = try await RouterMenuEvaluator.evaluate(state: "", menuTree: "", helper: sh, arguments: fakeHelper(reply))
    #expect(result.menus.map(\.index) == ["menu_Tools"])

    await #expect(throws: RouterMenuEvaluator.Failure.timeout) {
        try await RouterMenuEvaluator.evaluate(state: "", menuTree: "", helper: sh, arguments: fakeHelper(#"{"failure":{"timeout":{}}}"#))
    }
    await #expect(throws: RouterMenuEvaluator.Failure.shape("求值结果")) {
        try await RouterMenuEvaluator.evaluate(state: "", menuTree: "", helper: sh, arguments: fakeHelper("not json"))
    }
    // However it was produced, a menu past the bounds is refused.
    let tab = RouterMenuEntry.Tab(url: "a.asp", name: "a", kind: .tab, visible: true)
    let huge = RouterMenuEvaluator.Result(menus: Array(repeating: RouterMenuEntry(index: "menu_X", name: "X", visible: true, tabs: [tab], entry: "a.asp"), count: 200),
                                          facts: RouterWebFacts(), notes: [])
    let encoded = String(decoding: try JSONEncoder().encode(RouterMenuEvaluator.Reply(result: huge, failure: nil)), as: UTF8.self)
    await #expect(throws: RouterMenuEvaluator.Failure.tooLarge) {
        try await RouterMenuEvaluator.evaluate(state: "", menuTree: "", helper: sh, arguments: fakeHelper(encoded))
    }
}

@Test func evaluatorChildKeepsItsAnswerWithinBounds() throws {
    let many = (0..<200).map { #"{ menuName: "M\#($0)", index: "menu_\#($0)", tab: [ {url: "P\#($0).asp", tabName: "P"} ] }"# }.joined(separator: ",")
    #expect(throws: RouterMenuEvaluator.Failure.tooLarge) { try RouterMenuEvaluator.run(state: tinyState, menuTree: tinyTree(many)) }
    let long = #"{ menuName: "Long", index: "menu_Long", tab: [ {url: "\#(String(repeating: "x", count: 400)).asp", tabName: "L"} ] }"#
    #expect(throws: RouterMenuEvaluator.Failure.tooLarge) { try RouterMenuEvaluator.run(state: tinyState, menuTree: tinyTree(long)) }
    let reply = try JSONDecoder().decode(RouterMenuEvaluator.Reply.self, from: RouterMenuEvaluator.serve(Data("garbage".utf8)))
    #expect(reply.failure == .shape("求值请求"))
}

@Test func evaluatorRetriesFromAFreshContext() throws {
    // exclude.tabs() changes the list before it reads a global this firmware never defines; it must change it once.
    let list = """
    { menuName: "Wireless", index: "menu_Wireless", tab: [ {url: "A.asp", tabName: "A"}, {url: "B.asp", tabName: "B"}, {url: "C.asp", tabName: "C"} ] }
    """
    let tree = """
    define(function(){ var tree = { list: [\(list)], exclude: { menus: function(){ return []; },
      tabs: function(){ tree.list[0].tab.splice(0, 1); if (late_flag) return ["X"]; return []; } } }; return tree; });
    """
    let result = try RouterMenuEvaluator.run(state: tinyState, menuTree: tree)
    #expect(result.menus.first?.tabs.map(\.url) == ["B.asp", "C.asp"])
    #expect(result.notes.contains { $0.contains("late_flag") })
}

@Test func evaluatorKeepsTheModemTabOnlyWhereTheRoutersOwnShowMenuTreeDoes() throws {
    // 3.0.0.6 getTabCode keeps an excluded Modem tab in the USB application menu in router mode.
    let rule = #"function showMenuTree(menuList, menuExclude){ if(curTab.url.indexOf("Advanced_Modem_Content") == -1) return; }"#
    let list = """
    { menuName: "WAN", index: "menu_WAN", tab: [ {url: "Advanced_WAN_Content.asp", tabName: "Internet"}, {url: "Advanced_Modem_Content.asp", tabName: "USB"} ] },
    { menuName: "USB", index: "menu_APP", tab: [ {url: "APP_Installation.asp", tabName: "__HIDE__"}, {url: "Advanced_Modem_Content.asp", tabName: "3G/4G"} ] }
    """
    let tree = tinyTree(list, tabs: #"retArray.push("Advanced_Modem_Content.asp");"#)
    let modem = { (result: RouterMenuEvaluator.Result, menu: String) in
        result.menus.first { $0.index == menu }?.tabs.first { $0.url == "Advanced_Modem_Content.asp" }?.visible
    }
    let v3006 = try RouterMenuEvaluator.run(state: tinyState + rule, menuTree: tree)
    #expect(modem(v3006, "menu_APP") == true)
    #expect(modem(v3006, "menu_WAN") == false)
    let older = try RouterMenuEvaluator.run(state: tinyState + "function showMenuTree(menuList, menuExclude){}", menuTree: tree)
    #expect(modem(older, "menu_APP") == false)
    #expect(modem(older, "menu_WAN") == false)
}

/// With ROUTERBAR_HELPER set to a built RouterBar executable, the real child: a script that never ends or allocates
/// without end is stopped, and a menu still evaluates.
@Test func evaluatorChildIsStoppedByItsLimits() async throws {
    guard let path = ProcessInfo.processInfo.environment["ROUTERBAR_HELPER"] else { return }
    let helper = URL(fileURLWithPath: path)
    let ok = try await RouterMenuEvaluator.evaluate(state: tinyState, menuTree: tinyTree(tinyList), helper: helper)
    #expect(ok.menus.count == 1)
    var start = Date()
    await #expect(throws: RouterMenuEvaluator.Failure.timeout) {
        try await RouterMenuEvaluator.evaluate(state: tinyState, menuTree: "define(function(){ while (true) {} });", helper: helper, timeout: 1)
    }
    #expect(Date().timeIntervalSince(start) < 3)
    start = Date()
    await #expect(throws: RouterMenuEvaluator.Failure.tooLarge) {
        try await RouterMenuEvaluator.evaluate(state: "var keep = []; while (true) { keep.push(new Array(1000000).fill(1)); }", menuTree: tinyTree(tinyList), helper: helper)
    }
    #expect(Date().timeIntervalSince(start) < 5)
}

// MARK: Menu set

private func entry(_ index: String, _ tabs: [(String, RouterMenuEntry.TabKind, Bool)], entry: String? = nil) -> RouterMenuEntry {
    RouterMenuEntry(index: index, name: index, visible: true, tabs: tabs.map { .init(url: $0.0, name: $0.0, kind: $0.1, visible: $0.2) },
                    entry: entry ?? tabs.first { $0.2 }?.0)
}

@Test func menuSetKeepsTheEntryPageWithoutNativeContent() {
    // Alexa hidden, IFTTT the entry: both are __INHERIT__ pages; IFTTT has no native page.
    let alexa = entry("menu_Alexa_IFTTT", [("Advanced_Smart_Home_Alexa.asp", .subpage, false), ("Advanced_Smart_Home_IFTTT.asp", .subpage, true)],
                      entry: "Advanced_Smart_Home_IFTTT.asp")
    let set = WebMenuSet.build(entries: [alexa], profile: nil)
    let menu = set.menu("menu_Alexa_IFTTT")
    #expect(menu?.pages.map(\.id) == ["Advanced_Smart_Home_IFTTT.asp"])
    #expect(menu?.pages.first?.kind == .landing)
    if case .pending = menu?.pages.first?.parts.first?.content {} else { Issue.record("IFTTT should be an explanation") }
}

@Test func menuSetOffersOnlySwitchPagesTheRouterListsAndShows() throws {
    let registry = WebMenuRegistry.shared
    let withSwitch = try #require(WebMenuCatalog.menus.flatMap(\.pages).first { page in page.parts.contains { $0.url != nil } })
    let switchURLs = withSwitch.parts.compactMap(\.url)
    let menu = try #require(WebMenuCatalog.menus.first { $0.pages.contains(withSwitch) })
    let own = entry(menu.id, [(withSwitch.id, .tab, true)])
    // The switch pages are not listed at all: their choices go.
    let bare = WebMenuSet.build(entries: [own], profile: nil).menu(menu.id)?.page(withSwitch.id)
    #expect(bare?.parts.allSatisfy { $0.url == nil } == true)
    // Listed and shown: they stay.
    let listed = entry(menu.id, [(withSwitch.id, .tab, true)] + switchURLs.map { ($0, .subpage, true) })
    let full = WebMenuSet.build(entries: [listed], profile: nil).menu(menu.id)?.page(withSwitch.id)
    #expect(Set(full?.parts.compactMap(\.url) ?? []) == Set(switchURLs))
    #expect(registry.page(withSwitch.id) != nil)
}

@Test func fallbackMenuKeepsWritesOfTheReferenceWebAsExplanations() {
    let set = WebMenuSet.fallback("测试", profile: nil)
    let parts = set.menus.flatMap(\.pages).flatMap(\.parts)
    #expect(!parts.contains { if case .native(let feature) = $0.content { feature.followsReferenceWebCode } else { false } })
    #expect(parts.contains { if case .settings = $0.content { true } else { false } })
    #expect(set.source == .fallback("测试"))
}

// MARK: Write scope

private actor NVRAMRouter: RouterTransport {
    var nvram: [String: String]
    var support: [String: String]
    var posts = 0
    init(_ nvram: [String: String], support: [String: String] = [:]) { self.nvram = nvram; self.support = support }
    func send(_ request: URLRequest) async throws -> RouterHTTPResponse {
        if request.httpMethod == "POST" { posts += 1; return RouterHTTPResponse(data: Data("<script>done</script>".utf8), status: 200) }
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "hook" }?.value ?? ""
        if query.contains("get_ui_support") {
            return RouterHTTPResponse(data: try JSONSerialization.data(withJSONObject: ["get_ui_support": support]), status: 200)
        }
        let keys = query.split(separator: ";").compactMap { hook -> String? in
            guard let open = hook.firstIndex(of: "("), let comma = hook.firstIndex(of: ",") ?? hook.firstIndex(of: ")") else { return nil }
            return String(hook[hook.index(after: open)..<comma])
        }
        let object = Dictionary(uniqueKeysWithValues: keys.map { ($0, nvram[$0] ?? "") })
        return RouterHTTPResponse(data: try JSONSerialization.data(withJSONObject: object), status: 200)
    }
    nonisolated func cancel() {}
}

private func sectionAndChange(_ id: String, _ key: String, _ before: String, _ after: String) throws -> (SettingSection, SettingChange) {
    let section = try #require(SettingsCatalog.section(id))
    let field = try #require(section.fields.first { $0.key == key })
    return (section, SettingChange(field: field, before: before, after: after))
}

@Test func nothingIsWrittenBeforeTheRouterIsIdentified() async throws {
    let router = NVRAMRouter(["wl0_bss_maxassoc": "64"])
    let (section, change) = try sectionAndChange("radio0", "wl0_bss_maxassoc", "64", "32")
    let unverified = RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: router)
    await #expect(throws: RouterError.self) { try await unverified.applySettings(section: section, changes: [change]) }
    await #expect(throws: RouterError.self) { try await unverified.reboot() }

    // A 3.0.0.4.388 router: written from the 3.0.0.6 web code is refused, a restart is not.
    let older = RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: router, writes: .verified(branch: .v388, model: "RT-AX86U", menuRead: true))
    await #expect(throws: RouterError.self) { try await older.applySettings(section: section, changes: [change]) }
    #expect(await older.writeScope.refusal(for: .identified) == nil)
    // A 3.0.0.6 router whose menu could not be read, or another model's professional settings.
    let unread = RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: router, writes: .verified(branch: .v3006, model: RouterProfile.referenceModel, menuRead: false))
    await #expect(throws: RouterError.self) { try await unread.applySettings(section: section, changes: [change]) }
    let other = RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: router, writes: .verified(branch: .v3006, model: "GT-BE98", menuRead: true))
    await #expect(throws: RouterError.validation(SettingsCompatibility.modelSpecificText)) { try await other.applySettings(section: section, changes: [change]) }
    #expect(await router.posts == 0)
    #expect(SettingsCompatibility.readOnlyReason(sectionID: "wifi0", writes: .verified(branch: .v3006, model: "GT-BE98", menuRead: true)) == nil)
    #expect(SettingsCompatibility.readOnlyReason(sectionID: "radio0", writes: .verified(branch: .v3006, model: "GT-BE98", menuRead: true)) != nil)
    #expect(SettingsCompatibility.readOnlyReason(sectionID: "lan", writes: .unverified) != nil)
}

// MARK: Band security (Advanced_Wireless_Content.asp, js/asus.js)

@Test func bandSecurityChoicesFollowTheWebPage() {
    typealias Rules = WirelessSecurityRules
    #expect(Rules.cryptoChoices(auth: "psk2", wifi7Mode: true) == ["aes"])
    #expect(Rules.cryptoChoices(auth: "sae", wifi7Mode: false) == ["aes"])
    #expect(Rules.cryptoChoices(auth: "sae", wifi7Mode: true) == ["aes+gcmp256"])
    #expect(Rules.cryptoChoices(auth: "psk2sae", wifi7Mode: true) == ["aes+gcmp256"])
    #expect(Rules.cryptoChoices(auth: "pskpsk2", wifi7Mode: false) == ["aes", "tkip+aes"])
    #expect(Rules.cryptoChoices(auth: "open", wifi7Mode: true) == nil)
    #expect(Rules.mfpChoices(auth: "sae") == ["2"])
    #expect(Rules.mfpChoices(auth: "owe") == ["2"])
    #expect(Rules.mfpChoices(auth: "psk2sae") == ["1", "2"])
    #expect(Rules.mfpChoices(auth: "psk2") == ["0", "1", "2"])
    #expect(Rules.mfpChoices(auth: "open") == nil)
    let six = Rules.BandContext(sixGHz: true, wifi7Router: false, wifi7Mode: false)
    #expect(Rules.allowsAuth("sae", six) && !Rules.allowsAuth("psk2", six) && !Rules.allowsAuth("owe", six))
    #expect(Rules.allowsAuth("owe", .init(sixGHz: true, wifi7Router: true, wifi7Mode: true)))
    // A new auth brings the first encryption and protection the page offers for it.
    let adjusted = Rules.adjusted(["wl1_auth_mode_x": "sae", "wl1_crypto": "aes", "wl1_mfp": "0"], section: SettingsCatalog.section("wifi1")!,
                                  context: .init(sixGHz: false, wifi7Router: true, wifi7Mode: true))
    #expect(adjusted["wl1_crypto"] == "aes+gcmp256" && adjusted["wl1_mfp"] == "2")
}

@Test func bandSecurityIsCheckedWholeEvenWhenOnlyProtectionChanges() async throws {
    // WPA3-Personal requires protected management frames; switching them off alone must not pass.
    let router = NVRAMRouter(["wl1_auth_mode_x": "sae", "wl1_crypto": "aes", "wl1_mfp": "2", "wl1_wpa_psk": "correct-horse", "wl1_11be": "0"])
    let client = RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: router, writes: .reference)
    let (section, off) = try sectionAndChange("wifi1", "wl1_mfp", "2", "0")
    await #expect(throws: RouterError.self) { try await client.applySettings(section: section, changes: [off]) }
    // Wi-Fi 7 mode on: WPA3 keeps AES + GCMP-256.
    let wifi7 = NVRAMRouter(["wl1_auth_mode_x": "psk2", "wl1_crypto": "aes", "wl1_mfp": "1", "wl1_wpa_psk": "correct-horse", "wl1_11be": "1"])
    let (_, toSAE) = try sectionAndChange("wifi1", "wl1_auth_mode_x", "psk2", "sae")
    await #expect(throws: RouterError.self) {
        try await RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: wifi7, writes: .reference).applySettings(section: section, changes: [toSAE])
    }
    // A 6 GHz radio offers WPA3 only.
    let six = try #require(SettingsCatalog.section("wifi2@6 GHz"))
    #expect(six.fields.first { $0.key == "wl2_auth_mode_x" }?.options.map(\.value) == ["sae", "owe"])
    let radio = try #require(SettingsCatalog.section("radio2@6 GHz"))
    #expect(radio.fields.first { $0.key == "wl2_nmode_x" }?.options.map(\.value) == ["0", "9"])
    let sent = await router.posts + wifi7.posts
    #expect(sent == 0)
}

// MARK: History of earlier versions

@Test func historyOfEarlierVersionsIsFoundByHardwareAddressOrModel() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RouterBarTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = MonitoringFileStore(directory: folder)
    let mac = "AA:BB:CC:DD:EE:01"
    let key = MonitoringFileStore.routerKey(endpoint: "https://192.168.50.1:8443", hardwareAddress: mac, model: "RT-BE88U")
    // Kept under the old address, with the MAC as the router reported it.
    let old = PresenceArchive(routerKey: "http://192.168.50.1|aa:bb:cc:dd:ee:01")
    try await store.save(old)
    #expect(try await store.adoptEarlier(endpoint: "https://192.168.50.1:8443", hardwareAddress: mac, model: "RT-BE88U", as: key) == old.routerKey)
    #expect(try await store.load(routerKey: key).routerKey == key)
    // Once the router's own key exists, nothing is copied again.
    #expect(try await store.adoptEarlier(endpoint: "https://192.168.50.1:8443", hardwareAddress: mac, model: "RT-BE88U", as: key) == nil)
    // Kept by address and model before the router reported a hardware address.
    let other = MonitoringFileStore.routerKey(endpoint: "http://10.0.0.1", hardwareAddress: "AA:BB:CC:DD:EE:02", model: "RT-AX88U")
    try await store.save(PresenceArchive(routerKey: "http://10.0.0.1|RT-AX88U"))
    #expect(try await store.adoptEarlier(endpoint: "http://10.0.0.1", hardwareAddress: "AA:BB:CC:DD:EE:02", model: "RT-AX88U", as: other) == "http://10.0.0.1|RT-AX88U")
}
