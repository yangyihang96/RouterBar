import Foundation
import Testing
@testable import RouterCore

@Test func officialReleaseSelectionUsesModelAndNumericVersion() throws {
    let document = "RT-BE88U_3006_102.9_0.zip RT-BE88U_3006_102.10_0.zip RT-BE88U_3006_102.10_beta1.zip RT-BE96U_3006_102.99_0.zip"
    let release = try MerlinReleaseClient.latest(in: document, model: "RT-BE88U")
    #expect(release.version == "3006.102.10.0")
    #expect(release.downloadURL.host == "sourceforge.net")
    #expect(release.downloadURL.path.contains("/RT-BE88U/Release/"))
    #expect(throws: (any Error).self) { try MerlinReleaseClient.latest(in: document, model: "../../other") }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["ROUTERBAR_VERIFY_PUBLIC_DOWNLOAD"] == "1"))
func officialDownloadCanBePreparedWithoutRouterCredentials() async throws {
    let service = MerlinReleaseClient()
    let release = try await service.latest(model: "RT-BE88U")
    let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("com.yihang.RouterBar/Firmware/Verification-" + UUID().uuidString, isDirectory: true)
    let file = try await service.download(release, directory: folder) { _ in }
    #expect(file.size > 1_000_000)
    #expect(file.sha256.count == 64)
    #expect(file.url.lastPathComponent.hasPrefix("RT-BE88U_"))
    let report: [String: Any] = ["model": release.model, "version": release.version, "file": file.url.path, "bytes": file.size, "sha256": file.sha256, "uploadedToRouter": false]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: folder.deletingLastPathComponent().appendingPathComponent("download-verification.json"), options: .atomic)
}
