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
