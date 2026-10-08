import Foundation

/// 趋势图翻页的数据入口（仅在视图主线程调用）。
///
/// - Codex / Kimi Code：直接读本地日志，全历史可查、精确到小时；
/// - DeepSeek：网页接口口径，快照中只有近 30 天逐日与今日逐小时，更早的窗口缺席；
/// - 其余厂商：回退到采样序列（磁盘保留 45 天）。
@MainActor
enum UsageTrendData {
    /// 以 endDay 为最后一天（含）的逐日序列；该厂商在窗口内无任何数据时返回 nil。
    static func daily(kind: ProviderKind, days: Int, endingOn endDay: Date,
                      snapshot: ProviderSnapshot?) -> [DailyTokenUsage]? {
        switch kind {
        case .codex:
            let result = CodexLocalLogs.dailyTokens(sessionsRoot: codexSessions, days: days, now: endDay)
            return result.contains(where: { $0.tokens > 0 }) ? result : nil
        case .kimi:
            let result = KimiCodeLocalLogs.dailyTokens(sessionsRoot: kimiSessions, days: days, now: endDay)
            return result.contains(where: { $0.tokens > 0 }) ? result : nil
        case .deepSeek:
            guard let daily = snapshot?.dailyTokens else { return nil }
            return slice(daily: daily, days: days, endingOn: endDay)
        case .claude:
            guard snapshot?.tokenUsage != nil else { return nil }
            let result = UsageHistory.shared.dailyDeltas(kind: kind, key: "tokens", days: days, now: endDay)
            return result.contains(where: { $0.tokens > 0 }) ? result : nil
        }
    }

    /// 某天的逐小时序列；该厂商在该天无任何数据时返回 nil。
    static func hourly(kind: ProviderKind, on day: Date, snapshot: ProviderSnapshot?) -> [HourlyTokenUsage]? {
        switch kind {
        case .codex:
            let result = CodexLocalLogs.hourlyTokens(sessionsRoot: codexSessions, on: day)
            return result.contains(where: { $0.tokens > 0 }) ? result : nil
        case .kimi:
            let result = KimiCodeLocalLogs.hourlyTokens(sessionsRoot: kimiSessions, on: day)
            return result.contains(where: { $0.tokens > 0 }) ? result : nil
        case .deepSeek:
            // 逐小时只在「今天」拉取（网页接口口径），历史日期没有数据
            guard Calendar.current.isDateInToday(day) else { return nil }
            return snapshot?.hourlyTokens
        case .claude:
            return nil
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

    private static let codexSessions = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions")
    private static let kimiSessions = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".kimi-code/sessions")
}
