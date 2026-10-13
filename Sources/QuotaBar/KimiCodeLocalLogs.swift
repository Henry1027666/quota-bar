import Foundation

/// Kimi Code 本地会话日志（~/.kimi-code/sessions/<工作目录>/<会话>/agents/<agent>/wire.jsonl）
/// 的 token 统计。
///
/// Kimi 的用量接口只返回窗口百分比、不返回 token 计数；但每个 agent 的事件日志中
/// 每轮对话都会产生一条 `usage.record`（`usageScope == "turn"`），含
/// inputOther / inputCacheRead / inputCacheCreation / output 四项精确计数与毫秒时间戳。
/// 按事件时间归并到本地自然小时，即可得出逐小时 / 逐日 / 今日 / 近 7 天 / 近 30 天用量。
///
/// 模型维度：`usage.record` 自带 `model` 字段（如 "kimi-code/k3-256k"），无需状态机即可归属。
///
/// 注意：
/// - 子 agent 的用量只记录在自己的 wire.jsonl 里，需遍历 agents 下所有目录。
/// - `usageScope == "session"` 是累计快照，必须排除，否则会与 turn 记录重复计数。
/// - wire.jsonl 只增不改，mtime 早于统计窗口起点的文件不可能含窗口内记录，直接跳过。
///   其余文件按 mtime+size 做内存缓存，未变化不重读。
enum KimiCodeLocalLogs {
    struct TokenTotals: Equatable, Sendable {
        var today = 0
        var last7 = 0
        var last30 = 0
    }

    /// usage.record 缺 model 字段时的兜底模型名（仅影响模型细分，不影响总量口径）。
    static let unknownModel = "未知模型"

    /// path → (mtime, size, 逐模型每小时 token 数)
    private nonisolated(unsafe) static var cache: [String: (mtime: Date, size: UInt64, perHourByModel: [String: [String: Int]])] = [:]
    private static let lock = NSLock()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let hourFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH"
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
            // 逐模型展开：同一小时可能跨多个模型，需把各模型的该小时用量相加
            for perHour in perHourTokens(file).values {
                for (hourKey, tokens) in perHour {
                    let day = String(hourKey.prefix(10))
                    guard day >= last30Key else { continue }
                    totals.last30 += tokens
                    if day >= last7Key { totals.last7 += tokens }
                    if day == todayKey { totals.today += tokens }
                }
            }
        }
        return totals
    }

    /// 最近 days 天（含今天）的逐日 token 数，按本地自然日升序，无记录的日期为 0。
    static func dailyTokens(sessionsRoot: URL, days: Int, now: Date = Date()) -> [DailyTokenUsage] {
        let cal = Calendar(identifier: .gregorian)
        let dayStart = cal.startOfDay(for: now)
        guard let firstDay = cal.date(byAdding: .day, value: -(days - 1), to: dayStart) else { return [] }
        let firstKey = dayFormatter.string(from: firstDay)

        var perDay: [String: Int] = [:]
        for file in wireFiles(sessionsRoot: sessionsRoot, modifiedSince: firstDay) {
            for perHour in perHourTokens(file).values {
                for (hourKey, tokens) in perHour {
                    let day = String(hourKey.prefix(10))
                    guard day >= firstKey else { continue }
                    perDay[day, default: 0] += tokens
                }
            }
        }
        return (0..<days).compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: offset, to: firstDay) else { return nil }
            return DailyTokenUsage(day: day, tokens: perDay[dayFormatter.string(from: day)] ?? 0)
        }
    }

    /// 某天（默认今天）的逐小时 token 用量；今天只返回到当前小时，历史日期返回完整 24 小时。
    static func hourlyTokens(sessionsRoot: URL, on day: Date = Date(), now: Date = Date()) -> [HourlyTokenUsage] {
        hourlySeries(from: hourlyTotals(sessionsRoot: sessionsRoot, on: day), on: day, now: now)
    }

    /// 最近 days 天（含今天）的逐日 token 用量，按模型拆分（升序，无记录日期补 0）。
    /// 只返回窗口内有数据的模型，按合计降序。
    static func dailyTokensByModel(sessionsRoot: URL, days: Int, now: Date = Date()) -> [ModelTokenSeries] {
        let cal = Calendar(identifier: .gregorian)
        let dayStart = cal.startOfDay(for: now)
        guard let firstDay = cal.date(byAdding: .day, value: -(days - 1), to: dayStart) else { return [] }
        let firstKey = dayFormatter.string(from: firstDay)

        var perModelPerDay: [String: [String: Int]] = [:]
        for file in wireFiles(sessionsRoot: sessionsRoot, modifiedSince: firstDay) {
            for (model, perHour) in perHourTokens(file) {
                for (hourKey, tokens) in perHour {
                    let day = String(hourKey.prefix(10))
                    guard day >= firstKey else { continue }
                    perModelPerDay[model, default: [:]][day, default: 0] += tokens
                }
            }
        }
        return perModelPerDay.compactMap { model, perDay in
            let points = (0..<days).compactMap { offset -> DailyTokenUsage? in
                guard let day = cal.date(byAdding: .day, value: offset, to: firstDay) else { return nil }
                return DailyTokenUsage(day: day, tokens: perDay[dayFormatter.string(from: day)] ?? 0)
            }
            let series = ModelTokenSeries(model: model, points: points)
            return series.total > 0 ? series : nil
        }
        .sorted { $0.total > $1.total }
    }

    /// 某天（默认今天）的逐小时 token 用量，按模型拆分；只返回该天有数据的模型，按合计降序。
    static func hourlyTokensByModel(sessionsRoot: URL, on day: Date = Date(), now: Date = Date()) -> [ModelTokenSeries] {
        let dayKey = dayFormatter.string(from: Calendar(identifier: .gregorian).startOfDay(for: day))
        var perModel: [String: [Int: Int]] = [:]
        for file in wireFiles(sessionsRoot: sessionsRoot, modifiedSince: Calendar(identifier: .gregorian).startOfDay(for: day)) {
            for (model, perHour) in perHourTokens(file) {
                for (key, tokens) in perHour where key.hasPrefix(dayKey) {
                    guard let hour = Int(key.suffix(2)) else { continue }
                    perModel[model, default: [:]][hour, default: 0] += tokens
                }
            }
        }
        return perModel.compactMap { model, perHour -> ModelTokenSeries? in
            let points = hourlySeries(from: perHour, on: day, now: now).map {
                DailyTokenUsage(day: $0.hour, tokens: $0.tokens)
            }
            let series = ModelTokenSeries(model: model, points: points)
            return series.total > 0 ? series : nil
        }
        .sorted { $0.total > $1.total }
    }

    /// 某天各小时的合计 token 数（跨模型求和）。
    private static func hourlyTotals(sessionsRoot: URL, on day: Date) -> [Int: Int] {
        let dayStart = Calendar(identifier: .gregorian).startOfDay(for: day)
        let dayKey = dayFormatter.string(from: dayStart)
        var perHour: [Int: Int] = [:]
        for file in wireFiles(sessionsRoot: sessionsRoot, modifiedSince: dayStart) {
            for modelPerHour in perHourTokens(file).values {
                for (key, tokens) in modelPerHour where key.hasPrefix(dayKey) {
                    guard let hour = Int(key.suffix(2)) else { continue }
                    perHour[hour, default: 0] += tokens
                }
            }
        }
        return perHour
    }

    /// 把「小时 → token 数」铺成 0 点到 lastHour 的完整序列（今天截到当前小时）。
    private static func hourlySeries(from perHour: [Int: Int], on day: Date, now: Date) -> [HourlyTokenUsage] {
        let cal = Calendar(identifier: .gregorian)
        let dayStart = cal.startOfDay(for: day)
        let isToday = dayFormatter.string(from: dayStart) == dayFormatter.string(from: now)
        let lastHour = isToday ? cal.component(.hour, from: now) : 23
        return (0...lastHour).compactMap { hour in
            cal.date(byAdding: .hour, value: hour, to: dayStart).map {
                HourlyTokenUsage(hour: $0, tokens: perHour[hour] ?? 0)
            }
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

    /// 单文件的「模型 → 每小时 token 数」，带 mtime+size 缓存。
    private static func perHourTokens(_ url: URL) -> [String: [String: Int]] {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? UInt64 else { return [:] }
        lock.lock()
        if let cached = cache[url.path], cached.mtime == mtime, cached.size == size {
            lock.unlock()
            return cached.perHourByModel
        }
        lock.unlock()

        var perHourByModel: [String: [String: Int]] = [:]
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            for line in text.split(separator: "\n", omittingEmptySubsequences: true)
            where line.contains("\"type\":\"usage.record\"") && line.contains("\"usageScope\":\"turn\"") {
                guard let data = line.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let usage = event["usage"] as? [String: Any],
                      let ms = Support.number(event["time"]) else { continue }
                let tokens = ["inputOther", "inputCacheRead", "inputCacheCreation", "output"]
                    .reduce(0.0) { $0 + (Support.number(usage[$1]) ?? 0) }
                // usage.record 自带 model 字段；缺失时归入 unknownModel，仍计入总量
                let model = (event["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? unknownModel
                let hour = hourFormatter.string(from: Date(timeIntervalSince1970: ms / 1000))
                perHourByModel[model, default: [:]][hour, default: 0] += Int(tokens)
            }
        }

        lock.lock()
        cache[url.path] = (mtime, size, perHourByModel)
        lock.unlock()
        return perHourByModel
    }
}
