import Foundation
import os

public struct RouterHTTPResponse: Sendable {
    public let data: Data
    public let status: Int
    public init(data: Data, status: Int) { self.data = data; self.status = status }
}
public protocol RouterTransport: Sendable {
    func send(_ request: URLRequest) async throws -> RouterHTTPResponse
    func upload(_ request: URLRequest, file: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> RouterHTTPResponse
    func cancel()
    func cookies() -> [RouterSessionCookie]
    func replaceCookies(_ cookies: [RouterSessionCookie])
}
public extension RouterTransport {
    func upload(_ request: URLRequest, file: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> RouterHTTPResponse {
        var req = request; req.httpBody = try Data(contentsOf: file); return try await send(req)
    }
    func cookies() -> [RouterSessionCookie] { [] }
    func replaceCookies(_ cookies: [RouterSessionCookie]) {}
}

/// An independent ephemeral cookie jar; redirects never carry a session to a different origin.
public final class URLSessionRouterTransport: NSObject, RouterTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private let endpoint: RouterEndpoint
    private let session: URLSession
    private let redirectGuard: RouterRedirectGuard
    private let closed = OSAllocatedUnfairLock(initialState: false)
    private let replyLimit: Int
    public convenience init(endpoint: RouterEndpoint) { self.init(endpoint: endpoint, replyLimit: Self.replyLimit) }
    init(endpoint: RouterEndpoint, replyLimit: Int) {
        self.endpoint = endpoint
        self.replyLimit = replyLimit
        self.redirectGuard = RouterRedirectGuard(origin: endpoint.url)
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 1800
        config.httpMaximumConnectionsPerHost = 2
        self.session = URLSession(configuration: config, delegate: redirectGuard, delegateQueue: nil)
        super.init()
    }
    /// Replies larger than this stop arriving: the task is cancelled as soon as more comes in.
    static let replyLimit = 64_000_000
    static let uploadReplyLimit = 4_000_000

    public func send(_ request: URLRequest) async throws -> RouterHTTPResponse {
        let (data, response) = try await perform(limit: replyLimit, label: "响应大小", progress: nil) { $0.dataTask(with: request) }
        guard let response = response as? HTTPURLResponse else { throw RouterError.invalidResponse("HTTP") }
        return RouterHTTPResponse(data: data, status: response.statusCode)
    }
    public func upload(_ request: URLRequest, file: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> RouterHTTPResponse {
        let (data, response) = try await perform(limit: Self.uploadReplyLimit, label: "上传响应", progress: progress) { $0.uploadTask(with: request, fromFile: file) }
        guard let response = response as? HTTPURLResponse else { throw RouterError.invalidResponse("上传响应") }
        return RouterHTTPResponse(data: data, status: response.statusCode)
    }
    /// Other screens may still hold this client after the store replaced it. Creating a task on an
    /// invalidated URLSession raises an Objective-C exception that Swift cannot catch, so task creation
    /// and invalidation share one lock and late requests end as cancellations instead of crashing.
    public func cancel() {
        guard closed.withLock({ value in defer { value = true }; return !value }) else { return }
        session.invalidateAndCancel()
    }
    /// Runs one task with its own delegate, which counts the reply as it arrives and stops it past `limit`.
    private func perform(limit: Int, label: String, progress: (@Sendable (Double) -> Void)?,
                         _ make: (URLSession) -> URLSessionTask) async throws -> (Data, URLResponse) {
        let pending = PendingTask()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
                let delegate = LimitedReply(origin: endpoint.url, limit: limit, label: label, progress: progress) { continuation.resume(with: $0) }
                let task: URLSessionTask? = closed.withLockUnchecked { isClosed in
                    guard !isClosed else { return nil }
                    let task = make(session)
                    task.delegate = delegate
                    return task
                }
                guard let task else { delegate.finish(.failure(CancellationError())); return }
                pending.start(task, delegate: delegate)
            }
        } onCancel: { pending.cancel() }
    }
    public func cookies() -> [RouterSessionCookie] {
        (session.configuration.httpCookieStorage?.cookies(for: endpoint.url) ?? []).map(RouterSessionCookie.init)
    }
    public func replaceCookies(_ cookies: [RouterSessionCookie]) {
        guard let storage = session.configuration.httpCookieStorage else { return }
        for old in storage.cookies(for: endpoint.url) ?? [] { storage.deleteCookie(old) }
        for cookie in cookies where cookie.belongs(to: endpoint) {
            if let native = cookie.nativeCookie() { storage.setCookie(native) }
        }
    }
}

/// Starts a task once, and never starts one whose Swift task was cancelled before it existed: that request ends
/// as a cancellation without being sent.
private final class PendingTask: Sendable {
    private let state = OSAllocatedUnfairLock<(task: URLSessionTask?, canceled: Bool)>(uncheckedState: (nil, false))
    func start(_ task: URLSessionTask, delegate: LimitedReply) {
        let canceled = state.withLockUnchecked { value in value.task = task; return value.canceled }
        if canceled {
            task.cancel()
            delegate.finish(.failure(CancellationError()))
        } else {
            task.resume()
        }
    }
    func cancel() { state.withLockUnchecked { value in value.canceled = true; return value.task }?.cancel() }
}

/// Collects one reply. Past `limit` bytes (announced or received) the task is cancelled and the request fails with
/// `invalidResponse`; the result is delivered once, whichever comes first.
private final class LimitedReply: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let origin: URL
    private let limit: Int
    private let label: String
    private let progress: (@Sendable (Double) -> Void)?
    private let state: OSAllocatedUnfairLock<(data: Data, response: URLResponse?, exceeded: Bool, done: Bool)>
    private let deliver: @Sendable (Result<(Data, URLResponse), Error>) -> Void
    init(origin: URL, limit: Int, label: String, progress: (@Sendable (Double) -> Void)?,
         deliver: @escaping @Sendable (Result<(Data, URLResponse), Error>) -> Void) {
        self.origin = origin; self.limit = limit; self.label = label; self.progress = progress; self.deliver = deliver
        self.state = OSAllocatedUnfairLock(uncheckedState: (Data(), nil, false, false))
    }
    func finish(_ result: Result<(Data, URLResponse), Error>) {
        guard state.withLockUnchecked({ value in defer { value.done = true }; return !value.done }) else { return }
        deliver(result)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        if response.expectedContentLength > Int64(limit) {
            state.withLockUnchecked { $0.exceeded = true }
            completionHandler(.cancel)
            return
        }
        state.withLockUnchecked { $0.response = response }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let over = state.withLockUnchecked { value -> Bool in
            guard !value.exceeded else { return true }
            if value.data.count + data.count > limit { value.exceeded = true; value.data = Data(); return true }
            value.data.append(data)
            return false
        }
        if over { dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if let progress, totalBytesExpectedToSend > 0 { progress(Double(totalBytesSent) / Double(totalBytesExpectedToSend)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (data, response, exceeded) = state.withLockUnchecked { ($0.data, $0.response ?? task.response, $0.exceeded) }
        if exceeded { finish(.failure(RouterError.invalidResponse(label))) }
        else if let error { finish(.failure(error)) }
        else if let response { finish(.success((data, response))) }
        else { finish(.failure(URLError(.badServerResponse))) }
    }
    /// Uploads are never replayed by redirects, even within the router; other requests follow the session's guard.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        if progress != nil { completionHandler(nil); return }
        completionHandler(request.url.map { RouterRedirectGuard.sameOrigin(origin, $0) } == true ? request : nil)
    }
}

final class RouterRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    let origin: URL
    init(origin: URL) { self.origin = origin }
    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme == b.scheme && a.host == b.host && (a.port ?? (a.scheme == "https" ? 443 : 80)) == (b.port ?? (b.scheme == "https" ? 443 : 80))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url.map { Self.sameOrigin(origin, $0) } == true ? request : nil)
    }
}

