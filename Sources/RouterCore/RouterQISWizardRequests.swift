import Foundation

// 网络设置向导的请求：页面产生的每个写入和有副作用的 GET 照网页的路径、方法、字段顺序和编码发送；App 先确认，发送后读回核对。

// MARK: - Requests

/// One request of the wizard, as the page sends it.
public enum QISRequest: Sendable, Equatable {
    /// httpApi.nvramSet (httpApi.js 227–251): POST applyapp.cgi with encodeURIComponent(JSON.stringify(object)).
    case apply([(String, OrderedJSON)])
    /// httpApi.startAutoDet / startWan46AutoDet (512–522): GET appGet.cgi?hook=name(), which starts a service.
    case hook(String)
    /// A jQuery GET with `data` ($.param) or the query written into the URL; `json` when the page asks for JSON.
    case get(String, [(String, String)], json: Bool)
    /// httpApi.chpass (2306–2332): GET chpass.cgi with $.param of the data, dataType json, synchronous, answer not used.
    case chpass([(String, String)])

    public static func == (a: QISRequest, b: QISRequest) -> Bool {
        switch (a, b) {
        case (.apply(let x), .apply(let y)): x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case (.hook(let x), .hook(let y)): x == y
        case (.get(let p, let x, let j), .get(let q, let y, let k)): p == q && j == k && x.count == y.count && zip(x, y).allSatisfy { $0 == $1 }
        case (.chpass(let x), .chpass(let y)): x.count == y.count && zip(x, y).allSatisfy { $0 == $1 }
        default: false
        }
    }
    public var method: String { if case .apply = self { "POST" } else { "GET" } }
    public var path: String {
        switch self {
        case .apply: "applyapp.cgi"
        case .hook: "appGet.cgi"
        case .get(let path, _, _): path
        case .chpass: "chpass.cgi"
        }
    }
    /// The query as $.param writes it (encodeURIComponent, "%20" as "+").
    public var query: String? {
        switch self {
        case .apply: nil
        case .hook(let name): "hook=" + name + "()"
        case .get(_, let fields, _), .chpass(let fields): String(decoding: RouterAuthentication.orderedForm(fields, .jQuery), as: UTF8.self)
        }
    }
    /// The members the request carries, for showing (secret values masked) and checking.
    public var fields: [(String, String)] {
        switch self {
        case .apply(let members): members.map { ($0.0, TORSettings.javaScriptString($0.1)) }
        case .hook(let name): [("hook", name + "()")]
        case .get(_, let fields, _), .chpass(let fields): fields
        }
    }
    /// rc_service of an applyapp request.
    public var service: String? {
        guard case .apply(let members) = self else { return nil }
        return members.last { $0.0 == "rc_service" }.map { TORSettings.javaScriptString($0.1) }
    }
    static func isSecret(_ name: String) -> Bool {
        ["passwd", "psk", "security", "new_username"].contains { name.contains($0) }
    }
    /// One line for the confirmation: method, path and fields, secrets masked.
    public var summary: String {
        method + " /" + path + "\n" + fields.map { $0.0 + "=" + (Self.isSecret($0.0) ? (($0.1.isEmpty ? "" : "（已填写，不显示）")) : $0.1) }.joined(separator: "\n")
    }
}

/// How an event's requests turned out.
public enum QISRestart: Sendable, Equatable {
    case none
    /// Services restart (the rc_service); the router stays up.
    case services(String)
    /// restart_all after a mode change.
    case restartAll
    case reboot
}

/// Requests an event wants to send: the app confirms them first.
public struct QISSubmission: Sendable, Equatable {
    let outgoing: [QISOutgoing]
    /// The wizard as the page is once the requests are out: requests whose answer the page does not wait for leave it on
    /// the next page already; the callbacks (`then`) run after a successful send.
    public let state: QISWizard
    let then: QISThen
    /// The wizard as it was before the event, kept when the user declines.
    public let before: QISWizard
    public var requests: [QISRequest] { outgoing.map(\.request) }

    /// The restart the last applyapp request asks for.
    public var restart: QISRestart {
        guard let service = requests.last(where: { $0.service != nil })?.service else { return .none }
        if service.contains("reboot") { return .reboot }
        if service == "restart_all" { return .restartAll }
        return service.isEmpty ? .none : .services(service)
    }
    public var changesAdministrator: Bool { requests.contains { if case .chpass = $0 { true } else { false } } }
    /// The statement version the privacy page showed (its ppVersion), which agreeing signs.
    public var privacyVersion: String? { if case .privacy(let status) = before.page { status.privacyVersion } else { nil } }
    /// The LAN address after the change: the static address, "" for an address from DHCP, nil when the LAN is not changed.
    public var lanAddress: String? {
        guard let last = requests.last(where: { $0.service != nil }) else { return nil }
        let fields = Dictionary(last.fields, uniquingKeysWith: { _, new in new })
        guard let proto = fields["lan_proto"] else { return nil }
        return proto == "dhcp" ? "" : fields["lan_ipaddr"]
    }

    public var title: String {
        if requests.contains(where: { $0.path == "set_ASUS_NEW_EULA.cgi" }) { return "同意最终用户许可协议？" }
        if let request = requests.first(where: { $0.path == "set_ASUS_privacy_policy.cgi" }) {
            return request.fields.first?.1 == "1" ? "同意 ASUS 隐私声明？" : "不同意 ASUS 隐私声明？"
        }
        if then == .finish || then == .update {
            if before.page == .update { return "重新启动相关服务？" }
            return "提交网络设置向导的设置？"
        }
        return "按网页提交并重新启动 WAN？"
    }
    /// Whether this is the WAN restart a WAN page sends before Wireless.
    var restartsWANOnly: Bool {
        then == .nothing && requests.contains { ($0.service ?? "").hasPrefix("restart_wan_if") }
    }
    /// What the requests change, in the user's terms.
    public var impact: String {
        var lines: [String] = []
        for request in requests {
            switch request.path {
            case "set_ASUS_NEW_EULA.cgi": lines.append("路由器会记录已同意最终用户许可协议（ASUS_NEW_EULA=1）。")
            case "set_ASUS_privacy_policy.cgi":
                lines.append(request.fields.first?.1 == "1" ? "路由器会记录已同意 ASUS 隐私声明（ASUS_privacy_policy=1）。"
                             : "路由器会记录不同意 ASUS 隐私声明（ASUS_privacy_policy=0）；账号绑定、DDNS、Alexa、远程连接、通知等依赖它的功能可能受限。")
            case "set_security_update.cgi": lines.append("开启安全更新（security_update=1）。")
            case "chpass.cgi":
                lines.append("以 chpass.cgi 修改管理员账号和密码：之后 App 保存的登录信息失效，需要用新的账号和密码重新登录；App 不保存也不记录新密码。网页不检查这一请求的结果，接着提交其余设置。")
            default:
                guard let service = request.service else { continue }
                let fields = Dictionary(request.fields, uniquingKeysWith: { _, new in new })
                if fields["webs_update_enable"] != nil { lines.append("开启自动固件升级（webs_update_enable=1，rc_service=saveNvram）。"); continue }
                if restartsWANOnly {
                    lines.append("网页在这一步立即提交向导到目前为止的全部设置，并重新启动 WAN（rc_service=\(service)）：互联网会中断，通常数十秒；网页不等结果就进入无线设置。")
                    continue
                }
                switch service {
                case "": lines.append("提交全部设置，但暂不重新启动任何服务（rc_service 为空）；之后在固件升级页按“下一步”再重新启动相关服务。")
                case let text where text.contains("reboot"): lines.append("提交全部设置后路由器重新启动（rc_service=reboot），所有连接中断，网页按 \(state.rebootSeconds) 秒等待。")
                case "restart_all": lines.append("提交全部设置后路由器切换回无线路由器模式并重新启动所有服务（rc_service=restart_all），所有连接会中断。")
                default:
                    var parts: [String] = []
                    if service.contains("restart_wireless") { parts.append("Wi-Fi 断开后重新连接") }
                    if service.contains("restart_wan_if") { parts.append("互联网中断数十秒") }
                    if service.contains("restart_subnet") { parts.append("局域网网段改变") }
                    if service.contains("restart_sdn") { parts.append("“网络”(SDN) 中的网络重新建立") }
                    lines.append("提交全部设置并重新启动相关服务（rc_service=\(service)）" + (parts.isEmpty ? "。" : "：" + parts.joined(separator: "、") + "。"))
                }
                if fields["lan_proto"] == "dhcp" { lines.append("局域网地址改为自动获取（lan_proto=dhcp）：重启后路由器的地址由上级路由器分配，App 无法用原地址连接。") }
                else if let ip = fields["lan_ipaddr"], fields["lan_proto"] == "static" { lines.append("局域网地址改为 \(ip)：重启后请在连接设置中改用新地址。") }
                if fields.keys.contains(where: { $0.hasSuffix("_ssid") || $0.hasSuffix("_wpa_psk") || $0.hasPrefix("apm") }) {
                    lines.append("Wi-Fi 名称或密码改变后，已连接的设备需要用新信息重新连接（这台 Mac 若通过 Wi-Fi 连接也一样）。")
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// What qisSubmit says about the administrator account around chpass.cgi.
public enum QISAdministratorChange: Sendable, Equatable {
    /// chpass.cgi is about to be handed to the transport: from now on the account may be changed.
    case mayChange
    /// It provably never reached the router: stopped before sending, or the connection never opened.
    case unchanged
}

/// What came of a submission.
public struct QISReceipt: Sendable {
    /// Where the wizard goes; nil when it stays where it was before the event.
    public var state: QISWizard?
    public var message: String
    public var verified: [String] = []
    public var unverified: [String] = []
    public var restart: QISRestart = .none
    public var changedAdministrator = false
    /// chpass.cgi's statusCode, which the page does not look at.
    public var chpassStatus: String?
    public var lanAddress: String?
    /// Whether the read-back still has to wait for the router to come back.
    public var checkAfterRestart = false
}

public enum QISOutcome: Sendable, Equatable {
    case updated(QISWizard)
    /// A window.confirm: answer it with qisAnswer.
    case confirm(QISQuestion, QISWizard)
    case submit(QISSubmission)
    case leave(QISExit, QISWizard)
}

// MARK: - The firmware check (startLiveUpdate)

public struct QISFirmwareStatus: Sendable, Equatable {
    public var isNewFw: OrderedJSON = .number("0")
    public var newFwVersion = ""
    public var forceLevel = ""
    public var websStateUpdate: String?
}

/// startDetectLinkInternet and startLiveUpdate (plugins.js 2266–2301), run in the background once the user allowed the
/// request: wait (every second) for the router to be online, send the check, then read the firmware state every second
/// (after two) until it is fresh. submitQIS waits on it (handler.js 1464–1490).
public actor QISLiveUpdate {
    /// `stopped`: its page was left, or the wizard or connection moved on; run() carries on with it. `failed`: the check's
    /// request did not go through, and as httpApi.nvramSet calls back only on success (httpApi.js 241–243), the page never
    /// reads its result either.
    public enum Phase: Sendable, Equatable { case waitingForInternet, checking, done, stopped, failed(String) }
    public private(set) var status = QISFirmwareStatus()
    public private(set) var phase: Phase = .waitingForInternet
    /// start_webs_update once it was started: NowTime (plugins.js 2281) and the request itself, whose outcome (nil when it
    /// went through, otherwise why not) every run waits for. It is sent once; a run that comes back while it is still on
    /// its way waits for it rather than reading results the check has not asked for yet.
    private var check: (time: Double, sending: Task<String?, Never>)?
    /// When the result is first read: two seconds after the request went through (its success callback schedules the first
    /// read, plugins.js 2282, 2301). Set by whichever run sees the outcome first; a run that comes back waits what is left.
    private var firstRead: Date?
    /// The latest run; an older one still winding down changes nothing.
    private(set) var runs = 0
    let pause: @Sendable (Double) async throws -> Void
    let clock: @Sendable () -> Date

    public init(pause: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.pause = pause; self.clock = clock
    }

    /// Runs the check, or carries on with it after a stop. `shouldSend` is asked right before start_webs_update goes out,
    /// so a wizard or connection that moved on while the check waited for the internet sends nothing.
    public func run(from wizard: QISWizard, client: RouterClient, shouldSend: @Sendable () async -> Bool = { true }) async {
        switch phase {
        case .done, .failed: return
        default: break
        }
        runs += 1
        let run = runs
        func current() throws { try Task.checkCancellation(); if run != runs { throw CancellationError() } }
        var w = wizard
        phase = check == nil ? .waitingForInternet : .checking
        do {
            if check == nil {
                // startDetectLinkInternet (2266–2272): a read that fails counts as offline, as httpApi.nvramGet answers ""
                // for every name it could not read (httpApi.js 86–88).
                while !((try? await w.isConnected(client)) ?? false) { try current(); try await pause(1); try current() }
                try current()
                guard await shouldSend() else { throw CancellationError() }
                try current()
                let request = QISRequest.apply([("action_mode", .string("apply")), ("webs_update_trigger", .string("QIS")),
                                                ("rc_service", .string("start_webs_update")), ("skip_modify_flag", .string("1"))])
                check = ((clock().timeIntervalSince1970).rounded(.up),
                         Task { do { _ = try await client.qisSend(request); return nil } catch { return error.localizedDescription } })
            }
            guard let check else { return }
            let failure = await check.sending.value
            if let failure {
                if run == runs { phase = .failed(failure) }
                return
            }
            let first = firstRead ?? clock().addingTimeInterval(2)
            firstRead = first
            try current()
            phase = .checking
            let left = first.timeIntervalSince(clock())
            if left > 0 { try await pause(left) }
            while true {
                try current()
                // A read that fails gives "" for every name (httpApi.js 86–88) and the page reads again a second later.
                let info = (try? await w.nvramGet(["webs_state_update", "webs_state_info", "webs_state_flag", "webs_state_level", "webs_update_ts", "apps_sq"],
                                                  force: true, client)) ?? [:]
                try current()
                let stamp = info["webs_update_ts"] ?? ""
                let checked = stamp.isEmpty ? 0 : (javaScriptNumber(javaScriptSplit(stamp, "&#62")[0]) ?? .nan)
                if ["1", "2"].contains(info["webs_state_flag"] ?? "") {
                    status.isNewFw = .string(info["webs_state_flag"] ?? ""); status.newFwVersion = info["webs_state_info"] ?? ""
                    status.forceLevel = info["webs_state_level"] ?? ""
                }
                status.websStateUpdate = info["webs_state_update"] ?? ""
                if check.time - checked > 1800 || status.websStateUpdate != "1" { try await pause(1); continue }
                break
            }
            phase = .done
        } catch is CancellationError {
            if run == runs { phase = .stopped }
        } catch {
            if run == runs { phase = .failed(error.localizedDescription) }
        }
    }

    /// submitQIS's wait: online with fupgrade, up to ten seconds for a new version (1464–1475); otherwise until
    /// webs_state_update is "1", ten seconds at most but started again whenever it reads "0" (1478–1490). Both rely on
    /// startLiveUpdate going on reading (plugins.js 2283–2299). A check that stopped reads nothing until it carries on, and
    /// submitting on what it last read could send what the page would not (it would still be waiting, or would take the
    /// update branch, handler.js 1358–1408): the event ends without a request. A check whose request did not go through is
    /// the page's own case of nothing read, with its ten-second end.
    func waitForSubmit(link: Bool, fupgrade: Bool) async throws -> QISFirmwareStatus {
        try await pause(0.5)
        var count = 0
        while true {
            if phase == .stopped { throw QISFirmwareCheckStopped() }
            if link && fupgrade {
                guard status.newFwVersion.isEmpty, count < 10 else { break }
                count += 1
            } else {
                guard status.websStateUpdate != "1", count < 10 else { break }
                count += 1
                if status.websStateUpdate == "0" { count = 0 }
            }
            try await pause(1)
        }
        return status
    }
}

/// The wizard's final submit found its firmware check stopped.
public struct QISFirmwareCheckStopped: LocalizedError, Sendable {
    public var errorDescription: String? {
        "固件在线检查已停止（离开过这一页，或连接已更换）。网页在这里要等检查结果，所以这次没有提交任何设置；检查接着读取结果后，请再按一次。"
    }
}

public struct QISLiveUpdateLink: Sendable, Equatable {
    public let actor: QISLiveUpdate?
    public init(actor: QISLiveUpdate?) { self.actor = actor }
    public static func == (a: QISLiveUpdateLink, b: QISLiveUpdateLink) -> Bool { a.actor === b.actor }
}

extension QISWizard {
    /// reboot_time, as the pages wait for a reboot.
    public var rebootSeconds: Int {
        let value = javaScriptParseInt(http.nvram.values["reboot_time"] ?? "")
        return value.isNaN || value <= 0 ? 70 : value.clampedInt
    }
    /// The QIS flag the app would open the router's own wizard with for this page.
    public var browserFlag: String? {
        if case .browser(let branch) = page, let flag = branch.flag { return flag }
        return flag.isEmpty ? nil : flag
    }
    /// The side effects still waiting for an answer, taken out.
    public mutating func takeEffects() -> [QISEffect] { defer { effects = [] }; return effects }

    /// The callbacks after a successful send.
    mutating func runThen(_ then: QISThen, _ c: RouterClient) async throws {
        switch then {
        case .nothing: break
        case .privacy: try await goToPP(c)
        case .welcome: goToWelcome()
        case .update: try await goToUpdate(c)
        case .finish: form.withdrawing = false; loadPage(.summary)
        }
    }
}

// MARK: - Driving the wizard

extension RouterClient {
    /// Opens the wizard as QIS_wizard.htm?flag=… does.
    public func qisStart(flag: String = "") async throws -> QISWizard {
        var wizard = QISWizard(flag: flag)
        try await wizard.start(self)
        return wizard
    }

    /// Runs one event on the wizard.
    public func qis(_ wizard: QISWizard, _ event: QISEvent) async throws -> QISOutcome {
        var w = wizard
        w.outbox = []; w.then = .nothing; w.exit = nil
        do {
            try await w.handle(event, self)
        } catch let ask as QISAsk {
            var asking = wizard
            asking.pending = event
            return .confirm(ask.question, asking)
        }
        w.answers = [:]; w.pending = nil
        if let exit = w.exit { w.exit = nil; return .leave(exit, w) }
        if !w.outbox.isEmpty {
            let outgoing = w.outbox, then = w.then
            w.outbox = []; w.then = .nothing
            var before = wizard
            before.answers = [:]; before.pending = nil
            return .submit(QISSubmission(outgoing: outgoing, state: w, then: then, before: before))
        }
        return .updated(w)
    }

    /// The answer to a window.confirm: the interrupted event runs again with it.
    public func qisAnswer(_ wizard: QISWizard, question: QISQuestion, yes: Bool) async throws -> QISOutcome {
        var w = wizard
        guard let event = w.pending else { return .updated(w) }
        w.answers[question.id] = yes
        w.pending = nil
        return try await qis(w, event)
    }

    /// Sends a side effect the page starts itself (after the user allowed it).
    public func qisSend(effect: QISEffect) async throws {
        switch effect {
        case .autoDetect: _ = try await qisSend(.hook("start_force_autodet"))
        case .auto46Detect: _ = try await qisSend(.hook("restart_auto46det"))
        case .liveUpdate: break
        }
    }

    /// The submission's requests in the page's order (a request whose callback leads on stops the rest when it fails), the
    /// read-back of what the router keeps, and the callbacks. It throws only while nothing has been sent; after that,
    /// whatever goes wrong (a request, a callback's reads, the read-back, a cancellation) ends up in the receipt.
    /// `onAdministratorChange` hears `.mayChange` before chpass.cgi is handed to the transport — httpd changes the account
    /// before it answers (web.c 26876, 26884), so the account may change while the answer is still awaited — and
    /// `.unchanged` afterwards only when the request provably never reached the router.
    public func qisSubmit(_ submission: QISSubmission,
                          onAdministratorChange: (@Sendable (QISAdministratorChange) async -> Void)? = nil) async throws -> QISReceipt {
        try Task.checkCancellation()
        try acquireMutation()
        var receipt = QISReceipt(state: nil, message: "")
        var notes: [String] = [], stopped = false, sent: [QISRequest] = []
        do {
            defer { releaseMutation() }
            for outgoing in submission.outgoing {
                let changesAdministrator = { if case .chpass = outgoing.request { true } else { false } }()
                if changesAdministrator { await onAdministratorChange?(.mayChange) }
                var failure: Error?
                do {
                    let answer = try await qisDeliver(outgoing.request)
                    sent.append(outgoing.request)
                    if changesAdministrator { receipt.chpassStatus = answer }
                } catch {
                    failure = error
                }
                if changesAdministrator {
                    if failure.map(Self.mayHaveReachedRouter) ?? true { receipt.changedAdministrator = true }
                    else { await onAdministratorChange?(.unchanged) }
                }
                guard let failure else { continue }
                switch failure {
                case RouterError.submissionUncertain(let reason): sent.append(outgoing.request); notes.append(reason)
                case is CancellationError: notes.append("/\(outgoing.request.path) 没有发出：发送已停止，之后的请求也不再发送。")
                default: notes.append("/\(outgoing.request.path) 没有发出：" + failure.localizedDescription)
                }
                if !outgoing.ignoresAnswer || failure is CancellationError { stopped = true; break }
            }
        }
        receipt.restart = submission.restart
        receipt.lanAddress = submission.lanAddress
        if stopped {
            // The page waits for this answer, so it stays where it is (with what the event already changed in it).
            receipt.state = sent.isEmpty ? nil : submission.state
            receipt.message = notes.joined(separator: " ")
            return receipt
        }
        var w = submission.state
        do {
            try await w.runThen(submission.then, self)
            receipt.state = w
        } catch {
            // The router has the requests; only the reads of the page's next step did not finish.
            receipt.state = submission.state
            notes.append("路由器已接收请求，但读取下一步所需的信息没有完成（\(error.localizedDescription)）。请稍后重新读取核对，不要重复提交。")
        }
        switch submission.restart {
        case .reboot, .restartAll:
            receipt.checkAfterRestart = true
            receipt.message = (notes + ["路由器已接收设置，正在重新启动；恢复连接后再读回核对。"]).joined(separator: " ")
        default:
            if submission.lanAddress != nil {
                receipt.checkAfterRestart = true
                receipt.message = (notes + ["路由器已接收设置。"]).joined(separator: " ")
                return receipt
            }
            do {
                try await Task.sleep(for: .seconds(1))
                let checked = try await qisCheck(sent, privacyVersion: submission.privacyVersion)
                receipt.verified = checked.verified; receipt.unverified = checked.unverified
                receipt.message = (notes + [checked.message]).joined(separator: " ")
            } catch {
                receipt.unverified = Self.qisCheckedNames(sent)
                receipt.message = (notes + ["路由器已接收请求，但暂时无法读回核对。请稍后重新读取，不要重复提交。"]).joined(separator: " ")
            }
        }
        return receipt
    }

    /// Whether a change request that ended with this error may still have reached the router. Only two errors prove it
    /// did not: a stop before sending (RouterClient.request checks cancellation first, RouterClient.swift 132; one stopped
    /// on its way becomes submissionUncertain, 150 and 156–157) and a connection that never opened (a change request gets
    /// `.network` only for URLErrors that prove it unsent, 148–155, URLError.Code.provesRequestUnsent). Any answer — an
    /// HTTP error, a refused session, a reply it cannot read — may come after the handler ran: do_chpass_cgi changes the
    /// account before it writes its answer (web.c 26876, 26884), and the firmware here does not show where httpd refuses
    /// a request before its handler.
    static func mayHaveReachedRouter(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if case .network? = error as? RouterError { return false }
        return true
    }

    /// One request as the page sends it on its own (the live update check), under the client's write checks.
    @discardableResult
    func qisSend(_ request: QISRequest) async throws -> String {
        try acquireMutation(); defer { releaseMutation() }
        return try await qisDeliver(request)
    }

    /// One request as the page sends it; the answer text for chpass (its statusCode), "" otherwise. The caller holds
    /// the mutation (qisSubmit, qisSend).
    @discardableResult
    func qisDeliver(_ request: QISRequest) async throws -> String {
        switch request {
        case .apply(let members):
            try await submitApply(members: members)
            return ""
        case .hook, .get, .chpass:
            let data = try await self.request(request.path, rawQuery: request.query, timeout: 30, changes: true)
            switch request {
            case .get(_, _, json: true), .chpass:
                guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
                    throw RouterError.submissionUncertain("路由器的回应不是网页等待的 JSON，网页在这里不会继续；修改可能已经生效。请重新读取确认，不要重复提交。")
                }
                return ((object as? [String: Any])?["statusCode"]).map { "\($0)" } ?? ""
            default: return ""
            }
        }
    }

    /// The variables the router keeps from the requests (wan_ names under the wan_unit the request sets, httpd's own names
    /// left out), with the values sent.
    static func qisExpectations(_ requests: [QISRequest]) -> [(String, String)] {
        let skipped: Set<String> = ["action_mode", "rc_service", "skip_modify_flag", "cfg_pause", "http_username", "http_passwd", "wan_unit",
                                    "webs_update_trigger"]
        var expected: [(String, String)] = []
        func put(_ key: String, _ value: String) {
            if let at = expected.firstIndex(where: { $0.0 == key }) { expected[at].1 = value } else { expected.append((key, value)) }
        }
        for request in requests {
            switch request {
            case .apply(let members):
                let unit = members.first { $0.0 == "wan_unit" }.map { TORSettings.javaScriptString($0.1) }
                for (name, value) in members where !skipped.contains(name) {
                    let key = name.hasPrefix("wan_") && name != "wan_ifname_x" && unit != nil ? "wan\(unit!)_" + name.dropFirst(4) : name
                    put(key, TORSettings.javaScriptString(value))
                }
            case .get("set_ASUS_NEW_EULA.cgi", let fields, _): for (name, value) in fields { put(name, value) }
            default: break
            }
        }
        return expected.filter { RouterClient.readableKeys([$0.0]).count == 1 }
    }

    /// The names qisCheck reports for the requests.
    static func qisCheckedNames(_ requests: [QISRequest]) -> [String] {
        var names: [String] = []
        if requests.contains(where: { $0.path == "set_ASUS_privacy_policy.cgi" }) { names.append("ASUS_privacy_policy") }
        if requests.contains(where: { $0.path == "set_security_update.cgi" }) { names.append("security_update") }
        return names + qisExpectations(requests).map(\.0)
    }

    /// Reads back what the requests set; the privacy statement and the security update through their own CGIs. Only names
    /// are reported. `privacyVersion` is the version the privacy page showed.
    public func qisCheck(_ requests: [QISRequest], privacyVersion: String? = nil) async throws -> ApplyReceipt {
        var verified: [String] = [], unverified: [String] = []
        func record(_ name: String, _ kept: Bool) { if kept { verified.append(name) } else { unverified.append(name) } }
        if let policy = requests.last(where: { $0.path == "set_ASUS_privacy_policy.cgi" }), let action = policy.fields.first?.1 {
            // privateEula.get (httpApi.js 1073–1122) passes get_ASUS_privacy_policy.cgi's values on (1115–1116). What
            // set_ASUS_privacy_policy.cgi keeps is httpd's own (web.c 480–481 only declare it), so the "1" sent is not what
            // is looked for. The page's "SIGNED" reading (1090–1113) takes a version above "1" with a time as signed and 0
            // with a time as answered (1094): agreeing must leave a signing time and the version the page showed — or a
            // later one, should httpd sign the firmware's current version (compared as numbers) — and refusing must leave
            // 0 with a time. A read that fails is not verified (rather than privateEula.get's default of 0).
            let answer = try? OrderedJSON(data: try await request("get_ASUS_privacy_policy.cgi"))
            let pp = answer?["ASUS_privacy_policy"], time = answer?["ASUS_privacy_policy_time"].map(TORSettings.javaScriptString) ?? ""
            if answer == nil || time.isEmpty { record("ASUS_privacy_policy", false) }
            else if action == "1" {
                if let version = privacyVersion, PolicyTexts.privacy(version: version) != nil, let shown = javaScriptNumber(version),
                   let signed = javaScriptNumber(JavaScriptCompare.text(pp)) {
                    record("ASUS_privacy_policy", signed >= shown)
                } else {
                    record("ASUS_privacy_policy", false)
                }
            } else { record("ASUS_privacy_policy", JavaScriptCompare.looselyZero(pp)) }
        }
        if requests.contains(where: { $0.path == "set_security_update.cgi" }) {
            // securityUpdate.get (httpApi.js 1138–1150): GET get_security_update.cgi, its `security_update`, which the page
            // set to 1 (asus_policy.js 2502). A failed read or another value is not verified.
            let answer = try? OrderedJSON(data: try await request("get_security_update.cgi"))
            record("security_update", javaScriptLooselyEqual(answer?["security_update"], .number("1")))
        }
        let expected = Self.qisExpectations(requests)
        if !expected.isEmpty {
            let values = try await readSettings(expected.map(\.0))
            for (key, value) in expected { record(key, values[key] == value) }
        }
        let notChecked = requests.contains { if case .hook = $0 { true } else if case .chpass = $0 { true } else { false } }
        var message = unverified.isEmpty ? "已从路由器重新读取，\(verified.count) 项与提交的一致。"
            : "路由器已响应，但读回的 " + unverified.joined(separator: "、") + " 与提交的不一致或没有读到。请稍后重新读取核对，不要重复提交。"
        if notChecked { message += " 启动侦测和管理员账号的修改无法从这里读回。" }
        return ApplyReceipt(verified: verified, unverified: unverified, message: message)
    }

    /// nvram_default_get for the names, as appGet answers them (the escapes as nvram_get writes them).
    func qisDefaults(_ keys: [String]) async throws -> [String: String] {
        var result: [String: String] = [:]
        let readable = Self.readableKeys(keys)
        for start in stride(from: 0, to: readable.count, by: 6) {
            let batch = Array(readable[start..<min(start + 6, readable.count)])
            let data = try await request("appGet.cgi", query: [.init(name: "hook", value: batch.map { "nvram_default_get(\($0))" }.joined(separator: ";"))])
            let object = (try? OrderedJSON(data: data)) ?? .object([])
            for key in batch { result[key] = object[key]?.text ?? "" }
        }
        for key in keys where result[key] == nil { result[key] = "" }
        return result
    }
}
