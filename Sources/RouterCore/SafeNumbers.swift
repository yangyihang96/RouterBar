import Foundation

extension Double {
    /// `Int(self)` without the trap: nil for NaN, infinity, or a value outside Int's range. Router values are text
    /// ("1e400" reads as infinity), so a conversion of one must never be able to stop the app.
    public var truncatedInt: Int? {
        guard isFinite, self > -9.223372036854775e18, self < 9.223372036854775e18 else { return nil }
        return Int(self)
    }
    /// Number.prototype.toString(radix) of a whole number, as the pages call it on parseInt results: "NaN", "Infinity",
    /// and the digits of numbers past Int's range, which a Double still holds exactly.
    public func javaScriptString(radix: Int) -> String {
        if isNaN { return "NaN" }
        if isInfinite { return self < 0 ? "-Infinity" : "Infinity" }
        if let whole = truncatedInt { return String(whole, radix: radix) }
        var rest = abs(rounded(.towardZero)), digits = ""
        let base = Double(radix)
        repeat {
            digits = String(Int(rest.truncatingRemainder(dividingBy: base)), radix: radix) + digits
            rest = (rest / base).rounded(.towardZero)
        } while rest >= 1
        return (self < 0 ? "-" : "") + digits
    }
    /// For display and counts: NaN as 0, and values past Int's range at its ends.
    public var clampedInt: Int {
        if isNaN { return 0 }
        if self >= 9.223372036854775e18 { return .max }
        if self <= -9.223372036854775e18 { return .min }
        return Int(self)
    }
}
