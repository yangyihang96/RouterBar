import Foundation

/// In-memory cookie representation restricted to the configured router origin.
/// Never encoded, persisted, exported, or logged.
public struct RouterSessionCookie: Sendable {
    public let name: String
    public let value: String
    public let domain: String
    public let path: String
    public let secure: Bool
    public let httpOnly: Bool
    public let expires: Date?
    public init(_ cookie: HTTPCookie) {
        name = cookie.name; value = cookie.value; domain = cookie.domain; path = cookie.path
        secure = cookie.isSecure; httpOnly = cookie.isHTTPOnly; expires = cookie.expiresDate
    }
    public func nativeCookie() -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
        if secure { properties[.secure] = "TRUE" }
        if httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)
    }
    public func belongs(to endpoint: RouterEndpoint) -> Bool {
        domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() == endpoint.url.host?.lowercased()
    }
}
