import AppKit
import Charts
import SwiftUI

/// 透明毛玻璃背景：behindWindow 混合模式让面板真正透出并模糊桌面，
/// hudWindow 材质比 ultraThinMaterial 更轻更透（菜单栏 HUD 同款质感）。
private struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var opacity: Double = 1.0

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: NSVisualEffectView) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
        view.alphaValue = opacity
    }
}

/// 单页面板：顶部为今日/本周/本月 token 总用量，下方为圆角厂商卡片；
/// 每张卡片底部内嵌近 7 天逐日用量迷你曲线（有本地日志的厂商为精确值，
/// 其余为采样增量估算）。
struct DashboardView: View {
    @ObservedObject var store: QuotaStore
    @State private var refreshHovered = false
    /// 内容高度变化回调：AppDelegate 据此更新 popover 尺寸，实现窗口随条目自适应。
    var onContentHeightChange: ((CGFloat) -> Void)?

    /// 卡片列表区（ScrollView）最大高度：条目再多也不超过此高度，超出滚动。
    static let maxContentHeight: CGFloat = 560

    /// 可见厂商按「token plan → API → free」排序，free 统一排最下方；同档保持稳定顺序。
    fileprivate var sortedKinds: [ProviderKind] {
        let visible = ProviderKind.allCases.filter {
            if case .notDetected = store.states[$0] { return false }
            return true
        }
        return visible.sorted { lhs, rhs in
            let lt = store.states[lhs]?.tier ?? .free
            let rt = store.states[rhs]?.tier ?? .free
            if lt != rt { return lt < rt }
            return lhs.rawValue < rhs.rawValue
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            summarySection

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(sortedKinds) { kind in
                        ProviderCard(kind: kind, state: store.states[kind] ?? .loading)
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: Self.maxContentHeight)

            Divider().opacity(0.35)
            footer
        }
        .padding(14)
        .frame(width: 350)
        .background(VisualEffectBackground(opacity: 0.7))
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { onContentHeightChange?(geo.size.height) }
                    .onChange(of: geo.size.height) { _, newHeight in
                        onContentHeightChange?(newHeight)
                    }
            }
        )
        .fixedSize(horizontal: false, vertical: true)
        .task { await store.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .dsWebUsageUpdated)) { _ in
            Task { await store.refresh(force: true) }
        }
    }

    // MARK: - 顶部总用量

    /// 各厂商 Token 计数器在今日/本周/本月内的增量之和；无任何厂商返回 token 用量时为 nil。
    /// 本周以周一为起点（国内习惯）。有精确分解（本地日志）的厂商用精确值，其余用采样增量估算。
    private var tokenDeltas: (today: Int, week: Int, month: Int)? {
        let now = Date()
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        let dayStart = cal.startOfDay(for: now)
        let weekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? dayStart
        let monthStart = cal.dateInterval(of: .month, for: now)?.start ?? dayStart
        var today = 0, week = 0, month = 0, found = false
        for kind in sortedKinds {
            guard case .ready(let snapshot) = store.states[kind] else { continue }
            if let breakdown = snapshot.tokenBreakdown {
                found = true
                today += breakdown.today
                week += breakdown.week
                month += breakdown.month
            } else if snapshot.tokenUsage != nil {
                found = true
                today += Int(UsageHistory.shared.delta(kind: kind, key: "tokens", since: dayStart, now: now) ?? 0)
                week += Int(UsageHistory.shared.delta(kind: kind, key: "tokens", since: weekStart, now: now) ?? 0)
                month += Int(UsageHistory.shared.delta(kind: kind, key: "tokens", since: monthStart, now: now) ?? 0)
            }
        }
        return found ? (today, week, month) : nil
    }

    @ViewBuilder
    private var summarySection: some View {
        if let deltas = tokenDeltas {
            VStack(spacing: 6) {
                HStack(spacing: 0) {
                    tokenStat(title: "今日用量", value: deltas.today)
                    tokenStat(title: "本周用量", value: deltas.week)
                    tokenStat(title: "本月用量", value: deltas.month)
                }
                Text("Codex / Kimi Code 为本地日志精确统计，其余为采样增量估算")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 6)

            Divider().opacity(0.35)
        }
    }

    private func tokenStat(title: String, value: Int) -> some View {
        VStack(spacing: 2) {
            Text(value.formatted(.number.notation(.compactName)))
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            Label("仅在本机读取认证", systemImage: "lock.fill")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                Task { await store.refresh(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .symbolEffect(.rotate, isActive: store.isRefreshing)
                    .foregroundStyle(refreshHovered ? .primary : .secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { refreshHovered = $0 }
            .help("刷新")
            .disabled(store.isRefreshing)
        }
        .padding(.top, 10)
    }
}

private struct ProviderCard: View {
    let kind: ProviderKind
    let state: ProviderState
    @State private var nameHovered = false

    /// 卡片迷你趋势的近 7 天逐日序列：本地日志精确值优先，采样增量估算兜底；
    /// 7 天全为 0 时不展示。
    private var trendDays: [DailyTokenUsage]? {
        guard case .ready(let snapshot) = state else { return nil }
        if let daily = snapshot.dailyTokens {
            return daily.contains(where: { $0.tokens > 0 }) ? daily : nil
        }
        guard snapshot.tokenUsage != nil else { return nil }
        let days = UsageHistory.shared.dailyDeltas(kind: snapshot.kind, key: "tokens", days: 7)
        return days.contains(where: { $0.tokens > 0 }) ? days : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(kind.tint)
                    .frame(width: 24, height: 24)
                    .background(kind.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Button {
                        if let url = kind.website { NSWorkspace.shared.open(url) }
                    } label: {
                        HStack(spacing: 3) {
                            Text(kind.name).font(.system(size: 13, weight: .semibold))
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.tertiary)
                        }
                        .foregroundStyle(nameHovered ? kind.tint : .primary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { nameHovered = $0 }
                    .help("打开官网额度页")
                    subtitle
                }

                Spacer()
                trailingSummary
            }

            if case .ready(let snapshot) = state {
                if !snapshot.windows.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(snapshot.windows.prefix(4)) { window in
                            QuotaRow(window: window, tint: kind.tint)
                        }
                    }
                }
                if !snapshot.balances.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(snapshot.balances) { balance in
                            HStack {
                                Text(balance.label).foregroundStyle(.secondary)
                                Spacer()
                                Text(balanceText(balance))
                                    .monospacedDigit()
                                    .fontWeight(.medium)
                            }
                            .font(.caption)
                        }
                    }
                }
                if snapshot.tokenUsage != nil || snapshot.requestCount != nil {
                    VStack(spacing: 4) {
                        if let tokens = snapshot.tokenUsage {
                            HStack {
                                // DeepSeek 的用量接口按近 30 天汇总，其余厂商为今日口径
                                Text(kind == .deepSeek ? "Tokens · 近30天" : "Tokens · 今日").foregroundStyle(.secondary)
                                Spacer()
                                Text(tokens.formatted(.number.notation(.compactName)))
                                    .monospacedDigit()
                                    .fontWeight(.medium)
                            }
                        }
                        if let requests = snapshot.requestCount {
                            HStack {
                                Text(kind == .deepSeek ? "请求 · 近30天" : "请求").foregroundStyle(.secondary)
                                Spacer()
                                Text(requests.formatted())
                                    .monospacedDigit()
                                    .fontWeight(.medium)
                            }
                        }
                    }
                    .font(.caption)
                }
                if let days = trendDays {
                    MiniTrend(days: days, tint: kind.tint)
                }
                if kind == .deepSeek, snapshot.tokenUsage == nil, snapshot.requestCount == nil {
                    Button {
                        DeepSeekWebSession.shared.showLoginWindow()
                    } label: {
                        Label("登录 DeepSeek 获取今日用量", systemImage: "person.crop.circle.badge.plus")
                            .font(.caption)
                            .foregroundStyle(kind.tint)
                    }
                    .buttonStyle(.plain)
                    .help("在应用内登录 DeepSeek 开放平台，自动统计今日调用次数与消耗")
                }
                if let message = snapshot.message {
                    Text(message).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var subtitle: some View {
        switch state {
        case .loading:
            Text("正在检测…").foregroundStyle(.secondary)
        case .notDetected:
            EmptyView()
        case .unavailable(let message):
            Text(message).foregroundStyle(.tertiary).lineLimit(1)
        case .ready(let snapshot):
            Text([snapshot.plan, snapshot.account].compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? "已连接")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var trailingSummary: some View {
        switch state {
        case .loading:
            ProgressView().controlSize(.small)
        case .notDetected:
            EmptyView()
        case .unavailable:
            Image(systemName: "minus.circle").foregroundStyle(.tertiary)
        case .ready(let snapshot):
            if let balance = snapshot.balances.first {
                Text(balanceText(balance)).font(.caption).fontWeight(.semibold).monospacedDigit()
            } else if let window = snapshot.windows.first {
                Text(window.fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.caption).fontWeight(.semibold).monospacedDigit()
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
    }

    private func balanceText(_ balance: MoneyBalance) -> String {
        if balance.currency.lowercased() == "credits" {
            return "\(balance.amount.formatted(.number.precision(.fractionLength(0...2)))) credits"
        }
        return "\(balance.currency) \(balance.amount.formatted(.number.precision(.fractionLength(2))))"
    }
}

/// 卡片底部的近 7 天逐日用量迷你趋势：平滑曲线 + 浅渐变面积，无坐标轴，右端为今天。
private struct MiniTrend: View {
    let days: [DailyTokenUsage]
    let tint: Color

    var body: some View {
        Chart(days, id: \.day) { item in
            LineMark(
                x: .value("日期", item.day),
                y: .value("Tokens", item.tokens)
            )
            .foregroundStyle(tint)
            .interpolationMethod(.catmullRom)
            .lineStyle(StrokeStyle(lineWidth: 1.5))
            AreaMark(
                x: .value("日期", item.day),
                y: .value("Tokens", item.tokens)
            )
            .foregroundStyle(tint.opacity(0.12))
            .interpolationMethod(.catmullRom)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 26)
    }
}

private struct QuotaRow: View {
    let window: QuotaWindow
    let tint: Color

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(window.title)
                Spacer()
                Text("已用 \(window.fraction.formatted(.percent.precision(.fractionLength(0))))")
                    .monospacedDigit()
                if let resetAt = window.resetAt {
                    Text("·").foregroundStyle(.tertiary)
                    Text(resetAt, style: .relative)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            ProgressView(value: window.fraction)
                .progressViewStyle(.linear)
                .tint(progressTint)
        }
    }

    private var progressTint: Color {
        if window.fraction >= 0.9 { return .red }
        if window.fraction >= 0.7 { return .orange }
        return tint
    }
}

private extension ProviderState {
    var tier: PlanTier {
        if case .ready(let snapshot) = self { return snapshot.planTier }
        return .free
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
