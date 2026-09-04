import Foundation

struct ClaudeProvider: QuotaProvider {
    let kind = ProviderKind.claude

    func fetch() async throws -> ProviderSnapshot {
        guard let raw = try? Support.run(
            "/usr/bin/security",
            ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        ) else {
            throw QuotaError.notAuthenticated("Claude Code 尚未登录")
        }
        guard let data = raw.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = Support.string(oauth["accessToken"] ?? oauth["access_token"]) else {
            throw QuotaError.notAuthenticated("Claude Code 尚未登录")
        }
        let payload = try await Support.jsonRequest(
            URL(string: "https://api.anthropic.com/api/oauth/usage")!,
            bearer: token,
            headers: ["anthropic-beta": "oauth-2025-04-20", "User-Agent": "claude-code"]
        )
        let dictionary = payload as? [String: Any] ?? [:]
        var windows: [QuotaWindow] = []
        let legacy: [(String, String)] = [("five_hour", "5 小时"), ("seven_day", "周限额")]
        for (key, title) in legacy {
            guard let row = dictionary[key] as? [String: Any] else { continue }
            let percent = Support.firstNumber(in: row, keys: ["utilization", "percent", "used_percent"]) ?? 0
            let reset = Support.date(Support.firstValue(in: row, keys: ["resets_at", "reset_at"]))
            windows.append(QuotaWindow(title: title, used: percent, limit: 100, resetAt: reset))
        }
        if let limits = dictionary["limits"] as? [[String: Any]] {
            for row in limits {
                guard let percent = Support.firstNumber(in: row, keys: ["percent", "utilization"]) else { continue }
                let group = Support.firstString(in: row, keys: ["group", "kind"])?.lowercased() ?? ""
                let title = group.contains("session") ? "5 小时" : "周限额"
                let reset = Support.date(Support.firstValue(in: row, keys: ["resets_at", "reset_at"]))
                if !windows.contains(where: { $0.title == title && $0.resetAt == reset }) {
                    windows.append(QuotaWindow(title: title, used: percent, limit: 100, resetAt: reset))
                }
            }
        }
        let claims = Support.jwtClaims(token)
        return ProviderSnapshot(
            kind: kind,
            plan: Support.string(root["subscriptionType"] ?? root["rateLimitTier"]),
            account: Support.string(claims?["email"]),
            windows: windows,
            balances: [],
            tokenUsage: nil,
            requestCount: nil,
            updatedAt: Date(),
            message: windows.isEmpty ? "服务未返回额度窗口" : nil
        )
    }
}

struct KimiProvider: QuotaProvider {
    let kind = ProviderKind.kimi

    func fetch() async throws -> ProviderSnapshot {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".kimi-code/credentials/kimi-code.json"),
            home.appendingPathComponent(".kimi/credentials/kimi-code.json")
        ]
        let credentials = candidates.compactMap { url -> (URL, [String: Any])? in
            guard FileManager.default.fileExists(atPath: url.path),
                  let value = try? Support.dictionary(at: url) else { return nil }
            return (url, value)
        }.sorted {
            let lhs = Support.date($0.1["expires_at"] ?? $0.1["expiresAt"]) ?? .distantPast
            let rhs = Support.date($1.1["expires_at"] ?? $1.1["expiresAt"]) ?? .distantPast
            return lhs > rhs
        }
        guard !credentials.isEmpty else {
            throw QuotaError.notAuthenticated("未检测到 Kimi Code 登录")
        }

        for (url, credential) in credentials {
            guard let token = Support.string(credential["access_token"] ?? credential["accessToken"]) else { continue }
            do {
                return try await fetchSnapshot(token: token, credentialURL: url)
            } catch QuotaError.http(401) {
                continue
            }
        }

        throw QuotaError.notAuthenticated("Kimi Code 登录已过期")
    }

    private func fetchSnapshot(token: String, credentialURL: URL) async throws -> ProviderSnapshot {
        let payload: Any
        payload = try await Support.jsonRequest(
            URL(string: "https://api.kimi.com/coding/v1/usages")!,
            bearer: token,
            headers: kimiHeaders(home: credentialURL.deletingLastPathComponent().deletingLastPathComponent())
        )
        let root = payload as? [String: Any] ?? [:]
        let body = (root["data"] as? [String: Any]) ?? root
        let windows = Self.parseKimiWindows(body)
        let balances = Self.parseBalances(body)
        let user = (body["userInfo"] as? [String: Any]) ?? (body["user"] as? [String: Any])
        return ProviderSnapshot(
            kind: kind,
            plan: Support.firstString(in: body, keys: ["plan_name", "planName", "membership", "tier"]),
            account: user.flatMap { Support.firstString(in: $0, keys: ["email", "nickname", "username"]) },
            windows: windows,
            balances: balances,
            tokenUsage: intValue(in: body, keys: ["token_usage", "total_tokens", "tokens_used"]),
            requestCount: intValue(in: body, keys: ["request_count", "requests", "total_requests"]),
            updatedAt: Date(),
            message: windows.isEmpty && balances.isEmpty ? "服务未返回可展示额度" : nil
        )
    }

    /// 解析加油包（Extra Usage）余额。
    /// 实测 boosterWallet.balance.unit = UNIT_CURRENCY，以 1e-8 元为最小单位
    /// （如 amount=20000000000 → ¥200，amountLeft=5149500900 → ¥51.50，符合充值上限 ¥10,000）。
    static func parseBalances(_ body: [String: Any]) -> [MoneyBalance] {
        let extra = (body["extra_usage"] as? [String: Any]) ?? (body["extraUsage"] as? [String: Any])
        let extraCents = extra.flatMap { Support.firstNumber(in: $0, keys: ["balance_cents", "balanceCents"]) }
        let boosterWallet = body["boosterWallet"] as? [String: Any]
        let boosterBalance = boosterWallet?["balance"] as? [String: Any]
        let boosterYuan = boosterBalance
            .flatMap { Support.firstNumber(in: $0, keys: ["amountLeft", "amount_left"]) }
            .map { $0 * 1e-8 }
        let currency = extra.flatMap { Support.firstString(in: $0, keys: ["currency"]) }
            ?? (boosterWallet?["topupLimit"] as? [String: Any]).flatMap { Support.firstString(in: $0, keys: ["currency"]) }
            ?? "CNY"
        var balances: [MoneyBalance] = []
        if let boosterYuan { balances.append(MoneyBalance(label: "加油包", amount: boosterYuan, currency: currency)) }
        if let extraCents { balances.append(MoneyBalance(label: "Extra Usage", amount: extraCents / 100, currency: currency)) }
        return balances
    }

    private func kimiHeaders(home: URL) -> [String: String] {
        let device = (try? String(contentsOf: home.appendingPathComponent("device_id"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        return ["X-Msh-Platform": "kimi_cli", "X-Msh-Version": "quota-bar", "X-Msh-Device-Id": device]
    }

    /// Kimi 接口返回结构（实测）：
    /// - 顶层 `usage`：每周重置的套餐额度（周限额），如 `{ "limit": 100, "used": 98, "resetTime": "下周一" }`
    /// - `limits` 数组：各时间窗口，如 `[{ "window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"}, "detail": {"limit": 100, "used": 11, "resetTime": ...} }]`（300 分钟 → 5 小时）
    /// 窗口标题从 window 的时长推断；顶层 usage 单独解析为「周限额」，与 limits 共存显示。
    static func parseKimiWindows(_ body: [String: Any]) -> [QuotaWindow] {
        var windows: [QuotaWindow] = []

        // 1) limits 数组：具体时间窗口（300 分钟 → 5 小时等）
        if let rows = body["limits"] as? [[String: Any]] {
            for row in rows {
                let window = row["window"] as? [String: Any]
                let detail = row["detail"] as? [String: Any]
                guard let detail, let used = Support.firstNumber(in: detail, keys: ["used", "usage"]),
                      let limit = Support.firstNumber(in: detail, keys: ["limit", "total"]), limit > 0 else { continue }
                let duration = Support.firstNumber(in: window ?? [:], keys: ["duration"]) ?? 0
                let timeUnit = Support.firstString(in: window ?? [:], keys: ["timeUnit", "time_unit"])?.lowercased() ?? ""
                let title = Self.windowTitle(duration: duration, timeUnit: timeUnit)
                let reset = Support.date(Support.firstValue(in: detail, keys: ["resetTime", "reset_time", "resets_at"]))
                windows.append(QuotaWindow(title: title, used: used, limit: limit, resetAt: reset))
            }
        }

        // 2) 顶层 usage：每周重置的套餐额度（周限额）。若 limits 中已含周限额则不重复添加。
        if !windows.contains(where: { $0.title == "周限额" }),
           let usage = body["usage"] as? [String: Any],
           let used = Support.firstNumber(in: usage, keys: ["used", "usage"]),
           let limit = Support.firstNumber(in: usage, keys: ["limit", "total"]), limit > 0 {
            let reset = Support.date(Support.firstValue(in: usage, keys: ["resetTime", "reset_time", "resets_at"]))
            windows.append(QuotaWindow(title: "周限额", used: used, limit: limit, resetAt: reset))
        }

        // 3) 兜底：以上结构都没有时，尝试通用解析
        if windows.isEmpty {
            windows = Support.parseGenericWindows(body, preferredLabels: [
                "five": "5 小时", "5h": "5 小时", "week": "周限额", "month": "月限额"
            ])
        }

        var seen = Set<String>()
        return windows.filter { seen.insert("\($0.title)-\($0.resetAt?.timeIntervalSince1970 ?? 0)").inserted }
    }

    private static func windowTitle(duration: Double, timeUnit: String) -> String {
        if timeUnit.contains("month") { return "月限额" }
        if timeUnit.contains("day") && duration >= 7 { return "周限额" }
        if timeUnit.contains("week") { return "周限额" }
        if timeUnit.contains("minute"), duration == 300 { return "5 小时" }
        if timeUnit.contains("hour"), duration == 5 { return "5 小时" }
        if timeUnit.contains("minute") { return "\(Int(duration)) 分钟" }
        if timeUnit.contains("hour") { return "\(Int(duration)) 小时" }
        return "额度"
    }

    private func intValue(in dictionary: [String: Any], keys: [String]) -> Int? {
        Support.firstNumber(in: dictionary, keys: keys).map(Int.init)
    }
}

struct DeepSeekProvider: QuotaProvider {
    let kind = ProviderKind.deepSeek

    func fetch() async throws -> ProviderSnapshot {
        guard let apiKey = discoverAPIKey() else {
            throw QuotaError.notAuthenticated("未检测到 DeepSeek API Key")
        }
        let payload = try await Support.jsonRequest(
            URL(string: "https://api.deepseek.com/user/balance")!, bearer: apiKey
        )
        let root = payload as? [String: Any] ?? [:]
        let rows = root["balance_infos"] as? [[String: Any]] ?? []
        let balances = rows.compactMap { row -> MoneyBalance? in
            guard let amount = Support.firstNumber(in: row, keys: ["total_balance", "balance"]) else { return nil }
            return MoneyBalance(
                label: "API 余额",
                amount: amount,
                currency: Support.firstString(in: row, keys: ["currency"]) ?? "CNY"
            )
        }
        return ProviderSnapshot(
            kind: kind, plan: "API", account: nil, windows: [], balances: balances,
            tokenUsage: nil, requestCount: nil, updatedAt: Date(),
            message: Support.bool(root["is_available"]) == false ? "余额暂不可用" : (balances.isEmpty ? "服务未返回余额" : nil)
        )
    }

    private func discoverAPIKey() -> String? {
        if let value = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"].flatMap(Support.string) { return value }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dshHome = ProcessInfo.processInfo.environment["DSH_HOME"].flatMap(Support.string)
            .map(URL.init(fileURLWithPath:)) ?? home.appendingPathComponent(".dsh")
        let files = [
            dshHome.appendingPathComponent(".credentials.yaml"),
            dshHome.appendingPathComponent(".env"),
            home.appendingPathComponent(".claude/settings.json"),
            home.appendingPathComponent(".config/opencode/opencode.json"),
            home.appendingPathComponent(".config/opencode/opencode.jsonc"),
            home.appendingPathComponent(".kimi/config.toml"),
            home.appendingPathComponent(".kimi-code/config.toml"),
            home.appendingPathComponent(".deepseek/config.json")
        ]
        for url in files where FileManager.default.fileExists(atPath: url.path) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if let value = match(#"DEEPSEEK_API_KEY\s*[\"'=:\s]+([^\"'\s,}]+)"#, in: text) { return value }
            if text.localizedCaseInsensitiveContains("api.deepseek.com"),
               let value = match(#"(?:api_key|apiKey)\s*[\"'=:\s]+([^\"'\s,}]+)"#, in: text) { return value }
        }
        return nil
    }

    private func match(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              result.numberOfRanges > 1,
              let range = Range(result.range(at: 1), in: text) else { return nil }
        return Support.string(String(text[range]))
    }
}
