import SwiftUI
import RouterCore

/// Runtime status and start/stop for one VPN instance.
///
/// OpenVPN reads vpn_clientN_state / vpn_serverN_state. WireGuard only reads its enable flag and is shown
/// as "已启用 · 连接待确认"; it is never reported as connected. All decisions live in VPNRuntimeTracker:
/// every read and write carries a ticket, so a reply for a previous instance or operation is dropped.
/// The global write lock (store.beginOperation) is held from submission until the result is confirmed or the
/// user stops waiting; stopping only ends the wait, the request already sent is neither undone nor resent.
struct VPNRuntimeView: View {
    @Environment(RouterStore.self) var store
    let instance: VPNInstance
    let startBlockReason: String?
    /// Called when a start/stop finished, timed out or was abandoned, so a parent can refresh its summary.
    var onRuntimeChanged: ((VPNInstance) -> Void)? = nil

    @State private var tracker: VPNRuntimeTracker
    @State private var notice: (message: String, tone: NoticeBanner.Tone)?
    @State private var confirming: VPNRuntimeAction?
    @State private var autoStartDraft: Bool?
    @State private var waitTask: Task<Void, Never>?

    private static let pollInterval: Duration = .seconds(3)
    private static let pollAttempts = 12

    init(instance: VPNInstance, startBlockReason: String? = nil, onRuntimeChanged: ((VPNInstance) -> Void)? = nil) {
        self.instance = instance
        self.startBlockReason = startBlockReason
        self.onRuntimeChanged = onRuntimeChanged
        _tracker = State(initialValue: VPNRuntimeTracker(instance: instance))
    }

    /// Until `.task(id:)` has reset the tracker, a freshly selected instance renders as "not read",
    /// never with the previous instance's state.
    private var current: VPNRuntimeTracker { tracker.instance == instance ? tracker : VPNRuntimeTracker(instance: instance) }
    private var connected: Bool { store.phase == .connected }
    private var availability: VPNWriteAvailability {
        if connected, let refusal = store.writeScope.referenceWebRefusal { return .blocked(refusal) }
        return current.writeAvailability(connected: connected, otherOperationRunning: store.operationTitle != nil)
    }

    var body: some View {
        let state = current
        let status = state.status(connected: connected)
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: status.tone.symbol).font(.title2).foregroundStyle(status.tone.color).frame(width: 30)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(status.title).font(.headline)
                        if let detail = status.detail { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                        if let since = state.operation?.awaitingSince {
                            TimelineView(.periodic(from: since, by: 1)) { context in
                                Text("已等待 \(max(0, Int(context.date.timeIntervalSince(since)))) 秒").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                        } else if let at = status.at {
                            Text("读取于 \(VPNPresentation.time(at))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    Spacer(minLength: 12)
                    actions(state)
                }
                if let reason = availability.reason, state.primaryAction != nil || state.requiresFreshRead, state.operation?.isActive != true {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
                if state.primaryAction == .start, let startBlockReason {
                    Text(startBlockReason).font(.caption).foregroundStyle(.secondary)
                }
                if let notice { NoticeBanner(message: notice.message, tone: notice.tone) }
                if instance.startupListKey != nil { autoStartRow(state) }
            }
        }
        .task(id: instance) { await switchTo(instance) }
        .onChange(of: store.phase) { _, phase in if phase != .connected { endWaitSilently() } }
        .onDisappear { endWaitSilently() }
        .confirmationDialog(confirming == .start ? "启动\(instance.title)？" : "停止\(instance.title)？",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
            if let action = confirming { Button(action.title) { run(action) } }
        } message: {
            Text("使用这个 VPN 的设备会重新建立或中断连接。发送后会等待路由器确认，最长约 \(Self.pollAttempts * 3) 秒；期间其他写入操作需要等待。")
        }
    }

    @ViewBuilder private func actions(_ state: VPNRuntimeTracker) -> some View {
        if state.operation?.awaitingSince != nil {
            Button("停止等待") { stopWaiting() }
                .help("只停止等待结果，不会撤销或重复发送已提交的请求。")
        } else if state.operation?.isActive == true {
            ProgressView().controlSize(.small)
        } else {
            HStack(spacing: 8) {
                if state.reading.isLoading { ProgressView().controlSize(.small) }
                Button("读取状态") { Task { await read() } }
                    .disabled(!connected || state.reading.isLoading)
                if let action = state.primaryAction {
                    Button("立即\(action.title)") { confirming = action }
                        .buttonStyle(.borderedProminent).tint(action == .stop ? .orange : .teal)
                        .disabled(!availability.isAllowed || (action == .start && startBlockReason != nil))
                }
            }
        }
    }

    @ViewBuilder private func autoStartRow(_ state: VPNRuntimeTracker) -> some View {
        let reading = state.reading.value
        Divider()
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("自动启动此实例", isOn: Binding(get: { autoStartDraft ?? reading?.autoStart ?? false }, set: { autoStartDraft = $0 }))
                    .toggleStyle(.switch).tint(.teal)
                    .disabled(reading?.autoStart == nil || !availability.isAllowed)
                Text(reading == nil ? "读取状态后可修改。"
                     : reading?.autoStart == nil ? "路由器的自动启动列表格式未适配，暂不修改。"
                     : "让路由器自动启动这个 VPN 配置。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("保存启动选项") { Task { await saveStartup() } }
                .disabled(reading?.autoStart == nil || autoStartDraft == nil || autoStartDraft == reading?.autoStart || !availability.isAllowed)
        }
    }

    // MARK: Reads

    private func switchTo(_ next: VPNInstance) async {
        endWaitSilently()
        tracker.select(next)
        notice = nil; confirming = nil; autoStartDraft = nil
        await read()
    }

    private func read() async {
        guard connected, tracker.instance == instance, let ticket = tracker.beginRead(at: .now) else { return }
        let result: Result<VPNRuntimeReading, VPNReadFailure>
        do {
            let values = try await store.connectedClient().readSettings(VPNRuntimeReading.keys(for: ticket.instance))
            result = .success(try VPNRuntimeReading(instance: ticket.instance, values: values))
        } catch let failure as VPNReadFailure {
            result = .failure(failure)
        } catch {
            result = .failure(VPNReadFailure(error.localizedDescription))
            if tracker.instance == ticket.instance { store.handleManagementError(error) }
        }
        if tracker.finishRead(ticket, result, at: .now), case .success = result { autoStartDraft = nil }
    }

    // MARK: Start / stop

    private func run(_ action: VPNRuntimeAction) {
        confirming = nil
        guard action != .start || startBlockReason == nil else { return }
        guard let kind = instance.runtimeServiceKind, waitTask == nil, tracker.instance == instance else { return }
        guard store.beginOperation(action == .start ? "正在启动\(instance.title)" : "正在停止\(instance.title)") else { return }
        // The global lock is now ours, so the tracker sees no other operation.
        guard let ticket = tracker.beginOperation(action, connected: connected, otherOperationRunning: false) else { store.endOperation(); return }
        notice = nil
        let target = ticket.instance
        waitTask = Task { @MainActor in
            defer {
                store.endOperation()
                waitTask = nil
                onRuntimeChanged?(target)
            }
            do {
                try await store.connectedClient().setVPNRunning(kind: kind, unit: target.unit, running: action == .start)
            } catch RouterError.submissionUncertain(let reason) {
                tracker.submissionFailed(ticket, message: reason)
                return
            } catch {
                // Only an uncertain submission may have reached the router; any other failure left it untouched.
                tracker.submissionNotSent(ticket)
                notice = ("\(action.title)请求没有送达路由器：\(error.localizedDescription)", NoticeBanner.Tone.error)
                store.handleManagementError(error)
                return
            }
            tracker.submissionAccepted(ticket, at: .now)
            for _ in 0..<Self.pollAttempts {
                do { try await Task.sleep(for: Self.pollInterval) } catch { return }
                if Task.isCancelled { return }
                do {
                    let raw = try await store.connectedClient().readSettings([target.statusKey])[target.statusKey] ?? ""
                    if Task.isCancelled { return }
                    switch tracker.observe(ticket, rawState: raw, at: .now) {
                    case .keepWaiting: continue
                    case .ignored: return
                    case .finished:
                        if tracker.reading.value?.condition == .error {
                            notice = ("路由器报告连接异常，请检查服务器、账号和证书。", NoticeBanner.Tone.error)
                        } else {
                            notice = ("已从路由器确认\(action.title)完成。", NoticeBanner.Tone.success)
                        }
                        return
                    }
                } catch {
                    if Task.isCancelled { return }
                    if (error as? RouterError) == .authenticationRequired {
                        tracker.connectionLost(ticket); store.handleManagementError(error); return
                    }
                    tracker.pollFailed(ticket, message: error.localizedDescription)
                }
            }
            tracker.timedOut(ticket)
        }
    }

    private func stopWaiting() {
        guard let ticket = tracker.operation?.ticket, tracker.stopWaiting(ticket) else { return }
        waitTask?.cancel()
        notice = ("已停止等待。请求已发送给路由器，不会撤销，也不会重复提交。请稍后点击“读取状态”确认结果。", NoticeBanner.Tone.attention)
    }

    /// Leaving the view, switching instance or losing the connection ends the wait the same way as "停止等待".
    private func endWaitSilently() {
        if let ticket = tracker.operation?.ticket { tracker.stopWaiting(ticket) }
        waitTask?.cancel()
    }

    // MARK: Auto start

    private func saveStartup() async {
        guard let reading = tracker.reading.value, let list = reading.startupList, let desired = autoStartDraft,
              availability.isAllowed, store.beginOperation("正在保存 VPN 自动启动选项") else { return }
        let target = instance
        do {
            let verified = try await store.connectedClient().setOpenVPNStartup(target, before: list, enabled: desired)
            store.endOperation()
            guard tracker.instance == target else { return }
            notice = verified ? ("已从路由器确认自动启动选项。", NoticeBanner.Tone.success) : ("自动启动选项尚未确认一致，请重新读取。", NoticeBanner.Tone.attention)
        } catch {
            store.endOperation()
            guard tracker.instance == target else { return }
            notice = (error.localizedDescription, NoticeBanner.Tone.error); store.handleManagementError(error)
        }
        await read()
    }
}
