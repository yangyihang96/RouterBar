import Combine
import Foundation

// 网络设置向导在 App 里的运行：开始、按钮、确认框的回答、侦测页的计时器、页面自己发的请求和提交，全部按先后一个接一个执行，
// 每一件都记下开始时的“代次”和连接。重新开始、离开页面、连接断开都会换代：排着的跳过，正在读取的取消，晚到的结果丢弃——
// 不采用它的页面，不显示它带来的确认框和待确认请求，也不发出它带来的侦测请求。用户的操作优先于侦测页的计时器：正在读或排着的
// 一次计时读取作废，用户的操作照常执行。固件检查离开页面时停下，回来时接着读结果，不再重发检查。已经开始发送的提交照常做完
// （请求可能已到路由器），只是结果不再显示到别的向导上；chpass.cgi 交给发送层之前就通知 App 停用保存的登录信息，只有确定没发出
// 才恢复。

/// What the app around the wizard provides.
@MainActor
public protocol QISHost: AnyObject {
    /// The client of the current connection; throws when there is none.
    func qisClient() throws -> RouterClient
    /// Another router operation (a save, a restart) is under way; the detection timers wait for it.
    var qisOperationInProgress: Bool { get }
    func qisBeginOperation(_ title: String) -> Bool
    func qisEndOperation()
    /// An error from the router, for the connection's own handling (an expired login).
    func qisManagementError(_ error: Error)
    /// chpass.cgi is about to go out. From now on the saved login must not be tried again, even if the app ends before its
    /// answer or the rest of the submission fails or stops; the session itself stays for the requests the page still sends.
    func qisAdministratorMayHaveChanged()
    /// chpass.cgi provably never reached the router: what qisAdministratorMayHaveChanged set goes back as it was.
    func qisAdministratorUnchanged()
    /// The submission with chpass.cgi is over: the saved login no longer works; the user signs in with the new account.
    func qisAdministratorChanged()
    /// The submission went out: the WANs (wans_dualwan) and Wi-Fi it may have changed are read again by the connection.
    func qisSettingsMayHaveChanged()
    /// The router's uptime last read, for the restart wait.
    var qisUptime: TimeInterval { get }
    func qisAwaitRestart(_ client: RouterClient, from uptime: TimeInterval, checks: Int) async -> QISRestartWait
    /// MLO.asp, where 上一步 of the wizard's MLO entry leads.
    func qisOpenMLOPage()
}
public extension QISHost {
    func qisSettingsMayHaveChanged() {}
}

public enum QISRestartWait: Sendable, Equatable { case back, signInFailed(String), notConfirmed }

public struct QISNotice: Sendable, Equatable {
    public enum Tone: Sendable, Equatable { case success, information, attention, error }
    public let message: String
    public let tone: Tone
    public init(_ message: String, _ tone: Tone) { self.message = message; self.tone = tone }
}

/// An answer given in a notice that has to close first (the privacy withdrawal notice), kept with the wizard, connection
/// and page it was given on until it runs.
public struct QISDeferredEvent: Sendable {
    let id = UUID()
    let ticket: QISController.Ticket
    let page: QISPage
    let event: QISEvent
}

@MainActor
public final class QISController: ObservableObject {
    @Published public private(set) var wizard: QISWizard?
    /// The page before a branch the app leaves to the browser, for 返回向导上一页.
    @Published public private(set) var beforeBranch: QISWizard?
    @Published public private(set) var loading = false
    @Published public private(set) var busy: String?
    @Published public private(set) var notice: QISNotice?
    /// window.alert texts, shown one at a time.
    @Published public private(set) var alerts: [String] = []
    /// A window.confirm waiting for its answer.
    @Published public private(set) var question: QISQuestion?
    /// Requests waiting for the user's confirmation, and an identity that changes with each.
    @Published public private(set) var submission: QISSubmission?
    public private(set) var submissionID = UUID()
    /// The side effects the page starts itself, waiting for the user's answer, and that answer for this wizard.
    @Published public private(set) var asked: [QISEffect] = []
    @Published public private(set) var consent: Bool?
    /// The privacy statement's withdrawal notice.
    @Published public var withdrawShown = false
    @Published public private(set) var finished = false

    public weak var host: (any QISHost)?
    let pause: @Sendable (Double) async throws -> Void

    /// The wizard (generation) and the connection a piece of work belongs to.
    struct Ticket { let generation: Int; let client: RouterClient }
    private var generation = 0
    private var sessionClient: RouterClient?
    private var tail: Task<Void, Never>?
    /// Queued work that leaving the page cancels: everything but a submission.
    private var cancellable: [UUID: Task<Void, Never>] = [:]
    private var busyOwner: UUID?
    /// The wizard whose event the question interrupted, and the ticket of the question or submission on screen.
    private var asking: QISWizard?
    private var shownUnder: Ticket?
    /// This wizard's firmware check, once the user allowed it; leaving the page stops its task but keeps it for resume().
    private var liveUpdate: QISLiveUpdate?
    private var liveTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var pollEpoch = 0
    /// The latest timer run, which a user action cancels.
    private var tickTask: Task<Void, Never>?
    /// Answers taken by deferAnswer and not run yet.
    private var deferred: Set<UUID> = []
    private var administratorPending = false

    public init(pause: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.pause = pause
    }

    var current: Ticket? { sessionClient.map { Ticket(generation: generation, client: $0) } }
    /// Whether work of this ticket may still change what the page shows or send what it brings.
    func isCurrent(_ ticket: Ticket) -> Bool {
        guard ticket.generation == generation, let client = try? host?.qisClient() else { return false }
        return client === ticket.client
    }

    // MARK: Lifecycle

    /// Opens the wizard as QIS_wizard.htm?flag=… does; whatever the previous one was doing is dropped.
    public func start(flag: String) {
        reset()
        consent = nil; finished = false; withdrawShown = false; alerts = []
        sessionClient = try? host?.qisClient()
        guard let ticket = current else { return }
        loading = true
        enqueue(cancellable: true) { [self] in
            defer { if ticket.generation == generation { loading = false } }
            guard isCurrent(ticket) else { return }
            do {
                let w = try await ticket.client.qisStart(flag: flag)
                guard isCurrent(ticket) else { return }
                adopt(w, ticket)
            } catch {
                fail(error, ticket, prefix: "网络设置向导没有读取完成：")
            }
        }
    }
    /// Leaving the page, or starting again: queued work is skipped, reads in flight are cancelled and their answers
    /// dropped, the timers and the firmware check stop. A submission already being sent goes on to its end.
    public func stop() {
        generation += 1
        for task in cancellable.values { task.cancel() }
        cancellable = [:]; tickTask = nil; deferred = []
        stopPolling()
        liveTask?.cancel(); liveTask = nil
        busy = nil; busyOwner = nil; loading = false
        question = nil; asking = nil; submission = nil; shownUnder = nil; asked = []
    }
    /// Ends this wizard altogether, its firmware check included.
    private func reset() { stop(); wizard = nil; beforeBranch = nil; liveUpdate = nil }
    /// Back on the page: the timer of a polling page runs again, and the firmware check carries on where it stopped —
    /// reading the result of a check that went out, never sending it twice.
    public func resume() {
        if restartIfSessionChanged() { return }
        guard let ticket = current else { return }
        restartPolling(ticket)
        if let w = wizard, liveUpdate != nil { runLiveUpdate(ticket, from: w) }
    }
    /// The connection was replaced without the page seeing it go: what the wizard holds was read under the old session,
    /// so it is read again rather than used with the new one.
    private func restartIfSessionChanged() -> Bool {
        guard let session = sessionClient, let client = try? host?.qisClient(), client !== session else { return false }
        start(flag: wizard?.flag ?? "")
        notice = QISNotice("连接已经更换，网络设置向导已重新读取。", .information)
        return true
    }
    /// The connection went away: the wizard read under it goes too, and is read again with the next one.
    public func disconnected() { reset(); sessionClient = nil }
    /// 完成 on the summary page.
    public func close() { reset(); finished = false }
    public func dismissAlert() { if !alerts.isEmpty { alerts.removeFirst() } }

    // MARK: Events

    /// A button, choice or box of the page; it applies to the page it was made on.
    public func perform(_ event: QISEvent) {
        guard busy == nil, question == nil, submission == nil, !restartIfSessionChanged(), let page = wizard?.page, let ticket = current else { return }
        let owner = claimBusy(event == .next ? "正在处理…（最终提交前会按网页等待固件检查结果）" : "正在处理…")
        overrideTimer()
        enqueue(cancellable: true) { [self] in
            defer { releaseBusy(owner); resumeTimer(ticket) }
            guard isCurrent(ticket), let w = wizard, w.page == page else { return }
            do {
                let outcome = try await ticket.client.qis(w, event)
                guard isCurrent(ticket) else { return }
                handle(outcome, ticket)
            } catch {
                fail(error, ticket)
            }
        }
    }
    /// Typing: the wizard takes it at once; its change handler runs before the next button.
    public func edit(_ field: QISFieldID, _ value: String) { wizard?.edit(field, value) }
    public func editWireless(_ unit: String, ssid: Bool, _ value: String) { wizard?.editWireless(unit, ssid: ssid, value) }

    /// The answer to the window.confirm on screen: the interrupted event runs again with it.
    public func answer(_ yes: Bool) {
        guard !restartIfSessionChanged(), let q = question, let w = asking, let ticket = shownUnder else { return }
        question = nil; asking = nil; shownUnder = nil
        let owner = claimBusy("正在处理…")
        overrideTimer()
        enqueue(cancellable: true) { [self] in
            defer { releaseBusy(owner); resumeTimer(ticket) }
            guard isCurrent(ticket) else { return }
            do {
                let outcome = try await ticket.client.qisAnswer(w, question: q, yes: yes)
                guard isCurrent(ticket) else { return }
                handle(outcome, ticket)
            } catch {
                fail(error, ticket)
            }
        }
    }

    /// An answer in a notice that has to close before anything else can show (the privacy withdrawal notice): taken when
    /// its button is pressed, with the wizard, connection and page it belongs to, and run by perform(_:) once the notice
    /// has gone.
    public func deferAnswer(_ event: QISEvent) -> QISDeferredEvent? {
        guard let ticket = current, let page = wizard?.page else { return nil }
        let answer = QISDeferredEvent(ticket: ticket, page: page, event: event)
        deferred.insert(answer.id)
        return answer
    }
    /// Runs an answer taken by deferAnswer, unless the page was left meanwhile (stop() drops every answer still waiting)
    /// or the wizard, the connection or the page is no longer the one it was given on.
    public func perform(_ answer: QISDeferredEvent) {
        guard deferred.remove(answer.id) != nil, isCurrent(answer.ticket), wizard?.page == answer.page else { return }
        perform(answer.event)
    }

    /// 返回向导上一页 from a branch left to the browser.
    public func returnFromBranch() {
        guard var w = beforeBranch, let ticket = current else { return }
        beforeBranch = nil
        w.liveUpdate = QISLiveUpdateLink(actor: liveUpdate)
        wizard = w
        withdrawShown = w.form.withdrawing
        restartPolling(ticket)
    }

    private func handle(_ outcome: QISOutcome, _ ticket: Ticket) {
        switch outcome {
        case .updated(let w): adopt(w, ticket)
        case .confirm(let q, let w): asking = w; shownUnder = ticket; question = q
        case .submit(let s): alerts += s.state.alerts; shownUnder = ticket; submissionID = UUID(); submission = s
        case .leave(let exit, let w):
            adopt(w, ticket)
            stopPolling()
            wizard = nil
            switch exit {
            case .back: notice = QISNotice("网页在这里返回浏览器的上一页，离开了向导。", .information)
            case .mloPage: host?.qisOpenMLOPage()
            case .done: break
            }
        }
    }
    /// Takes a state: the firmware check stays attached, alerts and side effects come out, the page's timer starts over.
    private func adopt(_ state: QISWizard, _ ticket: Ticket) {
        var w = state
        w.liveUpdate = QISLiveUpdateLink(actor: liveUpdate)
        alerts += w.alerts
        let effects = w.takeEffects()
        if case .browser = w.page, let shown = wizard, !Self.isBrowser(shown) { beforeBranch = shown }
        wizard = w
        withdrawShown = w.form.withdrawing
        restartPolling(ticket)
        handle(effects, ticket)
    }
    static func isBrowser(_ w: QISWizard) -> Bool { if case .browser = w.page { true } else { false } }

    // MARK: The page's own requests

    /// 照网页发送 or 不发送, for the rest of this wizard.
    public func decide(send: Bool) {
        guard !restartIfSessionChanged(), let ticket = current else { return }
        consent = send
        let effects = asked; asked = []
        if send { sendEffects(effects, ticket) }
    }
    private func handle(_ effects: [QISEffect], _ ticket: Ticket) {
        guard !effects.isEmpty else { return }
        switch consent {
        case true?: sendEffects(effects, ticket)
        case false?: break
        case nil: for effect in effects where !asked.contains(effect) { asked.append(effect) }
        }
    }
    private func sendEffects(_ effects: [QISEffect], _ ticket: Ticket) {
        for effect in effects {
            if effect == .liveUpdate { startLiveUpdate(ticket); continue }
            enqueue(cancellable: true) { [self] in
                // Only for the wizard and connection it came from, checked right before it goes out.
                guard isCurrent(ticket) else { return }
                do { try await ticket.client.qisSend(effect: effect) }
                catch is CancellationError {}
                catch { if isCurrent(ticket) { notice = QISNotice("侦测请求没有完成：\(error.localizedDescription)", .attention) } }
            }
        }
    }
    /// The firmware check, once per wizard.
    private func startLiveUpdate(_ ticket: Ticket) {
        guard liveUpdate == nil, isCurrent(ticket), let w = wizard else { return }
        liveUpdate = QISLiveUpdate(pause: pause)
        wizard?.liveUpdate = QISLiveUpdateLink(actor: liveUpdate)
        runLiveUpdate(ticket, from: w)
    }
    /// Runs (or carries on with) the firmware check in the background. Its POST waits for the router to be online, so
    /// right before it goes out the check asks again whether this wizard and connection are still current.
    private func runLiveUpdate(_ ticket: Ticket, from w: QISWizard) {
        guard let actor = liveUpdate else { return }
        liveTask?.cancel()
        let client = ticket.client
        let shouldSend: @Sendable () async -> Bool = { [weak self] in await self?.isCurrent(ticket) ?? false }
        liveTask = Task { await actor.run(from: w, client: client, shouldSend: shouldSend) }
    }

    // MARK: The detection pages' timers

    /// Starts the page's timer again from now (or stops it on a page without one).
    private func restartPolling(_ ticket: Ticket) {
        stopPolling()
        guard wizard?.pollInterval != nil else { return }
        let epoch = pollEpoch
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.wizard?.pollInterval, let pause = self?.pause else { return }
                do { try await pause(interval) } catch { return }
                guard !Task.isCancelled, let self else { return }
                await self.tick(ticket, epoch: epoch).value
            }
        }
    }
    private func stopPolling() { pollEpoch += 1; pollTask?.cancel(); pollTask = nil }
    /// Whether the page's timer is armed.
    var timerRunning: Bool { pollTask != nil }
    /// A user action comes first: the timer run reading now, or waiting its turn, is dropped (its answer is never taken),
    /// so the action runs on the page it was made on instead of being lost to a tick that moved the page on. The page
    /// reads synchronously (httpApi.js 77), so there a click and a timer run never overlap either.
    private func overrideTimer() { stopPolling(); tickTask?.cancel(); tickTask = nil }
    /// After a user action that took no new state (it was dropped, failed or asked a question): the page's timer again.
    private func resumeTimer(_ ticket: Ticket) { if pollTask == nil, isCurrent(ticket) { restartPolling(ticket) } }

    /// One run of the page's timer, in turn with everything else; skipped while the page waits for the user or another
    /// operation runs, or once its timer was started over.
    @discardableResult
    func tick(_ ticket: Ticket? = nil, epoch: Int? = nil) -> Task<Void, Never> {
        let ticket = ticket ?? current, epoch = epoch ?? pollEpoch
        let task = enqueue(cancellable: true) { [self] in
            guard let ticket, isCurrent(ticket), epoch == pollEpoch, let w = wizard, w.pollInterval != nil, busy == nil, question == nil,
                  submission == nil, asked.isEmpty, host?.qisOperationInProgress == false else { return }
            // Whatever this run brings back — a state or an error — counts only while it is still the page's current run: a
            // user action makes it stale (overrideTimer) without changing the ticket, and an answer already on its way can
            // still come back as an HTTP error rather than a CancellationError (RouterClient.swift 160–162).
            do {
                let outcome = try await ticket.client.qis(w, .tick)
                guard isCurrent(ticket), epoch == pollEpoch, !Task.isCancelled else { return }
                handle(outcome, ticket)
            } catch is CancellationError {
            } catch {
                guard isCurrent(ticket), epoch == pollEpoch, !Task.isCancelled else { return }
                stopPolling()
                notice = QISNotice("侦测状态没有读取完成：\(error.localizedDescription)", .attention)
                host?.qisManagementError(error)
            }
        }
        tickTask = task
        return task
    }

    // MARK: Sending

    public func cancelSubmission() { submission = nil; shownUnder = nil }
    /// 确认发送: the requests go out in turn, if the wizard and connection are still the ones they were made for. Once
    /// sending has started it is not cancelled.
    public func confirmSubmission() {
        guard !restartIfSessionChanged(), let s = submission, let ticket = shownUnder else { return }
        submission = nil; shownUnder = nil
        enqueue(cancellable: false) { [self] in await run(s, ticket) }
    }
    func administratorChange(_ change: QISAdministratorChange) {
        switch change {
        case .mayChange: administratorPending = true; host?.qisAdministratorMayHaveChanged()
        case .unchanged: administratorPending = false; host?.qisAdministratorUnchanged()
        }
    }

    private func run(_ s: QISSubmission, _ ticket: Ticket) async {
        guard let host, isCurrent(ticket) else { return }
        guard host.qisBeginOperation("正在发送网络设置向导的请求") else {
            notice = QISNotice("另一项操作正在进行，没有发送。", .attention)
            return
        }
        let client = ticket.client, uptime = host.qisUptime
        administratorPending = false
        var message = "", tone = QISNotice.Tone.success
        do {
            let receipt = try await client.qisSubmit(s, onAdministratorChange: { [weak self] change in await self?.administratorChange(change) })
            host.qisSettingsMayHaveChanged()
            let shown = isCurrent(ticket)
            if shown { adopt(receipt.state ?? s.before, ticket) }
            message = receipt.message
            if !receipt.unverified.isEmpty || receipt.state == nil || receipt.message.contains("没有") || receipt.message.contains("无法") { tone = .attention }
            if receipt.changedAdministrator || administratorPending {
                let answer = receipt.chpassStatus.map { "chpass.cgi 回应 statusCode \($0)，网页不检查这一结果" } ?? "chpass.cgi 的结果没有确认"
                message += " 管理员账号或密码\(receipt.chpassStatus == nil ? "可能已" : "已")修改（\(answer)）。App 保存的登录信息不再可用："
                    + "请在连接设置中用新的账号和密码重新登录，再重新读取核对。"
                host.qisEndOperation()
                host.qisAdministratorChanged()
                if shown { finished = true; notice = QISNotice(message, .attention) }
                return
            }
            if receipt.checkAfterRestart {
                if let lan = receipt.lanAddress {
                    message += lan.isEmpty ? " 局域网地址改为自动获取，重启后路由器的地址由上级路由器分配：请找到新地址后在连接设置中重新连接，再核对结果。"
                        : " 局域网地址改为 \(lan)：路由器重启后，请在连接设置中改用 http://\(lan) 连接并核对结果。"
                    tone = .attention
                } else {
                    let wait = (receipt.state ?? s.before).rebootSeconds
                    switch await host.qisAwaitRestart(client, from: uptime, checks: max(24, (wait + 60) / 5)) {
                    case .back:
                        do {
                            let checked = try await client.qisCheck(s.requests, privacyVersion: s.privacyVersion)
                            message = "路由器已恢复连接。" + checked.message; tone = checked.isVerified ? .success : .attention
                        } catch {
                            message = "路由器已恢复连接，但暂时无法读回核对（\(error.localizedDescription)）。请稍后重新读取核对，不要重复提交。"
                            tone = .attention
                        }
                    case .signInFailed(let reason): message += " " + reason; tone = .attention
                    case .notConfirmed: message += " 还没有确认路由器恢复并完成设置。请稍后重新读取核对，不要重复提交。"; tone = .attention
                    }
                }
            }
            if isCurrent(ticket), wizard?.page == .summary { finished = true }
        } catch {
            // qisSubmit throws only before anything was sent.
            message = "请求没有完成：\(error.localizedDescription)"; tone = .error
            host.qisManagementError(error)
        }
        host.qisEndOperation()
        if administratorPending { host.qisAdministratorChanged() }
        if isCurrent(ticket) { notice = QISNotice(message, tone) }
    }

    // MARK: The queue

    /// Runs `work` after everything queued before it.
    @discardableResult
    private func enqueue(cancellable: Bool, _ work: @escaping @MainActor @Sendable () async -> Void) -> Task<Void, Never> {
        let previous = tail, id = UUID()
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await work()
            self?.cancellable[id] = nil
        }
        tail = task
        if cancellable { self.cancellable[id] = task }
        return task
    }
    /// Waits until what is queued, and what that queues in turn, is done.
    func settle() async {
        while let last = tail {
            await last.value
            if tail == last { return }
        }
    }
    private func claimBusy(_ text: String) -> UUID { let id = UUID(); busy = text; busyOwner = id; return id }
    private func releaseBusy(_ id: UUID) { if busyOwner == id { busy = nil; busyOwner = nil } }
    private func fail(_ error: Error, _ ticket: Ticket, prefix: String = "") {
        guard !(error is CancellationError), isCurrent(ticket) else { return }
        notice = QISNotice(prefix + error.localizedDescription, .error)
        host?.qisManagementError(error)
    }
}
