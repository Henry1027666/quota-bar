import Foundation

/// Codex 本地会话日志（~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl）的 token 统计。
///
/// Codex 的用量接口只返回窗口百分比、不返回 token 计数；但本地会话日志中每轮对话
/// 都会产生一条 `token_count` 事件，`payload.info.last_token_usage.total_tokens`
/// 是该轮的精确增量。按事件时间戳归并到本地自然小时，即可得出逐小时 / 逐日 /
/// 今日 / 近 7 天 / 近 30 天各级口径的用量。
///
/// 模型维度：`token_count` 自身不带模型名，但每一轮对话前会写入一条 `turn_context`
/// 记录（`payload.model`）。因此顺序扫描文件、把「最近一次见到的 turn_context.model」
/// 作为后续 token_count 的归属模型即可。实测 314 个会话文件中 turn_context 无缺失；
/// 若个别文件确实缺失（或 token_count 出现在首个 turn_context 之前），归入 unknownModel，
/// 仍然计入总量，只是细分曲线里显示为「未知模型」。
///
/// 日志量大（数百 MB），按文件 mtime+size 做内存缓存，未变化的文件不重读。
enum CodexLocalLogs {
    struct TokenTotals: Equatable, Sendable {
        var today = 0
        var last7 = 0
        var last30 = 0
    }

    /// turn_context 缺失时的兜底模型名（仅影响模型细分，不影响总量口径）。
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
        for file in sessionFiles(sessionsRoot: sessionsRoot, since: firstKey) {
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
        let perHour = hourlyTotals(sessionsRoot: sessionsRoot, on: day)
        return hourlySeries(from: perHour, on: day, now: now)
    }

    /// 最近 days 天（含今天）的逐日 token 用量，按模型拆分（升序，无记录日期补 0）。
    /// 只返回窗口内有数据的模型，按合计降序。
    static func dailyTokensByModel(sessionsRoot: URL, days: Int, now: Date = Date()) -> [ModelTokenSeries] {
        let cal = Calendar(identifier: .gregorian)
        let dayStart = cal.startOfDay(for: now)
        guard let firstDay = cal.date(byAdding: .day, value: -(days - 1), to: dayStart) else { return [] }
        let firstKey = dayFormatter.string(from: firstDay)

        var perModelPerDay: [String: [String: Int]] = [:]
        for file in sessionFiles(sessionsRoot: sessionsRoot, since: firstKey) {
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
        let dayStart = Calendar(identifier: .gregorian).startOfDay(for: day)
        let dayKey = dayFormatter.string(from: dayStart)
        var perModel: [String: [Int: Int]] = [:]
        for file in sessionFiles(sessionsRoot: sessionsRoot, since: dayKey) {
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
        let dayKey = dayFormatter.string(from: Calendar(identifier: .gregorian).startOfDay(for: day))
        var perHour: [Int: Int] = [:]
        for file in sessionFiles(sessionsRoot: sessionsRoot, since: dayKey) {
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

    /// 单文件的「模型 → 每小时 token 数」，带 mtime+size 缓存。
    ///
    /// 必须单次顺序扫描：模型归属依赖前文出现的 turn_context，分行过滤会丢掉这个上下文。
    /// 只解析同时含 `token_count` 或 `turn_context` 的行，其余行（占日志绝大多数）快速跳过。
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
        var currentModel = unknownModel
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                // turn_context：记录本轮的模型名，供后续 token_count 归属
                if line.contains("\"turn_context\"") {
                    if let data = line.data(using: .utf8),
                       let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       event["type"] as? String == "turn_context",
                       let payload = event["payload"] as? [String: Any],
                       let model = payload["model"] as? String, !model.isEmpty {
                        currentModel = model
                    }
                    continue
                }
                guard line.contains("\"type\":\"token_count\"") else { continue }
                guard let data = line.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = event["payload"] as? [String: Any],
                      let info = payload["info"] as? [String: Any],
                      let last = info["last_token_usage"] as? [String: Any],
                      let total = Support.number(last["total_tokens"]),
                      let ts = Support.date(event["timestamp"]) else { continue }
                perHourByModel[currentModel, default: [:]][hourFormatter.string(from: ts), default: 0] += Int(total)
            }
        }

        lock.lock()
        cache[url.path] = (mtime, size, perHourByModel)
        lock.unlock()
        return perHourByModel
    }
}
