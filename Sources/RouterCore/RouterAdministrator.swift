import Foundation
import CryptoKit

public enum AdministratorChange: Sendable {
    case username(String)
    case password(String)
}
public enum AdministratorProtocol {
    public static func fields(username: String, currentPassword: String, change: AdministratorChange) throws -> [String: String] {
        guard !username.isEmpty, !currentPassword.isEmpty else { throw RouterError.validation("请输入当前管理员密码") }
        func md5(_ value: String) -> String { Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
        var fields = ["cur_username": md5(username), "cur_passwd": md5(currentPassword), "restart_httpd":"1"]
        switch change {
        case .username(let name):
            guard name.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$"#, options: .regularExpression) != nil, !["root","guest","anonymous"].contains(name.lowercased()), name != currentPassword else { throw RouterError.validation("登录名需为 1–32 位字母、数字、横线或下划线，且不能使用保留名称") }
            fields["new_username"] = Data(name.utf8).base64EncodedString()
        case .password(let password):
            guard (10...32).contains(password.utf8.count), password.unicodeScalars.allSatisfy({ (32...126).contains($0.value) }), password != username, password != "admin" else { throw RouterError.validation("新密码请使用 10–32 位可打印英文字符，且不能与登录名相同") }
            fields["new_passwd"] = Data(password.utf8).base64EncodedString()
        }
        return fields
    }
}
extension RouterClient {
    public func changeAdministrator(username: String, currentPassword: String, change: AdministratorChange) async throws {
        try acquireMutation(); defer { releaseMutation() }
        let fields = try AdministratorProtocol.fields(username: username, currentPassword: currentPassword, change: change)
        // The firmware handler accepts both GET and POST. POST keeps credential material out of URLs.
        let data = try await request("chpass.cgi", method: "POST", body: RouterAuthentication.form(fields), contentType: "application/x-www-form-urlencoded", timeout: 30)
        // chpass.cgi changes the account before it writes this reply, so an unreadable reply leaves the result open.
        guard let json = try? RouterParser.json(data) else {
            throw RouterError.submissionUncertain("路由器的回应无法识别，管理员信息可能已经修改。请分别用新旧信息登录核对，不要重复提交。")
        }
        // 401 and 402 are refusals before any change; any other answer cannot tell whether the account changed.
        switch RouterParser.string(json["statusCode"]) {
        case "200": return
        case "401": throw RouterError.validation("当前管理员密码未通过验证，未自动重试。")
        case "402": throw RouterError.locked
        case let code:
            throw RouterError.submissionUncertain("路由器没有确认修改结果（statusCode \(code ?? "缺失")），管理员信息可能已经修改。请分别用新旧信息登录核对，不要重复提交。")
        }
    }
}
