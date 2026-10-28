import Foundation
import Testing
@testable import RouterCore

/// Counts requests and answers every one with an empty page.
private actor PageRouter: RouterTransport {
    var sent = 0
    func send(_ request: URLRequest) async throws -> RouterHTTPResponse {
        sent += 1
        return RouterHTTPResponse(data: Data("<html></html>".utf8), status: 200)
    }
    nonisolated func cancel() {}
}

/// Pages whose serving changes something on the router are never read as plain documents, whatever the session may write.
@Test func pagesThatChangeTheRouterAreNotReadAsDocuments() async throws {
    let router = PageRouter()
    for scope in [WriteScope.unverified, .reference] {
        let client = RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: router, writes: scope)
        for page in ["get_real_ip.asp", "cloud_main.asp", "Advanced_IPv61_Content.asp", "aidisk/Aidisk-3.asp"] {
            await #expect(throws: RouterError.self) { try await client.readManagementDocument(page) }
        }
    }
    #expect(await router.sent == 0)
    // Pages that only read keep working.
    let client = RouterClient(endpoint: try RouterEndpoint("192.168.50.1"), transport: router, writes: .unverified)
    _ = try await client.readManagementDocument("Tools_Sysinfo.asp")
    #expect(await router.sent == 1)
}
