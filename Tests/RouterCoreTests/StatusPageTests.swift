import Foundation
import Testing
@testable import RouterCore

// Fixtures follow the shape of Asuswrt-Merlin 3006.102.5 pages with made-up values: documentation addresses,
// locally administered MACs.

private let sysinfoPage = """
<script>
function hwaccel_state(){
var qos_enable = '0';
if (hnd_support) {
var cpu_model = "BCM4916 - B53 ARMv8&nbsp;&nbsp; (Cores: 4)";
if (cpu_model.search("BCM67") != -1)
code = "<span>Archer:</span> ";
else
code = "<span>Runner:</span> ";
var state = "Enabled";
code += state;
code += "&nbsp;&nbsp;-&nbsp;&nbsp;<span>Flow Cache:</span> ";
state = "Disabled";
code += state;
}
document.getElementById("hwaccel").innerHTML = code;
}
function show_connstate(){
document.getElementById("conn_td").innerHTML = conn_stats_arr[0] + " / 300000&nbsp;&nbsp;-&nbsp;&nbsp;" + conn_stats_arr[1] + " active";
}
nvram_total = 262144;
jffs_total = parseFloat("44.46");
var firmver = '3.0.0.6';
var buildno = '102.5';
var extendno = '0';
var rc_caps = "mssid 2.4G 5G wifi7 dualwan ipv6";
function show_wifi_version() {
var buf = "<td>";
buf += "wl0: Jun 24 2025 11:41:22 version 1.2.3 ";
if (band5g_support)
buf += "<br>wl1: Jun 24 2025 11:41:22 version 1.2.3 ";
if (wl_info.band5g_2_support || wl_info.band6g_support)
buf += "<br>None";
buf += "</td>";
document.getElementById("wifi_version_td").innerHTML = buf;
}
</script>
<th>Model</th>
<td id="model_id">RT-BE88U</td>
<tr>
<th>Firmware Build</th>
<td>Sun Aug  3 16:23:49 UTC 2025 builder@host</td>
</tr>
<tr>
<th>Bootloader</th>
<td>0.0.0.6</td>
</tr>
<tr>
<th>CPU Model</th>
<td>BCM4916 - B53 ARMv8&nbsp;&nbsp; (Cores: 4) @ 2600 MHz</td>
</tr>
"""

@Test func sysinfoPageReadsFactsWithoutRunningScripts() {
    let info = RouterParser.systemInfo(sysinfoPage)
    #expect(info.model == "RT-BE88U")
    #expect(info.firmware == "3006.102.5")
    #expect(info.firmwareBuild == "Sun Aug 3 16:23:49 UTC 2025 builder@host")
    #expect(info.bootloader == "0.0.0.6")
    #expect(info.cpuModel == "BCM4916 - B53 ARMv8 (Cores: 4) @ 2600 MHz")
    #expect(info.wirelessDrivers == ["wl0: Jun 24 2025 11:41:22 version 1.2.3", "wl1: Jun 24 2025 11:41:22 version 1.2.3"])
    #expect(info.features == ["2.4G", "5G", "dualwan", "ipv6", "mssid", "wifi7"])
    #expect(info.hardwareAcceleration == [.init(label: "Runner", value: "Enabled"), .init(label: "Flow Cache", value: "Disabled")])
    #expect(info.nvramTotalBytes == 262144)
    #expect(info.jffsTotalMB == 44.46)
    #expect(info.connectionLimit == 300000)
    #expect(info.reportsAssociated == false)
    #expect(info.jffsMounted == true)
    // An unmounted JFFS partition reports a negative size, which the page shows as not mounted; a page without
    // the figure says nothing either way.
    let unmounted = RouterParser.systemInfo(#"jffs_total = parseFloat("-1");"#)
    #expect(unmounted.jffsTotalMB == nil && unmounted.jffsMounted == false)
    #expect(RouterParser.systemInfo("<html></html>").jffsMounted == nil)
}

@Test func unmountedJFFSLeavesMemoryReadable() throws {
    let status = try RouterParser.systemStatus(sysinfo: #"mem_stats_arr = ["1000", "200", "10", "20", "0", "0", "131072", "-1", "700", "500"];"#, temperatures: nil)
    #expect(status.memory?.total == 1000 && status.memory?.available == 500)
    #expect(status.nvramUsedBytes == 131072 && status.jffsFreeMB == nil)
}

@Test func storageAndTemperatureHealthFollowThePageLines() {
    var info = RouterSystemInfo()
    info.nvramTotalBytes = 1000; info.jffsTotalMB = 40; info.jffsMounted = true
    var status = RouterSystemStatus()
    status.nvramUsedBytes = 904; status.jffsFreeMB = 20
    // 90.4 % rounds to 90, which the page does not flag; 90.6 % does.
    var check = HealthSystemAnalysis.storage(status: status, info: info)
    #expect(check.severity == .good && check.summary == "NVRAM 已用 90% · JFFS 已用 50%")
    status.nvramUsedBytes = 906
    #expect(HealthSystemAnalysis.storage(status: status, info: info).severity == .attention)
    status.nvramUsedBytes = nil
    #expect(HealthSystemAnalysis.storage(status: status, info: info).severity == .unknown)
    info.jffsMounted = false; info.jffsTotalMB = nil
    check = HealthSystemAnalysis.storage(status: status, info: info)
    #expect(check.severity == .attention && check.summary == "NVRAM 用量未返回 · JFFS 分区未挂载")

    status.cpuTemperature = 75.2
    status.radioTemperatures = [0: .celsius(59), 1: .celsius(85), 2: .disabled]
    check = HealthSystemAnalysis.temperature(status: status, radioTitles: [0: "2.4 GHz", 1: "5 GHz"])
    #expect(check.severity == .attention && check.summary == "CPU 75 °C · 2.4 GHz 59 °C · 5 GHz 85 °C")
    #expect(check.advice.hasPrefix("5 GHz 温度偏高"))
    status.radioTemperatures[1] = .celsius(70)
    #expect(HealthSystemAnalysis.temperature(status: status, radioTitles: [:]).summary == "CPU 75 °C · wl0 59 °C · wl1 70 °C")
    #expect(HealthSystemAnalysis.temperature(status: RouterSystemStatus(), radioTitles: [:]).severity == .unknown)
}

@Test func sysinfoScriptsGiveLoadMemoryClientsAndTemperatures() throws {
    let sysinfo = "\u{FEFF}" + """
    wlc_0_arr = ["0", "7", "6"];
    wlc_1_arr = ["0", "3", "3"];
    wlc_2_arr = ["0", "0", "0"];
    wlc_3_arr = ["0", "0", "0"];
    conn_stats_arr = ["1035","365"];
    mem_stats_arr = ["1999.96", "58.20", "45.30",
    "1200.53", "0.00", "0.00",
    "106237", "41.62",
    "629.73", "1290.25"];
    cpu_stats_arr = ["1.35", "1.35", "1.31"];
    """
    let coretmp = "\u{FEFF}" + """
    curr_coreTmp_wl0_raw = "59&deg;C";
    curr_coreTmp_wl0 = (curr_coreTmp_wl0_raw.indexOf("disabled") > 0 ? 0 : curr_coreTmp_wl0_raw.replace("&deg;C", ""));
    curr_coreTmp_wl1_raw = "61&deg;C";
    curr_coreTmp_wl2_raw = "<i>disabled</i>";
    curr_cpuTemp = "75.200";
    fanctrl_info = "";
    """
    let status = try RouterParser.systemStatus(sysinfo: sysinfo, temperatures: coretmp)
    #expect(status.loadAverage == [1.35, 1.35, 1.31])
    let memory = try #require(status.memory)
    #expect(memory.total == 1999.96 && memory.used == 629.73 && memory.available == 1290.25 && memory.free == 58.20)
    #expect(abs(memory.reclaimable - 1232.05) < 0.001)
    #expect(status.nvramUsedBytes == 106237 && status.jffsFreeMB == 41.62)
    #expect(status.connections == RouterSystemStatus.Connections(total: 1035, active: 365))
    #expect(status.wirelessClients[0] == RouterSystemStatus.WirelessCounts(associated: 0, authorized: 7, authenticated: 6))
    #expect(status.wirelessClients[1]?.authorized == 3)
    #expect(status.radioTemperatures == [0: .celsius(59), 1: .celsius(61), 2: .disabled])
    #expect(status.cpuTemperature == 75.2)
    #expect(status.fan == nil)
    // Temperatures are optional; a script without load or memory is not a reading.
    #expect(try RouterParser.systemStatus(sysinfo: sysinfo, temperatures: nil).radioTemperatures.isEmpty)
    #expect(throws: RouterError.self) { try RouterParser.systemStatus(sysinfo: "<html>error</html>", temperatures: coretmp) }
}

@Test func radioBandsFollowEachUnitsBand() {
    #expect(RouterRadioBands.titles(nband: [0: "2", 1: "1", 2: "", 3: ""]) == [0: "2.4 GHz", 1: "5 GHz"])
    // GT-AXE16000 style: the 2.4 GHz radio is the last unit and two radios share 5 GHz.
    #expect(RouterRadioBands.titles(nband: [0: "1", 1: "1", 2: "4", 3: "2"]) == [0: "5 GHz-1", 1: "5 GHz-2", 2: "6 GHz", 3: "2.4 GHz"])
}

@Test func dhcpLeasesKeepNamesTimesAndVLAN() throws {
    let page = """
    leasearray= [["85918", "02:00:00:00:00:01", "192.0.2.10", "*", "0"],
    ["3600", "02:00:00:00:00:0a", "192.0.2.20", "Living-Room-TV", "52"],
    []];
    """
    let leases = try RouterParser.dhcpLeases(page)
    #expect(leases.count == 2)
    #expect(leases[0] == RouterDHCPLease(mac: "02:00:00:00:00:01", ip: "192.0.2.10", hostname: nil, secondsLeft: 85918, vlan: "0"))
    #expect(leases[1].mac == "02:00:00:00:00:0A" && leases[1].hostname == "Living-Room-TV" && leases[1].vlan == "52")
    #expect(try RouterParser.dhcpLeases("leasearray= [[]];").isEmpty)
    #expect(throws: RouterError.self) { try RouterParser.dhcpLeases("<html></html>") }
}

@Test func ipv6StatusReadsConfigurationClientsAndPinholeState() throws {
    let page = """
    var pinholesarray = [[]];
    var ipv6cfgarray = [["IPv6 Connection Type","Native with DHCP-PD"],["LAN IPv6 Prefix","2001:db8:1::/64"],[]];
    var ipv6clientarray = [["laptop", "02:00:00:00:00:02", "2001:db8:1::2, fe80::2"],["*", "02:00:00:00:00:03", "2001:db8:1::3"],[]];
    function show_pinholes() {
    if ("0" == "0") {
    code += '<tr><td colspan="5">Pinhole support is currently disabled.</td></tr>';
    } else {
    """
    let status = try RouterParser.ipv6Status(page)
    #expect(status.enabled)
    #expect(status.configuration == [.init(label: "IPv6 Connection Type", value: "Native with DHCP-PD"), .init(label: "LAN IPv6 Prefix", value: "2001:db8:1::/64")])
    #expect(status.clients.map(\.addresses) == [["2001:db8:1::2", "fe80::2"], ["2001:db8:1::3"]])
    #expect(status.clients[1].hostname == nil)
    #expect(status.pinholes == nil)

    let enabled = page.replacingOccurrences(of: #"if ("0" == "0")"#, with: #"if ("1" == "0")"#)
        .replacingOccurrences(of: "var pinholesarray = [[]];", with: #"var pinholesarray = [["UDP", "2001:db8:9::1", "3478", "2001:db8:1::2", "3478", "", "Game"],[]];"#)
    #expect(try RouterParser.ipv6Status(enabled).pinholes == [.init(proto: "UDP", remoteIP: "2001:db8:9::1", remotePort: "3478", localIP: "2001:db8:1::2", localPort: "3478", description: "Game")])
    #expect(try RouterParser.ipv6Status("var ipv6cfgarray = [[]];").enabled == false)
}

@Test func portForwardStatusReadsRulesAndMappings() throws {
    let page = """
    var vserverarray = [["ALL", "", "TCP", "8443", "192.0.2.30", "443", "VSERVER"],[]];
    var upnparray = [["TCP", "41357", "192.0.2.40", "4484", "0", "NAT-PMP 4484 tcp"],
    ["UDP", "3074", "192.0.2.41", "3074", "1800", "Console"],
    []];
    """
    let status = try RouterParser.portForwardStatus(page)
    #expect(status.virtualServers == [.init(source: "ALL", proto: "TCP", portRange: "8443", redirectTo: "192.0.2.30", localPort: "443", chain: "VSERVER")])
    #expect(status.mappings.map(\.secondsLeft) == [nil, 1800])
    #expect(status.mappings[1].description == "Console")
    #expect(try RouterParser.portForwardStatus("var vserverarray = [[]];\nvar upnparray = [[]];") == RouterPortForwardStatus())
}

@Test func uiSupportReadsCapabilitiesLikeTheWeb() {
    let state = """
    function isSupport(_ptn){
    var ui_support = [{ "mssid": 1, "sdn_mwl": 6, "sdn_mainfh": 1, "ookla": 0 }
    ][0];
    """
    #expect(RouterParser.uiSupport("sdn_mainfh", in: state) == true)
    #expect(RouterParser.uiSupport("sdn_mwl", in: state) == true)
    #expect(RouterParser.uiSupport("ookla", in: state) == false)
    #expect(RouterParser.uiSupport("missing", in: state) == false)
    // A list in another form is not "unsupported" but unknown.
    #expect(RouterParser.uiSupport("sdn_mainfh", in: "var other = 1;") == nil)
}

@Test func interfaceCountersKeepEveryInterface() throws {
    let netdev = "\nnetdev = {\n 'INTERNET':{rx:0x1a2b3c4d5e,tx:0x10}\n,'WIRED':{rx:0x20,tx:0x30}\n,'BRIDGE':{rx:42,tx:7}\n,'WIRELESS0':{rx:0x0,tx:0x0}\n}\n"
    let counters = try RouterParser.interfaceCounters(netdev)
    #expect(counters.count == 4)
    #expect(counters["INTERNET"] == TrafficCounters(received: 0x1a2b3c4d5e, sent: 0x10))
    #expect(counters["BRIDGE"] == TrafficCounters(received: 42, sent: 7))
    #expect(throws: RouterError.self) { try RouterParser.interfaceCounters("netdev = {};") }
}

@Test func trafficCounterDeltasAllowForWrapButNotReset() {
    #expect(TrafficInterface.delta(from: 100, to: 250) == 150)
    #expect(TrafficInterface.delta(from: 0xFFFF_FF00, to: 0x100) == 0x200)
    #expect(TrafficInterface.delta(from: 0x1_0000_0000, to: 5) == nil)
}

@Test func trafficTabsAreNamedAndOrderedLikeTheWeb() {
    let bands = [0: "2.4 GHz", 1: "5 GHz"]
    func title(_ key: String, _ wans: [String] = ["wan", "none"]) -> String? { TrafficInterface.title(key, wanTypes: wans, lanPort: "4", radioBands: bands) }
    #expect(title("INTERNET") == "WAN")
    #expect(title("INTERNET", []) == "互联网")
    #expect(title("INTERNET", ["lan", "wan"]) == "LAN Port 4")
    #expect(title("INTERNET1", ["wan", "usb"]) == "USB Modem")
    #expect(title("WIRED") == "有线连接")
    #expect(title("BRIDGE") == nil)
    #expect(title("WIRELESS0") == "无线连接 (2.4GHz)")
    #expect(title("WIRELESS1") == "无线连接 (5GHz)")
    #expect(title("WIRELESS0.1") == nil)
    let keys = ["WIRELESS1", "BRIDGE", "WIRED", "WIRELESS0", "INTERNET"].sorted { TrafficInterface.order($0) < TrafficInterface.order($1) }
    #expect(keys == ["INTERNET", "WIRED", "WIRELESS0", "WIRELESS1", "BRIDGE"])
    #expect(TrafficInterface.isWAN("INTERNET") && !TrafficInterface.isWAN("WIRED"))
}

@Test func trafficHistoryReadsTheEmbeddedSamples() throws {
    let page = """
    if (nvram.rstats_enable != '1') return;
    try {

    speed_history = {
    'INTERNET': {
     rx: [100,200,0x10],
     rx_avg: 105,
     rx_max: 200,
     rx_total: 316,
     tx: [1,2,3],
     tx_avg: 2,
     tx_max: 3,
     tx_total: 6 },
    'WIRELESS0': {
     rx: [5],
     tx: [6]},
    _next: 28};
    }
    """
    let history = try RouterParser.trafficHistory(page)
    #expect(Set(history.keys) == ["INTERNET", "WIRELESS0"])
    #expect(history["INTERNET"]?.received == [100, 200, 16])
    #expect(history["INTERNET"]?.sentTotal == 6)
    #expect(history["INTERNET"]?.receivedPeak == 200)
    #expect(history["WIRELESS0"]?.sent == [6])
    #expect(history["WIRELESS0"]?.receivedAverage == nil)
    #expect(throws: RouterError.self) { try RouterParser.trafficHistory("speed_history = [];") }
}

@Test func trafficRecordsDecodePackedDatesNewestFirst() throws {
    let page = """
    var daily_history = [];

    daily_history = [
    [0x7e080b,0x0,0x0],[0x7e080c,0x400,0x800],[0x7e0901,0x1,0x2]];

    monthly_history = [
    [0x7e0800,0x33d647d7,0x40f69fed],[0x7e0900,0x10,0x20]];

    }
    catch (ex) {
    monthly_history = [];
    }
    """
    let records = try RouterParser.trafficRecords(page)
    #expect(records.daily.map(\.id) == [2026_10_01, 2026_09_12, 2026_09_11])
    #expect(records.daily[1] == TrafficRecord(year: 2026, month: 9, day: 12, receivedKiB: 1024, sentKiB: 2048))
    #expect(records.monthly.map(\.id) == [2026_10_00, 2026_09_00])
    #expect(records.monthly[1].receivedKiB == 0x33d647d7)
    #expect(try RouterParser.trafficRecords("daily_history = [\n];").daily.isEmpty)
}

@Test func rateWindowFollowsCountersAndBreaksAtGaps() throws {
    var window = TrafficRateWindow(capacity: 3, maximumGap: 20)
    let start = Date(timeIntervalSince1970: 0)
    window.consume(["INTERNET": TrafficCounters(received: 1_000, sent: 100)], at: 0, date: start)
    #expect(window.points.isEmpty)
    window.consume(["INTERNET": TrafficCounters(received: 3_000, sent: 300)], at: 2, date: start.addingTimeInterval(2))
    window.consume(["INTERNET": TrafficCounters(received: 9_000, sent: 700)], at: 4, date: start.addingTimeInterval(4))
    let summary = try #require(window.summary(for: "INTERNET"))
    #expect(summary.currentReceived == 3_000 && summary.currentSent == 200)
    #expect(summary.averageReceived == 2_000 && summary.peakReceived == 3_000)
    #expect(summary.totalReceived == 8_000 && summary.totalSent == 600)
    // A long pause starts a new segment and adds nothing; a counter reset gives no point.
    window.consume(["INTERNET": TrafficCounters(received: 10_000, sent: 800)], at: 60, date: start.addingTimeInterval(60))
    window.consume(["INTERNET": TrafficCounters(received: 12_000, sent: 900)], at: 62, date: start.addingTimeInterval(62))
    window.consume(["INTERNET": TrafficCounters(received: 0x1_0000_0005, sent: 0)], at: 64, date: start.addingTimeInterval(64))
    let points = try #require(window.points["INTERNET"])
    #expect(points.count == 3)
    #expect(points.map(\.segment) == [0, 0, 1])
    #expect(window.summary(for: "INTERNET")?.totalReceived == 10_000)
}

@Test func historySummaryAndPointsCoverTheChosenSpan() throws {
    let history = TrafficHistory(received: [30, 60, 90, 120], sent: [0, 0, 30, 30], receivedAverage: nil, receivedPeak: nil,
                                 receivedTotal: nil, sentAverage: nil, sentPeak: nil, sentTotal: nil)
    let all = try #require(history.summary(lastSamples: 4))
    #expect(all.totalReceived == 300 && all.peakReceived == 4 && all.averageReceived == 2.5 && all.currentSent == 1)
    #expect(history.summary(lastSamples: 2)?.totalReceived == 210)
    let end = Date(timeIntervalSince1970: 1_000)
    let points = history.points(lastSamples: 4, limit: 2, end: end)
    #expect(points.map(\.received) == [1.5, 3.5])
    #expect(points.map(\.date) == [end.addingTimeInterval(-60), end])
}
