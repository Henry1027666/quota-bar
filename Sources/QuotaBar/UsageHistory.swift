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

    /// 磁盘保留 14 天（展示窗口 7 天，留一倍余量）。
    static let retention: TimeInterval = 14 * 86400
    static let displayWindow: TimeInterval = 7 * 86400
    /// 单条序列的最大采样点数（超出丢最旧），防止长期运行文件膨胀。
    static let maxPointsPerSeries = 4000

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
