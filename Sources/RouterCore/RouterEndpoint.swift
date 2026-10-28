import Foundation

public enum RouterError: Error, LocalizedError, Sendable, Equatable {
    case invalidAddress, invalidResponse(String), authenticationRequired, invalidCredentials
    case captchaRequired, locked, unsupportedLogin, httpStatus(Int), network(String), validation(String), submissionUncertain(String)
    public var errorDescription: String? {
        switch self {
        case .invalidAddress: "请输入局域网路由器地址，例如 http://192.168.50.1。"
        case .invalidResponse(let section): "路由器返回的\(section)格式暂不支持。"
        case .authenticationRequired: "登录已失效，请重新连接路由器。"
        case .invalidCredentials: "账号或密码未通过验证。请核对后手动重试。"
        case .captchaRequired: "路由器要求验证码，请先等待登录限制解除后在程序内重试。"
        case .locked: "路由器暂时限制登录。自动重试已停止，请等待限制解除后重新连接。"
        case .unsupportedLogin: "未识别这台路由器的登录协议，暂时无法建立连接。"
        case .httpStatus(let code): "路由器返回 HTTP \(code)。"
        case .network(let message), .validation(let message), .submissionUncertain(let message): message
        }
    }
}

public struct RouterEndpoint: Sendable, Equatable {
    public let url: URL
    public init(_ address: String) throws {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard var c = URLComponents(string: input), ["http", "https"].contains(c.scheme?.lowercased() ?? ""),
              let host = c.host?.lowercased(), Self.allowedHost(host), c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil, c.path.isEmpty || c.path == "/",
              c.port == nil || (1...65535).contains(c.port!) else { throw RouterError.invalidAddress }
        c.path = "/"; c.host = host; c.scheme = c.scheme?.lowercased()
        guard let url = c.url else { throw RouterError.invalidAddress }
        self.url = url
    }
    public var displayAddress: String { String(url.absoluteString.dropLast()) }
    public var usesHTTP: Bool { url.scheme == "http" }
    private static func allowedHost(_ host: String) -> Bool {
        if ["router.asus.com", "www.asusrouter.com", "asusrouter.com"].contains(host) { return true }
        if host.hasSuffix(".local"), host.count > 6 { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              parts.compactMap({ Int($0) }).count == 4 else { return false }
        let ip = parts.compactMap { Int($0) }
        guard ip.allSatisfy({ (0...255).contains($0) }) else { return false }
        return ip[0] == 10 || (ip[0] == 192 && ip[1] == 168) || (ip[0] == 172 && (16...31).contains(ip[1]))
    }
    public func resource(_ path: String, query: [URLQueryItem] = []) -> URL {
        var parts = URLComponents(url: url.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            parts.queryItems = query
            // ASUS httpd treats a literal semicolon as a query separator. Its own httpApi.js
            // joins NVRAM hooks with %3B; Foundation leaves semicolons unescaped by default.
            parts.percentEncodedQuery = parts.percentEncodedQuery?
                .replacingOccurrences(of: ";", with: "%3B")
                .replacingOccurrences(of: "+", with: "%2B")
        }
        return parts.url!
    }
}
