import SwiftUI
import RouterCore

struct CredentialAccessPanel: View {
    @Environment(RouterStore.self) var store
    var body: some View {
        if let message = store.credentialAccess.state.message {
            VStack(alignment: .leading, spacing: 10) {
                NoticeBanner(message: message, tone: store.credentialAccess.state.isWaiting ? .information : .attention)
                if let start = store.credentialAccess.state.since {
                    HStack {
                        ProgressView().controlSize(.small)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("已等待 \(max(0, Int(context.date.timeIntervalSince(start)))) 秒").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.credentialAccess.state.canStopWaiting {
                            Button("停止等待，手动输入") { store.cancelCredentialWait() }.buttonStyle(.link)
                        }
                    }
                }
            }
        }
    }
}
