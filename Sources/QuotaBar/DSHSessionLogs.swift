import Foundation

/// DeepSeek Harness（DSH）本地会话统计：`~/.dsh/storages/session_projcache/sessions/*.json`。
///
/// 为什么需要它：DeepSeek 卡片的 token 用量原先只有一个来源——platform.deepseek.com 的
/// `by_api_key/*` 接口，它**只统计走本机 API key 的调用**。而 DSH 可以接多个 provider
/// （实测有 `deepseek-official` 与 `workbuddy-ai`），非官方路由的调用不经过该 key，
/// 平台接口完全看不到，于是这部分用量被漏掉了。本文件把这些「其它 provider」的用量补上。
///
/// 与平台口径的分工（重要，避免重复计算）：
/// - `deepseek-official` → 已由平台 `by_api_key` 统计，**此处必须排除**，
///   否则同一批调用会在两套口径下被算两次；
/// - 其它 provider（如 `workbuddy-ai`）→ 平台看不到，由这里统计；
/// - 旧格式会话（无 `modelSelection`）→ 无法判定来源，宁可不计也不错计。
///
/// 数据源为什么不用 `~/.dsh/sessions/**/*.jsonl.zstd`：那是 zstd 压缩的，而 macOS 的
/// Compression 框架只有 lzfse/lz4/zlib，不含 zstd；为此引入 Homebrew 的 libzstd 会让
/// 下载安装的用户强依赖 Homebrew。`session_projcache` 下的**未压缩** JSON 缓存带有
/// 同一份数据（已逐字段与 zstd 正文核对一致）。
///
/// 口径：取 `uncachedInputTokens + outputTokens`，**不含 `cacheReadTokens`**。
/// 后者是命中缓存的前缀，会随每轮重复计入整个上下文（实测同一会话 in+out=45,527
/// 而 in+out+cacheRead=798,167，相差 17.5 倍）。
enum DSHSessionLogs {
    /// 官方 provider：其用量已由平台接口统计，本地不再重复计入。
    static let officialProvider = "deepseek-official"

    /// path → (mtime, size, 解析结果)；解析结果 nil 表示该会话不计入。
    private nonisolated(unsafe) static var cache: [String: (mtime: Date, size: UInt64, stats: SessionStats?)] = [:]
    private static let lock = NSLock()

    /// 单个 DSH 会话的用量统计。
    struct SessionStats: Equatable, Sendable {
        /// 会话开始时间（identity.createdAt，毫秒 epoch）。
        let startedAt: Date
        /// 路由该会话的 provider（如 "workbuddy-ai"）。
        let provider: String
        /// 模型名（如 "deepseek-v4.1-flash"）。
        let model: String
        /// 非缓存输入 + 输出（不含 cacheRead，见类型注释）。
        let tokens: Int
    }

    /// 会话缓存目录（DSH 默认 ~/.dsh，可用 DSH_HOME 覆盖）。
    static func projcacheDirectory(home: URL? = nil) -> URL {
        let base = home ?? ProcessInfo.processInfo.environment["DSH_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh")
        return base
            .appendingPathComponent("storages")
            .appendingPathComponent("session_projcache")
            .appendingPathComponent("sessions")
    }

    /// 最近 days 天（含今天）逐日 token 用量；无数据返回空数组。
    /// 归属日期取会话开始时间（会话内跨天极少，且缓存只留会话级累计值）。
    static func dailyTokens(directory: URL, days: Int, now: Date = Date()) -> [DailyTokenUsage] {
        let cal = Calendar(identifier: .gregorian)
        let dayStart = cal.startOfDay(for: now)
        guard let firstDay = cal.date(byAdding: .day, value: -(days - 1), to: dayStart) else { return [] }

        var perDay: [Date: Int] = [:]
        for stats in allSessions(directory: directory) {
            let day = cal.startOfDay(for: stats.startedAt)
            guard day >= firstDay, day <= dayStart else { continue }
            perDay[day, default: 0] += stats.tokens
        }
        return (0..<days).compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: offset, to: firstDay) else { return nil }
            return DailyTokenUsage(day: day, tokens: perDay[day] ?? 0)
        }
    }

    /// 最近 days 天逐日用量，按模型拆分（升序，缺失日期补 0）；只含有数据的模型，按合计降序。
    static func dailyTokensByModel(directory: URL, days: Int, now: Date = Date()) -> [ModelTokenSeries] {
        let cal = Calendar(identifier: .gregorian)
        let dayStart = cal.startOfDay(for: now)
        guard let firstDay = cal.date(byAdding: .day, value: -(days - 1), to: dayStart) else { return [] }

        var perModelPerDay: [String: [Date: Int]] = [:]
        for stats in allSessions(directory: directory) {
            let day = cal.startOfDay(for: stats.startedAt)
            guard day >= firstDay, day <= dayStart else { continue }
            perModelPerDay[stats.model, default: [:]][day, default: 0] += stats.tokens
        }
        return perModelPerDay.compactMap { model, perDay in
            let points = (0..<days).compactMap { offset -> DailyTokenUsage? in
                guard let day = cal.date(byAdding: .day, value: offset, to: firstDay) else { return nil }
                return DailyTokenUsage(day: day, tokens: perDay[day] ?? 0)
            }
            let series = ModelTokenSeries(model: model, points: points)
            return series.total > 0 ? series : nil
        }
        .sorted { $0.total > $1.total }
    }

    /// 今日 / 近 7 天 / 近 30 天合计（滚动窗口，均含今天）。无数据时返回 nil。
    static func tokenTotals(directory: URL, now: Date = Date()) -> TokenBreakdown? {
        let sessions = allSessions(directory: directory)
        guard !sessions.isEmpty else { return nil }
        let cal = Calendar(identifier: .gregorian)
        let dayStart = cal.startOfDay(for: now)
        let last7Start = cal.date(byAdding: .day, value: -6, to: dayStart) ?? dayStart
        let last30Start = cal.date(byAdding: .day, value: -29, to: dayStart) ?? dayStart

        var today = 0, last7 = 0, last30 = 0
        for stats in sessions {
            let day = cal.startOfDay(for: stats.startedAt)
            guard day <= dayStart else { continue }
            if day >= last30Start { last30 += stats.tokens }
            if day >= last7Start { last7 += stats.tokens }
            if day == dayStart { today += stats.tokens }
        }
        return TokenBreakdown(today: today, last7: last7, last30: last30)
    }

    /// 遍历目录下所有会话缓存（带 mtime+size 缓存，未变化的文件不重读）。
    private static func allSessions(directory: URL) -> [SessionStats] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [SessionStats] = []
        for url in entries where url.pathExtension == "json" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let mtime = values.contentModificationDate,
                  let size = values.fileSize.map(UInt64.init) else { continue }
            lock.lock()
            let cached = cache[url.path]
            lock.unlock()
            if let cached, cached.mtime == mtime, cached.size == size {
                if let stats = cached.stats { result.append(stats) }
                continue
            }
            let stats = parse(url)
            lock.lock()
            cache[url.path] = (mtime, size, stats)
            lock.unlock()
            if let stats { result.append(stats) }
        }
        return result
    }

    /// 解析单个会话缓存：只保留「非官方 provider」的会话。
    /// 结构：{ record: { identity: { createdAt },
    ///                   rows: { tokenUsage: { val: { totals } },
    ///                           modelSelection: { val: { lastUsed: { provider, model } } } } } }
    private static func parse(_ url: URL) -> SessionStats? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let record = root["record"] as? [String: Any] else { return nil }
        let rows = record["rows"] as? [String: Any] ?? [:]

        // 无 modelSelection 的旧会话无法判定来源 → 跳过（宁缺勿错）
        guard let selection = (rows["modelSelection"] as? [String: Any])?["val"] as? [String: Any],
              let lastUsed = selection["lastUsed"] as? [String: Any],
              let provider = lastUsed["provider"] as? String, !provider.isEmpty,
              provider != officialProvider else { return nil }
        let model = (lastUsed["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? provider

        guard let totals = ((rows["tokenUsage"] as? [String: Any])?["val"] as? [String: Any])?["totals"]
                as? [String: Any] else { return nil }
        // 不含 cacheRead：那是缓存前缀，会重复计入整个上下文
        let input = Support.number(totals["uncachedInputTokens"]).map(Int.init) ?? 0
        let output = Support.number(totals["outputTokens"]).map(Int.init) ?? 0
        let tokens = input + output
        guard tokens > 0 else { return nil }

        let identity = record["identity"] as? [String: Any] ?? [:]
        guard let ms = Support.number(identity["createdAt"]) else { return nil }
        return SessionStats(
            startedAt: Date(timeIntervalSince1970: ms / 1000),
            provider: provider,
            model: model,
            tokens: tokens
        )
    }
}
