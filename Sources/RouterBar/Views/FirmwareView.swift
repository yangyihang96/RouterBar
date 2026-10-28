import SwiftUI
import RouterCore
import UniformTypeIdentifiers

struct FirmwareView: View {
    @Environment(RouterStore.self) var store
    @ObservedObject var model: FirmwareModel
    @State private var confirmInstall = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: model.title, subtitle: "检查版本、准备固件，然后在应用内完成更新。", symbol: "arrow.down.circle.fill", eyebrow: "系统管理")
                FirmwareJourney(stage: model.stage, hasImage: model.image != nil)
                if store.phase != .connected { ConnectionRequiredView() }
                HStack(spacing: 16) {
                    StatCard(title: "当前固件", value: store.snapshot?.sample.identity.firmware ?? "—", symbol: "cpu", tint: .primary, note: store.snapshot?.sample.identity.model)
                    StatCard(title: release != nil ? "官方正式版本" : "路由器上次检查结果", value: release?.version ?? (model.state?.latest.isEmpty == false ? model.state!.latest : "尚未读取"), symbol: "arrow.down.circle", tint: .teal, note: model.checkedAt.map { "检查于 \(MonitoringDate.time($0))" } ?? "进入此页不会自动检查或安装")
                }
                if let notice = model.notice {
                    Label(notice, systemImage: model.stage == .verified ? "checkmark.circle.fill" : "info.circle").font(.callout)
                        .foregroundStyle(model.stage == .verified ? .green : .secondary).padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading).background(.teal.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
                }
                if store.profile?.family == .stock { stockUpdatePanel } else {
                Panel {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            VStack(alignment: .leading, spacing: 7) { Text("检查固件更新").font(.headline); Text("直接向 Asuswrt-Merlin 官方发布源查询对应型号的正式版本。").font(.callout).foregroundStyle(.secondary) }
                            Spacer()
                            if model.stage == .checking { ProgressView().controlSize(.small) }
                            Button("检查更新") { Task { await model.check(store: store) } }.buttonStyle(.borderedProminent).tint(.teal).disabled(!canAct)
                            Button("下载官方固件") { Task { await model.prepareOnline(store: store) } }.disabled(!canAct)
                            Button("读取结果") { Task { await model.load(store: store) } }.disabled(!canAct)
                        }
                        if !model.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            DisclosureGroup("版本说明") { ScrollView { Text(model.notes).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 250) }
                        }
                    }
                }
                if model.downloading { ProgressView(value: model.downloadProgress) { Text("从官方发布源下载") } currentValueLabel: { Text(model.downloadProgress, format: .percent.precision(.fractionLength(0))) }.tint(.teal) }
                }
                Panel {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 7) { Text("安装固件文件").font(.headline); Text("选择适用于 \(store.snapshot?.sample.identity.model ?? "当前型号") 的已解压固件。保持路由器供电，安装后会自动重启。").font(.callout).foregroundStyle(.secondary) }
                            Spacer(); Button("选择固件…", action: chooseFirmware).disabled(!canAct)
                        }
                        if let image = model.image {
                            Divider()
                            HStack(spacing: 13) {
                                Image(systemName: "shippingbox.fill").font(.system(size: 32)).foregroundStyle(.teal)
                                VStack(alignment: .leading, spacing: 5) { Text(image.url.lastPathComponent).font(.callout.weight(.semibold)); Text(ByteCountFormatter.string(fromByteCount: image.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                                Spacer(); Button("安装到路由器") { confirmInstall = true }.buttonStyle(.borderedProminent).tint(.teal).disabled(!canAct)
                            }
                            DisclosureGroup("文件校验信息") {
                                VStack(alignment: .leading, spacing: 5) { Text("SHA-256").font(.caption.weight(.semibold)); Text(image.sha256).font(.caption.monospaced()).textSelection(.enabled); Text("此校验值用于确认上传前文件没有变化；固件签名与兼容性由路由器检查。").font(.caption).foregroundStyle(.secondary) }
                            }
                        } else if model.inspecting {
                            HStack { ProgressView().controlSize(.small); Text("正在校验所选文件…").font(.caption).foregroundStyle(.secondary) }
                        } else { Label(imageHint, systemImage: "doc.zipper").font(.caption).foregroundStyle(.secondary) }
                        if model.stage == .uploading { ProgressView(value: model.progress) { Text("上传进度") } currentValueLabel: { Text(model.progress, format: .percent.precision(.fractionLength(0))) }.tint(.teal) }
                        if [.installing, .reconnecting].contains(model.stage) { HStack { ProgressView().controlSize(.small); Text("等待路由器返回真实状态…").font(.callout).foregroundStyle(.secondary) } }
                    }
                }
                Text(store.profile?.family == .stock ? "原厂固件的在线更新由路由器自己向华硕服务器检查；本页可上传从华硕官网下载的固件文件，上传、等待恢复与版本回读在应用内完成。"
                     : "固件从 Asuswrt-Merlin 的 SourceForge 正式发布目录获取。下载、解压、上传与恢复连接均在应用内完成，也可选择已有固件文件。").font(.caption).foregroundStyle(.secondary)
            }.padding(32)
        }
        .task { await model.load(store: store) }
        .confirmationDialog("安装固件并重启路由器？", isPresented: $confirmInstall, titleVisibility: .visible) {
            Button("开始安装") { Task { await model.install(store: store) } }
        } message: { Text("\(model.image?.url.lastPathComponent ?? "")\n安装会暂时中断整个网络，期间请勿断开电源或退出应用。") }
    }
    var canAct: Bool { store.phase == .connected && store.operationTitle == nil && !model.busy }
    /// The release looked up for this router; one found for another model is not shown.
    private var release: MerlinRelease? {
        model.onlineRelease.flatMap { $0.model == store.snapshot?.sample.identity.model ? $0 : nil }
    }
    private var imageHint: String {
        let name = store.snapshot?.sample.identity.model ?? store.profile?.model ?? "当前型号"
        return name == "RT-BE88U" ? "RT-BE88U 支持 .pkgtb 固件映像" : "选择文件名包含 \(name) 的已解压固件（.w、.pkgtb、.trx 或 .bin）；上传后路由器会再次校验。"
    }
    /// ASUS firmware checks for updates itself, against ASUS's servers; its web page starts that check.
    private var stockUpdatePanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                Text("原厂固件的在线更新").font(.headline)
                Text("这台路由器使用华硕原厂固件（\(store.profile?.firmwareVersion ?? "—")）。原厂固件的“检查更新”由路由器自己连接华硕服务器完成，本应用不代替路由器检查；可以在浏览器中打开路由器的固件升级页使用。路由器同一时间只允许一个管理员登录，在浏览器登录可能会让 App 的连接失效。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let url = store.endpoint?.resource("Advanced_FirmwareUpgrade_Content.asp") {
                    Link("在浏览器中打开固件升级页", destination: url).font(.callout)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func chooseFirmware() {
        let panel = NSOpenPanel(); panel.title = "选择路由器固件"; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["pkgtb", "w", "trx", "bin"].compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK, let url = panel.url { Task { await model.select(url, model: store.snapshot?.sample.identity.model ?? "") } }
    }
}
