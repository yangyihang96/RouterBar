import Foundation

/// Which ASUS router and firmware the app is talking to, read once per connection. Pages use it to decide whether
/// their native implementation applies (the native pages follow the web code of firmware 3006.102) and which
/// radios exist.
public struct RouterProfile: Sendable, Equatable, Codable {
    public enum Family: String, Sendable, Codable {
        /// Asuswrt-Merlin: build numbers like "102.5" or "388.8".
        case merlin
        /// ASUS firmware: whole build numbers like "102" or "388".
        case stock
    }
    /// The firmware code line. Each has its own web interface: 3006 brings the SDN 网络 page and MLO, 388 and 386
    /// still have the guest network page, 384 and older predate most of today's pages.
    public enum Branch: String, Sendable, Codable, CaseIterable {
        case legacy, v384, v386, v388, v3006, unknown
        public var title: String {
            switch self {
            case .legacy: "3.0.0.4.38x 以前"
            case .v384: "3.0.0.4.384"
            case .v386: "3.0.0.4.386"
            case .v388: "3.0.0.4.388"
            case .v3006: "3.0.0.6"
            case .unknown: "未知分支"
            }
        }
    }
    public enum Band: String, Sendable, Codable {
        case ghz2_4 = "2.4 GHz", ghz5 = "5 GHz", ghz6 = "6 GHz", ghz60 = "60 GHz", unknown = ""
    }
    public struct Radio: Sendable, Equatable, Codable, Identifiable {
        /// The wl unit: wl0, wl1, …
        public let unit: Int
        /// As the web names it, e.g. "5 GHz-2".
        public let title: String
        public let band: Band
        public var id: Int { unit }
        public init(unit: Int, title: String, band: Band) { self.unit = unit; self.title = title; self.band = band }
    }

    /// `productid`.
    public let model: String
    /// `odmpid`, the marketed name when the router is sold under another name.
    public let marketedModel: String?
    public let firmver: String
    public let buildno: String
    public let extendno: String
    public let radios: [Radio]
    /// `ui_support` from state.js.
    public let uiSupport: [String: Double]

    public init(model: String, marketedModel: String?, firmver: String, buildno: String, extendno: String,
                radios: [Radio], uiSupport: [String: Double]) {
        self.model = model; self.marketedModel = marketedModel?.isEmpty == true ? nil : marketedModel
        self.firmver = firmver; self.buildno = buildno; self.extendno = extendno
        self.radios = radios; self.uiSupport = uiSupport
    }

    public var displayName: String { marketedModel ?? model }
    public var family: Family { buildno.contains(".") ? .merlin : .stock }
    /// Only the lines whose source was checked (audit/firmware-branches-2.0.0), as the router's own `firmver` writes them:
    /// 3.0.0.6 build 102, and 3.0.0.4 builds 388, 386 and 384 exactly (ASUS "388", Merlin "388.8"); older 3.0.0.4 builds
    /// are `.legacy`, anything else `.unknown`.
    public var branch: Branch {
        guard let build = Int(buildno.split(separator: ".", omittingEmptySubsequences: false).first ?? "") else { return .unknown }
        switch (firmver, build) {
        case ("3.0.0.6", 102): return .v3006
        case ("3.0.0.4", 388): return .v388
        case ("3.0.0.4", 386): return .v386
        case ("3.0.0.4", 384): return .v384
        case ("3.0.0.4", let older) where older < 384: return .legacy
        default: return .unknown
        }
    }
    /// The web code the native pages were written against and checked with: 3.0.0.6.102.
    public var isReferenceFirmware: Bool { branch == .v3006 }
    /// Firmware as the web footer shows it: Merlin "3006.102.5_2", ASUS "3.0.0.6.102_34713".
    public var firmwareVersion: String {
        let ext = extendno.split(separator: "-").first.map(String.init) ?? ""
        let suffix = ext.isEmpty || ext == "0" ? "" : "_" + ext
        switch family {
        case .merlin: return firmver.replacingOccurrences(of: ".", with: "") + "." + buildno + suffix
        case .stock: return firmver + "." + buildno + suffix
        }
    }
    public func supports(_ capability: String) -> Bool { (uiSupport[capability] ?? 0) != 0 }

    /// Builds the profile from the identity nvram values and what the router's state.js computed.
    /// `nband` is `wl0_nband` … `wl3_nband`; the web's own band titles win when state.js has them.
    public static func make(nvram: [String: String], facts: RouterWebFacts?) -> RouterProfile? {
        guard let model = nvram["productid"].flatMap({ $0.isEmpty ? nil : $0 }) else { return nil }
        let nband = Dictionary(uniqueKeysWithValues: (0...3).map { ($0, nvram["wl\($0)_nband"] ?? "") })
        return RouterProfile(model: model, marketedModel: nvram["odmpid"] ?? facts?.marketedModel,
                             firmver: nvram["firmver"] ?? "", buildno: nvram["buildno"] ?? "", extendno: nvram["extendno"] ?? "",
                             radios: radios(nband: nband, facts: facts), uiSupport: facts?.uiSupport ?? [:])
    }

    static let nbandBands: [String: Band] = ["2": .ghz2_4, "1": .ghz5, "4": .ghz6, "6": .ghz60]

    /// Radios in unit order. state.js `wl_nband_title` (from `wlnband_list`) names them the way the web does;
    /// without it, `wlN_nband` does, with two radios on one band numbered "-1" and "-2" as the web numbers them.
    static func radios(nband: [Int: String], facts: RouterWebFacts?) -> [Radio] {
        if let list = facts?.bandList, !list.isEmpty {
            let titles = facts?.bandTitles ?? []
            return list.enumerated().map { unit, code in
                let band: Band = code.hasPrefix("60g") ? .ghz60 : code.hasPrefix("6g") ? .ghz6 : code.hasPrefix("5g") ? .ghz5 : code.hasPrefix("2g") ? .ghz2_4 : .unknown
                let title = unit < titles.count && !titles[unit].isEmpty ? titles[unit] : RouterRadioBands.titles(nband: nband)[unit] ?? band.rawValue
                return Radio(unit: unit, title: title, band: band)
            }
        }
        let titles = RouterRadioBands.titles(nband: nband)
        return nband.keys.sorted().compactMap { unit in
            guard let band = nbandBands[nband[unit] ?? ""], let title = titles[unit] ?? (band == .ghz60 ? band.rawValue : nil) else { return nil }
            return Radio(unit: unit, title: title, band: band)
        }
    }

    /// The nvram the profile needs, read in one request.
    public static let nvramKeys = ["productid", "odmpid", "firmver", "buildno", "extendno", "wl0_nband", "wl1_nband", "wl2_nband", "wl3_nband"]
}
