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

// MARK: - DSH 会话日志（zstd）按日归集

/// 用系统 zstd（仅测试环境，用于造 fixture）压缩一段文本。
/// 生产代码用内置的 CZstd 解压，不依赖任何外部命令。
private func zstdCompress(_ text: String) throws -> Data {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
    try text.write(to: tmp, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let out = tmp.appendingPathExtension("zstd")
    defer { try? FileManager.default.removeItem(at: out) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/zstd")
    p.arguments = ["-q", "-f", tmp.path, "-o", out.path]
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw QuotaError.invalidResponse("zstd 压缩失败") }
    return try Data(contentsOf: out)
}

/// 写一个 DSH 会话目录：sessions/<workspace>/<session>/session.v4.jsonl.zstd
private func writeSessionLog(
    root: URL, workspace: String, session: String, fileName: String = "session.v4.jsonl.zstd",
    messages: [(at: Date, provider: String, model: String, input: Int, output: Int, cacheRead: Int)]
) throws {
    let dir = root.appendingPathComponent(workspace).appendingPathComponent(session)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let lines = messages.map { m -> String in
        let ms = Int(m.at.timeIntervalSince1970 * 1000)
        return """
        {"type":"assistant/message","seq":\(abs(m.at.hashValue % 100000)),"time":\(ms),\
        "data":{"turn":1,"step":1,"usage":{"inputTokens":\(m.input),"outputTokens":\(m.output),\
        "totalTokens":\(m.input + m.output + m.cacheRead),"cacheReadTokens":\(m.cacheRead)},\
        "message":{"role":"assistant","source":{"kind":"model","provider":"\(m.provider)",\
        "model":"\(m.model)"},"content":[]}}}
        """
    }.joined(separator: "\n")
    try zstdCompress(lines).write(to: dir.appendingPathComponent(fileName))
}

/// 按消息时间戳归日：跨天会话的用量必须正确拆分（这正是「今日显示 0」的根因）。
@Test func attributesUsageByMessageTimestampNotSessionStart() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("dshlog-\(UUID().uuidString)")
    let cal = Calendar(identifier: .gregorian)
    let today = cal.startOfDay(for: Date())
    let yesterday = cal.date(byAdding: .day, value: -1, to: today)!

    // 同一会话跨天：昨天 300，今天 200
    try writeSessionLog(root: root, workspace: "wd", session: "s1", messages: [
        (yesterday.addingTimeInterval(3600 * 10), "workbuddy-ai", "deepseek-v4.1-flash", 100, 200, 999),
        (today.addingTimeInterval(3600 * 9), "workbuddy-ai", "deepseek-v4.1-flash", 80, 120, 999)
    ])

    let totals = try #require(DSHSessionLogs.tokenTotals(root: root))
    #expect(totals.today == 200, "今天的部分必须算到今天，而不是会话开始日")
    #expect(totals.last7 == 500)

    let daily = DSHSessionLogs.dailyTokens(root: root, days: 3)
    let byDay = Dictionary(uniqueKeysWithValues: daily.map { ($0.day, $0.tokens) })
    #expect(byDay[today] == 200)
    #expect(byDay[yesterday] == 300)

    try FileManager.default.removeItem(at: root)
}

/// 官方 provider 已由平台接口统计，本地必须排除，否则重复计入。
@Test func excludesOfficialProvider() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("dshlog-\(UUID().uuidString)")
    let now = Date()
    try writeSessionLog(root: root, workspace: "wd", session: "s1", messages: [
        (now, "workbuddy-ai", "deepseek-v4.1-flash", 100, 100, 0),
        (now, "deepseek-official", "deepseek-flash", 9999, 9999, 0)
    ])
    let totals = try #require(DSHSessionLogs.tokenTotals(root: root))
    #expect(totals.today == 200, "只应计入非官方 provider 的 100+100")
    try FileManager.default.removeItem(at: root)
}

/// cacheRead 是缓存前缀，会重复计入整个上下文；用它当用量会高估十几倍。
@Test func excludesCacheReadTokens() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("dshlog-\(UUID().uuidString)")
    let now = Date()
    // 真实形态：input 36,071 / output 9,456 / cacheRead 752,640
    try writeSessionLog(root: root, workspace: "wd", session: "s1", messages: [
        (now, "workbuddy-ai", "deepseek-v4.1-flash", 36_071, 9_456, 752_640)
    ])
    let totals = try #require(DSHSessionLogs.tokenTotals(root: root))
    #expect(totals.today == 45_527, "应为 in+out，而非含 cacheRead 的 798,167")
    try FileManager.default.removeItem(at: root)
}

/// 同一会话目录存在多代日志（v3/v4/无版本）时只能取一个，否则重复计数。
@Test func picksOnlyNewestVersionPerSession() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("dshlog-\(UUID().uuidString)")
    let now = Date()
    let msgs: [(at: Date, provider: String, model: String, input: Int, output: Int, cacheRead: Int)] =
        [(now, "workbuddy-ai", "m", 100, 100, 0)]
    // v3 少一条、v4 是超集：若两个都读会得到 400 而非 200
    try writeSessionLog(root: root, workspace: "wd", session: "s1",
                        fileName: "session.v3.jsonl.zstd", messages: msgs)
    try writeSessionLog(root: root, workspace: "wd", session: "s1",
                        fileName: "session.v4.jsonl.zstd", messages: msgs + [
                            (now.addingTimeInterval(60), "workbuddy-ai", "m", 100, 100, 0)
                        ])
    try writeSessionLog(root: root, workspace: "wd", session: "s1",
                        fileName: "session.jsonl.zstd", messages: msgs)

    let totals = try #require(DSHSessionLogs.tokenTotals(root: root))
    #expect(totals.today == 400, "只应读 v4（超集，两条消息共 400），而不是三代相加")
    try FileManager.default.removeItem(at: root)
}

/// 逐小时序列与当日合计必须一致（今日曲线口径）。
/// 注意：今日的逐小时只铺到「当前小时」，因此 fixture 的时间必须早于当前时刻，
/// 否则会被合理截断（那是「今天还没到那个点」，不是 bug）。
@Test func hourlyMatchesDailyTotal() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("dshlog-\(UUID().uuidString)")
    let cal = Calendar(identifier: .gregorian)
    let now = Date()
    let today = cal.startOfDay(for: now)
    // 取 2 小时前 / 1 小时前，确保都落在「当前小时」之前
    let twoHoursAgo = now.addingTimeInterval(-7200)
    let oneHourAgo = now.addingTimeInterval(-3600)
    try writeSessionLog(root: root, workspace: "wd", session: "s1", messages: [
        (twoHoursAgo, "workbuddy-ai", "m", 100, 50, 0),
        (twoHoursAgo.addingTimeInterval(60), "workbuddy-ai", "m", 30, 20, 0),
        (oneHourAgo, "workbuddy-ai", "m", 10, 10, 0)
    ])
    let hourly = DSHSessionLogs.hourlyTokens(root: root, on: today)
    let hourlySum = hourly.reduce(0) { $0 + $1.tokens }
    let totals = try #require(DSHSessionLogs.tokenTotals(root: root))
    #expect(hourlySum == totals.today)
    #expect(hourlySum == 220, "三条消息都在今天且早于当前小时，应全部计入")
    try FileManager.default.removeItem(at: root)
}

/// 模型维度按日拆分，且合计等于逐日总量。
@Test func splitsByModel() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("dshlog-\(UUID().uuidString)")
    let now = Date()
    try writeSessionLog(root: root, workspace: "wd", session: "s1", messages: [
        (now, "workbuddy-ai", "model-a", 100, 100, 0),
        (now, "workbuddy-ai", "model-b", 50, 50, 0)
    ])
    let byModel = DSHSessionLogs.dailyTokensByModel(root: root, days: 7)
    #expect(byModel.count == 2)
    #expect(byModel.first?.model == "model-a", "应按合计降序")
    #expect(byModel.reduce(0) { $0 + $1.total } == 300)
    let dailySum = DSHSessionLogs.dailyTokens(root: root, days: 7).reduce(0) { $0 + $1.tokens }
    #expect(dailySum == 300)
    try FileManager.default.removeItem(at: root)
}

/// 空目录 / 不存在的目录不应崩。
@Test func handlesMissingRoot() {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString)")
    #expect(DSHSessionLogs.tokenTotals(root: missing) == nil)
    #expect(DSHSessionLogs.dailyTokens(root: missing, days: 7).allSatisfy { $0.tokens == 0 })
}

/// 端到端：真实 DSH 日志能取到今日用量（修复前这里恒为 0）。
@MainActor
@Test func realDSHLogsYieldTodayUsage() throws {
    let root = DSHSessionLogs.sessionsRoot()
    guard FileManager.default.fileExists(atPath: root.path) else {
        print("DSH-PROBE: 无 sessions 目录，跳过"); return
    }
    let usage = DeepSeekProvider.collectDSHUsage(root: root, days: 30, now: Date())
    guard let usage else { print("DSH-PROBE: 无非官方 provider 用量"); return }
    print("DSH-PROBE today=\(usage.today) last7=\(usage.breakdown.last7) last30=\(usage.breakdown.last30)")
    for m in usage.byModel ?? [] { print("DSH-PROBE model=\(m.model) total=\(m.total)") }
    #expect(usage.breakdown.last30 >= usage.breakdown.last7)
    #expect(usage.breakdown.last7 >= usage.today)
}
