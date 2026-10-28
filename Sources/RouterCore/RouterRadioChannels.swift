import Foundation

/// RT-BE88U has exactly two Broadcom radios: wl0 (2.4 GHz) and wl1 (5 GHz).
public enum RadioBand: Int, Sendable, CaseIterable {
    case ghz24 = 0, ghz5 = 1
    public var title: String { self == .ghz24 ? "2.4 GHz" : "5 GHz" }
    /// appGet hook documented by firmware-asus.js (`httpApi.hookGet("chanspecs_" + postfix)`).
    public var hook: String { self == .ghz24 ? "chanspecs_2g" : "chanspecs_5g" }
    /// Broadcom WL_NBAND_2G = 2, WL_NBAND_5G = 1.
    var nband: String { self == .ghz24 ? "2" : "1" }
    var channels: ClosedRange<Int> { self == .ghz24 ? 1...14 : 32...177 }
}

/// Broadcom `wlN_bw` values from system.channelBandwidthObject in firmware-asus.js.
/// 4 (80+80) and 6 (240/320) are intentionally not editable here.
public enum RadioBandwidth: String, Sendable, CaseIterable, Identifiable, Comparable {
    case auto = "0", mhz20 = "1", mhz40 = "2", mhz80 = "3", mhz160 = "5"
    public var id: String { rawValue }
    public var megahertz: Int? {
        switch self { case .auto: nil; case .mhz20: 20; case .mhz40: 40; case .mhz80: 80; case .mhz160: 160 }
    }
    public var label: String { megahertz.map { "\($0) MHz" } ?? "自动" }
    public static func < (a: Self, b: Self) -> Bool { (a.megahertz ?? 0) < (b.megahertz ?? 0) }
    init?(megahertz: Int) { guard let match = Self.allCases.first(where: { $0.megahertz == megahertz }) else { return nil }; self = match }
}

/// One raw chanspec string exactly as returned by the router, e.g. `1`, `1l`, `5u`, `36`, `36l`, `36/80`, `36/160`.
public struct RadioChanspec: Sendable, Hashable, Identifiable {
    public enum Sideband: Sendable, Hashable { case lower, upper }
    public let raw: String
    public let channel: Int
    public let width: RadioBandwidth
    public let sideband: Sideband?
    public var id: String { raw }
    public var label: String {
        let base = "信道 \(channel) · \(width.label)"
        switch sideband {
        case .lower: return base + "（扩展至 \(channel + 4)）"
        case .upper: return base + "（扩展至 \(channel - 4)）"
        case nil: return base
        }
    }
}

public struct RadioChannelOption: Sendable, Hashable, Identifiable {
    public let raw: String
    public let label: String
    public var id: String { raw }
}

public struct RadioChannelSnapshot: Sendable, Equatable {
    public static let autoChanspec = "0"
    public let unit: Int
    public let band: RadioBand
    /// Raw NVRAM values; may be outside what this app can edit and are shown verbatim.
    public let bandwidth: String
    public let chanspec: String
    /// Every writable chanspec the router offered, in router order.
    public let choices: [RadioChanspec]
    /// Automatic channel selection is always offered by the firmware control-channel UI.
    public let offersAutoChannel: Bool
    /// Legal on the router but at a width this app does not write (240/320 MHz).
    public let unsupportedChanspecs: [String]

    var bandwidthKey: String { "wl\(unit)_bw" }
    var chanspecKey: String { "wl\(unit)_chanspec" }

    /// Auto plus every width that actually appears in the router's chanspec list.
    public var widths: [RadioBandwidth] { [.auto] + Set(choices.map(\.width)).sorted() }
    public func label(for width: RadioBandwidth) -> String {
        guard width == .auto else { return width.label }
        let listed = widths.compactMap(\.megahertz).map(String.init).joined(separator: "/")
        return listed.isEmpty ? "自动" : "自动（\(listed) MHz）"
    }
    /// Auto bandwidth may pair with any legal chanspec; a fixed width only with chanspecs of that width.
    public func options(for width: RadioBandwidth) -> [RadioChannelOption] {
        let auto = offersAutoChannel ? [RadioChannelOption(raw: Self.autoChanspec, label: "自动选择信道")] : []
        return auto + choices.filter { width == .auto || $0.width == width }.map { RadioChannelOption(raw: $0.raw, label: $0.label) }
    }
    public var currentBandwidthLabel: String {
        RadioBandwidth(rawValue: bandwidth).map { label(for: $0) } ?? "未识别的值 \(bandwidth.isEmpty ? "（空）" : bandwidth)"
    }
    public var currentChanspecLabel: String {
        if chanspec == Self.autoChanspec { return "自动选择信道" }
        if let match = choices.first(where: { $0.raw == chanspec }) { return match.label }
        return "\(chanspec.isEmpty ? "（空）" : chanspec)（不在路由器当前提供的列表中）"
    }

    public func validate(bandwidth: String, chanspec: String) throws {
        guard let width = RadioBandwidth(rawValue: bandwidth), widths.contains(width) else {
            throw RouterError.validation("\(band.title) 频宽：路由器当前未提供该频宽")
        }
        guard options(for: width).contains(where: { $0.raw == chanspec }) else {
            throw RouterError.validation("\(band.title) 信道：\(chanspec) 不是路由器为 \(label(for: width)) 提供的合法信道")
        }
    }
    public func replacing(bandwidth: String, chanspec: String) -> RadioChannelSnapshot {
        RadioChannelSnapshot(unit: unit, band: band, bandwidth: bandwidth, chanspec: chanspec, choices: choices, offersAutoChannel: offersAutoChannel, unsupportedChanspecs: unsupportedChanspecs)
    }
}

public struct RadioChannelChange: Sendable, Equatable {
    public let unit: Int
    public let beforeBandwidth: String
    public let beforeChanspec: String
    public let afterBandwidth: String
    public let afterChanspec: String
    public init(snapshot: RadioChannelSnapshot, bandwidth: String, chanspec: String) {
        unit = snapshot.unit; beforeBandwidth = snapshot.bandwidth; beforeChanspec = snapshot.chanspec
        afterBandwidth = bandwidth; afterChanspec = chanspec
    }
    public var isChange: Bool { beforeBandwidth != afterBandwidth || beforeChanspec != afterChanspec }
}

public struct RadioChannelReceipt: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable { case verified, mismatch, uncertain }
    public var outcome: Outcome
    public var message: String
    public var isVerified: Bool { outcome == .verified }
}

enum RadioChannelParser {
    enum Entry: Equatable { case auto, choice(RadioChanspec), unsupportedWidth(String) }

    static func entry(_ raw: String, band: RadioBand) -> Entry? {
        if raw == RadioChannelSnapshot.autoChanspec { return .auto }
        func number(_ text: Substring, digits: ClosedRange<Int>) -> Int? {
            guard digits.contains(text.count), text.first != "0", text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(text)
        }
        // Plain / lower / upper sideband: "1", "1l", "5u", "36", "36l", "40u".
        let side: RadioChanspec.Sideband? = raw.last == "l" ? .lower : raw.last == "u" ? .upper : nil
        if let channel = number(side == nil ? Substring(raw) : raw.dropLast(), digits: 1...3) {
            guard band.channels.contains(channel) else { return nil }
            guard let side else { return .choice(.init(raw: raw, channel: channel, width: .mhz20, sideband: nil)) }
            guard band.channels.contains(side == .lower ? channel + 4 : channel - 4) else { return nil }
            return .choice(.init(raw: raw, channel: channel, width: .mhz40, sideband: side))
        }
        // Explicit width: 5 GHz only ("36/80", "36/160"; "/240" and "/320" are legal but not writable here).
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
        guard band == .ghz5, parts.count == 2, let channel = number(parts[0], digits: 1...3), band.channels.contains(channel),
              let mhz = number(parts[1], digits: 2...3) else { return nil }
        if [240, 320].contains(mhz) { return .unsupportedWidth(raw) }
        guard [40, 80, 160].contains(mhz), let width = RadioBandwidth(megahertz: mhz) else { return nil }
        return .choice(.init(raw: raw, channel: channel, width: width, sideband: nil))
    }

    /// Rejects the whole list on any malformed entry: a partly understood capability list is not trusted for writes.
    static func capabilities(_ value: Any?, band: RadioBand) throws -> (choices: [RadioChanspec], auto: Bool, unsupported: [String]) {
        let invalid = RouterError.invalidResponse("\(band.title) 信道能力（\(band.hook)）")
        guard let list = value as? [Any], list.count <= 512 else { throw invalid }
        var choices: [RadioChanspec] = [], unsupported: [String] = [], seen: Set<String> = [], auto = false
        for item in list {
            let raw: String
            if let s = item as? String { raw = s.trimmingCharacters(in: .whitespaces) }
            else if let n = item as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue == Double(n.intValue) { raw = n.stringValue }
            else { throw invalid }
            guard seen.insert(raw).inserted else { continue }
            switch entry(raw, band: band) {
            case .auto: auto = true
            case .choice(let choice): choices.append(choice)
            case .unsupportedWidth(let raw): unsupported.append(raw)
            case nil: throw invalid
            }
        }
        guard !choices.isEmpty else { throw RouterError.validation("路由器未返回 \(band.title) 的可用信道，暂不允许修改。") }
        return (choices, auto, unsupported)
    }
}

extension RouterClient {
    public func readRadioChannels(unit: Int) async throws -> RadioChannelSnapshot {
        // The control follows the 3.0.0.6 page for wl0 on 2.4 GHz and wl1 on 5 GHz; other radios (6 GHz, a second
        // 5 GHz radio) use other chanspec lists and are left to the router's page.
        guard let band = RadioBand(rawValue: unit) else { throw RouterError.validation("wl\(unit) 的信道与频宽控制尚未适配，请在路由器网页中设置。") }
        let bw = "wl\(unit)_bw", chanspec = "wl\(unit)_chanspec", nband = "wl\(unit)_nband"
        let values = try await readSettings([nband, bw, chanspec] + (unit == 1 ? ["wl1_bw_160"] : []))
        guard values[nband] == band.nband else { throw RouterError.validation("无线单元 wl\(unit) 不是 \(band.title)，已停止读取信道设置。") }
        let data = try await request("appGet.cgi", query: [.init(name: "hook", value: "\(band.hook)()")])
        let parsed = try RadioChannelParser.capabilities(try RouterParser.json(data)[band.hook], band: band)
        return RadioChannelSnapshot(unit: unit, band: band, bandwidth: values[bw] ?? "", chanspec: values[chanspec] ?? "",
                                    choices: parsed.choices.filter { unit != 1 || values["wl1_bw_160"] == "1" || $0.width != .mhz160 }, offersAutoChannel: true, unsupportedChanspecs: parsed.unsupported)
    }

    /// Re-reads capabilities and current values, rejects stale or no-longer-legal requests, then submits only
    /// `wlN_bw` and `wlN_chanspec`. Once the request may have been dispatched, failures and cancellation
    /// are reported as `.uncertain` and never retried.
    public func applyRadioChannels(_ change: RadioChannelChange, settleSeconds: Double = 15) async throws -> RadioChannelReceipt {
        try acquireMutation(); defer { releaseMutation() }
        guard change.isChange else { throw RouterError.validation("信道与频宽没有变化。") }
        let fresh = try await readRadioChannels(unit: change.unit)
        guard fresh.bandwidth == change.beforeBandwidth, fresh.chanspec == change.beforeChanspec else {
            throw RouterError.validation("\(fresh.band.title) 信道设置已被其他操作改变，请重新读取后再保存。")
        }
        try fresh.validate(bandwidth: change.afterBandwidth, chanspec: change.afterChanspec)
        try Task.checkCancellation()
        let fields = ["action_mode": "apply", "rc_service": "restart_wireless",
                      fresh.bandwidthKey: change.afterBandwidth, fresh.chanspecKey: change.afterChanspec]
        let uncertain = "请求可能已送达路由器，结果尚未确认。无线服务可能正在重启，请稍后重新读取，不要重复提交。"
        do { _ = try await submitApply(fields) }
        catch RouterError.authenticationRequired { throw RouterError.authenticationRequired }
        catch RouterError.submissionUncertain(let message) { return .init(outcome: .uncertain, message: message) }
        catch is CancellationError { return .init(outcome: .uncertain, message: "保存已在发送后取消。" + uncertain) }
        catch { return .init(outcome: .uncertain, message: uncertain) }
        do {
            try await Task.sleep(for: .seconds(max(settleSeconds, 0)))
            let after = try await readSettings([fresh.bandwidthKey, fresh.chanspecKey])
            guard after[fresh.bandwidthKey] == change.afterBandwidth, after[fresh.chanspecKey] == change.afterChanspec else {
                return .init(outcome: .mismatch, message: "路由器已响应，但重新读取的频宽 / 信道（\(after[fresh.bandwidthKey] ?? "—") / \(after[fresh.chanspecKey] ?? "—")）与提交值不一致。请重新读取并检查。")
            }
            return .init(outcome: .verified, message: "已从路由器重新读取，\(fresh.band.title) 频宽与信道已确认保存。")
        } catch is CancellationError {
            return .init(outcome: .uncertain, message: "保存已在发送后取消。" + uncertain)
        } catch {
            return .init(outcome: .uncertain, message: "路由器已接收请求，正在重启无线服务。保存结果仍待重新读取确认。")
        }
    }
}
