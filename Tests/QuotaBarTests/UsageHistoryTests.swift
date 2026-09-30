import Foundation
import Testing
@testable import QuotaBar

@MainActor
private func makeHistory() -> (UsageHistory, URL) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("quota-bar-test-\(UUID().uuidString).json")
    return (UsageHistory(fileURL: url), url)
}

@MainActor
private func snapshot(
    windows: [QuotaWindow] = [], balances: [MoneyBalance] = []
) -> ProviderSnapshot {
    ProviderSnapshot(
        kind: .kimi, plan: "pro", account: nil, windows: windows, balances: balances,
        tokenUsage: nil, requestCount: nil, updatedAt: Date(), message: nil
    )
}

@MainActor
@Test func historyRecordsWindowsAndBalances() {
    let (history, _) = makeHistory()
    let snap = snapshot(
        windows: [QuotaWindow(title: "周限额", used: 50, limit: 100, resetAt: nil)],
        balances: [MoneyBalance(label: "加油包", amount: 51.5, currency: "CNY")]
    )
    history.record(snap)
    #expect(history.displayKey(for: snap) == "window:周限额")
    let points = history.points(kind: .kimi, key: "window:周限额")
    #expect(points.count == 1)
    #expect(points.first?.value == 0.5)
    let balance = history.points(kind: .kimi, key: "balance:加油包(CNY)")
    #expect(balance.first?.value == 51.5)
}

@MainActor
@Test func historySkipsDenseAndUnchangedPoints() {
    let (history, _) = makeHistory()
    let snap = snapshot(windows: [QuotaWindow(title: "周限额", used: 50, limit: 100, resetAt: nil)])
    let t0 = Date()
    history.record(snap, at: t0)
    // 60 秒内重复采样：跳过
    history.record(snapshot(windows: [QuotaWindow(title: "周限额", used: 60, limit: 100, resetAt: nil)]),
                   at: t0.addingTimeInterval(30))
    #expect(history.points(kind: .kimi, key: "window:周限额", now: t0).count == 1)
    // 30 分钟内数值未变：跳过
    history.record(snap, at: t0.addingTimeInterval(600))
    #expect(history.points(kind: .kimi, key: "window:周限额", now: t0).count == 1)
    // 数值变化则记录
    history.record(snapshot(windows: [QuotaWindow(title: "周限额", used: 70, limit: 100, resetAt: nil)]),
                   at: t0.addingTimeInterval(600))
    #expect(history.points(kind: .kimi, key: "window:周限额", now: t0).count == 2)
}

@MainActor
@Test func historyPrunesBeyondDisplayWindowAndPersists() throws {
    let (history, url) = makeHistory()
    let now = Date()
    let snap = snapshot(windows: [QuotaWindow(title: "周限额", used: 50, limit: 100, resetAt: nil)])
    history.record(snap, at: now.addingTimeInterval(-20 * 86400)) // 超出 14 天保留期
    history.record(snap, at: now.addingTimeInterval(-8 * 86400))  // 在保留期内、7 天展示窗口外
    history.record(snap, at: now)                                  // 展示窗口内
    #expect(history.points(kind: .kimi, key: "window:周限额", now: now).count == 1)

    // 持久化：新实例从同一文件读回
    let reloaded = UsageHistory(fileURL: url)
    #expect(reloaded.points(kind: .kimi, key: "window:周限额", now: now).count == 1)
    try FileManager.default.removeItem(at: url)
}

@MainActor
@Test func historyDisplayKeyFallsBackToBalance() {
    let (_, _) = makeHistory()
    let balanceOnly = snapshot(balances: [MoneyBalance(label: "API 余额", amount: 20.5, currency: "CNY")])
    let history = UsageHistory(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("quota-bar-test-\(UUID().uuidString).json"))
    #expect(history.displayKey(for: balanceOnly) == "balance:API 余额(CNY)")
}

@MainActor
@Test func historyDeltaComputesCounterIncrease() {
    let (history, _) = makeHistory()
    // 固定时钟，避免测试恰好在凌晨运行时采样点顺序错乱
    let dayStart = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_780_000_000))
    let now = dayStart.addingTimeInterval(12 * 3600) // 当天中午
    func snap(_ tokens: Int) -> ProviderSnapshot {
        ProviderSnapshot(
            kind: .kimi, plan: nil, account: nil, windows: [], balances: [],
            tokenUsage: tokens, requestCount: nil, updatedAt: now, message: nil
        )
    }
    // 计数器采样：昨天 1000 → 今天凌晨 1500 → 现在 2600
    history.record(snap(1000), at: dayStart.addingTimeInterval(-86400))
    history.record(snap(1500), at: dayStart.addingTimeInterval(3600))
    history.record(snap(2600), at: now)
    // 今日增量 = 最新值 − 起点（0 点）前的最近采样 = 2600 − 1000
    #expect(history.delta(kind: .kimi, key: "tokens", since: dayStart, now: now) == 1600)
}

@MainActor
@Test func historyDeltaClampsCounterResetAndNeedsTwoPoints() {
    let (history, _) = makeHistory()
    let dayStart = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_780_000_000))
    let now = dayStart.addingTimeInterval(12 * 3600)
    func snap(_ tokens: Int) -> ProviderSnapshot {
        ProviderSnapshot(
            kind: .kimi, plan: nil, account: nil, windows: [], balances: [],
            tokenUsage: tokens, requestCount: nil, updatedAt: now, message: nil
        )
    }
    // 只有一个采样点 → nil
    history.record(snap(500), at: now)
    #expect(history.delta(kind: .kimi, key: "tokens", since: dayStart, now: now) == nil)
    // 计数器中途重置（厂商换了计费周期）→ 负增量钳制为 0
    history.record(snap(100), at: now.addingTimeInterval(600))
    #expect(history.delta(kind: .kimi, key: "tokens", since: dayStart, now: now) == 0)
}
