import Foundation

struct CodexProvider: QuotaProvider {
    let kind = ProviderKind.codex

    func fetch() async throws -> ProviderSnapshot {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap(Support.string)
            .map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let auth = try Support.dictionary(at: home.appendingPathComponent("auth.json"))
        let tokens = auth["tokens"] as? [String: Any]
        let accessToken = Support.string(tokens?["access_token"] ?? auth["access_token"])
        let apiKey = Support.string(auth["OPENAI_API_KEY"] ?? auth["openai_api_key"])

        var result: ProviderSnapshot
        if let accessToken {
            var headers: [String: String] = ["User-Agent": "codex-cli"]
            if let accountID = Support.string(tokens?["account_id"] ?? auth["account_id"]) {
                headers["ChatGPT-Account-Id"] = accountID
            }
            let payload = try await Support.jsonRequest(
                URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
                bearer: accessToken,
                headers: headers
            )
            result = snapshot(payload: payload, token: accessToken)
        } else if let apiKey {
            result = try await fetchAPIBalance(apiKey)
        } else {
            throw QuotaError.notAuthenticated("未检测到 Codex 登录")
        }

        // Codex 接口不返回 token 计数：改从本地会话日志精确统计（今日/近7天/近30天 + 近 7 天逐日）。
        // tokenUsage 展示今日值；tokenBreakdown 供顶部三栏统计，dailyTokens 供综合趋势图使用。
        let sessions = home.appendingPathComponent("sessions")
        let totals = CodexLocalLogs.tokenTotals(sessionsRoot: sessions)
        let daily = CodexLocalLogs.dailyTokens(sessionsRoot: sessions, days: 7)
        if totals.last30 > 0 || daily.contains(where: { $0.tokens > 0 }) {
            result.tokenUsage = totals.today
            result.tokenBreakdown = TokenBreakdown(today: totals.today, last7: totals.last7, last30: totals.last30)
            result.dailyTokens = daily
        }
        return result
    }

    private func snapshot(payload: Any, token: String) -> ProviderSnapshot {
        let root = payload as? [String: Any] ?? [:]
        let rate = (root["rate_limit"] as? [String: Any]) ?? (root["rateLimit"] as? [String: Any]) ?? [:]
        var windows: [QuotaWindow] = []
        for (key, title) in [("primary_window", "5 小时"), ("secondary_window", "周限额")] {
            guard let row = rate[key] as? [String: Any] else { continue }
            let usedPercent = Support.firstNumber(in: row, keys: ["used_percent", "usedPercent", "percent", "utilization"]) ?? 0
            let resetAt = Support.date(Support.firstValue(in: row, keys: ["reset_at", "resetAt", "resets_at", "resetsAt"]))
            windows.append(QuotaWindow(title: title, used: usedPercent, limit: 100, resetAt: resetAt))
        }
        if let extras = root["additional_rate_limits"] {
            windows += Support.parseGenericWindows(extras, preferredLabels: ["week": "周限额", "five": "5 小时"])
        }
        let claims = Support.jwtClaims(token)
        let auth = claims?["https://api.openai.com/auth"] as? [String: Any]
        let profile = claims?["https://api.openai.com/profile"] as? [String: Any]
        return ProviderSnapshot(
            kind: kind,
            plan: Support.firstString(in: root, keys: ["plan_type", "planName", "plan"]) ?? Support.string(auth?["chatgpt_plan_type"]),
            account: Support.string(profile?["email"] ?? claims?["email"]),
            windows: windows,
            balances: [],
            tokenUsage: nil,
            requestCount: nil,
            updatedAt: Date(),
            message: windows.isEmpty ? "服务未返回可展示额度" : nil
        )
    }

    private func fetchAPIBalance(_ apiKey: String) async throws -> ProviderSnapshot {
        let payload = try await Support.jsonRequest(
            URL(string: "https://api.openai.com/v1/dashboard/billing/credit_grants")!, bearer: apiKey
        )
        let root = payload as? [String: Any] ?? [:]
        let total = Support.firstNumber(in: root, keys: ["total_available", "total_granted"]) ?? 0
        let used = Support.firstNumber(in: root, keys: ["total_used"]) ?? 0
        return ProviderSnapshot(
            kind: kind, plan: "API", account: nil, windows: [],
            balances: [MoneyBalance(label: "余额", amount: max(total - used, 0), currency: "USD")],
            tokenUsage: nil, requestCount: nil, updatedAt: Date(), message: nil
        )
    }
}
