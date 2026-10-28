import AppKit
import ServiceManagement
import SwiftUI

/// 主窗口：顶栏（作用域切换 + 设置齿轮弹窗）+ 总览内容区。
/// 厂商不是独立页面，而是总览页内的作用域；无侧边栏。
struct MainWindowView: View {
    @ObservedObject var store: QuotaStore
    @ObservedObject var selection: MainWindowSelection
    @State private var showSettings = false
    @State private var gearHovered = false

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
            Divider()
            OverviewView(store: store, selection: selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await store.refresh() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            scopeSwitcher
            Spacer()
            settingsButton
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color(nsColor: .underPageBackgroundColor))
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

    // MARK: - 设置（齿轮按钮 + 弹窗）

    private var settingsButton: some View {
        Button { showSettings.toggle() } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(gearHovered ? Color.primary.opacity(0.08) : Color.primary.opacity(0.05))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { gearHovered = $0 }
        .sheet(isPresented: $showSettings) {
            VStack(spacing: 0) {
                HStack {
                    Text("设置")
                        .font(.headline)
                    Spacer()
                    Button("完成") { showSettings = false }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                SettingsView(store: store)
                    .frame(width: 400)
            }
            .padding(.bottom, 8)
        }
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

/// 总览页：三栏统计卡 + 趋势图翻页器 + 厂商明细卡（作用域切换器在顶栏）。
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
                                    chartHeight: 220, period: $chartPeriod,
                                    reloadToken: store.lastRefreshedAt)
                }

                if let scope {
                    providerDetail(kind: scope)
                }
            }
            .padding(20)
            .padding(.top, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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

            // DeepSeek 用量取自 DeepSeek Harness 的本地登录凭据；
            // 本应用不再提供登录入口，未登录时提示去 DSH 登录。
            if kind == .deepSeek, snapshot.tokenUsage == nil, snapshot.requestCount == nil {
                Label("在 DeepSeek Harness 中登录后即可自动统计用量",
                      systemImage: "info.circle")
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
                    Text("登录状态")
                    Spacer()
                    Text(deepSeekStatus)
                        .foregroundStyle(.secondary)
                }
                Text("登录凭据取自 DeepSeek Harness（~/.dsh），请在其应用内完成登录；本应用不要求单独登录。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(maxWidth: 560)
    }

    private var deepSeekStatus: String {
        switch store.states[.deepSeek] {
        case .ready(let snapshot):
            return snapshot.tokenUsage != nil || snapshot.requestCount != nil ? "已登录（用量统计开启）" : "已连接"
        case .notDetected:
            return "未检测到 DSH 登录"
        case .unavailable:
            return "登录已失效或不可用"
        case .loading, .none:
            return "检测中…"
        }
    }
}
