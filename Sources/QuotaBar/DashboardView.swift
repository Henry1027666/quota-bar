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

struct DashboardView: View {
    @ObservedObject var store: QuotaStore
    @State private var refreshHovered = false
    @State private var trendHovered = false
    @State private var showingTrends = false
    /// 内容高度变化回调：AppDelegate 据此更新 popover 尺寸，实现窗口随条目自适应。
    var onContentHeightChange: ((CGFloat) -> Void)?

    /// 内容区（ScrollView）最大高度：条目再多也不超过此高度，超出滚动。
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
        ZStack {
            if showingTrends {
                TrendsPage(store: store, onBack: { showingTrends = false })
            } else {
                mainContent
            }
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

    private var mainContent: some View {
        VStack(spacing: 0) {
            // 顶栏：右侧综合趋势入口
            HStack {
                Spacer()
                Button { showingTrends = true } label: {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(trendHovered ? .primary : .secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { trendHovered = $0 }
                .help("综合趋势")
            }
            .padding(.bottom, 6)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(sortedKinds.enumerated()), id: \.element) { index, kind in
                        ProviderCard(kind: kind, state: store.states[kind] ?? .loading)
                        if index < sortedKinds.count - 1 {
                            Divider().opacity(0.35)
                                .padding(.horizontal, 2)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: Self.maxContentHeight)

            Divider().opacity(0.35)
            footer
        }
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
                                // DeepSeek 的用量接口按近 30 天汇总，其余厂商为当前周期口径
                                Text(kind == .deepSeek ? "Tokens · 近30天" : "Tokens").foregroundStyle(.secondary)
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
        .padding(.vertical, 10)
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

/// 综合趋势页：左上角返回，逐厂商展示近 7 天趋势；无采样时展示占位而非隐藏。
private struct TrendsPage: View {
    @ObservedObject var store: QuotaStore
    let onBack: () -> Void
    @State private var backHovered = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(backHovered ? .primary : .secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { backHovered = $0 }
                .help("返回")
                Text("综合趋势")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.bottom, 8)

            Divider().opacity(0.35)

            if let deltas = tokenDeltas {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 0) {
                        tokenStat(title: "今日用量", value: deltas.today)
                        tokenStat(title: "本周用量", value: deltas.week)
                        tokenStat(title: "本月用量", value: deltas.month)
                    }
                    Text("Codex 为本地日志精确统计，其余为采样增量估算")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 8)

                Divider().opacity(0.35)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(readySnapshots, id: \.kind) { snapshot in
                        trendSection(for: snapshot)
                        if snapshot.kind != readySnapshots.last?.kind {
                            Divider().opacity(0.35).padding(.horizontal, 2)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: DashboardView.maxContentHeight)
        }
    }

    /// 按主面板同样的排序展示已就绪的厂商。
    private var readySnapshots: [ProviderSnapshot] {
        let kinds = ProviderKind.allCases.filter {
            if case .notDetected = store.states[$0] { return false }
            return true
        }.sorted { lhs, rhs in
            let lt = store.states[lhs]?.tier ?? .free
            let rt = store.states[rhs]?.tier ?? .free
            return lt != rt ? lt < rt : lhs.rawValue < rhs.rawValue
        }
        return kinds.compactMap { kind in
            guard case .ready(let snapshot) = store.states[kind] else { return nil }
            return snapshot
        }
    }

    /// 各厂商 Token 计数器在今日/本周/本月内的增量之和；无任何厂商返回 token 用量时为 nil。
    /// 本周以周一为起点（国内习惯）。有精确分解（如 Codex 本地日志）的厂商用精确值，
    /// 其余用采样增量估算。
    private var tokenDeltas: (today: Int, week: Int, month: Int)? {
        let now = Date()
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        let dayStart = cal.startOfDay(for: now)
        let weekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? dayStart
        let monthStart = cal.dateInterval(of: .month, for: now)?.start ?? dayStart
        var today = 0, week = 0, month = 0, found = false
        for snapshot in readySnapshots {
            if let breakdown = snapshot.tokenBreakdown {
                found = true
                today += breakdown.today
                week += breakdown.week
                month += breakdown.month
            } else if snapshot.tokenUsage != nil {
                found = true
                today += Int(UsageHistory.shared.delta(kind: snapshot.kind, key: "tokens", since: dayStart, now: now) ?? 0)
                week += Int(UsageHistory.shared.delta(kind: snapshot.kind, key: "tokens", since: weekStart, now: now) ?? 0)
                month += Int(UsageHistory.shared.delta(kind: snapshot.kind, key: "tokens", since: monthStart, now: now) ?? 0)
            }
        }
        return found ? (today, week, month) : nil
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

    @ViewBuilder
    private func trendSection(for snapshot: ProviderSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: snapshot.kind.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(snapshot.kind.tint)
                    .frame(width: 18, height: 18)
                    .background(snapshot.kind.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                Text(snapshot.kind.name).font(.caption).fontWeight(.medium)
                Spacer()
                Text("近 7 天").font(.caption2).foregroundStyle(.tertiary)
            }
            if let key = UsageHistory.shared.displayKey(for: snapshot) {
                TrendChart(
                    points: UsageHistory.shared.points(kind: snapshot.kind, key: key),
                    tint: snapshot.kind.tint,
                    isPercent: key.hasPrefix("window:"),
                    emptyText: "暂无足够采样数据，使用中会每 5 分钟自动积累"
                )
            } else {
                Text("该厂商没有可跟踪的额度序列")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
        }
        .padding(.vertical, 8)
    }
}

/// 近 7 天用量趋势图：折线 + 渐变面积，隐藏坐标轴；数据不足时显示占位文字。
/// 窗口类序列固定 0~1 纵轴（用量占比）；余额类按数据自适应。
private struct TrendChart: View {
    let points: [UsageHistory.Point]
    let tint: Color
    let isPercent: Bool
    let emptyText: String

    var body: some View {
        if points.count >= 3 {
            Chart {
                ForEach(points, id: \.ts) { point in
                    LineMark(
                        x: .value("时间", Date(timeIntervalSince1970: point.ts)),
                        y: .value("值", point.value)
                    )
                    .foregroundStyle(tint)
                    AreaMark(
                        x: .value("时间", Date(timeIntervalSince1970: point.ts)),
                        y: .value("值", point.value)
                    )
                    .foregroundStyle(tint.opacity(0.15))
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: yDomain)
            .frame(height: 56)
        } else {
            Text(emptyText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, minHeight: 56)
        }
    }

    private var yDomain: ClosedRange<Double> {
        if isPercent { return 0...1 }
        let values = points.map(\.value)
        let lo = values.min() ?? 0
        let hi = values.max() ?? 1
        let pad = max((hi - lo) * 0.1, 1e-6)
        return (lo - pad)...(hi + pad)
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
