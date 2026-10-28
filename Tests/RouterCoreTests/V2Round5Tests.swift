import Foundation
import Testing
@testable import RouterCore

/// Counts requests and answers every one with an empty page.
private actor SilentRouter: RouterTransport {
    var sent = 0
    func send(_ request: URLRequest) async throws -> RouterHTTPResponse {
        sent += 1
        return RouterHTTPResponse(data: Data("<html></html>".utf8), status: 200)
    }
    nonisolated func cancel() {}
}

// MARK: get_real_ip.asp runs a script on the router

@Test func realIPCheckWaitsForTheWriteChecks() async throws {
    let router = SilentRouter()
    let unverified = RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: router)
    await #expect(throws: RouterError.self) { try await unverified.realIPCheck() }
    await #expect(throws: RouterError.self) { try await unverified.alexaRealIP() }
    let older = RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: router, writes: .verified(branch: .v388, model: "RT-AX86U", menuRead: true))
    await #expect(throws: RouterError.self) { try await older.realIPCheck() }
    // Not as a plain document either.
    let reference = RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: router, writes: .reference)
    await #expect(throws: RouterError.self) { try await reference.readManagementDocument("get_real_ip.asp") }
    #expect(await router.sent == 0)
    _ = try await reference.realIPCheck()
    #expect(await router.sent == 1)
}

// MARK: firmver as the router writes it

@Test func firmwareVersionStringsMatchExactly() {
    for firmver in ["3006", "30.0.6", "3.0.06", "3.0.0.6 ", "v3.0.0.6"] {
        let profile = RouterProfile.make(nvram: ["productid": "RT-X", "firmver": firmver, "buildno": "102.5"], facts: nil)
        #expect(profile?.branch == .unknown, "\(firmver)")
        #expect(!WriteScope(profile: profile, menuRead: true).allowsReferenceWeb)
    }
    #expect(RouterProfile.make(nvram: ["productid": "RT-X", "firmver": "3.0.0.6", "buildno": "102.5"], facts: nil)?.branch == .v3006)
}

// MARK: Output that keeps coming after the child is gone

@Test func boundedProcessStopsReadingOutputThatKeepsComing() async {
    // The shell exits at once; the loop it leaves behind keeps writing to standard output until the pipe closes.
    let start = Date()
    await #expect(throws: BoundedProcess.Failure.timeout) {
        try await BoundedProcess.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "(while :; do echo x; done) & exit 0"],
                                     input: Data(), limits: .init(timeout: 0.5, outputLimit: 200_000_000, memoryLimit: 1 << 30))
    }
    #expect(Date().timeIntervalSince(start) < 2)
}
