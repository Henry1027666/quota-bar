import Foundation

/// Codex 本地会话日志（~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl）的 token 统计。
///
/// Codex 的用量接口只返回窗口百分比、不返回 token 计数；但本地会话日志中每轮对话
/// 都会产生一条 `token_count` 事件，`payload.info.last_token_usage.total_tokens`
/// 是该轮的精确增量。按事件时间戳归并到本地自然日，即可得出今日/本周/本月用量。
///
/// 日志量大（数百 MB），按文件 mtime+size 做内存缓存，未变化的文件不重读。
enum CodexLocalLogs {
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

    /// 统计今日 / 近 7 天 / 近 30 天（滚动窗口，均含今天）的 token 用量。sessionsRoot 为 ~/.codex/sessions。
    static func tokenTotals(sessionsRoot: URL, now: Date = Date()) -> TokenTotals {
        let cal = Calendar(identifier: .gregorian)
        let dayStart = cal.startOfDay(for: now)
        let last7Start = cal.date(byAdding: .day, value: -6, to: dayStart) ?? dayStart
        let last30Start = cal.date(byAdding: .day, value: -29, to: dayStart) ?? dayStart
        let last30Key = dayFormatter.string(from: last30Start)
        let last7Key = dayFormatter.string(from: last7Start)
        let todayKey = dayFormatter.string(from: dayStart)

        var totals = TokenTotals()
        for file in sessionFiles(sessionsRoot: sessionsRoot, since: last30Key) {
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
        for file in sessionFiles(sessionsRoot: sessionsRoot, since: firstKey) {
            for (day, tokens) in perDayTokens(file) where day >= firstKey {
                perDay[day, default: 0] += tokens
            }
        }
        return (0..<days).compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: offset, to: firstDay) else { return nil }
            return DailyTokenUsage(day: day, tokens: perDay[dayFormatter.string(from: day)] ?? 0)
        }
    }

    /// sessions 目录按 YYYY/MM/DD 组织（本地日期），只需枚举自起始日期起的日期目录。
    private static func sessionFiles(sessionsRoot: URL, since startKey: String) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            // 路径形如 .../sessions/2026/09/30/rollout-xxx.jsonl
            let day = url.deletingLastPathComponent().lastPathComponent
            let month = url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            let year = url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            let key = "\(year)-\(month)-\(day)"
            guard key.count == 10, key >= startKey else { continue }
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
            where line.contains("\"type\":\"token_count\"") {
                guard let data = line.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = event["payload"] as? [String: Any],
                      let info = payload["info"] as? [String: Any],
                      let last = info["last_token_usage"] as? [String: Any],
                      let total = Support.number(last["total_tokens"]),
                      let ts = Support.date(event["timestamp"]) else { continue }
                perDay[dayFormatter.string(from: ts), default: 0] += Int(total)
            }
        }

        lock.lock()
        cache[url.path] = (mtime, size, perDay)
        lock.unlock()
        return perDay
    }
}
