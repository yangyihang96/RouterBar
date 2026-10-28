import Foundation

public enum PresenceState: String, Codable, Sendable { case online, offline, unknown }
public enum PresenceEventKind: String, Codable, Sendable {
    /// `observedOnline` and `observedOffline` were written by 1.4.x at every monitoring restart. They stay
    /// decodable so those archives still load; new records mark changes across a pause with `afterPause`.
    case firstSeen, online, offline, observedOnline, observedOffline
    public var title: String {
        switch self {
        case .firstSeen: "首次发现"; case .online: "重新上线"; case .offline: "确认离线"
        case .observedOnline: "恢复监测时在线"; case .observedOffline: "恢复监测时离线"
        }
    }
}
public struct PresenceEvent: Identifiable, Codable, Sendable, Equatable {
    public var id = UUID()
    public let mac: String
    public let name: String
    public let kind: PresenceEventKind
    public let at: Date
    /// First absent observation, not the exact time of disconnection.
    public var absentSince: Date?
    /// The change happened while monitoring was paused; only its first observation afterwards is known.
    public var afterPause: Bool?
}
public struct DevicePresenceRecord: Identifiable, Codable, Sendable, Equatable {
    public var id: String { mac }
    public let mac: String
    public var name: String
    public var kind: DeviceKind
    public var ip: String?
    public var connection: String
    public var firstObserved: Date
    public var lastSeen: Date?
    public var lastObserved: Date
    public var state: PresenceState
    public var watched = false
    public var lastAlert: Date?
}
public struct PresenceArchive: Codable, Sendable {
    public var version = 1
    public var routerKey: String
    public var records: [String: DevicePresenceRecord] = [:]
    public var events: [PresenceEvent] = []
    public var savedAt: Date = .now
    public init(routerKey: String) { self.routerKey = routerKey }
}

/// Only consecutive successful observations establish a transition. A pause keeps each device's last
/// confirmed state, so resuming records only devices whose state really changed, and a device missing
/// after a pause still needs `offlineDelay` of continuous absence. A client list that suddenly collapses
/// (the router's client table restarting) is not evidence that devices left: absences are held until the
/// list recovers or the collapse lasts `listDropDelay`.
public struct PresenceTracker: Sendable {
    public private(set) var archive: PresenceArchive
    public private(set) var pendingOffline: [String: Date] = [:]
    /// Devices missing from a collapsed client list, whose offline judgement is on hold.
    public private(set) var heldAbsent: Set<String> = []
    private var pendingMonotonic: [String: TimeInterval] = [:]
    private var pendingAfterPause: Set<String> = []
    private var listDrop: (date: Date, monotonic: TimeInterval, afterPause: Bool)?
    private var previousMonotonic: TimeInterval?
    private var previousUptime: TimeInterval?
    public let offlineDelay: TimeInterval
    public let alertCooldown: TimeInterval
    public let listDropDelay: TimeInterval
    public init(archive: PresenceArchive, offlineDelay: TimeInterval = 180, alertCooldown: TimeInterval = 1800, listDropDelay: TimeInterval = 600) {
        self.archive = archive; self.offlineDelay = offlineDelay; self.alertCooldown = alertCooldown
        self.listDropDelay = max(listDropDelay, offlineDelay)
    }
    /// Stops judging without forgetting the last confirmed states; every timer restarts after the pause.
    public mutating func pause() {
        previousMonotonic = nil; previousUptime = nil; listDrop = nil
        pendingOffline = [:]; pendingMonotonic = [:]; pendingAfterPause = []; heldAbsent = []
    }
    public mutating func setWatched(_ watched: Bool, mac: String) { archive.records[mac]?.watched = watched }
    public mutating func acknowledgeAlert(mac: String, at date: Date) { archive.records[mac]?.lastAlert = date }
    @discardableResult
    public mutating func observe(_ devices: [RouterDevice]?, at date: Date, monotonic: TimeInterval,
                                 uptime: TimeInterval?, maximumGap: TimeInterval = 150) -> [PresenceEvent] {
        guard let devices else { pause(); return [] }
        if let old = previousMonotonic, monotonic <= old || monotonic - old > maximumGap { pause() }
        if let old = previousUptime, let uptime, uptime < old { pause() }
        let resumed = previousMonotonic == nil
        previousMonotonic = monotonic; previousUptime = uptime
        let online = Set(devices.filter(\.isOnline).map { $0.mac.uppercased() })
        let knownOnline = archive.records.values.filter { $0.state == .online }.count
        for device in devices {
            let mac = device.mac.uppercased()
            if archive.records[mac] == nil {
                archive.records[mac] = DevicePresenceRecord(mac: mac, name: device.name, kind: device.classification.kind,
                    ip: device.ip, connection: device.connectionLabel, firstObserved: date,
                    lastSeen: device.isOnline ? date : nil, lastObserved: date, state: .unknown)
                if device.isOnline { append(mac, .firstSeen, at: date) }
            }
            archive.records[mac]?.name = device.name
            archive.records[mac]?.kind = device.classification.kind
            if let ip = device.ip { archive.records[mac]?.ip = ip }
            archive.records[mac]?.connection = device.connectionLabel
        }
        let collapsed = knownOnline >= 4 && online.count * 2 < knownOnline
        if !collapsed { listDrop = nil } else if listDrop == nil { listDrop = (date, monotonic, resumed) }
        let holding = listDrop.map { monotonic - $0.monotonic < listDropDelay } ?? false
        heldAbsent = []
        var alerts: [PresenceEvent] = []
        for mac in Array(archive.records.keys) {
            guard let old = archive.records[mac] else { continue }
            archive.records[mac]?.lastObserved = date
            if online.contains(mac) {
                archive.records[mac]?.lastSeen = date; archive.records[mac]?.state = .online
                clearPending(mac)
                if old.state == .offline { append(mac, .online, at: date, afterPause: resumed) }
            } else if old.state == .online {
                // Each device is dated from the first list that lacked it, also while a collapsed list is held: a
                // collapse decides only when absences may be judged, not how long a device has been away.
                if pendingOffline[mac] == nil {
                    pendingOffline[mac] = date; pendingMonotonic[mac] = monotonic
                    if resumed { pendingAfterPause.insert(mac) }
                }
                if holding { heldAbsent.insert(mac); continue }
                if let since = pendingOffline[mac], let began = pendingMonotonic[mac], monotonic - began >= offlineDelay {
                    let afterPause = pendingAfterPause.contains(mac)
                    archive.records[mac]?.state = .offline; clearPending(mac)
                    let event = append(mac, .offline, at: date, absentSince: since, afterPause: afterPause)
                    if old.watched, old.lastAlert.map({ date.timeIntervalSince($0) >= alertCooldown }) ?? true { alerts.append(event) }
                }
            } else if old.state == .unknown {
                archive.records[mac]?.state = .offline
            }
        }
        prune(at: date)
        return alerts
    }
    private mutating func clearPending(_ mac: String) {
        pendingOffline[mac] = nil; pendingMonotonic[mac] = nil; pendingAfterPause.remove(mac)
    }
    @discardableResult private mutating func append(_ mac: String, _ kind: PresenceEventKind, at date: Date,
                                                    absentSince: Date? = nil, afterPause: Bool = false) -> PresenceEvent {
        let event = PresenceEvent(mac: mac, name: archive.records[mac]?.name ?? mac, kind: kind, at: date,
                                  absentSince: absentSince, afterPause: afterPause ? true : nil)
        archive.events.append(event); return event
    }
    private mutating func prune(at date: Date) {
        archive.events = Array(archive.events.filter { $0.at >= date.addingTimeInterval(-30 * 86400) }.suffix(10_000))
        // Retain known/watched devices; cap stale unobserved inventory independently of event retention.
        if archive.records.count > 2048 {
            let removable = archive.records.values.filter { !$0.watched && $0.state != .online }.sorted { ($0.lastSeen ?? .distantPast) < ($1.lastSeen ?? .distantPast) }
            for record in removable.prefix(archive.records.count - 2048) { archive.records[record.mac] = nil }
        }
        archive.savedAt = date
    }
}
