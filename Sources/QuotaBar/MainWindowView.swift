import AppKit
import ServiceManagement
import SwiftUI

/// 主窗口侧边栏条目：总览 / 各厂商详情 / 设置。
enum SidebarItem: Hashable {
    case overview
    case provider(ProviderKind)
    case settings
}

/// 主窗口：NavigationSplitView 侧边栏布局，承载从弹层搬来的图表与明细。
struct MainWindowView: View {
    @ObservedObject var store: QuotaStore
    @ObservedObject var selection: MainWindowSelection

    var body: some View {
        NavigationSplitView {
            List(selection: $selection.item) {
                Label("总览", systemImage: "chart.line.uptrend.xyaxis")
                    .tag(SidebarItem.overview)
                Section("厂商") {
                    ForEach(ProviderKind.allCases) { kind in
                        // 未检测到的厂商也列出但灰显，保持侧边栏条目稳定不跳动
                        let detected: Bool = {
                            if case .notDetected = store.states[kind] { return false }
                            return true
                        }()
                        Label(kind.name, systemImage: kind.symbol)
                            .foregroundStyle(detected ? kind.tint : .secondary)
                            .tag(SidebarItem.provider(kind))
                    }
                }
                Label("设置", systemImage: "gearshape")
                    .tag(SidebarItem.settings)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            switch selection.item ?? .overview {
            case .overview:
                OverviewView(store: store)
            case .provider(let kind):
                ProviderDetailView(kind: kind, state: store.states[kind] ?? .loading)
            case .settings:
                SettingsView(store: store)
            }
        }
        .task { await store.refresh() }
    }
}

/// 总览页：三个大数字卡片（今日/近7天/近30天）+ 大号趋势图翻页器。
private struct OverviewView: View {
    @ObservedObject var store: QuotaStore

    private var kinds: [ProviderKind] {
        sortedVisibleKinds(states: store.states)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let deltas = tokenDeltas(kinds: kinds, states: store.states) {
                    HStack(spacing: 12) {
                        bigStat(title: "今日用量", value: deltas.today)
                        bigStat(title: "近7天用量", value: deltas.last7)
                        bigStat(title: "近30天用量", value: deltas.last30)
                    }
                }
                TrendChartPager(kinds: kinds, snapshot: { store.states[$0]?.snapshot }, chartHeight: 220)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("总览")
    }

    private func bigStat(title: String, value: Int) -> some View {
        VStack(spacing: 4) {
            Text(value.formatted(.number.notation(.compactName)))
                .font(.system(size: 28, weight: .semibold))
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// 厂商详情页：头部（图标/名称+官网链接/plan·account）、全部配额窗口进度条、余额分组行、
/// 该厂商单独的逐日曲线（30 天）与今日逐小时曲线、DeepSeek 登录入口、错误/提示信息。
private struct ProviderDetailView: View {
    let kind: ProviderKind
    let state: ProviderState
    @State private var nameHovered = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                switch state {
                case .loading:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在检测…").foregroundStyle(.secondary)
                    }
                    .font(.callout)
                case .notDetected:
                    Text("未在本机检测到 \(kind.name) 的登录凭据")
                        .foregroundStyle(.secondary)
                case .unavailable(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                case .ready(let snapshot):
                    readyContent(snapshot)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(kind.name)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: kind.symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(kind.tint)
                .frame(width: 40, height: 40)
                .background(kind.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    if let url = kind.website { NSWorkspace.shared.open(url) }
                } label: {
                    HStack(spacing: 4) {
                        Text(kind.name).font(.title3).fontWeight(.semibold)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(nameHovered ? kind.tint : .primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { nameHovered = $0 }
                .help("打开官网额度页")
                if case .ready(let snapshot) = state {
                    Text([snapshot.plan, snapshot.account].compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? "已连接")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func readyContent(_ snapshot: ProviderSnapshot) -> some View {
        if !snapshot.windows.isEmpty {
            VStack(spacing: 10) {
                ForEach(snapshot.windows) { window in
                    QuotaRow(window: window, tint: kind.tint)
                }
            }
        }

        let balances = displayBalances(kind: kind, snapshot: snapshot)
        if !balances.isEmpty {
            VStack(spacing: 4) {
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

        if let daily = UsageTrendData.daily(kind: kind, days: 30, endingOn: Date(), snapshot: snapshot) {
            VStack(alignment: .leading, spacing: 6) {
                Text("近 30 天逐日用量")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                CombinedTrendChart(trends: [ProviderTrend(kind: kind, days: daily)])
                    .frame(height: 160)
            }
        }

        if let hourly = UsageTrendData.hourly(kind: kind, on: Date(), snapshot: snapshot) {
            let hours = hourly.filter { $0.hour <= Date() }
            if !hours.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("今日逐小时用量")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HourlyTrendChart(trends: [ProviderHourlyTrend(kind: kind, hours: hours)])
                        .frame(height: 160)
                }
            }
        }

        // 登录入口从弹层卡片挪到详情页：DeepSeek 网页用量需应用内登录一次
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
        .navigationTitle("设置")
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
