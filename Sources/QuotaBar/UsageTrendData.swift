import Foundation

/// 趋势图翻页的数据入口。
///
/// - Codex / Kimi Code：直接读本地日志，全历史可查、精确到小时；
/// - DeepSeek：网页接口口径，快照中只有近 30 天逐日与今日逐小时，更早的窗口缺席。
///
/// 日志解析量大（数百 MB），所有入口都是 async 且不在主线程执行文件 IO——
/// 视图层用 .task 加载，绝不能回到在 body 里同步调用（冷扫描会卡死窗口打开）。
enum UsageTrendData {
    /// 以 endDay 为最后一天（含）的逐日序列；该厂商在窗口内无任何数据时返回 nil。
    static func daily(kind: ProviderKind, days: Int, endingOn endDay: Date,
                      snapshot: ProviderSnapshot?) async -> [DailyTokenUsage]? {
        switch kind {
        case .codex:
            let result = await Task.detached {
                CodexLocalLogs.dailyTokens(sessionsRoot: codexSessions, days: days, now: endDay)
            }.value
            return result.contains(where: { $0.tokens > 0 }) ? result : nil
        case .kimi:
            let result = await Task.detached {
                KimiCodeLocalLogs.dailyTokens(sessionsRoot: kimiSessions, days: days, now: endDay)
            }.value
            return result.contains(where: { $0.tokens > 0 }) ? result : nil
        case .deepSeek:
            guard let daily = snapshot?.dailyTokens else { return nil }
            return slice(daily: daily, days: days, endingOn: endDay)
        }
    }

    /// 某天的逐小时序列；该厂商在该天无任何数据时返回 nil。
    static func hourly(kind: ProviderKind, on day: Date, snapshot: ProviderSnapshot?) async -> [HourlyTokenUsage]? {
        switch kind {
        case .codex:
            let result = await Task.detached {
                CodexLocalLogs.hourlyTokens(sessionsRoot: codexSessions, on: day)
            }.value
            return result.contains(where: { $0.tokens > 0 }) ? result : nil
        case .kimi:
            let result = await Task.detached {
                KimiCodeLocalLogs.hourlyTokens(sessionsRoot: kimiSessions, on: day)
            }.value
            return result.contains(where: { $0.tokens > 0 }) ? result : nil
        case .deepSeek:
            // 逐小时只在「今天」拉取（网页接口口径），历史日期没有数据
            guard Calendar.current.isDateInToday(day) else { return nil }
            return snapshot?.hourlyTokens
        }
    }

    /// 与 `daily` 同口径的逐日序列，按模型拆分（只含有数据的模型，按合计降序）。
    /// 无模型维度（或窗口内该厂商无数据）时返回 nil，图表退化为只画总用量一条线。
    static func dailyByModel(kind: ProviderKind, days: Int, endingOn endDay: Date,
                             snapshot: ProviderSnapshot?) async -> [ModelTokenSeries]? {
        switch kind {
        case .codex:
            let result = await Task.detached {
                CodexLocalLogs.dailyTokensByModel(sessionsRoot: codexSessions, days: days, now: endDay)
            }.value
            return result.isEmpty ? nil : result
        case .kimi:
            let result = await Task.detached {
                KimiCodeLocalLogs.dailyTokensByModel(sessionsRoot: kimiSessions, days: days, now: endDay)
            }.value
            return result.isEmpty ? nil : result
        case .deepSeek:
            // 快照的模型序列按近 30 天日期轴铺开，需切到与 daily 相同的窗口
            guard let byModel = snapshot?.dailyTokensByModel else { return nil }
            return sliceByModel(byModel, days: days, endingOn: endDay)
        }
    }

    /// 与 `hourly` 同口径的逐小时序列，按模型拆分。仅「今天」有数据（与 hourly 一致）。
    static func hourlyByModel(kind: ProviderKind, on day: Date,
                              snapshot: ProviderSnapshot?) async -> [ModelTokenSeries]? {
        switch kind {
        case .codex:
            let result = await Task.detached {
                CodexLocalLogs.hourlyTokensByModel(sessionsRoot: codexSessions, on: day)
            }.value
            return result.isEmpty ? nil : result
        case .kimi:
            let result = await Task.detached {
                KimiCodeLocalLogs.hourlyTokensByModel(sessionsRoot: kimiSessions, on: day)
            }.value
            return result.isEmpty ? nil : result
        case .deepSeek:
            guard Calendar.current.isDateInToday(day) else { return nil }
            guard let byModel = snapshot?.hourlyTokensByModel, !byModel.isEmpty else { return nil }
            return byModel
        }
    }

    /// 从快照的 30 天逐日序列中切出指定窗口（窗口内未被覆盖的日期补 0；完全不重叠返回 nil）。
    private static func slice(daily: [DailyTokenUsage], days: Int, endingOn endDay: Date) -> [DailyTokenUsage]? {
        let cal = Calendar(identifier: .gregorian)
        let endStart = cal.startOfDay(for: endDay)
        guard let firstDay = cal.date(byAdding: .day, value: -(days - 1), to: endStart) else { return nil }
        var byDay: [Date: Int] = [:]
        for item in daily { byDay[item.day] = item.tokens }
        let result = (0..<days).compactMap { offset -> DailyTokenUsage? in
            guard let day = cal.date(byAdding: .day, value: offset, to: firstDay) else { return nil }
            return DailyTokenUsage(day: day, tokens: byDay[day] ?? 0)
        }
        return result.contains(where: { $0.tokens > 0 }) ? result : nil
    }

    /// `slice` 的模型维度版本：把每个模型的 30 天序列按 endDay 对齐重铺到 days 天窗口。
    /// 窗口完全不覆盖快照日期范围时全部补 0，这些空序列会被过滤掉，最终返回 nil。
    private static func sliceByModel(_ byModel: [ModelTokenSeries], days: Int,
                                     endingOn endDay: Date) -> [ModelTokenSeries]? {
        let cal = Calendar(identifier: .gregorian)
        let endStart = cal.startOfDay(for: endDay)
        guard let firstDay = cal.date(byAdding: .day, value: -(days - 1), to: endStart) else { return nil }
        let result = byModel.compactMap { series -> ModelTokenSeries? in
            var byDay: [Date: Int] = [:]
            for point in series.points { byDay[point.day] = point.tokens }
            let points = (0..<days).compactMap { offset -> DailyTokenUsage? in
                guard let day = cal.date(byAdding: .day, value: offset, to: firstDay) else { return nil }
                return DailyTokenUsage(day: day, tokens: byDay[day] ?? 0)
            }
            let sliced = ModelTokenSeries(model: series.model, points: points)
            return sliced.total > 0 ? sliced : nil
        }
        .sorted { $0.total > $1.total }
        return result.isEmpty ? nil : result
    }

    private static let codexSessions = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions")
    private static let kimiSessions = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".kimi-code/sessions")
}
