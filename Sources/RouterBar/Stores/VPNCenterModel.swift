import SwiftUI
import RouterCore

/// State of the VPN center: one overview of all 13 slots plus a single NativeSettingsModel editor that is
/// pointed at whichever catalog section is selected. Writes go through NativeSettingsModel.save →
/// RouterClient.applySettings unchanged; this model never builds SettingChange values itself.
@MainActor
final class VPNCenterModel: ObservableObject {
    @Published private(set) var selection: VPNCenterDestination?
    @Published private(set) var overview: [VPNInstance: VPNReadState<VPNProfileSummary>] = [:]
    @Published private(set) var director: VPNReadState<VPNDirectorSummary> = .notRead
    @Published private(set) var overviewReadAt: Date?
    @Published var showAdvanced = false
    /// Field to scroll to and highlight after a search jump.
    @Published var highlightedKey: String?
    /// Target waiting for "放弃修改" confirmation.
    @Published var pendingSelection: VPNCenterDestination?
    @Published var showingAddSheet = false
    @Published var blockedMessage: String?

    /// The only editor of the VPN tabs. Separate from RouterStore's settings editors so a settings page and
    /// a VPN tab never share a draft.
    let editor = NativeSettingsModel()
    /// Previews render from injected summaries and never touch the router.
    let isPreview: Bool
    private var overviewToken = UUID()
    /// A newer read of one card supersedes that card's older overview read without abandoning other cards.
    private var summaryTokens: [VPNCenterDestination: UUID] = [:]

    init() { isPreview = false; reset() }

    /// Preview / test hook: fixed summaries keyed by instance, read at `at`.
    init(previewValues: [VPNInstance: [String: String]], startupLists: [String: String] = [:], director raw: String = "", at: Date = .now) {
        isPreview = true
        for instance in VPNInstance.allSlots {
            if let values = previewValues[instance] {
                let list = instance.startupListKey.flatMap { startupLists[$0] }
                overview[instance] = .loaded(VPNProfileSummary(instance: instance, values: values, startupList: list), at: at)
            } else {
                overview[instance] = .notRead
            }
        }
        director = Self.directorState(raw, at: at)
        overviewReadAt = at
    }

    // MARK: Lifecycle

    /// Call from RouterStore.stopSession(): drops every value read from the previous session.
    func reset() {
        overviewToken = UUID()
        summaryTokens.removeAll()
        overview = Dictionary(uniqueKeysWithValues: VPNInstance.allSlots.map { ($0, .notRead) })
        director = .notRead
        overviewReadAt = nil
        editor.reset()
        pendingSelection = nil; blockedMessage = nil; highlightedKey = nil
    }

    var needsOverview: Bool { !isPreview && overviewReadAt == nil && !overview.values.contains { $0.isLoading } }

    /// Reads every slot separately so one failing slot (e.g. a firmware without WireGuard) does not hide the others.
    func loadOverview(store: RouterStore) async {
        guard !isPreview, store.phase == .connected else { return }
        let token = UUID(); overviewToken = token
        let destinations = VPNInstance.allSlots.map { VPNCenterDestination.instance($0) } + [.routing]
        let tickets = Dictionary(uniqueKeysWithValues: destinations.map { ($0, UUID()) })
        summaryTokens = tickets
        let started = Date()
        for instance in VPNInstance.allSlots { overview[instance] = .loading(since: started) }
        director = .loading(since: started)
        let client: RouterClient
        do { client = try store.connectedClient() }
        catch { fail(all: error, token: token); return }

        var lists: [String: String] = [:]
        do { lists = try await client.readSettings(["vpn_clientx_eas", "vpn_serverx_start"]) }
        catch { guard token == overviewToken else { return }; store.handleManagementError(error) }
        for instance in VPNInstance.allSlots {
            guard token == overviewToken else { return }
            let destination = VPNCenterDestination.instance(instance)
            guard summaryTokens[destination] == tickets[destination] else { continue }
            do {
                let values = try await client.readSettings(instance.overviewKeys)
                guard token == overviewToken else { return }
                guard summaryTokens[destination] == tickets[destination] else { continue }
                let list = instance.startupListKey.flatMap { lists[$0] }
                overview[instance] = .loaded(VPNProfileSummary(instance: instance, values: values, startupList: list), at: .now)
            } catch {
                guard token == overviewToken else { return }
                guard summaryTokens[destination] == tickets[destination] else { continue }
                overview[instance] = .failed(error.localizedDescription, at: .now)
                if (error as? RouterError) == .authenticationRequired { fail(all: error, token: token); store.handleManagementError(error); return }
            }
        }
        do {
            let raw = try await client.readSettings(["vpndirector_rulelist"])["vpndirector_rulelist"] ?? ""
            guard token == overviewToken else { return }
            if summaryTokens[.routing] == tickets[.routing] { director = Self.directorState(raw, at: .now) }
        } catch {
            guard token == overviewToken else { return }
            if summaryTokens[.routing] == tickets[.routing] { director = .failed(error.localizedDescription, at: .now) }
        }
        overviewReadAt = .now
    }

    /// Re-reads one card after a verified save, import or start/stop.
    func refreshSummary(_ destination: VPNCenterDestination, store: RouterStore) async {
        guard !isPreview, store.phase == .connected, let client = try? store.connectedClient() else { return }
        let token = overviewToken
        let ticket = UUID(); summaryTokens[destination] = ticket
        switch destination {
        case .instance(let instance):
            do {
                var keys = instance.overviewKeys
                if let key = instance.startupListKey { keys.append(key) }
                let values = try await client.readSettings(keys)
                guard token == overviewToken, summaryTokens[destination] == ticket else { return }
                overview[instance] = .loaded(VPNProfileSummary(instance: instance, values: values, startupList: instance.startupListKey.flatMap { values[$0] }), at: .now)
            } catch {
                guard token == overviewToken, summaryTokens[destination] == ticket else { return }
                overview[instance] = .failed(error.localizedDescription, at: .now)
                store.handleManagementError(error)
            }
        case .routing:
            do {
                let raw = try await client.readSettings(["vpndirector_rulelist"])["vpndirector_rulelist"] ?? ""
                guard token == overviewToken, summaryTokens[destination] == ticket else { return }
                director = Self.directorState(raw, at: .now)
            } catch {
                guard token == overviewToken, summaryTokens[destination] == ticket else { return }
                director = .failed(error.localizedDescription, at: .now)
                store.handleManagementError(error)
            }
        }
    }

    private func fail(all error: Error, token: UUID) {
        guard token == overviewToken else { return }
        let now = Date()
        for instance in VPNInstance.allSlots where overview[instance]?.isLoading == true { overview[instance] = .failed(error.localizedDescription, at: now) }
        if director.isLoading { director = .failed(error.localizedDescription, at: now) }
    }

    // MARK: Lists

    func state(_ instance: VPNInstance) -> VPNReadState<VPNProfileSummary> { overview[instance] ?? .notRead }

    /// Client slots shown as cards: anything not positively read as unused (unread and failed slots stay visible).
    var listedClients: [VPNInstance] {
        VPNInstance.outboundSlots.filter { instance in
            guard case .loaded(let summary, _) = state(instance) else { return false }
            return !summary.presence.foldsIntoAddMenu
        }
    }
    /// Client slots that failed to read; shown separately so they are neither folded nor treated as empty.
    var failedClients: [VPNInstance] {
        VPNInstance.outboundSlots.filter { if case .failed = state($0) { true } else { false } }
    }
    var pendingClientCount: Int {
        VPNInstance.outboundSlots.filter { switch state($0) { case .notRead, .loading: true; default: false } }.count
    }
    /// Only slots freshly read as unused fold into "添加配置".
    var unusedClients: [VPNInstance] {
        VPNInstance.outboundSlots.filter { state($0).value?.presence.foldsIntoAddMenu == true }
    }
    func directorReferences(_ instance: VPNInstance) -> (total: Int, enabled: Int)? { director.value?.references(to: instance) }

    // MARK: Selection and draft protection

    /// Returns the policy decision. `.proceed` switches immediately, `.confirmDiscard` stores the target
    /// for the confirmation dialog, `.blocked` explains why nothing happened.
    @discardableResult
    func requestSelection(_ target: VPNCenterDestination, store: RouterStore) -> VPNSelectionDecision {
        let decision = VPNSelectionPolicy.decide(current: selection, target: target, pendingChanges: editor.changes.count,
                                                 saving: editor.saving, operationRunning: store.operationTitle != nil)
        switch decision {
        case .proceed: apply(target)
        case .confirmDiscard: pendingSelection = target
        case .blocked(let reason): blockedMessage = reason
        case .alreadySelected: break
        }
        return decision
    }

    func confirmPendingSelection(store: RouterStore) {
        guard let target = pendingSelection, !editor.saving, store.operationTitle == nil else { return }
        pendingSelection = nil
        editor.discard()
        apply(target)
    }
    func cancelPendingSelection() { pendingSelection = nil; highlightedKey = nil }

    /// Leaves no slot selected, e.g. when the VPN tab now shown does not hold the selected slot. A save under
    /// way keeps its editor; navigating away with a draft is confirmed by RouterStore before this runs.
    func clearSelection() {
        guard selection != nil, !editor.saving else { return }
        editor.reset()
        selection = nil; pendingSelection = nil; highlightedKey = nil; blockedMessage = nil
    }

    /// Clears the previous instance's values and invalidates its in-flight read (NativeSettingsModel.reset
    /// replaces its request token), then points the editor at the new catalog section.
    private func apply(_ target: VPNCenterDestination) {
        editor.reset()
        editor.verified = false
        selection = target
        editor.selectedID = target.sectionID
        blockedMessage = nil
        if let key = highlightedKey, VPNCenterDestination(settingKey: key) != target { highlightedKey = nil }
        showAdvanced = highlightedKey.map { VPNFieldLayout.tier(forKey: $0) == .advanced } ?? false
    }

    /// Search jump from the settings search: selects the owning card and reveals the field.
    @discardableResult
    func focus(settingKey: String, store: RouterStore) -> VPNSelectionDecision? {
        guard let target = VPNCenterDestination(settingKey: settingKey) else { return nil }
        highlightedKey = settingKey
        let decision = requestSelection(target, store: store)
        if decision == .alreadySelected, VPNFieldLayout.tier(forKey: settingKey) == .advanced { showAdvanced = true }
        return decision
    }

    /// Whether the editor currently holds a completed read of `destination`.
    func editorHasLoaded(_ destination: VPNCenterDestination) -> Bool {
        editor.readAt != nil && editor.loadedSectionID == destination.sectionID && editor.selectedID == destination.sectionID
    }

    /// Classification from the editor's fresh full-section read, preferred over the overview for import placement.
    func freshPresence(_ instance: VPNInstance) -> VPNSlotPresence? {
        guard editorHasLoaded(.instance(instance)) else { return nil }
        return VPNProfileClassifier.presence(of: instance, values: editor.values)
    }
}

extension VPNCenterModel {
    static func directorState(_ raw: String, at date: Date) -> VPNReadState<VPNDirectorSummary> {
        if let summary = try? VPNDirectorSummary(raw: raw) { return .loaded(summary, at: date) }
        return .failed("规则格式与当前固件不同，原始内容已保留。", at: date)
    }

    /// Sample data for SwiftUI previews: a configured OpenVPN client, an incomplete WireGuard client,
    /// four empty OpenVPN slots (default port only) and three WireGuard slots left unread.
    static func preview() -> VPNCenterModel {
        var values: [VPNInstance: [String: String]] = [:]
        for n in 2...5 {
            let instance = VPNInstance.openVPNClient(n)
            var empty: [String: String] = [:]
            for key in instance.overviewKeys { empty[key] = key.hasSuffix("_port") ? "1194" : key.hasSuffix("_state") ? "0" : "" }
            values[instance] = empty
        }
        values[.openVPNClient(1)] = ["vpn_client1_desc": "家庭出口", "vpn_client1_addr": "vpn.example.com", "vpn_client1_port": "1194", "vpn_client1_proto": "udp",
                                     "vpn_client1_userauth": "0", "vpn_client1_username": "", "vpn_client1_enforce": "1", "vpn_client1_state": "2"]
        values[.wireGuardClient(2)] = ["wgc2_enable": "1", "wgc2_desc": "", "wgc2_addr": "10.6.0.2/32", "wgc2_priv": "preview", "wgc2_ppub": "",
                                       "wgc2_ep_addr": "203.0.113.5", "wgc2_ep_port": "51820", "wgc2_aips": "0.0.0.0/0", "wgc2_enforce": "0"]
        values[.openVPNServer(1)] = ["vpn_server1_port": "1194", "vpn_server1_proto": "udp", "vpn_server1_state": "0"]
        values[.openVPNServer(2)] = ["vpn_server2_port": "1195", "vpn_server2_proto": "udp", "vpn_server2_state": "0"]
        values[.wireGuardServer] = ["wgs1_enable": "0", "wgs1_port": "51820", "wgs1_addr": "10.6.0.1/32"]
        return VPNCenterModel(previewValues: values, startupLists: ["vpn_clientx_eas": "1,"], director: "<1>电视>192.168.50.20>>OVPN1")
    }
}
