import SwiftUI
import RouterCore

@MainActor
final class SDNModel: ObservableObject {
    @Published var snapshot: SDNSnapshot?
    @Published var loading = false
    @Published var notice: String?
    @Published var verified = false
    func load(store: RouterStore) async {
        guard !loading, store.operationTitle == nil else { return }; loading = true; notice = nil
        defer { loading = false }
        do { snapshot = try await store.connectedClient().sdnSnapshot() }
        catch { notice = error.localizedDescription; store.handleManagementError(error) }
    }
    func apply(_ plan: SDNPlan, store: RouterStore) async {
        guard store.beginOperation(plan.summary) else { return }; notice = nil; verified = false
        defer { store.endOperation() }
        do {
            let client = try store.connectedClient()
            let receipt = try await client.applySDN(plan)
            notice = receipt.message; verified = receipt.isVerified
            guard receipt.isVerified else { return }
            do { snapshot = try await client.sdnSnapshot() }
            catch {
                // The save itself was confirmed; only the list is out of date, so never plan the next edit from it.
                snapshot = nil
                notice = receipt.message + " 但重新读取网络列表失败：\(error.localizedDescription) 请稍后重新读取。"
                store.handleManagementError(error)
            }
        } catch { notice = error.localizedDescription; verified = false; store.handleManagementError(error) }
    }
    func reset() { snapshot = nil; notice = nil; loading = false }
}
