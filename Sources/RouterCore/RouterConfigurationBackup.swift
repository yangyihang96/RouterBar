import Foundation
import CryptoKit

public struct ConfigurationBackup: Sendable {
    public let url: URL
    public let size: Int
    public let sha256: String
    public static func inspect(_ url: URL) throws -> ConfigurationBackup {
        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard url.isFileURL, url.pathExtension.lowercased() == "cfg", attributes.isRegularFile == true,
              attributes.isSymbolicLink != true, let size = attributes.fileSize, (9..<32_000_000).contains(size) else {
            throw RouterError.validation("请选择有效的 .CFG 配置文件（小于 32 MB）")
        }
        let data = try Data(contentsOf: url)
        try validate(data)
        return ConfigurationBackup(url: url, size: data.count, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
    public static func validate(_ data: Data) throws {
        guard data.count >= 9 else { throw RouterError.validation("配置文件不完整") }
        let magic = String(decoding: data.prefix(4), as: UTF8.self)
        // RT-BE88U uses Broadcom HDR2; HDR1 is the legacy format accepted by its handler.
        guard ["HDR1", "HDR2"].contains(magic) else { throw RouterError.validation("这不是此机型支持的华硕配置备份") }
        let bytes = Array(data.prefix(8))
        let length = Int(bytes[4]) | Int(bytes[5]) << 8 | Int(bytes[6]) << 16 | (magic == "HDR1" ? Int(bytes[7]) << 24 : 0)
        guard length > 0, length <= data.count - 8 else { throw RouterError.validation("配置文件的长度校验失败，请重新导出备份") }
    }
    enum RestoreReply: Equatable { case accepted, rejected, unrecognized }
    /// upload.cgi answers with Uploading.asp (loading bar, then the router restores and restarts) or, when the file
    /// failed its checks, UploadError.asp (an alert). The rejected file only ever reached a temporary file.
    static func restoreReply(_ data: Data) -> RestoreReply {
        let text = String(decoding: data, as: UTF8.self)
        if text.contains("alert(") { return .rejected }
        return text.contains("parent.showLoadingBar(") && text.contains("parent.detect_httpd()") ? .accepted : .unrecognized
    }
}
