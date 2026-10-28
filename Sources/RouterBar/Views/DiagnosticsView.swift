import SwiftUI
import RouterCore

/// The read-only log and tool pages of 系统记录 and 网络工具, one mode per web tab.
enum DiagnosticsMode: Hashable {
    case systemLog, routeTable, connections, networkAnalysis, netstat
    /// readDiagnostic tab for the log pages.
    var source: String? {
        switch self {
        case .systemLog: "syslog"
        case .routeTable: "routes"
        case .connections: "connections"
        case .networkAnalysis, .netstat: nil
        }
    }
    /// Methods the web page offers, as RouterClient.startDiagnostic codes.
    var methods: [(code: String, title: String)] {
        switch self {
        case .networkAnalysis: [("3", "Ping"), ("4", "Traceroute"), ("5", "DNS 查询")]
        case .netstat: [("6", "Netstat"), ("7", "NAT 连接")]
        default: []
        }
    }
    var title: String {
        switch self {
        case .systemLog: "系统记录"
        case .routeTable: "路由表"
        case .connections: "连接"
        case .networkAnalysis: "网络诊断"
        case .netstat: "Netstat"
        }
    }
    var subtitle: String {
        switch self {
        case .systemLog: "路由器的系统日志，可以保存为文本。"
        case .routeTable: "路由器当前的 IPv4 与 IPv6 路由表。"
        case .connections: "当前经过路由器的网络连接（连接追踪表）。"
        case .networkAnalysis: "用 Ping、Traceroute 或 DNS 查询检查连通性，结果由路由器返回。"
        case .netstat: "路由器上的网络连接与 NAT 连接。"
        }
    }
    var symbol: String {
        switch self {
        case .systemLog: "doc.text"
        case .routeTable: "arrow.triangle.branch"
        case .connections: "point.3.connected.trianglepath.dotted"
        case .networkAnalysis: "waveform.path.ecg"
        case .netstat: "list.bullet.rectangle"
        }
    }
}

struct DiagnosticsView: View {
    @Environment(RouterStore.self) var store
    let mode: DiagnosticsMode
    @State private var text = ""
    @State private var error: String?
    @State private var busy = false
    @State private var method = ""
    @State private var host = ""
    @State private var ipVersion = "v4"
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { PageHeader(title: mode.title, subtitle: mode.subtitle, symbol: mode.symbol); Spacer(); if busy { ProgressView().controlSize(.small) } }
            if mode.source == nil {
                HStack {
                    Picker("诊断类型", selection: $method) { ForEach(mode.methods, id: \.code) { Text($0.title).tag($0.code) } }.labelsHidden().frame(width: 140)
                    if !["6", "7"].contains(method) { TextField("IP 地址或域名", text: $host).textFieldStyle(.roundedBorder); Picker("协议", selection: $ipVersion) { Text("IPv4").tag("v4"); Text("IPv6").tag("v6") }.labelsHidden().frame(width: 100) }
                    Spacer(); Button("运行诊断") { Task { await diagnose() } }.buttonStyle(.borderedProminent).tint(.teal)
                }.disabled(busy || store.phase != .connected || store.operationTitle != nil)
            } else {
                HStack { Button("读取") { Task { await read() } }.disabled(busy || store.phase != .connected || store.operationTitle != nil); Spacer(); Button("保存文本…", action: export).disabled(text.isEmpty) }
            }
            if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange).font(.callout) }
            ScrollView([.horizontal, .vertical]) { Text(text.isEmpty ? (mode.source == nil ? "选择诊断类型后运行，结果由路由器返回。" : "点击“读取”获取路由器返回的结果。") : text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(18) }
                .frame(maxWidth: .infinity, maxHeight: .infinity).card()
        }.padding(30)
        .onAppear { if method.isEmpty { method = mode.methods.first?.code ?? "" } }
    }
    func read() async {
        guard let source = mode.source else { return }
        busy = true; error = nil; defer { busy = false }
        do { text = try await store.connectedClient().readDiagnostic(source) }
        catch { self.error = error.localizedDescription; store.handleManagementError(error) }
    }
    func diagnose() async {
        guard store.beginOperation("正在执行网络诊断", readOnly: true) else { return }; busy = true; error = nil
        defer { busy = false; store.endOperation() }
        do {
            let client = try store.connectedClient()
            let job = try await client.startDiagnostic(method: method, host: host, version: ipVersion)
            for _ in 0..<60 {
                try await Task.sleep(for: .seconds(1))
                let result = try await client.diagnosticResult(job: job)
                text = result.text
                if result.complete { return }
            }
            error = "诊断仍未结束，可以稍后重新读取。"
        } catch { self.error = error.localizedDescription; store.handleManagementError(error) }
    }
    func export() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Router-\(mode.source ?? "diagnostic").txt"
        // Logs name devices, addresses and connections, so they are saved readable by this user only.
        if panel.runModal() == .OK, let url = panel.url { do { try PrivateFile.write(Data(text.utf8), to: url) } catch { self.error = error.localizedDescription } }
    }
}
