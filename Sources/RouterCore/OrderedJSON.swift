import Foundation

/// A JSON value that keeps the order of object members, as a browser's JSON.parse does and JSONSerialization does not.
/// Pages that walk an answer with `for … in` or Object.entries see its members in that order (json-c writes them in the
/// order they were added), so readers that follow such a page parse the answer with this.
public indirect enum OrderedJSON: Sendable, Equatable {
    case object([(String, OrderedJSON)])
    case array([OrderedJSON])
    case string(String)
    /// The number as written, so that it can be read the way the page reads it.
    case number(String)
    case bool(Bool)
    case null

    public static func == (lhs: OrderedJSON, rhs: OrderedJSON) -> Bool {
        switch (lhs, rhs) {
        case (.object(let a), .object(let b)): a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case (.array(let a), .array(let b)): a == b
        case (.string(let a), .string(let b)), (.number(let a), .number(let b)): a == b
        case (.bool(let a), .bool(let b)): a == b
        case (.null, .null): true
        default: false
        }
    }

    /// A member of an object; like JSON.parse, a repeated name keeps its first place and its last value.
    public subscript(key: String) -> OrderedJSON? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.0 == key }?.1
    }

    public var members: [(String, OrderedJSON)] { if case .object(let members) = self { members } else { [] } }

    /// The text JavaScript would make of the value when it is joined into a string: numbers as written are close enough
    /// for the values routers send (integers); objects and arrays are not text.
    public var text: String? {
        switch self {
        case .string(let value), .number(let value): value
        case .bool(let value): value ? "true" : "false"
        case .null: "null"
        case .object, .array: nil
        }
    }

    public init(data: Data) throws {
        var parser = Parser(bytes: Array(data))
        parser.skipSpace()
        self = try parser.value(depth: 0)
        parser.skipSpace()
        guard parser.index == parser.bytes.count else { throw RouterError.invalidResponse("JSON") }
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func skipSpace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func value(depth: Int) throws -> OrderedJSON {
            guard depth < 64, index < bytes.count else { throw RouterError.invalidResponse("JSON") }
            switch bytes[index] {
            case UInt8(ascii: "{"):
                index += 1
                var members: [(String, OrderedJSON)] = []
                skipSpace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
                while true {
                    skipSpace()
                    guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw RouterError.invalidResponse("JSON") }
                    let key = try string()
                    skipSpace()
                    guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw RouterError.invalidResponse("JSON") }
                    index += 1
                    skipSpace()
                    let member = try value(depth: depth + 1)
                    if let at = members.firstIndex(where: { $0.0 == key }) { members[at].1 = member } else { members.append((key, member)) }
                    skipSpace()
                    guard index < bytes.count else { throw RouterError.invalidResponse("JSON") }
                    if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                    guard bytes[index] == UInt8(ascii: "}") else { throw RouterError.invalidResponse("JSON") }
                    index += 1
                    return .object(members)
                }
            case UInt8(ascii: "["):
                index += 1
                var elements: [OrderedJSON] = []
                skipSpace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(elements) }
                while true {
                    skipSpace()
                    elements.append(try value(depth: depth + 1))
                    skipSpace()
                    guard index < bytes.count else { throw RouterError.invalidResponse("JSON") }
                    if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                    guard bytes[index] == UInt8(ascii: "]") else { throw RouterError.invalidResponse("JSON") }
                    index += 1
                    return .array(elements)
                }
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return .number(try number())
            }
        }

        mutating func literal(_ word: String) throws {
            let expected = Array(word.utf8)
            guard index + expected.count <= bytes.count, Array(bytes[index..<index + expected.count]) == expected else { throw RouterError.invalidResponse("JSON") }
            index += expected.count
        }

        mutating func number() throws -> String {
            let start = index
            func digits() -> Int { let from = index; while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }; return index - from }
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard index < bytes.count else { throw RouterError.invalidResponse("JSON") }
            if bytes[index] == UInt8(ascii: "0") { index += 1 } else { guard digits() > 0 else { throw RouterError.invalidResponse("JSON") } }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") { index += 1; guard digits() > 0 else { throw RouterError.invalidResponse("JSON") } }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                guard digits() > 0 else { throw RouterError.invalidResponse("JSON") }
            }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }

        mutating func string() throws -> String {
            index += 1
            var units: [UInt16] = []
            var raw: [UInt8] = []
            func flush() { if !raw.isEmpty { units.append(contentsOf: String(decoding: raw, as: UTF8.self).utf16); raw.removeAll() } }
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                switch byte {
                case UInt8(ascii: "\""):
                    flush()
                    return String(decoding: units, as: UTF16.self)
                case UInt8(ascii: "\\"):
                    flush()
                    guard index < bytes.count else { throw RouterError.invalidResponse("JSON") }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case UInt8(ascii: "\""): units.append(0x22)
                    case UInt8(ascii: "\\"): units.append(0x5C)
                    case UInt8(ascii: "/"): units.append(0x2F)
                    case UInt8(ascii: "b"): units.append(0x08)
                    case UInt8(ascii: "f"): units.append(0x0C)
                    case UInt8(ascii: "n"): units.append(0x0A)
                    case UInt8(ascii: "r"): units.append(0x0D)
                    case UInt8(ascii: "t"): units.append(0x09)
                    case UInt8(ascii: "u"):
                        guard index + 4 <= bytes.count, let unit = UInt16(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16) else {
                            throw RouterError.invalidResponse("JSON")
                        }
                        units.append(unit)
                        index += 4
                    default: throw RouterError.invalidResponse("JSON")
                    }
                default:
                    guard byte >= 0x20 else { throw RouterError.invalidResponse("JSON") }
                    raw.append(byte)
                }
            }
            throw RouterError.invalidResponse("JSON")
        }
    }
}
