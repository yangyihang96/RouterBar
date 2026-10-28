import Foundation

/// The router web page's own rules for a router-mode LAN change (Advanced_LAN_Content.asp, DHCP page).
/// Saving only lan_ipaddr would leave the DHCP pool and the router-mode copies in the old subnet.
enum LANAddressRules {
    static let contextKeys = ["sw_mode", "lan_hostname", "lan_ipaddr", "lan_netmask", "wan0_ipaddr", "wan0_netmask",
                              "subnet_rl", "subnet_rulelist_ext", "http_enable", "le_enable"]

    /// The extra fields the web page submits together with these LAN changes.
    static func dependentFields(changes: [String: String], context: [String: String], support: [String: String]) throws -> [String: String] {
        let oldIP = context["lan_ipaddr"] ?? "", oldMask = context["lan_netmask"] ?? ""
        let newIP = changes["lan_ipaddr"] ?? oldIP, newMask = changes["lan_netmask"] ?? oldMask
        let addressChanged = newIP != oldIP || newMask != oldMask
        var extra: [String: String] = [:]
        if addressChanged {
            guard context["sw_mode"] == "1" else { throw RouterError.validation("路由器当前不是无线路由器模式，局域网地址请在路由器网页中修改。") }
            guard support["tagged_based_vlan"] != "1", (context["subnet_rulelist_ext"] ?? "").isEmpty else {
                throw RouterError.validation("这台路由器按 VLAN 子网规则管理局域网，请在路由器网页中修改地址，以便同时更新这些规则。")
            }
            guard let ip = SDNPlanner.ip(newIP), let mask = SDNPlanner.ip(newMask), SDNPlanner.validMask(mask) else {
                throw RouterError.validation("请输入有效的 IP 地址和连续的子网掩码。")
            }
            let network = ip & mask, broadcast = network | ~mask
            guard ip != network, ip != broadcast, broadcast - network >= 3 else { throw RouterError.validation("IP 地址不能是网络地址或广播地址，子网也需要留出 DHCP 地址。") }
            if let wan = SDNPlanner.ip(context["wan0_ipaddr"] ?? ""), wan != 0, let wanMask = SDNPlanner.ip(context["wan0_netmask"] ?? ""),
               SDNPlanner.validMask(wanMask), (wan & (mask & wanMask)) == (ip & (mask & wanMask)) {
                throw RouterError.validation("新的局域网与 WAN 地址 \(context["wan0_ipaddr"] ?? "") 位于同一网段，会导致无法上网。")
            }
            for row in try LosslessRuleTable(context["subnet_rl"] ?? "", minimumColumns: 4).rows {
                // The page refuses a guest-network gateway address; an overlapping guest subnet breaks routing just the same.
                // A row that carries the current LAN address is the main network itself.
                guard row[2] != oldIP else { continue }
                var conflict = row[2] == newIP
                if let other = SDNPlanner.ip(row[2]), let otherMask = SDNPlanner.ip(row[3]), SDNPlanner.validMask(otherMask) {
                    conflict = conflict || (other & mask & otherMask) == (ip & mask & otherMask)
                }
                if conflict { throw RouterError.validation("新的局域网与访客或自定义网络 \(row[2]) 的网段重叠，请换一个地址。") }
            }
            extra["lan_ipaddr_rt"] = newIP; extra["lan_netmask_rt"] = newMask
            // calculatorIPPoolRange: network + 1 moves on by one whenever it is not above the router's address, which it
            // never is, so the pool is network + 2 to broadcast − 1 wherever the router sits. The page would also save
            // a pool that holds nothing but the router's own address (a /30 with the router last); that leaves clients
            // without an address, so it is refused here.
            let start = network + 2, end = broadcast - 1
            if start == end, end == ip { throw RouterError.validation("按这个地址和子网掩码，DHCP 地址池只剩路由器自己的地址，设备将无法取得地址。请换一个地址或更大的子网。") }
            extra["dhcp_start"] = SDNPlanner.address(start); extra["dhcp_end"] = SDNPlanner.address(end)
        }
        // The router's self-signed HTTPS certificate names the host and address, so the page asks for a new one.
        let hostname = changes["lan_hostname"] ?? context["lan_hostname"] ?? ""
        if addressChanged || hostname != context["lan_hostname"], context["http_enable"] != "0", context["le_enable"] == "0" { extra["https_crt_gen"] = "1" }
        return extra
    }

    /// A DHCP pool has to stay inside the LAN subnet, away from its network and broadcast addresses.
    static func validatePool(start: String, end: String, lanIP: String, mask: String) throws {
        guard let ip = SDNPlanner.ip(lanIP), let mask = SDNPlanner.ip(mask), SDNPlanner.validMask(mask) else { throw RouterError.validation("无法确认当前局域网地址，已停止保存。") }
        let network = ip & mask, broadcast = network | ~mask
        guard let first = SDNPlanner.ip(start), let last = SDNPlanner.ip(end), first <= last,
              first > network, last < broadcast, first & mask == network, last & mask == network else {
            throw RouterError.validation("DHCP 地址池需位于局域网 \(SDNPlanner.address(network))/\(mask.nonzeroBitCount) 内，且起始地址不大于结束地址。")
        }
    }
}
