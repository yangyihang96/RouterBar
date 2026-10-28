import Foundation

/// The validator.js (3006.102.5) checks the 1.13 pages call, with what they do to the field: range and numberRange
/// rewrite a value they accept (leading zeros dropped, "" made "0"), and the page then submits the rewritten value.
/// Each check returns nil when it accepts, otherwise the text of the alert the page shows.
public enum WebValidator {
    /// validator.range (1727–1755): `isNaN(v) || v < min || v > max` on the text, then str2val. A comparison with NaN is
    /// false, so a bound the page computes as NaN does not limit (the alert then names it NaN).
    static func range(_ value: inout String, _ minimum: Double, _ maximum: Double) -> String? {
        let (low, high) = minimum > maximum ? (maximum, minimum) : (minimum, maximum)
        guard let number = javaScriptNumber(value), !(number < low), !(number > high) else {
            return "请输入一数值介于 " + javaScriptText(low) + " 至 " + javaScriptText(high)
        }
        value = str2val(value)
        if value.isEmpty { value = "0" }
        return nil
    }

    /// validator.rangeAllowZero (1807–1830): a value equal to 0 as a number ("" and " " too) passes as it is; otherwise
    /// range's check without swapping the bounds, whose alert ends in "." and puts the default back; then str2val.
    static func rangeAllowZero(_ value: inout String, _ minimum: Double, _ maximum: Double, default fallback: String) -> String? {
        if javaScriptNumber(value) == 0 { return nil }
        guard let number = javaScriptNumber(value), !(number < minimum), !(number > maximum) else {
            value = fallback
            return "请输入一数值介于 " + javaScriptText(minimum) + " 至 " + javaScriptText(maximum) + "."
        }
        value = str2val(value)
        if value.isEmpty { value = "0" }
        return nil
    }

    /// str2val (validator.js 1728–1735): the text without its leading "0" characters.
    static func str2val(_ text: String) -> String { String(String.UnicodeScalarView(text.unicodeScalars.drop { $0 == "0" })) }

    /// validator.ipRange (1449–1495) with v "" (no netmask defaults): an empty value passes; otherwise digits, or "*" for a
    /// whole part, four parts of at most 255 between dots. A bad value is cleared.
    static func ipRange(_ value: inout String) -> String? {
        if value.isEmpty { return nil }
        var number = -1, position = 0
        func bad() -> String { let alert = value + " 不是有效的 IP 地址！"; value = ""; return alert }
        for unit in value.utf16 {
            if (0x30...0x39).contains(unit) {
                number = number == -1 ? Int(unit - 0x30) : min(number, 1_000) * 10 + Int(unit - 0x30)
            } else if unit == 0x2A, number == -1 {
                number = 0
            } else {
                if number < 0 || number > 255 || unit != 0x2E { return bad() }
                number = -1; position += 1
            }
        }
        if position != 3 || number < 0 || number > 255 { return bad() }
        return nil
    }

    /// validator.isLegal_ipv6 (848–862): the page's pattern, with ASCII digits for \d and the end of the text for $ (as
    /// in JavaScript); the alert leaves the value as it is.
    static func isLegalIPv6(_ value: String) -> String? {
        value.range(of: legalIPv6, options: .regularExpression) != nil ? nil : value + " 不是有效的 IP 地址！"
    }
    static let legalIPv6: String = {
        let hex = "[0-9A-Fa-f]{1,4}", octet = #"(\b((25[0-5])|(1[0-9]{2})|(2[0-4][0-9])|([0-9]{1,2}))\b)"#
        let v4 = #"(\#(octet)\.){3}\#(octet)"#
        let forms = ["((\(hex):){7}\(hex))", "((\(hex):){6}:\(hex))", "((\(hex):){5}:(\(hex):)?\(hex))", "((\(hex):){4}:(\(hex):){0,2}\(hex))",
                     "((\(hex):){3}:(\(hex):){0,3}\(hex))", "((\(hex):){2}:(\(hex):){0,4}\(hex))", "((\(hex):){6}\(v4))",
                     "((\(hex):){0,5}:\(v4))", "(::(\(hex):){0,5}\(v4))", "(\(hex)::(\(hex):){0,5}\(hex))", "(::(\(hex):){0,6}\(hex))",
                     "((\(hex):){1,7}:)"]
        return "^(" + forms.joined(separator: "|") + #")\z"#
    }()

    /// validator.numberRange (1579–1606): "a:b" with one to five ASCII digits each must rise and have both ends in range
    /// (eachPort 281–292, whose alert names the end as typed) and stays as it is; anything else goes to range.
    static func numberRange(_ value: inout String, _ minimum: Double, _ maximum: Double) -> String? {
        let parts = value.unicodeScalars.split(separator: ":", omittingEmptySubsequences: false)
        let digits = { (part: Substring.UnicodeScalarView.SubSequence) in (1...5).contains(part.count) && part.allSatisfy { (0x30...0x39).contains($0.value) } }
        guard parts.count == 2, digits(parts[0]), digits(parts[1]) else { return range(&value, minimum, maximum) }
        let ends = parts.map { String(String.UnicodeScalarView($0)) }
        let first = Double(ends[0]) ?? 0, second = Double(ends[1]) ?? 0
        if first >= second { return "不是有效的通信端口编号。" }
        for (end, number) in zip(ends, [first, second]) where number < minimum || number > maximum {
            return end + " 不是有效的通信端口编号。"
        }
        return nil
    }

    /// validator.inet_network (984–1000): the address as a number, -1 for an empty value, -2 for anything that is not four
    /// decimal parts below 256.
    static func inetNetwork(_ text: String) -> Double {
        if text.isEmpty { return -1 }
        let parts = text.unicodeScalars.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { (0x30...0x39).contains($0.value) } }) else { return -2 }
        let numbers = parts.map { Double(String(String.UnicodeScalarView($0))) ?? .infinity }
        guard numbers.allSatisfy({ $0 < 256 }) else { return -2 }
        return numbers.reduce(0) { $0 * 256 + $1 }
    }

    /// The text a browser leaves after an edit that made `old` into `new` in a field. `typed` is the character of the key
    /// press that made it, nil for pasting, dropping or deleting, which a page's onKeyPress does not see. A typed key goes
    /// through `keyPress`, which gets the field's whole value and refuses the key (nil) or returns the value as the script
    /// left it: with something added at its end the script set the value, so the caret is at its end and the character
    /// goes in there. maxLength works as a browser's maxlength: what an edit inserts is cut to the room the rest of the
    /// text leaves (nothing for a typed character without room, nor for the script's addition), and what it replaced goes
    /// all the same. `replaced` is the part of `old` (UTF-16 offsets) the edit replaced, as the text field reported it;
    /// without it, or when `new` does not keep the rest of `old` around it, the edit is taken to be one replacement between
    /// what is the same at both ends, which repeated text can place wrongly.
    public static func edit(_ old: String, _ new: String, typed: Character?, maxLength: Int? = nil,
                            replaced: Range<Int>? = nil, keyPress: ((String, Character) -> String?)? = nil) -> String {
        guard let typed else {
            guard let maxLength else { return new }
            let before = Array(old.utf16), after = Array(new.utf16)
            var head = 0, tail = 0
            if let replaced, let kept = kept(replaced, from: before, to: after) {
                (head, tail) = kept
            } else {
                guard after.count > maxLength, after.count > before.count else { return new }
                while head < before.count, before[head] == after[head] { head += 1 }
                while tail < before.count - head, before[before.count - 1 - tail] == after[after.count - 1 - tail] { tail += 1 }
            }
            let room = max(0, maxLength - (head + tail))
            guard after.count - head - tail > room else { return new }
            let inserted = after[head..<(after.count - tail)].prefix(room)
            return String(decoding: Array(before[..<head]) + inserted + Array(before[(before.count - tail)...]), as: UTF16.self)
        }
        guard let start = keyPress.map({ $0(old, typed) }) ?? old else { return old }
        if start != old {
            if let maxLength, start.utf16.count >= maxLength { return start }
            return start + String(typed)
        }
        if let maxLength, new.utf16.count > maxLength {
            let before = Array(old.utf16)
            guard let replaced, let kept = kept(replaced, from: before, to: Array(new.utf16)) else { return old }
            return String(decoding: Array(before[..<kept.head]) + Array(before[(before.count - kept.tail)...]), as: UTF16.self)
        }
        return new
    }

    /// How much of `old` stays before and after an edit that replaced `replaced` (UTF-16 offsets into `old`), when `new`
    /// keeps those parts of `old` around what went in.
    private static func kept(_ replaced: Range<Int>, from old: [UInt16], to new: [UInt16]) -> (head: Int, tail: Int)? {
        guard replaced.lowerBound >= 0, replaced.upperBound <= old.count else { return nil }
        let head = replaced.lowerBound, tail = old.count - replaced.upperBound
        guard head + tail <= new.count, old[..<head] == new[..<head], old[(old.count - tail)...] == new[(new.count - tail)...] else { return nil }
        return (head, tail)
    }

    /// validator.isNumber (510–530) on key press: digits only.
    public static func numberKeyPress(_ value: String, _ key: Character) -> String? {
        ("0"..."9").contains(key) ? value : nil
    }
    /// numberKeyPress for a field that has validator.isNumber on key press, every key for one that has no filter.
    public static func numberKeyPress(_ filtered: Bool) -> (String, Character) -> String? {
        filtered ? { numberKeyPress($0, $1) } : { value, _ in value }
    }

    /// validator.isHWAddr (440–473) on key press: an ASCII hex digit, typed while the value has fewer than five ":", at
    /// least two characters and neither of its last two a ":", first has ":" appended to the value; ":" goes in; any
    /// other key does nothing.
    public static func hardwareAddressKeyPress(_ value: String, _ key: Character) -> String? {
        if key == ":" { return value }
        guard key.isASCII, key.isHexDigit else { return nil }
        let units = Array(value.utf16)
        let colon = UInt16(UInt8(ascii: ":"))
        if units.filter({ $0 == colon }).count < 5, units.count >= 2, units[units.count - 2] != colon, units[units.count - 1] != colon {
            return value + ":"
        }
        return value
    }

    /// validator.isPrivateIP (923–940): strictly inside 10/8, 172.16/12 or 192.168/16, so the network and broadcast
    /// addresses of each range are not private.
    static func isPrivateIP(_ text: String) -> Bool {
        let number = inetNetwork(text)
        let ranges: [(String, String)] = [("10.0.0.0", "10.255.255.255"), ("172.16.0.0", "172.31.255.255"), ("192.168.0.0", "192.168.255.255")]
        return ranges.contains { number > inetNetwork($0.0) && number < inetNetwork($0.1) }
    }
}
