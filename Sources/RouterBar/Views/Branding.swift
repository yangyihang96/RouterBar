import SwiftUI
import RouterCore

@MainActor enum BrandAssets {
    static let icon: NSImage? = Bundle.main.url(forResource: "RouterBar-Icon", withExtension: "png").flatMap(NSImage.init(contentsOf:))
}
struct BrandIcon: View {
    let size: CGFloat
    var body: some View {
        Group {
            if let icon = BrandAssets.icon { Image(nsImage: icon).resizable().interpolation(.high).scaledToFit() }
            else { Image(systemName: "wifi.router.fill").resizable().scaledToFit().padding(size * 0.16).foregroundStyle(.teal) }
        }.frame(width: size, height: size).accessibilityLabel("路由器面板")
    }
}
extension DeviceKind {
    var tint: Color {
        switch self {
        case .phone, .tablet, .laptop, .desktop, .computer, .appleDevice: .blue
        case .television, .speaker: .purple
        case .gameConsole: .indigo
        case .camera: .orange
        case .robotVacuum: .pink
        case .light: .yellow
        case .storage, .homeServer: .indigo
        case .router: .teal
        case .printer: .cyan
        case .watch: .mint
        case .plug, .appliance, .smartHome: .orange
        case .unknown: .gray
        }
    }
}
struct DeviceGlyph: View {
    let kind: DeviceKind
    var size: CGFloat = 44
    var online = true
    var body: some View {
        Image(systemName: NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil) != nil ? kind.symbol : "circle.circle.fill")
            .font(.system(size: size * 0.46, weight: .medium)).symbolRenderingMode(.hierarchical)
            .foregroundStyle(online ? kind.tint : .secondary).frame(width: size, height: size)
            .background((online ? kind.tint : .gray).opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.27))
            .overlay(RoundedRectangle(cornerRadius: size * 0.27).stroke(kind.tint.opacity(online ? 0.13 : 0.04)))
            .accessibilityLabel(kind.title)
    }
}
struct SignalBars: View {
    let rssi: Int?
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4) { index in
                RoundedRectangle(cornerRadius: 1.3).fill(index < bars ? tint : .secondary.opacity(0.18)).frame(width: 3, height: CGFloat(4 + index * 3))
            }
        }.frame(width: 18, height: 14).accessibilityLabel(rssi.map { "信号 \($0) dBm" } ?? "无信号数据")
    }
    private var bars: Int { guard let rssi else { return 0 }; return rssi >= -50 ? 4 : rssi >= -65 ? 3 : rssi >= -75 ? 2 : 1 }
    private var tint: Color { bars >= 3 ? .teal : bars == 2 ? .orange : .red }
}
