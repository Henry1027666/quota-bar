import Foundation
import Testing
@testable import QuotaBar

/// 按 DSH 真实缓存结构写一个会话文件（只保留解析所需字段）。
private func writeDSHSession(
    into dir: URL, name: String, createdAt: Date, provider: String?, model: String,
    uncachedInput: Int, output: Int, cacheRead: Int = 0
) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var rows: [String: Any] = [
        "tokenUsage": ["val": ["totals": [
            "uncachedInputTokens": uncachedInput,
            "outputTokens": output,
            "cacheReadTokens": cacheRead,
            "cacheWriteTokens": 0
        ]]]
    ]
    if let provider {
        rows["modelSelection"] = ["val": ["lastUsed": ["provider": provider, "model": model]]]
    }
    let root: [String: Any] = [
        "record": [
            "identity": ["createdAt": createdAt.timeIntervalSince1970 * 1000],
            "rows": rows
        ]
    ]
    let data = try JSONSerialization.data(withJSONObject: root)
    try data.write(to: dir.appendingPathComponent(name))
}

@Test func dshCountsOnlyWorkBuddyProvider() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-\(UUID().uuidString)")
    let dir = root.appendingPathComponent("sessions")
    let today = Calendar(identifier: .gregorian).startOfDay(for: Date())

    // wb ai：计入
    try writeDSHSession(into: dir, name: "a.json", createdAt: today.addingTimeInterval(3600),
                        provider: "workbuddy-ai", model: "deepseek-v4.1-flash",
                        uncachedInput: 1000, output: 200, cacheRead: 50_000)
    // deepseek-official：platform 接口已在统计，必须排除，否则重复计入
    try writeDSHSession(into: dir, name: "b.json", createdAt: today.addingTimeInterval(7200),
                        provider: "deepseek-official", model: "deepseek-flash",
                        uncachedInput: 9999, output: 9999)
    // 无 provider（旧格式）：无法判定来源，跳过
    try writeDSHSession(into: dir, name: "c.json", createdAt: today.addingTimeInterval(10800),
                        provider: nil, model: "deepseek-flash",
                        uncachedInput: 5555, output: 5555)

    let totals = try #require(DSHSessionLogs.tokenTotals(directory: dir))
    // 只算 wb ai 的 1000+200；cacheRead 不计入
    #expect(totals.today == 1200)
    #expect(totals.last7 == 1200)

    let byModel = DSHSessionLogs.dailyTokensByModel(directory: dir, days: 7)
    #expect(byModel.count == 1)
    #expect(byModel.first?.model == "deepseek-v4.1-flash")
    #expect(byModel.first?.total == 1200)

    try FileManager.default.removeItem(at: root)
}

/// cacheRead 是命中缓存的前缀，会重复计入整个上下文；用它当用量会高估十几倍。
@Test func dshExcludesCacheReadTokens() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-\(UUID().uuidString)")
    let dir = root.appendingPathComponent("sessions")
    let today = Calendar(identifier: .gregorian).startOfDay(for: Date())
    // 真实形态：input 36,071 / output 9,456 / cacheRead 752,640
    try writeDSHSession(into: dir, name: "a.json", createdAt: today.addingTimeInterval(3600),
                        provider: "workbuddy-ai", model: "deepseek-v4.1-flash",
                        uncachedInput: 36_071, output: 9_456, cacheRead: 752_640)

    let totals = try #require(DSHSessionLogs.tokenTotals(directory: dir))
    #expect(totals.today == 45_527, "应为 in+out，而非 in+out+cacheRead(798,167)")
    #expect(totals.today != 798_167)

    try FileManager.default.removeItem(at: root)
}

@Test func dshDailyTokensBucketByStartDay() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-\(UUID().uuidString)")
    let dir = root.appendingPathComponent("sessions")
    let cal = Calendar(identifier: .gregorian)
    let today = cal.startOfDay(for: Date())

    try writeDSHSession(into: dir, name: "t.json", createdAt: today.addingTimeInterval(3600),
                        provider: "workbuddy-ai", model: "m", uncachedInput: 100, output: 100)
    // 3 天前
    try writeDSHSession(into: dir, name: "d3.json", createdAt: today.addingTimeInterval(-3 * 86400),
                        provider: "workbuddy-ai", model: "m", uncachedInput: 50, output: 50)
    // 窗口外
    try writeDSHSession(into: dir, name: "old.json", createdAt: today.addingTimeInterval(-40 * 86400),
                        provider: "workbuddy-ai", model: "m", uncachedInput: 9999, output: 9999)

    let daily = DSHSessionLogs.dailyTokens(directory: dir, days: 7)
    #expect(daily.count == 7)
    #expect(daily.last?.tokens == 200)
    #expect(daily[daily.count - 4].tokens == 100)
    #expect(daily.reduce(0) { $0 + $1.tokens } == 300)

    try FileManager.default.removeItem(at: root)
}

/// 无 wb ai 会话时返回 nil，避免影响 platform 原有口径。
@Test func dshReturnsNilWithoutWorkBuddySessions() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-\(UUID().uuidString)")
    let dir = root.appendingPathComponent("sessions")
    let today = Calendar(identifier: .gregorian).startOfDay(for: Date())
    try writeDSHSession(into: dir, name: "a.json", createdAt: today,
                        provider: "deepseek-official", model: "m",
                        uncachedInput: 100, output: 100)
    #expect(DSHSessionLogs.tokenTotals(directory: dir) == nil)
    try FileManager.default.removeItem(at: root)
    // 目录不存在时也不应崩
    #expect(DSHSessionLogs.tokenTotals(directory: dir.appendingPathComponent("nope")) == nil)
}

// MARK: - 与 platform 来源的合并

@Test func mergeBreakdownSumsBothSources() {
    let platform = TokenBreakdown(today: 100, last7: 700, last30: 3000)
    let dsh = TokenBreakdown(today: 20, last7: 150, last30: 400)
    let merged = DeepSeekProvider.mergeBreakdown(platform, dsh)
    #expect(merged.today == 120)
    #expect(merged.last7 == 850)
    #expect(merged.last30 == 3400)
    // 任一侧缺失时取另一侧
    #expect(DeepSeekProvider.mergeBreakdown(nil, dsh).today == 20)
}

@Test func mergeDailyAddsOverlappingDays() {
    let cal = Calendar(identifier: .gregorian)
    let today = cal.startOfDay(for: Date())
    let d0 = today
    let d1 = cal.date(byAdding: .day, value: -1, to: today)!
    let d2 = cal.date(byAdding: .day, value: -2, to: today)!

    let platform = [
        DailyTokenUsage(day: d0, tokens: 100),
        DailyTokenUsage(day: d1, tokens: 200),
        DailyTokenUsage(day: d2, tokens: 300)
    ]
    // DSH 只覆盖较近两天，且与 platform 重叠
    let dsh = [
        DailyTokenUsage(day: d0, tokens: 10),
        DailyTokenUsage(day: d1, tokens: 20)
    ]
    let merged = DeepSeekProvider.mergeDaily(platform, dsh)
    #expect(merged.count == 3)
    let byDay = Dictionary(uniqueKeysWithValues: merged.map { ($0.day, $0.tokens) })
    #expect(byDay[d0] == 110, "重叠日应相加")
    #expect(byDay[d1] == 220)
    #expect(byDay[d2] == 300, "仅 platform 有的日期保留")
    // 按日期升序
    #expect(merged.map(\.day) == [d2, d1, d0])
    // 任一侧缺失时取另一侧
    #expect(DeepSeekProvider.mergeDaily(nil, dsh).count == 2)
}

@Test func mergeModelSeriesCombinesSameModelName() {
    let cal = Calendar(identifier: .gregorian)
    let today = cal.startOfDay(for: Date())
    let l = [ModelTokenSeries(model: "deepseek-flash", points: [
        DailyTokenUsage(day: today, tokens: 100)
    ])]
    let r = [ModelTokenSeries(model: "deepseek-flash", points: [
        DailyTokenUsage(day: today, tokens: 50)
    ])]
    let merged = DeepSeekProvider.mergeModelSeries(l, r)
    #expect(merged?.count == 1, "同名模型应合并为一条")
    #expect(merged?.first?.total == 150)
    // 单侧为 nil 时取另一侧
    #expect(DeepSeekProvider.mergeModelSeries(nil, r)?.first?.total == 50)
    #expect(DeepSeekProvider.mergeModelSeries(l, nil)?.first?.total == 100)
    #expect(DeepSeekProvider.mergeModelSeries(nil, nil) == nil)
}
