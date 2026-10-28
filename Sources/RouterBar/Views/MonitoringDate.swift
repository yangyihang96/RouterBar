import Foundation

enum MonitoringDate {
    static func day(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "今天" }
        if Calendar.current.isDateInYesterday(date) { return "昨天" }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(Locale(identifier: "zh_CN")))
    }
    static func full(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(Locale(identifier: "zh_CN")))
    }
    static func short(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "zh_CN")))
    }
    static func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .standard).locale(Locale(identifier: "zh_CN")))
    }
}
