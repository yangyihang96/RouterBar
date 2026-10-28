import Foundation
import Testing
@testable import RouterCore

// MARK: Menu evaluation

/// A state.js with the parts menuTree.js reads, and the browser calls a real state.js makes while loading.
private let sampleState = """
if(parent.webWrapper) document.write('<link rel="stylesheet" href="/css/x.css"></link>');
document.write('<script src="/require/require.min.js"></script>');
var cookie = document.cookie.split(";");
if (navigator.userAgent.indexOf("MSIE") != -1) var old_ie = 1;
if (window.addEventListener) window.addEventListener("unload", function(){}, false);
$(function(){ document.getElementById("x").innerHTML = "y"; });
var based_modelid = 'RT-TEST';
var odmpid = 'RT-TEST-PRO';
var ui_lang = 'CN';
function isSupport(_ptn){
var ui_support = [{ "mssid": 1, "alexa": 1, "ifttt": 0, "wireguard": 1, "dualwan": 0, "is_ax5400_i1": 0 }][0];
return ui_support[_ptn] ? ui_support[_ptn] : 0;
}
var isSwMode = function(mode){ return "rt" == mode.toLowerCase(); };
var alexa_support = isSupport("alexa"), ifttt_support = isSupport("ifttt");
var wireguard_support = isSupport("wireguard"), dualWAN_support = isSupport("dualwan");
var wlnband_list = `2g1&#605g1&#606g1`.split("&#60");
var wl_nband_title = ["2.4 GHz", "5 GHz", "6 GHz"];
"""

private func sampleTree(_ list: String, menus: String = "", tabs: String = "") -> String {
    """
    define(function(){
    var menuTree = {
        list: [\(list)],
        exclude: {
            menus: function(){ var retArray = []; \(menus) return retArray; },
            tabs: function(){ var retArray = []; \(tabs) return retArray; }
        }
    };
    return menuTree;
    });
    """
}

private let sampleList = """
{ menuName: "网络设置向导", index: "menu_QIS", tab: [ {url: "QIS_wizard.htm", tabName: "__HIDE__"}, {url: "NULL", tabName: "__INHERIT__"} ] },
{ menuName: "一般设置", index: "menu_Split", tab: [ {url: "NULL", tabName: "__HIDE__"} ] },
{ menuName: "VPN", index: "menu_VPN", tab: [
    {url: "Advanced_VPNServer_Content.asp", tabName: "VPN 服务器"},
    {url: "Advanced_WireguardServer_Content.asp", tabName: "WireGuard"},
    {url: "Advanced_VPN_Detail.asp", tabName: "__INHERIT__"} ] },
{ menuName: "双线路", index: "menu_DualWAN", tab: [ {url: "Advanced_WANPort_Content.asp", tabName: "双线路"} ] },
{ menuName: "Alexa & IFTTT", index: "menu_Alexa_IFTTT", tab: [ {url: "Advanced_Smart_Home_Alexa.asp", tabName: "__HIDE__"} ] },
{ menuName: "AiMesh", index: "menu_AiMesh", tab: [ {url: "AiMesh.asp", tabName: "AiMesh"} ] },
{ menuName: "空", index: "menu_Null", tab: [ {url: "NULL", tabName: "__HIDE__"} ] },
{ menuName: "<#Menu_Tools#><br/>工具", index: "menu_Tools", tab: [ {url: "Tools_Sysinfo.asp", tabName: "Sysinfo &amp; 信息"} ] }
"""

@Test func menuFollowsTheWebsOwnRules() async throws {
    let tree = sampleTree(sampleList,
                          menus: #"if (!dualWAN_support) retArray.push("menu_DualWAN");"#,
                          tabs: #"retArray.push("Advanced_VPNServer_Content.asp"); if (!wireguard_support) retArray.push("Advanced_WireguardServer_Content.asp");"#)
    let result = try RouterMenuEvaluator.run(state: sampleState, menuTree: tree)
    let byIndex = Dictionary(uniqueKeysWithValues: result.menus.map { ($0.index, $0) })
    #expect(result.menus.map(\.index) == ["menu_QIS", "menu_Split", "menu_VPN", "menu_DualWAN", "menu_Alexa_IFTTT", "menu_AiMesh", "menu_Null", "menu_Tools"])
    // Opens at the first tab the web does not exclude; the excluded one stays listed but hidden.
    #expect(byIndex["menu_VPN"]?.visible == true)
    #expect(byIndex["menu_VPN"]?.entry == "Advanced_WireguardServer_Content.asp")
    #expect(byIndex["menu_VPN"]?.tabs.map(\.visible) == [false, true, true])
    #expect(byIndex["menu_VPN"]?.tabs.map(\.kind) == [.tab, .tab, .subpage])
    // Excluded by exclude.menus(); a first tab of "NULL" hides the menu too.
    #expect(byIndex["menu_DualWAN"]?.visible == false)
    #expect(byIndex["menu_Null"]?.visible == false)
    // NULL tabs are not pages; the group heading stays as a heading.
    #expect(byIndex["menu_QIS"]?.tabs.map(\.url) == ["QIS_wizard.htm"])
    #expect(byIndex["menu_Split"]?.isGroupHeading == true)
    #expect(byIndex["menu_Split"]?.visible == true)
    // state.js showMenuTree names: Alexa alone, and AiMesh on the Simplified Chinese interface.
    #expect(byIndex["menu_Alexa_IFTTT"]?.name == "Amazon Alexa")
    #expect(byIndex["menu_AiMesh"]?.name == "AiMesh 随心组网")
    // Markup and entities in names are text.
    #expect(byIndex["menu_Tools"]?.name == "工具")
    #expect(byIndex["menu_Tools"]?.tabs.first?.name == "Sysinfo & 信息")
    #expect(result.notes.isEmpty)
}

@Test func menuReadsTheFactsStateJSComputes() async throws {
    let result = try RouterMenuEvaluator.run(state: sampleState, menuTree: sampleTree(sampleList))
    #expect(result.facts.model == "RT-TEST")
    #expect(result.facts.marketedModel == "RT-TEST-PRO")
    #expect(result.facts.language == "CN")
    #expect(result.facts.bandList == ["2g1", "5g1", "6g1"])
    #expect(result.facts.bandTitles == ["2.4 GHz", "5 GHz", "6 GHz"])
    #expect(result.facts.supports("wireguard"))
    #expect(!result.facts.supports("ifttt"))
}

@Test func menuTreatsGlobalsTheFirmwareNeverDefinesAsUnsupported() async throws {
    let tree = sampleTree(sampleList, tabs: #"if (!mystery_support) retArray.push("Tools_Sysinfo.asp"); if (other_flag) retArray.push("AiMesh.asp");"#)
    let result = try RouterMenuEvaluator.run(state: sampleState, menuTree: tree)
    let byIndex = Dictionary(uniqueKeysWithValues: result.menus.map { ($0.index, $0) })
    #expect(byIndex["menu_Tools"]?.visible == false)
    #expect(byIndex["menu_AiMesh"]?.visible == true)
    #expect(result.notes.contains { $0.contains("mystery_support") && $0.contains("other_flag") })
}

@Test func menuAcceptsAModuleWithDependencies() async throws {
    let tree = "define(['jquery'], function(){ return { list: [\(sampleList)], exclude: { menus: function(){ return []; }, tabs: function(){ return []; } } }; });"
    let result = try RouterMenuEvaluator.run(state: sampleState, menuTree: tree)
    #expect(result.menus.count == 8)
}

@Test func menuRejectsWhatIsNotAMenuTree() {
    #expect(throws: RouterMenuEvaluator.Failure.shape("menuTree.list / exclude")) {
        try RouterMenuEvaluator.run(state: sampleState, menuTree: "define(function(){ return { list: 3 }; });")
    }
    #expect(throws: RouterMenuEvaluator.Failure.self) {
        try RouterMenuEvaluator.run(state: sampleState, menuTree: "define(function(){ syntax error here")
    }
    #expect(throws: RouterMenuEvaluator.Failure.tooLarge) {
        try RouterMenuEvaluator.run(state: String(repeating: " ", count: 2_000_001), menuTree: sampleTree(sampleList))
    }
}

@Test func menuVariableNamesFromErrorsAreIdentifiersOnly() {
    #expect(RouterMenuEvaluator.missingVariable(in: "ReferenceError: Can't find variable: foo_support") == "foo_support")
    #expect(RouterMenuEvaluator.missingVariable(in: "ReferenceError: Can't find variable: a; alert(1)") == nil)
    #expect(RouterMenuEvaluator.missingVariable(in: "TypeError: undefined is not an object") == nil)
}

/// The RT-BE88U's own state.js and menuTree.js as this Mac last read them (private, never in the repository): the
/// evaluated menu must equal the one captured for the reference catalog.
@Test func menuOfTheReferenceRouterMatchesTheCapture() async throws {
    let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/com.yihang.RouterBar")
    guard let folder = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil))?
            .filter({ $0.lastPathComponent.hasPrefix("InterfaceAudit-") }).sorted(by: { $0.path < $1.path }).last,
          let state = try? String(contentsOf: folder.appendingPathComponent("state.js"), encoding: .utf8),
          let tree = try? String(contentsOf: folder.appendingPathComponent("require__modules__menuTree.js"), encoding: .utf8) else { return }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    struct Captured: Decodable {
        struct Tab: Decodable { let url: String; let kind: String; let visible: Bool }
        let index: String; let visible: Bool; let tabs: [Tab]
    }
    let captured = try JSONDecoder().decode([Captured].self, from: Data(contentsOf: root.appendingPathComponent("audit/web-menu/visible-menu-RT-BE88U-3006.102.5.json")))
    let result = try RouterMenuEvaluator.run(state: state, menuTree: tree)
    #expect(result.menus.map(\.index) == captured.map(\.index))
    for (menu, expected) in zip(result.menus, captured) {
        #expect(menu.visible == expected.visible, "\(menu.index)")
        #expect(menu.tabs.map(\.url) == expected.tabs.map(\.url), "\(menu.index)")
        #expect(menu.tabs.map(\.kind.rawValue) == expected.tabs.map(\.kind), "\(menu.index)")
        #expect(menu.tabs.map(\.visible) == expected.tabs.map(\.visible), "\(menu.index)")
    }
    #expect(result.facts.model == "RT-BE88U")
    #expect(result.facts.bandTitles?.count == 2)
    #expect(result.facts.supports("sdn_mainfh") == RouterParser.uiSupport("sdn_mainfh", in: state))
}

// MARK: Profile

@Test func profileReadsTheFirmwareLine() throws {
    let merlin = try #require(RouterProfile.make(nvram: ["productid": "RT-BE88U", "firmver": "3.0.0.6", "buildno": "102.5", "extendno": "0",
                                                         "wl0_nband": "2", "wl1_nband": "1"], facts: nil))
    #expect(merlin.family == .merlin)
    #expect(merlin.branch == .v3006)
    #expect(merlin.isReferenceFirmware)
    #expect(merlin.firmwareVersion == "3006.102.5")
    #expect(merlin.radios.map(\.title) == ["2.4 GHz", "5 GHz"])

    let stock = try #require(RouterProfile.make(nvram: ["productid": "RT-AX86U", "odmpid": "RT-AX86U Pro", "firmver": "3.0.0.4", "buildno": "388",
                                                        "extendno": "24231-g1a2b3c4", "wl0_nband": "2", "wl1_nband": "1"], facts: nil))
    #expect(stock.family == .stock)
    #expect(stock.branch == .v388)
    #expect(!stock.isReferenceFirmware)
    #expect(stock.firmwareVersion == "3.0.0.4.388_24231")
    #expect(stock.displayName == "RT-AX86U Pro")

    let older = try #require(RouterProfile.make(nvram: ["productid": "RT-AC68U", "firmver": "3.0.0.4", "buildno": "386.14", "extendno": "2"], facts: nil))
    #expect(older.family == .merlin)
    #expect(older.branch == .v386)
    #expect(older.firmwareVersion == "3004.386.14_2")
    #expect(RouterProfile.make(nvram: ["productid": "RT-N66U", "firmver": "3.0.0.4", "buildno": "380"], facts: nil)?.branch == .legacy)
    #expect(RouterProfile.make(nvram: ["productid": ""], facts: nil) == nil)
}

@Test func profileNamesRadiosAsTheWebDoes() throws {
    let quad = try #require(RouterProfile.make(nvram: ["productid": "GT-BE98", "firmver": "3.0.0.6", "buildno": "102",
                                                       "wl0_nband": "2", "wl1_nband": "1", "wl2_nband": "1", "wl3_nband": "4"], facts: nil))
    #expect(quad.radios.map(\.title) == ["2.4 GHz", "5 GHz-1", "5 GHz-2", "6 GHz"])
    #expect(quad.radios.map(\.band) == [.ghz2_4, .ghz5, .ghz5, .ghz6])

    let facts = RouterWebFacts(bandTitles: ["2.4 GHz", "5 GHz", "6 GHz-1", "6 GHz-2"], bandList: ["2g1", "5g1", "6g1", "6g2"])
    let web = try #require(RouterProfile.make(nvram: ["productid": "GT-BE19000", "wl0_nband": "2", "wl1_nband": "1", "wl2_nband": "4", "wl3_nband": "4"], facts: facts))
    #expect(web.radios.map(\.title) == ["2.4 GHz", "5 GHz", "6 GHz-1", "6 GHz-2"])
    #expect(web.radios.map(\.band) == [.ghz2_4, .ghz5, .ghz6, .ghz6])
}

// MARK: Menu set

/// The RT-BE88U's menu as captured (audit/web-menu/), as menu entries.
private func capturedEntries() throws -> [RouterMenuEntry] {
    struct Captured: Decodable {
        struct Tab: Decodable { let url: String; let name: String; let kind: String; let visible: Bool }
        let index: String; let name: String; let visible: Bool; let tabs: [Tab]
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let captured = try JSONDecoder().decode([Captured].self, from: Data(contentsOf: root.appendingPathComponent("audit/web-menu/visible-menu-RT-BE88U-3006.102.5.json")))
    return captured.map { menu in
        RouterMenuEntry(index: menu.index, name: RouterMenuEvaluator.plain(menu.name), visible: menu.visible,
                        tabs: menu.tabs.map { .init(url: $0.url, name: RouterMenuEvaluator.plain($0.name), kind: .init(rawValue: $0.kind) ?? .tab, visible: $0.visible) },
                        entry: menu.tabs.first(where: \.visible)?.url)
    }
}

private func profile(_ model: String, firmver: String = "3.0.0.6", buildno: String = "102.5", nband: [String] = ["2", "1"]) -> RouterProfile {
    var nvram = ["productid": model, "firmver": firmver, "buildno": buildno, "extendno": "0"]
    for (unit, band) in nband.enumerated() { nvram["wl\(unit)_nband"] = band }
    return RouterProfile.make(nvram: nvram, facts: nil)!
}

@Test func referenceRoutersOwnMenuBuildsTheReferenceCatalog() throws {
    let entries = try capturedEntries()
    let set = WebMenuSet.build(entries: entries, profile: profile("RT-BE88U"))
    #expect(set.menus.map(\.id) == WebMenuCatalog.menus.map(\.id))
    // The catalog also lists the per-band MAC filter and RADIUS pages under the condition the web's menu itself
    // evaluates (`sdn_mainfh`); the router's menu already leaves them out.
    let shown = Set(entries.flatMap { $0.tabs.filter(\.visible).map(\.url) })
    for (built, reference) in zip(set.menus, WebMenuCatalog.menus) {
        let pages = reference.pages.filter { shown.contains($0.id) }
        #expect(built.group == reference.group, "\(built.id)")
        #expect(built.symbol == reference.symbol, "\(built.id)")
        #expect(built.pages.map(\.id) == pages.map(\.id), "\(built.id)")
        #expect(built.pages.map(\.kind) == pages.map(\.kind), "\(built.id)")
        #expect(built.pages.map(\.parts) == pages.map(\.parts), "\(built.id)")
        #expect(built.home.id == reference.home.id, "\(built.id)")
    }
    #expect(WebMenuCatalog.menus.flatMap(\.pages).filter { !shown.contains($0.id) }.map(\.id) == ["Advanced_ACL_Content.asp", "Advanced_WSecurity_Content.asp"])
    #expect(set.groupTitle(.general) == "一般设置")
    #expect(set.groupTitle(.advanced) == "高级设置")
    #expect(set.webOnlyPages.isEmpty)
    #expect(set.location(of: .overview) == WebMenuCatalog.location(of: .overview))
}

@Test func radiosBeyondTheReferenceGetTheirOwnSwitches() throws {
    let triBand = profile("RT-BE96U", buildno: "102", nband: ["2", "1", "4"])
    let set = WebMenuSet.build(entries: try capturedEntries(), profile: triBand)
    let general = try #require(set.menu("menu_Wireless")?.page("Advanced_Wireless_Content.asp"))
    #expect(general.parts.map(\.id) == ["wl0", "wl1", "wl2"])
    #expect(general.parts.map(\.title) == ["2.4 GHz", "5 GHz", "6 GHz"])
    #expect(general.parts.map(\.content) == [.settings(["wifi0"], accessory: .radioChannels(0)),
                                             .settings(["wifi1", "band1"], accessory: .radioChannels(1)),
                                             .settings(["wifi2@6 GHz"], accessory: nil)])
    let professional = try #require(set.menu("menu_Wireless")?.page("Advanced_WAdvanced_Content.asp"))
    #expect(professional.parts.map(\.content) == [.settings(["radio0"]), .settings(["radio1"]), .settings(["radio2@6 GHz"])])

    let sixGHz = try #require(SettingsCatalog.section("wifi2@6 GHz"))
    #expect(sixGHz.title.hasPrefix("6 GHz"))
    #expect(sixGHz.fields.allSatisfy { $0.key.hasPrefix("wl2_") })
    #expect(sixGHz.fields.first { $0.key == "wl2_auth_mode_x" }?.options.map(\.value) == ["sae", "owe"])
    #expect(WebMenuCatalog.condition(ofSection: "wifi2@6 GHz") == .perBandWireless)
    #expect(SettingsCatalog.section("radio3@5 GHz-2")?.fields.first?.key == "wl3_radio")
    #expect(SettingsCatalog.section("band3@5 GHz-2")?.fields.map(\.key) == ["wl3_bw_160"])
    #expect(SettingsCatalog.section("wifi9@6 GHz") == nil)
    #expect(SettingsCatalog.section("nothing@6 GHz") == nil)

    let quad = WebMenuSet.build(entries: try capturedEntries(), profile: profile("GT-BE98", buildno: "102", nband: ["2", "1", "1", "4"]))
    let quadGeneral = try #require(quad.menu("menu_Wireless")?.page("Advanced_Wireless_Content.asp"))
    #expect(quadGeneral.parts.map(\.title) == ["2.4 GHz", "5 GHz-1", "5 GHz-2", "6 GHz"])
    #expect(quadGeneral.parts[1].content == .settings(["wifi1@5 GHz-1", "band1@5 GHz-1"], accessory: .radioChannels(1)))
}

@Test func otherFirmwareLinesKeepOnlyNativePagesThatShareTheirRequests() throws {
    let stock388 = profile("RT-AX86U", firmver: "3.0.0.4", buildno: "388")
    #expect(stock388.branch == .v388)
    let set = WebMenuSet.build(entries: try capturedEntries(), profile: stock388)
    func content(_ menu: String, _ page: String, part: Int = 0) -> WebContent? { set.menu(menu)?.page(page)?.parts[part].content }
    // A page written from the 3.0.0.6 web code explains itself instead.
    guard case .pending(let text, _) = content("menu_GameBoost", "GameBoost.asp") else { Issue.record("game boost stays native"); return }
    #expect(text.contains("3.0.0.4.388"))
    // Read-only pages, settings sections, firmware upload and the backup stay native.
    #expect(content("menu_Log", "Main_DHCPStatus_Content.asp") == .native(.dhcpLeases))
    #expect(content("menu_Firewall", "Advanced_BasicFirewall_Content.asp") == .settings(["firewall"]))
    #expect(content("menu_Setting", "Advanced_FirmwareUpgrade_Content.asp") == .native(.firmware))
    #expect(content("menu_Setting", "Advanced_SettingBackup_Content.asp") == .native(.settingBackup))
    // The channel control follows the 3.0.0.6 page, so only its settings stay.
    #expect(content("menu_Wireless", "Advanced_Wireless_Content.asp", part: 1) == .settings(["wifi1", "band1"], accessory: nil))
}

@Test func pagesWithoutNativeContentAndHiddenSwitchesFollowTheRouter() throws {
    var entries = try capturedEntries()
    // A firmware line with the guest network page, and without WireGuard clients.
    let guest = RouterMenuEntry(index: "menu_GuestNetwork", name: "访客网络", visible: true,
                                tabs: [.init(url: "Guest_network.asp", name: "访客网络", kind: .tab, visible: true)], entry: "Guest_network.asp")
    entries = entries.map { entry in
        if entry.index == "menu_GuestNetwork" { return guest }
        guard entry.index == "menu_VPN" else { return entry }
        return RouterMenuEntry(index: entry.index, name: entry.name, visible: entry.visible,
                               tabs: entry.tabs.map { .init(url: $0.url, name: $0.name, kind: $0.kind, visible: $0.url == "Advanced_WireguardClient_Content.asp" ? false : $0.visible) },
                               entry: entry.entry)
    }
    let set = WebMenuSet.build(entries: entries, profile: profile("RT-BE88U"))
    let page = try #require(set.menu("menu_GuestNetwork")?.pages.first)
    guard case .pending(let text, _) = page.parts[0].content else { Issue.record("guest network has native content"); return }
    #expect(text.contains("浏览器"))
    #expect(set.webOnlyPages.map(\.id) == ["Guest_network.asp"])
    #expect(set.menu("menu_GuestNetwork")?.symbol == "network")
    let clients = try #require(set.menu("menu_VPN")?.page("Advanced_OpenVPNClient_Content.asp"))
    #expect(clients.parts.map(\.id) == ["openvpn", "pptp"])
}
