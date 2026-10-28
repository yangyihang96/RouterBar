import SwiftUI
import RouterCore

/// The system page's 时区, 夏令时更改开始于 and 夏令时更改结束于 rows: a searchable zone list and the daylight saving rule,
/// kept in time_zone, time_zone_dst and time_zone_dstoff the way Advanced_System_Content.asp submits them.
struct TimeZoneEditor: View {
    /// Edited here rather than as rows of their own.
    static let embeddedKeys: Set<String> = ["time_zone_dst", "time_zone_dstoff"]
    @Environment(RouterStore.self) var store
    @ObservedObject var model: NativeSettingsModel
    @State private var choosing = false
    /// time_zone_x as last read from the router.
    @State private var effective: String?

    private var zoneValue: String { model.draft["time_zone"] ?? "" }
    private var zone: RouterTimeZone? { RouterTimeZones.zone(zoneValue) }
    private var ruleText: String { model.draft["time_zone_dstoff"] ?? "" }
    private var draftClock: RouterClockRule? { RouterClockRule(zone: zoneValue, dst: model.draft["time_zone_dst"] ?? "", rule: ruleText) }
    private var savedClock: RouterClockRule? {
        RouterClockRule(zone: model.values["time_zone"] ?? "", dst: model.values["time_zone_dst"] ?? "", rule: model.values["time_zone_dstoff"] ?? "")
    }
    private func changed(_ keys: String...) -> Bool { keys.contains { model.values[$0] != model.draft[$0] } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row("时区", changed: changed("time_zone", "time_zone_dst")) {
                Button { choosing = true } label: {
                    HStack(spacing: 6) {
                        Text(zone?.label ?? (zoneValue.isEmpty ? "未设置" : "当前：\(zoneValue)")).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("时区")
                .accessibilityValue(zone?.label ?? zoneValue)
                .popover(isPresented: $choosing, arrowEdge: .bottom) {
                    TimeZoneList(selection: zoneValue) { select($0); choosing = false }
                }
            }
            if let zone, zone.dst {
                daylightSaving(zone)
            } else if zone != nil {
                Text("该时区不使用夏令时。").font(.caption).foregroundStyle(.secondary)
            }
            comparison
        }
        .task(id: model.readAt) { await readEffective() }
    }

    @ViewBuilder private func daylightSaving(_ zone: RouterTimeZone) -> some View {
        let parsed = DaylightSavingRule(ruleText)
        let defaultRule = zone.defaultRule.flatMap(DaylightSavingRule.init)
        if let shown = parsed ?? defaultRule {
            row("夏令时更改开始于", changed: changed("time_zone_dstoff")) { TransitionPicker(name: "夏令时开始", transition: binding(shown, \.start)) }
            row("夏令时更改结束于", changed: changed("time_zone_dstoff")) { TransitionPicker(name: "夏令时结束", transition: binding(shown, \.end)) }
        }
        if parsed == nil {
            NoticeBanner(message: "路由器保存的夏令时规则“\(ruleText)”无法识别，上方显示的是该时区的默认规则。调整后才会作为修改保存。", tone: .attention)
        } else if parsed?.overlaps == true {
            Text("夏令时的开始与结束不能在同一个月的同一周、同一天（路由器网页同样不允许）。").font(.caption).foregroundStyle(.red)
        }
        if let defaultRule, parsed != defaultRule {
            HStack(alignment: .top, spacing: 12) {
                NoticeBanner(message: "这条规则与固件为该时区提供的默认规则不同。默认规则：\(defaultRule.summary)。", tone: .attention)
                Button("改用默认规则") { model.draft["time_zone_dstoff"] = defaultRule.text }.padding(.top, 10)
            }
        }
    }

    /// The firmware's zoneinfo name for the zone (rc/common.c tz_list) checked against macOS's time zone data, and the
    /// router's clock checked against this Mac as the router page's corrected_timezone() does.
    @ViewBuilder private var comparison: some View {
        if let zone, let iana = zone.iana, let reference = TimeZone(identifier: iana), let clock = draftClock {
            let differences = clock.differences(from: reference, start: .now)
            if differences.isEmpty {
                Label("按当前选择，未来一年路由器时间与 \(iana) 一致（按天对照 macOS 时区数据）。", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                NoticeBanner(message: "按当前选择，未来一年路由器时间会与 \(iana) 不一致（按天对照 macOS 时区数据）："
                             + ClockDifference.summary(differences, in: reference) + "。", tone: .attention)
            }
        }
        if let savedClock, savedClock.secondsFromGMT(for: .now) != TimeZone.current.secondsFromGMT(for: .now) {
            NoticeBanner(message: "提醒：路由器目前的时间（\(ClockDifference.utc(savedClock.secondsFromGMT(for: .now)))）与这台 Mac（\(ClockDifference.utc(TimeZone.current.secondsFromGMT(for: .now)))）不在同一时区。", tone: .attention)
        }
        if let effective, !effective.isEmpty {
            let stale = savedClock.map { $0.text != effective } ?? false
            Text("路由器当前生效的时区设置：\(effective)" + (stale ? "（与已保存的设置不一致，路由器可能尚未重新应用时区）" : ""))
                .font(.caption).foregroundStyle(stale ? .orange : .secondary).textSelection(.enabled)
        }
    }

    private func row<Control: View>(_ title: String, changed: Bool, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 18) {
            HStack(spacing: 6) { if changed { Circle().fill(.teal).frame(width: 5, height: 5) }; Text(title).font(.callout) }
                .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
    }

    private func binding(_ shown: DaylightSavingRule, _ part: WritableKeyPath<DaylightSavingRule, DaylightSavingRule.Transition>) -> Binding<DaylightSavingRule.Transition> {
        Binding(get: { shown[keyPath: part] }, set: { var rule = shown; rule[keyPath: part] = $0; model.draft["time_zone_dstoff"] = rule.text })
    }

    private func select(_ new: RouterTimeZone) {
        model.draft.merge(RouterTimeZoneRules.choosing(new, stored: model.values)) { _, chosen in chosen }
    }

    private func readEffective() async {
        guard model.readAt != nil, let client = try? store.connectedClient() else { effective = nil; return }
        effective = try? await client.readEffectiveTimeZone()
    }
}

/// One of the page's start or end rows: month, week of the month, weekday and hour.
private struct TransitionPicker: View {
    typealias Transition = DaylightSavingRule.Transition
    let name: String
    @Binding var transition: Transition
    var body: some View {
        HStack(spacing: 6) {
            Picker("\(name)：月", selection: $transition.month) { ForEach(Transition.months, id: \.self) { Text("\($0) 月").tag($0) } }.fixedSize()
            Picker("\(name)：第几个", selection: $transition.week) { ForEach(Transition.weeks, id: \.self) { Text(Transition.weekName($0)).tag($0) } }.fixedSize()
            Picker("\(name)：星期", selection: $transition.weekday) { ForEach(Transition.weekdays, id: \.self) { Text(Transition.weekdayName($0)).tag($0) } }.fixedSize()
            Picker("\(name)：时", selection: $transition.hour) { ForEach(Transition.hours, id: \.self) { Text("\($0):00").tag($0) } }.fixedSize()
        }.labelsHidden()
    }
}

/// The page's time zone list with a search field; the router's current zone is marked and scrolled into view.
private struct TimeZoneList: View {
    let selection: String
    let choose: (RouterTimeZone) -> Void
    @State private var query = ""
    @FocusState private var searching: Bool
    var body: some View {
        let zones = RouterTimeZones.search(query)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索城市、GMT+10 或 Australia", text: $query).textFieldStyle(.plain).focused($searching)
            }.padding(12)
            Divider()
            if zones.isEmpty {
                ContentUnavailableView.search(text: query).frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(zones) { zone in
                        Button { choose(zone) } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(zone.label)
                                    if let iana = zone.iana { Text(iana).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer(minLength: 8)
                                if zone.dst {
                                    Text("夏令时").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(Color.teal.opacity(0.12), in: Capsule())
                                }
                                Image(systemName: "checkmark").foregroundStyle(.teal).opacity(zone.value == selection ? 1 : 0)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).id(zone.value)
                    }
                    .listStyle(.plain)
                    .onAppear { proxy.scrollTo(selection, anchor: .center) }
                }
            }
        }
        .frame(width: 440, height: 480)
        .onAppear { searching = true }
    }
}
