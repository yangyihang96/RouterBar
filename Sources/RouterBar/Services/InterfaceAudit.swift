#if ROUTERBAR_AUDIT
import Foundation
import RouterCore

/// Development-only read audit. Never submits a settings form or exports credentials.
enum InterfaceAudit {
    static func run(client: RouterClient, destination: URL) async throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var pages = [
            "js/httpApi.js", "js/asus.js", "require/modules/menuTree.js", "client_function.js",
            "Advanced_Wireless_Content.asp", "Advanced_WAdvanced_Content.asp", "Advanced_WWPS_Content.asp", "Advanced_ACL_Content.asp", "Advanced_WMode_Content.asp", "Advanced_WSecurity_Content.asp",
            "SDN.asp", "AiMesh.asp", "Advanced_LAN_Content.asp", "Advanced_DHCP_Content.asp", "Advanced_GWStaticRoute_Content.asp", "Advanced_IPTV_Content.asp", "Advanced_SwitchCtrl_Content.asp",
            "Advanced_WAN_Content.asp", "Advanced_WANPort_Content.asp", "Advanced_WAN_Content.asp", "Advanced_WANPort_Content.asp", "Advanced_VirtualServer_Content.asp", "Advanced_PortTrigger_Content.asp", "Advanced_Exposed_Content.asp", "Advanced_ASUSDDNS_Content.asp", "Advanced_NATPassThrough_Content.asp",
            "Advanced_IPv6_Content.asp", "Advanced_VPNStatus.asp", "Advanced_VPNClient_Content.asp", "Advanced_VPNServer_Content.asp", "Advanced_OpenVPNClient_Content.asp", "Advanced_OpenVPNServer_Content.asp", "Advanced_WireguardClient_Content.asp", "Advanced_WireguardServer_Content.asp", "VPNDirector.asp",
            "Advanced_BasicFirewall_Content.asp", "Advanced_Firewall_Content.asp", "Advanced_URLFilter_Content.asp", "Advanced_KeywordFilter_Content.asp",
            "AiProtection_HomeProtection.asp", "AiProtection_WebProtector.asp", "AiProtection_InfectedDevicePreventBlock.asp", "AiProtection_IntrusionPreventionSystem.asp", "AiProtection_MaliciousSitesBlocking.asp",
            "AdaptiveQoS_Bandwidth_Monitor.asp", "QoS_EZQoS.asp", "QoS_Adaptive.asp", "QoS_UserRules.asp", "QoS_UserPrio.asp", "Bandwidth_Limiter.asp", "Main_TrafficMonitor_realtime.asp", "GameBoost.asp", "GameProfile.asp", "UUAccelerator.asp",
            "APP_Installation.asp", "Advanced_AiDisk_samba.asp", "Advanced_AiDisk_ftp.asp", "Advanced_AiDisk_MediaServer.asp", "Advanced_TimeMachine.asp", "cloud_main.asp", "Advanced_Smart_Home_Alexa.asp",
            "Advanced_OperationMode_Content.asp", "Advanced_System_Content.asp", "Advanced_FirmwareUpgrade_Content.asp", "Advanced_SettingBackup_Content.asp", "Advanced_SNMP_Content.asp", "Tools_OtherSettings.asp", "Tools_Sysinfo.asp", "Main_LogStatus_Content.asp", "Main_Analysis_Content.asp"
        ]
        pages += ["state.js", "detect_firmware.asp", "ajax_fwdl_percent.asp", "SDN/sdn.html", "VPN/vpns.html", "VPN/vpnc.html", "aimesh/aimesh_topology.html", "aimesh/aimesh_system_settings.html", "Advanced_VPNDirector.asp", "Advanced_VPN_OpenVPN.asp", "Advanced_VPN_PPTP.asp", "Advanced_VPN_IPSec.asp", "Advanced_Instant_Guard.asp", "DNSDirector.asp", "Advanced_AiDisk_NFS.asp", "mediaserver.asp", "Guest_network.asp", "MLO.asp", "Advanced_Smart_Connect.asp", "Advanced_QOSUserRules_Content.asp", "Advanced_QOSUserPrio_Content.asp", "Main_WOL_Content.asp", "Main_Netstat_Content.asp", "Main_RouteStatus_Content.asp", "Main_ConnStatus_Content.asp", "Main_WStatus_Content.asp", "Main_TrafficMonitor_settings.asp", "TrafficAnalyzer_Statistic.asp", "cloud_settings.asp", "cloud_sync.asp", "cloud_router_sync.asp", "Advanced_Roaming_Block_Content.asp"]
        // Read-only status pages and the scripts they poll, for the 1.7 native pages.
        pages += ["ajax_sysinfo.asp", "ajax_coretmp.asp", "Main_DHCPStatus_Content.asp", "Main_IPV6Status_Content.asp", "Main_IPTStatus_Content.asp", "Main_TrafficMonitor_last24.asp", "Main_TrafficMonitor_daily.asp", "Main_TrafficMonitor_monthly.asp", "tmcal.js", "tmmenu.js", "tmhist.js"]
        // 1.9: the pages behind AiProtection's records, Traffic Analyzer's statistics and 网页浏览历史.
        pages += ["AdaptiveQoS_WebHistory.asp", "Advanced_Privacy.asp", "cloud_syslog.asp"]
        // 1.12: the pages still without native views, as this model serves them (FUNCTION sysdep variants included),
        // and the scripts and frames they load. Only the documents are read and their scripts never run here; the router
        // still runs the server-side functions a page calls while it serves it (cloud_main.asp's apps_action() sets
        // apps_state_action, Advanced_IPv61_Content.asp's wan_get_parameter() copies wanN_ to wan_, neither committed).
        pages += ["QIS_wizard.htm", "ParentalControl.asp", "AdaptiveQoS_InternetSpeed.asp", "internet_speed.html", "aidisk.asp",
                  "aidisk/Aidisk-1.asp", "aidisk/Aidisk-2.asp", "aidisk/Aidisk-3.asp", "aidisk/Aidisk-4.asp", "PrinterServer.asp",
                  "Advanced_IPv61_Content.asp", "Advanced_Wireless_Survey.asp", "js/searchOpenNatProfile.js", "js/gameProfile.js",
                  "js/weekSchedule/weekSchedule.js", "Advanced_Smart_Home_IFTTT.asp", "GameBoost_Tencent.asp"]
        var results = try await captureData(client: client, destination: destination)
        // Pages whose serving changes something on the router are not read here (RouterClient.activeDocuments).
        var queue = Array(Set(pages).subtracting(RouterClient.activeDocuments)).sorted()
        var seen = Set<String>()
        while !queue.isEmpty {
            let path = queue.removeFirst()
            guard seen.insert(path).inserted else { continue }
            let existing = destination.appendingPathComponent(path.replacingOccurrences(of: "/", with: "__"))
            if FileManager.default.fileExists(atPath: existing.path) { continue }
            do {
                let content = try await client.readManagementDocument(path)
                if path.contains("/") && (path.hasSuffix(".html") || path.hasSuffix(".js")) {
                    let regex = try NSRegularExpression(pattern: #"["']/([A-Za-z0-9_/-]+\.(?:js|html))["']"#)
                    for m in regex.matches(in: content, range: NSRange(content.startIndex..., in: content)) {
                        if let r = Range(m.range(at: 1), in: content) {
                            let dep = String(content[r])
                            if ["SDN/", "VPN/", "aimesh/", "js/sdn", "js/vpn"].contains(where: { dep.hasPrefix($0) }) { queue.append(dep) }
                        }
                    }
                }
                let file = destination.appendingPathComponent(path.replacingOccurrences(of: "/", with: "__"))
                try content.write(to: file, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                results.append(["path": path, "status": "read", "bytes": "\(content.utf8.count)"])
            } catch RouterError.authenticationRequired { throw RouterError.authenticationRequired }
            catch { results.append(["path": path, "status": "unavailable"]) }
            try await Task.sleep(for: .milliseconds(150))
        }
        let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: destination.appendingPathComponent("inventory.json"))
    }
    /// The data the 1.9 read-only pages show, read the way the web pages read it when they open, plus the switches and
    /// capabilities that decide whether the web shows it. Raw answers stay in `data/` next to the pages.
    static func captureData(client: RouterClient, destination: URL) async throws -> [[String: String]] {
        let folder = destination.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        func save(_ name: String, _ content: String) throws {
            let file = folder.appendingPathComponent(name)
            try content.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        var results: [[String: String]] = []
        let keys = ["wrs_protect_enable", "wrs_mals_enable", "wrs_vp_enable", "wrs_cc_enable", "wrs_mals_t", "wrs_vp_t", "wrs_cc_t",
                    "TM_EULA", "bwdpi_db_enable", "dns_dpi_trf_analysis", "apps_analysis", "dns_dpi_apps_analysis", "bwdpi_wh_enable",
                    "qos_enable", "qos_type", "rstats_enable", "rstats_path", "rstats_stime", "rstats_new", "rstats_offset", "time_zone_x",
                    "enable_webdav", "enable_cloudsync", "ASUS_NEW_EULA", "ASUS_EULA"]
        var settings: [String: String] = [:]
        for start in stride(from: 0, to: keys.count, by: 6) {
            settings.merge(try await client.readSettings(Array(keys[start..<min(start + 6, keys.count)]))) { _, new in new }
        }
        let support = try await client.uiCapabilities()
        let flags = ["bwdpi", "dns_dpi", "adaptive_qos", "traffic_analyzer", "webdav", "cloudsync", "aicloudipk", "usbX"]
        let report: [String: Any] = ["settings": settings, "ui_support": support.filter { flags.contains($0.key) }, "mac_time": ISO8601DateFormatter().string(from: .now)]
        try save("switches.json", String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        // The raw values behind the 网络 page's WiFi7 模式 and 认证 rows and the per-band `wl*_11be`, to check the 1.9 Wi-Fi 7
        // switch against. Only the band, auth and crypto columns of `_security`: the fourth is the password.
        let sdn = try LosslessRuleTable(try await client.readSettings(["sdn_rl"])["sdn_rl"] ?? "", minimumColumns: 16)
        var networks: [[String: Any]] = []
        for row in sdn.rows where row[0] != "0" {
            let prefix = (["MAINFH", "MAINBH"].contains(row[1]) ? "apm" : "apg") + row[5] + "_"
            let values = try await client.readSettings([prefix + "11be", prefix + "mlo", prefix + "security"])
            let security = try LosslessRuleTable(values[prefix + "security"] ?? "", minimumColumns: 4).rows.map { Array($0.prefix(3)) }
            networks.append(["id": row[0], "kind": row[1], "enabled": row[2], "prefix": prefix, "11be": values[prefix + "11be"] ?? "", "mlo": values[prefix + "mlo"] ?? "", "security": security])
        }
        let wifi7: [String: Any] = ["networks": networks, "bands": try await client.readSettings(["wl0_11be", "wl1_11be", "wl2_11be"]),
                                    "ui_support": support.filter { ["wifi7", "mlo", "sdn_mainfh", "sdn_mwl"].contains($0.key) }]
        try save("wifi7.json", String(decoding: try JSONSerialization.data(withJSONObject: wifi7, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        try save("wireless.json", try await captureWireless(client: client, support: support))
        let now = String(Int(Date().timeIntervalSince1970))
        var reads: [(String, RouterDataPage, [(String, String)])] = [("counts", .protectionCounts, [])]
        for type in ["vp", "mals", "cc"] {
            reads.append(("\(type)-mac", .protectionEvents, [("type", type), ("event", "mac")]))
            reads.append(("\(type)-all", .protectionEventDetails, [("type", type), ("event", "all")]))
            reads.append(("\(type)-chart", type == "vp" ? .intrusionChart : .protectionChart, [("type", type), ("date", now)]))
        }
        for (suffix, clients, apps) in [("", RouterDataPage.clientStatistics, RouterDataPage.appStatistics), ("-dns", .clientStatisticsDNS, .appStatisticsDNS)] {
            for (mode, dura) in [("hour", "24"), ("day", "7"), ("day", "31")] {
                reads.append(("wan-\(mode)-\(dura)\(suffix)", apps, [("client", "all"), ("mode", mode), ("dura", dura), ("date", now)]))
            }
            for dura in ["24", "7", "31"] {
                reads.append(("clients-\(dura)\(suffix)", clients, [("client", "all"), ("mode", "detail"), ("dura", dura), ("date", now)]))
                reads.append(("apps-\(dura)\(suffix)", apps, [("client", "all"), ("mode", "detail"), ("dura", dura), ("date", now)]))
            }
        }
        reads.append(("webhistory-1", .webHistory, [("client", "all"), ("page", "1")]))
        reads.append(("traffic-a", .realtimeTraffic, []))
        reads.append(("traffic-dns-a", .realtimeTrafficDNS, []))
        func read(_ name: String, _ page: RouterDataPage, _ query: [(String, String)]) async throws -> String? {
            do {
                let content = try await client.readDataPage(page, query)
                try save(name + ".txt", content)
                results.append(["path": "data/\(name)", "status": "read", "bytes": "\(content.utf8.count)"])
                return content
            } catch RouterError.authenticationRequired { throw RouterError.authenticationRequired }
            catch { results.append(["path": "data/\(name)", "status": "unavailable", "error": error.localizedDescription]); return nil }
        }
        var answers: [String: String] = [:]
        for (name, page, query) in reads {
            answers[name] = try await read(name, page, query)
            try await Task.sleep(for: .milliseconds(200))
        }
        // A second realtime read a few seconds later shows how the counters advance, and one device's breakdown shows
        // the per-app rows the web lists under a device.
        try await Task.sleep(for: .seconds(4))
        _ = try await read("traffic-b", .realtimeTraffic, [])
        let macPattern = #"[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}"#
        if let mac = (answers["clients-24"] ?? answers["clients-24-dns"]).flatMap({ RouterParser.capture("(" + macPattern + ")", in: $0) }) {
            _ = try await read("client-apps-24", .appStatistics, [("client", mac), ("mode", "detail"), ("dura", "24"), ("date", now)])
            _ = try await read("client-traffic", .realtimeTraffic, [("client", mac)])
        }
        return results
    }
    /// 1.10: the variables behind 无线 › WPS、WDS、漫游阻止列表、MLO and Smart Connect 规则, read the way those pages read them.
    /// MAC lists keep only their shape. WPS_info.xml also holds the network name and key, so of it only the fields the page
    /// shows are kept, the PIN as its length.
    static func captureWireless(client: RouterClient, support: [String: String]) async throws -> String {
        var keys = ["wlnband_list", "sw_mode", "wlc_band", "wl_unit", "ap_wifi_rl", "sdn_rl", "productid", "wps_enable", "wps_band_x", "wps_multiband",
                    "wps_dualband", "wsc_config_state", "wl_wps_mode", "wl_closed", "rast_static_cli_enable", "smart_connect_x",
                    "smart_connect_selif_x", "bsd_bounce_detect", "mld_enable", "mlo_bh_band"]
        for unit in 0...2 {
            keys += ["nband", "radio", "auth_mode_x", "wep_x", "closed", "mode_x", "wdsapply_x", "wdslist", "wdsnum_x", "bw", "chanspec", "channel",
                     "hwaddr", "bsd_steering_policy", "bsd_if_qualify_policy", "bsd_sta_select_policy", "bsd_if_select_policy", "txchain",
                     "rast_static_client"].map { "wl\(unit)_\($0)" }
        }
        var values = try await client.readSettings(keys)
        let subunit = SmartConnectSubunit.mainFronthaul(sdnRL: values["sdn_rl"] ?? "", apWifiRL: values["ap_wifi_rl"] ?? "")
        values.merge(try await client.readSettings((0...2).flatMap { ["wl\($0).\(subunit)_bsd_sta_select_policy", "wl\($0).\(subunit)_bsd_if_select_policy"] })) { _, new in new }
        let mac = #"(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}"#
        for (key, value) in values where key.hasSuffix("wdslist") || key.hasSuffix("rast_static_client") || key.hasSuffix("hwaddr") {
            values[key] = value.replacingOccurrences(of: mac, with: "MAC", options: .regularExpression)
        }
        func captures(_ pattern: String, in text: String) -> [[String]] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
                (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
            }
        }
        var wps: [String: Any] = [:]
        do {
            let xml = try await client.readDataPage(.wpsStatus)
            var fields: [String: [Any]] = [:], selfClosing: [String: [Int]] = [:]
            // Empty items may come as <wps_info/>: their positions are kept so the item numbers stay right.
            for match in captures(#"<(wps_info\d?)(?:\s*(/)>|\s*>([^<]*)</\1\s*>)"#, in: xml) {
                let index = fields[match[0], default: []].count
                let value = match[2]
                if match[1] == "/" { selfClosing[match[0], default: []].append(index) }
                if [0, 1, 11, 12].contains(index) { fields[match[0], default: []].append(value) }
                else if index == 7 { fields[match[0], default: []].append(["length": value.count, "digits": value.allSatisfy(\.isNumber)]) }
                else { fields[match[0], default: []].append(["length": value.count]) }
            }
            let tags = Set(captures(#"<([A-Za-z_][A-Za-z0-9_]*)\b"#, in: xml).map { $0[0] })
            wps = ["fields": fields, "selfClosing": selfClosing, "tags": tags.sorted(), "bytes": xml.utf8.count]
        } catch RouterError.authenticationRequired { throw RouterError.authenticationRequired }
        catch { wps = ["error": error.localizedDescription] }
        let flags = ["5G", "wps_multiband", "lyra_hide", "noWiFi", "rawifi", "lantiq", "wigig", "wl6", "smart_connect", "smart_connect_v2", "bandstr",
                     "mlo", "mlo_bh_band", "sdn_mwl", "sdn_mainfh", "bcmwifi", "wifi7", "amas", "rast",
                     // What require/modules/menuTree.js hides the five pages by: Smart Connect 543–544 (and 695–759 by mode),
                     // 漫游阻止列表 644–652, MLO 667–668, WPS and WDS 712–718 in repeater mode.
                     "qcawifi", "amasRouter", "amasNode", "mtlancfg", "user_low_rssi", "concurrep"]
        let report: [String: Any] = ["settings": values, "subunit": subunit, "wps": wps, "sdnOnline": try await client.sdnOnlineCounts(),
                                     "ui_support": support.filter { flags.contains($0.key) }, "mac_time": ISO8601DateFormatter().string(from: .now)]
        return String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
    }
    static func verifyNative(client: RouterClient, destination: URL) async throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        func progress(_ stage: String) throws { try JSONSerialization.data(withJSONObject: ["stage": stage, "timestamp": ISO8601DateFormatter().string(from: .now)]).write(to: destination, options: .atomic) }
        try progress("reading catalog")
        let sections = SettingsCatalog.sections
        let keys = Array(Set(sections.flatMap { $0.fields.map(\.storageKey) }))
        var values: [String: String] = [:]
        for start in stride(from: 0, to: keys.count, by: 6) {
            let group = Array(keys[start..<min(start + 6, keys.count)])
            do { values.merge(try await client.readSettings(group)) { _, new in new } }
            catch {
                for key in group {
                    if let single = try? await client.readSettings([key]) { values.merge(single) { _, new in new } }
                }
            }
            try progress("catalog keys read \(values.count) of \(keys.count)")
        }
        var result: [[String: Any]] = []
        for section in sections {
            var incompatibleRules: [String] = []
            for field in section.fields where field.kind == "rules" {
                if (try? RouterRuleCodec.decode(values[field.key] ?? "", columns: field.columns.count)) == nil { incompatibleRules.append(field.key) }
            }
            result.append(["section": section.id, "fields": section.fields.count, "allReturned": section.fields.allSatisfy { values[$0.storageKey] != nil }, "ruleFormatsNeedingAdapter": incompatibleRules])
        }
        try progress("reading firmware status")
        let firmware = try await client.firmwareState()
        let sdn = try await client.readSettings(["sdn_rl", "subnet_rl", "vlan_rl", "rc_support"])
        let sdnRows = (sdn["sdn_rl"] ?? "").split(separator: "<").map { $0.components(separatedBy: ">") }
        try progress("reading SDN profiles")
        let nativeNetworks = try await client.sdnSnapshot()
        let sdnSummary = sdnRows.map { row -> [String: Any] in ["id": row.first ?? "", "kind": row.count > 1 ? row[1] : "", "columns": row.count] }
        let mesh = try await client.meshNodes()
        let vpnKeyCount = (try? await client.vpnKeyMaterial(.openVPNClient(1)).count) ?? -1
        let peerCount = (try? await client.wireGuardPeerConfigurations().count) ?? -1
        var radios: [[String: Any]] = []
        for unit in 0...1 {
            do {
                let radio = try await client.readRadioChannels(unit: unit)
                radios.append(["unit":unit, "choices":radio.choices.count, "bandwidths":radio.widths.map(\.rawValue), "read":true])
            } catch { radios.append(["unit":unit, "read":false, "error":error.localizedDescription]) }
        }
        var diagnosticSizes: [String: Int] = [:]
        for kind in ["syslog", "routes", "connections"] { diagnosticSizes[kind] = (try? await client.readDiagnostic(kind).utf8.count) ?? -1 }
        let report: [String: Any] = ["radioCapabilities": radios, "wireGuardPeerSlotsRead":peerCount, "vpnKeyFieldsRead": vpnKeyCount, "diagnosticSizes": diagnosticSizes, "meshNodesRead": mesh.count, "nativeNetworkProfilesRead": nativeNetworks.profiles.count, "sdnProfiles": sdnSummary, "rc_support": sdn["rc_support"] ?? "", "sections": result, "uniqueKeys": keys.count, "returnedKeys": values.count, "missingKeys": keys.filter { values[$0] == nil }, "firmwareStatusRead": true, "reportedLatest": firmware.latest, "writesPerformed": 0, "timestamp": ISO8601DateFormatter().string(from: .now)]
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

}

#endif
