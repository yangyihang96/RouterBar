import Foundation
import Testing
@testable import RouterCore

/// The menu evaluation against other firmware lines' own web code (Asuswrt-Merlin source: main, 3006.102-wifi6, 3004.388,
/// 386_x, 384.14_x). The sources are not in the repository; point ROUTERBAR_FIRMWARE_SOURCES at a folder with
/// `<branch>/www/state.js` and `<branch>/www/require/...` to run it. httpd fills the `<% %>` and `<# #>` tags before it
/// serves the scripts; here they are filled with plain sample values.
@Test func menusEvaluateOnEveryFirmwareLine() async throws {
    guard let root = ProcessInfo.processInfo.environment["ROUTERBAR_FIRMWARE_SOURCES"] else { return }
    let base = URL(fileURLWithPath: root, isDirectory: true)
    let branches: [(String, [String])] = [
        ("main", ["www/require/menuTrees/menuTree.js"]),
        ("3006.102-wifi6", ["www/require/menuTrees/menuTree.js"]),
        ("3004.388", ["www/require/menuTrees/menuTree_bwdpi_traffic_analyzer.js", "www/require/modules/menuTree.js"]),
        ("386_x", ["www/require/menuTrees/menuTree_bwdpi_traffic_analyzer.js", "www/require/modules/menuTree.js"]),
        ("384.14_x", ["www/require/menuTrees/menuTree_bwdpi_no_traffic_analyzer.js", "www/require/modules/menuTree.js"])
    ]
    for (branch, candidates) in branches {
        let folder = base.appendingPathComponent(branch)
        guard let template = try? String(contentsOf: folder.appendingPathComponent("www/state.js"), encoding: .utf8),
              let treePath = candidates.first(where: { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }),
              let tree = try? String(contentsOf: folder.appendingPathComponent(treePath), encoding: .utf8) else {
            Issue.record("\(branch): sources missing"); continue
        }
        let result = try RouterMenuEvaluator.run(state: served(template), menuTree: served(tree))
        let visible = result.menus.filter { $0.visible && !$0.isGroupHeading }
        print("\(branch) (\(treePath)): \(result.menus.count) menus, \(visible.count) shown, \(visible.flatMap { $0.tabs.filter(\.visible) }.count) pages; notes: \(result.notes)")
        #expect(visible.count >= 10, "\(branch)")
        #expect(visible.contains { $0.index == "menu_Index" }, "\(branch)")
        #expect(visible.contains { $0.index == "menu_Wireless" }, "\(branch)")
        #expect(result.facts.model == "RT-TEST", "\(branch)")
    }
}

/// What httpd would serve: tags filled, nvram empty except a few, a router in router mode with common capabilities.
private func served(_ template: String) -> String {
    let support = #"{"mssid":1,"2.4G":1,"5G":1,"usbX":1,"vpnc":1,"openvpnd":1,"pptpd":1,"ipv6":1,"dualwan":1,"amas":1,"amasRouter":1,"bwdpi":1,"ookla":1,"wireguard":1,"nwtool":1,"PARENTAL2":1,"switchctrl":1,"dnsfilter":1,"update":1}"#
    let nvram = ["productid": "RT-TEST", "sw_mode": "1", "wl_unit": "0", "wans_dualwan": "wan none", "preferred_lang": "EN",
                 "wlnband_list": "2g1&#605g1", "wl0_nband": "2", "wl1_nband": "1", "wl_ifnames": "eth6 eth7"]
    var text = template
    // get_operation_mode writes a quoted word ("rt"); most other tags outside a string write a JavaScript array.
    for (pattern, replacement) in [(#"<%\s*get_ui_support\(\);?\s*%>"#, support), (#"<%\s*get_operation_mode\(\);?\s*%>"#, "'rt'")] {
        text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
    // nvram_get("key") inside a string becomes the value; any other tag inside a string is empty, and outside one [].
    let tag = try! NSRegularExpression(pattern: #"(['"`]?)<%\s*(.*?)\s*%>"#, options: [.dotMatchesLineSeparators])
    var out = "", last = text.startIndex
    for match in tag.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        guard let whole = Range(match.range, in: text), let quoteRange = Range(match.range(at: 1), in: text), let body = Range(match.range(at: 2), in: text) else { continue }
        out += text[last..<whole.lowerBound]
        let quote = String(text[quoteRange]), call = String(text[body])
        var value = quote.isEmpty ? "[]" : ""
        if let key = call.firstMatch(of: /nvram_get\("([A-Za-z0-9_]+)"\)/)?.1 { value = nvram[String(key)] ?? (quote.isEmpty ? "''" : "") }
        out += quote + value
        last = whole.upperBound
    }
    out += text[last...]
    return out.replacingOccurrences(of: #"<#([A-Za-z0-9_]+)#>"#, with: "$1", options: .regularExpression)
}
