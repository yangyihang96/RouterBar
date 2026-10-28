#if ROUTERBAR_PREVIEW
import AppKit
import SwiftUI
import RouterCore

/// Development builds only (`-Xswiftc -DROUTERBAR_PREVIEW`): renders the main screens with made-up sample data, in light
/// and dark appearance, into PNG files, without a router, network or keychain, and without showing a window.
@MainActor
enum PreviewRenderer {
    static func run(to folder: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let only = ProcessInfo.processInfo.environment["PREVIEW_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        for screen in screens() where only?.contains(screen.name) ?? true {
            for dark in [false, true] {
                let store = makeStore(profile: screen.profile)
                screen.prepare(store)
                let view = screen.view().environment(store).environment(\.locale, Locale(identifier: "zh_CN")).tint(.teal)
                let image = render(view, size: screen.size, dark: dark, titled: screen.titled)
                let url = folder.appendingPathComponent("\(screen.name)-\(dark ? "dark" : "light").png")
                try? image?.write(to: url)
            }
        }
        print("rendered to \(folder.path)")
    }

    struct Screen {
        let name: String
        let size: CGSize
        var titled = false
        /// The router of the sample session; the reference router when nil.
        var profile: RouterProfile? = nil
        var prepare: (RouterStore) -> Void = { _ in }
        let view: () -> AnyView
    }

    static func screens() -> [Screen] {
        [
            Screen(name: "menu-panel", size: CGSize(width: 420, height: 640)) { AnyView(MenuPanel()) },
            Screen(name: "overview", size: CGSize(width: 1280, height: 860), titled: true,
                   prepare: { $0.open(.overview) }) { AnyView(DashboardView()) },
            Screen(name: "clients", size: CGSize(width: 1280, height: 860), titled: true,
                   prepare: { $0.open(.clients) }) { AnyView(DashboardView()) },
            Screen(name: "settings-firewall", size: CGSize(width: 1280, height: 860), titled: true,
                   prepare: { $0.open(section: "firewall") }) { AnyView(DashboardView()) },
            Screen(name: "settings-wireless", size: CGSize(width: 1280, height: 860), titled: true,
                   prepare: { $0.open(section: "radio1") }) { AnyView(DashboardView()) },
            // Another firmware line: the settings show their values only.
            Screen(name: "settings-readonly", size: CGSize(width: 1280, height: 860), titled: true,
                   profile: RouterProfile(model: "RT-AX86U", marketedModel: nil, firmver: "3.0.0.4", buildno: "388.8", extendno: "0",
                                          radios: [.init(unit: 0, title: "2.4 GHz", band: .ghz2_4), .init(unit: 1, title: "5 GHz", band: .ghz5)], uiSupport: [:]),
                   prepare: { $0.open(section: "firewall") }) { AnyView(DashboardView()) },
            Screen(name: "system-log", size: CGSize(width: 1280, height: 860), titled: true,
                   prepare: { $0.open(.dhcpLeases) }) { AnyView(DashboardView()) },
            Screen(name: "connection", size: CGSize(width: 1280, height: 860), titled: true,
                   prepare: { $0.open(.connection) }) { AnyView(DashboardView()) },
            Screen(name: "pending", size: CGSize(width: 1280, height: 860), titled: true,
                   prepare: { store in
                       if let page = store.menuSet.webOnlyPages.first, let menu = store.menuSet.menus.first(where: { $0.pages.contains(page) }) {
                           store.open(page: page, in: menu)
                       }
                   }) { AnyView(DashboardView()) }
        ]
    }

    // MARK: Sample data (made up; no real names or addresses)

    static func makeStore(profile other: RouterProfile? = nil) -> RouterStore {
        let store = RouterStore(autoStart: false)
        let identity = RouterIdentity(model: "RT-BE88U", firmware: "3006.102.5", lanAddress: "192.168.50.1", wanAddress: "203.0.113.24",
                                      hardwareAddress: "02:00:5E:10:00:01")
        let clients = sampleClients()
        var calculator = MetricCalculator()
        let start = ProcessInfo.processInfo.systemUptime - 10
        _ = calculator.consume(RouterSample(identity: identity, internet: .online, devices: clients, cpu: ["cpu0": CPUTicks(total: 100_000, used: 20_000)],
                                            memoryUsedKiB: 412_000, memoryTotalKiB: 1_024_000, traffic: TrafficCounters(received: 9_000_000_000, sent: 2_000_000_000),
                                            uptime: 1_234_567, sampledAt: Date().addingTimeInterval(-10), monotonicTime: start))
        let snapshot = calculator.consume(RouterSample(identity: identity, internet: .online, devices: clients, cpu: ["cpu0": CPUTicks(total: 101_000, used: 20_180)],
                                                       memoryUsedKiB: 418_000, memoryTotalKiB: 1_024_000, traffic: TrafficCounters(received: 9_124_000_000, sent: 2_018_000_000),
                                                       uptime: 1_234_577, sampledAt: Date(), monotonicTime: start + 10))
        let history: [TrafficPoint] = (0..<40).map { i in
            let x = Double(i)
            let download: Double = 6_000_000 + 5_000_000 * sin(x / 4) + Double(i % 3) * 400_000
            let upload: Double = 1_200_000 + 600_000 * cos(x / 5)
            return TrafficPoint(date: Date().addingTimeInterval((x - 40) * 10), download: download, upload: upload, segment: 0)
        }
        let profile = RouterProfile(model: "RT-BE88U", marketedModel: nil, firmver: "3.0.0.6", buildno: "102.5", extendno: "0",
                                    radios: [.init(unit: 0, title: "2.4 GHz", band: .ghz2_4), .init(unit: 1, title: "5 GHz", band: .ghz5)],
                                    uiSupport: ["sdn_mainfh": 1])
        let client = RouterClient(endpoint: try! RouterEndpoint("192.168.50.1"), transport: PreviewTransport())
        store.installPreview(client: client, snapshot: snapshot, history: history, profile: other ?? profile, menus: .reference)
        return store
    }

    static func sampleClients() -> [RouterDevice] {
        let rows: [(String, String, String, String, String)] = [
            ("MacBook Pro", "Apple", "2", "-48", "1"), ("iPhone", "Apple", "2", "-55", "1"), ("客厅电视", "Sony", "0", "", "1"),
            ("iPad", "Apple", "1", "-62", "1"), ("书房打印机", "Brother", "1", "-70", "1"), ("NAS", "Synology", "0", "", "1"),
            ("扫地机器人", "Roborock", "1", "-67", "1"), ("游戏主机", "Nintendo", "2", "-58", "1"), ("智能插座", "Xiaomi", "1", "-72", "1"),
            ("旧手机", "Samsung", "1", "-80", "0")
        ]
        var list: [String: Any] = [:]
        for (index, row) in rows.enumerated() {
            let mac = String(format: "02:00:5E:00:00:%02X", index + 16)
            list[mac] = ["name": row.0, "nickName": row.0, "vendor": row.1, "isWL": row.2, "rssi": row.3, "isOnline": row.4,
                         "ip": "192.168.50.\(index + 20)", "curTx": row.2 == "0" ? "" : "\(800 + index * 60)", "curRx": row.2 == "0" ? "" : "\(600 + index * 40)",
                         "wlConnectTime": "0\(index % 9):1\(index % 6):2\(index % 9)", "internetState": "1"]
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["get_clientlist": list])) ?? Data()
        return (try? RouterParser.clients(data)) ?? []
    }

    // MARK: Rendering

    final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
        override var canBecomeKey: Bool { true }
    }

    static func render<V: View>(_ view: V, size: CGSize, dark: Bool, titled: Bool) -> Data? {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = appearance
        let style: NSWindow.StyleMask = titled ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.borderless]
        let window = KeyWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: size.width, height: size.height), styleMask: style, backing: .buffered, defer: false)
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        if titled { window.titlebarAppearsTransparent = false; window.title = "路由器面板"; window.toolbarStyle = .unified }
        window.contentView = host
        window.setContentSize(size)
        window.orderFrontRegardless()
        // Let tasks, layout and the toolbar settle.
        for _ in 0..<12 { RunLoop.current.run(until: Date().addingTimeInterval(0.1)); host.layoutSubtreeIfNeeded() }
        let target = titled ? (window.contentView?.superview ?? host) : host
        guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { return nil }
        target.cacheDisplay(in: target.bounds, to: rep)
        window.orderOut(nil)
        return rep.representation(using: .png, properties: [:])
    }
}

/// Answers the reads a page makes with sample values, so pages render as they would with a router. Nothing is sent.
final class PreviewTransport: RouterTransport, @unchecked Sendable {
    func send(_ request: URLRequest) async throws -> RouterHTTPResponse {
        guard let url = request.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return .init(data: Data(), status: 404) }
        if parts.path.hasSuffix("appGet.cgi"), let hook = parts.queryItems?.first(where: { $0.name == "hook" })?.value {
            var result: [String: Any] = [:]
            for call in hook.split(separator: ";") where call.hasPrefix("nvram_get(") && call.hasSuffix(")") {
                let key = String(call.dropFirst("nvram_get(".count).dropLast())
                result[key] = Self.value(for: key)
            }
            return .init(data: (try? JSONSerialization.data(withJSONObject: result)) ?? Data(), status: 200)
        }
        return .init(data: Data(), status: 404)
    }
    func cancel() {}

    static let named: [String: String] = [
        "productid": "RT-BE88U", "firmver": "3.0.0.6", "buildno": "102.5", "extendno": "0", "lan_ipaddr": "192.168.50.1",
        "lan_netmask": "255.255.255.0", "wl0_ssid": "Home-WiFi", "wl1_ssid": "Home-WiFi-5G", "lan_hostname": "router",
        "wl0_nband": "2", "wl1_nband": "1", "sw_mode": "1", "time_zone": "AUS-10", "ntp_server0": "pool.ntp.org"
    ]
    static func value(for key: String) -> String {
        if let value = named[key] { return value }
        let field = SettingsCatalog.sections.flatMap(\.fields).first { $0.storageKey == key }
        guard let field else { return "" }
        if let first = field.options.first { return field.options.count > 1 ? field.options[1].value : first.value }
        switch field.kind {
        case "integer": return String(field.minimum.map { max($0, 1) * 10 } ?? 100)
        case "secret", "secretText": return "sample-passphrase"
        case "ip", "ipv4": return "192.168.50.10"
        case "toggle": return "1"
        case "rules": return ""
        default: return ""
        }
    }
}
#endif
