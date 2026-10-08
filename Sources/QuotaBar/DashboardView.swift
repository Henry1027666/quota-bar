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
    /// 顶部统计选中的统计周期，下方趋势图随之切换。
    @State private var period: TrendPeriod = .today
    /// 图表翻页偏移：0 为当前周期，每翻一页回退一个周期（日/周/月随 period）。
    @State private var pageOffset = 0
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
        .padding(.horizontal, 14)
        .padding(.top, 24)
        .padding(.bottom, 14)
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

    /// 各厂商 Token 计数器在今日 / 近 7 天 / 近 30 天（滚动窗口，含今天）内的用量之和；
    /// 无任何厂商返回 token 用量时为 nil。有精确分解（本地日志 / 逐日接口）的厂商用精确值，
    /// 其余用采样增量估算。
    private var tokenDeltas: (today: Int, last7: Int, last30: Int)? {
        let now = Date()
        let cal = Calendar(identifier: .gregorian)
        let dayStart = cal.startOfDay(for: now)
        let last7Start = cal.date(byAdding: .day, value: -6, to: dayStart) ?? dayStart
        let last30Start = cal.date(byAdding: .day, value: -29, to: dayStart) ?? dayStart
        var today = 0, last7 = 0, last30 = 0, found = false
        for kind in sortedKinds {
            guard case .ready(let snapshot) = store.states[kind] else { continue }
            if let breakdown = snapshot.tokenBreakdown {
                found = true
                today += breakdown.today
                last7 += breakdown.last7
                last30 += breakdown.last30
            } else if snapshot.tokenUsage != nil {
                found = true
                today += Int(UsageHistory.shared.delta(kind: kind, key: "tokens", since: dayStart, now: now) ?? 0)
                last7 += Int(UsageHistory.shared.delta(kind: kind, key: "tokens", since: last7Start, now: now) ?? 0)
                last30 += Int(UsageHistory.shared.delta(kind: kind, key: "tokens", since: last30Start, now: now) ?? 0)
            }
        }
        return found ? (today, last7, last30) : nil
    }

    @ViewBuilder
    private var summarySection: some View {
        let deltas = tokenDeltas
        let trends = trends
        if deltas != nil || !trends.isEmpty {
            VStack(spacing: 8) {
                if let deltas {
                    HStack(spacing: 4) {
                        periodStat(title: "今日用量", value: deltas.today, period: .today)
                        periodStat(title: "近7天用量", value: deltas.last7, period: .last7)
                        periodStat(title: "近30天用量", value: deltas.last30, period: .last30)
                    }
                }
                if !trends.isEmpty {
                    chartPager
                }
            }
            .padding(.bottom, 6)

            Divider().opacity(0.35)
        }
    }

    /// 图表区：翻页头（‹ 日期范围 ›）+ 固定高度内容，切换周期或翻页时窗口不抖动。
    private static let chartHeight: CGFloat = 96

    @ViewBuilder
    private var chartPager: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Button { pageOffset -= 1 } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text(pageRangeTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button { pageOffset += 1 } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(pageOffset == 0)
                .opacity(pageOffset == 0 ? 0.25 : 1)
                Spacer()
            }

            Group {
                switch period {
                case .today:
                    if pagedHourlyTrends.isEmpty {
                        chartPlaceholder("该日无逐小时用量数据")
                    } else {
                        HourlyTrendChart(trends: pagedHourlyTrends)
                    }
                case .last7:
                    if pagedDailyTrends.isEmpty {
                        chartPlaceholder("该时段无用量数据")
                    } else {
                        CombinedTrendChart(trends: pagedDailyTrends)
                    }
                case .last30:
                    if pagedDailyTrends.isEmpty {
                        chartPlaceholder("该时段无用量数据")
                    } else {
                        ContributionGrid(trends: pagedDailyTrends)
                    }
                }
            }
            .frame(height: Self.chartHeight)
        }
    }

    /// 当前页锚定的窗口末日：pageOffset 为 0 时是今天，每翻一页回退一个周期。
    private var pageEndDay: Date {
        let step = switch period {
        case .today: 1
        case .last7: 7
        case .last30: 30
        }
        return Calendar.current.date(byAdding: .day, value: pageOffset * step, to: Date()) ?? Date()
    }

    /// 翻页头的日期范围文案。
    private var pageRangeTitle: String {
        let cal = Calendar(identifier: .gregorian)
        let end = cal.startOfDay(for: pageEndDay)
        switch period {
        case .today:
            return end.formatted(.dateTime.month(.wide).day().weekday(.abbreviated))
        case .last7, .last30:
            let days = period == .last7 ? 7 : 30
            let start = cal.date(byAdding: .day, value: -(days - 1), to: end) ?? end
            return "\(start.formatted(.dateTime.month(.wide).day())) – \(end.formatted(.dateTime.month(.wide).day()))"
        }
    }

    /// 当前页的厂商逐日序列（近 7 天曲线 / 近 30 天点阵共用）。
    private var pagedDailyTrends: [ProviderTrend] {
        let days = period == .last7 ? 7 : 30
        return sortedKinds.compactMap { kind in
            guard let result = UsageTrendData.daily(
                kind: kind, days: days, endingOn: pageEndDay,
                snapshot: store.states[kind]?.snapshot
            ) else { return nil }
            return ProviderTrend(kind: kind, days: result)
        }
    }

    /// 当前页的厂商逐小时序列（仅今日视图）；今天的序列截掉未来小时。
    private var pagedHourlyTrends: [ProviderHourlyTrend] {
        let now = Date()
        return sortedKinds.compactMap { kind in
            guard let hours = UsageTrendData.hourly(
                kind: kind, on: pageEndDay, snapshot: store.states[kind]?.snapshot
            ) else { return nil }
            return ProviderHourlyTrend(kind: kind, hours: hours.filter { $0.hour <= now })
        }
    }

    /// 当前窗口（不翻页）的厂商逐日序列，只用于判断是否有数据可展示图表区。
    private var trends: [ProviderTrend] {
        sortedKinds.compactMap { kind in
            guard let result = UsageTrendData.daily(
                kind: kind, days: 30, endingOn: Date(), snapshot: store.states[kind]?.snapshot
            ) else { return nil }
            return ProviderTrend(kind: kind, days: result)
        }
    }

    /// 顶部统计项：同时是趋势图周期切换按钮，选中项带浅色底；切换时翻页归零。
    private func periodStat(title: String, value: Int, period: TrendPeriod) -> some View {
        Button {
            self.period = period
            pageOffset = 0
        } label: {
            VStack(spacing: 2) {
                Text(value.formatted(.number.notation(.compactName)))
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(self.period == period ? Color.primary.opacity(0.08) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func chartPlaceholder(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                if !displayBalances.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(displayBalances, id: \.label) { group in
                            HStack {
                                Text(group.label).foregroundStyle(.secondary)
                                Spacer()
                                Text(group.text)
                                    .monospacedDigit()
                                    .fontWeight(.medium)
                            }
                            .font(.caption)
                        }
                    }
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

    /// 卡片展示的余额行：DeepSeek 隐藏「近30天消费」；同名行（如 API 余额的 CNY/USD 两条）
    /// 合并为一行，金额用 " / " 连接，保持首次出现顺序。
    private var displayBalances: [(label: String, text: String)] {
        guard case .ready(let snapshot) = state else { return [] }
        var order: [String] = []
        var grouped: [String: [MoneyBalance]] = [:]
        for balance in snapshot.balances {
            if kind == .deepSeek, balance.label == "近30天消费" { continue }
            if grouped[balance.label] == nil { order.append(balance.label) }
            grouped[balance.label, default: []].append(balance)
        }
        return order.map { label in
            (label, grouped[label]!.map(balanceText).joined(separator: " / "))
        }
    }

    private func balanceText(_ balance: MoneyBalance) -> String {
        if balance.currency.lowercased() == "credits" {
            return "\(balance.amount.formatted(.number.precision(.fractionLength(0...2)))) credits"
        }
        return "\(balance.currency) \(balance.amount.formatted(.number.precision(.fractionLength(2))))"
    }
}

/// 一个厂商的近 7 天逐日 token 序列（综合趋势图用）。
private struct ProviderTrend: Identifiable {
    let kind: ProviderKind
    let days: [DailyTokenUsage]

    var id: ProviderKind { kind }
}

/// 顶部三栏统计下方的近 7 天综合用量曲线：每家厂商一条彩色平滑曲线，无坐标轴，右端为今天。
/// 鼠标悬停时显示垂直参考线，并浮出气泡列出当天各厂商用量。
private struct CombinedTrendChart: View {
    let trends: [ProviderTrend]
    @State private var hoverDay: Date?
    @State private var hoverX: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            Chart {
                ForEach(trends) { trend in
                    ForEach(trend.days, id: \.day) { item in
                        LineMark(
                            x: .value("日期", item.day),
                            y: .value("Tokens", item.tokens)
                        )
                        // 用 foregroundStyle(by:) 按厂商分系列（颜色由 chartForegroundStyleScale 指定）：
                        // 不分系列时所有 LineMark 会被连成一条折线，跨厂商首尾相接成对角线锯齿
                        .foregroundStyle(by: .value("厂商", trend.kind.name))
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        if hoverDay == item.day {
                            PointMark(
                                x: .value("日期", item.day),
                                y: .value("Tokens", item.tokens)
                            )
                            .foregroundStyle(by: .value("厂商", trend.kind.name))
                            .symbolSize(24)
                        }
                    }
                }
                if let hoverDay {
                    RuleMark(x: .value("日期", hoverDay))
                        .foregroundStyle(.secondary.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartForegroundStyleScale(
                domain: trends.map { $0.kind.name },
                range: trends.map { $0.kind.tint }
            )
            .chartOverlay { proxy in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            hoverX = location.x
                            // 坐标轴全部隐藏，绘图区与 overlay 同原点同尺寸，直接用 location.x 反解日期
                            if let date: Date = proxy.value(atX: location.x) {
                                hoverDay = nearestDay(to: date)
                            }
                        case .ended:
                            hoverDay = nil
                        }
                    }
            }
            .overlay(alignment: .topLeading) {
                if let hoverDay {
                    tooltip(for: hoverDay)
                        .offset(x: min(max(hoverX - 60, 0), max(geo.size.width - 122, 0)), y: 0)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// 各厂商序列共享同一组自然日，用第一条序列找离鼠标最近的一天。
    private func nearestDay(to date: Date) -> Date? {
        trends.first?.days.min(by: {
            abs($0.day.timeIntervalSince(date)) < abs($1.day.timeIntervalSince(date))
        })?.day
    }

    private func tooltip(for day: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(day.formatted(.dateTime.month(.wide).day().weekday(.abbreviated)))
                .fontWeight(.semibold)
            ForEach(trends) { trend in
                HStack(spacing: 4) {
                    Circle().fill(trend.kind.tint).frame(width: 5, height: 5)
                    Text(trend.kind.name)
                    Spacer()
                    Text((trend.days.first { $0.day == day }?.tokens ?? 0)
                        .formatted(.number.notation(.compactName)))
                        .monospacedDigit()
                }
            }
        }
        .font(.caption2)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: 122)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.secondary.opacity(0.2), lineWidth: 0.5)
        )
    }
}

/// 顶部统计切换的统计周期。
private enum TrendPeriod {
    case today, last7, last30
}

/// 一个厂商的今日逐小时 token 序列（逐小时曲线图用）。
private struct ProviderHourlyTrend: Identifiable {
    let kind: ProviderKind
    let hours: [HourlyTokenUsage]

    var id: ProviderKind { kind }
}

/// 今日逐小时用量曲线：每家厂商一条彩色平滑曲线；悬停显示参考线与该小时各厂商用量气泡。
private struct HourlyTrendChart: View {
    let trends: [ProviderHourlyTrend]
    @State private var hoverHour: Date?
    @State private var hoverX: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            Chart {
                ForEach(trends) { trend in
                    ForEach(trend.hours, id: \.hour) { item in
                        LineMark(
                            x: .value("时间", item.hour),
                            y: .value("Tokens", item.tokens)
                        )
                        .foregroundStyle(by: .value("厂商", trend.kind.name))
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        if hoverHour == item.hour {
                            PointMark(
                                x: .value("时间", item.hour),
                                y: .value("Tokens", item.tokens)
                            )
                            .foregroundStyle(by: .value("厂商", trend.kind.name))
                            .symbolSize(24)
                        }
                    }
                }
                if let hoverHour {
                    RuleMark(x: .value("时间", hoverHour))
                        .foregroundStyle(.secondary.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartForegroundStyleScale(
                domain: trends.map { $0.kind.name },
                range: trends.map { $0.kind.tint }
            )
            .chartOverlay { proxy in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            hoverX = location.x
                            // 坐标轴全部隐藏，绘图区与 overlay 同原点同尺寸，直接用 location.x 反解时间
                            if let date: Date = proxy.value(atX: location.x) {
                                hoverHour = nearestHour(to: date)
                            }
                        case .ended:
                            hoverHour = nil
                        }
                    }
            }
            .overlay(alignment: .topLeading) {
                if let hoverHour {
                    tooltip(for: hoverHour)
                        .offset(x: min(max(hoverX - 60, 0), max(geo.size.width - 122, 0)), y: 0)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func nearestHour(to date: Date) -> Date? {
        trends.first?.hours.min(by: {
            abs($0.hour.timeIntervalSince(date)) < abs($1.hour.timeIntervalSince(date))
        })?.hour
    }

    private func tooltip(for hour: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(hour.formatted(.dateTime.month(.wide).day().hour()))
                .fontWeight(.semibold)
            ForEach(trends) { trend in
                HStack(spacing: 4) {
                    Circle().fill(trend.kind.tint).frame(width: 5, height: 5)
                    Text(trend.kind.name)
                    Spacer()
                    Text((trend.hours.first { $0.hour == hour }?.tokens ?? 0)
                        .formatted(.number.notation(.compactName)))
                        .monospacedDigit()
                }
            }
        }
        .font(.caption2)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: 122)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.secondary.opacity(0.2), lineWidth: 0.5)
        )
    }
}

/// 近 30 天点阵贡献图（GitHub 风格）：周一到周日七列、逐周一行，
/// 颜色深浅表示当日各厂商 token 合计；悬停格子浮出气泡显示当日明细。
/// 格子刻意做小（13pt），与曲线图同高，切换周期时窗口不抖动。
private struct ContributionGrid: View {
    let trends: [ProviderTrend]
    @State private var hoverDay: Date?
    @State private var hoverIndex = 0

    private static let cellSize: CGFloat = 13
    private static let cellSpacing: CGFloat = 3
    private static let gridWidth = 7 * cellSize + 6 * cellSpacing

    /// 逐日合计（当日 00:00 → tokens）
    private var totals: [Date: Int] {
        var result: [Date: Int] = [:]
        for trend in trends {
            for item in trend.days { result[item.day, default: 0] += item.tokens }
        }
        return result
    }

    /// 日历网格单元（nil 为起始日所在周之前的占位空格），周一为每周第一天。
    private var cells: [Date?] {
        guard let days = trends.first?.days, !days.isEmpty else { return [] }
        let cal = Calendar(identifier: .gregorian)
        let weekday = cal.component(.weekday, from: days[0].day) // 周日=1 … 周六=7
        let leading = (weekday + 5) % 7 // 周一起点的偏移
        return Array(repeating: nil, count: leading) + days.map { Optional($0.day) }
    }

    var body: some View {
        let totals = self.totals
        let maxTokens = totals.values.max() ?? 0
        let cells = self.cells
        GeometryReader { geo in
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(Self.cellSize), spacing: Self.cellSpacing), count: 7),
                spacing: Self.cellSpacing
            ) {
                ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                    if let day = cell {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(color(for: totals[day] ?? 0, max: maxTokens))
                            .frame(width: Self.cellSize, height: Self.cellSize)
                            .onHover { hovering in
                                if hovering {
                                    hoverDay = day
                                    hoverIndex = index
                                } else if hoverDay == day {
                                    hoverDay = nil
                                }
                            }
                    } else {
                        Color.clear.frame(width: Self.cellSize, height: Self.cellSize)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                if let hoverDay {
                    tooltip(for: hoverDay)
                        .offset(x: tooltipX(in: geo.size.width), y: 2)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    /// 气泡跟随悬停格子的列：格子中心水平对齐，并在图表区内钳制。
    private func tooltipX(in width: CGFloat) -> CGFloat {
        let originX = (width - Self.gridWidth) / 2
        let column = hoverIndex % 7
        let centerX = originX + CGFloat(column) * (Self.cellSize + Self.cellSpacing) + Self.cellSize / 2
        return min(max(centerX - 61, 0), max(width - 122, 0))
    }

    private func color(for tokens: Int, max maxTokens: Int) -> Color {
        guard tokens > 0, maxTokens > 0 else { return Color.primary.opacity(0.05) }
        switch Double(tokens) / Double(maxTokens) {
        case ..<0.25: return .accentColor.opacity(0.25)
        case ..<0.5: return .accentColor.opacity(0.45)
        case ..<0.75: return .accentColor.opacity(0.7)
        default: return .accentColor
        }
    }

    private func tooltip(for day: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(day.formatted(.dateTime.month(.wide).day().weekday(.abbreviated)))
                .fontWeight(.semibold)
            ForEach(trends) { trend in
                HStack(spacing: 4) {
                    Circle().fill(trend.kind.tint).frame(width: 5, height: 5)
                    Text(trend.kind.name)
                    Spacer()
                    Text((trend.days.first { $0.day == day }?.tokens ?? 0)
                        .formatted(.number.notation(.compactName)))
                        .monospacedDigit()
                }
            }
        }
        .font(.caption2)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: 122)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.secondary.opacity(0.2), lineWidth: 0.5)
        )
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

    var snapshot: ProviderSnapshot? {
        if case .ready(let snapshot) = self { return snapshot }
        return nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
