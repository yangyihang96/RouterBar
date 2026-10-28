import Foundation
import CryptoKit

public struct FirmwareState: Sendable, Equatable {
    public var latest: String
    public var available: Bool
    public var checking: Bool
    public var downloading: Bool
    public var installing: Bool
    public var progress: Double?
    public var error: String?
    public var raw: [String: String]
    public static func parse(_ script: String) throws -> FirmwareState {
        let script = script.replacingOccurrences(of: "\u{FEFF}", with: "")
        let keys = ["webs_state_update", "webs_state_error", "webs_state_info", "webs_state_flag", "webs_state_upgrade", "cfg_check", "cfg_upgrade", "fwdl_percent", "hndwr_status"]
        var values: [String: String] = [:]
        for key in keys {
            let regex = try NSRegularExpression(pattern: #"(?:^|[\n;])\s*(?:var\s+)?"# + key + #"\s*=\s*["']([^"']*)["']\s*;"#)
            if let match = regex.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)), let range = Range(match.range(at: 1), in: script) { values[key] = String(script[range]) }
        }
        guard values["webs_state_update"] != nil else { throw RouterError.invalidResponse("固件状态") }
        let errors = ["1": "无法连接固件服务器。", "2": "路由器内存不足。", "3": "固件校验失败。"]
        let cfgErrors = ["2": "固件下载失败。", "3": "固件下载失败。", "4": "固件校验失败。"]
        let number = Double((values["fwdl_percent"] ?? "").replacingOccurrences(of: "%", with: ""))
        return FirmwareState(latest: (values["webs_state_info"] ?? "").replacingOccurrences(of: "_", with: "."), available: ["1", "2"].contains(values["webs_state_flag"] ?? ""), checking: values["webs_state_update"] == "0", downloading: values["webs_state_upgrade"] == "0" || ["1", "6", "8"].contains(values["cfg_upgrade"] ?? ""), installing: values["cfg_upgrade"] == "10", progress: number.map { min(100, max(0, $0)) / 100 }, error: errors[values["webs_state_error"] ?? ""] ?? cfgErrors[values["cfg_upgrade"] ?? ""], raw: values)
    }
}
public struct FirmwareImage: Sendable {
    public var url: URL
    public var size: Int64
    public var sha256: String
    public var expectedVersion: String?
    public static func inspect(_ url: URL, model: String) throws -> FirmwareImage {
        let metadata = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard metadata.isRegularFile == true, metadata.isSymbolicLink != true, !model.isEmpty else { throw RouterError.validation("请选择普通固件文件") }
        let name = url.lastPathComponent.lowercased()
        guard ["w", "pkgtb", "trx", "bin"].contains(url.pathExtension.lowercased()), name.contains(model.lowercased()) else { throw RouterError.invalidResponse("请选择文件名包含 \(model) 的已解压固件文件（.w / .pkgtb / .trx / .bin）") }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 1_000_000, size < 512_000_000 else { throw RouterError.invalidResponse("固件文件大小") }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        // The router checks the image itself; these catch a renamed or truncated file before it is sent.
        let kind = url.pathExtension.lowercased()
        let magic = try handle.read(upToCount: 4) ?? Data()
        try handle.seek(toOffset: 0)
        if model == "RT-BE88U", kind != "pkgtb" { throw RouterError.validation("RT-BE88U 需要有效的 .pkgtb 固件映像") }
        // .pkgtb is a flattened device tree (FIT) image; .trx starts with "HDR0".
        if kind == "pkgtb", magic != Data([0xd0, 0x0d, 0xfe, 0xed]) { throw RouterError.validation("所选 .pkgtb 文件不是有效的固件映像") }
        if kind == "trx", magic != Data("HDR0".utf8) { throw RouterError.validation("所选 .trx 文件不是有效的固件映像") }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
        let pattern = NSRegularExpression.escapedPattern(for: model) + #"_([0-9]{4})_([0-9]+\.[0-9]+)_([0-9]+)"#
        let regex = try NSRegularExpression(pattern: pattern)
        var version: String?
        if let match = regex.firstMatch(in: url.lastPathComponent, range: NSRange(url.lastPathComponent.startIndex..., in: url.lastPathComponent)) {
            let parts = (1...3).compactMap { Range(match.range(at: $0), in: url.lastPathComponent).map { String(url.lastPathComponent[$0]) } }
            version = parts.joined(separator: ".")
        }
        return FirmwareImage(url: url, size: size, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(), expectedVersion: version)
    }
}

/// What upgrade.cgi answered. Merlin's httpd sends Updating.asp when it starts flashing, UpdateError.asp when it
/// rejects the image, and UpdateError_reboot.asp when it rejects the image after stopping services and restarts.
enum FirmwareUploadReply: Equatable {
    case flashing, rejected, rejectedRestarting, unrecognized
    init(_ text: String) {
        // Both error pages read upgrade_fw_status; the success page and the restart-after-error page start the loading bar.
        let rejected = text.contains("upgrade_fw_status") || text.contains("UpdateError") || text.contains("upgrade_error")
        let restarting = text.contains("showLoadingBar(") && text.contains("detect_httpd(")
        switch (rejected, restarting) {
        case (false, true): self = .flashing
        case (true, false): self = .rejected
        case (true, true): self = .rejectedRestarting
        case (false, false): self = .unrecognized
        }
    }
}

public struct MultipartUpload: Sendable {
    public let file: URL
    public let contentType: String
    public let sha256: String
    public static func create(file: URL, field: String, fields: [String: String]) throws -> MultipartUpload {
        let boundary = "RouterBar-" + UUID().uuidString
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".upload")
        FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
        do {
            let out = try FileHandle(forWritingTo: destination); defer { try? out.close() }
            func write(_ text: String) throws { try out.write(contentsOf: Data(text.utf8)) }
            for key in fields.keys.sorted() {
                guard key.range(of: #"^[A-Za-z0-9_]+$"#, options: .regularExpression) != nil else { throw RouterError.invalidResponse("上传字段") }
                try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(fields[key]!)\r\n")
            }
            let name = file.lastPathComponent.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
            guard field.range(of: #"^[A-Za-z0-9_]+$"#, options: .regularExpression) != nil else { throw RouterError.invalidResponse("上传字段") }
            try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"; filename=\"\(name)\"\r\nContent-Type: application/octet-stream\r\n\r\n")
            let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
            var hash = SHA256()
            while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk); try out.write(contentsOf: chunk) }
            try write("\r\n--\(boundary)--\r\n")
            return MultipartUpload(file: destination, contentType: "multipart/form-data; boundary=\(boundary)", sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
}

extension RouterClient {
    public func firmwareState() async throws -> FirmwareState {
        let data = try await request("detect_firmware.asp")
        return try FirmwareState.parse(String(decoding: data, as: UTF8.self))
    }
    public func firmwareDownloadState() async throws -> FirmwareState {
        let data = try await request("ajax_fwdl_percent.asp")
        return try FirmwareState.parse(String(decoding: data, as: UTF8.self))
    }
    public func checkFirmware() async throws {
        try acquireMutation(); defer { releaseMutation() }
        // Merlin's actual page invokes start_webs_update for this branch.
        _ = try await submitApply(["action_mode": "apply", "rc_service": "start_webs_update", "webs_update_trigger": "FWUG"])
    }
    public func firmwareReleaseNotes() async throws -> String {
        let data = try await request("get_release_note0.asp")
        let text = String(decoding: data, as: UTF8.self)
        return text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
    }
    public func installFirmware(_ image: FirmwareImage, model: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        try acquireMutation(.identified); defer { releaseMutation() }
        let identity = try await readSettings(["productid"])
        guard identity["productid"] == model else { throw RouterError.validation("当前连接的路由器型号与所选固件不一致") }
        let checked = try FirmwareImage.inspect(image.url, model: model)
        guard checked.size == image.size, checked.sha256 == image.sha256 else { throw RouterError.invalidResponse("固件文件在确认后发生变化，请重新选择") }
        let multipart = try MultipartUpload.create(file: image.url, field: "file", fields: ["current_page": "Advanced_FirmwareUpgrade_Content.asp", "next_page": "", "action_mode": "", "action_script": "", "action_wait": ""])
        defer { try? FileManager.default.removeItem(at: multipart.file) }
        guard multipart.sha256 == image.sha256 else { throw RouterError.validation("固件在准备上传时发生变化，操作已取消") }
        let data = try await upload("upgrade.cgi", multipart: multipart, progress: progress)
        switch FirmwareUploadReply(String(decoding: data, as: UTF8.self)) {
        case .flashing: return
        case .rejected: throw RouterError.validation("路由器拒绝了这个固件文件（未通过校验），没有刷写，仍在运行原来的固件。")
        case .rejectedRestarting: throw RouterError.submissionUncertain("路由器拒绝了这个固件文件，没有刷写；它正在重新启动以恢复服务。请等待恢复后核对版本，不要重复上传。")
        case .unrecognized: throw RouterError.submissionUncertain("固件上传后未收到刷写确认；请检查路由器状态，不要重复上传。")
        }
    }
    public func exportConfiguration(model: String, removePasswords: Bool) async throws -> Data {
        guard model.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { throw RouterError.invalidResponse("路由器型号") }
        let data = try await request("Settings_\(model).CFG", query: [.init(name: "path", value: "0"), .init(name: "remove_passwd", value: removePasswords ? "1" : "0")], timeout: 60)
        try ConfigurationBackup.validate(data)
        return data
    }
    public func restoreConfiguration(_ backup: ConfigurationBackup, progress: @escaping @Sendable (Double) -> Void) async throws {
        try acquireMutation(.identified); defer { releaseMutation() }
        let checked = try ConfigurationBackup.inspect(backup.url)
        guard checked.sha256 == backup.sha256, checked.size == backup.size else { throw RouterError.validation("配置文件在确认后发生变化，请重新选择") }
        let multipart = try MultipartUpload.create(file: backup.url, field: "file", fields: [:])
        defer { try? FileManager.default.removeItem(at: multipart.file) }
        guard multipart.sha256 == backup.sha256 else { throw RouterError.validation("配置文件在准备上传时发生变化，操作已取消") }
        switch ConfigurationBackup.restoreReply(try await upload("upload.cgi", multipart: multipart, progress: progress)) {
        case .accepted: return
        case .rejected: throw RouterError.validation("路由器拒绝了这个配置文件，没有进行恢复，现有配置保持不变。请确认文件来自同型号的路由器。")
        case .unrecognized: throw RouterError.submissionUncertain("路由器未确认接受配置恢复，可能正在恢复并重新启动。请等待几分钟后检查路由器状态，不要重复上传。")
        }
    }
    public func reboot() async throws { try acquireMutation(.identified); defer { releaseMutation() }; _ = try await submitApply(["action_mode": "apply", "rc_service": "reboot"]) }
    public func factoryReset() async throws {
        try acquireMutation(.identified); defer { releaseMutation() }
        // httpd stops USB apps (waiting up to two minutes) before it replies with Restarting.asp.
        _ = try await request("apply.cgi", method: "POST", body: RouterAuthentication.form(["action_mode": "Restore"]), contentType: "application/x-www-form-urlencoded", timeout: 150)
    }
    public func setVPNRunning(kind: String, unit: Int, running: Bool) async throws {
        try acquireMutation(); defer { releaseMutation() }
        guard ["vpnclient", "vpnserver", "wgc"].contains(kind), (1...(kind == "vpnserver" ? 2 : 5)).contains(unit) else { throw RouterError.invalidResponse("VPN 实例") }
        let service = (running ? "start_" : "stop_") + kind + (kind == "wgc" ? " " : "") + String(unit)
        _ = try await submitApply(["action_mode": "apply", "rc_service": service])
    }
    public func readDiagnostic(_ kind: String) async throws -> String {
        if kind == "syslog" { return String(decoding: try await request("syslog.txt"), as: UTF8.self) }
        let allowed = ["routes": "Main_RouteStatus_Content.asp", "connections": "ajax_conntrack.asp"]
        guard let path = allowed[kind] else { throw RouterError.validation("请选择支持的日志类型") }
        let source = String(decoding: try await request(path), as: UTF8.self)
        let names = kind == "routes" ? ["routearray", "routev6array"] : ["connarray", "connarray_route"]
        var sections: [String] = []
        for name in names {
            let rows = try RouterParser.stringRows(named: name, in: source)
            let heading = kind == "routes" ? (name == "routearray" ? "IPv4 路由":"IPv6 路由") : (name == "connarray" ? "NAT 连接":"路由连接")
            sections.append(heading + "\n" + (rows.isEmpty ? "没有记录" : rows.map { $0.joined(separator: "    ") }.joined(separator: "\n")))
        }
        return sections.joined(separator: "\n\n")
    }
}
