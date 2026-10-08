import AppKit
import ServiceManagement
import SwiftUI

/// 主窗口侧边栏条目：总览 / 设置。厂商不再是侧边栏页面，而是总览页内的作用域。
enum SidebarItem: Hashable {
    case overview
    case settings
}

/// 主窗口：自绘固定侧边栏布局（不用 NavigationSplitView——它自动注入的收起按钮
/// 在 macOS 26 上渲染成乱跑的悬浮胶囊，且这个窗口不需要收起侧边栏）。
struct MainWindowView: View {
    @ObservedObject var store: QuotaStore
    @ObservedObject var selection: MainWindowSelection

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 180)
                .frame(maxHeight: .infinity)
                .background(Color(nsColor: .underPageBackgroundColor))

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await store.refresh() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            SidebarRow(title: "总览", symbol: "chart.line.uptrend.xyaxis", tint: .accentColor,
                       selected: currentItem == .overview) {
                selection.item = .overview
            }
            SidebarRow(title: "设置", symbol: "gearshape", tint: .accentColor,
                       selected: currentItem == .settings) {
                selection.item = .settings
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
    }

    private var currentItem: SidebarItem {
        selection.item ?? .overview
    }

    @ViewBuilder
    private var detail: some View {
        switch currentItem {
        case .overview:
            OverviewView(store: store, selection: selection)
        case .settings:
            SettingsView(store: store)
        }
    }
}

/// 侧边栏条目：选中态为 accent 圆角底 + 白字，未选中为透明底 + 品牌色图标。
private struct SidebarRow: View {
    let title: String
    let symbol: String
    let tint: Color
    var dimmed = false
    var indented = false
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected ? .white : tint)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? .white : (dimmed ? .secondary : .primary))
                Spacer()
            }
            .padding(.leading, indented ? 18 : 8)
            .padding(.trailing, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color.accentColor : (hovered ? Color.primary.opacity(0.06) : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// 通用卡片容器：圆角浅底 + 内边距，标题小字置顶。
private struct DetailCard<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// 总览页：作用域切换器（总览/各厂商）+ 三栏统计卡 + 趋势图翻页器 + 厂商明细卡。
/// 页面模板只有一套，切换作用域只是改数据口径：总览为全部厂商合计，厂商为单列数据。
private struct OverviewView: View {
    @ObservedObject var store: QuotaStore
    @ObservedObject var selection: MainWindowSelection
    /// 图表统计周期：由统计卡片点击驱动，默认近一年（年度点阵图）。
    @State private var chartPeriod: TrendPeriod = .last365

    private var visibleKinds: [ProviderKind] {
        sortedVisibleKinds(states: store.states)
    }

    /// 生效作用域：选中的厂商已不可见（如变成未检测到）时回退为总览。
    private var scope: ProviderKind? {
        guard let s = selection.scope, visibleKinds.contains(s) else { return nil }
        return s
    }

    private var scopedKinds: [ProviderKind] {
        scope.map { [$0] } ?? visibleKinds
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                scopeSwitcher

                if let deltas = tokenDeltas(kinds: scopedKinds, states: store.states) {
                    HStack(spacing: 12) {
                        bigStat(title: "今日用量", value: deltas.today, period: .today)
                        bigStat(title: "近7天用量", value: deltas.last7, period: .last7)
                        bigStat(title: "近30天用量", value: deltas.last30, period: .last30)
                        bigStat(title: "近一年用量", value: deltas.last365, period: .last365)
                    }
                }

                DetailCard {
                    TrendChartPager(kinds: scopedKinds, snapshot: { store.states[$0]?.snapshot },
                                    chartHeight: 220, period: $chartPeriod)
                }

                if let scope {
                    providerDetail(kind: scope)
                }
            }
            .padding(20)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 作用域切换器

    private var scopeSwitcher: some View {
        HStack(spacing: 4) {
            scopeTab(title: "总览", kind: nil)
            ForEach(visibleKinds) { kind in
                scopeTab(title: kind.name, kind: kind)
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func scopeTab(title: String, kind: ProviderKind?) -> some View {
        let selected = scope == kind
        return Button {
            selection.scope = kind
        } label: {
            HStack(spacing: 6) {
                if let kind {
                    Circle().fill(kind.tint).frame(width: 7, height: 7)
                }
                Text(title)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color(nsColor: .controlBackgroundColor) : .clear)
                    .shadow(color: selected ? .black.opacity(0.14) : .clear, radius: 2, y: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 厂商明细（作用域为单个厂商时显示）

    @ViewBuilder
    private func providerDetail(kind: ProviderKind) -> some View {
        let state = store.states[kind] ?? .loading
        switch state {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在检测…").foregroundStyle(.secondary)
            }
            .font(.callout)
        case .notDetected:
            EmptyView()
        case .unavailable(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .ready(let snapshot):
            let subtitle = [snapshot.plan, snapshot.account].compactMap { $0 }.joined(separator: " · ")
            if !snapshot.windows.isEmpty {
                DetailCard {
                    HStack(spacing: 6) {
                        Text("配额")
                            .font(.caption).fontWeight(.medium).foregroundStyle(.secondary)
                        if !subtitle.isEmpty {
                            Text(subtitle).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    VStack(spacing: 10) {
                        ForEach(snapshot.windows) { window in
                            QuotaRow(window: window, tint: kind.tint)
                        }
                    }
                }
            }

            let balances = displayBalances(kind: kind, snapshot: snapshot)
            if !balances.isEmpty {
                DetailCard {
                    HStack(spacing: 6) {
                        Text("余额与消费")
                            .font(.caption).fontWeight(.medium).foregroundStyle(.secondary)
                        if snapshot.windows.isEmpty, !subtitle.isEmpty {
                            Text(subtitle).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    VStack(spacing: 6) {
                        ForEach(balances, id: \.label) { group in
                            HStack {
                                Text(group.label).foregroundStyle(.secondary)
                                Spacer()
                                Text(group.text)
                                    .monospacedDigit()
                                    .fontWeight(.medium)
                            }
                            .font(.callout)
                        }
                    }
                }
            }

            // DeepSeek 网页用量需应用内登录一次
            if kind == .deepSeek, snapshot.tokenUsage == nil, snapshot.requestCount == nil {
                Button {
                    DeepSeekWebSession.shared.showLoginWindow()
                } label: {
                    Label("登录 DeepSeek 获取今日用量", systemImage: "person.crop.circle.badge.plus")
                        .font(.callout)
                        .foregroundStyle(kind.tint)
                }
                .buttonStyle(.plain)
                .help("在应用内登录 DeepSeek 开放平台，自动统计今日调用次数与消耗")
            }

            if let message = snapshot.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// 统计卡：同时是图表周期切换器，选中卡带品牌色描边。
    private func bigStat(title: String, value: Int, period: TrendPeriod) -> some View {
        let selected = chartPeriod == period
        return Button {
            chartPeriod = period
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Text(value.formatted(.number.notation(.compactName)))
                    .font(.system(size: 26, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(selected ? 0.6 : 0), lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 设置页：开机启动、刷新频率、DeepSeek 登录管理。
private struct SettingsView: View {
    @ObservedObject var store: QuotaStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage(QuotaStore.refreshIntervalKey) private var refreshMinutes = 5

    var body: some View {
        Form {
            Section("通用") {
                Toggle("开机启动", isOn: $launchAtLogin)
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
                Picker("刷新频率", selection: $refreshMinutes) {
                    Text("1 分钟").tag(1)
                    Text("5 分钟").tag(5)
                    Text("10 分钟").tag(10)
                }
                .onChange(of: refreshMinutes) { _, newValue in
                    store.updateRefreshInterval(minutes: newValue)
                }
            }
            Section("DeepSeek") {
                HStack {
                    Text(deepSeekStatus)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("打开登录窗口") {
                        DeepSeekWebSession.shared.showLoginWindow()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(maxWidth: 560)
    }

    private var deepSeekStatus: String {
        switch store.states[.deepSeek] {
        case .ready(let snapshot):
            return snapshot.tokenUsage != nil || snapshot.requestCount != nil ? "已登录（网页用量统计开启）" : "已连接"
        case .notDetected:
            return "未登录"
        case .unavailable:
            return "登录已失效或不可用"
        case .loading, .none:
            return "检测中…"
        }
    }
}
