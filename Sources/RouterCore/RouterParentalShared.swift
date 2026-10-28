import Foundation

// 家长管理两页（AiProtection_WebProtector.asp、ParentalControl.asp，Asuswrt-Merlin 3006.102.5）共用：页面读取的变量在脚本、
// 隐藏字段里各自的样子，isSupport() 的原值，MAC 检查，以及 start_apply.htm 表单的发送与回应。

// MARK: - Values in the page's contexts

/// The variables a page reads, kept as nvram_char_to_ascii wrote them (still percent-encoded), so that each of the page's
/// contexts can be derived from the stored bytes: the text a script gets from `'<% nvram_get(name); %>'`, and a hidden
/// input's value as the browser decodes its attribute.
public struct EncodedNvram: Sendable, Equatable {
    public let encoded: [String: String]
    public init(encoded: [String: String]) { self.encoded = encoded }

    /// The stored bytes: each %XX of the answer as a byte, other characters as their UTF-8.
    func bytes(_ key: String) -> [UInt8] {
        let units = Array((encoded[key] ?? "").utf8)
        func hex(_ unit: UInt8) -> UInt8? {
            switch unit {
            case 0x30...0x39: unit - 0x30
            case 0x41...0x46: unit - 0x37
            case 0x61...0x66: unit - 0x57
            default: nil
            }
        }
        var bytes: [UInt8] = [], index = 0
        while index < units.count {
            if units[index] == 0x25, index + 2 < units.count, let high = hex(units[index + 1]), let low = hex(units[index + 2]) {
                bytes.append(high << 4 | low); index += 3
            } else {
                bytes.append(units[index]); index += 1
            }
        }
        return bytes
    }
    /// The stored value as text.
    public func raw(_ key: String) -> String { String(decoding: bytes(key), as: UTF8.self) }
    /// `'<% nvram_get(name); %>'` in a script (ej_nvram_get, web.c 1322–1334): the escapes stay as written.
    func js(_ key: String) -> String { aspNvramText(bytes(key)) }
    /// `value="<% nvram_get(name); %>"` as the browser reads it: the escapes decoded as character references.
    func attribute(_ key: String) -> String { HTMLText.decode(js(key), inAttribute: true) }
    /// A value written between quotes in a script: a quote of that kind or a backslash in it stops the whole script.
    func breaksScript(_ key: String, quote: Character) -> Bool { js(key).contains(quote) || js(key).contains("\\") }
}

// MARK: - isSupport()

/// get_ui_support as the pages' isSupport() returns it (state.js 481–486): `ui_support[name]` itself when it is truthy,
/// otherwise the number 0. The value is kept as the router wrote it (a number or a text), so `parseInt(isSupport(…))`,
/// `== 0` and `> 0` are worked out as JavaScript works them out, not on a Boolean.
public struct UISupport: Sendable, Equatable {
    public let object: OrderedJSON?
    public init(_ object: OrderedJSON?) { self.object = object }

    /// isSupport(name).
    public func value(_ name: String) -> OrderedJSON {
        guard let value = object?[name], javaScriptTruthy(value) else { return .number("0") }
        return value
    }
    /// `if(isSupport(name))`: a text "0" is truthy, the number 0 is not.
    public func on(_ name: String) -> Bool { javaScriptTruthy(object?[name]) }
    /// `parseInt(isSupport(name))`; NaN for a value without leading digits.
    public func integer(_ name: String) -> Double { javaScriptParseInt(TORSettings.javaScriptString(value(name))) }
    /// isSupport(name) joined into a text.
    public func text(_ name: String) -> String { TORSettings.javaScriptString(value(name)) }
}

/// ToBoolean for a JSON value: an empty text, 0, NaN, false, null and a missing value are false; objects and arrays true.
func javaScriptTruthy(_ value: OrderedJSON?) -> Bool {
    switch value {
    case nil, .null?: return false
    case .bool(let on)?: return on
    case .string(let text)?: return !text.isEmpty
    case .number(let text)?:
        let number = javaScriptNumber(text) ?? .nan
        return !number.isNaN && number != 0
    case .object?, .array?: return true
    }
}

/// parseInt(text, radix): leading white space and a sign, then the longest run of digits of the radix (a "0x" prefix is
/// taken without a radix or with 16); NaN when no digit leads.
func javaScriptParseInt(_ text: String, radix: Int? = nil) -> Double {
    var body = Substring(javaScriptTrim(text)), sign = 1.0
    if let mark = body.first, mark == "+" || mark == "-" { sign = mark == "-" ? -1 : 1; body = body.dropFirst() }
    var base = radix ?? 10
    if radix == nil || radix == 16, body.hasPrefix("0x") || body.hasPrefix("0X") { base = 16; body = body.dropFirst(2) }
    var value = 0.0, digits = 0
    for character in body {
        guard character.isASCII, let digit = character.hexDigitValue, digit < base else { break }
        value = value * Double(base) + Double(digit); digits += 1
    }
    return digits == 0 ? .nan : sign * value
}

/// String.prototype.split with a text separator, on UTF-16 code units: "" gives [""].
func javaScriptSplit(_ text: String, _ separator: String) -> [String] {
    let units = Array(text.utf16), mark = Array(separator.utf16)
    guard !mark.isEmpty else { return units.map { String(decoding: [$0], as: UTF16.self) } }
    var parts: [String] = [], start = 0, index = 0
    while index + mark.count <= units.count {
        if Array(units[index..<index + mark.count]) == mark {
            parts.append(String(decoding: units[start..<index], as: UTF16.self)); index += mark.count; start = index
        } else { index += 1 }
    }
    parts.append(String(decoding: units[start...], as: UTF16.self))
    return parts
}

/// `text.indexOf(search) != -1`, on UTF-16 code units.
func javaScriptContains(_ text: String, _ search: String) -> Bool {
    let units = Array(text.utf16), needle = Array(search.utf16)
    guard !needle.isEmpty else { return true }
    guard needle.count <= units.count else { return false }
    return (0...(units.count - needle.count)).contains { Array(units[$0..<$0 + needle.count]) == needle }
}

/// `x >= y` in JavaScript, false when either side is NaN.
func javaScriptAtLeast(_ x: OrderedJSON, _ y: OrderedJSON) -> Bool {
    [.orderedDescending, .orderedSame].contains(JavaScriptCompare.relational(x, y))
}
/// `x > y` in JavaScript.
func javaScriptAbove(_ x: OrderedJSON, _ y: OrderedJSON) -> Bool { JavaScriptCompare.relational(x, y) == .orderedDescending }

// MARK: - MAC addresses

public enum ParentalMAC {
    /// check_hwaddr_flag(obj, 'inner') (general.js 1767–1780): 0 for an empty value, or one holding six two-digit hex groups
    /// each followed by ":" or the end anywhere in it (the pattern is not anchored); 1 otherwise. 'inner' skips the unicast
    /// check that would give 2.
    public static func flag(_ value: String) -> Int {
        guard !value.isEmpty else { return 0 }
        let units = Array(value.utf16)
        func hex(_ unit: UInt16) -> Bool { (0x30...0x39).contains(unit) || (0x41...0x46).contains(unit) || (0x61...0x66).contains(unit) }
        for start in units.indices {
            var at = start, groups = 0
            while groups < 6, at + 1 < units.count, hex(units[at]), hex(units[at + 1]) {
                if at + 2 == units.count { at += 2; groups += 1; break }
                guard units[at + 2] == 0x3A else { break }
                at += 3; groups += 1
            }
            // The last group may also end the text; a group that ends it leaves no room for another.
            if groups == 6 { return 0 }
        }
        return 1
    }
    /// The hint check_macaddr writes under the field for flag 1 (LANHostConfig_ManualDHCPMacaddr_itemdesc).
    public static let formatHint = "MAC 地址的格式为六组十六进制的数元，每组两个，以冒号分隔，按照传送排序。（例如，12:34:56:aa:bc:ef）"
}

// MARK: - The page's form

/// A page's `form` as it goes to start_apply.htm: the named controls that are not disabled, in document order.
public struct ParentalFormSubmission: Sendable, Equatable {
    public let fields: [(String, String)]
    public init(fields: [(String, String)]) { self.fields = fields }
    public static func == (a: ParentalFormSubmission, b: ParentalFormSubmission) -> Bool { a.fields.elementsEqual(b.fields, by: { $0 == $1 }) }
    /// The value of the first control with this name.
    public func value(_ name: String) -> String? { fields.first { $0.0 == name }?.1 }
    public var actionScript: String { value("action_script") ?? "" }
    public var reboots: Bool { actionScript == "reboot" }
    /// action_wait as a number of seconds (the page's own loading time); 5 when it is not a plain number.
    public var wait: Int { Int(value("action_wait") ?? "") ?? 5 }
}

/// What start_apply.htm answers for action_mode "apply" (web.c 5953–5961): done_committing() when a variable changed,
/// no_changes_and_no_committing() when none did. The action_script runs in both cases.
public enum FormApplyAnswer: Sendable, Equatable { case changed, unchanged, unrecognized }

extension RouterClient {
    /// document.form.submit(): the form to start_apply.htm, encoded as the browser encodes a submitted form.
    func postParentalForm(_ submission: ParentalFormSubmission) async throws -> FormApplyAnswer {
        let data = try await request("start_apply.htm", method: "POST", body: RouterAuthentication.orderedForm(submission.fields, .formSubmission),
                                     contentType: "application/x-www-form-urlencoded", timeout: 60)
        let text = String(decoding: data, as: UTF8.self)
        if text.contains("<script>done_committing();</script>") { return .changed }
        if text.contains("<script>no_changes_and_no_committing();</script>") { return .unchanged }
        return .unrecognized
    }

    /// Reads `keys` back and compares them with `sent` (raw values, as the router keeps them).
    func checkSent(_ sent: [(String, String)], success: String) async throws -> ApplyReceipt {
        let keys = sent.map(\.0)
        let after = try await readSettings(keys)
        let unverified = sent.filter { after[$0.0] != $0.1 }.map(\.0)
        return ApplyReceipt(verified: keys.filter { !unverified.contains($0) }, unverified: unverified,
                            message: unverified.isEmpty ? success : "路由器已响应，但这些设置与提交值不一致：" + unverified.joined(separator: "、") + "。请重新读取并检查。")
    }

    /// The pages' get_ui_support, kept as the router wrote it.
    func orderedUISupport() async throws -> UISupport {
        guard let object = try await orderedHook("get_ui_support"), case .object = object else { throw RouterError.invalidResponse("固件功能列表") }
        return UISupport(object)
    }
}
