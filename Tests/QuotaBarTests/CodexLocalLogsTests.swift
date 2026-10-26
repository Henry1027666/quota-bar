import Foundation
import Testing
@testable import QuotaBar

@Test func codexLocalLogsTotalsByDay() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-test-\(UUID().uuidString)")
    let sessions = root.appendingPathComponent("sessions")
    let cal = Calendar(identifier: .gregorian)
    let now = Date()
    let dayStart = cal.startOfDay(for: now)

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

    try write(tokens: 1000, day: dayStart, name: "a.jsonl")                        // 今天
    try write(tokens: 500, day: dayStart.addingTimeInterval(-8 * 86400), name: "b.jsonl")   // 8 天前：近30天含、近7天不含
    try write(tokens: 9000, day: dayStart.addingTimeInterval(-40 * 86400), name: "c.jsonl") // 40 天前：都不含

    let totals = CodexLocalLogs.tokenTotals(sessionsRoot: sessions, now: now)
    #expect(totals.today == 1000)
    #expect(totals.last7 == 1000)
    #expect(totals.last30 == 1500)

    try FileManager.default.removeItem(at: root)
}

@Test func codexLocalLogsDailyTokens() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-daily-\(UUID().uuidString)")
    let sessions = root.appendingPathComponent("sessions")
    var cal = Calendar(identifier: .gregorian)
    cal.firstWeekday = 2
    let now = Date()
    let dayStart = cal.startOfDay(for: now)

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
    try write(tokens: 500, day: dayStart.addingTimeInterval(-3 * 86400), name: "b.jsonl")
    // 7 天窗口之外：不计入
    try write(tokens: 9999, day: dayStart.addingTimeInterval(-10 * 86400), name: "c.jsonl")

    let daily = CodexLocalLogs.dailyTokens(sessionsRoot: sessions, days: 7, now: now)
    #expect(daily.count == 7)
    #expect(daily.last?.tokens == 1000)                       // 末位是今天
    #expect(daily[daily.count - 4].tokens == 500)             // 3 天前
    #expect(daily.reduce(0) { $0 + $1.tokens } == 1500)       // 窗口外的 9999 不计入
    #expect(daily.allSatisfy { cal.startOfDay(for: $0.day) == $0.day })

    try FileManager.default.removeItem(at: root)
}

/// 模型维度：token_count 自身不带模型名，须由前文的 turn_context 归属。
@Test func codexLocalLogsAttributesTokensToModel() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-model-\(UUID().uuidString)")
    let sessions = root.appendingPathComponent("sessions")
    let cal = Calendar(identifier: .gregorian)
    let now = Date()
    let dayStart = cal.startOfDay(for: now)
    let comps = cal.dateComponents([.year, .month, .day], from: dayStart)
    let dir = sessions.appendingPathComponent(
        String(format: "%04d/%02d/%02d", comps.year!, comps.month!, comps.day!))
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let iso = ISO8601DateFormatter().string(from: dayStart.addingTimeInterval(12 * 3600))

    // 一轮一个模型：turn_context 切换后，后续 token_count 归属新模型
    let lines = [
        #"{"timestamp":"\#(iso)","type":"turn_context","payload":{"model":"gpt-a"}}"#,
        #"{"timestamp":"\#(iso)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":100}}}}"#,
        #"{"timestamp":"\#(iso)","type":"turn_context","payload":{"model":"gpt-b"}}"#,
        #"{"timestamp":"\#(iso)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":250}}}}"#,
        #"{"timestamp":"\#(iso)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":50}}}}"#
    ]
    try lines.joined(separator: "\n").write(
        to: dir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)

    let byModel = CodexLocalLogs.dailyTokensByModel(sessionsRoot: sessions, days: 7, now: now)
    let totals = Dictionary(uniqueKeysWithValues: byModel.map { ($0.model, $0.total) })
    #expect(totals["gpt-a"] == 100)
    // 第二、三条都归属 gpt-b（切换后持续生效）
    #expect(totals["gpt-b"] == 300)
    // 模型之和 = 总量
    let daily = CodexLocalLogs.dailyTokens(sessionsRoot: sessions, days: 7, now: now)
    #expect(daily.reduce(0) { $0 + $1.tokens } == 400)
    #expect(byModel.reduce(0) { $0 + $1.total } == 400)
    // 按合计降序
    #expect(byModel.map(\.model) == ["gpt-b", "gpt-a"])

    try FileManager.default.removeItem(at: root)
}

/// turn_context 缺失时归入 unknownModel，但总量口径不受影响。
@Test func codexLocalLogsFallsBackToUnknownModel() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-unknown-\(UUID().uuidString)")
    let sessions = root.appendingPathComponent("sessions")
    let cal = Calendar(identifier: .gregorian)
    let now = Date()
    let dayStart = cal.startOfDay(for: now)
    let comps = cal.dateComponents([.year, .month, .day], from: dayStart)
    let dir = sessions.appendingPathComponent(
        String(format: "%04d/%02d/%02d", comps.year!, comps.month!, comps.day!))
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let iso = ISO8601DateFormatter().string(from: dayStart.addingTimeInterval(12 * 3600))
    let line = #"{"timestamp":"\#(iso)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":777}}}}"#
    try line.write(to: dir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)

    let byModel = CodexLocalLogs.dailyTokensByModel(sessionsRoot: sessions, days: 7, now: now)
    #expect(byModel.count == 1)
    #expect(byModel.first?.model == CodexLocalLogs.unknownModel)
    #expect(byModel.first?.total == 777)
    // 总量不变
    #expect(CodexLocalLogs.tokenTotals(sessionsRoot: sessions, now: now).today == 777)

    try FileManager.default.removeItem(at: root)
}

/// 逐小时序列同样按模型归属。
@Test func codexLocalLogsHourlyByModel() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-hourly-model-\(UUID().uuidString)")
    let sessions = root.appendingPathComponent("sessions")
    let cal = Calendar(identifier: .gregorian)
    let now = Date()
    let dayStart = cal.startOfDay(for: now)
    let comps = cal.dateComponents([.year, .month, .day], from: dayStart)
    let dir = sessions.appendingPathComponent(
        String(format: "%04d/%02d/%02d", comps.year!, comps.month!, comps.day!))
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let iso = ISO8601DateFormatter().string(from: dayStart.addingTimeInterval(3600))
    let lines = [
        #"{"timestamp":"\#(iso)","type":"turn_context","payload":{"model":"gpt-a"}}"#,
        #"{"timestamp":"\#(iso)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":123}}}}"#
    ]
    try lines.joined(separator: "\n").write(
        to: dir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)

    let byModel = CodexLocalLogs.hourlyTokensByModel(sessionsRoot: sessions, on: now, now: now)
    #expect(byModel.count == 1)
    #expect(byModel.first?.model == "gpt-a")
    #expect(byModel.first?.total == 123)
    // 与逐小时总量一致
    #expect(CodexLocalLogs.hourlyTokens(sessionsRoot: sessions, on: now, now: now)
        .reduce(0) { $0 + $1.tokens } == 123)

    try FileManager.default.removeItem(at: root)
}

/// 本机有 zstd 命令行时才运行（仅用于生成压缩 fixture；应用侧用内置解压器，不依赖 CLI）。
private func zstdAvailable() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["zstd", "--version"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
}

private func zstdCompress(_ url: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["zstd", "-q", "-f", url.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "zstd", code: Int(process.terminationStatus))
    }
}

/// 旧会话被 Codex 压缩为 .jsonl.zst（约一周前的日志）：须照常统计。
@Test func codexLocalLogsReadsZstdCompressedLogs() throws {
    guard zstdAvailable() else { return }
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-zst-\(UUID().uuidString)")
    let sessions = root.appendingPathComponent("sessions")
    let cal = Calendar(identifier: .gregorian)
    let now = Date()
    let dayStart = cal.startOfDay(for: now)
    let comps = cal.dateComponents([.year, .month, .day], from: dayStart)
    let dir = sessions.appendingPathComponent(
        String(format: "%04d/%02d/%02d", comps.year!, comps.month!, comps.day!))
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let iso = ISO8601DateFormatter().string(from: dayStart.addingTimeInterval(12 * 3600))
    let line = #"{"timestamp":"\#(iso)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":456}}}}"#
    let plain = dir.appendingPathComponent("a.jsonl")
    try line.write(to: plain, atomically: true, encoding: .utf8)
    try zstdCompress(plain)
    try FileManager.default.removeItem(at: plain)

    let totals = CodexLocalLogs.tokenTotals(sessionsRoot: sessions, now: now)
    #expect(totals.today == 456)

    try FileManager.default.removeItem(at: root)
}

/// 归档目录 archived_sessions（扁平、日期在文件名里）与主目录同basename 去重。
@Test func codexLocalLogsReadsArchivedSessions() throws {
    guard zstdAvailable() else { return }
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-archived-\(UUID().uuidString)")
    let sessions = root.appendingPathComponent("sessions")
    let archived = root.appendingPathComponent("archived_sessions")
    try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
    let cal = Calendar(identifier: .gregorian)
    let now = Date()
    let dayStart = cal.startOfDay(for: now)

    func tokenLine(_ tokens: Int, _ iso: String) -> String {
        #"{"timestamp":"\#(iso)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":\#(tokens)}}}}"#
    }

    // 3 天前的会话：只存在于归档目录（压缩态），按文件名日期计入近 7 天
    let past = dayStart.addingTimeInterval(-3 * 86400).addingTimeInterval(12 * 3600)
    let pastComps = cal.dateComponents([.year, .month, .day], from: past)
    let archivedName = String(format: "rollout-%04d-%02d-%02dT12-00-00-aaaa.jsonl.zst",
                              pastComps.year!, pastComps.month!, pastComps.day!)
    let archivedPlain = archived.appendingPathComponent(String(archivedName.dropLast(4)))
    try tokenLine(300, ISO8601DateFormatter().string(from: past)).write(
        to: archivedPlain, atomically: true, encoding: .utf8)
    try zstdCompress(archivedPlain)
    try FileManager.default.removeItem(at: archivedPlain)

    // 今天的会话：主目录为压缩态，且与归档目录同 basename（模拟重复归档），只计一次
    let todayComps = cal.dateComponents([.year, .month, .day], from: dayStart)
    let dir = sessions.appendingPathComponent(
        String(format: "%04d/%02d/%02d", todayComps.year!, todayComps.month!, todayComps.day!))
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let dupName = String(format: "rollout-%04d-%02d-%02dT09-00-00-bbbb.jsonl.zst",
                         todayComps.year!, todayComps.month!, todayComps.day!)
    for base in [archived.appendingPathComponent(dupName), dir.appendingPathComponent(dupName)] {
        let plainURL = base.deletingPathExtension() // 去掉 .zst，先写纯文本
        try tokenLine(100, ISO8601DateFormatter().string(from: dayStart.addingTimeInterval(9 * 3600))).write(
            to: plainURL, atomically: true, encoding: .utf8)
        try zstdCompress(plainURL)
        try FileManager.default.removeItem(at: plainURL)
    }

    let totals = CodexLocalLogs.tokenTotals(sessionsRoot: sessions, now: now)
    #expect(totals.today == 100)        // 重复 basename 只计一次
    #expect(totals.last7 == 400)        // 300（归档）+ 100（今天）

    try FileManager.default.removeItem(at: root)
}
