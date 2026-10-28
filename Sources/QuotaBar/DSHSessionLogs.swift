import Foundation

/// DeepSeek Harness（DSH）本地会话日志统计：`~/.dsh/sessions/**/session*.jsonl.zstd`。
///
/// 为什么需要它：DeepSeek 卡片的 token 用量原先只有一个来源——platform.deepseek.com 的
/// `by_api_key/*` 接口，它**只统计走本机 API key 的调用**。而 DSH 可以接多个 provider
/// （实测有 `deepseek-official` 与 `workbuddy-ai`），非官方路由的调用不经过该 key，
/// 平台接口完全看不到，于是这部分用量被漏掉了。本文件把这些「其它 provider」补上。
///
/// 与平台口径的分工（重要，避免重复计算）：
/// - `deepseek-official` 近 30 天 → 已由平台 `by_api_key` 统计，**此处必须排除**；
/// - `deepseek-official` 更早的历史 → 平台只回溯 30 天查不到，由本地日志补齐
///   （`dailyTokens` / `dailyTokensByModel` 传 `includeOfficialBefore:` 启用）；
/// - 其它 provider（如 `workbuddy-ai`）→ 平台完全看不到，始终由这里统计；
/// - 无法判定 provider 的记录 → 宁可不计也不错计。
///
/// 为什么必须解析压缩正文（而不是 `storages/session_projcache` 的未压缩 JSON）：
/// projcache 只保存**会话累计** token（`tokenUsage.totals`）与最后活动时间，没有按日明细。
/// 一个会话可以跨天连续使用，把累计值算到会话开始日会让「今日用量」严重失真
/// （实测某会话 10-13 开始、10-14 仍在用，46 万 token 全被算到 10-13，当日显示 0，
/// 而 10-14 实际有 13 万）。压缩正文里每条 `assistant/message` 都带毫秒时间戳，
/// 是唯一能精确归日的数据源。解压由随包编译的 zstd 单文件解压器完成（见 CZstd），
/// 不依赖 Homebrew 或任何外部组件。
///
/// 口径：取 `totalTokens`（= `inputTokens + cacheReadTokens + outputTokens`），
/// 与平台 `by_api_key` 的计费口径对齐。
///
/// **不要只取 `inputTokens + outputTokens`**（本项目曾如此实现，导致少算两三个数量级）：
/// DSH 的 `inputTokens` 是**未命中缓存**的输入部分，`cacheReadTokens` 是**命中缓存**的输入部分，
/// 两者互不重叠、都是真实消耗的 prompt token，平台侧分别对应 PROMPT_CACHE_MISS_TOKEN /
/// PROMPT_CACHE_HIT_TOKEN，**都计入计费**。实测每条请求恒满足
/// `total = inputTokens + cacheReadTokens + outputTokens`，说明三者是不重叠的分项。
/// 本机实测差距：某会话当日 in+out=197,040，而含 cacheRead 为 101,759,408（约 500 倍）。
///
/// 去重：同一会话目录可能同时存在 `session.jsonl.zstd` / `session.v3.jsonl.zstd` /
/// `session.v4.jsonl.zstd`，它们是同一会话的不同格式世代、内容互相重叠
/// （实测 v4 是 v3 的超集）。**每个目录只取版本号最高的一个**，否则会重复计数。
enum DSHSessionLogs {
    /// 官方 provider：近 30 天的用量已由平台接口统计，窗口内本地不再重复计入；
    /// 但平台只回溯近 30 天，更早的历史只能由本地日志补上（见 `includeOfficialBefore`）。
    static let officialProvider = "deepseek-official"

    /// path → (mtime, size, 该文件解析出的 (时间, 模型, token) 点)
    private nonisolated(unsafe) static var fileCache: [String: (mtime: Date, size: UInt64, points: [UsagePoint])] = [:]
    private static let lock = NSLock()
    /// 解析结果磁盘缓存：重启后免全量重新解压/解析，只有新增/变化的文件才重新读
    private static let diskCache = LogParseCache<[UsagePoint]>(name: "dsh")

    /// 一条消息级用量（含精确时间戳，用于按日归集）。
    struct UsagePoint: Equatable, Sendable, Codable {
        let at: Date
        let provider: String
        let model: String
        /// 本次请求的总 token（未命中输入 + 命中输入 + 输出），与平台计费口径一致。
        let tokens: Int
    }

    /// DSH 的 sessions 根目录（DSH 默认 ~/.dsh，可用 DSH_HOME 覆盖）。
    static func sessionsRoot(home: URL? = nil) -> URL {
        let base = home ?? ProcessInfo.processInfo.environment["DSH_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh")
        return base.appendingPathComponent("sessions")
    }

    /// 官方 provider 的点是否计入本次聚合：
    /// - 不传 cutoff（今日/近7/近30、逐小时）：一律排除——这些窗口平台接口都能覆盖；
    /// - 传 cutoff（历史回溯）：cutoff 之前的官方点计入（平台只回溯近 30 天，更早的
    ///   官方用量平台已查不到，必须由本地日志补上），cutoff 当天及之后仍排除以免重复。
    private static func makeInclude(officialCutoff: Date?, cal: Calendar) -> (UsagePoint) -> Bool {
        guard let officialCutoff else {
            return { $0.provider != officialProvider }
        }
        return { point in
            point.provider != officialProvider
                || cal.startOfDay(for: point.at) < officialCutoff
        }
    }

    /// 最近 days 天（含今天）逐日 token 用量；无数据返回全 0 序列。
    /// `includeOfficialBefore:` 传入平台窗口起点（通常今天-29 天）时，早于该日期的
    /// 官方 provider 用量也会计入（用于把历史回溯补到平台 30 天覆盖之外）。
    static func dailyTokens(root: URL, days: Int, includeOfficialBefore officialCutoff: Date? = nil,
                            now: Date = Date()) -> [DailyTokenUsage] {
        let cal = Calendar(identifier: .gregorian)
        let dayStart = cal.startOfDay(for: now)
        guard let firstDay = cal.date(byAdding: .day, value: -(days - 1), to: dayStart) else { return [] }
        let include = makeInclude(officialCutoff: officialCutoff, cal: cal)

        var perDay: [Date: Int] = [:]
        for point in allPoints(root: root, since: firstDay) where include(point) {
            let day = cal.startOfDay(for: point.at)
            guard day >= firstDay, day <= dayStart else { continue }
            perDay[day, default: 0] += point.tokens
        }
        return (0..<days).compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: offset, to: firstDay) else { return nil }
            return DailyTokenUsage(day: day, tokens: perDay[day] ?? 0)
        }
    }

    /// 最近 days 天逐日用量，按模型拆分（只含有数据的模型，按合计降序）。
    /// `includeOfficialBefore:` 语义与 `dailyTokens` 相同。
    static func dailyTokensByModel(root: URL, days: Int, includeOfficialBefore officialCutoff: Date? = nil,
                                   now: Date = Date()) -> [ModelTokenSeries] {
        let cal = Calendar(identifier: .gregorian)
        let dayStart = cal.startOfDay(for: now)
        guard let firstDay = cal.date(byAdding: .day, value: -(days - 1), to: dayStart) else { return [] }
        let include = makeInclude(officialCutoff: officialCutoff, cal: cal)

        var perModelPerDay: [String: [Date: Int]] = [:]
        for point in allPoints(root: root, since: firstDay) where include(point) {
            let day = cal.startOfDay(for: point.at)
            guard day >= firstDay, day <= dayStart else { continue }
            perModelPerDay[point.model, default: [:]][day, default: 0] += point.tokens
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

    /// 某天的逐小时用量（供「今日」曲线）。仅统计该天，返回 0 点到当前小时的完整序列。
    static func hourlyTokens(root: URL, on day: Date = Date(), now: Date = Date()) -> [HourlyTokenUsage] {
        let cal = Calendar(identifier: .gregorian)
        let dayStart = cal.startOfDay(for: day)
        let isToday = dayStart == cal.startOfDay(for: now)
        let lastHour = isToday ? cal.component(.hour, from: now) : 23

        var perHour: [Int: Int] = [:]
        for point in allPoints(root: root, since: dayStart)
        where cal.startOfDay(for: point.at) == dayStart && point.provider != officialProvider {
            let hour = cal.component(.hour, from: point.at)
            perHour[hour, default: 0] += point.tokens
        }
        return (0...lastHour).compactMap { hour in
            cal.date(byAdding: .hour, value: hour, to: dayStart).map {
                HourlyTokenUsage(hour: $0, tokens: perHour[hour] ?? 0)
            }
        }
    }

    /// 今日 / 近 7 天 / 近 30 天合计（滚动窗口，均含今天）。无数据返回 nil。
    static func tokenTotals(root: URL, now: Date = Date()) -> TokenBreakdown? {
        let cal = Calendar(identifier: .gregorian)
        let dayStart = cal.startOfDay(for: now)
        let last7Start = cal.date(byAdding: .day, value: -6, to: dayStart) ?? dayStart
        let last30Start = cal.date(byAdding: .day, value: -29, to: dayStart) ?? dayStart
        let points = allPoints(root: root, since: last30Start)
        guard !points.isEmpty else { return nil }

        var today = 0, last7 = 0, last30 = 0
        for point in points where point.provider != officialProvider {
            let day = cal.startOfDay(for: point.at)
            guard day <= dayStart else { continue }
            if day >= last30Start { last30 += point.tokens }
            if day >= last7Start { last7 += point.tokens }
            if day == dayStart { today += point.tokens }
        }
        return TokenBreakdown(today: today, last7: last7, last30: last30)
    }

    // MARK: - 文件遍历与解析

    /// 枚举所有会话目录，每个目录取版本最高的日志文件，汇总其用量点。
    ///
    /// 按 mtime 剪枝：日志只增不改，mtime 早于窗口起点的文件不可能含窗口内记录。
    /// 这一步很关键——本机 160 个待解压文件解压后合计 824MB 文本（其中只有 4 万行带 usage），
    /// 全量冷扫描约 38s；剪枝到近 30 天后只剩约 40 个文件（66MB），耗时降到秒级。
    /// 已实测验证：120 个 mtime 超 30 天的旧文件中，**没有**任何一个的最后一条消息落在窗口内，
    /// 因此按 mtime 跳过是安全的。
    private static func allPoints(root: URL, since cutoff: Date) -> [UsagePoint] {
        guard let workspaceDirs = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [UsagePoint] = []
        for workspace in workspaceDirs {
            guard let sessionDirs = try? FileManager.default.contentsOfDirectory(
                at: workspace, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for session in sessionDirs {
                guard let file = newestSessionLog(in: session) else { continue }
                // mtime 剪枝：文件最后写入早于窗口起点 → 不可能有窗口内记录
                if let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate, mtime < cutoff { continue }
                result.append(contentsOf: points(in: file))
            }
        }
        return result
    }

    /// 同一会话目录里可能有 session.jsonl.zstd / session.v3 / session.v4 等多个世代，
    /// 内容互相重叠（v4 ⊃ v3）。取版本号最高的一个，避免重复计数。
    private static func newestSessionLog(in directory: URL) -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }

        var best: (version: Int, url: URL)?
        for url in files where url.lastPathComponent.hasPrefix("session") && url.pathExtension == "zstd" {
            // "session.jsonl.zstd" → 0；"session.v4.jsonl.zstd" → 4
            let name = url.lastPathComponent
            var version = 0
            if let r = name.range(of: #"\.v(\d+)\."#, options: .regularExpression) {
                version = Int(name[r].dropFirst(2).dropLast(1)) ?? 0
            }
            if best == nil || version > best!.version { best = (version, url) }
        }
        return best?.url
    }

    /// 解析单个日志文件：逐行取 assistant/message 的 usage 与时间戳。
    /// 带 mtime+size 缓存，未变化的文件不重复解压。
    private static func points(in url: URL) -> [UsagePoint] {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let mtime = values.contentModificationDate,
              let size = values.fileSize.map(UInt64.init) else { return [] }
        lock.lock()
        let cached = fileCache[url.path]
        lock.unlock()
        if let cached, cached.mtime == mtime, cached.size == size { return cached.points }

        // 内存未命中 → 查磁盘缓存（重启后的热路径）
        if let value = diskCache.value(for: url.path, mtime: mtime, size: size) {
            lock.lock()
            fileCache[url.path] = (mtime, size, value)
            lock.unlock()
            return value
        }

        let parsed = parse(url)
        lock.lock()
        fileCache[url.path] = (mtime, size, parsed)
        lock.unlock()
        diskCache.insert(parsed, for: url.path, mtime: mtime, size: size)
        return parsed
    }

    private static func parse(_ url: URL) -> [UsagePoint] {
        guard let text = DSHLogZstd.decompressText(at: url) else { return [] }
        var result: [UsagePoint] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            // 快速跳过：只处理带 usage 的 assistant/message
            guard line.contains("\"assistant/message\""), line.contains("\"usage\"") else { continue }
            guard let data = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  event["type"] as? String == "assistant/message",
                  let payload = event["data"] as? [String: Any],
                  let usage = payload["usage"] as? [String: Any],
                  let ms = Support.number(event["time"]) else { continue }

            // provider/model 在 data.message.source。官方 provider 的点**不在这里丢弃**：
            // 近 30 天的窗口内用量由平台接口统计（调用方排除），更早的历史则由本地补齐
            // （调用方按 includeOfficialBefore 计入），两种口径在聚合时分流。
            let source = ((payload["message"] as? [String: Any])?["source"] as? [String: Any]) ?? [:]
            guard let provider = source["provider"] as? String, !provider.isEmpty else { continue }
            let model = (source["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? provider

            // 与平台计费口径一致：未命中输入 + 命中输入（cacheRead）+ 输出。
            // 三者不重叠（实测 totalTokens 恒等于三者之和），漏掉 cacheRead 会少算两三个数量级。
            let input = Support.number(usage["inputTokens"]).map(Int.init) ?? 0
            let cacheRead = Support.number(usage["cacheReadTokens"]).map(Int.init) ?? 0
            let output = Support.number(usage["outputTokens"]).map(Int.init) ?? 0
            let tokens = input + cacheRead + output
            guard tokens > 0 else { continue }

            result.append(UsagePoint(
                at: Date(timeIntervalSince1970: ms / 1000),
                provider: provider,
                model: model,
                tokens: tokens
            ))
        }
        return result
    }
}
