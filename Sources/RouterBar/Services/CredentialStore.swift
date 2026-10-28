import Foundation
import Security
import LocalAuthentication
import RouterCore

struct RouterCredential: Codable, Sendable { let username: String; let password: String }
enum CredentialLookup: Sendable { case credential(RouterCredential), unavailable(CredentialAccessState) }

enum CredentialStore {
    private static let service = "com.yihang.RouterBar.credentials"
    static func read(address: String, allowInteraction: Bool = false) async -> RouterCredential? {
        if case .credential(let value) = await lookup(address: address, allowInteraction: allowInteraction) { return value }
        return nil
    }
    static func lookup(address: String, allowInteraction: Bool = false) async -> CredentialLookup {
        await Task.detached(priority: .userInitiated) { readSynchronously(address: address, allowInteraction: allowInteraction) }.value
    }
    private static func readSynchronously(address: String, allowInteraction: Bool) -> CredentialLookup {
        var query = base(address)
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        query[kSecUseAuthenticationContext as String] = context
        // Login-keychain ACL items predate the data-protection keychain and can ignore LAContext.
        // Keep its legacy no-UI flag as well so automatic startup never waits on an ACL dialog.
        if !allowInteraction { query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return .unavailable(.from(status: status)) }
        guard let data = item as? Data, let value = try? JSONDecoder().decode(RouterCredential.self, from: data) else { return .unavailable(.corrupted) }
        return .credential(value)
    }
    static func save(_ credential: RouterCredential, address: String) async throws {
        try await Task.detached(priority: .userInitiated) { try saveSynchronously(credential, address: address) }.value
    }
    private static func saveSynchronously(_ credential: RouterCredential, address: String) throws {
        let data = try JSONEncoder().encode(credential)
        let query = base(address)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    static func remove(address: String) async throws {
        try await Task.detached(priority: .userInitiated) { try removeSynchronously(address: address) }.value
    }
    private static func removeSynchronously(address: String) throws {
        let status = SecItemDelete(base(address) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    private static func base(_ address: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: address]
    }
}
