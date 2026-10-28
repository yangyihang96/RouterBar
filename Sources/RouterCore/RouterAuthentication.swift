import Foundation
import CryptoKit

public enum RouterAuthentication {
    public enum Mode: Sendable { case challenge, legacy }
    public static func mode(from loginHTML: String) throws -> Mode {
        try checkLoginRestrictions(loginHTML)
        if loginHTML.contains("login_v2.cgi") && loginHTML.contains("get_Nonce.cgi") { return .challenge }
        if loginHTML.contains("action=\"login.cgi\"") && loginHTML.contains("login_authorization") { return .legacy }
        throw RouterError.unsupportedLogin
    }
    public static func checkLoginRestrictions(_ html: String) throws {
        let status = RouterParser.capture(#"["']error_status["']\s*:\s*"?(\d+)"#, in: html).flatMap(Int.init) ?? 0
        let count = RouterParser.capture(#"["']error_num["']\s*:\s*(\d+)"#, in: html).flatMap(Int.init) ?? 0
        if status == 7 || status == 11 { throw RouterError.locked }
        if count >= 2 || status == 10 { throw RouterError.captchaRequired }
    }
    public static func authorization(username: String, password: String, nonce: String, clientNonce: String) throws -> String {
        // The observed ASUS JS hash consumes Latin-1 bytes (not UTF-8) and rejects >255 code points.
        let message = "\(username):\(nonce):\(password):\(clientNonce)"
        guard let data = message.data(using: .isoLatin1, allowLossyConversion: false) else { throw RouterError.unsupportedLogin }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func randomString(count: Int) -> String {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var rng = SystemRandomNumberGenerator()
        return String((0..<count).map { _ in alphabet.randomElement(using: &rng)! })
    }
    public static func form(_ fields: [String: String]) -> Data {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let text = fields.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: safe)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: safe)!)"
        }.joined(separator: "&")
        return Data(text.utf8)
    }

    /// The fields in the order a page sends them: jQuery's `$.param` (encodeURIComponent, then "%20" as "+") for
    /// `$.ajax` data, or the browser's application/x-www-form-urlencoded serializer (only alphanumerics and `*-._`
    /// unescaped, space as "+") for a submitted form.
    enum Encoding { case jQuery, formSubmission }
    static func orderedForm(_ fields: [(String, String)], _ encoding: Encoding) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
                                   + (encoding == .jQuery ? "-_.!~*'()" : "*-._") + " ")
        func encode(_ text: String) -> String {
            (text.addingPercentEncoding(withAllowedCharacters: allowed) ?? "").replacingOccurrences(of: " ", with: "+")
        }
        return Data(fields.map { encode($0.0) + "=" + encode($0.1) }.joined(separator: "&").utf8)
    }
}
