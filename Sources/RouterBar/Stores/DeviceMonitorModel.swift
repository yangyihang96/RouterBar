import SwiftUI
import RouterCore

@MainActor
final class DeviceMonitorModel: ObservableObject {
    @Published var selectedMAC: String?
    @Published private(set) var tracker = PresenceTracker(archive: PresenceArchive(routerKey: ""))
    @Published private(set) var isMonitoring = false
    @Published private(set) var storageNotice: String?
    @Published private(set) var rates: [String: DeviceTrafficRate] = [:]
    @Published private(set) var rateHistory: [String: [DeviceTrafficRate]] = [:]
    @Published private(set) var trafficStatus = "等待路由器提供单设备流量"
    @Published private(set) var trafficReadAt: Date?
    let notifications = DeviceNotifications()
    private var trafficWindow = DeviceTrafficWindow()
    private let files: MonitoringFileStore
    /// Changes on every pause, so traffic reads and alert checks started before it are dropped.
    private var token = UUID()
    /// Only the newest prepare installs an archive. Pausing (sleep, read failures) never aborts a load.
    private var loadTicket = UUID()
    /// The router whose archive this connection records into.
    private var activeKey = ""
    private var writable = false
    private var lastSave = Date.distantPast
    private var nextTrafficRead = Date.distantPast
    private var lastUptime: TimeInterval?
    private var lastTrafficKey = ""
    private var revision: UInt64 = 0
    init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.yihang.RouterBar/DeviceHistory", isDirectory: true)
        files = MonitoringFileStore(directory: root)
    }
    var records: [DevicePresenceRecord] { tracker.archive.records.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    var watched: [DevicePresenceRecord] { records.filter(\.watched) }
    var events: [PresenceEvent] { Array(tracker.archive.events.reversed()) }
    func events(mac: String) -> [PresenceEvent] { events.filter { $0.mac == mac } }
    func record(_ mac: String) -> DevicePresenceRecord? { tracker.archive.records[mac] }
    /// Online now, as far as monitoring can tell; a paused monitor only knows the last confirmed state.
    func isOnline(_ mac: String) -> Bool {
        isMonitoring && record(mac)?.state == .online && tracker.pendingOffline[mac] == nil && !tracker.heldAbsent.contains(mac)
    }
    func presenceLabel(_ mac: String) -> String {
        let state = record(mac)?.state
        guard isMonitoring else {
            switch state { case .online: return "监测暂停 · 上次在线"; case .offline: return "监测暂停 · 上次离线"; default: return "监测暂停" }
        }
        if tracker.heldAbsent.contains(mac) { return "列表异常 · 暂缓判断" }
        if tracker.pendingOffline[mac] != nil { return "离线待确认" }
        switch state { case .online: return "在线"; case .offline: return "离线"; default: return "状态待确认" }
    }
    func prepare(endpoint: String, identity: RouterIdentity) async {
        let key = MonitoringFileStore.routerKey(endpoint: endpoint, hardwareAddress: identity.hardwareAddress, model: identity.model)
        // Earlier versions kept the history by address; it is copied to the router's own key once.
        var migration: String?
        do { try await files.adoptEarlier(endpoint: endpoint, hardwareAddress: identity.hardwareAddress, model: identity.model, as: key) }
        catch { migration = "旧版本保存的设备历史未能迁移（\(error.localizedDescription)），原文件已保留；本次连接从新的记录开始。" }
        pause(); activeKey = key
        let ticket = UUID(); loadTicket = ticket
        // History that failed to load is read again on every connection and never replaced by an empty one.
        if tracker.archive.routerKey != key || !writable {
            do {
                let archive = try await files.load(routerKey: key)
                guard loadTicket == ticket else { return }
                tracker = PresenceTracker(archive: archive); writable = true; storageNotice = migration
            } catch {
                guard loadTicket == ticket else { return }
                tracker = PresenceTracker(archive: PresenceArchive(routerKey: key)); writable = false
                storageNotice = "本地历史未能读取，新记录暂未写入；原文件已保留。"
            }
        }
        lastSave = .distantPast; lastUptime = nil; lastTrafficKey = key
        Task { await notifications.refresh() }
    }
    func pause() {
        token = UUID(); tracker.pause(); isMonitoring = false; rates = [:]; rateHistory = [:]; trafficWindow.reset()
        trafficStatus = "连接恢复后重新采样"; trafficReadAt = nil; nextTrafficRead = .distantPast
    }
    /// A failed read is only a missing observation. The tracker drops its pending judgements itself once
    /// the gap exceeds its limit, so a brief failure neither restarts the timers nor fabricates an outage.
    func readFailed() {
        isMonitoring = false; rates = [:]; rateHistory = [:]; trafficWindow.reset()
        trafficStatus = "读取失败，恢复后重新采样"; trafficReadAt = nil; nextTrafficRead = .distantPast
    }
    func consume(_ sample: RouterSample, refreshSeconds: Double) {
        // Never record into another router's archive while this router's history is still loading.
        guard !activeKey.isEmpty, tracker.archive.routerKey == activeKey else { return }
        let oldLastEvent = tracker.archive.events.last?.id
        let alerts = tracker.observe(sample.devices, at: sample.sampledAt, monotonic: sample.monotonicTime,
            uptime: sample.uptime, maximumGap: max(90, refreshSeconds * 2.5))
        isMonitoring = sample.devices != nil
        if let old = lastUptime, let uptime = sample.uptime, uptime < old { trafficWindow.reset(); rates = [:]; rateHistory = [:] }
        lastUptime = sample.uptime
        if sample.devices == nil { rates = [:]; rateHistory = [:]; trafficWindow.reset(); trafficReadAt = nil; trafficStatus = "设备列表暂不可用，已暂停流量判断" }
        if tracker.archive.events.last?.id != oldLastEvent || sample.sampledAt.timeIntervalSince(lastSave) > 60 { persist() }
        let ticket = token, key = activeKey
        for event in alerts {
            Task { [weak self] in
                guard let self else { return }
                let due = { [weak self] () -> Bool in
                    guard let self else { return false }
                    return self.token == ticket && self.isMonitoring && self.record(event.mac)?.watched == true && self.record(event.mac)?.state == .offline
                }
                guard due() else { return }
                // Once macOS accepted the notification its cooldown counts, even if monitoring paused meanwhile.
                if await self.notifications.send(name: event.name, eventID: event.id.uuidString, stillDue: due), self.tracker.archive.routerKey == key {
                    self.tracker.acknowledgeAlert(mac: event.mac, at: .now); self.persist()
                }
            }
        }
    }
    func setWatched(_ value: Bool, mac: String) {
        tracker.setWatched(value, mac: mac); persist()
        if value { Task { await notifications.authorize() } }
    }
    func readTraffic(client: RouterClient, online: Set<String>) async {
        guard Date() >= nextTrafficRead else { return }
        let ticket = token, key = lastTrafficKey
        do {
            let reading = try await client.deviceTraffic()
            guard token == ticket, key == lastTrafficKey else { return }
            trafficWindow.consume(reading, online: online)
            rates = trafficWindow.rates; rateHistory = trafficWindow.history
            trafficReadAt = reading.date
            trafficStatus = reading.counters.isEmpty ? "路由器暂未提供设备流量计数，无法据此判断为零流量。" : rates.isEmpty ? "已收到计数，等待下一次采样" : "已读取 \(rates.count) 台设备的实际流量"
            nextTrafficRead = reading.date.addingTimeInterval(reading.counters.isEmpty ? 60 : 0)
        } catch {
            guard token == ticket else { return }
            trafficWindow.reset(); rates = [:]; rateHistory = [:]; trafficReadAt = nil
            trafficStatus = "单设备流量暂不可用；不会用无线链路速率代替。"
            nextTrafficRead = Date().addingTimeInterval(60)
        }
    }
    private func persist() {
        guard writable, !tracker.archive.routerKey.isEmpty else { return }
        let archive = tracker.archive
        revision += 1; let saveRevision = revision
        lastSave = .now
        Task {
            do { try await files.save(archive, revision: saveRevision) }
            catch { if tracker.archive.routerKey == archive.routerKey { storageNotice = "设备历史保存失败：" + error.localizedDescription } }
        }
    }
}
