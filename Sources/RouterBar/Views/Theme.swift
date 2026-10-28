import SwiftUI
import AppKit
import RouterCore

/// Visual tokens shared by every page: a quiet canvas behind the pages, cards standing on it, one radius and
/// spacing scale, and a color per menu that its icon and page header carry (as System Settings colors its panes).
enum Theme {
    static let accent = Color.teal
    /// Behind every page.
    static let canvas = Color(nsColor: .dynamic(light: NSColor(srgbRed: 0.949, green: 0.953, blue: 0.961, alpha: 1),
                                                dark: NSColor(srgbRed: 0.102, green: 0.106, blue: 0.114, alpha: 1)))
    /// A card on the canvas.
    static let card = Color(nsColor: .dynamic(light: .white, dark: NSColor(srgbRed: 0.153, green: 0.157, blue: 0.169, alpha: 1)))
    /// Fills inside a card: wells, tracks, unselected chips.
    static let well = Color(nsColor: .dynamic(light: NSColor(white: 0, alpha: 0.045), dark: NSColor(white: 1, alpha: 0.065)))
    static let hairline = Color(nsColor: .dynamic(light: NSColor(white: 0, alpha: 0.085), dark: NSColor(white: 1, alpha: 0.085)))
    static let radius: CGFloat = 12
    static let smallRadius: CGFloat = 8
    /// Page margin.
    static let page: CGFloat = 28
    /// Between cards.
    static let gap: CGFloat = 16

    /// The color of a menu of the router's web interface, by its menuTree.js index.
    static func tint(menu id: String) -> Color {
        switch id {
        case "menu_QIS": .purple
        case "menu_Index", "menu_Wireless", "menu_AiCloud": .blue
        case "menu_AiMesh", "menu_IPv6": .teal
        case "menu_GuestNetwork", "menu_Guest_network", "menu_Alexa_IFTTT": .cyan
        case "menu_AiProtection", "menu_LAN": .green
        case "menu_ParentalControl", "menu_NekworkTool", "menu_Tools": .orange
        case "menu_BandwidthMonitor", "menu_QoS", "menu_TrafficManager", "menu_WAN": .indigo
        case "menu_TrafficAnalyzer": .mint
        case "menu_GameBoost", "menu_OpenNAT", "menu_Firewall": .red
        case "menu_UU": .pink
        case "menu_VPN": .purple
        case "menu_APP": .brown
        default: .gray
        }
    }
    static func tint(local page: LocalPage) -> Color {
        switch page {
        case .deviceHistory: .purple
        case .health: .pink
        case .connection: .gray
        }
    }
}

extension NSColor {
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }
}

/// The page's color: its menu's, set by the page container and read by the header.
private struct PageTintKey: EnvironmentKey { static let defaultValue = Theme.accent }
extension EnvironmentValues {
    var pageTint: Color {
        get { self[PageTintKey.self] }
        set { self[PageTintKey.self] = newValue }
    }
}

/// A rounded card on the canvas: white or raised gray, a hairline edge, a faint shadow in light appearance.
struct CardBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var radius: CGFloat = Theme.radius
    func body(content: Content) -> some View {
        content
            .background(Theme.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.045), radius: 5, y: 1)
    }
}
extension View {
    func card(radius: CGFloat = Theme.radius) -> some View { modifier(CardBackground(radius: radius)) }
}

/// An SF Symbol on a colored rounded square, as System Settings draws its pane icons.
struct SymbolTile: View {
    let symbol: String
    var tint: Color = Theme.accent
    var size: CGFloat = 22
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        Image(systemName: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil ? symbol : "square.grid.2x2")
            .font(.system(size: size * 0.52, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [tint.opacity(0.82), tint], startPoint: .top, endPoint: .bottom), in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

/// A small colored dot with a word, for states: online, offline, waiting.
struct StatusDot: View {
    let color: Color
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
                .overlay(Circle().stroke(color.opacity(0.25), lineWidth: 3))
            Text(text)
        }
    }
}
