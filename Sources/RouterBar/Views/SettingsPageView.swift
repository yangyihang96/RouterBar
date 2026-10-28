import SwiftUI
import Combine
import RouterCore

/// Follows every section editor shown on one page, so the page's save bar acts on whichever has changes.
@MainActor
final class SettingsPageModel: ObservableObject {
    let editors: [NativeSettingsModel]
    private var observers: [AnyCancellable] = []
    init(editors: [NativeSettingsModel]) {
        self.editors = editors
        observers = editors.map { editor in
            editor.objectWillChange.sink { [weak self] _ in MainActor.assumeIsolated { self?.objectWillChange.send() } }
        }
    }
    /// One section of a page is edited at a time; the others wait until it is saved or undone.
    var active: NativeSettingsModel? { editors.first { !$0.changes.isEmpty } }
    var loading: Bool { editors.contains(where: \.loading) }
    var saving: Bool { editors.contains(where: \.saving) }
    var readAt: Date? { editors.compactMap(\.readAt).min() }
    func load(store: RouterStore) async {
        for editor in editors where !editor.saving { await editor.load(store: store) }
    }
}

extension NativeSettingsModel: Identifiable {}

/// Explains settings the web hides on this page right now, with a way to where they are managed.
struct SettingsPageNote {
    let text: String
    var link: (title: String, feature: NativeFeature)?
}

/// The catalog sections of one web page or switch choice: a card per section and one save bar, as the web page
/// has one 应用本页面设置 button. Every visit reads the router again.
struct SettingsPageView: View {
    @Environment(RouterStore.self) var store
    @StateObject private var page: SettingsPageModel
    let title: String
    let symbol: String
    let accessory: NativeFeature?
    let note: SettingsPageNote?
    @State private var reviewing: NativeSettingsModel?
    @State private var confirmReload = false

    init(editors: [NativeSettingsModel], title: String, symbol: String, accessory: NativeFeature? = nil, note: SettingsPageNote? = nil) {
        _page = StateObject(wrappedValue: SettingsPageModel(editors: editors))
        self.title = title; self.symbol = symbol; self.accessory = accessory; self.note = note
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .top, spacing: 15) {
                        PageHeader(title: title, subtitle: subtitle, symbol: symbol)
                        Spacer()
                        if page.loading || page.saving { ProgressView().controlSize(.small) }
                    }
                    if let note {
                        VStack(alignment: .leading, spacing: 8) {
                            NoticeBanner(message: note.text, tone: .information)
                            if let link = note.link { Button(link.title) { store.open(link.feature) }.buttonStyle(.link) }
                        }
                    }
                    if store.phase != .connected {
                        ConnectionRequiredView()
                    } else {
                        // PrinterServer.asp puts its description and links above the switch.
                        if case .printerServer = accessory { PrinterServerIntro() }
                        ForEach(page.editors) { editor in
                            SettingsSectionCard(model: editor, showsTitle: page.editors.count > 1, locked: page.active.map { $0 !== editor } ?? false)
                        }
                        if case .radioChannels(let unit) = accessory {
                            if page.active != nil { Text("请先保存或撤销上方修改，再调整信道与频宽。").font(.caption).foregroundStyle(.secondary) }
                            // A saved 160 MHz switch changes which channels the router offers, so a fresh read reloads them.
                            RadioChannelsView(unit: unit).id("\(unit)-\(page.readAt?.timeIntervalSince1970 ?? 0)").disabled(page.active != nil)
                        }
                    }
                }.padding(28)
            }
            if !page.editors.isEmpty {
                Divider()
                saveBar
            }
        }
        .task(id: store.phase == .connected) { if store.phase == .connected { await page.load(store: store) } }
        .sheet(item: $reviewing) { editor in
            SettingsReviewSheet(model: editor) { reviewing = nil; Task { await editor.save(store: store) } }
        }
        .confirmationDialog("放弃当前尚未保存的修改？", isPresented: $confirmReload) {
            Button("放弃并重新读取", role: .destructive) { page.active?.discard(); Task { await page.load(store: store) } }
        }
    }

    private var subtitle: String {
        if page.editors.isEmpty { return "读取路由器当前允许的选项，确认后保存。" }
        let readOnly = page.editors.allSatisfy { editor in editor.section.map { store.readOnlyReason(section: $0.id) != nil } ?? true }
        return readOnly ? "读取路由器当前的设置；这台路由器在 App 内只显示当前值。" : "读取当前设置，确认修改后保存到路由器。"
    }

    private var saveBar: some View {
        HStack(spacing: 13) {
            VStack(alignment: .leading, spacing: 3) {
                if let active = page.active {
                    Text("\(active.changes.count) 项修改尚未保存" + (page.editors.count > 1 ? "（\(active.section?.title ?? "")）" : "")).font(.callout.weight(.medium))
                } else {
                    Text("没有未保存的修改").font(.callout.weight(.medium))
                }
                if let time = page.readAt { Text("读取于 \(MonitoringDate.time(time))").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Button("重新读取") { if page.active == nil { Task { await page.load(store: store) } } else { confirmReload = true } }
            Button("撤销修改") { page.active?.discard() }.disabled(page.active == nil)
            Button("保存到路由器") { reviewing = page.active }.buttonStyle(.borderedProminent).tint(.teal)
                .disabled(page.active == nil || page.active?.readAt == nil)
        }.padding(18).background(.bar).disabled(store.phase != .connected || page.loading || store.operationTitle != nil)
    }
}

/// One catalog section: its fields as read from the router, the draft, and the result of the last save.
struct SettingsSectionCard: View {
    @Environment(RouterStore.self) var store
    @ObservedObject var model: NativeSettingsModel
    let showsTitle: Bool
    /// Another section on the page holds changes.
    let locked: Bool
    @State private var rulesField: SettingField?
    private var readOnly: String? { model.section.flatMap { store.readOnlyReason(section: $0.id) } }
    /// The band's security choices follow its auth and Wi-Fi 7 mode, as on the web page (WirelessSecurityRules).
    private var bandContext: WirelessSecurityRules.BandContext? {
        guard let id = model.section?.id, let unit = WirelessSecurityRules.unit(ofSection: id) else { return nil }
        return .init(sixGHz: id.contains("@6"), wifi7Router: store.profile?.supports("wifi7") ?? false, wifi7Mode: model.values["wl\(unit)_11be"] == "1")
    }
    /// The fields the web shows now, with the choices it offers for them.
    private func shownFields(_ section: SettingSection) -> [SettingField] {
        let fields = section.fields.filter { !TimeZoneEditor.embeddedKeys.contains($0.key) && store.isVisible(field: $0.key) }
        guard let band = bandContext, let unit = WirelessSecurityRules.unit(ofSection: section.id) else { return fields }
        return fields.compactMap { WirelessSecurityRules.shownField($0, values: model.draft, unit: unit, context: band) }
    }
    var body: some View {
        if let section = model.section {
            VStack(alignment: .leading, spacing: 14) {
                if showsTitle { SectionTitle(title: section.title, symbol: section.symbol) }
                if let notice = model.notice {
                    Label(notice, systemImage: model.verified ? "checkmark.circle.fill" : "info.circle")
                        .font(.callout).foregroundStyle(model.verified ? .green : .orange).padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading).background((model.verified ? Color.green : .orange).opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
                if model.loading && model.readAt == nil {
                    VStack(spacing: 14) { ProgressView(); Text("正在读取路由器设置…").foregroundStyle(.secondary) }.frame(maxWidth: .infinity, minHeight: showsTitle ? 120 : 260)
                } else if model.readAt != nil {
                    if let readOnly { NoticeBanner(message: readOnly, tone: .information) }
                    Panel {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(shownFields(section).enumerated()), id: \.element.id) { index, field in
                                if index > 0 { Divider().padding(.vertical, 13) }
                                if field.kind == "rules" {
                                    RuleSummary(field: field, value: model.draft[field.key] ?? "", open: { rulesField = field })
                                } else if field.kind == "timeZone" {
                                    TimeZoneEditor(model: model)
                                } else {
                                    NativeSettingRow(field: field, value: Binding(get: { model.draft[field.key] ?? "" }, set: { model.edit(field.key, $0, band: bandContext) }), changed: model.values[field.key] != model.draft[field.key])
                                }
                            }
                        }.disabled(store.operationTitle != nil || locked || model.loading || readOnly != nil)
                    }
                    if locked { Text("请先保存或撤销另一组设置的修改，再编辑这一组。").font(.caption).foregroundStyle(.secondary) }
                    Label(section.impact, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                } else if model.notice == nil {
                    ContentUnavailableView("尚未读取设置", systemImage: "arrow.clockwise", description: Text("点击“重新读取”后即可编辑。"))
                }
            }
            .sheet(item: $rulesField) { field in RuleEditorSheet(field: field, original: model.draft[field.key] ?? "") { model.draft[field.key] = $0 } }
        }
    }
}

struct ConnectionRequiredView: View {
    @Environment(RouterStore.self) var store
    var body: some View {
        ContentUnavailableView {
            Label("连接路由器后即可管理", systemImage: "wifi.router")
        } description: { Text("概览、设置和固件更新共用同一次登录。") }
        actions: { Button("连接设置") { store.open(.connection) }.buttonStyle(.borderedProminent).tint(.teal) }
    }
}

struct NativeSettingRow: View {
    let field: SettingField
    @Binding var value: String
    var changed = false
    @State private var reveal = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: field.kind == "multiline" ? .top : .center, spacing: 18) {
                HStack(spacing: 6) { if changed { Circle().fill(.teal).frame(width: 5, height: 5) }; Text(field.label.trimmingCharacters(in: .whitespaces)).font(.callout) }.frame(maxWidth: .infinity, alignment: .leading)
                Group {
                    if field.kind == "readonly" {
                        Text(value.isEmpty ? "未设置" : field.options.first { $0.value == value }?.label ?? value).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2).frame(width: 240, alignment: .trailing)
                    } else if field.kind == "toggle" && ["0", "1", ""].contains(value) {
                        Toggle(field.label, isOn: Binding(get: { value == "1" }, set: { value = $0 ? "1" : "0" })).labelsHidden().toggleStyle(.switch).tint(.teal)
                    } else if !field.options.isEmpty {
                        Picker(field.label, selection: $value) {
                            if !field.options.contains(where: { $0.value == value }) { Text(value.isEmpty ? "未设置" : "当前：\(value)").tag(value) }
                            ForEach(field.options) { option in Text(option.label).tag(option.value) }
                        }.labelsHidden().frame(width: 240)
                    } else if field.kind == "multiline" || field.kind == "secretText" {
                        if field.isSecret && !reveal {
                            Button("查看并编辑") { reveal = true }.frame(width: 240, alignment: .trailing)
                        } else {
                            TextEditor(text: $value).font(.system(.caption, design: .monospaced)).frame(width: 280, height: 120).overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                        }
                    } else if field.isSecret {
                        HStack {
                            if reveal { TextField("", text: $value) } else { SecureField("", text: $value) }
                            Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }.buttonStyle(.borderless).help(reveal ? "隐藏" : "显示")
                        }.frame(width: 240).textFieldStyle(.roundedBorder)
                    } else {
                        TextField(field.rangeText ?? "未设置", text: $value).textFieldStyle(.roundedBorder).frame(width: 240)
                    }
                }.accessibilityLabel(field.label)
            }
            if let note = field.note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct SettingsReviewSheet: View {
    @ObservedObject var model: NativeSettingsModel
    var presentation: (SettingField) -> SettingField = { $0 }
    let apply: () -> Void
    @Environment(\.dismiss) var dismiss
    var validation: String? {
        do {
            for change in model.changes { try change.field.validate(change.after) }
            try RouterTimeZoneRules.validate(model.values.merging(model.draft) { _, edited in edited }, changed: Set(model.changes.map(\.field.key)))
            return nil
        }
        catch {
            var message = error.localizedDescription
            for change in model.changes { message = message.replacingOccurrences(of: change.field.label, with: presentation(change.field).label) }
            return message
        }
    }
    private func display(_ value: String, field: SettingField) -> String {
        if value.isEmpty { return "未设置" }
        if field.kind == "toggle", ["0", "1"].contains(value) { return value == "1" ? "启用" : "关闭" }
        if field.kind == "timeZone" { return RouterTimeZones.zone(value)?.label ?? value }
        if field.kind == "dstRule" { return DaylightSavingRule(value)?.summary ?? value }
        return field.options.first { $0.value == value }?.label ?? value
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("确认保存到路由器", systemImage: "checkmark.shield").font(.title2.bold())
            Text(model.section?.title ?? "").foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.changes, id: \.field.key) { change in
                        let field = presentation(change.field)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(field.label).font(.callout.weight(.semibold))
                            if change.field.isSecret { Text("密码或密钥将更新").foregroundStyle(.secondary) }
                            else if change.field.kind == "rules" { Text("规则表将更新").foregroundStyle(.secondary) }
                            else { Text("\(display(change.before, field: field)) → \(display(change.after, field: field))").font(.callout).textSelection(.enabled) }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 300)
            Text(model.section?.impact ?? "").font(.callout).foregroundStyle(.secondary)
            if let validation { Text(validation).foregroundStyle(.red).font(.callout) }
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Button("确认保存", action: apply).buttonStyle(.borderedProminent).tint(.teal).disabled(validation != nil) }
        }.padding(28).frame(width: 540)
    }
}

struct RuleSummary: View {
    let field: SettingField
    let value: String
    let open: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 5) { Text(field.label).font(.callout.weight(.medium)); Text(summary).font(.caption).foregroundStyle(.secondary) }
                Spacer(); Button("编辑规则", action: open)
            }
            if let rows = try? RouterRuleCodec.decode(value, columns: field.columns.count), !rows.isEmpty {
                ForEach(Array(rows.prefix(4).enumerated()), id: \.offset) { index, row in
                    HStack { Text(String(index + 1)).foregroundStyle(.tertiary).frame(width: 20); Text(row.filter { !$0.isEmpty }.joined(separator: "  ·  ")).lineLimit(1).font(.caption.monospaced()) }.padding(.vertical, 3)
                }
                if rows.count > 4 { Text("另有 \(rows.count - 4) 条规则").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
    private var summary: String { (try? RouterRuleCodec.decode(value, columns: field.columns.count)).map { "\($0.count) 条规则" } ?? "当前格式需要进一步适配，原始内容已保留" }
}

struct RuleEditorSheet: View {
    let field: SettingField
    let original: String
    let save: (String) -> Void
    @Environment(\.dismiss) var dismiss
    @State private var rows: [[String]] = []
    @State private var error: String?
    @State private var compatible = true
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Label(field.label, systemImage: "list.bullet.rectangle").font(.title2.bold()); Spacer(); Text("\(rows.count) 条").foregroundStyle(.secondary) }
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { ForEach(field.columns, id: \.self) { Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 160, alignment: .leading) }; Color.clear.frame(width: 24) }
                    ForEach(rows.indices, id: \.self) { index in
                        HStack {
                            ForEach(field.columns.indices, id: \.self) { col in
                                TextField(field.columns[col], text: Binding(get: { rows.indices.contains(index) ? rows[index][col] : "" }, set: { if rows.indices.contains(index) { rows[index][col] = $0 } })).textFieldStyle(.roundedBorder).frame(width: 160)
                            }
                            Button(role: .destructive) { rows.remove(at: index) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                        }
                    }
                }.padding(4)
            }.frame(minHeight: 200, maxHeight: 380)
            if let error { Text(error).foregroundStyle(.orange).font(.callout) }
            HStack {
                Button { rows.append(Array(repeating: "", count: field.columns.count)) } label: { Label("添加规则", systemImage: "plus") }.disabled(!compatible)
                Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保留修改") {
                    do { let value = try RouterRuleCodec.encode(rows, columns: field.columns.count); try field.validate(value); save(value); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).tint(.teal).disabled(!compatible)
            }
            Text("保留后，点击设置页的“保存到路由器”才会生效。").font(.caption).foregroundStyle(.secondary)
        }.padding(26).frame(width: 850)
        .onAppear { do { rows = try RouterRuleCodec.decode(original, columns: field.columns.count) } catch { self.error = error.localizedDescription; compatible = false } }
    }
}
