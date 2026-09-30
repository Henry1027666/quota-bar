import Foundation
import Testing
@testable import QuotaBar

@Test func codexLocalLogsTotalsByDay() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-test-\(UUID().uuidString)")
    let sessions = root.appendingPathComponent("sessions")
    var cal = Calendar(identifier: .gregorian)
    cal.firstWeekday = 2
    let now = Date()
    let dayStart = cal.startOfDay(for: now)
    let weekStart = cal.dateInterval(of: .weekOfYear, for: now)!.start
    let monthStart = cal.dateInterval(of: .month, for: now)!.start

    // 按 sessions/YYYY/MM/DD/rollout.jsonl 结构写 fixture，事件时间戳取当天本地正午
    func write(tokens: Int, day: Date, name: String) throws {
        let comps = cal.dateComponents([.year, .month, .day], from: day)
        let dir = sessions.appendingPathComponent(
            String(format: "%04d/%02d/%02d", comps.year!, comps.month!, comps.day!))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter().string(from: day.addingTimeInterval(12 * 3600))
        let line = """
        {"timestamp":"\(iso)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":\(tokens)}}}}
        """
        try line.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    try write(tokens: 1000, day: dayStart, name: "a.jsonl")
    try write(tokens: 500, day: dayStart.addingTimeInterval(-86400), name: "b.jsonl")
    try write(tokens: 9000, day: monthStart.addingTimeInterval(-86400), name: "c.jsonl")

    let totals = CodexLocalLogs.tokenTotals(sessionsRoot: sessions, now: now)
    #expect(totals.today == 1000)
    let yesterdayInWeek = dayStart.addingTimeInterval(-86400) >= weekStart
    let yesterdayInMonth = dayStart.addingTimeInterval(-86400) >= monthStart
    #expect(totals.week == (yesterdayInWeek ? 1500 : 1000))
    #expect(totals.month == (yesterdayInMonth ? 1500 : 1000))

    try FileManager.default.removeItem(at: root)
}
