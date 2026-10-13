import Foundation

/// DeepSeek Harness（DSH）本地会话统计：`~/.dsh/storages/session_projcache/sessions/*.json`。
///
/// 为什么需要它：DSH 里如果通过第三方路由（如 `provider: "workbuddy-ai"`）调用 DeepSeek 模型，
/// 这些请求**不经过用户自己的 DeepSeek API key**，因此 platform.deepseek.com 的
/// `by_api_key/*` 接口（面板里 DeepSeek 卡片的既有数据源）完全看不到这部分用量。
/// 本地会话缓存是唯一能反映它的地方。
///
/// 数据源选择：DSH 的会话正文（`~/.dsh/sessions/**/session*.jsonl.zstd`）是 **zstd 压缩**的，
/// macOS 的 Compression 框架只提供 lzfse/lz4/zlib，不含 zstd；为此引入 Homebrew 的
/// libzstd 会让下载安装的用户强依赖 Homebrew。而 `storages/session_projcache` 下的
/// **未压缩** JSON 缓存里带有同一份精确数据（已与 zstd 正文逐字段核对一致）：
///
/// ```json
/// "tokenUsage": { "val": { "totals": {
///     "uncachedInputTokens": 36071, "outputTokens": 9456,
///     "cacheReadTokens": 752640, "cacheWriteTokens": 0 } } }
/// "modelSelection": { "val": { "lastUsed": { "provider": "workbuddy-ai",
///                                             "model": "deepseek-v4.1-flash" } } }
/// ```
///
/// 口径说明：
/// - `totals` 是**会话累计**（与 zstd 正文里 assistant/message 的逐请求 usage 求和一致）；
/// - 取 `uncachedInputTokens + outputTokens` 作为「本会话 token 用量」。
///   **不含 `cacheReadTokens`**——那是命中缓存的前缀，会重复计入整个上下文
///   （实测同一会话 in+out=45,527 而 in+out+cacheRead=798,167，相差 17.5 倍）；
/// - 只统计 `provider == "workbuddy-ai"` 的会话（用户明确要的是 wb ai 用量）；
///   `deepseek-official` 是用户 API key 直连，platform 接口已在统计，重复计入会翻倍；
///   早期格式无 `modelSelection` 的会话无法判定来源，宁可漏计也不错计。
///
/// 158 个会话缓存、解析耗时可忽略（每个文件几 KB），但仍按 mtime+size 做内存缓存。
enum DSHSessionLogs {
    /// 被统计的第三方路由标识（DSH 中 wb ai 的 provider 名）。
    static let workBuddyProvider = "workbuddy-ai"

    /// path → (mtime, size, 该会话的统计)
    private nonisolated(unsafe) static var cache: [String: (mtime: Date, size: UInt64, stats: SessionStats?)] = [:]
    private static let lock = NSLock()

    /// 单个 DSH 会话的 token 统计。
    struct SessionStats: Equatable, Sendable {
        /// 会话开始时间（identity.createdAt，毫秒 epoch）。
        let startedAt: Date
        let model: String
        /// 非缓存输入 + 输出（不含 cacheRead，见类型注释的口径说明）。
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

    /// 最近 days 天（含今天）逐日 token 用量；无数据时返回空序列。
    /// 归属日期取会话开始时间（会话内跨天的情况极少，且缓存只保留会话级累计值）。
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

    /// 今日 / 近 7 天 / 近 30 天合计（滚动窗口，均含今天）。无任何数据时返回 nil。
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

    /// 遍历目录下所有会话缓存，解析出被统计的会话（带 mtime+size 缓存）。
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

    /// 解析单个会话缓存 JSON。
    /// 结构：{ record: { identity: { createdAt }, rows: { tokenUsage: { val: { totals } },
    ///                                                  modelSelection: { val: { lastUsed } } } } }
    private static func parse(_ url: URL) -> SessionStats? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let record = root["record"] as? [String: Any] else { return nil }
        let rows = record["rows"] as? [String: Any] ?? [:]

        // 只统计 wb ai 路由；无 modelSelection 的旧会话无法判定来源，跳过
        guard let selection = (rows["modelSelection"] as? [String: Any])?["val"] as? [String: Any],
              let lastUsed = selection["lastUsed"] as? [String: Any],
              (lastUsed["provider"] as? String) == workBuddyProvider,
              let model = lastUsed["model"] as? String, !model.isEmpty else { return nil }

        guard let totals = ((rows["tokenUsage"] as? [String: Any])?["val"] as? [String: Any])?["totals"]
                as? [String: Any] else { return nil }
        // 不含 cacheRead：「非缓存输入 + 输出」才是本次真实新增的 token
        let input = Support.number(totals["uncachedInputTokens"]).map(Int.init) ?? 0
        let output = Support.number(totals["outputTokens"]).map(Int.init) ?? 0
        let tokens = input + output
        guard tokens > 0 else { return nil }

        let identity = record["identity"] as? [String: Any] ?? [:]
        guard let ms = Support.number(identity["createdAt"]) else { return nil }
        return SessionStats(
            startedAt: Date(timeIntervalSince1970: ms / 1000),
            model: model,
            tokens: tokens
        )
    }
}
