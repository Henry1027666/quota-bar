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
            return snapshot(payload: payload, token: accessToken)
        }
        if let apiKey { return try await fetchAPIBalance(apiKey) }
        throw QuotaError.notAuthenticated("未检测到 Codex 登录")
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
        let credits = root["credits"] as? [String: Any]
        let balance = credits.flatMap { Support.firstNumber(in: $0, keys: ["balance", "remaining", "available"]) }
        let claims = Support.jwtClaims(token)
        let auth = claims?["https://api.openai.com/auth"] as? [String: Any]
        let profile = claims?["https://api.openai.com/profile"] as? [String: Any]
        return ProviderSnapshot(
            kind: kind,
            plan: Support.firstString(in: root, keys: ["plan_type", "planName", "plan"]) ?? Support.string(auth?["chatgpt_plan_type"]),
            account: Support.string(profile?["email"] ?? claims?["email"]),
            windows: windows,
            balances: balance.map { [MoneyBalance(label: "加油包", amount: $0, currency: "credits")] } ?? [],
            tokenUsage: nil,
            requestCount: nil,
            updatedAt: Date(),
            message: windows.isEmpty && balance == nil ? "服务未返回可展示额度" : nil
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

struct CursorProvider: QuotaProvider {
    let kind = ProviderKind.cursor

    func fetch() async throws -> ProviderSnapshot {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/Library/Application Support/Cursor/User/globalStorage/state.vscdb",
            "\(home)/Library/Application Support/Cursor - Insiders/User/globalStorage/state.vscdb",
            "\(home)/Library/Application Support/Cursor Nightly/User/globalStorage/state.vscdb"
        ]
        guard let database = candidates.first(where: FileManager.default.fileExists(atPath:)) else {
            throw QuotaError.notAuthenticated("未检测到 Cursor")
        }
        let keys = "'cursorAuth/accessToken','cursorAuth/cachedEmail','cursorAuth/stripeMembershipType'"
        let query = "SELECT key, value FROM ItemTable WHERE key IN (\(keys));"
        let output = try Support.run("/usr/bin/sqlite3", ["-readonly", "-batch", "-noheader", "-separator", "\t", database, query])
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let raw = String(parts[1])
            let decoded = (try? JSONDecoder().decode(String.self, from: Data(raw.utf8))) ?? raw
            values[String(parts[0])] = decoded
        }
        guard let token = values["cursorAuth/accessToken"], !token.isEmpty else {
            throw QuotaError.notAuthenticated("Cursor 尚未登录")
        }

        async let summary = try? Support.jsonRequest(
            URL(string: "https://cursor.com/api/usage-summary")!,
            headers: ["Cookie": "WorkosCursorSessionToken=\(sessionToken(token))"]
        )
        async let current = try? Support.jsonRequest(
            URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!,
            method: "POST", bearer: token,
            headers: ["Connect-Protocol-Version": "1"], body: Data("{}".utf8)
        )
        let payloads = await [summary, current].compactMap { $0 }
        var windows = payloads.flatMap { Support.parseGenericWindows($0) }
        var seen = Set<String>()
        windows = windows.filter { seen.insert("\($0.title)-\($0.limit)-\($0.used)").inserted }
        let root = payloads.first as? [String: Any]
        let account = values["cursorAuth/cachedEmail"] ?? root.flatMap { Support.firstString(in: $0, keys: ["email"]) }
        let requests = payloads.lazy.compactMap(extractRequestCount).first
        let tokens = payloads.lazy.compactMap(extractTokenCount).first
        return ProviderSnapshot(
            kind: kind,
            plan: values["cursorAuth/stripeMembershipType"] ?? root.flatMap { Support.firstString(in: $0, keys: ["membershipType", "planName"]) },
            account: account,
            windows: windows,
            balances: [],
            tokenUsage: tokens,
            requestCount: requests,
            updatedAt: Date(),
            message: payloads.isEmpty ? "已登录，暂时无法读取额度" : nil
        )
    }

    private func sessionToken(_ token: String) -> String {
        if token.contains("%3A%3A") { return token }
        return token.replacingOccurrences(of: "::", with: "%3A%3A")
    }

    private func extractRequestCount(_ payload: Any) -> Int? {
        recursiveNumber(payload, keys: ["numRequests", "num_requests", "totalRequests", "requestCount"]).map(Int.init)
    }

    private func extractTokenCount(_ payload: Any) -> Int? {
        recursiveNumber(payload, keys: ["totalTokens", "total_tokens", "tokenUsage", "tokens"]).map(Int.init)
    }

    private func recursiveNumber(_ value: Any, keys: Set<String>) -> Double? {
        if let dictionary = value as? [String: Any] {
            for key in keys { if let number = Support.number(dictionary[key]) { return number } }
            for child in dictionary.values { if let number = recursiveNumber(child, keys: keys) { return number } }
        } else if let array = value as? [Any] {
            for child in array { if let number = recursiveNumber(child, keys: keys) { return number } }
        }
        return nil
    }
}
