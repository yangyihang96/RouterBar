import Foundation

public struct MerlinRelease: Sendable, Equatable {
    public let model: String
    public let filename: String
    public let version: String
    public var downloadURL: URL { URL(string: "https://sourceforge.net/projects/asuswrt-merlin/files/\(model)/Release/\(filename)/download")! }
}

/// Public download service has its own session and never receives router cookies or credentials.
public actor MerlinReleaseClient {
    private let session: URLSession
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 900
        session = URLSession(configuration: config, delegate: ReleaseRedirectGuard(), delegateQueue: nil)
    }
    public static func latest(in document: String, model: String) throws -> MerlinRelease {
        guard model.range(of: #"^[A-Z0-9_-]{3,30}$"#, options: .regularExpression) != nil else { throw RouterError.validation("路由器型号不支持自动下载") }
        let regex = try NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: model) + #"_([0-9]{4})_([0-9]+\.[0-9]+)_([0-9]+)\.zip"#)
        let names = Set(regex.matches(in: document, range: NSRange(document.startIndex..., in: document)).compactMap { Range($0.range, in: document).map { String(document[$0]) } })
        guard let filename = names.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }).first else { throw RouterError.validation("官方源没有返回适用于当前型号的正式固件") }
        let version = filename.dropFirst(model.count + 1).dropLast(4).replacingOccurrences(of: "_", with: ".")
        return MerlinRelease(model: model, filename: filename, version: version)
    }
    public func latest(model: String) async throws -> MerlinRelease {
        guard model.range(of: #"^[A-Z0-9_-]{3,30}$"#, options: .regularExpression) != nil else { throw RouterError.validation("路由器型号无效") }
        var request = URLRequest(url: URL(string: "https://sourceforge.net/projects/asuswrt-merlin/files/\(model)/Release/")!)
        request.setValue("RouterBar/1.2", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, data.count <= 2_000_000 else { throw RouterError.network("暂时无法读取官方固件目录，请稍后再试。") }
        return try Self.latest(in: String(decoding: data, as: UTF8.self), model: model)
    }
    public func download(_ release: MerlinRelease, directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> FirmwareImage {
        // Reconstruct from the strictly parsed filename, never a third-party arbitrary URL.
        let checked = try Self.latest(in: release.filename, model: release.model)
        guard checked == release else { throw RouterError.validation("固件下载信息不一致") }
        let observer = ReleaseDownloadProgress(callback: progress)
        let (temporary, response) = try await session.download(from: release.downloadURL, delegate: observer)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw RouterError.network("固件下载未完成。") }
        let size = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard (1_000_000...256_000_000).contains(size) else { throw RouterError.validation("下载文件大小异常，已停止准备更新") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let archive = directory.appendingPathComponent(UUID().uuidString + ".zip")
        try FileManager.default.moveItem(at: temporary, to: archive)
        defer { try? FileManager.default.removeItem(at: archive) }
        let output = try await Task.detached(priority: .utility) {
            try Self.extractImage(archive: archive, release: release, directory: directory)
        }.value
        return try FirmwareImage.inspect(output, model: release.model)
    }
    static func extractImage(archive: URL, release: MerlinRelease, directory: URL) throws -> URL {
        let listing = Process(); listing.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); listing.arguments = ["-Z1", archive.path]
        let pipe = Pipe(); listing.standardOutput = pipe; listing.standardError = FileHandle.nullDevice
        try listing.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); listing.waitUntilExit()
        guard listing.terminationStatus == 0, data.count < 256_000 else { throw RouterError.validation("固件压缩包无法读取") }
        let names = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
        let expectedPrefix = release.filename.dropLast(4)
        let candidates = names.filter { name in
            !name.hasPrefix("/") && !name.components(separatedBy: "/").contains("..") &&
            URL(fileURLWithPath: name).lastPathComponent.hasPrefix(expectedPrefix) &&
            ["pkgtb", "w", "trx", "bin"].contains(URL(fileURLWithPath: name).pathExtension.lowercased())
        }
        guard candidates.count == 1, let member = candidates.first else { throw RouterError.validation("压缩包中未找到唯一匹配型号与版本的固件") }
        let target = directory.appendingPathComponent(URL(fileURLWithPath: member).lastPathComponent)
        guard !FileManager.default.fileExists(atPath: target.path) else { return target }
        FileManager.default.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600])
        do {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); process.arguments = ["-p", archive.path, member]
            let stream = Pipe(); process.standardOutput = stream; process.standardError = FileHandle.nullDevice
            let file = try FileHandle(forWritingTo: target); defer { try? file.close() }
            try process.run(); var total = 0
            while let chunk = try stream.fileHandleForReading.read(upToCount: 1_048_576), !chunk.isEmpty {
                total += chunk.count
                if total > 512_000_000 { process.terminate(); throw RouterError.validation("解压后的固件过大") }
                try file.write(contentsOf: chunk)
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0, total > 1_000_000 else { throw RouterError.validation("固件解压校验未通过") }
            return target
        } catch { try? FileManager.default.removeItem(at: target); throw error }
    }
}
private class ReleaseRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static func allowed(_ url: URL) -> Bool { url.scheme == "https" && (url.host == "sourceforge.net" || url.host?.hasSuffix(".dl.sourceforge.net") == true || url.host == "downloads.sourceforge.net") }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url.map(Self.allowed) == true ? request : nil)
    }
}
private final class ReleaseDownloadProgress: ReleaseRedirectGuard, URLSessionDownloadDelegate, @unchecked Sendable {
    let callback: @Sendable (Double) -> Void
    init(callback: @escaping @Sendable (Double) -> Void) { self.callback = callback }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > 256_000_000 { downloadTask.cancel(); return }
        if totalBytesExpectedToWrite > 0 { callback(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }
}
