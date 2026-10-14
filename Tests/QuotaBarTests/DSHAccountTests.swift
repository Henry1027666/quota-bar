import Foundation
import Testing
@testable import QuotaBar

/// 凭据解析：只取 platform grant 的 token，且必须是 platform.deepseek.com 签发。
@Test func parsesDSHTokenFromCredentials() {
    let yaml = """
    version: 1
    refs:
      DEEPSEEK_API_KEY: sk-abc123
    records:
      client-connection/browser-session:
        kind: grant
        payload:
          version: 1
          secret: should-not-be-picked
      deepseek-account-platform/device:
        kind: grant
        payload:
          id: 98853de8-3959-4170-b3b2-44dc2630531e
      deepseek-account-platform/default:
        kind: grant
        payload:
          version: 1
          token: THE-PLATFORM-TOKEN
          issuer: https://platform.deepseek.com
    """
    #expect(DSHDeepSeekAccount.parseToken(from: yaml) == "THE-PLATFORM-TOKEN")
}

/// 必须校验 issuer：其它 origin 的 grant 不能拿来调 platform 接口。
@Test func rejectsNonPlatformIssuer() {
    let yaml = """
    records:
      deepseek-account-platform/default:
        kind: grant
        payload:
          token: OTHER-TOKEN
          issuer: https://evil.example.com
    """
    #expect(DSHDeepSeekAccount.parseToken(from: yaml) == nil)
}

/// 缺 token / 缺 grant / 空文件都应安全返回 nil，不能崩也不能误取。
@Test func handlesMalformedCredentials() {
    #expect(DSHDeepSeekAccount.parseToken(from: "") == nil)
    #expect(DSHDeepSeekAccount.parseToken(from: "version: 1\nrecords: {}\n") == nil)
    // 只有 device grant，没有 default grant
    let onlyDevice = """
    records:
      deepseek-account-platform/device:
        kind: grant
        payload:
          id: 98853de8
    """
    #expect(DSHDeepSeekAccount.parseToken(from: onlyDevice) == nil)
    // token 为空
    let emptyToken = """
    records:
      deepseek-account-platform/default:
        payload:
          token:
    """
    #expect(DSHDeepSeekAccount.parseToken(from: emptyToken) == nil)
}

/// grant 块结束判定：后续同级键的字段不能被误当成该 grant 的内容。
@Test func stopsAtSiblingGrant() {
    let yaml = """
    records:
      deepseek-account-platform/default:
        kind: grant
        payload:
          token: REAL-TOKEN
      deepseek-account-platform/device:
        kind: grant
        payload:
          token: DECOY-TOKEN
    """
    #expect(DSHDeepSeekAccount.parseToken(from: yaml) == "REAL-TOKEN")
}

/// 端到端：真实凭据能拉到余额与逐日用量，且与已知口径一致。
@MainActor
@Test func fetchesRealUsageViaDSHCredential() async throws {
    guard DSHDeepSeekAccount.token() != nil else {
        print("DSH-PROBE: 本机无 DSH 凭据，跳过"); return
    }
    let provider = DeepSeekProvider()
    let snapshot = try await provider.fetch()
    print("DSH-PROBE balances=\(displayBalances(kind: .deepSeek, snapshot: snapshot))")
    print("DSH-PROBE today=\(String(describing: snapshot.tokenUsage)) req=\(String(describing: snapshot.requestCount))")
    print("DSH-PROBE last365=\(String(describing: snapshot.last365Tokens))")
    print("DSH-PROBE dailyDays=\(snapshot.dailyTokens?.count ?? 0) models=\(snapshot.dailyTokensByModel?.count ?? 0)")
    for m in snapshot.dailyTokensByModel ?? [] {
        print("DSH-PROBE model=\(m.model) total=\(m.total)")
    }
    #expect(!snapshot.balances.isEmpty, "应拿到余额")
    #expect(snapshot.dailyTokens != nil, "应拿到逐日用量")
    #expect((snapshot.last365Tokens ?? 0) > 0, "应拿到近一年合计")
}

// MARK: - DSH 其它 provider 用量（补充平台口径）

/// 按 DSH 真实缓存结构写一个会话文件。
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
    try JSONSerialization.data(withJSONObject: root).write(to: dir.appendingPathComponent(name))
}

/// 只统计非官方 provider：deepseek-official 已由平台接口统计，重复计入会翻倍。
@Test func dshCountsOnlyNonOfficialProviders() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-\(UUID().uuidString)")
    let dir = root.appendingPathComponent("sessions")
    let today = Calendar(identifier: .gregorian).startOfDay(for: Date())

    // wb ai：平台看不到，必须计入
    try writeDSHSession(into: dir, name: "wb.json", createdAt: today.addingTimeInterval(3600),
                        provider: "workbuddy-ai", model: "deepseek-v4.1-flash",
                        uncachedInput: 1000, output: 200, cacheRead: 50_000)
    // 官方：平台已统计，必须排除
    try writeDSHSession(into: dir, name: "official.json", createdAt: today.addingTimeInterval(7200),
                        provider: "deepseek-official", model: "deepseek-flash",
                        uncachedInput: 9999, output: 9999)
    // 旧格式无 provider：无法判定来源，跳过
    try writeDSHSession(into: dir, name: "legacy.json", createdAt: today.addingTimeInterval(10800),
                        provider: nil, model: "deepseek-flash", uncachedInput: 5555, output: 5555)

    let totals = try #require(DSHSessionLogs.tokenTotals(directory: dir))
    #expect(totals.today == 1200, "只应计入 wb ai 的 1000+200")

    let byModel = DSHSessionLogs.dailyTokensByModel(directory: dir, days: 7)
    #expect(byModel.count == 1)
    #expect(byModel.first?.model == "deepseek-v4.1-flash")
    #expect(byModel.first?.total == 1200)

    try FileManager.default.removeItem(at: root)
}

/// cacheRead 是缓存前缀，会随每轮重复计入整个上下文；用它当用量会高估十几倍。
@Test func dshExcludesCacheReadTokens() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-\(UUID().uuidString)")
    let dir = root.appendingPathComponent("sessions")
    let today = Calendar(identifier: .gregorian).startOfDay(for: Date())
    // 真实形态：input 36,071 / output 9,456 / cacheRead 752,640
    try writeDSHSession(into: dir, name: "a.json", createdAt: today.addingTimeInterval(3600),
                        provider: "workbuddy-ai", model: "deepseek-v4.1-flash",
                        uncachedInput: 36_071, output: 9_456, cacheRead: 752_640)
    let totals = try #require(DSHSessionLogs.tokenTotals(directory: dir))
    #expect(totals.today == 45_527, "应为 in+out，而非含 cacheRead 的 798,167")
    try FileManager.default.removeItem(at: root)
}

@Test func dshDailyTokensBucketByStartDay() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-\(UUID().uuidString)")
    let dir = root.appendingPathComponent("sessions")
    let today = Calendar(identifier: .gregorian).startOfDay(for: Date())
    try writeDSHSession(into: dir, name: "t.json", createdAt: today.addingTimeInterval(3600),
                        provider: "workbuddy-ai", model: "m", uncachedInput: 100, output: 100)
    try writeDSHSession(into: dir, name: "d3.json", createdAt: today.addingTimeInterval(-3 * 86400),
                        provider: "workbuddy-ai", model: "m", uncachedInput: 50, output: 50)
    try writeDSHSession(into: dir, name: "old.json", createdAt: today.addingTimeInterval(-40 * 86400),
                        provider: "workbuddy-ai", model: "m", uncachedInput: 9999, output: 9999)

    let daily = DSHSessionLogs.dailyTokens(directory: dir, days: 7)
    #expect(daily.count == 7)
    #expect(daily.last?.tokens == 200)
    #expect(daily[daily.count - 4].tokens == 100)
    #expect(daily.reduce(0) { $0 + $1.tokens } == 300)
    try FileManager.default.removeItem(at: root)
}

/// 只有官方 provider 时返回 nil，确保不干扰平台原有口径。
@Test func dshReturnsNilWhenOnlyOfficial() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("dsh-\(UUID().uuidString)")
    let dir = root.appendingPathComponent("sessions")
    let today = Calendar(identifier: .gregorian).startOfDay(for: Date())
    try writeDSHSession(into: dir, name: "a.json", createdAt: today,
                        provider: "deepseek-official", model: "m", uncachedInput: 100, output: 100)
    #expect(DSHSessionLogs.tokenTotals(directory: dir) == nil)
    try FileManager.default.removeItem(at: root)
    // 目录不存在也不应崩
    #expect(DSHSessionLogs.tokenTotals(directory: dir.appendingPathComponent("nope")) == nil)
}

@Test func mergeBreakdownSumsBothSources() {
    let platform = TokenBreakdown(today: 100, last7: 700, last30: 3000)
    let dsh = TokenBreakdown(today: 20, last7: 150, last30: 400)
    let merged = DeepSeekProvider.mergeBreakdown(platform, dsh)
    #expect(merged.today == 120)
    #expect(merged.last7 == 850)
    #expect(merged.last30 == 3400)
    #expect(DeepSeekProvider.mergeBreakdown(nil, dsh).today == 20)
}

@Test func mergeDailyAddsOverlappingDays() {
    let cal = Calendar(identifier: .gregorian)
    let today = cal.startOfDay(for: Date())
    let d1 = cal.date(byAdding: .day, value: -1, to: today)!
    let d2 = cal.date(byAdding: .day, value: -2, to: today)!
    let platform = [
        DailyTokenUsage(day: today, tokens: 100),
        DailyTokenUsage(day: d1, tokens: 200),
        DailyTokenUsage(day: d2, tokens: 300)
    ]
    let dsh = [
        DailyTokenUsage(day: today, tokens: 10),
        DailyTokenUsage(day: d1, tokens: 20)
    ]
    let merged = DeepSeekProvider.mergeDaily(platform, dsh)
    #expect(merged.count == 3)
    let byDay = Dictionary(uniqueKeysWithValues: merged.map { ($0.day, $0.tokens) })
    #expect(byDay[today] == 110)
    #expect(byDay[d1] == 220)
    #expect(byDay[d2] == 300)
    #expect(merged.map(\.day) == [d2, d1, today])
    #expect(DeepSeekProvider.mergeDaily(nil, dsh).count == 2)
}

@Test func mergeModelSeriesCombinesSameModelName() {
    let today = Calendar(identifier: .gregorian).startOfDay(for: Date())
    let l = [ModelTokenSeries(model: "deepseek-flash", points: [DailyTokenUsage(day: today, tokens: 100)])]
    let r = [ModelTokenSeries(model: "deepseek-flash", points: [DailyTokenUsage(day: today, tokens: 50)])]
    let merged = DeepSeekProvider.mergeModelSeries(l, r)
    #expect(merged?.count == 1)
    #expect(merged?.first?.total == 150)
    #expect(DeepSeekProvider.mergeModelSeries(nil, r)?.first?.total == 50)
    #expect(DeepSeekProvider.mergeModelSeries(l, nil)?.first?.total == 100)
    #expect(DeepSeekProvider.mergeModelSeries(nil, nil) == nil)
}

/// 端到端：真实 DSH 缓存能取到非官方 provider 用量（本机有 wb ai 会话时应 > 0）。
@MainActor
@Test func collectsRealDSHNonOfficialUsage() async throws {
    let dir = DSHSessionLogs.projcacheDirectory()
    guard FileManager.default.fileExists(atPath: dir.path) else {
        print("DSH-PROBE: 无 DSH projcache，跳过"); return
    }
    let usage = DeepSeekProvider.collectDSHUsage(directory: dir, days: 30, now: Date())
    print("DSH-PROBE collect = \(usage == nil ? "nil" : "today=\(usage!.today) last30=\(usage!.breakdown.last30)")")
    if let byModel = usage?.byModel {
        for m in byModel { print("DSH-PROBE model=\(m.model) total=\(m.total)") }
    }
    let official = usage?.byModel?.contains { $0.model.contains("deepseek-flash") && $0.total > 100_000_000 } ?? false
    #expect(!official, "不应把官方 provider 的大额用量算进来")
}
