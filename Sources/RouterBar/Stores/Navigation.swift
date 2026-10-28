import SwiftUI
import RouterCore

/// Pages that belong to this app rather than to the router's web interface.
enum LocalPage: String, CaseIterable, Identifiable {
    case deviceHistory = "设备历史", health = "网络健康", connection = "连接设置"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .deviceHistory: "clock.arrow.circlepath"
        case .health: "heart.text.clipboard"
        case .connection: "gearshape"
        }
    }
}

enum SidebarItem: Hashable {
    /// A menu of the router's web interface, by its menuTree.js index.
    case menu(String)
    case local(LocalPage)
}

enum NavigationTarget: Equatable {
    /// Selecting a menu opens its first page, as clicking the web's menu does.
    case sidebar(SidebarItem)
    case web(WebLocation)
}

/// A navigation plus what to select in the VPN center once it is shown.
struct NavigationRequest: Equatable {
    var target: NavigationTarget
    var vpnDestination: VPNCenterDestination?
    var vpnSettingKey: String?
}

/// The web menu path of the page being shown, used as the page header's eyebrow.
private struct WebPathKey: EnvironmentKey { static let defaultValue: String? = nil }
extension EnvironmentValues {
    var webPath: String? {
        get { self[WebPathKey.self] }
        set { self[WebPathKey.self] = newValue }
    }
}

extension WebMenu {
    /// Menus without any native page are listed like the others but drawn quieter.
    var isPending: Bool { pages.allSatisfy(\.isPending) }
}

extension WebPage {
    var isPending: Bool { parts.allSatisfy(\.isPending) }
}

extension WebPart {
    var isPending: Bool { if case .pending = content { true } else { false } }
}
