import Foundation

/// Kimi Code 本地会话日志（~/.kimi-code/sessions/<工作目录>/<会话>/agents/<agent>/wire.jsonl）
/// 的 token 统计。
///
/// Kimi 的用量接口只返回窗口百分比、不返回 token 计数；但每个 agent 的事件日志中
/// 每轮对话都会产生一条 `usage.record`（`usageScope == "turn"`），含
/// inputOther / inputCacheRead / inputCacheCreation / output 四项精确计数与毫秒时间戳。
/// 按事件时间归并到本地自然日，即可得出今日/本周/本月用量。
///
/// 注意：
/// - 子 agent 的用量只记录在自己的 wire.jsonl 里，需遍历 agents 下所有目录。
/// - `usageScope == "session"` 是累计快照，必须排除，否则会与 turn 记录重复计数。
/// - wire.jsonl 只增不改，mtime 早于本月起点的文件不可能含本月记录，直接跳过。
///   其余文件按 mtime+size 做内存缓存，未变化不重读。
enum KimiCodeLocalLogs {
    struct TokenTotals: Equatable, Sendable {
        var today = 0
        var last7 = 0
        var last30 = 0
    }

    /// path → (mtime, size, 每日 token 数)
    private nonisolated(unsafe) static var cache: [String: (mtime: Date, size: UInt64, perDay: [String: Int])] = [:]
    private static let lock = NSLock()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// 统计今日 / 近 7 天 / 近 30 天（滚动窗口，均含今天）的 token 用量。sessionsRoot 为 ~/.kimi-code/sessions。
    static func tokenTotals(sessionsRoot: URL, now: Date = Date()) -> TokenTotals {
        let cal = Calendar(identifier: .gregorian)
        let dayStart = cal.startOfDay(for: now)
        let last7Start = cal.date(byAdding: .day, value: -6, to: dayStart) ?? dayStart
        let last30Start = cal.date(byAdding: .day, value: -29, to: dayStart) ?? dayStart
        let last30Key = dayFormatter.string(from: last30Start)
        let last7Key = dayFormatter.string(from: last7Start)
        let todayKey = dayFormatter.string(from: dayStart)

        var totals = TokenTotals()
        for file in wireFiles(sessionsRoot: sessionsRoot, modifiedSince: last30Start) {
            for (day, tokens) in perDayTokens(file) {
                if day >= last30Key { totals.last30 += tokens }
                if day >= last7Key { totals.last7 += tokens }
                if day == todayKey { totals.today += tokens }
            }
        }
        return totals
    }

    /// 最近 days 天（含今天）的逐日 token 数，按本地自然日升序，无记录的日期为 0。
    static func dailyTokens(sessionsRoot: URL, days: Int, now: Date = Date()) -> [DailyTokenUsage] {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        let dayStart = cal.startOfDay(for: now)
        guard let firstDay = cal.date(byAdding: .day, value: -(days - 1), to: dayStart) else { return [] }
        let firstKey = dayFormatter.string(from: firstDay)

        var perDay: [String: Int] = [:]
        for file in wireFiles(sessionsRoot: sessionsRoot, modifiedSince: firstDay) {
            for (day, tokens) in perDayTokens(file) where day >= firstKey {
                perDay[day, default: 0] += tokens
            }
        }
        return (0..<days).compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: offset, to: firstDay) else { return nil }
            return DailyTokenUsage(day: day, tokens: perDay[dayFormatter.string(from: day)] ?? 0)
        }
    }

    /// 枚举所有 agents/*/wire.jsonl；只增不改的日志按 mtime 剪枝，跳过起始日期之前未再写入的文件。
    private static func wireFiles(sessionsRoot: URL, modifiedSince startDate: Date) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent == "wire.jsonl" {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let mtime, mtime < startDate { continue }
            files.append(url)
        }
        return files
    }

    /// 单文件的每日 token 数（day → tokens），带 mtime+size 缓存。
    private static func perDayTokens(_ url: URL) -> [String: Int] {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? UInt64 else { return [:] }
        lock.lock()
        if let cached = cache[url.path], cached.mtime == mtime, cached.size == size {
            lock.unlock()
            return cached.perDay
        }
        lock.unlock()

        var perDay: [String: Int] = [:]
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            for line in text.split(separator: "\n", omittingEmptySubsequences: true)
            where line.contains("\"type\":\"usage.record\"") && line.contains("\"usageScope\":\"turn\"") {
                guard let data = line.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let usage = event["usage"] as? [String: Any],
                      let ms = Support.number(event["time"]) else { continue }
                let tokens = ["inputOther", "inputCacheRead", "inputCacheCreation", "output"]
                    .reduce(0.0) { $0 + (Support.number(usage[$1]) ?? 0) }
                let day = dayFormatter.string(from: Date(timeIntervalSince1970: ms / 1000))
                perDay[day, default: 0] += Int(tokens)
            }
        }

        lock.lock()
        cache[url.path] = (mtime, size, perDay)
        lock.unlock()
        return perDay
    }
}
