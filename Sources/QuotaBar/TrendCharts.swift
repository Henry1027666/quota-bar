import Charts
import SwiftUI

/// 趋势图统计周期（今日 / 近 7 天 / 近 30 天 / 近一年）。
enum TrendPeriod: CaseIterable {
    case today, last7, last30, last365

    var title: String {
        switch self {
        case .today: "今日"
        case .last7: "近7天"
        case .last30: "近30天"
        case .last365: "近一年"
        }
    }

    /// 逐日序列天数（今日视图走逐小时，不用这个）。
    var days: Int {
        switch self {
        case .today: 1
        case .last7: 7
        case .last30: 30
        case .last365: 365
        }
    }
}

/// 一个厂商的逐日 token 序列（综合趋势图 / 点阵图用）。
struct ProviderTrend: Identifiable {
    let kind: ProviderKind
    let days: [DailyTokenUsage]

    var id: ProviderKind { kind }
}

/// 一个厂商的逐小时 token 序列（逐小时曲线图用）。
struct ProviderHourlyTrend: Identifiable {
    let kind: ProviderKind
    let hours: [HourlyTokenUsage]

    var id: ProviderKind { kind }
}

/// 单厂商作用域下，一张图里的一条序列：总用量（isPrimary，只用于悬停气泡）
/// 或某个模型（由品牌色派生的同色系色阶，堆叠柱的一段）。
struct ChartSeries: Identifiable {
    /// 序列显示名（图例与悬停气泡用）。总用量用厂商名，模型用模型名。
    let name: String
    /// 该序列的采样点（逐日或逐小时，与同一张图内其他序列同轴）。
    let points: [DailyTokenUsage]
    let color: Color
    /// true 表示这是总用量序列（不代表某个模型）。
    let isPrimary: Bool

    var id: String { name }

    /// 合计，用于图例排序与零用量过滤。
    var total: Int { points.reduce(0) { $0 + $1.tokens } }

    /// 复制一份并改写 isPrimary：无模型维度时把总量当作唯一的分段来画。
    func replacingPrimary(_ value: Bool) -> ChartSeries {
        ChartSeries(name: name, points: points, color: color, isPrimary: value)
    }
}

/// 模型曲线配色：以厂商品牌色为基准，在 HSB 空间沿「亮度 / 饱和度 / 色相」三个方向
/// 拉开差距，保证同色系观感下相邻模型仍可区分。索引超出预设长度时循环取用。
func modelTint(_ base: Color, index: Int) -> Color {
    // 预设档位：亮度优先拉开，其次色相偏移（避免整组曲线同色难辨）
    let variants: [(brightness: Double, saturation: Double, hueShift: Double)] = [
        (1.0, 0.72, 0.0),
        (0.72, 0.95, 0.05),
        (1.0, 0.42, -0.06),
        (0.55, 0.85, 0.11),
        (0.88, 0.55, 0.17),
        (0.42, 0.9, -0.11)
    ]
    let v = variants[index % variants.count]
    let ns = NSColor(base).usingColorSpace(.deviceRGB) ?? .systemBlue
    var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
    ns.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
    // 色相环绕到 [0,1)，亮度钳制到可见区间（纯黑/纯白曲线都不可辨）
    let newHue = (hue + CGFloat(v.hueShift)).truncatingRemainder(dividingBy: 1)
    let wrappedHue = newHue < 0 ? newHue + 1 : newHue
    let newBri = min(max(bri * CGFloat(v.brightness), 0.35), 1.0)
    let newSat = min(max(sat * CGFloat(v.saturation), 0.25), 1.0)
    return Color(hue: Double(wrappedHue), saturation: Double(newSat),
                 brightness: Double(newBri), opacity: 1)
}

extension ProviderState {
    var tier: PlanTier {
        if case .ready(let snapshot) = self { return snapshot.planTier }
        return .free
    }

    var snapshot: ProviderSnapshot? {
        if case .ready(let snapshot) = self { return snapshot }
        return nil
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// 可见厂商按「token plan → API → free」排序，free 统一排最下方；同档保持稳定顺序。
/// 弹层与主窗口总览共用，保证两处条目顺序一致。
func sortedVisibleKinds(states: [ProviderKind: ProviderState]) -> [ProviderKind] {
    let visible = ProviderKind.allCases.filter {
        if case .notDetected = states[$0] { return false }
        return true
    }
    return visible.sorted { lhs, rhs in
        let lt = states[lhs]?.tier ?? .free
        let rt = states[rhs]?.tier ?? .free
        if lt != rt { return lt < rt }
        return lhs.rawValue < rhs.rawValue
    }
}

/// 各厂商 Token 计数器在今日 / 近 7 天 / 近 30 天 / 近一年（滚动窗口，含今天）内的用量之和；
/// 无任何厂商返回 token 用量时为 nil。有精确分解（本地日志 / 逐日接口）的厂商用精确值，
/// 其余用采样增量估算。弹层顶部三栏与主窗口总览大数字卡片共用。
/// 近一年经 UsageTrendData 全历史逐日序列求和（本地日志厂商为精确值；
/// DeepSeek 为「官方 key 近 30 天 + 非官方 provider 本地日志一年」并集）。
@MainActor
func tokenDeltas(kinds: [ProviderKind], states: [ProviderKind: ProviderState]) -> (today: Int, last7: Int, last30: Int, last365: Int)? {
    let now = Date()
    let cal = Calendar(identifier: .gregorian)
    let dayStart = cal.startOfDay(for: now)
    let last7Start = cal.date(byAdding: .day, value: -6, to: dayStart) ?? dayStart
    let last30Start = cal.date(byAdding: .day, value: -29, to: dayStart) ?? dayStart
    var today = 0, last7 = 0, last30 = 0, last365 = 0, found = false
    for kind in kinds {
        guard case .ready(let snapshot) = states[kind] else { continue }
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
        if let year = snapshot.last365Tokens {
            last365 += year
        } else if snapshot.tokenUsage != nil {
            // 采样兜底厂商无预计算年份值，历史采样序列为内存数据，直接求和
            last365 += UsageHistory.shared.dailyDeltas(kind: kind, key: "tokens", days: 365, now: now)
                .reduce(0) { $0 + $1.tokens }
        }
    }
    return found ? (today, last7, last30, last365) : nil
}

/// 卡片/详情页展示的余额行：DeepSeek 隐藏「近30天消费」；同名行（如 API 余额的 CNY/USD 两条）
/// 合并为一行，金额用 " / " 连接，保持首次出现顺序。
func displayBalances(kind: ProviderKind, snapshot: ProviderSnapshot) -> [(label: String, text: String)] {
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

func balanceText(_ balance: MoneyBalance) -> String {
    if balance.currency.lowercased() == "credits" {
        return "\(balance.amount.formatted(.number.precision(.fractionLength(0...2)))) credits"
    }
    return "\(balance.currency) \(balance.amount.formatted(.number.precision(.fractionLength(2))))"
}

struct QuotaRow: View {
    let window: QuotaWindow
    let tint: Color

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
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

            CapsuleTrack(fraction: window.fraction, tint: progressTint)
        }
    }

    private var progressTint: Color {
        if window.fraction >= 0.9 { return .red }
        if window.fraction >= 0.7 { return .orange }
        return tint
    }
}

/// 胶囊进度条：浅色轨道 + 品牌色填充，比系统 ProgressView 更饱满。
private struct CapsuleTrack: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(tint)
                    .frame(width: fraction > 0 ? max(6, geo.size.width * fraction) : 0)
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.25), value: fraction)
    }
}

/// 趋势图翻页器：周期由外部（统计卡片）选择，本组件只负责固定高度图表区，
/// 切换周期时窗口不抖动。主窗口总览页使用。
struct TrendChartPager: View {
    let kinds: [ProviderKind]
    /// 取厂商最新快照（UsageTrendData 需要快照里的逐日/逐小时精确数据）。
    let snapshot: (ProviderKind) -> ProviderSnapshot?
    var chartHeight: CGFloat = 96
    /// 统计周期：由上方统计卡片驱动（点今日用量→今日曲线…）。
    @Binding var period: TrendPeriod
    /// 刷新令牌（store.lastRefreshedAt）：快照更新后重新加载趋势。
    var reloadToken: Date? = nil

    /// nil = 加载中。趋势数据在后台线程解析（日志文件量大），加载期间显示占位。
    @State private var dailyTrends: [ProviderTrend]?
    @State private var hourlyTrends: [ProviderHourlyTrend]?
    /// 单厂商作用域下的「总用量 + 各模型」曲线组（总览作用域恒为 nil，不参与渲染）。
    @State private var dailySeries: [ChartSeries]?
    @State private var hourlySeries: [ChartSeries]?

    /// 是否单厂商作用域：此时曲线图展开到「总用量 + 各模型」。
    private var isSingleProvider: Bool { kinds.count == 1 }

    var body: some View {
        VStack(spacing: 6) {
            // 图例形状跟图表走：堆叠柱用方块（与堆叠段一致），曲线/点阵用圆点。
            // 总量不进图例，它在悬停气泡里给出；近一年点阵图不显示图例
            // （格子深浅只表达当日总量，系列明细由悬停气泡给出）。
            if period != .last365, !legendEntries.isEmpty {
                HStack(spacing: 12) {
                    ForEach(legendEntries) { entry in
                        HStack(spacing: 4) {
                            if chartShowsBars {
                                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                    .fill(entry.color)
                                    .frame(width: 7, height: 7)
                            } else {
                                Circle().fill(entry.color).frame(width: 6, height: 6)
                            }
                            Text(entry.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer()
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Group {
                switch period {
                case .today:
                    if let hourlySeries, isSingleProvider {
                        if hourlySeries.isEmpty {
                            chartPlaceholder("该日无逐小时用量数据")
                        } else {
                            MultiSeriesHourlyChart(series: hourlySeries, tint: kinds[0].tint)
                                .transition(.opacity)
                        }
                    } else if let hourlyTrends {
                        if hourlyTrends.isEmpty {
                            chartPlaceholder("该日无逐小时用量数据")
                        } else {
                            // 与单厂商逐小时图同口径：各厂商按品牌色堆叠成柱
                            MultiSeriesHourlyChart(series: overviewHourlyStackedSeries,
                                                   tint: hourlyTrends.first?.kind.tint ?? .accentColor)
                                .transition(.opacity)
                        }
                    } else {
                        chartPlaceholder("加载中…")
                    }
                case .last7, .last30, .last365:
                    if let dailySeries, isSingleProvider {
                        if dailySeries.isEmpty {
                            chartPlaceholder("该时段无用量数据")
                        } else if period == .last365 {
                            MultiSeriesContributionGrid(series: dailySeries, cellSize: gridCellSize)
                                .transition(.opacity)
                        } else {
                            MultiSeriesTrendChart(series: dailySeries, tint: kinds[0].tint)
                                .transition(.opacity)
                        }
                    } else if let dailyTrends {
                        if dailyTrends.isEmpty {
                            chartPlaceholder("该时段无用量数据")
                        } else if period == .last365 {
                            ContributionGrid(trends: dailyTrends, cellSize: gridCellSize)
                                .transition(.opacity)
                        } else {
                            // 与单厂商图同口径：各厂商按品牌色堆叠成柱，柱高为当日总量
                            MultiSeriesTrendChart(series: overviewStackedSeries,
                                                  tint: dailyTrends.first?.kind.tint ?? .accentColor)
                                .transition(.opacity)
                        }
                    } else {
                        chartPlaceholder("加载中…")
                    }
                }
            }
            .frame(height: chartHeight)
            // 切周期时新旧图表交叉淡入淡出（状态变更由统计条按钮包在 withAnimation 里）
            .animation(.snappy(duration: 0.3), value: period)
        }
        .task(id: reloadID) {
            // 切周期时先置回加载态，避免旧数据在新口径下闪一帧
            dailyTrends = nil
            hourlyTrends = nil
            dailySeries = nil
            hourlySeries = nil
            await reload()
        }
    }

    /// 触发趋势重载的条件组合：周期、厂商范围、快照刷新时间。
    private var reloadID: String {
        "\(period.title)-\(kinds.map(\.rawValue).joined())-\(reloadToken?.timeIntervalSince1970 ?? 0)"
    }

    /// 后台加载当前周期的厂商趋势序列（UsageTrendData 内部已把文件 IO 放到非主线程）。
    /// 单厂商作用域额外加载模型维度，组装成「总用量 + 各模型」曲线组。
    private func reload() async {
        let end = Date()
        if period == .today {
            let now = Date()
            if isSingleProvider, let kind = kinds.first {
                let totals = await UsageTrendData.hourly(kind: kind, on: end, snapshot: snapshot(kind)) ?? []
                let byModel = await UsageTrendData.hourlyByModel(kind: kind, on: end, snapshot: snapshot(kind)) ?? []
                hourlySeries = buildSeries(kind: kind, totalPoints: totals.map { ($0.hour, $0.tokens) },
                                           modelSeries: byModel)
                return
            }
            var result: [ProviderHourlyTrend] = []
            for kind in kinds {
                if let hours = await UsageTrendData.hourly(kind: kind, on: end, snapshot: snapshot(kind)) {
                    result.append(ProviderHourlyTrend(kind: kind, hours: hours.filter { $0.hour <= now }))
                }
            }
            hourlyTrends = result
        } else {
            if isSingleProvider, let kind = kinds.first {
                let totals = await UsageTrendData.daily(
                    kind: kind, days: period.days, endingOn: end, snapshot: snapshot(kind)
                ) ?? []
                let byModel = await UsageTrendData.dailyByModel(
                    kind: kind, days: period.days, endingOn: end, snapshot: snapshot(kind)
                ) ?? []
                dailySeries = buildSeries(kind: kind, totalPoints: totals.map { ($0.day, $0.tokens) },
                                          modelSeries: byModel)
                return
            }
            var result: [ProviderTrend] = []
            for kind in kinds {
                if let days = await UsageTrendData.daily(
                    kind: kind, days: period.days, endingOn: end, snapshot: snapshot(kind)
                ) {
                    result.append(ProviderTrend(kind: kind, days: days))
                }
            }
            dailyTrends = result
        }
    }

    /// 组装单厂商曲线组：第 0 条是总用量（粗线、品牌色），其后为各模型（细线、色阶）。
    /// 总用量与模型合计理论上相等；两者都为空时返回空数组（交由占位文案处理）。
    private func buildSeries(kind: ProviderKind, totalPoints: [(Date, Int)],
                             modelSeries: [ModelTokenSeries]) -> [ChartSeries] {
        var series: [ChartSeries] = []
        let totalSum = totalPoints.reduce(0) { $0 + $1.1 }
        if totalSum > 0 || !modelSeries.isEmpty {
            series.append(ChartSeries(
                name: kind.name,
                points: totalPoints.map { DailyTokenUsage(day: $0.0, tokens: $0.1) },
                color: kind.tint,
                isPrimary: true
            ))
        }
        for (index, model) in modelSeries.enumerated() where model.total > 0 {
            series.append(ChartSeries(
                name: model.model,
                points: model.points,
                color: modelTint(kind.tint, index: index),
                isPrimary: false
            ))
        }
        return series
    }

    /// 当前周期图表是否为柱形图：今日/近7天/近30天（总览与单厂商）都是堆叠柱，
    /// 只有近一年是点阵图。图例形状跟图表走（柱→方块）。
    private var chartShowsBars: Bool {
        period != .last365
    }

    /// 点阵格子边长：按图表区高度推导（7 行格子 + 月份标签占满卡片），
    /// 随窗口等比伸缩，限 8...18 防止过密或超出。
    private var gridCellSize: CGFloat {
        let total = chartHeight - 36   // 月份标签 14 + 行距 4 + 格子间距 6×3 + 余量
        return min(max((total / 7 - ContributionGrid.defaultCellSpacing), 8), 18)
    }

    /// 图例条目：单厂商作用域用各模型，否则用各厂商；都只列实际有数据的序列。
    /// 单厂商时通常排除总量条目——它已由堆叠柱高表达，图例重复列出反而误导。
    /// 例外：该厂商没有模型维度时（图上画的就是总量那根柱），图例保留它，否则图例会空。
    private var legendEntries: [ChartSeries] {
        if isSingleProvider {
            let all = period == .today ? (hourlySeries ?? []) : (dailySeries ?? [])
            let models = all.filter { !$0.isPrimary }
            return models.isEmpty ? all : models
        }
        let kinds = self.legendKinds
        return kinds.map { ChartSeries(name: $0.name, points: [], color: $0.tint, isPrimary: true) }
    }

    /// 总览作用域的「总量 + 各厂商」堆叠柱序列：第 0 条为每日合计（不参与绘制，
    /// 只进悬停气泡），其后为各厂商分段（品牌色）。口径与单厂商图的「总量 + 各模型」一致。
    private var overviewStackedSeries: [ChartSeries] {
        var perDay: [Date: Int] = [:]
        for trend in dailyTrends ?? [] {
            for item in trend.days { perDay[item.day, default: 0] += item.tokens }
        }
        var series: [ChartSeries] = []
        let totalPoints = perDay.keys.sorted()
            .map { DailyTokenUsage(day: $0, tokens: perDay[$0] ?? 0) }
        if !totalPoints.isEmpty {
            series.append(ChartSeries(name: "总用量", points: totalPoints,
                                      color: .accentColor, isPrimary: true))
        }
        for trend in dailyTrends ?? [] {
            series.append(ChartSeries(name: trend.kind.name, points: trend.days,
                                      color: trend.kind.tint, isPrimary: false))
        }
        return series
    }

    /// 总览作用域「今日」的「总量 + 各厂商」逐小时堆叠柱序列（口径与逐日版一致）。
    private var overviewHourlyStackedSeries: [ChartSeries] {
        var perHour: [Date: Int] = [:]
        for trend in hourlyTrends ?? [] {
            for item in trend.hours { perHour[item.hour, default: 0] += item.tokens }
        }
        var series: [ChartSeries] = []
        let totalPoints = perHour.keys.sorted()
            .map { DailyTokenUsage(day: $0, tokens: perHour[$0] ?? 0) }
        if !totalPoints.isEmpty {
            series.append(ChartSeries(name: "总用量", points: totalPoints,
                                      color: .accentColor, isPrimary: true))
        }
        for trend in hourlyTrends ?? [] {
            series.append(ChartSeries(
                name: trend.kind.name,
                points: trend.hours.map { DailyTokenUsage(day: $0.hour, tokens: $0.tokens) },
                color: trend.kind.tint, isPrimary: false))
        }
        return series
    }

    /// 当前页实际有数据的厂商（图例行用）。
    private var legendKinds: [ProviderKind] {
        switch period {
        case .today: return hourlyTrends?.map(\.kind) ?? []
        case .last7, .last30, .last365: return dailyTrends?.map(\.kind) ?? []
        }
    }

    private func chartPlaceholder(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 近一年点阵贡献图（GitHub 风格）：七行为周一到周日、逐周一列，
/// 颜色深浅表示当日各厂商 token 合计；悬停格子浮出气泡显示当日明细。
/// 宽度超出可视区时横向滚动，默认滚到最新（右侧）。
struct ContributionGrid: View {
    let trends: [ProviderTrend]
    @State private var hoverDay: Date?
    @State private var hoverColumn = 0

    static let defaultCellSize: CGFloat = 10
    static let defaultCellSpacing: CGFloat = 3
    /// 格子边长：默认 10；由图表区高度传入时可随窗口等比伸缩
    var cellSize: CGFloat = Self.defaultCellSize
    private let cellSpacing: CGFloat = Self.defaultCellSpacing
    private var columnWidth: CGFloat { cellSize + cellSpacing }
    private let monthLabelHeight: CGFloat = 14

    /// 逐日合计（当日 00:00 → tokens）
    private var totals: [Date: Int] {
        var result: [Date: Int] = [:]
        for trend in trends {
            for item in trend.days { result[item.day, default: 0] += item.tokens }
        }
        return result
    }

    /// 逐周列：每列 7 个单元（周一到周日，nil 为首周起始日之前的占位空格）。
    private var weeks: [[Date?]] {
        guard let days = trends.first?.days, !days.isEmpty else { return [] }
        let cal = Calendar(identifier: .gregorian)
        let weekday = cal.component(.weekday, from: days[0].day) // 周日=1 … 周六=7
        let leading = (weekday + 5) % 7 // 周一起点的偏移
        let cells = Array(repeating: nil, count: leading) + days.map { Optional($0.day) }
        var result: [[Date?]] = []
        for chunkStart in stride(from: 0, to: cells.count, by: 7) {
            var week = Array(cells[chunkStart..<min(chunkStart + 7, cells.count)])
            while week.count < 7 { week.append(nil) }
            result.append(week)
        }
        return result
    }

    /// 月份标签：某列包含当月 1 号时，在该列上方显示月份。
    private var monthLabels: [(column: Int, text: String)] {
        let cal = Calendar(identifier: .gregorian)
        return weeks.enumerated().compactMap { index, week in
            for case let day? in week where cal.component(.day, from: day) == 1 {
                return (index, day.formatted(.dateTime.month(.wide)))
            }
            return nil
        }
    }

    var body: some View {
        let totals = self.totals
        let maxTokens = totals.values.max() ?? 0
        let weeks = self.weeks
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    // 月份标签行
                    ZStack(alignment: .topLeading) {
                        Color.clear.frame(
                            width: CGFloat(weeks.count) * columnWidth,
                            height: monthLabelHeight
                        )
                        ForEach(monthLabels, id: \.column) { label in
                            Text(label.text)
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .offset(x: CGFloat(label.column) * columnWidth)
                        }
                    }

                    HStack(spacing: cellSpacing) {
                        ForEach(Array(weeks.enumerated()), id: \.offset) { column, week in
                            VStack(spacing: cellSpacing) {
                                ForEach(Array(week.enumerated()), id: \.offset) { _, cell in
                                    if let day = cell {
                                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                            .fill(color(for: totals[day] ?? 0, max: maxTokens))
                                            .frame(width: cellSize, height: cellSize)
                                            .onHover { hovering in
                                                if hovering {
                                                    hoverDay = day
                                                    hoverColumn = column
                                                } else if hoverDay == day {
                                                    hoverDay = nil
                                                }
                                            }
                                    } else {
                                        Color.clear.frame(width: cellSize, height: cellSize)
                                    }
                                }
                            }
                            .id(column)
                        }
                    }
                }
                .padding(.horizontal, 2)
                .overlay(alignment: .topLeading) {
                    if let hoverDay {
                        tooltip(for: hoverDay)
                            .offset(x: tooltipX, y: monthLabelHeight + 4)
                            .allowsHitTesting(false)
                    }
                }
            }
            .onAppear { proxy.scrollTo(weeks.count - 1, anchor: .trailing) }
            .onChange(of: weeks.count) { _, count in
                proxy.scrollTo(count - 1, anchor: .trailing)
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// 气泡跟随悬停格子的列：格子中心水平对齐，并在网格内钳制。
    private var tooltipX: CGFloat {
        let gridWidth = CGFloat(weeks.count) * columnWidth
        let centerX = CGFloat(hoverColumn) * columnWidth + cellSize / 2 + 2
        return min(max(centerX - 61, 0), max(gridWidth - 122, 0))
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

// MARK: - 单厂商堆叠柱图（各模型堆叠，总量只在悬停气泡显示）

/// 单厂商逐日图：各模型**堆叠**成柱，柱高即当日总量。
///
/// 为什么不用「总量曲线 + 各模型曲线」：当某个模型占绝对多数（如 DeepSeek 单一模型 100%）时，
/// 总量曲线与该模型曲线完全重合，两条线互相遮挡，既看不出总量也看不出模型占比。
/// 堆叠柱天然规避这个问题——总量由柱高表达（不再单独画一条线），各模型由堆叠分段表达，
/// 占比一眼可见；具体总量值在悬停气泡里给出。
///
/// 堆叠顺序：按合计**升序**——用量最少的画在柱底，最多的堆到柱顶。
/// 柱底固定是最小用量那一层，柱顶由最大用量模型决定，跨日期比较时形态更稳定。
///
/// series 里 isPrimary 的那条（总量）**不参与绘制**，只用于气泡里的总量显示。
/// 例外：若该厂商没有模型维度（modelSeries 为空，如尚未解析出模型的历史数据），
/// 则退回「画总量一根柱」，否则图表会整个空白。
struct MultiSeriesTrendChart: View {
    let series: [ChartSeries]
    let tint: Color
    @State private var hoverDay: Date?
    @State private var hoverX: CGFloat = 0

    /// 总量序列（气泡里显示；无模型时退回作为唯一的柱）。
    private var totalSeries: ChartSeries? { series.first { $0.isPrimary } }
    /// 参与堆叠的模型序列，按合计升序（少量在柱底）。无模型维度时退回总量那一根柱。
    private var modelSeries: [ChartSeries] {
        let models = series.filter { !$0.isPrimary }
        if models.isEmpty {
            return totalSeries.map { [$0.replacingPrimary(false)] } ?? []
        }
        return models.sorted { $0.total < $1.total }
    }

    var body: some View {
        GeometryReader { geo in
            Chart {
                ForEach(modelSeries) { item in
                    barMarks(for: item)
                }
                if let hoverDay {
                    RuleMark(x: .value("日期", hoverDay, unit: .day))
                        .foregroundStyle(.secondary.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartLegend(.hidden)
            .chartYScale(domain: 0...yUpperBound)
            .chartForegroundStyleScale(
                domain: modelSeries.map(\.name),
                range: modelSeries.map(\.color)
            )
            .chartXAxis {
                // 日期轴：标签随宽度自动疏密（近7天每天一个，近30天约每周一个）
                AxisMarks(values: .automatic) { _ in
                    AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                }
            }
            .chartYAxis {
                // token 轴：紧凑格式（如 1.2亿）+ 浅色网格线，便于对柱高读数
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                    AxisValueLabel {
                        if let tokens = value.as(Int.self) {
                            Text(tokens.formatted(.number.notation(.compactName)))
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                // plotFrame 是 Anchor<CGRect>，需经 GeometryProxy 解析成实际坐标
                GeometryReader { overlayGeo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                // 悬停判定按「柱子所占的横向区间」而非最近数据点：
                                // 柱有宽度，用最近点会让鼠标移到柱子边缘时仍高亮隔壁那根。
                                guard let plotFrame = proxy.plotFrame else { return }
                                let rect = overlayGeo[plotFrame]
                                hoverX = location.x
                                hoverDay = day(atX: location.x - rect.origin.x, width: rect.width)
                            case .ended:
                                hoverDay = nil
                            }
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

    /// 纵轴上界：按**单日各模型合计**（即真实柱高）取最大值，再留 12% 留白避免柱子贴顶。
    /// 不能取「单个模型的最大值」——堆叠后柱高是同日各模型之和，用单模型最大值会让柱顶被裁切。
    private var yUpperBound: Double {
        var maxPerDay = 0
        for day in allDays {
            maxPerDay = max(maxPerDay, totalTokens(on: day, in: modelSeries))
        }
        return maxPerDay > 0 ? Double(maxPerDay) * 1.12 : 1
    }

    /// 所有出现过的日期（并集，升序），供纵轴范围与柱区间判定复用。
    private var allDays: [Date] {
        var seen: Set<Date> = []
        var result: [Date] = []
        for item in modelSeries {
            for point in item.points where !seen.contains(point.day) {
                seen.insert(point.day)
                result.append(point.day)
            }
        }
        return result.sorted()
    }

    /// 某日期在给定序列集合下的合计。
    private func totalTokens(on day: Date, in items: [ChartSeries]) -> Int {
        items.reduce(0) { sum, item in
            sum + (item.points.first { $0.day == day }?.tokens ?? 0)
        }
    }

    /// 由绘图区内的 x 坐标反解所属日期：按柱宽等分区间，落在哪根柱的范围内就选哪根。
    /// 相比「找最近的数据点」，这样在柱子边缘与相邻柱之间都不会误判。
    private func day(atX x: CGFloat, width: CGFloat) -> Date? {
        let days = allDays
        guard !days.isEmpty, width > 0 else { return nil }
        let slot = width / CGFloat(days.count)
        guard slot > 0 else { return nil }
        let index = Int(floor(x / slot))
        // 落在绘图区边缘的极小边距：夹到最近一端，避免悬停突然消失
        guard index >= 0, index < days.count else {
            return index < 0 ? days.first : days.last
        }
        return days[index]
    }

    /// 单个模型的堆叠柱段：同一自然日的各模型自动堆叠，柱高即合计。
    @ChartContentBuilder
    private func barMarks(for item: ChartSeries) -> some ChartContent {
        ForEach(item.points, id: \.day) { point in
            BarMark(
                x: .value("日期", point.day, unit: .day),
                y: .value("Tokens", point.tokens),
                width: .ratio(0.6)
            )
            .foregroundStyle(by: .value("序列", item.name))
            // 悬停时聚焦当天：当天柱子全不透明，其余日期淡化
            .opacity(hoverDay == nil || hoverDay == point.day ? 1 : 0.35)
        }
    }

    /// 悬停气泡：总量置顶（图上不再画，只在这里给具体值），其下为各模型分段。
    private func tooltip(for day: Date) -> some View {
        let total = totalSeries?.points.first { $0.day == day }?.tokens
            ?? modelSeries.reduce(0) { $0 + ($1.points.first { $0.day == day }?.tokens ?? 0) }
        return VStack(alignment: .leading, spacing: 3) {
            Text(day.formatted(.dateTime.month(.wide).day().weekday(.abbreviated)))
                .fontWeight(.semibold)
            HStack(spacing: 4) {
                Text("总用量")
                Spacer()
                Text(total.formatted(.number.notation(.compactName)))
                    .monospacedDigit()
                    .fontWeight(.semibold)
            }
            Divider().opacity(0.4)
            ForEach(modelSeries) { item in
                HStack(spacing: 4) {
                    Rectangle().fill(item.color).frame(width: 5, height: 5)
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text((item.points.first { $0.day == day }?.tokens ?? 0)
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

/// 单厂商逐小时堆叠柱图：口径与 MultiSeriesTrendChart 完全相同（含无模型维度时退回总量柱），
/// 只是横轴单位为小时。
struct MultiSeriesHourlyChart: View {
    let series: [ChartSeries]
    let tint: Color
    @State private var hoverHour: Date?
    @State private var hoverX: CGFloat = 0

    /// 总量序列（气泡里显示；无模型时退回作为唯一的柱）。
    private var totalSeries: ChartSeries? { series.first { $0.isPrimary } }
    /// 参与堆叠的模型序列，按合计升序（少量在柱底，与逐日图一致）。无模型维度时退回总量柱。
    private var modelSeries: [ChartSeries] {
        let models = series.filter { !$0.isPrimary }
        if models.isEmpty {
            return totalSeries.map { [$0.replacingPrimary(false)] } ?? []
        }
        return models.sorted { $0.total < $1.total }
    }

    var body: some View {
        GeometryReader { geo in
            Chart {
                ForEach(modelSeries) { item in
                    barMarks(for: item)
                }
                if let hoverHour {
                    RuleMark(x: .value("时间", hoverHour, unit: .hour))
                        .foregroundStyle(.secondary.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartLegend(.hidden)
            .chartXAxis {
                // 小时轴：标签随宽度自动疏密（如 0时 6时 12时 18时）
                AxisMarks(values: .automatic) { _ in
                    AxisValueLabel(format: .dateTime.hour())
                }
            }
            .chartYAxis {
                // token 轴：紧凑格式（如 1.2亿）+ 浅色网格线，与逐日图一致
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                    AxisValueLabel {
                        if let tokens = value.as(Int.self) {
                            Text(tokens.formatted(.number.notation(.compactName)))
                        }
                    }
                }
            }
            .chartYScale(domain: 0...yUpperBound)
            .chartForegroundStyleScale(
                domain: modelSeries.map(\.name),
                range: modelSeries.map(\.color)
            )
            .chartOverlay { proxy in
                // plotFrame 是 Anchor<CGRect>，需经 GeometryProxy 解析成实际坐标
                GeometryReader { overlayGeo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                // 与逐日图一致：按柱子所占横向区间判定，而非最近数据点
                                guard let plotFrame = proxy.plotFrame else { return }
                                let rect = overlayGeo[plotFrame]
                                hoverX = location.x
                                hoverHour = hour(atX: location.x - rect.origin.x, width: rect.width)
                            case .ended:
                                hoverHour = nil
                            }
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

    /// 纵轴上界：按**单小时各模型合计**（柱高）取最大值并留 12% 留白（与逐日图口径一致）。
    private var yUpperBound: Double {
        var maxPerHour = 0
        for hour in allHours {
            maxPerHour = max(maxPerHour, totalTokens(on: hour))
        }
        return maxPerHour > 0 ? Double(maxPerHour) * 1.12 : 1
    }

    /// 所有出现过的小时（并集，升序）。
    private var allHours: [Date] {
        var seen: Set<Date> = []
        var result: [Date] = []
        for item in modelSeries {
            for point in item.points where !seen.contains(point.day) {
                seen.insert(point.day)
                result.append(point.day)
            }
        }
        return result.sorted()
    }

    private func totalTokens(on hour: Date) -> Int {
        modelSeries.reduce(0) { sum, item in
            sum + (item.points.first { $0.day == hour }?.tokens ?? 0)
        }
    }

    /// 由绘图区内的 x 坐标反解所属小时：按柱宽等分区间判定。
    private func hour(atX x: CGFloat, width: CGFloat) -> Date? {
        let hours = allHours
        guard !hours.isEmpty, width > 0 else { return nil }
        let slot = width / CGFloat(hours.count)
        guard slot > 0 else { return nil }
        let index = Int(floor(x / slot))
        guard index >= 0, index < hours.count else {
            return index < 0 ? hours.first : hours.last
        }
        return hours[index]
    }

    /// 单个模型的堆叠柱段（按小时分桶）。
    @ChartContentBuilder
    private func barMarks(for item: ChartSeries) -> some ChartContent {
        ForEach(item.points, id: \.day) { point in
            BarMark(
                x: .value("时间", point.day, unit: .hour),
                y: .value("Tokens", point.tokens),
                width: .ratio(0.6)
            )
            .foregroundStyle(by: .value("序列", item.name))
            .opacity(hoverHour == nil || hoverHour == point.day ? 1 : 0.35)
        }
    }

    private func tooltip(for hour: Date) -> some View {
        let total = totalSeries?.points.first { $0.day == hour }?.tokens
            ?? modelSeries.reduce(0) { $0 + ($1.points.first { $0.day == hour }?.tokens ?? 0) }
        return VStack(alignment: .leading, spacing: 3) {
            Text(hour.formatted(.dateTime.month(.wide).day().hour()))
                .fontWeight(.semibold)
            HStack(spacing: 4) {
                Text("总用量")
                Spacer()
                Text(total.formatted(.number.notation(.compactName)))
                    .monospacedDigit()
                    .fontWeight(.semibold)
            }
            Divider().opacity(0.4)
            ForEach(modelSeries) { item in
                HStack(spacing: 4) {
                    Rectangle().fill(item.color).frame(width: 5, height: 5)
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text((item.points.first { $0.day == hour }?.tokens ?? 0)
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

/// 单厂商近一年点阵图：格子深浅按当日**总用量**着色（与总览一致，便于横向比较），
/// 悬停气泡列出当天总量 + 各模型明细。
struct MultiSeriesContributionGrid: View {
    let series: [ChartSeries]
    @State private var hoverDay: Date?
    @State private var hoverColumn = 0

    static let defaultCellSize: CGFloat = 10
    static let defaultCellSpacing: CGFloat = 3
    /// 格子边长：默认 10；由图表区高度传入时可随窗口等比伸缩
    var cellSize: CGFloat = Self.defaultCellSize
    private let cellSpacing: CGFloat = Self.defaultCellSpacing
    private var columnWidth: CGFloat { cellSize + cellSpacing }
    private let monthLabelHeight: CGFloat = 14

    /// 总用量序列（第 0 条）的逐日值；点阵用它的日期轴与着色。
    private var primary: ChartSeries? { series.first { $0.isPrimary } ?? series.first }

    private var totals: [Date: Int] {
        var result: [Date: Int] = [:]
        for item in primary?.points ?? [] { result[item.day] = item.tokens }
        return result
    }

    private var days: [DailyTokenUsage] { primary?.points ?? [] }

    private var weeks: [[Date?]] {
        guard !days.isEmpty else { return [] }
        let cal = Calendar(identifier: .gregorian)
        let weekday = cal.component(.weekday, from: days[0].day)
        let leading = (weekday + 5) % 7
        let cells = Array(repeating: nil, count: leading) + days.map { Optional($0.day) }
        var result: [[Date?]] = []
        for chunkStart in stride(from: 0, to: cells.count, by: 7) {
            var week = Array(cells[chunkStart..<min(chunkStart + 7, cells.count)])
            while week.count < 7 { week.append(nil) }
            result.append(week)
        }
        return result
    }

    private var monthLabels: [(column: Int, text: String)] {
        let cal = Calendar(identifier: .gregorian)
        return weeks.enumerated().compactMap { index, week in
            for case let day? in week where cal.component(.day, from: day) == 1 {
                return (index, day.formatted(.dateTime.month(.wide)))
            }
            return nil
        }
    }

    var body: some View {
        let totals = self.totals
        let maxTokens = totals.values.max() ?? 0
        let weeks = self.weeks
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    ZStack(alignment: .topLeading) {
                        Color.clear.frame(
                            width: CGFloat(weeks.count) * columnWidth,
                            height: monthLabelHeight
                        )
                        ForEach(monthLabels, id: \.column) { label in
                            Text(label.text)
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .offset(x: CGFloat(label.column) * columnWidth)
                        }
                    }

                    HStack(spacing: cellSpacing) {
                        ForEach(Array(weeks.enumerated()), id: \.offset) { column, week in
                            VStack(spacing: cellSpacing) {
                                ForEach(Array(week.enumerated()), id: \.offset) { _, cell in
                                    if let day = cell {
                                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                            .fill(color(for: totals[day] ?? 0, max: maxTokens))
                                            .frame(width: cellSize, height: cellSize)
                                            .onHover { hovering in
                                                if hovering {
                                                    hoverDay = day
                                                    hoverColumn = column
                                                } else if hoverDay == day {
                                                    hoverDay = nil
                                                }
                                            }
                                    } else {
                                        Color.clear.frame(width: cellSize, height: cellSize)
                                    }
                                }
                            }
                            .id(column)
                        }
                    }
                }
                .padding(.horizontal, 2)
                .overlay(alignment: .topLeading) {
                    if let hoverDay {
                        tooltip(for: hoverDay)
                            .offset(x: tooltipX, y: monthLabelHeight + 4)
                            .allowsHitTesting(false)
                    }
                }
            }
            .onAppear { proxy.scrollTo(weeks.count - 1, anchor: .trailing) }
            .onChange(of: weeks.count) { _, count in
                proxy.scrollTo(count - 1, anchor: .trailing)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var tooltipX: CGFloat {
        let gridWidth = CGFloat(weeks.count) * columnWidth
        let centerX = CGFloat(hoverColumn) * columnWidth + cellSize / 2 + 2
        return min(max(centerX - 61, 0), max(gridWidth - 122, 0))
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
            ForEach(series) { item in
                HStack(spacing: 4) {
                    Circle().fill(item.color).frame(width: 5, height: 5)
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text((item.points.first { $0.day == day }?.tokens ?? 0)
                        .formatted(.number.notation(.compactName)))
                        .monospacedDigit()
                        .fontWeight(item.isPrimary ? .semibold : .regular)
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
