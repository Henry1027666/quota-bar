import Foundation
import Testing
@testable import QuotaBar

@Test func parsesQuotaWindowsAndDates() throws {
    let payload: [String: Any] = [
        "limits": [
            ["name": "five_hour", "used": 24, "limit": 100, "reset_at": "2026-09-04T12:00:00Z"],
            ["name": "weekly", "percent": 51, "resets_at": "2026-09-08T12:00:00Z"]
        ]
    ]
    let windows = Support.parseGenericWindows(payload)
    #expect(windows.contains { $0.title == "5 小时" && $0.used == 24 })
    #expect(windows.contains { $0.title == "周限额" && $0.used == 51 })
}

@Test func parsesMillisecondsTimestamp() {
    let date = Support.date(1_788_528_000_000 as Double)
    #expect(date != nil)
    #expect(date!.timeIntervalSince1970 == 1_788_528_000)
}

@Test func kimiShowsWeeklyQuotaAlongsideFiveHourWindow() {
    // 实测接口结构：顶层 usage 是周限额，limits 数组是 5 小时窗口，两者应同时显示。
    let body: [String: Any] = [
        "usage": ["limit": 100, "used": 98, "resetTime": "2026-09-08T05:51:13Z"],
        "limits": [
            [
                "window": ["duration": 300, "timeUnit": "TIME_UNIT_MINUTE"],
                "detail": ["limit": 100, "used": 50, "resetTime": "2026-09-04T12:51:13Z"]
            ]
        ]
    ]
    let windows = KimiProvider.parseKimiWindows(body)
    #expect(windows.contains { $0.title == "周限额" && $0.used == 98 && $0.limit == 100 })
    #expect(windows.contains { $0.title == "5 小时" && $0.used == 50 && $0.limit == 100 })
    #expect(windows.count == 2)
}

@Test func kimiParsesBoosterWalletBalance() {
    // 实测 boosterWallet.balance 结构：amount/amountLeft 以 1e-8 元为单位（UNIT_CURRENCY）。
    let body: [String: Any] = [
        "boosterWallet": [
            "balance": ["amount": 20_000_000_000, "amountLeft": 5_149_500_900, "unit": "UNIT_CURRENCY"],
            "topupLimit": ["currency": "CNY"]
        ]
    ]
    let balances = KimiProvider.parseBalances(body)
    #expect(balances.count == 1)
    #expect(balances.first?.label == "加油包")
    #expect(balances.first?.currency == "CNY")
    #expect(balances.first?.amount == 51.495009)
}

@Test func planTierOrdersTokenPlanApiFree() {
    func snapshot(plan: String?, windows: [QuotaWindow] = [], balances: [MoneyBalance] = []) -> ProviderSnapshot {
        ProviderSnapshot(
            kind: .kimi, plan: plan, account: nil, windows: windows, balances: balances,
            tokenUsage: nil, requestCount: nil, updatedAt: Date(), message: nil
        )
    }
    let window = QuotaWindow(title: "周限额", used: 50, limit: 100, resetAt: nil)
    #expect(snapshot(plan: "Token Plan", windows: [window]).planTier == .tokenPlan)
    #expect(snapshot(plan: "API").planTier == .api)
    #expect(snapshot(plan: "Free").planTier == .free)
    #expect(snapshot(plan: nil, windows: [window]).planTier == .tokenPlan)
    #expect(snapshot(plan: nil).planTier == .free)
    // 三档排序关系：tokenPlan < api < free
    #expect(PlanTier.tokenPlan < PlanTier.api)
    #expect(PlanTier.api < PlanTier.free)
}
