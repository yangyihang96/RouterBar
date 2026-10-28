import Foundation
import CryptoKit

/// Atomic private storage. No credentials or session cookies are part of this schema.
public actor MonitoringFileStore {
    private let directory: URL
    private var revisions: [String: UInt64] = [:]
    public init(directory: URL) { self.directory = directory }
    public func load(routerKey: String) throws -> PresenceArchive {
        let url = file(routerKey)
        guard FileManager.default.fileExists(atPath: url.path) else { return PresenceArchive(routerKey: routerKey) }
        let data = try Data(contentsOf: url)
        guard data.count <= 20_000_000 else { throw RouterError.invalidResponse("本地设备历史大小") }
        let archive = try JSONDecoder().decode(PresenceArchive.self, from: data)
        guard archive.version == 1, archive.routerKey == routerKey else { throw RouterError.invalidResponse("本地设备历史版本") }
        return archive
    }
    public func save(_ archive: PresenceArchive, revision: UInt64? = nil) throws {
        if let revision, let written = revisions[archive.routerKey], revision < written { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(archive).write(to: file(archive.routerKey), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(archive.routerKey).path)
        if let revision { revisions[archive.routerKey] = revision }
    }
    /// Copies the history kept under `oldKey` to `newKey` when only the old one exists; the old file stays as it is.
    @discardableResult
    public func adopt(_ oldKey: String, as newKey: String) throws -> Bool {
        guard oldKey != newKey, !FileManager.default.fileExists(atPath: file(newKey).path),
              FileManager.default.fileExists(atPath: file(oldKey).path) else { return false }
        var archive = try load(routerKey: oldKey)
        archive.routerKey = newKey
        try save(archive)
        return true
    }
    /// Copies this router's history from where earlier versions kept it, when its key (`routerKey`) has none yet: under
    /// any address with its hardware address (`address|MAC`), so a changed address, port or protocol keeps it, or
    /// under this address with its model (`address|model`), kept before the router reported a hardware address. The
    /// most recently written such file wins; old files stay as they are. Returns the key it was copied from.
    @discardableResult
    public func adoptEarlier(endpoint: String, hardwareAddress: String?, model: String, as newKey: String) throws -> String? {
        guard !FileManager.default.fileExists(atPath: file(newKey).path),
              FileManager.default.fileExists(atPath: directory.path) else { return nil }
        let mac = hardwareAddress?.uppercased()
        func earlier(_ key: String) -> Bool {
            guard key != newKey, !key.hasPrefix("router|"), let separator = key.lastIndex(of: "|") else { return false }
            if key == endpoint + "|" + model { return true }
            guard let mac else { return false }
            return key[key.index(after: separator)...].uppercased() == mac
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "json" }
        var best: (key: String, date: Date)?
        for url in files {
            guard let data = try? Data(contentsOf: url), data.count <= 20_000_000,
                  let header = try? JSONDecoder().decode(ArchiveHeader.self, from: data), earlier(header.routerKey) else { continue }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if best.map({ date > $0.date }) ?? true { best = (header.routerKey, date) }
        }
        guard let best, try adopt(best.key, as: newKey) else { return nil }
        return best.key
    }
    private struct ArchiveHeader: Decodable { let routerKey: String }

    /// The history of one router: by its hardware address, so a new address, port or protocol for the same router keeps
    /// its history; by address and model when the router does not report one.
    public static func routerKey(endpoint: String, hardwareAddress: String?, model: String) -> String {
        if let mac = hardwareAddress?.uppercased(), mac.range(of: #"^([0-9A-F]{2}:){5}[0-9A-F]{2}$"#, options: .regularExpression) != nil {
            return "router|" + mac
        }
        return endpoint + "|" + model
    }
    private func file(_ key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }
}
