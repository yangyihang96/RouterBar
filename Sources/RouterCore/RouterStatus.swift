import Foundation

// Read-only status pages of the web interface: System Info and the 系统记录 tabs. Every value comes from the
// page or the script it polls, parsed as data; nothing here changes the router.

/// A radio's temperature as ajax_coretmp.asp reports it.
public enum RouterTemperature: Sendable, Equatable {
    case celsius(Double)
    /// The radio is switched off, or the unit does not exist ("<i>disabled</i>").
    case disabled
}

/// What Tools_Sysinfo.asp renders once per visit.
public struct RouterSystemInfo: Sendable, Equatable {
    public struct Fact: Sendable, Equatable, Hashable {
        public let label: String
        public let value: String
        public init(label: String, value: String) { self.label = label; self.value = value }
    }
    public var model: String?
    /// As the page shows it, e.g. "3006.102.5".
    public var firmware: String?
    public var firmwareBuild: String?
    public var bootloader: String?
    public var cpuModel: String?
    /// One line per radio, e.g. "wl0: Jun 24 2025 … version …".
    public var wirelessDrivers: [String] = []
    /// `rc_support` sorted, as the page lists it under Features.
    public var features: [String] = []
    /// Runner (or Archer) and Flow Cache on Broadcom HND routers.
    public var hardwareAcceleration: [Fact] = []
    /// The page's `nvram_total`; the web compares NVRAM use against it.
    public var nvramTotalBytes: Double?
    /// nil when the JFFS partition is not mounted or the page does not give its size.
    public var jffsTotalMB: Double?
    /// false when the page reports the JFFS partition as not mounted (a negative size); nil when it does not say.
    public var jffsMounted: Bool?
    /// The connection limit the page prints after the connection count.
    public var connectionLimit: Int?
    /// Wi-Fi 7 routers report no "Associated" count; the web then leaves it out.
    public var reportsAssociated = true
    public init() {}
}

/// What ajax_sysinfo.asp and ajax_coretmp.asp report on each poll.
public struct RouterSystemStatus: Sendable, Equatable {
    /// mem_stats_arr in MB, labelled as the page labels it.
    public struct Memory: Sendable, Equatable {
        public let total, free, buffers, cache, swapUsed, swapTotal, used, available: Double
        /// What the page's chart calls Reclaimable.
        public var reclaimable: Double { max(0, available - free) }
    }
    public struct WirelessCounts: Sendable, Equatable {
        public let associated, authorized, authenticated: Int
    }
    public var loadAverage: [Double]?
    public var memory: Memory?
    public var nvramUsedBytes: Double?
    public var jffsFreeMB: Double?
    public struct Connections: Sendable, Equatable {
        public let total, active: Int
    }
    public var connections: Connections?
    /// By radio unit (wl0…wl3).
    public var wirelessClients: [Int: WirelessCounts] = [:]
    public var cpuTemperature: Double?
    /// By radio unit (wl0…wl3).
    public var radioTemperatures: [Int: RouterTemperature] = [:]
    /// Fan state on routers that have one.
    public var fan: String?
    public init() {}
}

/// The band each radio unit serves, from `wlN_nband`: the web's System Info and traffic tabs are named after it.
public enum RouterRadioBands {
    /// Titles by unit, e.g. [0: "2.4 GHz", 1: "5 GHz"]; two radios on one band become "5 GHz-1" and "5 GHz-2".
    public static func titles(nband: [Int: String]) -> [Int: String] {
        let names = ["2": "2.4 GHz", "1": "5 GHz", "4": "6 GHz"]
        let units = nband.keys.sorted().compactMap { unit in names[nband[unit] ?? ""].map { (unit, $0) } }
        var titles: [Int: String] = [:]
        for (unit, name) in units {
            let same = units.filter { $0.1 == name }.map(\.0)
            titles[unit] = same.count > 1 ? "\(name)-\((same.firstIndex(of: unit) ?? 0) + 1)" : name
        }
        return titles
    }
    /// The web's own guess for a router whose bands cannot be read: wl0 is 2.4 GHz and wl1 is 5 GHz.
    public static let fallback: [Int: String] = [0: "2.4 GHz", 1: "5 GHz"]
}

/// A DHCP lease as Main_DHCPStatus_Content.asp lists it.
public struct RouterDHCPLease: Sendable, Equatable, Identifiable {
    public let mac: String
    public let ip: String
    /// nil when the client sent no host name ("*").
    public let hostname: String?
    /// Seconds left when the page was read.
    public let secondsLeft: Int
    /// Only on routers with VLAN support ("mtlancfg").
    public let vlan: String?
    public var id: String { mac + "|" + ip }
}

/// Main_IPV6Status_Content.asp: the IPv6 configuration, IPv6 clients and firewall pinholes.
public struct RouterIPv6Status: Sendable, Equatable {
    public struct Client: Sendable, Equatable, Identifiable {
        public let hostname: String?
        public let mac: String
        public let addresses: [String]
        public var id: String { mac }
    }
    public struct Pinhole: Sendable, Equatable, Hashable {
        public let proto, remoteIP, remotePort, localIP, localPort, description: String
    }
    /// Label and value pairs as the page lists them; empty when IPv6 is not enabled.
    public var configuration: [RouterSystemInfo.Fact] = []
    public var clients: [Client] = []
    /// nil when pinhole support is switched off.
    public var pinholes: [Pinhole]?
    public var enabled: Bool { !configuration.isEmpty }
    public init() {}
}

/// Main_IPTStatus_Content.asp: the port forwards in effect and the UPnP, NAT-PMP and PCP mappings.
public struct RouterPortForwardStatus: Sendable, Equatable {
    public struct VirtualServer: Sendable, Equatable, Hashable {
        public let source, proto, portRange, redirectTo, localPort, chain: String
    }
    public struct Mapping: Sendable, Equatable, Hashable {
        public let proto, port, redirectTo, localPort, description: String
        /// nil when the mapping does not expire (the page shows N/A).
        public let secondsLeft: Int?
    }
    public var virtualServers: [VirtualServer] = []
    public var mappings: [Mapping] = []
    public init() {}
}

extension RouterParser {
    public static func systemInfo(_ page: String) -> RouterSystemInfo {
        var info = RouterSystemInfo()
        info.model = capture(#"<td id="model_id">([^<]*)</td>"#, in: page).map(cellText).flatMap { $0.isEmpty ? nil : $0 }
        if let major = capture(#"var firmver = '([^']*)'"#, in: page), let build = capture(#"var buildno = '([^']*)'"#, in: page) {
            let ext = capture(#"var extendno = '([^']*)'"#, in: page) ?? ""
            info.firmware = major.replacingOccurrences(of: ".", with: "") + "." + build + (ext.isEmpty || ext == "0" ? "" : "_" + ext)
        }
        func cell(_ heading: String) -> String? {
            capture("<th>" + NSRegularExpression.escapedPattern(for: heading) + #"</th>\s*<td>([^<]*)</td>"#, in: page).map(cellText).flatMap { $0.isEmpty ? nil : $0 }
        }
        info.firmwareBuild = cell("Firmware Build")
        info.bootloader = cell("Bootloader")
        info.cpuModel = cell("CPU Model")
        if let body = function("show_wifi_version", in: page) {
            info.wirelessDrivers = captures(#"buf \+= "([^"]*)""#, in: body).map { cellText($0[0]) }.filter { !$0.isEmpty && $0 != "None" }
        }
        if let caps = capture(#"var rc_caps = "([^"]*)""#, in: page) {
            info.features = caps.split(separator: " ").map(String.init).sorted()
            info.reportsAssociated = !info.features.contains("wifi7")
        }
        if let body = function("hwaccel_state", in: page) {
            let states = captures(#"\bstate = "([^"]*)""#, in: body).map { cellText($0[0]) }
            if states.count == 2 {
                let cpu = capture(#"var cpu_model = "([^"]*)""#, in: body) ?? ""
                info.hardwareAcceleration = [.init(label: cpu.contains("BCM67") ? "Archer" : "Runner", value: states[0]),
                                             .init(label: "Flow Cache", value: states[1])]
            }
        }
        info.nvramTotalBytes = capture(#"\bnvram_total = (\d+);"#, in: page).flatMap(Double.init)
        if let jffs = capture(#"jffs_total = parseFloat\("(-?[0-9.]+)"\)"#, in: page).flatMap(Double.init) {
            info.jffsMounted = jffs >= 0
            if jffs >= 0 { info.jffsTotalMB = jffs }
        }
        info.connectionLimit = capture(#"conn_stats_arr\[0\] \+ " / (\d+)"#, in: page).flatMap { Int($0) }
        return info
    }

    /// The body of a page function, up to the next function; page scripts are never run.
    private static func function(_ name: String, in page: String) -> String? {
        guard let start = page.range(of: "function \(name)(") else { return nil }
        let rest = page[start.upperBound...]
        let end = rest.range(of: "\nfunction ")?.lowerBound ?? rest.range(of: "</script>")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    public static func systemStatus(sysinfo: String, temperatures: String?) throws -> RouterSystemStatus {
        var status = RouterSystemStatus()
        func numbers(_ name: String) -> [Double]? {
            (try? strings(named: name, in: sysinfo))?.map { Double($0.trimmingCharacters(in: .whitespaces)) ?? .nan }
        }
        if let load = numbers("cpu_stats_arr"), load.count == 3, load.allSatisfy({ $0.isFinite && $0 >= 0 }) { status.loadAverage = load }
        if let m = numbers("mem_stats_arr"), m.count >= 10 {
            func valid(_ value: Double) -> Bool { value.isFinite && value >= 0 }
            if [m[0], m[1], m[2], m[3], m[4], m[5], m[8], m[9]].allSatisfy(valid) {
                status.memory = .init(total: m[0], free: m[1], buffers: m[2], cache: m[3], swapUsed: m[4], swapTotal: m[5], used: m[8], available: m[9])
            }
            if valid(m[6]) { status.nvramUsedBytes = m[6] }
            // An unmounted JFFS partition reports a negative free size; memory figures stand on their own.
            if valid(m[7]) { status.jffsFreeMB = m[7] }
        }
        if let conn = numbers("conn_stats_arr"), conn.count == 2, conn.allSatisfy({ $0.isFinite && $0 >= 0 }),
           let total = conn[0].truncatedInt, let active = conn[1].truncatedInt {
            status.connections = .init(total: total, active: active)
        }
        for unit in 0...3 {
            if let counts = numbers("wlc_\(unit)_arr"), counts.count == 3, counts.allSatisfy({ $0.isFinite && $0 >= 0 }),
               let associated = counts[0].truncatedInt, let authorized = counts[1].truncatedInt, let authenticated = counts[2].truncatedInt {
                status.wirelessClients[unit] = .init(associated: associated, authorized: authorized, authenticated: authenticated)
            }
        }
        guard status.loadAverage != nil || status.memory != nil else { throw RouterError.invalidResponse("系统信息") }
        if let temperatures {
            for match in captures(#"curr_coreTmp_wl(\d)_raw\s*=\s*"([^"]*)""#, in: temperatures) {
                guard let unit = Int(match[0]) else { continue }
                if match[1].contains("disabled") { status.radioTemperatures[unit] = .disabled }
                else if let value = capture(#"^\s*(-?\d+(?:\.\d+)?)"#, in: match[1]).flatMap(Double.init) { status.radioTemperatures[unit] = .celsius(value) }
            }
            status.cpuTemperature = capture(#"curr_cpuTemp\s*=\s*"(-?\d+(?:\.\d+)?)""#, in: temperatures).flatMap(Double.init)
            status.fan = capture(#"fanctrl_info\s*=\s*"([^"]+)""#, in: temperatures).map(cellText).flatMap { $0.isEmpty ? nil : $0 }
        }
        return status
    }

    public static func dhcpLeases(_ page: String) throws -> [RouterDHCPLease] {
        try stringRows(named: "leasearray", in: page).compactMap { row in
            guard row.count >= 4, let seconds = Int(row[0]) else { return nil }
            let name = row[3].trimmingCharacters(in: .whitespaces)
            return RouterDHCPLease(mac: row[1].uppercased(), ip: row[2], hostname: name.isEmpty || name == "*" ? nil : name,
                                   secondsLeft: seconds, vlan: row.count > 4 ? row[4] : nil)
        }
    }

    public static func ipv6Status(_ page: String) throws -> RouterIPv6Status {
        var status = RouterIPv6Status()
        status.configuration = try stringRows(named: "ipv6cfgarray", in: page).filter { $0.count >= 2 }.map { .init(label: $0[0], value: $0[1]) }
        status.clients = ((try? stringRows(named: "ipv6clientarray", in: page)) ?? []).filter { $0.count >= 3 }.map { row in
            let name = row[0].trimmingCharacters(in: .whitespaces)
            return .init(hostname: name.isEmpty || name == "*" ? nil : name, mac: row[1].uppercased(),
                         addresses: row[2].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }
        // The page decides with a value it renders into `if ("…" == "0")` ahead of "Pinhole support is currently disabled".
        let disabled = capture(#"if \("(\d*)" == "0"\) \{\s*code \+= '<tr><td colspan="5">Pinhole support is currently disabled"#, in: page) == "0"
        if !disabled {
            status.pinholes = ((try? stringRows(named: "pinholesarray", in: page)) ?? []).filter { $0.count >= 7 }.map {
                .init(proto: $0[0], remoteIP: $0[1], remotePort: $0[2], localIP: $0[3], localPort: $0[4], description: $0[6])
            }
        }
        return status
    }

    public static func portForwardStatus(_ page: String) throws -> RouterPortForwardStatus {
        var status = RouterPortForwardStatus()
        status.virtualServers = try stringRows(named: "vserverarray", in: page).filter { $0.count >= 7 }.map {
            .init(source: $0[0], proto: $0[2], portRange: $0[3], redirectTo: $0[4], localPort: $0[5], chain: $0[6])
        }
        status.mappings = try stringRows(named: "upnparray", in: page).filter { $0.count >= 6 }.map {
            let seconds = Int($0[4]) ?? 0
            return .init(proto: $0[0], port: $0[1], redirectTo: $0[2], localPort: $0[3], description: $0[5], secondsLeft: seconds > 0 ? seconds : nil)
        }
        return status
    }
}

extension RouterClient {
    public func systemInfo() async throws -> RouterSystemInfo {
        RouterParser.systemInfo(try await readManagementDocument("Tools_Sysinfo.asp"))
    }
    /// The radios' temperatures are optional: a router without the script still reports load, memory and clients.
    public func systemStatus() async throws -> RouterSystemStatus {
        let sysinfo = try await readManagementDocument("ajax_sysinfo.asp")
        let temperatures: String?
        do { temperatures = try await readManagementDocument("ajax_coretmp.asp") }
        catch RouterError.authenticationRequired { throw RouterError.authenticationRequired }
        catch is CancellationError { throw CancellationError() }
        catch { temperatures = nil }
        return try RouterParser.systemStatus(sysinfo: sysinfo, temperatures: temperatures)
    }
    public func dhcpLeases() async throws -> [RouterDHCPLease] {
        try RouterParser.dhcpLeases(try await readManagementDocument("Main_DHCPStatus_Content.asp"))
    }
    public func ipv6Status() async throws -> RouterIPv6Status {
        try RouterParser.ipv6Status(try await readManagementDocument("Main_IPV6Status_Content.asp"))
    }
    public func portForwardStatus() async throws -> RouterPortForwardStatus {
        try RouterParser.portForwardStatus(try await readManagementDocument("Main_IPTStatus_Content.asp"))
    }
}
