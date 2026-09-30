import Foundation

/// 用量历史：每次刷新把各厂商额度快照落盘，供面板展示近 7 天趋势。
/// 存 ~/Library/Application Support/QuotaBar/history.json，按 厂商 → 序列 → 采样点 组织。
@MainActor
final class UsageHistory {
    struct Point: Codable, Equatable, Sendable {
        let ts: TimeInterval
        let value: Double
    }

    static let shared = UsageHistory()

    /// 磁盘保留 45 天（「本月用量」需要月初基线）。
    static let retention: TimeInterval = 45 * 86400
    static let displayWindow: TimeInterval = 7 * 86400
    /// 单条序列的最大采样点数（超出丢最旧），防止长期运行文件膨胀。
    static let maxPointsPerSeries = 12000

    /// kind.rawValue → 序列 key（"window:周限额" / "balance:API 余额(CNY)"）→ 采样点
    private(set) var series: [String: [String: [Point]]] = [:]

    private let fileURL: URL

    convenience init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("QuotaBar")
        self.init(fileURL: dir.appendingPathComponent("history.json"))
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    /// 记录一次快照：窗口记录用量比例（0~1），余额记录金额，token 用量记录条数。
    func record(_ snapshot: ProviderSnapshot, at now: Date = Date()) {
        let ts = now.timeIntervalSince1970
        let kind = snapshot.kind.rawValue
        var dirty = false
        for window in snapshot.windows {
            dirty = append(kind: kind, key: "window:\(window.title)", value: window.fraction, at: ts) || dirty
        }
        for balance in snapshot.balances {
            dirty = append(kind: kind, key: "balance:\(balance.label)(\(balance.currency))", value: balance.amount, at: ts) || dirty
        }
        if let tokens = snapshot.tokenUsage {
            dirty = append(kind: kind, key: "tokens", value: Double(tokens), at: ts) || dirty
        }
        if dirty { save() }
    }

    /// 追加点。与末点间隔 <60s 跳过；数值与末点相同且间隔 <30min 也跳过（平稳期不产生冗余点）。
    @discardableResult
    private func append(kind: String, key: String, value: Double, at ts: TimeInterval) -> Bool {
        var points = series[kind]?[key] ?? []
        if let last = points.last {
            let gap = ts - last.ts
            if gap < 60 { return false }
            if gap < 1800, last.value == value { return false }
        }
        points.append(Point(ts: ts, value: value))
        let cutoff = ts - Self.retention
        points.removeAll { $0.ts < cutoff }
        if points.count > Self.maxPointsPerSeries {
            points.removeFirst(points.count - Self.maxPointsPerSeries)
        }
        series[kind, default: [:]][key] = points
        return true
    }

    /// 近 7 天的采样点（供趋势图）。
    func points(kind: ProviderKind, key: String, now: Date = Date()) -> [Point] {
        let cutoff = now.timeIntervalSince1970 - Self.displayWindow
        return (series[kind.rawValue]?[key] ?? []).filter { $0.ts >= cutoff }
    }

    /// 累计型序列（如 tokens）在指定起点之后的增量：最新值 − 起点前最近一次采样值。
    /// 起点前无采样时用最早采样（增量只覆盖采样期内）；周期内厂商计数器重置导致负值时钳制为 0。
    /// 采样不足两个点时返回 nil。
    func delta(kind: ProviderKind, key: String, since start: Date, now: Date = Date()) -> Double? {
        guard let points = series[kind.rawValue]?[key], let latest = points.last else { return nil }
        let baseline = points.last(where: { $0.ts <= start.timeIntervalSince1970 }) ?? points.first
        guard let baseline, latest.ts > baseline.ts else { return nil }
        return max(latest.value - baseline.value, 0)
    }

    /// 累计型序列（tokens）按本地自然日拆分最近 days 天的逐日增量（采样估算）。
    /// 某日增量 = 相邻采样点的差值（归属较晚点所在日），计数器重置的负增量钳制为 0；
    /// 无采样覆盖的日期为 0。供没有本地日志的厂商参与综合趋势图。
    func dailyDeltas(kind: ProviderKind, key: String, days: Int, now: Date = Date()) -> [DailyTokenUsage] {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        let dayStart = cal.startOfDay(for: now)
        guard let firstDay = cal.date(byAdding: .day, value: -(days - 1), to: dayStart) else { return [] }
        let firstTs = firstDay.timeIntervalSince1970

        var perDay: [String: Double] = [:]
        var prev: Point?
        for point in series[kind.rawValue]?[key] ?? [] {
            if let prev, point.ts >= firstTs {
                let delta = max(point.value - prev.value, 0)
                if delta > 0 {
                    let day = Self.dayFormatter.string(from: Date(timeIntervalSince1970: point.ts))
                    perDay[day, default: 0] += delta
                }
            }
            prev = point
        }
        return (0..<days).compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: offset, to: firstDay) else { return nil }
            return DailyTokenUsage(day: day, tokens: Int(perDay[Self.dayFormatter.string(from: day)] ?? 0))
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// 厂商卡片趋势图跟踪的序列：优先周限额窗口，其次第一个窗口，再退化到第一条余额。
    func displayKey(for snapshot: ProviderSnapshot) -> String? {
        if snapshot.windows.contains(where: { $0.title == "周限额" }) { return "window:周限额" }
        if let first = snapshot.windows.first { return "window:\(first.title)" }
        if let first = snapshot.balances.first { return "balance:\(first.label)(\(first.currency))" }
        return nil
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: [String: [Point]]].self, from: data) else { return }
        series = decoded
    }

    private func save() {
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(series)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.append("HIS", "历史写入失败: \(error.localizedDescription)")
        }
    }
}
