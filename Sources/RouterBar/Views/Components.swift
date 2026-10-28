import SwiftUI
import RouterCore

enum Format {
    static func speed(_ bytes: Double?) -> String {
        guard let bytes else { return "—" }
        if bytes >= 1_000_000 { return String(format: "%.2f MB/s", bytes / 1_000_000) }
        return String(format: "%.1f KB/s", bytes / 1_000)
    }
    static func percent(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0) } ?? "—" }
    static func uptime(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "—" }
        let whole = max(0, seconds.clampedInt)
        let hours = whole / 3600
        if hours >= 24 { return "\(hours / 24) 天 \(hours % 24) 小时" }
        return "\(hours) 小时 \(whole / 60 % 60) 分钟"
    }
}

/// Counts down to the next automatic reconnect.
struct ReconnectCountdown: View {
    let at: Date
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text("· \(max(0, Int(at.timeIntervalSince(context.date).rounded(.up)))) 秒后自动重连").monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

struct StatusBadge: View {
    @Environment(RouterStore.self) var store
    var body: some View {
        StatusDot(color: store.statusColor, text: store.statusTitle)
            .font(.caption.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 5)
            .background(store.statusColor.opacity(0.12), in: Capsule())
    }
}

/// A card. Pages place their content in these on the canvas.
struct Panel<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content.padding(18).frame(maxWidth: .infinity, alignment: .leading).card()
    }
}

/// One figure: what it is, the value, and a line of context. The value stays in the text color; the icon carries color.
struct StatCard: View {
    /// Figures in one row line up.
    static let height: CGFloat = 96
    let title: String
    let value: String
    let symbol: String
    let tint: Color
    var note: String? = nil
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Image(systemName: symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(tint == .primary ? Color.secondary : tint)
                    Text(title).font(.subheadline).foregroundStyle(.secondary)
                }
                Text(value).font(.system(size: 25, weight: .semibold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6)
                Spacer(minLength: 0)
                if let note { Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }.frame(minHeight: StatCard.height, alignment: .topLeading)
        }
    }
}

struct KeyValue: View {
    let key: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.callout).padding(.vertical, 3)
    }
}

struct FreshnessView: View {
    @Environment(RouterStore.self) var store
    var body: some View {
        if let date = store.snapshot?.sample.sampledAt {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                let age = context.date.timeIntervalSince(date)
                HStack(spacing: 5) {
                    Image(systemName: "clock")
                    Text(age > 90 || !store.hasLiveSession ? "上次成功读取" : "更新于")
                    Text(date, style: .relative)
                    Text("前")
                }.font(.caption).foregroundStyle(age > 90 || !store.hasLiveSession ? Color.orange : Color.secondary)
            }
        }
    }
}
