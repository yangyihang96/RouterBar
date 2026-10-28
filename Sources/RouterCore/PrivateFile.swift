import Foundation
import Darwin

/// Writes secrets (private keys, VPN profiles, configuration backups) so that no other account can read them at
/// any moment: the bytes go into a new 0600 file beside the destination, which then replaces the destination.
/// Writing first and restricting afterwards would leave the file readable in between.
public enum PrivateFile {
    public static func write(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).partial")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var failure: POSIXErrorCode?
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 { if errno == EINTR { continue }; failure = POSIXErrorCode(rawValue: errno) ?? .EIO; return }
                offset += written
            }
        }
        if failure == nil, fsync(descriptor) != 0 { failure = POSIXErrorCode(rawValue: errno) ?? .EIO }
        close(descriptor)
        if failure == nil, rename(temporary.path, url.path) != 0 { failure = POSIXErrorCode(rawValue: errno) ?? .EIO }
        if let failure { unlink(temporary.path); throw POSIXError(failure) }
    }
}
