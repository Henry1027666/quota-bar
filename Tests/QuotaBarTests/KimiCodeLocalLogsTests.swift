import Foundation
import Testing
@testable import QuotaBar

@Test func kimiCodeLocalLogsTotalsByDay() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("kimi-test-\(UUID().uuidString)")
    let sessions = root.appendingPathComponent("sessions")
    let cal = Calendar(identifier: .gregorian)
    let now = Date()
    let dayStart = cal.startOfDay(for: now)

    // 按 sessions/wd_x/session_y/agents/<agent>/wire.jsonl 结构写 fixture，时间取当天本地正午
    func write(tokens: Int, day: Date, agent: String, scope: String = "turn") throws {
        let dir = sessions.appendingPathComponent("wd_test/session_\(agent)/agents/\(agent)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ms = Int(day.addingTimeInterval(12 * 3600).timeIntervalSince1970 * 1000)
        let line = """
        {"type":"usage.record","agentId":"\(agent)","model":"kimi-code/k3","usage":{"inputOther":\(tokens - 100),"output":100,"inputCacheRead":0,"inputCacheCreation":0},"usageScope":"\(scope)","time":\(ms)}
        """
        try line.write(to: dir.appendingPathComponent("wire.jsonl"), atomically: true, encoding: .utf8)
    }

    // 今日：main 1000 + 子 agent 500（子 agent 用量在各自 wire.jsonl 中，必须计入）
    try write(tokens: 1000, day: dayStart, agent: "main")
    try write(tokens: 500, day: dayStart, agent: "agent-1")
    // 8 天前：近30天含、近7天不含
    try write(tokens: 200, day: dayStart.addingTimeInterval(-8 * 86400), agent: "agent-2")
    // 40 天前：任何区间都不计入
    try write(tokens: 9000, day: dayStart.addingTimeInterval(-40 * 86400), agent: "agent-3")
    // session 级累计快照：必须排除，否则重复计数
    try write(tokens: 99999, day: dayStart, agent: "agent-4", scope: "session")

    let totals = KimiCodeLocalLogs.tokenTotals(sessionsRoot: sessions, now: now)
    #expect(totals.today == 1500)
    #expect(totals.last7 == 1500)
    #expect(totals.last30 == 1700)

    try FileManager.default.removeItem(at: root)
}

@Test func kimiCodeLocalLogsDailyTokens() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("kimi-daily-\(UUID().uuidString)")
    let sessions = root.appendingPathComponent("sessions")
    var cal = Calendar(identifier: .gregorian)
    cal.firstWeekday = 2
    let now = Date()
    let dayStart = cal.startOfDay(for: now)

    func write(tokens: Int, day: Date, agent: String) throws {
        let dir = sessions.appendingPathComponent("wd_t/s_\(agent)/agents/\(agent)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ms = Int(day.addingTimeInterval(12 * 3600).timeIntervalSince1970 * 1000)
        let line = """
        {"type":"usage.record","agentId":"\(agent)","model":"k","usage":{"inputOther":\(tokens),"output":0,"inputCacheRead":0,"inputCacheCreation":0},"usageScope":"turn","time":\(ms)}
        """
        try line.write(to: dir.appendingPathComponent("wire.jsonl"), atomically: true, encoding: .utf8)
    }

    try write(tokens: 1000, day: dayStart, agent: "main")
    try write(tokens: 500, day: dayStart.addingTimeInterval(-3 * 86400), agent: "agent-1")

    let daily = KimiCodeLocalLogs.dailyTokens(sessionsRoot: sessions, days: 7, now: now)
    #expect(daily.count == 7)
    #expect(daily.last?.tokens == 1000)
    #expect(daily[daily.count - 4].tokens == 500)
    #expect(daily.reduce(0) { $0 + $1.tokens } == 1500)

    try FileManager.default.removeItem(at: root)
}

@Test func kimiCodeLocalLogsHourlyTokens() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("kimi-hourly-\(UUID().uuidString)")
    let sessions = root.appendingPathComponent("sessions")
    let cal = Calendar(identifier: .gregorian)
    let now = Date()
    let dayStart = cal.startOfDay(for: now)
    let currentHour = cal.component(.hour, from: now)

    // 同一 agent 的多条记录必须写在同一个 wire.jsonl 里（append），不同 agent 各自一个文件
    func write(hours: [(tokens: Int, hour: Int)], agent: String) throws {
        let dir = sessions.appendingPathComponent("wd_h/s_\(agent)/agents/\(agent)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let text = hours.map { tokens, hour in
            let ms = Int(dayStart.addingTimeInterval(TimeInterval(hour * 3600 + 60)).timeIntervalSince1970 * 1000)
            return """
            {"type":"usage.record","agentId":"\(agent)","model":"k","usage":{"inputOther":\(tokens),"output":0,"inputCacheRead":0,"inputCacheCreation":0},"usageScope":"turn","time":\(ms)}
            """
        }.joined(separator: "\n")
        try text.write(to: dir.appendingPathComponent("wire.jsonl"), atomically: true, encoding: .utf8)
    }

    try write(hours: [(100, 0), (200, 1)], agent: "main")
    try write(hours: [(300, 1)], agent: "agent-1")

    let hourly = KimiCodeLocalLogs.hourlyTokens(sessionsRoot: sessions, now: now)
    #expect(hourly.count == currentHour + 1)          // 今天只到当前小时
    #expect(hourly[0].tokens == 100)
    #expect(hourly[1].tokens == 500)                   // 跨 agent 同小时合并
    #expect(hourly.allSatisfy { cal.component(.minute, from: $0.hour) == 0 })

    try FileManager.default.removeItem(at: root)
}

/// 模型维度：usage.record 自带 model 字段，按模型拆分且合计等于总量。
@Test func kimiCodeLocalLogsSplitsByModel() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("kimi-model-\(UUID().uuidString)")
    let sessions = root.appendingPathComponent("sessions")
    let dayStart = Calendar(identifier: .gregorian).startOfDay(for: Date())

    func write(tokens: Int, agent: String, model: String, day: Date) throws {
        let dir = sessions.appendingPathComponent("wd_test/session_\(agent)/agents/\(agent)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ms = Int(day.addingTimeInterval(12 * 3600).timeIntervalSince1970 * 1000)
        let line = """
        {"type":"usage.record","model":"\(model)","usage":{"inputOther":\(tokens - 100),"output":100,"inputCacheRead":0,"inputCacheCreation":0},"usageScope":"turn","time":\(ms)}
        """
        try line.write(to: dir.appendingPathComponent("wire.jsonl"), atomically: true, encoding: .utf8)
    }

    try write(tokens: 1000, agent: "main", model: "kimi-code/k3", day: dayStart)
    try write(tokens: 400, agent: "agent-1", model: "kimi-code/k2", day: dayStart)
    try write(tokens: 300, agent: "agent-2", model: "kimi-code/k3", day: dayStart.addingTimeInterval(-2 * 86400))

    let byModel = KimiCodeLocalLogs.dailyTokensByModel(sessionsRoot: sessions, days: 7, now: Date())
    let totals = Dictionary(uniqueKeysWithValues: byModel.map { ($0.model, $0.total) })
    #expect(totals["kimi-code/k3"] == 1300)
    #expect(totals["kimi-code/k2"] == 400)
    // 按合计降序
    #expect(byModel.map(\.model) == ["kimi-code/k3", "kimi-code/k2"])
    // 模型之和 = 总量
    let daily = KimiCodeLocalLogs.dailyTokens(sessionsRoot: sessions, days: 7, now: Date())
    #expect(daily.reduce(0) { $0 + $1.tokens } == byModel.reduce(0) { $0 + $1.total })

    try FileManager.default.removeItem(at: root)
}

/// 缺 model 字段时归入 unknownModel，总量不变。
@Test func kimiCodeLocalLogsFallsBackToUnknownModel() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("kimi-unknown-\(UUID().uuidString)")
    let sessions = root.appendingPathComponent("sessions")
    let dayStart = Calendar(identifier: .gregorian).startOfDay(for: Date())
    let dir = sessions.appendingPathComponent("wd_test/session_a/agents/main")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let ms = Int(dayStart.addingTimeInterval(12 * 3600).timeIntervalSince1970 * 1000)
    let line = """
    {"type":"usage.record","usage":{"inputOther":100,"output":100,"inputCacheRead":0,"inputCacheCreation":0},"usageScope":"turn","time":\(ms)}
    """
    try line.write(to: dir.appendingPathComponent("wire.jsonl"), atomically: true, encoding: .utf8)

    let byModel = KimiCodeLocalLogs.dailyTokensByModel(sessionsRoot: sessions, days: 7, now: Date())
    #expect(byModel.count == 1)
    #expect(byModel.first?.model == KimiCodeLocalLogs.unknownModel)
    #expect(byModel.first?.total == 200)
    #expect(KimiCodeLocalLogs.tokenTotals(sessionsRoot: sessions, now: Date()).today == 200)

    try FileManager.default.removeItem(at: root)
}
