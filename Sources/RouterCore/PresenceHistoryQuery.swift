import Foundation

public enum PresenceHistoryFilter: String, CaseIterable, Sendable {
    case changes, discovery, observations, all
    public var title: String {
        switch self {
        case .changes: "上下线"; case .discovery: "首次发现"; case .observations: "恢复监测"; case .all: "全部记录"
        }
    }
    public func includes(_ event: PresenceEvent) -> Bool {
        switch self {
        case .changes: event.kind == .online || event.kind == .offline
        case .discovery: event.kind == .firstSeen
        case .observations: event.kind == .observedOnline || event.kind == .observedOffline || event.afterPause == true
        case .all: true
        }
    }
}

public enum PresenceHistoryQuery {
    public static func matches(_ record: DevicePresenceRecord, search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || [record.name, record.mac, record.ip ?? ""].contains { $0.localizedCaseInsensitiveContains(query) }
    }
    /// Filtering is presentation only: baseline observations and the source archive remain intact.
    public static func events(_ events: [PresenceEvent], records: [String: DevicePresenceRecord],
                              mac: String? = nil, watchedOnly: Bool = false, search: String = "",
                              filter: PresenceHistoryFilter = .changes, since: Date = .distantPast) -> [PresenceEvent] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return events.reversed().filter { event in
            guard event.at >= since, filter.includes(event), mac == nil || event.mac == mac else { return false }
            let record = records[event.mac]
            if watchedOnly && record?.watched != true { return false }
            return query.isEmpty || record.map { matches($0, search: query) } == true ||
                event.name.localizedCaseInsensitiveContains(query) || event.mac.localizedCaseInsensitiveContains(query)
        }.sorted { $0.at > $1.at }
    }
}
