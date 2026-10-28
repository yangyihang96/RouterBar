import Foundation

/// Status data the web's AiProtection, Traffic Analyzer and Adaptive QoS pages read when they open. Each is a GET
/// whose handler only reports (Asuswrt-Merlin 3006.102.5 httpd/web.c: do_sqlite_Stat_hook 32580, ej_bwdpi_history
/// 32612, ej_bwdpi_monitor_stat/info/ips/nonips 32633–32681, the ej_dns_* variants 32829–32899). The pages' changing
/// calls (white list, clearing logs, erasing events) use other URLs and cannot be reached through this list.
public enum RouterDataPage: String, Sendable, CaseIterable {
    /// `event_count = …`: blocked counts of the three protections.
    case protectionCounts = "getAiProtectionEvent.asp"
    /// `data = '…'`: hits per device (`event=mac`) or every event (`event=all`) of one protection (`type`).
    case protectionEvents = "getIPSEvent.asp"
    case protectionEventDetails = "getIPSDetailEvent.asp"
    /// `data = '…'`: seven days of high, medium and low counts ending at `date`.
    case intrusionChart = "getIPSChart.asp"
    case protectionChart = "getNonIPSChart.asp"
    /// `array_statistics = …` from Traffic Analyzer's database, by `client`, `mode`, `dura` and `date`.
    case clientStatistics = "getAppTraffic.asp"
    case clientStatisticsDNS = "getAppTraffic_Dns.asp"
    case appStatistics = "getWanTraffic.asp"
    case appStatisticsDNS = "getWanTraffic_Dns.asp"
    /// `array_temp = …`: one page of 网页浏览历史.
    case webHistory = "getWebHistory.asp"
    /// `array_traffic = …; router_traffic = …`: cumulative counters per device, or per app of one `client`
    /// (ej_bwdpi_status 32740 and ej_dns_status, which validate the arguments before reading).
    case realtimeTraffic = "getTraffic.asp"
    case realtimeTrafficDNS = "getTraffic_Dns.asp"
    /// The WPS page's status poll (Advanced_WWPS_Content.asp 407–411): `nvram_dump("wps_info.log","")`, which only reports
    /// (web.c ej_dump 2569–2579). The answer also holds the network name and key; WPSStatus keeps the fields the page shows.
    case wpsStatus = "WPS_info.xml"
    /// The VLAN page's port status (Advanced_VLAN_Switch_Content.asp 335–358, 674–686): `node_mac` is a node's MAC or
    /// "all". do_get_port_status_cgi only reports (web.c 25302–25340); the cable test next to it is another URL.
    case portStatus = "get_port_status.cgi"

    /// The parameters the web sends to these pages.
    static let parameters: Set<String> = ["type", "event", "date", "client", "mode", "dura", "page", "node_mac"]
}

extension RouterClient {
    /// One allow-listed data page. Values are limited to what the web sends: words, numbers and MAC addresses.
    public func readDataPage(_ page: RouterDataPage, _ query: [(String, String)] = []) async throws -> String {
        var items: [URLQueryItem] = []
        for (name, value) in query {
            guard RouterDataPage.parameters.contains(name), value.range(of: #"^[A-Za-z0-9:._-]{1,40}$"#, options: .regularExpression) != nil
            else { throw RouterError.validation("数据页面参数不受支持：\(name)") }
            items.append(URLQueryItem(name: name, value: value))
        }
        return String(decoding: try await request(page.rawValue, query: items, timeout: 15), as: UTF8.self)
    }
}
