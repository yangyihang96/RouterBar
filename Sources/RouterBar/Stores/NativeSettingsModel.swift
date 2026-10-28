import SwiftUI
import RouterCore

/// Reads, edits and saves one catalog section. Pages own one per section through RouterStore.settingsModel(for:);
/// the VPN center re-points its single editor at whichever slot is selected.
@MainActor
final class NativeSettingsModel: ObservableObject {
    @Published var selectedID: String
    @Published var values: [String: String] = [:]
    @Published var draft: [String: String] = [:]
    @Published var loading = false
    @Published var saving = false
    @Published var notice: String?
    @Published var verified = false
    @Published var readAt: Date?
    var loadedSectionID: String?
    private var requestID = UUID()
    init(sectionID: String = "") { selectedID = sectionID }
    var section: SettingSection? { SettingsCatalog.section(selectedID) }
    var changes: [SettingChange] {
        guard let section else { return [] }
        return section.fields.compactMap { field in
            guard let old = values[field.key], let edited = draft[field.key] else { return nil }
            // Sent as the web sends it (an emptied number as "0"), so a value the web would not change is no change.
            let new = field.submitted(edited)
            guard old != new else { return nil }
            return SettingChange(field: field, before: old, after: new)
        }
    }
    func reset() { requestID = UUID(); values = [:]; draft = [:]; loading = false; notice = nil; readAt = nil; loadedSectionID = nil }
    func load(store: RouterStore) async {
        guard let section, !saving else { return }
        let token = UUID(); requestID = token
        // Reading the same section again keeps its last values on screen, locked, until the new ones arrive, so a revisit
        // does not flash an empty card. Anything else starts empty.
        let keepsLastRead = loadedSectionID == section.id && readAt != nil && changes.isEmpty
        if !keepsLastRead { values = [:]; draft = [:]; readAt = nil }
        notice = nil; verified = false; loading = true
        defer { if requestID == token { loading = false } }
        do {
            let client = try store.connectedClient()
            let result = try await client.readSettings(section: section)
            guard requestID == token else { return }
            values = result; draft = result; readAt = .now; loadedSectionID = section.id
        } catch {
            guard requestID == token else { return }
            // What failed to read is not shown as current.
            values = [:]; draft = [:]; readAt = nil
            notice = error.localizedDescription; store.handleManagementError(error)
        }
    }
    /// An edit; a band's new auth brings the encryption and management frame protection the page then offers.
    func edit(_ key: String, _ value: String, band: WirelessSecurityRules.BandContext?) {
        draft[key] = value
        guard let band, let section, let unit = WirelessSecurityRules.unit(ofSection: section.id), key == "wl\(unit)_auth_mode_x" else { return }
        draft = WirelessSecurityRules.adjusted(draft, section: section, context: band)
    }
    func save(store: RouterStore) async {
        guard let section, !changes.isEmpty, !saving else { return }
        if let reason = store.readOnlyReason(section: section.id) { notice = reason; return }
        guard store.beginOperation("正在保存\(section.title)") else { return }
        let submitted = changes
        saving = true; notice = nil; verified = false
        defer { saving = false; store.endOperation() }
        do {
            let client = try store.connectedClient()
            let result = try await client.applySettings(section: section, changes: submitted)
            notice = result.message; verified = result.isVerified
            if result.isVerified {
                for change in submitted { values[change.field.key] = change.after }
                readAt = .now
            }
        } catch { notice = error.localizedDescription; store.handleManagementError(error) }
    }
    func discard() { draft = values; notice = nil }
}
