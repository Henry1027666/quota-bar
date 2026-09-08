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

@Test func deepSeekParsesByApiKeyUsage() {
    // DeepSeek 用量页改版后的 by_api_key 接口结构（实测）：
    // summary → 充值余额/累计消费；amount → series[].buckets[].usage 逐日求和；
    // cost → data[].series[].buckets[].cost 逐日求和。
    let summary: [String: Any] = [
        "code": 0, "data": ["biz_code": 0, "biz_data": [
            "bonus_wallets": [["balance": "0", "currency": "USD"]],
            "normal_wallets": [["balance": "0E-16", "currency": "USD"],
                               ["balance": "20.5045226600000000", "currency": "CNY"]],
            "total_costs": [["amount": "0", "currency": "USD"],
                            ["amount": "519.4954773400000000", "currency": "CNY"]]
        ]]
    ]
    let amount: [String: Any] = [
        "code": 0, "data": ["biz_code": 0, "biz_data": [
            "bucket": 86400,
            "series": [[
                "api_key": ["name": "qingyao-copilot"],
                "buckets": [
                    ["time": 1786204800, "usage": ["PROMPT_CACHE_HIT_TOKEN": 100, "PROMPT_CACHE_MISS_TOKEN": 200, "REQUEST": 5, "RESPONSE_TOKEN": 300]],
                    ["time": 1786291200, "usage": ["PROMPT_CACHE_HIT_TOKEN": 0, "PROMPT_CACHE_MISS_TOKEN": 50, "REQUEST": 2, "RESPONSE_TOKEN": 100]]
                ]
            ]]
        ]]
    ]
    let cost: [String: Any] = [
        "code": 0, "data": ["biz_code": 0, "biz_data": [
            "data": [["currency": "CNY", "series": [[
                "api_key": ["name": "qingyao-copilot"],
                "buckets": [
                    ["cost": "1.5", "time": 1786204800],
                    ["cost": "2.25", "time": 1786291200],
                    ["cost": "0.75", "time": todayStartUTC]
                ]
            ]]]]
        ]]
    ]
    let payload: [String: Any] = [
        "/api/v0/users/get_user_summary": summary,
        "/api/v0/usage/by_api_key/amount": amount,
        "/api/v0/usage/by_api_key/cost": cost,
    ]
    let web = DeepSeekProvider.parseWebPayload(payload)
    #expect(web != nil)
    #expect(web?.requestCount == 7)
    #expect(web?.tokenUsage == 750)
    #expect(web?.balances.contains { $0.label == "累计消费" && abs($0.amount - 519.49) < 0.01 } == true)
    #expect(web?.balances.contains { $0.label == "今日消费" && abs($0.amount - 0.75) < 0.01 } == true)
    #expect(web?.balances.contains { $0.label == "近30天消费" && abs($0.amount - 4.50) < 0.01 } == true)
    // 充值余额与官方 API 余额重复，不重复展示；零值赠送余额也不显示
    #expect(web?.balances.contains { $0.label == "充值余额" } == false)
    #expect(web?.balances.contains { $0.label == "赠送余额" } == false)
}

/// 东八区「今天 00:00」的 epoch（与 DeepSeek 用量接口 tz=28800 口径一致）。
private var todayStartUTC: TimeInterval {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
    let start = cal.startOfDay(for: Date())
    return start.timeIntervalSince1970
}

@Test func kimiParsesFiveHourWindowWhenQuotaExhausted() {
    // 额度用满时接口只返回 remaining 不返回 used：5 小时窗口仍应显示，used 由 limit-remaining 推算。
    let body: [String: Any] = [
        "usage": ["limit": 100, "used": 100, "resetTime": "2026-09-08T05:51:13Z"],
        "limits": [
            [
                "window": ["duration": 300, "timeUnit": "TIME_UNIT_MINUTE"],
                "detail": ["limit": 100, "remaining": 100, "resetTime": "2026-09-07T05:51:13Z"]
            ]
        ]
    ]
    let windows = KimiProvider.parseKimiWindows(body)
    #expect(windows.contains { $0.title == "周限额" && $0.used == 100 && $0.limit == 100 })
    #expect(windows.contains { $0.title == "5 小时" && $0.used == 0 && $0.limit == 100 })
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
