import SwiftUI

/// Shared page header: the page's icon in its menu's color, one title, and a line on what the page is for. Where the
/// page sits in the router's menu is in the window's title.
struct PageHeader: View {
    let title: String
    let subtitle: String
    let symbol: String
    var eyebrow: String? = nil
    /// Set on pages that do not scroll as a whole: a subtitle sized to its full wrapped height counts toward the
    /// window's minimum size, and in the narrow measuring pass that can push the window past the screen.
    var subtitleLineLimit: Int? = nil
    @Environment(\.pageTint) private var tint
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            SymbolTile(symbol: symbol, tint: tint, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 21, weight: .semibold)).lineLimit(2)
                if let subtitleLineLimit {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(subtitleLineLimit)
                } else {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SectionTitle: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let symbol { Image(systemName: symbol).font(.callout.weight(.semibold)).foregroundStyle(.secondary).frame(width: 18) }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }
}

struct NoticeBanner: View {
    let message: String
    var tone: Tone = .information
    enum Tone { case information, success, attention, error }
    private var color: Color { switch tone { case .information: .blue; case .success: .green; case .attention: .orange; case .error: .red } }
    private var symbol: String { switch tone { case .information: "info.circle.fill"; case .success: "checkmark.circle.fill"; case .attention: "exclamationmark.triangle.fill"; case .error: "xmark.octagon.fill" } }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).font(.callout)
            Text(message).font(.callout).foregroundStyle(.primary.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct ConnectionJourney: View {
    var current: Int
    private let labels = ["连接路由器", "读取配置", "开始管理"]
    var body: some View {
        HStack(spacing: 13) {
            ForEach(Array(labels.enumerated()), id: \.offset) { index, title in
                HStack(spacing: 7) {
                    Text("\(index + 1)").font(.caption.weight(.semibold)).frame(width: 23, height: 23)
                        .background(index <= current ? Color.teal.opacity(0.12) : Color.secondary.opacity(0.08), in: Circle())
                    Text(title).font(.caption.weight(index == current ? .semibold : .regular))
                }.foregroundStyle(index <= current ? Color.teal : .secondary)
                if index < labels.count - 1 { Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary) }
            }
        }.accessibilityElement(children: .combine)
    }
}
