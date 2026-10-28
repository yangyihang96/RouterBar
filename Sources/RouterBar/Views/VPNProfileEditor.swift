import SwiftUI
import RouterCore

/// Detail page for one VPN center destination. Fixed order: status and primary action → common fields →
/// advanced (collapsed) → certificates / files → replacement. Fields are edited through the shared
/// NativeSettingsModel and saved with SettingsReviewSheet → NativeSettingsModel.save → applySettings.
struct VPNProfileEditor: View {
    @Environment(RouterStore.self) var store
    @ObservedObject var center: VPNCenterModel
    @ObservedObject var editor: NativeSettingsModel
    let destination: VPNCenterDestination

    @State private var showingReview = false
    @State private var rulesField: SettingField?
    @State private var confirmReload = false
    @State private var filesExpanded = false

    private var section: SettingSection? { SettingsCatalog.section(destination.sectionID) }
    private var loaded: Bool { center.editorHasLoaded(destination) }
    private var busy: Bool { store.operationTitle != nil || editor.saving }
    private var hasDraft: Bool { !editor.changes.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header
                        if let notice = editor.notice { NoticeBanner(message: notice, tone: editor.verified ? .success : .attention) }
                        if store.phase != .connected {
                            ConnectionRequiredView()
                        } else {
                            // Runtime and file views stay mounted while the editor reloads, so their own
                            // results (e.g. an import outcome) are not lost when settings are re-read.
                            if let instance = destination.instance {
                                VPNRuntimeView(instance: instance, startBlockReason: VPNProfileClassifier.startBlockReason(for: instance, presence: center.freshPresence(instance))) { changed in Task { await center.refreshSummary(.instance(changed), store: store) } }
                                    .disabled(hasDraft)
                                if hasDraft { Text("请先保存或撤销下方修改，再启动、停止或导入。").font(.caption).foregroundStyle(.secondary) }
                            }
                            if loaded, let section {
                                fields(section, proxy: proxy)
                            } else if editor.loading {
                                VStack(spacing: 12) { ProgressView(); Text("正在读取\(destination.title)…").foregroundStyle(.secondary) }.frame(maxWidth: .infinity, minHeight: 180)
                            } else {
                                ContentUnavailableView {
                                    Label("尚未读取设置", systemImage: "arrow.clockwise")
                                } description: { Text("读取后才能查看与编辑此配置。") } actions: {
                                    Button("读取") { Task { await editor.load(store: store) } }
                                }
                            }
                            trailing
                        }
                    }.padding(28)
                }
                .onChange(of: center.highlightedKey) { _, key in scroll(proxy, to: key) }
                .onChange(of: loaded) { _, isLoaded in if isLoaded { scroll(proxy, to: center.highlightedKey) } }
            }
            Divider()
            footer
        }
        .task(id: destination) { await loadIfNeeded() }
        .onChange(of: store.phase) { _, phase in if phase == .connected { Task { await loadIfNeeded() } } }
        .onChange(of: editor.readAt) { _, at in
            if at != nil, loaded { Task { await center.refreshSummary(destination, store: store) } }
        }
        .sheet(isPresented: $showingReview) {
            SettingsReviewSheet(model: editor, presentation: VPNPresentation.displayField) { showingReview = false; Task { await save() } }
        }
        .sheet(item: $rulesField) { field in
            RuleEditorSheet(field: VPNPresentation.displayField(field), original: editor.draft[field.key] ?? "") { editor.draft[field.key] = $0 }
        }
        .confirmationDialog("放弃尚未保存的修改并重新读取？", isPresented: $confirmReload, titleVisibility: .visible) {
            Button("放弃并重新读取", role: .destructive) { editor.discard(); Task { await editor.load(store: store) } }
        }
    }

    // MARK: Header

    private var header: some View {
        let summary = destination.instance.flatMap { center.state($0).value }
        let subtitle: String
        switch destination {
        case .instance(let instance):
            subtitle = [instance.slotLabel, liveConnectionLine(instance) ?? summary?.connectionLine].compactMap { $0 }.joined(separator: " · ")
        case .routing:
            subtitle = "按设备或网段选择经由 WAN 或某个 VPN 客户端出站。"
        }
        return PageHeader(title: liveName ?? summary?.displayName ?? destination.title, subtitle: subtitle,
                          symbol: destination.symbol, eyebrow: destination.purpose.title)
    }

    /// Name and "host:port · UDP" from the current draft, so the header follows unsaved edits.
    private var liveName: String? {
        guard loaded, let instance = destination.instance else { return nil }
        let name = (editor.draft[instance.settingPrefix + "desc"] ?? "").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
    private func liveConnectionLine(_ instance: VPNInstance) -> String? {
        guard loaded else { return nil }
        return VPNProfileSummary(instance: instance, values: editor.draft).connectionLine
    }

    // MARK: Content

    @ViewBuilder private func fields(_ section: SettingSection, proxy: ScrollViewProxy) -> some View {
        let parts = VPNFieldLayout.partition(section.fields)
        if let instance = destination.instance {
            missingBanner(instance)
            if VPNImportPlacement.decide(instance, presence: center.freshPresence(instance)) == .recommended {
                Panel {
                    HStack(alignment: .top, spacing: 14) {
                        SectionTitle(title: "从配置文件开始", subtitle: "尚未填写连接信息。导入会替换此位置的设置；旧证书等内容未在列表中检查，上传前会再次确认。", symbol: "square.and.arrow.down")
                        Spacer()
                        Button("导入配置文件…") {
                            filesExpanded = true
                            withAnimation { proxy.scrollTo(Self.filesAnchor, anchor: .top) }
                        }.buttonStyle(.borderedProminent).tint(.teal).disabled(hasDraft || busy)
                    }
                }
            }
        }
        fieldsPanel(parts.primary)
        advanced(parts.advanced)
        Label(section.impact, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
    }

    /// Certificates, files and replacement, then server peers or routing notes. Mounted independently of the editor's read state.
    @ViewBuilder private var trailing: some View {
        switch destination {
        case .instance(let instance):
            files(instance).id(Self.filesAnchor)
            if instance == .wireGuardServer {
                SectionTitle(title: "WireGuard 服务器的客户端", subtitle: "编辑客户端；导出配置在“导出客户端配置”中。", symbol: "person.2")
                WireGuardPeersView { Task { await editor.load(store: store) } }.disabled(hasDraft)
            }
        case .routing:
            routingNotes
        }
    }
    private static let filesAnchor = "vpn-files"

    @ViewBuilder private func missingBanner(_ instance: VPNInstance) -> some View {
        if case .incomplete(let missing)? = center.freshPresence(instance) {
            NoticeBanner(message: "配置不完整，缺少：\(missing.joined(separator: "、"))。证书完整性请在“证书与导入”中检查。", tone: .attention)
        }
    }

    private func fieldsPanel(_ fields: [SettingField]) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(fields.enumerated()), id: \.element.id) { index, field in
                    if index > 0 { Divider().padding(.vertical, 13) }
                    row(field)
                }
            }.disabled(busy)
        }
    }

    @ViewBuilder private func advanced(_ fields: [SettingField]) -> some View {
        if !fields.isEmpty {
            DisclosureGroup(isExpanded: $center.showAdvanced) {
                fieldsPanel(fields).padding(.top, 10)
            } label: {
                let changed = fields.filter { editor.values[$0.key] != editor.draft[$0.key] }.count
                Text("高级设置（\(fields.count) 项\(changed > 0 ? "，\(changed) 项已修改" : "")）").font(.headline)
            }
        }
    }

    @ViewBuilder private func row(_ catalogField: SettingField) -> some View {
        let shown = VPNPresentation.displayField(catalogField)
        let highlighted = center.highlightedKey == catalogField.key
        Group {
            if catalogField.kind == "rules" {
                RuleSummary(field: shown, value: editor.draft[catalogField.key] ?? "", open: { rulesField = catalogField })
            } else {
                // `shown` only changes label/help/option titles; edits are stored by key and saved with the catalog field.
                NativeSettingRow(field: shown, value: Binding(get: { editor.draft[catalogField.key] ?? "" }, set: { editor.draft[catalogField.key] = $0 }),
                                 changed: editor.values[catalogField.key] != editor.draft[catalogField.key])
            }
        }
        .padding(highlighted ? 8 : 0)
        .background(highlighted ? Color.teal.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .id(catalogField.key)
    }

    // MARK: Files

    /// One VPNFilesView per destination in a fixed position, so its import/export result survives re-reads.
    /// Its own confirmation dialog ("替换…的配置？") is kept for every import, including empty slots.
    private func files(_ instance: VPNInstance) -> some View {
        let placement = VPNImportPlacement.decide(instance, presence: center.freshPresence(instance))
        return DisclosureGroup(isExpanded: $filesExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                switch placement {
                case .replacement:
                    NoticeBanner(message: "此位置已有或可能有配置。导入文件会先重置此位置，解析失败时原设置也可能被清空。要使用其他位置，请通过“添加配置”选择。", tone: .attention)
                case .recommended:
                    NoticeBanner(message: "此位置尚未填写连接信息。导入会替换该位置的设置与证书，其他位置不受影响。", tone: .information)
                case .unavailable:
                    EmptyView()
                }
                VPNFilesView(instance: instance) { routerChanged(instance) }.disabled(hasDraft)
            }.padding(.top, 10)
        } label: {
            Text(filesTitle(instance, placement)).font(.headline)
        }
    }

    private func filesTitle(_ instance: VPNInstance, _ placement: VPNImportPlacement) -> String {
        switch instance {
        case .openVPNClient: placement == .recommended ? "证书与导入" : "证书与用文件替换"
        case .wireGuardClient: placement == .recommended ? "导入配置文件" : "用文件替换"
        case .openVPNServer: "证书与导出客户端配置"
        case .wireGuardServer: "导出客户端配置"
        }
    }

    private func routerChanged(_ instance: VPNInstance) {
        Task {
            await editor.load(store: store)
        }
    }

    private var routingNotes: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let summary = center.director.value, !summary.interfaces.isEmpty {
                Panel {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(title: "按接口统计", subtitle: "按规则中的接口原文统计（上次读取的已保存规则）。", symbol: "list.number")
                        ForEach(summary.interfaces, id: \.name) { item in
                            HStack {
                                Text(item.name.isEmpty ? "（空）" : item.name).font(.callout.monospaced())
                                Spacer()
                                Text("\(item.total) 条 · \(item.enabled) 条启用").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            NoticeBanner(message: "要让整个访客网络使用同一个 VPN，请前往“网络”页面，选择相应网络并设置 VPN 出口。", tone: .information)
            Button("前往“网络”") { store.open(.networks) }.disabled(busy)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 13) {
            VStack(alignment: .leading, spacing: 3) {
                Text(hasDraft ? "\(editor.changes.count) 项修改尚未保存" : "没有未保存的修改").font(.callout.weight(.medium))
                if loaded, let time = editor.readAt { Text("读取于 \(VPNPresentation.time(time))").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Button("重新读取") { if hasDraft { confirmReload = true } else { Task { await editor.load(store: store) } } }
            Button("撤销修改") { editor.discard() }.disabled(!hasDraft)
            Button("保存到路由器") { showingReview = true }.buttonStyle(.borderedProminent).tint(.teal)
                .disabled(!hasDraft || !loaded)
        }
        .padding(18).background(.bar)
        .disabled(store.phase != .connected || editor.loading || busy)
    }

    // MARK: Actions

    private func loadIfNeeded() async {
        guard !center.isPreview, editor.selectedID == destination.sectionID, !editor.saving, !center.editorHasLoaded(destination) else { return }
        await editor.load(store: store)
    }

    private func save() async {
        await editor.save(store: store)
    }

    private func scroll(_ proxy: ScrollViewProxy, to key: String?) {
        guard let key, loaded else { return }
        if VPNFieldLayout.tier(forKey: key) == .advanced { center.showAdvanced = true }
        withAnimation { proxy.scrollTo(key, anchor: .center) }
    }
}
