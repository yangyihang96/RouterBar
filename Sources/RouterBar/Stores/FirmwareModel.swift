import SwiftUI
import RouterCore

@MainActor
final class FirmwareModel: ObservableObject {
    enum Stage: String { case idle, checking, ready, uploading, installing, reconnecting, verified, uncertain, failed }
    @Published var state: FirmwareState?
    @Published var stage: Stage = .idle
    @Published var progress: Double = 0
    @Published var image: FirmwareImage?
    @Published var notice: String?
    @Published var notes: String = ""
    @Published var readAt: Date?
    @Published var checkedAt: Date?
    @Published var onlineRelease: MerlinRelease?
    @Published var downloading = false
    @Published var downloadProgress = 0.0
    /// A chosen file is being checked; installing waits for it.
    @Published var inspecting = false
    private let releases = MerlinReleaseClient()
    /// Only the latest file choice may set the image.
    private var selection = UUID()
    var busy: Bool { downloading || inspecting || [.checking, .uploading, .installing, .reconnecting].contains(stage) }
    var title: String {
        switch stage {
        case .idle: "固件与系统更新"
        case .checking: "正在检查更新"
        case .ready: "固件已准备"
        case .uploading: "正在上传固件"
        case .installing: "路由器正在刷写"
        case .reconnecting: "正在等待路由器恢复"
        case .verified: "已读取更新后的版本"
        case .uncertain: "更新结果待确认"
        case .failed: "操作未完成"
        }
    }
    func reset() {
        // A file check or download under way belongs to the session that started it, and another router may follow:
        // both go, even while an upload keeps the rest.
        selection = UUID(); inspecting = false; downloading = false; onlineRelease = nil
        guard !busy else { return }
        state = nil; readAt = nil; checkedAt = nil; image = nil; notes = ""; notice = nil; stage = .idle
    }
    func load(store: RouterStore) async {
        guard !busy else { return }
        do { state = try await store.connectedClient().firmwareState(); readAt = .now }
        catch { notice = error.localizedDescription; store.handleManagementError(error) }
    }
    func check(store: RouterStore) async {
        guard !busy, let identity = store.snapshot?.sample.identity, store.beginOperation("正在检查官方固件版本", readOnly: true) else { return }
        stage = .checking; notice = nil
        defer { store.endOperation() }
        do {
            let release = try await releases.latest(model: identity.model)
            onlineRelease = release; checkedAt = .now; stage = .idle
            func normalized(_ value: String) -> String { var v = value.replacingOccurrences(of: "_", with: "."); if v.hasSuffix(".0") { v.removeLast(2) }; return v }
            let newer = normalized(release.version).compare(normalized(identity.firmware), options: .numeric) == .orderedDescending
            notice = newer ? "官方正式发布目录中有新版本 \(release.version)，可直接在此下载并安装。" : "当前固件已与官方正式发布版本一致，或比该发布版本更新。"
        } catch { stage = .failed; notice = error.localizedDescription }
    }
    func prepareOnline(store: RouterStore) async {
        guard !busy, let routerModel = store.snapshot?.sample.identity.model, store.beginOperation("正在获取官方固件", readOnly: true) else { return }
        downloading = true; downloadProgress = 0; notice = "正在读取 Asuswrt-Merlin 官方发布目录…"
        // Like a file choice, a download belongs to the session that started it (reset() ends both).
        let token = UUID(); selection = token
        defer { downloading = false; store.endOperation() }
        do {
            let release = try await releases.latest(model: routerModel)
            guard selection == token else { return }
            onlineRelease = release; notice = "正在下载 \(release.version)…"
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("com.yihang.RouterBar/Firmware/" + UUID().uuidString, isDirectory: true)
            let downloaded = try await releases.download(release, directory: directory) { [weak self] value in Task { @MainActor in self?.downloadProgress = value } }
            guard selection == token else { return }
            image = downloaded; stage = .ready; notice = "官方固件已下载并解压。点击“安装到路由器”开始更新。"
        } catch {
            guard selection == token else { return }
            notice = error.localizedDescription; stage = .failed
        }
    }
    func select(_ url: URL, model: String) async {
        guard !busy else { return }
        let token = UUID(); selection = token
        inspecting = true; notice = "正在校验所选文件…"
        defer { if selection == token { inspecting = false } }
        do {
            let inspected = try await Task.detached(priority: .userInitiated) { try FirmwareImage.inspect(url, model: model) }.value
            guard selection == token else { return }
            image = inspected; stage = .ready; notice = nil
        } catch {
            guard selection == token else { return }
            image = nil; notice = error.localizedDescription
        }
    }
    func install(store: RouterStore) async {
        guard let image, let before = store.snapshot?.sample, !busy, store.beginOperation("固件更新进行中") else { return }
        stage = .uploading; progress = 0; notice = nil
        defer { store.endOperation() }
        let client: RouterClient
        do { client = try store.connectedClient() } catch { stage = .failed; notice = error.localizedDescription; return }
        do {
            try await client.installFirmware(image, model: before.identity.model) { [weak self] fraction in Task { @MainActor in self?.progress = fraction } }
            await store.firmwareMayHaveChanged(client)
            stage = .installing; notice = "固件已上传，等待路由器完成刷写和重新启动。"
        } catch RouterError.submissionUncertain(let reason) {
            // The response may disappear when httpd stops. Do not resend the image.
            await store.firmwareMayHaveChanged(client)
            stage = .uncertain; notice = reason + " 正在读取路由器状态。"
        } catch RouterError.authenticationRequired {
            stage = .failed; notice = "登录已失效，固件没有上传。请恢复连接后重新选择安装。"; return
        } catch {
            // Anything else ended before the router took the image, so there is no restart to wait for.
            stage = .failed; notice = error.localizedDescription; return
        }
        var signIns = 0
        for attempt in 0..<40 {
            try? await Task.sleep(for: .seconds(15))
            if attempt > 2 && stage != .uncertain { stage = .reconnecting }
            do {
                let sample = try await client.sample()
                let restarted = sample.uptime.map { $0 < (before.uptime ?? 0) } ?? false
                func normalize(_ v: String) -> String { var value = v.replacingOccurrences(of: "_", with: "."); if value.hasSuffix(".0") { value.removeLast(2) }; return value }
                let expectedMatches = image.expectedVersion.map { normalize($0) == normalize(sample.identity.firmware) } ?? false
                if expectedMatches && (sample.identity.firmware != before.identity.firmware || restarted) {
                    stage = .verified; notice = "已重新读取路由器，版本与所选固件一致： \(sample.identity.firmware)。"
                    store.acceptManagementSample(sample); self.image = nil; return
                }
                if restarted && attempt > 3 {
                    stage = .uncertain; notice = "路由器已重新启动，当前为 \(sample.identity.firmware)。请核对所选固件版本，不能据此确认升级成功。"
                    store.acceptManagementSample(sample); return
                }
            } catch RouterError.authenticationRequired {
                guard attempt >= 4, signIns < 3 else { continue }
                signIns += 1
                do { _ = try await store.signInAgainAfterRestart(client) }
                catch { stage = .uncertain; notice = "更新结果尚未确认：" + error.localizedDescription; return }
            } catch { /* A temporary disconnect is expected during reboot. */ }
        }
        stage = .uncertain; notice = "尚未读取到更新后的固件版本。请检查路由器状态，恢复连接后再核对版本。"
    }
}
