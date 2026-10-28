import AppKit
import ServiceManagement
import SwiftUI

/// 主窗口：顶栏（作用域切换 + 刷新/设置）+ 总览内容区。
/// 厂商不是独立页面，而是总览页内的作用域；无侧边栏。
struct MainWindowView: View {
    @ObservedObject var store: QuotaStore
    @ObservedObject var selection: MainWindowSelection
    @State private var showSettings = false

    private var visibleKinds: [ProviderKind] {
        sortedVisibleKinds(states: store.states)
    }

    /// 生效作用域：选中的厂商已不可见（如变成未检测到）时回退为总览。
    private var scope: ProviderKind? {
        guard let s = selection.scope, visibleKinds.contains(s) else { return nil }
        return s
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            OverviewView(store: store, selection: selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await store.refresh() }
        .sheet(isPresented: $showSettings) {
            SettingsView(store: store, onDone: { showSettings = false })
        }
    }

    // MARK: - 顶栏

    private var header: some View {
        HStack(spacing: 10) {
            scopeSwitcher
            Spacer()
            refreshStatus
            HeaderIconButton(systemName: "arrow.clockwise", help: "刷新", spinning: store.isRefreshing) {
                Task { await store.refresh(force: true) }
            }
            .disabled(store.isRefreshing)
            HeaderIconButton(systemName: "gearshape", help: "设置") {
                showSettings = true
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var refreshStatus: some View {
        if let date = store.lastRefreshedAt {
            Text("更新于 \(date.formatted(date: .omitted, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - 作用域切换器

    private var scopeSwitcher: some View {
        HStack(spacing: 2) {
            scopeTab(title: "总览", kind: nil)
            ForEach(visibleKinds) { kind in
                scopeTab(title: kind.name, kind: kind)
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func scopeTab(title: String, kind: ProviderKind?) -> some View {
        let selected = scope == kind
        return Button {
            // 包动画切换：统计条数字、图表序列、厂商明细卡的出现/消失都随之过渡
            withAnimation(.snappy(duration: 0.3)) {
                selection.scope = kind
            }
        } label: {
            HStack(spacing: 5) {
                if let kind {
                    Circle().fill(kind.tint).frame(width: 6, height: 6)
                }
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? .primary : .secondary)
            .padding(.horizontal, 13)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color(nsColor: .controlBackgroundColor) : .clear)
                    .shadow(color: selected ? .black.opacity(0.12) : .clear, radius: 2, y: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 通用组件

/// 卡片样式：浅底 + 细描边圆角容器（控制底色在窗口底色上有自然的层次感）。
private extension View {
    func cardStyle(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
    }
}

/// 顶栏/卡片头部的图标按钮：悬停浅底，可附加旋转效果（刷新中）。
private struct HeaderIconButton: View {
    let systemName: String
    let help: String
    var spinning = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovered ? .primary : .secondary)
                .symbolEffect(.rotate, isActive: spinning)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hovered ? Color.primary.opacity(0.08) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}

/// 区块小标题（卡片内分区用）。
private struct SectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
    }
}

// MARK: - 总览页

/// 总览页：统计条（兼图表周期切换）+ 趋势图卡片 + 厂商明细卡（作用域切换器在顶栏）。
/// 页面模板只有一套，切换作用域只是改数据口径：总览为全部厂商合计，厂商为单列数据。
private struct OverviewView: View {
    @ObservedObject var store: QuotaStore
    @ObservedObject var selection: MainWindowSelection
    /// 图表统计周期：由统计条点击驱动，默认近一年（年度点阵图）。
    @State private var chartPeriod: TrendPeriod = .last365

    private var visibleKinds: [ProviderKind] {
        sortedVisibleKinds(states: store.states)
    }

    private var scope: ProviderKind? {
        guard let s = selection.scope, visibleKinds.contains(s) else { return nil }
        return s
    }

    private var scopedKinds: [ProviderKind] {
        scope.map { [$0] } ?? visibleKinds
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let deltas = tokenDeltas(kinds: scopedKinds, states: store.states) {
                        StatStrip(deltas: deltas, selection: $chartPeriod)
                    }

                    TrendCard(
                        kinds: scopedKinds,
                        snapshot: { store.states[$0]?.snapshot },
                        reloadToken: store.lastRefreshedAt,
                        period: $chartPeriod,
                        chartHeight: chartHeight(for: geo.size.height)
                    )

                    if let scope {
                        ProviderDetailCard(kind: scope, state: store.states[scope] ?? .loading)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
    }

    /// 趋势图高度：占窗口内容高度的主体，随窗口等比伸缩并设上下限
    /// （预留统计条、卡片标题/内边距与顶栏的高度）。
    private func chartHeight(for contentHeight: CGFloat) -> CGFloat {
        min(max(contentHeight * 0.52, 200), 420)
    }
}

// MARK: - 统计条（兼图表周期切换器）

/// 一行四格的统计条：今日 / 近7天 / 近30天 / 近一年。
/// 格子同时是图表周期切换器，选中格带强调色浅底与描边。
private struct StatStrip: View {
    let deltas: (today: Int, last7: Int, last30: Int, last365: Int)
    @Binding var selection: TrendPeriod

    var body: some View {
        HStack(spacing: 0) {
            StatCell(title: "今日用量", value: deltas.today, period: .today, selection: $selection)
            separator
            StatCell(title: "近7天用量", value: deltas.last7, period: .last7, selection: $selection)
            separator
            StatCell(title: "近30天用量", value: deltas.last30, period: .last30, selection: $selection)
            separator
            StatCell(title: "近一年用量", value: deltas.last365, period: .last365, selection: $selection)
        }
        .padding(5)
        .cardStyle(padding: 0)
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.07))
            .frame(width: 1)
            .padding(.vertical, 12)
    }
}

private struct StatCell: View {
    let title: String
    let value: Int
    let period: TrendPeriod
    @Binding var selection: TrendPeriod
    @State private var hovered = false

    private var selected: Bool { selection == period }

    var body: some View {
        Button {
            // 包动画切换：选中格底色/描边过渡，下方图表交叉淡入淡出
            withAnimation(.snappy(duration: 0.3)) {
                selection = period
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(value.formatted(.number.notation(.compactName)))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    // 切作用域时数字滚动过渡而不是瞬间跳变
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.10) : (hovered ? Color.primary.opacity(0.04) : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(selected ? 0.35 : 0), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - 趋势图卡片

/// 趋势图卡片：标题 + 当前周期徽标 + 图表区（高度由窗口尺寸推导，随窗口等比伸缩）。
private struct TrendCard: View {
    let kinds: [ProviderKind]
    let snapshot: (ProviderKind) -> ProviderSnapshot?
    let reloadToken: Date?
    @Binding var period: TrendPeriod
    var chartHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel(title: "用量趋势")
                Spacer()
                Text(period.title)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.05), in: Capsule())
            }
            TrendChartPager(kinds: kinds, snapshot: snapshot,
                            chartHeight: chartHeight,
                            period: $period, reloadToken: reloadToken)
        }
        .cardStyle()
    }
}

// MARK: - 厂商明细卡（作用域为单个厂商时显示）

private struct ProviderDetailCard: View {
    let kind: ProviderKind
    let state: ProviderState

    var body: some View {
        switch state {
        case .loading:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在检测 \(kind.name)…").foregroundStyle(.secondary)
            }
            .font(.callout)
            .cardStyle(padding: 22)
        case .notDetected:
            EmptyView()
        case .unavailable(let message):
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message).foregroundStyle(.secondary)
            }
            .font(.callout)
            .cardStyle()
        case .ready(let snapshot):
            content(snapshot)
        }
    }

    @ViewBuilder
    private func content(_ snapshot: ProviderSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header(snapshot)

            if !snapshot.windows.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(title: "配额")
                    ForEach(snapshot.windows) { window in
                        QuotaRow(window: window, tint: kind.tint)
                    }
                }
            }

            let balances = displayBalances(kind: kind, snapshot: snapshot)
            if !balances.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(title: "余额与消费")
                    ForEach(Array(balances.enumerated()), id: \.element.label) { index, group in
                        HStack {
                            Text(group.label).foregroundStyle(.secondary)
                            Spacer()
                            Text(group.text)
                                .monospacedDigit()
                                .fontWeight(.medium)
                        }
                        .font(.callout)
                        if index < balances.count - 1 {
                            Divider().opacity(0.3)
                        }
                    }
                }
            }

            // DeepSeek 用量取自 DeepSeek Harness 的本地登录凭据；
            // 本应用不再提供登录入口，未登录时提示去 DSH 登录。
            if kind == .deepSeek, snapshot.tokenUsage == nil, snapshot.requestCount == nil {
                Label("在 DeepSeek Harness 中登录后即可自动统计用量", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let message = snapshot.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .cardStyle()
    }

    private func header(_ snapshot: ProviderSnapshot) -> some View {
        HStack(spacing: 12) {
            Image(systemName: kind.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(kind.tint)
                .frame(width: 32, height: 32)
                .background(kind.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(kind.name).font(.headline)
                let subtitle = [snapshot.plan, snapshot.account].compactMap { $0 }.joined(separator: " · ")
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let url = kind.website {
                HeaderIconButton(systemName: "arrow.up.right", help: "打开官网额度页") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

// MARK: - 设置

/// 设置弹层：分组卡片样式（通用 / DeepSeek），行内图标 + 控件。
private struct SettingsView: View {
    @ObservedObject var store: QuotaStore
    let onDone: () -> Void
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage(QuotaStore.refreshIntervalKey) private var refreshMinutes = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("设置")
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
                Button("完成", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }

            settingsGroup("通用") {
                SettingsRow(icon: "power", tint: .green, title: "开机启动") {
                    Toggle("", isOn: $launchAtLogin)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .onChange(of: launchAtLogin) { _, newValue in
                            do {
                                if newValue {
                                    try SMAppService.mainApp.register()
                                } else {
                                    try SMAppService.mainApp.unregister()
                                }
                            } catch {
                                // 注册失败（如未签名运行）时把开关回退到系统实际状态
                                launchAtLogin = SMAppService.mainApp.status == .enabled
                            }
                        }
                }
                rowDivider
                SettingsRow(icon: "arrow.clockwise", tint: .blue, title: "刷新频率") {
                    Picker("", selection: $refreshMinutes) {
                        Text("1 分钟").tag(1)
                        Text("5 分钟").tag(5)
                        Text("10 分钟").tag(10)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                    .onChange(of: refreshMinutes) { _, newValue in
                        store.updateRefreshInterval(minutes: newValue)
                    }
                }
            }

            settingsGroup("DeepSeek") {
                SettingsRow(icon: "key.fill", tint: .cyan, title: "登录状态") {
                    HStack(spacing: 6) {
                        Circle().fill(deepSeekStatus.color).frame(width: 7, height: 7)
                        Text(deepSeekStatus.text).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                Text("登录凭据取自 DeepSeek Harness（~/.dsh），请在其应用内完成登录；本应用不要求单独登录。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
        .padding(20)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var rowDivider: some View {
        Divider()
            .opacity(0.4)
            .padding(.leading, 48)
    }

    private func settingsGroup<Content: View>(_ title: String,
                                              @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .cardStyle(padding: 0)
        }
    }

    private var deepSeekStatus: (text: String, color: Color) {
        switch store.states[.deepSeek] {
        case .ready(let snapshot):
            return snapshot.tokenUsage != nil || snapshot.requestCount != nil
                ? ("已登录（用量统计开启）", .green)
                : ("已连接", .green)
        case .notDetected:
            return ("未检测到 DSH 登录", Color.secondary)
        case .unavailable:
            return ("登录已失效或不可用", .orange)
        case .loading, .none:
            return ("检测中…", Color.secondary)
        }
    }
}

/// 设置行：彩色图标 + 标题 + 右侧控件。
private struct SettingsRow<Control: View>: View {
    let icon: String
    let tint: Color
    let title: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(title).font(.callout)
            Spacer()
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
