import Foundation
import Testing
@testable import RouterCore

/// Counts requests and answers every one with an empty JSON object.
private actor QuietRouter: RouterTransport {
    var sent = 0
    func send(_ request: URLRequest) async throws -> RouterHTTPResponse {
        sent += 1
        return RouterHTTPResponse(data: Data("{}".utf8), status: 200)
    }
    nonisolated func cancel() {}
}

private func profile(firmver: String, buildno: String) -> RouterProfile? {
    RouterProfile.make(nvram: ["productid": "RT-X", "firmver": firmver, "buildno": buildno], facts: nil)
}

// MARK: Firmware lines from the router's own values

@Test func onlyCheckedFirmwareLinesAreRecognised() {
    let known: [(String, String, RouterProfile.Branch)] = [
        ("3.0.0.6", "102", .v3006), ("3.0.0.6", "102.5", .v3006), ("3.0.0.4", "388", .v388), ("3.0.0.4", "388.8", .v388),
        ("3.0.0.4", "386", .v386), ("3.0.0.4", "386.14", .v386), ("3.0.0.4", "384", .v384), ("3.0.0.4", "384.19", .v384),
        ("3.0.0.4", "382", .legacy), ("3.0.0.4", "385", .unknown), ("3.0.0.4", "387", .unknown), ("3.0.0.4", "389", .unknown),
        ("3.0.0.4", "999.1", .unknown), ("3.0.0.6", "", .unknown), ("3.0.0.6", "100", .unknown), ("3.0.0.6", "103", .unknown),
        ("3.0.0.5", "388", .unknown), ("", "388", .unknown)
    ]
    for (firmver, buildno, branch) in known {
        #expect(profile(firmver: firmver, buildno: buildno)?.branch == branch, "\(firmver) \(buildno)")
    }
}

@Test func anUncheckedFirmwareLineWritesNothingEvenWithItsMenuRead() async throws {
    let router = QuietRouter()
    for buildno in ["389", "385", "999.1"] {
        let scope = WriteScope(profile: profile(firmver: "3.0.0.4", buildno: buildno), menuRead: true)
        let client = RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: router, writes: scope)
        await #expect(throws: RouterError.self) { try await client.reboot() }
        await #expect(throws: RouterError.self) { try await client.factoryReset() }
        await #expect(throws: RouterError.self) { try await client.startDiagnostic(method: "3", host: "example.com", version: "v4") }
    }
    let noBuild = WriteScope(profile: profile(firmver: "3.0.0.6", buildno: ""), menuRead: true)
    #expect(!noBuild.allowsReferenceWeb)
    #expect(await router.sent == 0)
}

// MARK: Network diagnostics start something on the router

@Test func networkDiagnosticsWaitForTheWriteChecks() async throws {
    let router = QuietRouter()
    let unverified = RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: router)
    await #expect(throws: RouterError.self) { try await unverified.startDiagnostic(method: "3", host: "example.com", version: "v4") }
    #expect(await router.sent == 0)
    // Every checked line reads the same netool.cgi parameters: an identified 388 router may start one.
    let older = RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: router, writes: .verified(branch: .v388, model: "RT-AX86U", menuRead: true))
    _ = try? await older.startDiagnostic(method: "3", host: "example.com", version: "v4")
    #expect(await router.sent == 1)
}

// MARK: A band whose current auth has no choice the section can save

@Test func encryptionWithoutASaveableChoiceIsShownReadOnly() throws {
    let section = try #require(SettingsCatalog.section("wifi1"))
    let crypto = try #require(section.fields.first { $0.key == "wl1_crypto" })
    let context = WirelessSecurityRules.BandContext(sixGHz: false, wifi7Router: true, wifi7Mode: false)
    let suiteB = WirelessSecurityRules.shownField(crypto, values: ["wl1_auth_mode_x": "suite-b", "wl1_crypto": "suite-b"], unit: 1, context: context)
    #expect(suiteB?.kind == "readonly")
    #expect(suiteB?.note != nil)
    #expect(WirelessSecurityRules.shownField(crypto, values: ["wl1_auth_mode_x": "open"], unit: 1, context: context) == nil)
    let personal = WirelessSecurityRules.shownField(crypto, values: ["wl1_auth_mode_x": "psk2"], unit: 1, context: context)
    #expect(personal?.kind == crypto.kind)
    #expect(personal?.options.map(\.value) == ["aes"])
}

// MARK: Output held open after the child is gone

@Test func boundedProcessStopsWaitingForOutputAProcessItStartedKeepsOpen() async {
    // The shell exits at once; the sleep it leaves behind keeps standard output open for three seconds.
    let start = Date()
    await #expect(throws: BoundedProcess.Failure.timeout) {
        try await BoundedProcess.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 3 & exit 0"], input: Data(),
                                     limits: .init(timeout: 0.5, outputLimit: 1_000, memoryLimit: 1 << 30))
    }
    #expect(Date().timeIntervalSince(start) < 2)
    let cancelled = Date()
    let task = Task {
        try await BoundedProcess.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 3 & exit 0"], input: Data(),
                                     limits: .init(timeout: 20, outputLimit: 1_000, memoryLimit: 1 << 30))
    }
    try? await Task.sleep(for: .milliseconds(300))
    task.cancel()
    await #expect(throws: BoundedProcess.Failure.cancelled) { try await task.value }
    #expect(Date().timeIntervalSince(cancelled) < 2)
}
