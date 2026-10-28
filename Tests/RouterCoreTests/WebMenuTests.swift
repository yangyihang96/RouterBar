import Foundation
import Testing
@testable import RouterCore

/// The router's own menu as captured from the RT-BE88U (audit/web-menu/), which the native navigation mirrors.
private struct CapturedMenu: Decodable {
    struct Tab: Decodable { let url: String; let name: String; let kind: String; let visible: Bool }
    let index: String
    let name: String
    let visible: Bool
    let tabs: [Tab]
}

private func capturedMenu() throws -> [CapturedMenu] {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("audit/web-menu/visible-menu-RT-BE88U-3006.102.5.json"))
    return try JSONDecoder().decode([CapturedMenu].self, from: data)
}

/// Web names may carry markup, e.g. "AiCloud 2.0<br/>个人云 2.0 应用".
private func plain(_ name: String) -> String {
    name.replacingOccurrences(of: "<br/>", with: " ").replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
}

private var allPages: [WebPage] { WebMenuCatalog.menus.flatMap(\.pages) }
private var allParts: [WebPart] { allPages.flatMap(\.parts) }

@Test func menusMatchTheRoutersWebMenuInNameGroupAndOrder() throws {
    var group: WebMenuGroup?
    var expected: [(id: String, title: String, group: WebMenuGroup?, tabs: [String])] = []
    for menu in try capturedMenu() {
        if menu.index == "menu_Split" { group = WebMenuGroup(rawValue: menu.name); continue }
        guard menu.visible else { continue }
        expected.append((menu.index, plain(menu.name), group, menu.tabs.filter { $0.visible && $0.kind == "tab" }.map { plain($0.name) }))
    }
    #expect(expected.count == 24)
    #expect(WebMenuCatalog.menus.map(\.id) == expected.map(\.id))
    for (menu, want) in zip(WebMenuCatalog.menus, expected) {
        #expect(menu.title == want.title, "\(menu.id)")
        #expect(menu.group == want.group, "\(menu.id)")
        // Tabs the web shows on this router, in web order and with the web's names.
        #expect(menu.tabs.filter { $0.condition == nil }.map(\.title) == want.tabs, "\(menu.id)")
    }
}

@Test func everyPageTheWebShowsHasANativePlace() throws {
    let captured = try capturedMenu().filter { $0.visible && $0.index != "menu_Split" }
    let visible = Set(captured.flatMap { $0.tabs.filter(\.visible).map(\.url) })
    let hidden = Set(captured.flatMap { $0.tabs.filter { !$0.visible }.map(\.url) })
    let native = Set(allPages.map(\.id) + allParts.compactMap(\.url))
    #expect(visible.subtracting(native) == Set(WebMenuCatalog.unlinkedPages.keys))
    // Pages beyond those shown here are only the ones the web itself shows under a condition.
    let conditional = Set(allPages.filter { $0.condition != nil }.map(\.id) + allParts.filter { $0.condition != nil }.compactMap(\.url))
    #expect(native.subtracting(visible) == Set(["Advanced_ACL_Content.asp", "Advanced_WSecurity_Content.asp"]))
    #expect(native.subtracting(visible).isSubset(of: hidden.intersection(conditional)))
    // The landing page is the first page of its menu, as the web opens it.
    for menu in WebMenuCatalog.menus {
        #expect(menu.pages.dropFirst().allSatisfy { $0.kind != .landing }, "\(menu.id)")
        #expect(menu.pages.contains { $0.kind != .subpage }, "\(menu.id)")
    }
}

@Test func webPagesAndPartsAreUnique() {
    let pageIDs = allPages.map(\.id)
    #expect(Set(pageIDs).count == pageIDs.count)
    let partURLs = allParts.compactMap(\.url)
    #expect(Set(partURLs).count == partURLs.count)
    #expect(Set(partURLs).isDisjoint(with: pageIDs))
    for page in allPages {
        #expect(!page.parts.isEmpty, "\(page.id)")
        #expect(Set(page.parts.map(\.id)).count == page.parts.count, "\(page.id)")
    }
}

@Test func everyCatalogSectionLivesOnExactlyOneWebPage() {
    let placed = allParts.flatMap(\.content.sectionIDs)
    let catalog = SettingsCatalog.sections.map(\.id)
    #expect(Set(placed).isSubset(of: catalog))
    for id in catalog {
        let count = placed.filter { $0 == id }.count
        if WebMenuCatalog.hiddenSections[id] != nil { #expect(count == 0, "\(id)") } else { #expect(count == 1, "\(id)") }
    }
    #expect(Set(WebMenuCatalog.hiddenSections.keys).isSubset(of: catalog))
    #expect(Set(WebMenuCatalog.sectionConditions.keys).isSubset(of: placed))
    // A settings section sits on the web page it was read from.
    for page in allPages {
        for part in page.parts {
            guard case .settings(let ids, _) = part.content else { continue }
            for id in ids { #expect(SettingsCatalog.sections.first { $0.id == id }?.source == (part.url ?? page.id), "\(id)") }
        }
    }
}

@Test func pendingPagesExplainThemselvesAndLinkToRealPlaces() {
    for part in allParts {
        guard case .pending(let text, let related) = part.content else { continue }
        #expect(text.count >= 8, "\(part.title)")
        for link in related {
            switch link {
            case .section(let id): #expect(WebMenuCatalog.location(ofSection: id) != nil, "\(id)")
            case .feature(let feature): #expect(WebMenuCatalog.location(of: feature) != nil)
            }
        }
    }
}

@Test func locationsResolveToTheMirroredWebPage() {
    #expect(WebMenuCatalog.location(ofSection: "wan0") == WebLocation(menu: "menu_WAN", page: "Advanced_WAN_Content.asp", part: "wan0"))
    #expect(WebMenuCatalog.location(ofSection: "band1") == WebLocation(menu: "menu_Wireless", page: "Advanced_Wireless_Content.asp", part: "5g"))
    #expect(WebMenuCatalog.location(ofSection: "radio1") == WebLocation(menu: "menu_Wireless", page: "Advanced_WAdvanced_Content.asp", part: "5g"))
    #expect(WebMenuCatalog.location(ofSection: "conntrack") == WebLocation(menu: "menu_Setting", page: "Tools_OtherSettings.asp", part: "main"))
    #expect(WebMenuCatalog.location(ofSection: "wgc3") == WebLocation(menu: "menu_VPN", page: "Advanced_OpenVPNClient_Content.asp", part: "wireguard"))
    #expect(WebMenuCatalog.location(ofSection: "wgs1") == WebLocation(menu: "menu_VPN", page: "Advanced_VPN_OpenVPN.asp", part: "others"))
    #expect(WebMenuCatalog.location(of: .radioChannels(1)) == WebLocation(menu: "menu_Wireless", page: "Advanced_Wireless_Content.asp", part: "5g"))
    #expect(WebMenuCatalog.location(of: .firmware) == WebLocation(menu: "menu_Setting", page: "Advanced_FirmwareUpgrade_Content.asp", part: "firmware"))
    #expect(WebMenuCatalog.location(of: .clients) == WebLocation(menu: "menu_Index", page: "index.asp", part: "clients"))
    #expect(WebMenuCatalog.location(ofSection: "nfs") == nil)
    #expect(WebMenuCatalog.names(of: WebMenuCatalog.location(ofSection: "band1")!) == ["无线网络", "一般设置", "5 GHz"])
    #expect(WebMenuCatalog.names(of: WebMenuCatalog.location(ofSection: "dhcp")!) == ["内部网络(LAN)", "DHCP 服务器"])
    #expect(WebMenuCatalog.names(of: WebMenuCatalog.location(of: .mesh)!) == ["AiMesh"])
    #expect(WebMenuCatalog.names(of: WebMenuCatalog.location(ofSection: "qos")!) == ["Adaptive QoS 智能场景加速", "带宽管理 QoS"])
    #expect(WebMenuCatalog.names(of: WebMenuCatalog.location(ofSection: "qosrules")!) == ["Adaptive QoS 智能场景加速", "带宽管理 QoS", "用户自定义带宽管理规则"])
}

@Test func vpnScopesSplitEverySlotOnce() {
    let scopes: [VPNScope] = [.routing, .openVPNServers, .otherServers, .clients(.openVPN), .clients(.wireGuard)]
    let all = scopes.flatMap(\.destinations)
    #expect(all.count == VPNCenterDestination.all.count)
    #expect(Set(all) == Set(VPNCenterDestination.all))
    for scope in scopes { for destination in scope.destinations { #expect(VPNScope.containing(destination) == scope) } }
    for scope in scopes { #expect(WebMenuCatalog.location(of: .vpn(scope)) != nil) }
}

@Test func onePlaceForEachNativeView() {
    var features: [NativeFeature] = []
    for part in allParts {
        switch part.content {
        case .native(let feature): features.append(feature)
        case .settings(_, let accessory?): features.append(accessory)
        default: break
        }
    }
    #expect(Set(features).count == features.count)
}

@Test func theGeneralWirelessPageOwnsThe160MHzSwitch() throws {
    let general = try #require(SettingsCatalog.sections.first { $0.id == "band1" })
    let professional = try #require(SettingsCatalog.sections.first { $0.id == "radio1" })
    #expect(general.source == "Advanced_Wireless_Content.asp")
    #expect(general.fields.map(\.key) == ["wl1_bw_160"])
    #expect(!professional.fields.contains { $0.key == "wl1_bw_160" })
    #expect(general.service == professional.service && general.wait == professional.wait)
}
