import Foundation
import Testing
@testable import RouterCore

@Test func sendAfterCancelEndsAsCancellationInsteadOfCrashing() async throws {
    let transport = URLSessionRouterTransport(endpoint: try RouterEndpoint("192.168.50.1"))
    let request = URLRequest(url: URL(string: "data:text/plain,ok")!)
    // Before cancellation the session still runs tasks (a data: URL simply is not an HTTP response).
    await #expect(throws: RouterError.invalidResponse("HTTP")) { _ = try await transport.send(request) }
    transport.cancel()
    transport.cancel()
    await #expect(throws: CancellationError.self) { _ = try await transport.send(request) }
}

@Test func aReplyPastTheLimitStopsArrivingInsteadOfFillingMemory() async throws {
    let transport = URLSessionRouterTransport(endpoint: try RouterEndpoint("192.168.50.1"), replyLimit: 100)
    let large = URLRequest(url: URL(string: "data:text/plain;base64," + Data(repeating: 0x41, count: 4096).base64EncodedString())!)
    await #expect(throws: RouterError.invalidResponse("响应大小")) { _ = try await transport.send(large) }
    // A reply within the limit arrives as before (a data: URL is simply not an HTTP response).
    await #expect(throws: RouterError.invalidResponse("HTTP")) { _ = try await transport.send(URLRequest(url: URL(string: "data:text/plain,ok")!)) }
    transport.cancel()
}

@Test func swiftCancellationCancelsTheURLTask() async throws {
    let transport = URLSessionRouterTransport(endpoint: try RouterEndpoint("192.168.50.1"))
    // Port 9 (discard) on a TEST-NET address never answers; cancellation must end the wait promptly.
    let request = URLRequest(url: URL(string: "http://192.0.2.1:9/")!, timeoutInterval: 30)
    let task = Task { try await transport.send(request) }
    try await Task.sleep(for: .milliseconds(200))
    let began = Date()
    task.cancel()
    await #expect(throws: (any Error).self) { _ = try await task.value }
    #expect(Date().timeIntervalSince(began) < 5)
    transport.cancel()
}
