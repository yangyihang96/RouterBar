import SwiftUI
import RouterCore

/// What one read-only page last read from the router, when, and why the last read failed. A failed read keeps
/// the previous value on screen with its time, so the page never passes old figures off as new.
@MainActor
final class RouterReading<Value: Sendable>: ObservableObject {
    @Published private(set) var value: Value?
    @Published private(set) var readAt: Date?
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    private var token = UUID()

    /// Reads through the shared login. Skipped while another router operation (a save, a restart) is under way, and
    /// while this page is already reading unless `supersede` says the new read replaces that one: a page whose request
    /// changed (another period, another device) passes it, so the older answer is dropped instead of the newer request.
    func load(store: RouterStore, supersede: Bool = false, _ read: (RouterClient) async throws -> Value) async {
        guard store.phase == .connected, store.operationTitle == nil, supersede || !loading else { return }
        let id = UUID(); token = id; loading = true
        defer { if token == id { loading = false } }
        do {
            let result = try await read(try store.connectedClient())
            // A read cancelled with its page publishes nothing, even if it finished with what it had.
            guard token == id, !Task.isCancelled else { return }
            value = result; readAt = .now; error = nil
        } catch is CancellationError {
        } catch {
            guard token == id else { return }
            self.error = error.localizedDescription
            store.handleManagementError(error)
        }
    }
}

/// The shared header of the read-only status pages: title, when the page was read, and a way to read again.
struct StatusPageHeader: View {
    @Environment(RouterStore.self) var store
    let title: String
    let subtitle: String
    let symbol: String
    let readAt: Date?
    let loading: Bool
    /// For a page that does not scroll as a whole (see PageHeader).
    var subtitleLineLimit: Int? = nil
    let reload: () async -> Void
    /// The read 重新读取 started. Leaving the page cancels it, as leaving a web page ends its script, so it does not go on
    /// sending requests for a page that is no longer shown.
    @State private var reading: Task<Void, Never>?

    var body: some View {
        HStack(alignment: .top, spacing: 15) {
            PageHeader(title: title, subtitle: subtitle, symbol: symbol, subtitleLineLimit: subtitleLineLimit)
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 10) {
                    if loading { ProgressView().controlSize(.small) }
                    Button("重新读取") { reading?.cancel(); reading = Task { await reload() } }
                        .disabled(store.phase != .connected || loading || store.operationTitle != nil)
                }
                if let readAt { Text("读取于 \(MonitoringDate.time(readAt))").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .onDisappear { reading?.cancel(); reading = nil }
    }
}

/// A read error under the header; the page keeps showing what was read before.
struct ReadErrorLabel: View {
    let message: String?
    var body: some View {
        if let message { Label(message, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange) }
    }
}

extension Format {
    /// 1024-based, as the router's traffic tables count (KB, MB, GB).
    static func bytes(_ value: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var amount = max(0, value), index = 0
        while amount >= 1024, index < units.count - 1 { amount /= 1024; index += 1 }
        return index == 0 ? "\(Int(amount)) B" : String(format: "%.2f %@", amount, units[index])
    }
    /// A countdown such as "23:51:58" or "2 天 03:04:05".
    static func remaining(_ seconds: Double) -> String {
        let total = max(0, seconds.rounded(.down).clampedInt)
        let clock = String(format: "%02d:%02d:%02d", total / 3600 % 24, total / 60 % 60, total % 60)
        return total >= 86_400 ? "\(total / 86_400) 天 \(clock)" : clock
    }
}

/// Where a page's content goes until its first read: a spinner while reading, and after a failed read (the error is
/// shown above it) a note that the page can be read again, instead of a spinner that never ends.
struct ReadingPlaceholder: View {
    var failed = false
    var minHeight: CGFloat = 220
    var body: some View {
        if failed {
            ContentUnavailableView("未能读取", systemImage: "exclamationmark.arrow.triangle.2.circlepath", description: Text("可以点“重新读取”再试一次。"))
                .frame(maxWidth: .infinity, minHeight: minHeight)
        } else {
            ProgressView("正在读取…").frame(maxWidth: .infinity, minHeight: minHeight)
        }
    }
}
