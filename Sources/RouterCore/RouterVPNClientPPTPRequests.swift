import Foundation

// VPN › VPN 客户端 › PPTP/L2TP 的请求与读写：开关、保存、删除、“适用于所有设备”与“互联网”的应用各自组成的 httpApi.nvramSet
// 对象；打开时、每 5 秒、打开设置时与 7114 SDK 的 PPPoE 检查所读的内容；按网页发送（applyapp.cgi）并按网页的等待读回核对。
// 行号均指 VPN/vpnc.html。

// MARK: - Requests

/// One httpApi.nvramSet (js/httpApi.js 227–251): the object's members in the order the page added them (a member set again
/// keeps its place); undefined members are left out by JSON.stringify, and a number stays a number.
public struct VPNClientRequest: Sendable, Equatable {
    public struct Member: Sendable, Equatable {
        public let name: String
        public var value: OrderedJSON?
    }
    public private(set) var members: [Member] = []
    /// What the page does after sending: shows its loading for that long and reads the list again, waits for a reboot or for
    /// the 30-second restart_net_and_phy, or (适用于所有设备) checks vpnc_default_wan_tmp every 100 ms, 50 times at most.
    public enum After: Sendable, Equatable { case seconds(Double), reboot, networkRestart, defaultWAN }
    public var after: After = .seconds(1)
    /// Variables the router keeps as sent, which are read back afterwards.
    public var checks: [String] = []

    init(_ members: [(String, OrderedJSON?)]) { for (name, value) in members { set(name, value) } }
    mutating func set(_ name: String, _ value: OrderedJSON?) {
        if let at = members.firstIndex(where: { $0.name == name }) { members[at].value = value } else { members.append(Member(name: name, value: value)) }
    }
    mutating func set(_ name: String, _ text: String) { set(name, .string(text)) }

    /// The members JSON.stringify writes.
    var sent: [(String, OrderedJSON)] { members.compactMap { member in member.value.map { (member.name, $0) } } }
    /// JSON.stringify of the object, which encodeURIComponent then makes the body.
    public var json: String { OrderedJSON.object(sent).javaScriptJSON }
    public func value(_ name: String) -> String? { members.first { $0.name == name }?.value.map(TORSettings.javaScriptString) }
    public var service: String? { value("rc_service") }
    public var reboots: Bool { after == .reboot }
}

/// The check for PPPoE with NAT acceleration on routers built on the 7114 SDK (464–491, 543–571, 3023–3046): a WAN on PPPoE
/// and ctf_disable "0" make vpncoppp decide: "" or "0" asks to reboot the router with NAT acceleration forced off
/// (ctf_nonat_force=1, rc_service=reboot), "1" forces it off without the reboot.
public struct VPNClientNAT: Sendable, Equatable {
    public let reboot: Bool
    public let forceOff: Bool
    public static let none = VPNClientNAT(reboot: false, forceOff: false)
    public static let confirmation = "当您的 VPN 客户端使用 PPPoE 连接时，路由器将会自动重启，以关闭 NAT 加速。确定继续？"
}

extension VPNClientPage {
    /// The wan<i>_proto names the check reads: i from 0 while i < isSupport("wanMax") (at most 32 here).
    var natNames: [String] {
        guard supports("sdk7114") else { return [] }
        let limit: Double
        switch isSupport("wanMax") {
        case .string(let text), .number(let text): limit = javaScriptNumber(text) ?? .nan
        case .bool(let on): limit = on ? 1 : 0
        default: limit = .nan
        }
        let count = limit.isNaN ? 0 : Int(max(0, min(32, limit.rounded(.up))))
        return (0..<count).map { "wan\($0)_proto" } + ["ctf_disable", "vpncoppp"]
    }
    /// The check, with the router's answers merged in.
    public mutating func natCheck() -> VPNClientNAT {
        guard supports("sdk7114") else { return .none }
        var pppoe = false
        for name in natNames.dropLast(2) where nvramGet([name], force: true)[name] == "pppoe" { pppoe = true; break }
        guard pppoe, nvramGet(["ctf_disable"], force: true)["ctf_disable"] == "0" else { return .none }
        switch nvramGet(["vpncoppp"], force: true)["vpncoppp"] ?? "" {
        case "", "0": return VPNClientNAT(reboot: true, forceOff: true)
        case "1": return VPNClientNAT(reboot: false, forceOff: true)
        default: return .none
        }
    }

    /// The switch of a profile (390–622). Without Fusion every other profile goes off and the running client becomes this
    /// one (or "disable"); with Fusion the profile's active field changes and vpnc_unit names its place in the list. Fusion
    /// refuses a further active profile once vpnc_activate_maximum are on.
    public func switching(_ idx: Int, on: Bool, nat: VPNClientNAT = .none) -> Result<VPNClientRequest, VPNClientAlert> {
        guard writable else { return .failure(.listUnavailable) }
        guard let at = profiles.firstIndex(where: { $0.idx == idx }) else { return .failure(.stopped) }
        let profile = profiles[at]
        // `specific_data.proto.toLowerCase()` (434, 529) of undefined throws before anything is sent.
        guard let proto = profile.proto?.lowercased() else { return .failure(.stopped) }
        if fusion {
            if on, Double(profiles.filter(\.activate).count) >= activeMaximum { return .failure(VPNClientAlert(activeLimitNote)) }
            var request = VPNClientRequest([("action_mode", .string("apply")), ("rc_service", .string("restart_vpnc")), ("vpnc_unit", .string(""))])
            if on, nat.forceOff { request.set("ctf_nonat_force", "1") }
            request.set("rc_service", on ? (nat.reboot ? "reboot" : "restart_vpnc") : "stop_vpnc")
            var updated = profiles
            updated[at].activate = on
            let lists = VPNClientProfile.lists(updated, fusion: true)
            request.set("vpnc_clientlist", lists.clientlist)
            request.set("vpnc_pptp_options_x_list", lists.options)
            request.set("vpnc_unit", .number(String(profile.idx)))
            request.after = on && nat.reboot ? .reboot : .seconds(1)
            request.checks = ["vpnc_clientlist", "vpnc_pptp_options_x_list"]
            return .success(request)
        }
        var request = VPNClientRequest([("vpnc_proto", .string("disable")), ("action_mode", .string("apply")), ("rc_service", .string("restart_vpncall"))])
        let unit = profile.server ?? "undefined"
        if proto == "pptp" || proto == "l2tp" {
            request.set("vpnc_heartbeat_x", ""); request.set("vpnc_pppoe_username", ""); request.set("vpnc_pppoe_passwd", ""); request.set("vpnc_auto_conn", "1")
        } else if proto == "openvpn" || proto == "cyberghost" {
            request.set("vpn_client_unit", profile.server.map(OrderedJSON.string)); request.set("vpn_clientx_eas", "")
            request.set("vpn_client\(unit)_username", ""); request.set("vpn_client\(unit)_password", "")
        }
        if on {
            if nat.forceOff { request.set("ctf_nonat_force", "1") }
            if nat.reboot { request.set("rc_service", "reboot") }
            request.set("vpnc_proto", proto)
            if proto == "pptp" || proto == "l2tp" {
                request.set("vpnc_heartbeat_x", profile.server.map(OrderedJSON.string))
                request.set("vpnc_pppoe_username", profile.username.map(OrderedJSON.string))
                request.set("vpnc_pppoe_passwd", profile.passwd.map(OrderedJSON.string))
                if proto == "pptp" {
                    request.set("vpnc_pptp_options_x", profile.pptpOptions != "auto" && profile.pptpOptions != "" ? profile.pptpOptions.map(OrderedJSON.string) : .string(""))
                }
            } else if proto == "openvpn" || proto == "cyberghost" {
                request.set("vpn_client_unit", profile.server.map(OrderedJSON.string))
                request.set("vpn_clientx_eas", .string(unit + ","))
                request.set("vpn_client\(unit)_username", profile.username.map(OrderedJSON.string))
                request.set("vpn_client\(unit)_password", profile.passwd.map(OrderedJSON.string))
            }
        } else if proto == "pptp" {
            request.set("vpnc_pptp_options_x", "")
        }
        request.after = on && nat.reboot ? .reboot : .seconds(1)
        let sent = request.sent.map(\.0)
        request.checks = sent.filter { !["action_mode", "rc_service", "ctf_nonat_force", "vpn_client_unit"].contains($0) }
        return .success(request)
    }

    /// The switch once its NAT check has answered, on the page as it now is: refused as stale unless the page still has the
    /// basis the check started on (the web reads it synchronously within the click, 464–510).
    public func switching(_ idx: Int, on: Bool, nat: VPNClientNAT, preparedOn basis: VPNClientBasis) -> Result<VPNClientRequest, VPNClientAlert> {
        guard stillMatches(basis) else { return .failure(.stale) }
        return switching(idx, on: on, nat: nat)
    }

    /// 应用 of the settings (apply_data 2834–3187). `newIndex` is get_new_vpnc_index as apply_data reads it for a new Fusion
    /// profile; `nat` the 7114 check, which a new Fusion profile switched on at once goes through without the confirm.
    public func saving(_ editor: VPNClientEditor, newIndex: OrderedJSON? = nil, nat: VPNClientNAT = .none) -> Result<VPNClientRequest, VPNClientSaveFailure> {
        guard writable else { return .failure(.alert(.listUnavailable)) }
        var editing: Int?
        if case .profile(let idx) = editor.target { editing = profiles.firstIndex { $0.idx == idx } }
        if fusion, let editing, profiles[editing].activate { return .failure(.alert(.deactivateToEdit)) }
        let typeTitle = editor.form.type?.uppercased()
        let (form, invalid) = editor.form.validated()
        if let invalid { return .failure(.invalid(invalid)) }
        let duplicate = profiles.contains { item in
            item.server == form.server && item.username == form.username && item.passwd == form.password && item.proto == typeTitle && item.idx != editing.map { profiles[$0].idx }
        }
        if duplicate { return .failure(.alert(.duplicate)) }
        var request = VPNClientRequest([("vpnc_clientlist", .string("")), ("vpnc_pptp_options_x_list", .string("")), ("action_mode", .string("apply"))])
        var updated = profiles
        var index: OrderedJSON?
        let options = typeTitle != "PPTP" ? "auto" : editor.form.pptpOptions
        if let editing {
            updated[editing].desc = form.desc; updated[editing].proto = typeTitle; updated[editing].server = form.server
            updated[editing].username = form.username; updated[editing].passwd = form.password; updated[editing].pptpOptions = options
            index = updated[editing].vpncIndex
            if updated[editing].activate {
                // Without Fusion: the running client takes the new settings (2937–2957); `vpn_proto.toLowerCase()` of
                // undefined throws.
                guard let proto = typeTitle?.lowercased() else { return .failure(.alert(.stopped)) }
                request.set("rc_service", "restart_vpncall")
                request.set("vpnc_proto", proto)
                if proto == "pptp" || proto == "l2tp" {
                    request.set("vpnc_heartbeat_x", form.server); request.set("vpnc_pppoe_username", form.username); request.set("vpnc_pppoe_passwd", form.password)
                }
                if proto == "pptp" {
                    request.set("vpnc_pptp_options_x", editor.form.pptpOptions != "auto" && editor.form.pptpOptions != "" ? editor.form.pptpOptions.map(OrderedJSON.string) : .string(""))
                }
            }
        } else {
            var profile = VPNClientProfile(desc: form.desc, proto: typeTitle, server: form.server, username: form.username, passwd: form.password,
                                           pptpOptions: options, idx: profiles.count)
            if fusion {
                profile.activate = editor.autoEnable
                profile.vpncIndex = newIndex
            }
            index = profile.vpncIndex
            updated.append(profile)
        }
        let lists = VPNClientProfile.lists(updated, fusion: fusion)
        request.set("vpnc_clientlist", lists.clientlist)
        request.set("vpnc_pptp_options_x_list", lists.options)
        let sent = Set(request.sent.map(\.0))
        request.checks = ["vpnc_clientlist", "vpnc_pptp_options_x_list", "vpnc_proto", "vpnc_heartbeat_x", "vpnc_pppoe_username", "vpnc_pppoe_passwd",
                          "vpnc_pptp_options_x"].filter(sent.contains)
        if fusion {
            var service = ""
            var policies = editor.policies ?? VPNClientPolicies(bindings: [], rules: [], readDHCP: "", readRules: "")
            if policies.dhcpList != policies.readDHCP {
                service += "restart_net_and_phy;"
                request.set("dhcp_staticlist", policies.dhcpList)
                request.checks.append("dhcp_staticlist")
            }
            if editor.autoEnable && editing == nil {
                service += "restart_vpnc;"
                request.set("vpnc_unit", .number(String(profiles.count)))
                var cache = self.cache
                if cache.get(["vpnc_default_wan"], force: false, encoded: encoded)["vpnc_default_wan"] == "0" {
                    request.set("vpnc_default_wan_tmp", index)
                    service += "restart_default_wan;"
                }
            }
            if instantGuard, let wireless = editor.wireless {
                // 2984–3014: the VPN Wi-Fi rules are the profile's to change when there are none, or the first is its own.
                let current = policies.rules.filter(\.wireless)
                if current.isEmpty || javaScriptLooselyEqual(.string(current[0].vpncIndex), index) {
                    let text = index.map(TORSettings.javaScriptString) ?? "undefined"
                    policies.rules.removeAll(where: \.wireless)
                    let bits = Int(wireless.option ?? "") ?? 0
                    if bits & 1 != 0 { policies.rules.append(VPNClientRule(activate: "1", ip: "", vpncIndex: text, brifname: "br1")) }
                    if bits & 2 != 0 { policies.rules.append(VPNClientRule(activate: "1", ip: "", vpncIndex: text, brifname: "br2")) }
                }
            }
            if policies.ruleList != policies.readRules {
                if !service.contains("restart_vpnc") { service += "restart_vpnc_dev_policy;" }
                request.set("vpnc_dev_policy_list", policies.ruleList)
                request.set("vpnc_dev_policy_list_tmp", policies.readRules)
                request.checks.append("vpnc_dev_policy_list")
            }
            if editor.autoEnable && editing == nil, nat.forceOff {
                request.set("ctf_nonat_force", "1")
                if nat.reboot { service = "reboot" }
            }
            if !service.isEmpty { request.set("rc_service", service) }
        }
        // The loading the page shows (3111–3133), after which it reads the list again.
        let service = request.service ?? ""
        if service.contains("reboot") { request.after = .reboot }
        else if service.contains("restart_net_and_phy;") { request.after = .networkRestart }
        else if service.contains("restart_default_wan;") { request.after = .seconds(10) }
        else if service.contains("restart_vpnc;") { request.after = .seconds(3) }
        else { request.after = .seconds(0.8) }
        return .success(request)
    }

    /// 删除 (set_del_btn 3230–3277, set_del_profile 3278–3382). With Fusion an active profile is refused; deleting the
    /// default connection first sends vpnc_default_wan_tmp=0 on its own, then the lists and the rules without the profile's.
    /// Without Fusion an active profile also stops the client. `policies` are the open form's.
    public func deleting(_ idx: Int, policies: VPNClientPolicies?) -> Result<[VPNClientRequest], VPNClientAlert> {
        guard writable else { return .failure(.listUnavailable) }
        guard let at = profiles.firstIndex(where: { $0.idx == idx }) else { return .failure(.stopped) }
        let profile = profiles[at]
        if fusion, profile.activate { return .failure(.deactivateToDelete) }
        // `_data.proto.toLowerCase()` (3348) of undefined throws before anything is sent.
        guard profile.proto != nil else { return .failure(.stopped) }
        var remaining = profiles
        remaining.remove(at: at)
        var requests: [VPNClientRequest] = []
        var request = VPNClientRequest([("vpnc_clientlist", .string("")), ("vpnc_pptp_options_x_list", .string("")), ("action_mode", .string("apply"))])
        let proto = profile.proto?.lowercased()
        let unit = profile.server ?? "undefined"
        if fusion {
            var cache = self.cache
            if profile.hasIndex(cache.get(["vpnc_default_wan"], force: false, encoded: encoded)["vpnc_default_wan"]) {
                var reset = VPNClientRequest([("action_mode", .string("apply")), ("rc_service", .string("restart_default_wan")), ("vpnc_default_wan_tmp", .string("0"))])
                reset.after = .seconds(0)
                requests.append(reset)
            }
            request.set("rc_service", "restart_vpnc_dev_policy")
            var rules = policies ?? VPNClientPolicies(bindings: [], rules: [], readDHCP: "", readRules: "")
            rules.rules.removeAll { profile.hasIndex($0.vpncIndex) }
            request.set("vpnc_dev_policy_list", rules.ruleList)
            if rules.ruleList != rules.readRules { request.set("vpnc_dev_policy_list_tmp", rules.readRules) }
            request.checks = ["vpnc_dev_policy_list"]
        } else if profile.activate {
            request.set("rc_service", "restart_vpncall")
            request.set("vpnc_proto", "disable")
            if proto == "openvpn" || proto == "cyberghost" {
                request.set("vpn_clientx_eas", ""); request.set("vpn_client_unit", profile.server.map(OrderedJSON.string))
            }
            request.checks = ["vpnc_proto"]
        }
        if proto == "openvpn" || proto == "cyberghost" {
            for part in ["ca", "crt", "key", "static", "crl"] { request.set("vpn_crt_client\(unit)_\(part)", "") }
        }
        let lists = VPNClientProfile.lists(remaining, fusion: fusion)
        request.set("vpnc_clientlist", lists.clientlist)
        request.set("vpnc_pptp_options_x_list", lists.options)
        request.checks = ["vpnc_clientlist", "vpnc_pptp_options_x_list"] + request.checks
        // showLoading(3) (3362).
        request.after = .seconds(3)
        requests.append(request)
        return .success(requests)
    }

    /// 适用于所有设备 (Get_Component_Default_Connection 1526–1574): sent at once with the profile's vpnc_idx when switched
    /// on, "0" when switched off; 互联网 ("0") cannot be switched off. The page then waits for vpnc_default_wan_tmp to clear.
    public func defaultConnection(index: String?, on: Bool) -> Result<VPNClientRequest, VPNClientAlert> {
        guard writable else { return .failure(.listUnavailable) }
        if !on, index == "0" { return .failure(.keepInternetDefault) }
        var request = VPNClientRequest([("action_mode", .string("apply")), ("vpnc_default_wan_tmp", on ? index.map(OrderedJSON.string) : .string("0")),
                                        ("rc_service", .string("restart_default_wan"))])
        request.after = .defaultWAN
        return .success(request)
    }

    /// 互联网's 应用目前所有设置 (930–979): the bindings and rules when they changed, with their services (or nothing but
    /// action_mode).
    public func internetApplying(_ policies: VPNClientPolicies) -> Result<VPNClientRequest, VPNClientAlert> {
        guard writable else { return .failure(.listUnavailable) }
        var request = VPNClientRequest([("action_mode", .string("apply"))])
        var service = ""
        if policies.dhcpList != policies.readDHCP {
            service += "restart_net_and_phy;"
            request.set("dhcp_staticlist", policies.dhcpList)
            request.checks.append("dhcp_staticlist")
        }
        if policies.ruleList != policies.readRules {
            service += "restart_vpnc_dev_policy;"
            request.set("vpnc_dev_policy_list", policies.ruleList)
            request.set("vpnc_dev_policy_list_tmp", policies.readRules)
            request.checks.append("vpnc_dev_policy_list")
        }
        if !service.isEmpty { request.set("rc_service", service) }
        request.after = service.contains("restart_net_and_phy") ? .networkRestart : .seconds(0.8)
        return .success(request)
    }
}

/// Why 应用 sends nothing: an alert (show_customize_alert), or a field's hint under it.
public enum VPNClientSaveFailure: Error, Sendable, Equatable {
    case alert(VPNClientAlert)
    case invalid(VPNClientForm.Invalid)
}

extension VPNClientPage {
    /// The two lists, and what the help link and clientList read.
    static let listKeys = ["vpnc_clientlist", "vpnc_pptp_options_x_list", "preferred_lang", "productid", "lan_hwaddr", "wlnband_list"]
    /// The running PPTP/L2TP client (without Fusion, 634–661 and 2376–2455).
    static let runningKeys = ["vpnc_proto", "vpnc_pppoe_username", "vpnc_pppoe_passwd", "vpnc_heartbeat_x", "vpn_clientx_eas", "vpnc_state_t", "vpnc_sbstate_t"]
    /// Fusion: the default connection, the bindings and the device rules.
    static let fusionKeys = ["vpnc_default_wan", "dhcp_staticlist", "vpnc_dev_policy_list"]

    /// get_wl_unit_by_band's guest SSID names for 2.4 and 5 GHz from wlnband_list as nvram_char_to_ascii gave it.
    static func ssidNames(wlnband encoded: String) -> [String] {
        let bands = aspNvramText(charToAsciiBytes(encoded)).uppercased().components(separatedBy: "&#60")
        return ["2G1", "5G1"].map { band in "wl" + (bands.firstIndex(of: band).map(String.init) ?? "") + ".1_ssid" }
    }
    /// The OpenVPN state names check_profile_status reads when the running client is OpenVPN (2384–2387).
    static func openVPNKeys(_ encoded: [String: String]) -> [String] {
        func raw(_ name: String) -> String { String(decoding: charToAsciiBytes(encoded[name] ?? ""), as: UTF8.self) }
        guard ["openvpn", "cyberghost"].contains(raw("vpnc_proto")) else { return [] }
        let unit = javaScriptReplace(raw("vpn_clientx_eas"), ",", "")
        return ["vpn_client\(unit)_state", "vpn_client\(unit)_errno"]
    }
}

extension RouterClient {
    /// httpApi.hookGet (js/httpApi.js 412–437): the answer's member, undefined (nil) when it has none, "" when the request
    /// fails.
    func pageHook(_ name: String) async throws -> OrderedJSON? {
        do { return try await orderedHook(name) }
        catch RouterError.authenticationRequired { throw RouterError.authenticationRequired }
        catch is CancellationError { throw CancellationError() }
        catch { return .string("") }
    }

    /// nvram_char_to_ascii answers for names the router may not have (an odd unit makes an unreadable name, read as "").
    private func encodedValues(_ names: [String]) async throws -> [String: String] {
        let readable = Self.readableKeys(names)
        var values = try await readEncodedSettings(readable)
        for name in names where !readable.contains(name) { values[name] = "" }
        return values
    }

    /// What VPN/vpnc.html reads when it opens (initial 4174–4302, with state.js and client_function.js): ui_support as
    /// written, the two lists, the running client (without Fusion), and for Fusion the default connection, bindings, rules,
    /// WAN state, the hooks and clientList.
    public func vpnClientPage() async throws -> VPNClientPage {
        guard let support = try await orderedHook("get_ui_support"), case .object = support else { throw RouterError.invalidResponse("固件功能列表") }
        let fusion = javaScriptTruthy(support["real_vpn_fusion"])
        var encoded = try await encodedValues(VPNClientPage.listKeys + VPNClientPage.runningKeys + (fusion ? VPNClientPage.fusionKeys + VPNClientPage.wanKeys : []))
        if !fusion { encoded.merge(try await encodedValues(VPNClientPage.openVPNKeys(encoded))) { _, new in new } }
        var hooks: [String: OrderedJSON] = [:]
        if javaScriptTruthy(support["sdk7114"]) { hooks["get_default_reboot_time"] = try await pageHook("get_default_reboot_time") }
        var operationMode = "", clients: [TORSettings.ClientEntry] = []
        if fusion {
            for name in ["get_vpnc_nondef_wan_prof_list", "get_wan_unit", "get_vpnc_status"] { hooks[name] = try await pageHook(name) }
            operationMode = try await orderedHook("get_operation_mode")?.text ?? ""
            if !javaScriptTruthy(support["mtlancfg"]), javaScriptTruthy(support["ig_site2site"]) {
                encoded.merge(try await encodedValues(VPNClientPage.ssidNames(wlnband: encoded["wlnband_list"] ?? ""))) { _, new in new }
            }
            func raw(_ name: String) -> String { String(decoding: charToAsciiBytes(encoded[name] ?? ""), as: UTF8.self) }
            clients = TORSettings.clientList(current: try await optionalHook("get_clientlist"), history: try await optionalHook("get_clientlist_from_json_database"),
                                             lanMAC: raw("lan_hwaddr"), productID: raw("productid"), amas: javaScriptTruthy(support["amas"]))
        }
        return VPNClientPage(support: support, encoded: encoded, hooks: hooks, operationMode: operationMode, clients: clients)
    }

    /// check_profile_status's reads, every 5 seconds: get_vpnc_status (Fusion), or the running client's variables.
    /// `refreshingClient` after a switch without Fusion, whose interval reads the running client again first (614–617).
    public func vpnClientPoll(_ page: VPNClientPage, refreshingClient: Bool) async throws -> VPNClientPage {
        if page.fusion { return page.polled(hooks: ["get_vpnc_status": try await pageHook("get_vpnc_status")], refreshingClient: refreshingClient) }
        return page.polled(encoded: try await encodedValues(page.statusNames), refreshingClient: refreshingClient)
    }

    /// What opening a form reads again with Fusion: the bindings and rules (update_vpnc_dev_policy_list_json), the guest
    /// SSIDs, get_new_vpnc_index for a new profile (2779) and the WAN state for 互联网 (getWanInfo). Without Fusion nothing.
    public func vpnClientFormPage(_ page: VPNClientPage, new: Bool = false, internet: Bool = false) async throws -> (page: VPNClientPage, newIndex: OrderedJSON?) {
        guard page.fusion else { return (page, nil) }
        var names = VPNClientPage.fusionKeys
        if page.instantGuard { names += page.ssidNames }
        if internet { names += VPNClientPage.wanKeys }
        var hooks: [String: OrderedJSON?] = [:]
        if internet { hooks["get_wan_unit"] = try await pageHook("get_wan_unit") }
        let newIndex = new ? try await pageHook("get_new_vpnc_index") : nil
        return (page.merging(encoded: try await encodedValues(names), hooks: hooks), newIndex)
    }

    /// apply_data's own read of get_new_vpnc_index for a new Fusion profile (2911).
    public func vpnClientNewIndex() async throws -> OrderedJSON? { try await pageHook("get_new_vpnc_index") }

    /// The 7114 SDK check (464–491, 3023–3046): wan<i>_proto, ctf_disable and vpncoppp read again.
    public func vpnClientNAT(_ page: VPNClientPage) async throws -> (page: VPNClientPage, nat: VPNClientNAT) {
        let names = page.natNames
        guard !names.isEmpty else { return (page, .none) }
        var merged = page.merging(encoded: try await encodedValues(names))
        let nat = merged.natCheck()
        return (merged, nat)
    }

    /// The requests in turn as the page sends them (each sent whatever the one before answered), then what the page waits
    /// for, then the variables read back. A reboot is only reported as sent.
    public func submitVPNClient(_ requests: [VPNClientRequest]) async throws -> ApplyReceipt {
        try acquireMutation(); defer { releaseMutation() }
        var uncertainty: String?
        for (number, request) in requests.enumerated() {
            do {
                try await submitApply(members: request.sent)
            } catch is CancellationError {
                throw CancellationError()
            } catch RouterError.submissionUncertain(let reason) {
                uncertainty = reason
            } catch let error where number < requests.count - 1 {
                uncertainty = "前一个请求没有完成（\(error.localizedDescription)），网页仍会接着发送下一个；设置可能只写入了一部分。请重新读取确认。"
            }
        }
        guard let last = requests.last else { return ApplyReceipt(verified: [], unverified: [], message: "") }
        let checked = requests.flatMap(\.checks)
        switch last.after {
        case .reboot:
            return ApplyReceipt(verified: [], unverified: checked, message: uncertainty ?? "路由器已接收设置并开始重新启动，恢复连接后才能读取确认。")
        case .networkRestart:
            // showLoading(30), after which the page waits for the router to answer again (3120–3156, 963–971).
            try await Task.sleep(for: .seconds(30))
        case .defaultWAN:
            // vpnc_default_wan_tmp every 100 ms until it is empty, 50 times at most (1549–1569). Its clearing is only when the
            // page reads the list again; the default connection itself is vpnc_default_wan (3395), which must now be the one
            // asked for.
            var cleared = false
            for _ in 0..<50 {
                try await Task.sleep(for: .milliseconds(100))
                if try await tolerantValue("vpnc_default_wan_tmp") == "" { cleared = true; break }
            }
            if let uncertainty { return ApplyReceipt(verified: [], unverified: ["vpnc_default_wan"], message: uncertainty) }
            guard cleared else {
                return ApplyReceipt(verified: [], unverified: ["vpnc_default_wan"], message: "路由器已接收请求，但 5 秒内 vpnc_default_wan_tmp 没有清空，默认连接可能尚未更改。请重新读取确认。")
            }
            guard let target = last.value("vpnc_default_wan_tmp") else {
                return ApplyReceipt(verified: [], unverified: ["vpnc_default_wan"], message: "请求里没有 vpnc_default_wan_tmp（这个配置文件没有 vpnc_idx），无法核对默认连接。请重新读取并检查。")
            }
            switch try await tolerantValue("vpnc_default_wan") {
            case target?:
                return ApplyReceipt(verified: ["vpnc_default_wan"], unverified: [], message: "已从路由器重新读取：默认连接（vpnc_default_wan）已是 \(target)。")
            case let other?:
                return ApplyReceipt(verified: [], unverified: ["vpnc_default_wan"], message: "vpnc_default_wan_tmp 已清空，但读回的默认连接（vpnc_default_wan）是 \(other)，不是 \(target)。请重新读取并检查。")
            case nil:
                return ApplyReceipt(verified: [], unverified: ["vpnc_default_wan"], message: "vpnc_default_wan_tmp 已清空，但没有读到 vpnc_default_wan，默认连接尚未核对。请重新读取并检查。")
            }
        case .seconds(let seconds):
            if seconds > 0 { try await Task.sleep(for: .seconds(seconds)) }
        }
        if let uncertainty { return ApplyReceipt(verified: [], unverified: checked, message: uncertainty) }
        do {
            return try await checkVPNClient(requests)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ApplyReceipt(verified: [], unverified: checked, message: "路由器已接收请求，正在重启相关服务。结果仍待重新读取确认。")
        }
    }

    /// One variable read again, nil when the read fails (httpApi.nvramGet then answers ""); leaving the page still cancels.
    private func tolerantValue(_ name: String) async throws -> String? {
        do { return try await readSettings([name])[name] }
        catch is CancellationError { throw CancellationError() }
        catch { return nil }
    }

    /// The variables the requests set and the router keeps, read back and compared with what was sent.
    public func checkVPNClient(_ requests: [VPNClientRequest]) async throws -> ApplyReceipt {
        var expected: [String: String] = [:]
        for request in requests { for name in request.checks { expected[name] = request.value(name) ?? "" } }
        guard !expected.isEmpty else { return ApplyReceipt(verified: [], unverified: [], message: "路由器已接收请求。") }
        let names = expected.keys.sorted()
        let after = try await readSettings(names)
        let unverified = names.filter { after[$0] != expected[$0] }
        return ApplyReceipt(verified: names.filter { !unverified.contains($0) }, unverified: unverified,
                            message: unverified.isEmpty ? "已从路由器重新读取，\(names.count) 项设置与提交的一致。"
                                : "路由器已响应，但读回的 " + unverified.joined(separator: "、") + " 与提交的不一致。请重新读取并检查。")
    }
}
