import Foundation
import os

public actor RouterClient {
    /// Version comes from the packaged Info.plist so the request header never drifts from the installed build.
    public static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    public static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15 RouterBar/" + appVersion
    public let endpoint: RouterEndpoint
    private let transport: any RouterTransport
    private var mutationInFlight = false
    /// Nothing is written to a router this session has not identified (RouterStore.readRouterModel).
    public private(set) var writeScope: WriteScope
    var preferredTrafficPath: String?
    /// Every request that changes the router or starts something on it passes here, and nothing goes to a router whose
    /// model, firmware line and web menu this session has not read. Requests written from the 3.0.0.6 web code
    /// (`.referenceWeb`, the default) go only to a 3.0.0.6 router; firmware upload, configuration restore, factory reset,
    /// restart and the network diagnostics (`.identified`), whose handlers are the same on every line from 384 to 3006, to a
    /// router of any of those lines.
    func acquireMutation(_ requirement: WriteRequirement = .referenceWeb) throws {
        if let refusal = writeScope.refusal(for: requirement) { throw RouterError.validation(refusal) }
        guard !mutationInFlight else { throw RouterError.validation("另一项路由器操作尚未结束，请等待完成后重试。") }
        mutationInFlight = true
    }
    func releaseMutation() { mutationInFlight = false }
    public init(endpoint: RouterEndpoint, transport: (any RouterTransport)? = nil, writes: WriteScope = .unverified) {
        self.endpoint = endpoint
        self.transport = transport ?? URLSessionRouterTransport(endpoint: endpoint)
        self.writeScope = writes
    }
    public func setWriteScope(_ scope: WriteScope) { writeScope = scope }
    public func cancel() { transport.cancel() }
    public func sessionCookies() -> [RouterSessionCookie] { transport.cookies() }
    public func adoptSessionCookies(_ cookies: [RouterSessionCookie]) { transport.replaceCookies(cookies) }

    /// Pages whose server-side code changes something on the router while it serves them: get_real_ip.asp runs
    /// getrealip.sh while the router is online, cloud_main.asp's apps_action() sets apps_state_action,
    /// Advanced_IPv61_Content.asp's wan_get_parameter() copies wanN_ to wan_, and aidisk/Aidisk-3.asp clears the DDNS
    /// return code. Never read as plain documents; the pages that need them send them through the write checks
    /// (realIP(), the AiDisk wizard's requests).
    public static let activeDocuments: Set<String> = ["get_real_ip.asp", "cloud_main.asp", "Advanced_IPv61_Content.asp", "aidisk/Aidisk-3.asp"]

    public func readManagementDocument(_ path: String, timeout: TimeInterval = 12) async throws -> String {
        guard !Self.activeDocuments.contains(path) else { throw RouterError.invalidResponse("这一页会让路由器执行脚本，不能当作只读页面读取") }
        return try await managementDocument(path, timeout: timeout, changes: false)
    }
    func managementDocument(_ path: String, timeout: TimeInterval = 12, changes: Bool) async throws -> String {
        guard path.range(of: #"^[A-Za-z0-9_/-]+\.(asp|htm|html|js)$"#, options: .regularExpression) != nil,
              !path.contains("..") else { throw RouterError.invalidResponse("管理文档路径") }
        let data = try await request(path, allowLoginPage: true, timeout: timeout, changes: changes)
        let text = String(decoding: data, as: UTF8.self)
        if (text.contains("login_authorization") && text.contains("name=\"login_passwd\"")) ||
            (text.count < 500 && text.contains("Main_Login.asp")) { throw RouterError.authenticationRequired }
        return text
    }

    public func login(username: String, password: String) async throws {
        let page = try await request("Main_Login.asp", allowLoginPage: true)
        let mode = try RouterAuthentication.mode(from: String(decoding: page, as: UTF8.self))
        var fields = ["group_id": "", "action_mode": "", "action_script": "", "action_wait": "5",
                      "current_page": "Main_Login.asp", "next_page": "index.asp", "login_captcha": ""]
        let path: String
        switch mode {
        case .challenge:
            path = "login_v2.cgi"
            let id = RouterAuthentication.randomString(count: 10)
            let nonceData = try await request("get_Nonce.cgi", method: "POST", body: try JSONSerialization.data(withJSONObject: ["id": id]), contentType: "application/json", allowLoginPage: true)
            let response = try RouterParser.json(nonceData)
            guard let nonce = response["nonce"] as? String, !nonce.isEmpty else { throw RouterError.invalidResponse("登录挑战") }
            let cnonce = RouterAuthentication.randomString(count: 32)
            fields["id"] = id; fields["cnonce"] = cnonce
            fields["login_authorization"] = try RouterAuthentication.authorization(username: username, password: password, nonce: nonce, clientNonce: cnonce)
        case .legacy:
            path = "login.cgi"
            fields["login_authorization"] = Data("\(username):\(password)".utf8).base64EncodedString()
        }
        let loginData = try await request(path, method: "POST", body: RouterAuthentication.form(fields),
                                          contentType: "application/x-www-form-urlencoded", allowLoginPage: true)
        let text = String(decoding: loginData, as: UTF8.self)
        try RouterAuthentication.checkLoginRestrictions(text)
        // A 200 response or cookie alone is not authentication evidence. Read a protected model field.
        do { _ = try await identityData() }
        catch RouterError.authenticationRequired { throw RouterError.invalidCredentials }
    }

    public func sample() async throws -> RouterSample {
        let identityJSON = try await identityData()
        var unavailable: [String] = []
        let xml = try await optional("ajax_status.xml", label: "互联网状态 / 运行时长", unavailable: &unavailable)
            .map { String(decoding: $0, as: UTF8.self) }
        let identity = try RouterParser.identity(identityJSON, status: xml)
        var sample = RouterSample(identity: identity, internet: xml.map(RouterParser.internet) ?? .unknown, uptime: xml.flatMap(RouterParser.uptime))
        if let data = try await optional("appGet.cgi", query: [.init(name: "hook", value: "get_clientlist()")], label: "设备列表", unavailable: &unavailable) {
            do { sample.devices = try RouterParser.clients(data) } catch { unavailable.append("设备列表") }
        }
        if let data = try await optional("cpu_ram_status.asp", label: "CPU / 内存", unavailable: &unavailable) {
            do {
                let stats = try RouterParser.cpuAndMemory(String(decoding: data, as: UTF8.self))
                sample.cpu = stats.cpu; sample.memoryUsedKiB = stats.used; sample.memoryTotalKiB = stats.total
                if stats.used == nil { unavailable.append("内存") }
            } catch { unavailable.append("CPU / 内存") }
        }
        if let data = try await optional("update.cgi", query: [.init(name: "output", value: "netdev")], label: "互联网流量", unavailable: &unavailable) {
            do { sample.traffic = try RouterParser.traffic(String(decoding: data, as: UTF8.self)) }
            catch { unavailable.append("互联网流量") }
        }
        sample.sampledAt = Date(); sample.monotonicTime = ProcessInfo.processInfo.systemUptime
        sample.unavailable = unavailable
        return sample
    }

    func upload(_ path: String, multipart: MultipartUpload, progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url: endpoint.resource(path))
        request.httpMethod = "POST"; request.timeoutInterval = 600
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(endpoint.resource("index.asp").absoluteString, forHTTPHeaderField: "Referer")
        request.setValue(endpoint.displayAddress, forHTTPHeaderField: "Origin")
        request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
        let response: RouterHTTPResponse
        do { response = try await transport.upload(request, file: multipart.file, progress: progress) }
        catch let error as URLError where error.code.provesRequestUnsent {
            throw RouterError.network("无法连接路由器，文件尚未上传。请检查网络后重试。")
        } catch is URLError {
            throw RouterError.submissionUncertain("上传发送后连接中断，结果尚未确认。请检查路由器状态，不要重复上传。")
        } catch is CancellationError {
            throw RouterError.submissionUncertain("上传等待已取消，路由器可能已接收文件。请检查路由器状态，不要重复上传。")
        } catch RouterError.invalidResponse {
            throw RouterError.submissionUncertain("路由器的上传回应无法识别，结果尚未确认。请检查路由器状态，不要重复上传。")
        }
        if response.status == 401 || response.status == 403 || RouterParser.isLoginPage(String(decoding: response.data, as: UTF8.self)) { throw RouterError.authenticationRequired }
        if response.status >= 500 { throw RouterError.submissionUncertain("路由器接收文件后返回 HTTP \(response.status)，结果尚未确认。请检查路由器状态，不要重复上传。") }
        guard (200...299).contains(response.status) else { throw RouterError.httpStatus(response.status) }
        return response.data
    }

    private func identityData() async throws -> [String: Any] {
        let keys = ["productid", "firmver", "buildno", "extendno", "lan_ipaddr", "wan_unit", "lan_hwaddr"]
        let data = try await request("appGet.cgi", query: [.init(name: "hook", value: keys.map { "nvram_get(\($0))" }.joined(separator: ";"))])
        let object = try RouterParser.json(data)
        guard RouterParser.string(object["productid"]) != nil else { throw RouterError.authenticationRequired }
        return object
    }
    private func optional(_ path: String, query: [URLQueryItem] = [], label: String, unavailable: inout [String]) async throws -> Data? {
        do { return try await request(path, query: query) }
        catch RouterError.authenticationRequired { throw RouterError.authenticationRequired }
        catch is CancellationError { throw CancellationError() }
        catch { unavailable.append(label); return nil }
    }
    /// `changes` marks a GET that changes the router (the policy and Ookla CGIs read their values from the query), so a
    /// failure after sending is reported as unconfirmed, like a POST.
    /// `rawQuery` is a query already encoded the way the page encodes it (jQuery's $.param), sent as it is.
    func request(_ path: String, query: [URLQueryItem] = [], rawQuery: String? = nil, method: String = "GET", body: Data? = nil,
                         contentType: String? = nil, allowLoginPage: Bool = false, timeout: TimeInterval = 12, changes: Bool = false) async throws -> Data {
        try Task.checkCancellation()
        var url = endpoint.resource(path, query: query)
        if let rawQuery, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.percentEncodedQuery = rawQuery
            url = parts.url ?? url
        }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = timeout
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(endpoint.resource(allowLoginPage ? "Main_Login.asp" : "index.asp").absoluteString, forHTTPHeaderField: "Referer")
        request.setValue(endpoint.displayAddress, forHTTPHeaderField: "Origin")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        // Login requests are the only POSTs that may return the login page; every other POST changes the router.
        let mutation = changes || (method == "POST" && !allowLoginPage)
        let response: RouterHTTPResponse
        let started = ContinuousClock.now
        defer { Self.log.debug("\(method, privacy: .public) \(Self.summary(path, query: query), privacy: .public) \(started.duration(to: .now).milliseconds, privacy: .public) ms") }
        do { response = try await transport.send(request) }
        catch let error as URLError {
            // A login that fails in transit changes nothing on the router and is simply tried again.
            if mutation, !error.code.provesRequestUnsent { throw RouterError.submissionUncertain("请求发送后连接中断，结果尚未确认。请重新读取，不要重复提交。") }
            if error.code == .cancelled { throw CancellationError() }
            if [.serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot].contains(error.code) {
                throw RouterError.network("路由器 HTTPS 证书未被 macOS 信任。请先在系统中配置可信证书，或使用当前局域网 HTTP 地址。")
            }
            throw RouterError.network("无法连接路由器，请检查当前 Wi-Fi、地址和本地网络权限。")
        } catch is CancellationError {
            if mutation { throw RouterError.submissionUncertain("请求等待已取消，路由器可能已接收修改。请重新读取，不要重复提交。") }
            throw CancellationError()
        } catch RouterError.invalidResponse(let what) {
            // The reply itself was unusable (too large, not HTTP): the request had gone out.
            if mutation { throw RouterError.submissionUncertain("路由器的回应无法使用（\(what)），修改可能已经生效。请重新读取，不要重复提交。") }
            throw RouterError.invalidResponse(what)
        }
        if response.status == 401 || response.status == 403 { throw RouterError.authenticationRequired }
        if mutation, response.status >= 500 { throw RouterError.submissionUncertain("路由器接收请求后返回 HTTP \(response.status)，修改可能已部分生效。请重新读取，不要重复提交。") }
        guard (200...299).contains(response.status) else { throw RouterError.httpStatus(response.status) }
        if !allowLoginPage {
            if RouterParser.isLoginPage(String(decoding: response.data, as: UTF8.self)) { throw RouterError.authenticationRequired }
            if let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any], json["error_status"] != nil {
                throw RouterError.authenticationRequired
            }
        }
        return response.data
    }
}

extension RouterClient {
    /// Request timings for `log stream --level debug --predicate 'subsystem == "com.yihang.RouterBar"'`.
    static let log = Logger(subsystem: "com.yihang.RouterBar", category: "request")
    /// The page and, for appGet.cgi, its hook names without arguments: no setting names, addresses or values.
    static func summary(_ path: String, query: [URLQueryItem]) -> String {
        guard let hook = query.first(where: { $0.name == "hook" })?.value else { return path }
        var counts: [String: Int] = [:], order: [String] = []
        for call in hook.split(separator: ";") {
            let name = String(call.prefix { $0 != "(" })
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        return path + "[" + order.map { name in
            let count = counts[name] ?? 1
            return count > 1 ? "\(name)×\(count)" : name
        }.joined(separator: ",") + "]"
    }
}

extension Duration {
    var milliseconds: Int { Int(components.seconds) * 1000 + Int(components.attoseconds / 1_000_000_000_000_000) }
}

extension URLError.Code {
    /// Failures that happen before a request reaches the router. Any other failure may follow delivery,
    /// so a change request that ends with one is reported as unconfirmed rather than as not applied.
    var provesRequestUnsent: Bool {
        [.cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet, .badURL, .unsupportedURL,
         .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
         .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired,
         .appTransportSecurityRequiresSecureConnection, .internationalRoamingOff, .callIsActive, .dataNotAllowed,
         .fileDoesNotExist, .noPermissionsToReadFile].contains(self)
    }
}

/// What a session may change on its router.
public enum WriteScope: Sendable, Equatable {
    /// The router has not been identified in this session.
    case unverified
    /// Identified: its firmware line and model (`productid`), and whether its own web menu was read.
    case verified(branch: RouterProfile.Branch, model: String, menuRead: Bool)

    public init(profile: RouterProfile?, menuRead: Bool) {
        self = profile.map { .verified(branch: $0.branch, model: $0.model, menuRead: menuRead) } ?? .unverified
    }
    /// Requests written from the reference web code go to a 3.0.0.6 router whose menu was read.
    public var allowsReferenceWeb: Bool { refusal(for: .referenceWeb) == nil }
    /// Why a request written from the reference web code would be refused, or nil.
    public var referenceWebRefusal: String? { refusal(for: .referenceWeb) }
    public var model: String? {
        if case .verified(_, let model, _) = self { return model }
        return nil
    }
    /// The lines whose httpd handles upgrade.cgi, upload.cgi, apply.cgi `Restore` and applyapp.cgi `rc_service` alike
    /// (web.c mime_handlers and do_apply_cgi of 384.14_x, 386_x, 3004.388, 3006.102 and main; audit/firmware-branches-2.0.0).
    static let sharedMaintenanceLines: Set<RouterProfile.Branch> = [.v384, .v386, .v388, .v3006]
    func refusal(for requirement: WriteRequirement) -> String? {
        switch self {
        case .unverified:
            return "还没有核对这台路由器的型号和固件，暂不允许修改。请等连接完成核对后再试。"
        case .verified(let branch, _, let menuRead):
            if !menuRead { return "未能读取这台路由器的网页菜单，无法核对它的网页与固件，暂不允许在 App 内修改。请在浏览器中使用路由器网页。" }
            switch requirement {
            case .referenceWeb where branch != .v3006:
                return "这项修改按 3.0.0.6 固件的网页实现；这台路由器是 \(branch.title) 固件，网页的请求可能不同。请在浏览器中使用路由器网页。"
            case .identified where !Self.sharedMaintenanceLines.contains(branch):
                return "这台路由器的固件（\(branch.title)）不在已核对的分支内，暂不允许在 App 内修改。请在浏览器中使用路由器网页。"
            default:
                return nil
            }
        }
    }
}

/// Which routers a request may go to (RouterClient.acquireMutation).
public enum WriteRequirement: Sendable, Equatable {
    /// Every firmware line from 384 to 3006 handles it the same way: firmware upload, configuration restore, factory
    /// reset, restart, network diagnostics (netool.cgi).
    case identified
    /// Written from the 3.0.0.6 web code.
    case referenceWeb
}
