import Foundation
import Testing
@testable import RouterCore

// 1.13：外部网络 › IPv6 › 第二 WAN（Advanced_IPv61_Content.asp）。期望值（各联机类型显示的行、提示文字与要回到的栏位、表单
// 字段与顺序）取自在 Node 中用最小 DOM 运行该页自己的脚本（连同 validator.js、state.js 的 inputCtrl、general.js 的 inet_network）
// 得到的结果。

// MARK: - A router for this page

/// Answers appGet (nvram_char_to_ascii from `nvram`, get_ui_support from `support`), update_IPv6state.asp from `nvram`, and
/// start_apply.htm like httpd's validate_apply: it keeps the router variables the form sends (not the page's own controls,
/// nor `ignoring`) and answers done_committing, or no_changes_and_no_committing when none differs. `afterApply` stands for
/// what restart_net then sets itself.
private actor IPv61Router: RouterTransport {
    var nvram: [String: String]
    let support: [String: Any]
    let ignoring: Set<String>
    let afterApply: [String: String]
    private(set) var requests: [(method: String, path: String, body: String)] = []

    init(nvram: [String: String], support: [String: Any] = ["ipv6pt": 1], ignoring: Set<String> = [], afterApply: [String: String] = [:]) {
        self.nvram = nvram; self.support = support; self.ignoring = ignoring; self.afterApply = afterApply
    }

    static func isRouterVariable(_ name: String) -> Bool {
        let pageOwn: Set = ["ipv61_ifdev_select", "ipv61_prefix_span_for_start", "ipv61_dhcp_start_start", "ipv61_prefix_span_for_end", "ipv61_dhcp_end_end"]
        return (name.hasPrefix("ipv61_") && !pageOwn.contains(name)) || ["wan_unit", "preferred_lang"].contains(name)
    }

    func send(_ request: URLRequest) async throws -> RouterHTTPResponse {
        guard let url = request.url else { throw RouterError.network("no url") }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let path = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        requests.append((request.httpMethod ?? "GET", path, body))
        switch path {
        case "appGet.cgi":
            let hook = items.first { $0.name == "hook" }?.value ?? ""
            if hook == "get_ui_support()" { return try Self.reply(["get_ui_support": support]) }
            var object: [String: String] = [:]
            for call in hook.split(separator: ";") {
                guard let open = call.firstIndex(of: "("), let comma = call.firstIndex(of: ",") else { continue }
                let key = String(call[call.index(after: open)..<comma])
                if let value = nvram[key] { object[key] = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) }
            }
            return try Self.reply(object)
        case "start_apply.htm":
            var modified = false
            for (key, value) in decodeForm(body) where Self.isRouterVariable(key) && !ignoring.contains(key) && nvram[key] != value {
                nvram[key] = value; modified = true
            }
            if modified { nvram.merge(afterApply) { _, set in set } }
            let reply = modified ? "<script>done_committing();</script>\n<script>restart_needed_time(30);</script>" : "<script>no_changes_and_no_committing();</script>"
            return RouterHTTPResponse(data: Data(("<html><script>function no_changes_and_no_committing(){}</script>" + reply).utf8), status: 200)
        case "update_IPv6state.asp":
            let script = "\u{FEFF}state_ipv6_prefix = \"\";\nstate_ipv61_prefix = \"\(nvram["ipv61_prefix"] ?? "")\";\n"
                + "state_ipv61_prefix_length = \"\(nvram["ipv61_prefix_length"] ?? "")\";\nstate_ipv61_rtr_addr =\t\"\(nvram["ipv61_rtr_addr"] ?? "")\";\n"
            return RouterHTTPResponse(data: Data(script.utf8), status: 200)
        default:
            return RouterHTTPResponse(data: Data(), status: 404)
        }
    }
    nonisolated func cancel() {}
    static func reply(_ object: Any) throws -> RouterHTTPResponse { RouterHTTPResponse(data: try JSONSerialization.data(withJSONObject: object), status: 200) }
    var posts: [(method: String, path: String, body: String)] { requests.filter { $0.method == "POST" } }
}

private func decodeForm(_ body: String) -> [(String, String)] {
    body.split(separator: "&").map { pair in
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map {
            String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
        }
        return (parts[0], parts.count > 1 ? parts[1] : "")
    }
}
private func client(_ router: IPv61Router) throws -> RouterClient { RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: router, writes: .reference) }

/// The router defaults (shared/defaults.c 4349–4392) and a second WAN on LAN port 4.
private let defaults = ["wan1_proto": "dhcp", "wan1_ipaddr": "100.64.10.20", "ipv6_unit": "1", "enable_ftp": "0", "wans_dualwan": "wan lan", "wans_lanport": "4",
    "productid": "RT-BE88U", "preferred_lang": "CN", "firmver": "3.0.0.6", "wan_unit": "0", "ipv61_service": "disabled", "ipv61_ifdev": "ppp",
    "ipv61_dhcp_pd": "1", "ipv61_accept_defrtr": "1", "ipv61_tun_v4end": "0.0.0.0", "ipv61_relay": "192.88.99.1", "ipv61_6rd_dhcp": "1",
    "ipv61_6rd_prefix": "", "ipv61_6rd_prefixlen": "32", "ipv61_6rd_router": "0.0.0.0", "ipv61_6rd_ip4size": "0", "ipv61_tun_addr": "",
    "ipv61_tun_addrlen": "64", "ipv61_tun_peer": "", "ipv61_tun_mtu": "0", "ipv61_tun_ttl": "255", "ipv61_ipaddr": "", "ipv61_prefix_len_wan": "64",
    "ipv61_gateway": "", "ipv61_rtr_addr": "", "ipv61_prefix_length": "64", "ipv61_prefix": "", "ipv61_autoconf_type": "0", "ipv61_dhcp_start": "",
    "ipv61_dhcp_end": "", "ipv61_dhcp_lifetime": "86400", "ipv61_dnsenable": "1", "ipv61_dns1": "", "ipv61_dns2": "", "ipv61_dns3": "",
    "ipv61_radvd": "1", "ipv61_prefix_length_s": "64", "ipv61_rtr_addr_s": "", "ipv61_prefix_s": ""]
private let staticStateful = ["ipv61_service": "other", "ipv61_ipaddr": "2001:db8:ffff::2", "ipv61_gateway": "2001:db8:ffff::1", "ipv61_rtr_addr": "2001:db8:1::1",
    "ipv61_prefix": "2001:db8:1::", "ipv61_autoconf_type": "1", "ipv61_dhcp_start": "2001:db8:1::1000", "ipv61_dhcp_end": "2001:db8:1::2000", "ipv61_dhcp_pd": "0"]
private let native = ["ipv61_service": "dhcp6", "ipv61_rtr_addr": "2001:db8:5:1::1", "ipv61_prefix": "2001:db8:5:1::"]
private func values(_ overrides: [String: String]...) -> [String: String] { overrides.reduce(defaults) { $0.merging($1) { _, new in new } } }
private func form(_ overrides: [String: String]..., passthrough: Bool = true) -> IPv61Form {
    IPv61Page(values: overrides.reduce(defaults) { $0.merging($1) { _, new in new } }, passthrough: passthrough).form
}
private func visible(_ form: IPv61Form) -> [String] {
    IPv61Form.layout.flatMap(\.rows).filter { form.isShown($0) }.map { $0.id.replacingOccurrences(of: "ipv61_", with: "") }
}
private func submitted(_ form: inout IPv61Form) -> IPv61Form.Submission? { if case .success(let submission) = form.apply() { submission } else { nil } }
private func stop(_ form: inout IPv61Form) -> IPv61Form.Stop? { if case .failure(let stop) = form.apply() { stop } else { nil } }
/// The request body start_apply.htm receives for a submission.
private func body(_ submission: IPv61Form.Submission) -> String {
    String(decoding: RouterAuthentication.orderedForm(submission.fields, .formSubmission), as: UTF8.self)
}

// MARK: - Showing and enabling

@Test func eachConnectionTypeShowsTheWebPagesRows() {
    // showInputfield / showInputfield2 (81–572): the rows shown, as the page's own script leaves them.
    #expect(visible(form()) == ["wan_selection", "service"])
    #expect(visible(form(native)) == ["wan_selection", "service", "dhcp_pd", "prefix_len_wan", "ipaddr_r", "prefix_length_r", "prefix_r", "autoconf_type",
                                      "dnsenable", "_radvd"])
    #expect(visible(form(native, ["ipv61_dhcp_pd": "0", "ipv61_autoconf_type": "1"])) == ["wan_selection", "service", "dhcp_pd", "rtr_addr", "prefix_length",
        "prefix_r", "autoconf_type", "dhcp_start_start", "dhcp_end_end", "dhcp_lifetime", "dnsenable", "_radvd"])
    #expect(visible(form(staticStateful)) == ["wan_selection", "service", "ipaddr", "prefix_len_wan", "gateway", "rtr_addr", "prefix_length", "prefix_r",
        "autoconf_type", "dhcp_start_start", "dhcp_end_end", "dhcp_lifetime", "dns1", "dns2", "dns3", "_radvd"])
    #expect(visible(form(["ipv61_service": "ipv6pt", "wan1_proto": "pppoe", "ipv61_dnsenable": "0"])) == ["wan_selection", "service", "ifdev_select", "dnsenable",
                                                                                                           "dns1", "dns2", "dns3"])
    #expect(visible(form(["ipv61_service": "flets"])) == ["wan_selection", "service", "dnsenable"])
    #expect(visible(form(["ipv61_service": "6to4"])) == ["wan_selection", "service", "relay", "tun_mtu", "tun_ttl", "ipaddr_r", "prefix_length_r", "prefix_r",
                                                          "dns1", "dns2", "dns3", "_radvd"])
    #expect(visible(form(["ipv61_service": "6in4"])) == ["wan_selection", "service", "tun_v4end", "tun_addr", "tun_addrlen", "tun_peer", "tun_mtu", "tun_ttl",
                                                          "ipaddr_r", "prefix_length", "prefix", "dns1", "dns2", "dns3", "_radvd"])
    #expect(visible(form(["ipv61_service": "6rd"])) == ["wan_selection", "service", "6rd_dhcp", "tun_mtu", "tun_ttl", "ipaddr_r", "prefix_length_r", "prefix_r",
                                                         "dns1", "dns2", "dns3", "_radvd"])
    #expect(visible(form(["ipv61_service": "6rd", "ipv61_6rd_dhcp": "0"])) == ["wan_selection", "service", "6rd_dhcp", "6rd_prefix", "6rd_prefixlen", "6rd_router",
        "6rd_ip4size", "tun_mtu", "tun_ttl", "ipaddr_r", "prefix_length_r", "prefix_r", "dns1", "dns2", "dns3", "_radvd"])
    // The spans: the page's own values, 6to4's prefix from the WAN address (calcIP6), DHCP-PD's prefix from the LAN address.
    #expect(form(["ipv61_service": "6to4"]).text(.prefix) == "2002:6440:0a14::" && form(["ipv61_service": "6to4"]).text(.prefixLength) == "48")
    #expect(form(native).text(.prefix) == "2001:db8:5:1::" && form(native).text(.prefixLength) == "" && form(native).text(.ipaddr) == "2001:db8:5:1::1")
}

@Test func disabledControlsAreNotSentAndHiddenEnabledOnesAre() throws {
    // Native without DHCP-PD hides the WAN table but leaves its prefix length enabled (showInputfield2 489–505), so the page
    // sends it; the tunnel fields it disabled are not sent.
    var withoutPD = form(native, ["ipv61_dhcp_pd": "0"])
    #expect(!withoutPD.isShown(.wan) && !withoutPD.control("ipv61_prefix_len_wan").disabled && withoutPD.control("ipv61_tun_mtu").disabled)
    let fields = try #require(submitted(&withoutPD)).fields.map(\.0)
    #expect(fields.contains("ipv61_prefix_len_wan") && !fields.contains("ipv61_tun_mtu") && !fields.contains("ipv61_dns1"))
    // Choosing the interface: Accept Default Route shows only for Native over PPP (567–571).
    var ppp = form(native, ["wan1_proto": "pppoe"])
    #expect(!ppp.control("_ipv61_accept_defrtr").disabled)
    ppp.chooseInterface("eth")
    #expect(ppp.control("_ipv61_accept_defrtr").disabled && ppp.value("ipv61_ifdev_select") == "eth")
}

@Test func optionsFollowSupportAndTheSavedType() {
    // Without ipv6pt support Passthrough and FLET'S go; a saved ipv6pt then shows as the first option and the fields as disabled.
    let unsupported = form(["ipv61_service": "ipv6pt"], passthrough: false)
    #expect(unsupported.control("ipv61_service").options.map(\.value) == ["disabled", "dhcp6", "other", "6to4", "6in4", "6rd"])
    #expect(unsupported.value("ipv61_service") == "disabled" && !unsupported.updatesState && visible(unsupported) == ["wan_selection", "service"])
    #expect(form().control("ipv61_service").options.map(\.label) == ["关闭", "Native", "静态 IPv6", "Passthrough", "FLET'S IPv6 service", "Tunnel 6to4",
                                                                     "Tunnel 6in4", "Tunnel 6rd"])
    // static6 is the legacy name of other (63–66).
    let legacy = form(staticStateful, ["ipv61_service": "static6"])
    #expect(legacy.value("ipv61_service") == "other" && legacy.protoOrig == "other" && legacy.updatesState)
    // genWANSoption (933–961): USB left out (its index stays a blank option), LAN named by its port, parseInt(ipv6_unit).
    #expect(form().control("wan_selection").options == [.init(value: "0", label: "WAN"), .init(value: "1", label: "LAN Port 4")])
    let usbFirst = form(["wans_dualwan": "usb wan"]).control("wan_selection")
    #expect(usbFirst.options == [.init(value: "", label: ""), .init(value: "1", label: "WAN")] && usbFirst.selected == 1)
    #expect(form(["wans_dualwan": "wan usb"]).control("wan_selection").selected == nil)
    #expect(form(["ipv6_unit": ""]).control("wan_selection").selected == 0)
}

@Test func typingKeepsToMaxLengthAndTheLeaseTakesDigits() {
    var sixrd = form(["ipv61_service": "6rd", "ipv61_6rd_dhcp": "0"])
    sixrd.type("ipv61_6rd_ip4size", "123")
    #expect(sixrd.value("ipv61_6rd_ip4size") == "12")
    var stateful = form(staticStateful)
    // isNumber filters a typed key, also over a selection; pasted text stays for validForm, cut to maxlength 6.
    let lease = stateful.value("ipv61_dhcp_lifetime")
    stateful.type("ipv61_dhcp_lifetime", lease + "a", key: "a")
    #expect(stateful.value("ipv61_dhcp_lifetime") == lease)
    stateful.type("ipv61_dhcp_lifetime", "3600s", key: nil)
    #expect(stateful.value("ipv61_dhcp_lifetime") == "3600s")
    stateful.type("ipv61_dhcp_lifetime", "12a3456", key: nil)
    #expect(stateful.value("ipv61_dhcp_lifetime") == "12a345")
    // A disabled field takes nothing.
    stateful.type("ipv61_tun_mtu", "1400")
    #expect(stateful.value("ipv61_tun_mtu") == "0")
}

// MARK: - validForm

@Test func validFormStopsWhereThePageStops() {
    func alert(_ form: IPv61Form, _ edits: [(String, String)] = []) -> IPv61Form.Stop? {
        var form = form
        for (name, value) in edits { form.set(name, value) }
        return stop(&form)
    }
    // Stateful autoconfiguration takes 16 bits: the LAN prefix length stops at 112 (695–699, 725–729); Stateless allows 126.
    #expect(alert(form(staticStateful), [("ipv61_prefix_length", "113")]) == .init(alert: "请输入一数值介于 3 至 112", field: "ipv61_prefix_length"))
    #expect(alert(form(staticStateful, ["ipv61_autoconf_type": "0"]), [("ipv61_prefix_length", "113")]) == nil)
    #expect(alert(form(native, ["ipv61_dhcp_pd": "0", "ipv61_autoconf_type": "1"]), [("ipv61_prefix_length", "113")])?.alert == "请输入一数值介于 3 至 112")
    #expect(alert(form(native, ["ipv61_dhcp_pd": "0"]), [("ipv61_prefix_length", "126")]) == nil)
    // 6rd: the prefix length stops at 126 − (32 − IPv4 mask length) (789–797); a mask length range rewrote to "x10" leaves NaN.
    let sixrd = ["ipv61_service": "6rd", "ipv61_6rd_dhcp": "0", "ipv61_6rd_router": "198.51.100.1", "ipv61_6rd_prefix": "2001:db8::"]
    #expect(alert(form(sixrd, ["ipv61_6rd_prefixlen": "100"])) == .init(alert: "请输入一数值介于 3 至 94", field: "ipv61_6rd_prefixlen"))
    #expect(alert(form(sixrd, ["ipv61_6rd_prefixlen": "98", "ipv61_6rd_ip4size": "08"])) == nil)
    #expect(alert(form(sixrd, ["ipv61_6rd_prefixlen": "200", "ipv61_6rd_ip4size": "0x10"])) == nil)
    // Static mode needs its WAN address; an empty one stops at its alert.
    #expect(alert(form(staticStateful), [("ipv61_ipaddr", "")]) == .init(alert: " 不是有效的 IP 地址！", field: "ipv61_ipaddr"))
    #expect(alert(form(staticStateful), [("ipv61_gateway", "fe80::1::2")]) == .init(alert: "fe80::1::2 不是有效的 IP 地址！", field: "ipv61_gateway"))
    var switched = form(native)
    switched.chooseService("other")
    #expect(stop(&switched) == .init(alert: " 不是有效的 IP 地址！", field: "ipv61_ipaddr"))
    var tunnel = form()
    tunnel.chooseService("6in4")
    #expect(stop(&tunnel) == .init(alert: " 不是有效的 IP 地址！", field: "ipv61_tun_addr"))
    // The Stateful pool (704–720): hex parts, start not above end, then the lease time.
    let pool = values(native, ["ipv61_dhcp_pd": "0", "ipv61_autoconf_type": "1", "ipv61_dhcp_start": "2001:db8:5:1::2000", "ipv61_dhcp_end": "2001:db8:5:1::1000"])
    #expect(alert(IPv61Page(values: pool, passthrough: true).form) == .init(alert: "此设置值须高于 2000", field: "ipv61_dhcp_end_end"))
    #expect(alert(form(native, ["ipv61_autoconf_type": "1"]), [("ipv61_dhcp_start_start", "12345")]) == .init(alert: "12345 不是有效的 IP 地址！", field: "ipv61_dhcp_start_start"))
    #expect(alert(form(native, ["ipv61_autoconf_type": "1"]), [("ipv61_dhcp_lifetime", "100")]) == .init(alert: "请输入一数值介于 120 至 604800", field: "ipv61_dhcp_lifetime"))
    // A saved pool without "::" gives the start field "undefined" (535–536).
    #expect(alert(form(native, ["ipv61_autoconf_type": "1", "ipv61_dhcp_start": "1000", "ipv61_dhcp_end": "2000"]))?.alert == "undefined 不是有效的 IP 地址！")
    // Manual DNS servers are checked only when filled.
    #expect(alert(form(native, ["ipv61_dnsenable": "0"]), [("ipv61_dns2", "2001:db8::zz")]) == .init(alert: "2001:db8::zz 不是有效的 IP 地址！", field: "ipv61_dns2"))
}

@Test func validFormRewritesAndClearsLikeThePage() {
    // range and rangeAllowZero write the accepted value without leading zeros; valid_IP writes the relay without them.
    var tunnel = form(["ipv61_service": "6to4", "ipv61_relay": "192.088.099.001", "ipv61_tun_mtu": "01400", "ipv61_tun_ttl": "0"])
    let sent = submitted(&tunnel)
    #expect(tunnel.value("ipv61_relay") == "192.88.99.1" && tunnel.value("ipv61_tun_mtu") == "1400" && tunnel.value("ipv61_tun_ttl") == "0")
    #expect(sent?.fields.first { $0.0 == "ipv61_relay" }?.1 == "192.88.99.1")
    var rewritten = form(sixrdManual(ip4size: "08", length: "98"))
    _ = submitted(&rewritten)
    #expect(rewritten.value("ipv61_6rd_ip4size") == "8")
    // A refused relay or endpoint is cleared; a refused MTU or TTL gets its default back (the alert ends in ".").
    var loopback = form(["ipv61_service": "6to4", "ipv61_relay": "127.0.0.1"])
    #expect(stop(&loopback) == .init(alert: "127.0.0.1 不是有效的 IP 地址！", field: "ipv61_relay") && loopback.value("ipv61_relay") == "")
    var endpoint = form(["ipv61_service": "6in4", "ipv61_tun_v4end": "203.0.113.256", "ipv61_tun_addr": "2001:db8:c::2"])
    #expect(stop(&endpoint)?.field == "ipv61_tun_v4end" && endpoint.value("ipv61_tun_v4end") == "")
    var mtu = form(["ipv61_service": "6to4", "ipv61_tun_mtu": "1500"])
    #expect(stop(&mtu) == .init(alert: "请输入一数值介于 1280 至 1480.", field: "ipv61_tun_mtu") && mtu.value("ipv61_tun_mtu") == "0")
    var ttl = form(["ipv61_service": "6to4", "ipv61_tun_ttl": "300"])
    #expect(stop(&ttl)?.alert == "请输入一数值介于 0 至 255." && ttl.value("ipv61_tun_ttl") == "255")
}
private func sixrdManual(ip4size: String, length: String) -> [String: String] {
    ["ipv61_service": "6rd", "ipv61_6rd_dhcp": "0", "ipv61_6rd_router": "198.51.100.1", "ipv61_6rd_prefix": "2001:db8::", "ipv61_6rd_ip4size": ip4size,
     "ipv61_6rd_prefixlen": length]
}

@Test func validatorsMatchValidatorJS() {
    // isLegal_ipv6 (848–862) as JavaScript runs it: "::" alone fails, a trailing line break fails, only ASCII digits count.
    for (address, legal) in [("::", false), ("::1", true), ("1::", true), ("1:2:3:4:5:6:7:8", true), ("1:2:3:4:5:6:7", false), ("::ffff:192.168.1.1", true),
                             ("::ffff:192.168.1.256", false), ("::1.2.3.04", true), ("::001.2.3.4", false), ("2001:db8::1\n", false), ("::١", false),
                             ("1:2:3:4:5:6:7:8::", false), ("fe80::1%eth0", false)] {
        #expect((WebValidator.isLegalIPv6(address) == nil) == legal, "\(address)")
    }
    var empty = "", star = "10.*.0.1", long = "99999999999999999999.1.1.1"
    #expect(WebValidator.ipRange(&empty) == nil && WebValidator.ipRange(&star) == nil && WebValidator.ipRange(&long) != nil && long == "")
    var unlimited = "500"
    #expect(WebValidator.range(&unlimited, 3, .nan) == nil)
    var blank = ""
    #expect(WebValidator.rangeAllowZero(&blank, 1280, 1480, default: "0") == nil && blank == "")
}

// MARK: - The address pool

@Test func theAddressPoolIsRebuiltLikeThePage() throws {
    // Static, Stateful: the pool keeps the saved host parts and takes the LAN address's prefix once the field is left (1207, 524–541).
    var moved = form(staticStateful)
    #expect(moved.value("ipv61_prefix_span_for_start") == "2001:db8:1" && moved.value("ipv61_dhcp_start_start") == "1000")
    moved.type("ipv61_rtr_addr", "2001:db8:2::1")
    #expect(moved.value("ipv61_prefix_span_for_start") == "2001:db8:1")
    moved.blurLANAddress()
    let sent = Dictionary(try #require(submitted(&moved)).fields, uniquingKeysWith: { first, _ in first })
    #expect(sent["ipv61_dhcp_start"] == "2001:db8:2::1000" && sent["ipv61_dhcp_end"] == "2001:db8:2::2000")
    #expect(sent["ipv61_rtr_addr_s"] == "2001:db8:2::1" && sent["ipv61_prefix_length_s"] == "64")
    // Native with DHCP-PD: the prefix comes from the LAN address update_IPv6state.asp reports, once Stateful is clicked again.
    var delegated = form(native, ["ipv61_autoconf_type": "1", "ipv61_dhcp_start": "2001:db8:5:1::1000", "ipv61_dhcp_end": "2001:db8:5:1::1fff"])
    delegated.showInfo(IPv61State(prefix: "2001:db8:9:1::", prefixLength: "64", rtrAddr: "2001:db8:9:1::1"))
    #expect(delegated.text(.ipaddr) == "2001:db8:9:1::1" && delegated.value("ipv61_prefix_span_for_start") == "2001:db8:5:1")
    delegated.click("ipv61_autoconf_type", 1)
    #expect(delegated.value("ipv61_prefix_span_for_start") == "2001:db8:9:1")
    // Static → Native → Static: the pool prefix is taken before the LAN address is put back, so it is empty (387–404).
    var roundTrip = form(staticStateful)
    roundTrip.chooseService("dhcp6"); roundTrip.chooseService("other")
    #expect(Dictionary(try #require(submitted(&roundTrip)).fields, uniquingKeysWith: { first, _ in first })["ipv61_dhcp_start"] == "::1000")
    // GetIPv6_split (624–648) and calcIP6 (662–681).
    #expect(IPv61Form.getIPv6Split("2001:db8:1:2:3::1") == "2001:db8:1:2" && IPv61Form.getIPv6Split("2001:db8::1") == "2001:db8")
    #expect(IPv61Form.getIPv6Split("2001:db8") == "2001:db8:undefined:undefined" && IPv61Form.getIPv6Split("::1") == "" && IPv61Form.getIPv6Split("x") == "")
    #expect(IPv61Form.calcIP6("100.64.10.20") == "6440:0a14" && IPv61Form.calcIP6("") == "NaNNaN:NaNNaN" && IPv61Form.calcIP6("-1.2.3.4") == "0-102:0304")
}

// MARK: - The request

@Test func secondWANIPv6PageReadsWhatTheWebPageReads() async throws {
    let router = IPv61Router(nvram: values(native))
    let page = try await client(router).ipv61Page()
    #expect(page.passthrough && page.values["ipv61_service"] == "dhcp6" && Set(page.values.keys) == Set(IPv61Page.keys))
    #expect(try await client(router).ipv61State() == IPv61State(prefix: "2001:db8:5:1::", prefixLength: "64", rtrAddr: "2001:db8:5:1::1"))
    #expect(try await client(IPv61Router(nvram: values(), support: [:])).ipv61Page().passthrough == false)
    #expect(await router.requests.allSatisfy { $0.method == "GET" })
}

@Test func staticAndNativeSendTheWebPagesForm() async throws {
    // Static, Stateful, with a new LAN address: fields and order as the page's form submits them.
    var staticForm = form(staticStateful)
    staticForm.type("ipv61_rtr_addr", "2001:db8:2::1"); staticForm.blurLANAddress()
    let router = IPv61Router(nvram: values(staticStateful))
    let staticPage = IPv61Page(values: values(staticStateful), passthrough: true)
    let receipt = try await client(router).submitIPv61(try #require(submitted(&staticForm)), page: staticPage, waiting: .zero)
    #expect(await router.posts.map(\.path) == ["start_apply.htm"])
    let staticBody: String = "productid=RT-BE88U&current_page=Advanced_IPv61_Content.asp&next_page=Advanced_IPv61_Content.asp&group_id=&modified=0"
        + "&action_mode=apply_new&action_script=restart_net&action_wait=30&preferred_lang=CN&firmver=3.0.0.6&wan_unit=0&ipv61_ifdev=ppp"
        + "&ipv61_dhcp_start=2001%3Adb8%3A2%3A%3A1000&ipv61_dhcp_end=2001%3Adb8%3A2%3A%3A2000&ipv61_prefix_length_s=64&ipv61_rtr_addr_s=2001%3Adb8%3A2%3A%3A1"
        + "&ipv61_prefix_s=&ipv61_radvd=1&wan_selection=1&ipv61_service=other&ipv61_ipaddr=2001%3Adb8%3Affff%3A%3A2&ipv61_prefix_len_wan=64"
        + "&ipv61_gateway=2001%3Adb8%3Affff%3A%3A1&ipv61_rtr_addr=2001%3Adb8%3A2%3A%3A1&ipv61_prefix_length=64&ipv61_autoconf_type=1"
        + "&ipv61_prefix_span_for_start=2001%3Adb8%3A2&ipv61_dhcp_start_start=1000&ipv61_prefix_span_for_end=2001%3Adb8%3A2&ipv61_dhcp_end_end=2000"
        + "&ipv61_dhcp_lifetime=86400&ipv61_dns1=&ipv61_dns2=&ipv61_dns3=&_ipv61_radvd=1"
    #expect(await router.posts[0].body == staticBody)
    // Read back: what changed and what applyRule fills, in form order.
    #expect(receipt.isVerified && receipt.verified == ["wan_unit", "ipv61_ifdev", "ipv61_dhcp_start", "ipv61_dhcp_end", "ipv61_prefix_length_s",
                                                       "ipv61_rtr_addr_s", "ipv61_prefix_s", "ipv61_radvd", "ipv61_rtr_addr"])

    // Native over PPPoE with DHCP-PD, Stateful, the pool prefix from the reported LAN address.
    let nativeValues = values(native, ["wan1_proto": "pppoe", "ipv61_autoconf_type": "1", "ipv61_dhcp_start": "2001:db8:5:1::1000",
                                       "ipv61_dhcp_end": "2001:db8:5:1::1fff"])
    var nativeForm = IPv61Page(values: nativeValues, passthrough: true).form
    nativeForm.showInfo(IPv61State(prefix: "2001:db8:9:1::", prefixLength: "64", rtrAddr: "2001:db8:9:1::1"))
    nativeForm.click("ipv61_autoconf_type", 1)
    let nativeRouter = IPv61Router(nvram: nativeValues)
    _ = try await client(nativeRouter).submitIPv61(try #require(submitted(&nativeForm)), page: IPv61Page(values: nativeValues, passthrough: true), waiting: .zero)
    let nativeBody: String = "productid=RT-BE88U&current_page=Advanced_IPv61_Content.asp&next_page=Advanced_IPv61_Content.asp"
        + "&group_id=&modified=0&action_mode=apply_new&action_script=restart_net&action_wait=30&preferred_lang=CN&firmver=3.0.0.6&wan_unit=0&ipv61_ifdev=ppp"
        + "&ipv61_dhcp_start=2001%3Adb8%3A9%3A1%3A%3A1000&ipv61_dhcp_end=2001%3Adb8%3A9%3A1%3A%3A1fff&ipv61_prefix_length_s=&ipv61_rtr_addr_s=&ipv61_prefix_s="
        + "&ipv61_radvd=1&ipv61_accept_defrtr=1&wan_selection=1&ipv61_service=dhcp6&ipv61_ifdev_select=ppp&ipv61_dhcp_pd=1&_ipv61_accept_defrtr=1"
        + "&ipv61_prefix_len_wan=64&ipv61_autoconf_type=1&ipv61_prefix_span_for_start=2001%3Adb8%3A9%3A1&ipv61_dhcp_start_start=1000"
        + "&ipv61_prefix_span_for_end=2001%3Adb8%3A9%3A1&ipv61_dhcp_end_end=1fff&ipv61_dhcp_lifetime=86400&ipv61_dnsenable=1&_ipv61_radvd=1"
    #expect(await nativeRouter.posts[0].body == nativeBody)
}

@Test func tunnelsAndFletsSendTheWebPagesForm() throws {
    var sixin4 = form(["ipv61_service": "6in4", "ipv61_tun_v4end": "203.0.113.1", "ipv61_tun_addr": "2001:db8:c::2", "ipv61_prefix": "2001:db8:d::",
                       "ipv61_prefix_length": "48", "ipv61_rtr_addr": "2001:db8:d::1"])
    let tunnel: String = "productid=RT-BE88U"
        + "&current_page=Advanced_IPv61_Content.asp&next_page=Advanced_IPv61_Content.asp&group_id=&modified=0&action_mode=apply_new&action_script=restart_net"
        + "&action_wait=30&preferred_lang=CN&firmver=3.0.0.6&wan_unit=0&ipv61_ifdev=ppp&ipv61_prefix_length_s=48&ipv61_rtr_addr_s=&ipv61_prefix_s=2001%3Adb8%3Ad%3A%3A"
        + "&ipv61_radvd=1&wan_selection=1&ipv61_service=6in4&ipv61_tun_v4end=203.0.113.1&ipv61_tun_addr=2001%3Adb8%3Ac%3A%3A2&ipv61_tun_addrlen=64&ipv61_tun_peer="
        + "&ipv61_tun_mtu=0&ipv61_tun_ttl=255&ipv61_prefix_length=48&ipv61_prefix=2001%3Adb8%3Ad%3A%3A&ipv61_prefix_span_for_start=&ipv61_prefix_span_for_end="
        + "&ipv61_dns1=&ipv61_dns2=&ipv61_dns3=&_ipv61_radvd=1"
    #expect(body(try #require(submitted(&sixin4))) == tunnel)
    // FLET'S: applyRule enables the interface select (so it is sent too) and sets ipv61_ifdev to eth; the LAN address goes empty.
    var flets = form(["ipv61_service": "flets", "ipv61_dhcp_pd": "0"])
    let fletsBody: String = "productid=RT-BE88U"
        + "&current_page=Advanced_IPv61_Content.asp&next_page=Advanced_IPv61_Content.asp&group_id=&modified=0&action_mode=apply_new&action_script=restart_net"
        + "&action_wait=30&preferred_lang=CN&firmver=3.0.0.6&wan_unit=0&ipv61_ifdev=eth&ipv61_prefix_length_s=&ipv61_rtr_addr_s=&ipv61_prefix_s=&ipv61_radvd=1"
        + "&wan_selection=1&ipv61_service=flets&ipv61_ifdev_select=ppp&ipv61_rtr_addr=&ipv61_prefix_span_for_start=&ipv61_prefix_span_for_end="
        + "&ipv61_dnsenable=1&_ipv61_radvd=1"
    #expect(body(try #require(submitted(&flets))) == fletsBody)
    // FTP on adds restart_ftpd (872–874); an unknown Router Advertisement value sends ipv61_radvd 0 and no radio.
    var ftp = form(staticStateful, ["enable_ftp": "1"])
    #expect(try #require(submitted(&ftp)).script == "restart_net;restart_ftpd")
    var radvd = form(["ipv61_radvd": ""])
    let fields = try #require(submitted(&radvd)).fields
    #expect(fields.first { $0.0 == "ipv61_radvd" }?.1 == "0" && !fields.contains { $0.0 == "_ipv61_radvd" })
}

@Test func readBackLeavesWhatRestartNetSetsAndReportsMismatches() async throws {
    // Disabled → Native without DHCP-PD: ipv61_prefix goes empty in the form but restart_net sets it, so it is not read back.
    let saved = values(["ipv61_prefix": "2001:db8:5:1::", "ipv61_rtr_addr": "2001:db8:5:1::1"])
    var switched = IPv61Page(values: saved, passthrough: true).form
    switched.chooseService("dhcp6"); switched.click("ipv61_dhcp_pd", 1)
    switched.type("ipv61_rtr_addr", "2001:db8:7::1"); switched.type("ipv61_prefix_length", "56"); switched.blurLANAddress()
    let submission = try #require(submitted(&switched))
    #expect(submission.changes(from: saved).map(\.key).contains("ipv61_prefix") && submission.setByRouter(original: saved) == ["ipv61_prefix"])
    let router = IPv61Router(nvram: saved, afterApply: ["ipv61_prefix": "2001:db8:7::"])
    let receipt = try await client(router).submitIPv61(submission, page: IPv61Page(values: saved, passthrough: true), waiting: .zero)
    #expect(receipt.isVerified && !receipt.verified.contains("ipv61_prefix") && receipt.verified.contains("ipv61_rtr_addr") && receipt.message.contains("不核对"))
    // In modes where restart_net sets the LAN address and prefix length as well, those are left out too.
    #expect(try #require(submitted(&switched)).setByRouter(original: values(native)) == ["ipv61_prefix"])
    var delegated = form(native)
    #expect(try #require(submitted(&delegated)).setByRouter(original: values(native)) == ["ipv61_prefix", "ipv61_prefix_length", "ipv61_rtr_addr"])
    // A variable the router did not keep is reported.
    var moved = form(staticStateful)
    moved.type("ipv61_rtr_addr", "2001:db8:2::1"); moved.blurLANAddress()
    let refusing = IPv61Router(nvram: values(staticStateful), ignoring: ["ipv61_dhcp_start"])
    let mismatch = try await client(refusing).submitIPv61(try #require(submitted(&moved)), page: IPv61Page(values: values(staticStateful), passthrough: true),
                                                          waiting: .zero)
    #expect(mismatch.unverified == ["ipv61_dhcp_start"] && mismatch.message.hasPrefix("路由器已响应，但部分设置与提交值不一致"))
}

@Test func anUnchangedFormIsAnsweredWithoutARestart() async throws {
    // Disabled, with the _s copies as an earlier save left them: nothing differs, httpd answers no_changes_and_no_committing.
    let saved = values(["ipv61_prefix_length_s": ""])
    var unchanged = IPv61Page(values: saved, passthrough: true).form
    let submission = try #require(submitted(&unchanged))
    #expect(submission.changes(from: saved).isEmpty)
    // The default _s copy (64) is cleared by the page's form, which is a change.
    #expect(submission.changes(from: values()).map(\.key) == ["ipv61_prefix_length_s"])
    let receipt = try await client(IPv61Router(nvram: saved)).submitIPv61(submission, page: IPv61Page(values: saved, passthrough: true), waiting: .seconds(60))
    #expect(receipt.isVerified && receipt.message.hasPrefix("路由器回应没有需要保存的变更，没有重新启动网络。"))
}

// MARK: - Menu and catalog

@Test func theSecondWANIPv6IsANativePage() {
    #expect(WebMenuCatalog.location(of: .ipv6SecondWAN) == WebLocation(menu: "menu_IPv6", page: "Advanced_IPv6_Content.asp", part: "ipv6-2"))
    let part = WebMenuCatalog.menu("menu_IPv6")?.page("Advanced_IPv6_Content.asp")?.parts.first { $0.id == "ipv6-2" }
    #expect(part?.condition == .dualWAN && part?.url == "Advanced_IPv61_Content.asp")
    // The generic settings section is gone; the first WAN's ipv6 section stays.
    #expect(!SettingsCatalog.sections.contains { $0.id == "ipv61" || $0.fields.contains { $0.key.hasPrefix("ipv61_") } })
    #expect(SettingsCatalog.sections.first { $0.id == "ipv6" }?.source == "Advanced_IPv6_Content.asp")
}
