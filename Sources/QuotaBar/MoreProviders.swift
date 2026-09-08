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
            // access_token 已过期或即将过期：先用 refresh_token 刷新（Kimi CLI 亦是此机制）。
            var effectiveToken = token
            if Self.isExpiring(credential), let refreshed = await Self.refreshCredential(at: url) {
                effectiveToken = refreshed
            }
            do {
                return try await fetchSnapshot(token: effectiveToken, credentialURL: url)
            } catch QuotaError.http(401) {
                // 401：刷新后再试一次
                if let refreshed = await Self.refreshCredential(at: url) {
                    do {
                        return try await fetchSnapshot(token: refreshed, credentialURL: url)
                    } catch QuotaError.http(401) {
                        continue
                    }
                }
                continue
            }
        }

        // 存在凭据但全部失效：显示「登录已过期」卡片，而不是从面板中悄悄隐藏。
        throw QuotaError.sessionExpired("Kimi 登录已过期，请重新登录")
    }

    /// access_token 是否已过期或在 5 分钟缓冲期内即将过期。
    private static func isExpiring(_ credential: [String: Any]) -> Bool {
        guard let exp = Support.number(credential["expires_at"] ?? credential["expiresAt"]) else { return false }
        return exp - Date().timeIntervalSince1970 < 300
    }

    /// 用 refresh_token 刷新 access_token 并原子写回凭据文件（保持 600 权限）；成功返回新 token。
    private static func refreshCredential(at url: URL) async -> String? {
        guard let data = try? Data(contentsOf: url),
              var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let refreshToken = Support.string(dict["refresh_token"]) else { return nil }
        var request = URLRequest(url: URL(string: "https://auth.kimi.com/api/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = "client_id=17e5f671-d194-4dfb-9706-5516cb48c098&grant_type=refresh_token&refresh_token=\(refreshToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? refreshToken)"
        request.httpBody = Data(form.utf8)
        guard let (data, response) = try? await Support.session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let newToken = Support.string(result["access_token"]) else { return nil }
        dict["access_token"] = newToken
        if let newRefresh = Support.string(result["refresh_token"]) { dict["refresh_token"] = newRefresh }
        if let expiresIn = Support.number(result["expires_in"]) {
            dict["expires_at"] = Date().timeIntervalSince1970 + expiresIn
        }
        if let payload = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) {
            if (try? payload.write(to: url, options: .atomic)) != nil {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
        return newToken
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
    /// 注意：额度用满时接口可能不再返回 `detail.used`，只返回 `remaining`，需用 limit - remaining 推算。
    /// 窗口标题从 window 的时长推断；顶层 usage 单独解析为「周限额」，与 limits 共存显示。
    static func parseKimiWindows(_ body: [String: Any]) -> [QuotaWindow] {
        var windows: [QuotaWindow] = []

        // 1) limits 数组：具体时间窗口（300 分钟 → 5 小时等）
        if let rows = body["limits"] as? [[String: Any]] {
            for row in rows {
                let window = row["window"] as? [String: Any]
                let detail = row["detail"] as? [String: Any]
                guard let detail, let used = usedAmount(in: detail),
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
           let used = usedAmount(in: usage),
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

    /// 从额度明细提取已用量：优先 used/usage；额度用满时接口可能只返回 remaining，此时用 limit - remaining 推算。
    private static func usedAmount(in detail: [String: Any]) -> Double? {
        if let used = Support.firstNumber(in: detail, keys: ["used", "usage"]) { return used }
        if let limit = Support.firstNumber(in: detail, keys: ["limit", "total"]),
           let remaining = Support.firstNumber(in: detail, keys: ["remaining", "left"]) {
            return limit - remaining
        }
        return nil
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
        // 官方 API：余额（始终可用）
        let payload = try await Support.jsonRequest(
            URL(string: "https://api.deepseek.com/user/balance")!, bearer: apiKey
        )
        let root = payload as? [String: Any] ?? [:]
        let rows = root["balance_infos"] as? [[String: Any]] ?? []
        var balances = rows.compactMap { row -> MoneyBalance? in
            guard let amount = Support.firstNumber(in: row, keys: ["total_balance", "balance"]) else { return nil }
            return MoneyBalance(
                label: "API 余额",
                amount: amount,
                currency: Support.firstString(in: row, keys: ["currency"]) ?? "CNY"
            )
        }.filter { $0.amount > 0 }

        // 网页用量统计（今日调用次数 / 消耗 / 本月消费）：
        // 纯 HTTP 拉取——优先 bearer token（~/.deepseek/web_token），否则 DeepSeek 网页会话 cookie
        // （~/.deepseek/web_cookies，由内嵌登录成功后收割）。两条都是轻量 URLSession，不创建任何 WebView，
        // 避免后台反复加载 usage 整站导致的 WebKit 渲染内存滚雪球（曾实测 40MB→800MB 卡死）。
        var tokenUsage: Int?
        var requestCount: Int?
        var message: String?
        if let webToken = discoverWebToken() {
            Log.append("DS", "发现网页会话 token (前缀 \(webToken.prefix(12))…)，拉取用量接口")
            // 网页会话 bearer token（~/.deepseek/web_token，由内嵌登录收割 localStorage JWT 写入）
            do {
                let web = try await fetchWebUsage(bearer: webToken)
                applyWeb(web, to: &balances, &tokenUsage, &requestCount)
                Log.append("DS", "用量接口成功: balances=\(web.balances.count) tokens=\(String(describing: web.tokenUsage)) req=\(String(describing: web.requestCount))")
                if web.isEmpty { message = "网页用量接口未返回数据" }
            } catch let QuotaError.sessionExpired(msg) {
                Log.append("DS", "用量接口 → 登录过期: \(msg)")
                message = msg
            } catch {
                Log.append("DS", "用量接口 → 失败: \(error.localizedDescription)")
                message = "用量统计不可用（\(error.localizedDescription)）"
            }
        } else {
            // 无网页会话 token：提示用户在面板点「登录 DeepSeek」。
            // 绝不在此创建 WebView——后台纯 HTTP，杜绝 WebKit 渲染内存滚雪球。
            Log.append("DS", "未发现网页会话 token")
            message = "未开启今日用量：点下方「登录 DeepSeek」"
        }

        return ProviderSnapshot(
            kind: kind, plan: "API", account: nil, windows: [], balances: balances,
            tokenUsage: tokenUsage, requestCount: requestCount, updatedAt: Date(),
            message: Support.bool(root["is_available"]) == false ? "余额暂不可用"
                : (message ?? (balances.isEmpty ? "服务未返回余额" : nil))
        )
    }

    private func applyWeb(_ web: WebUsage, to balances: inout [MoneyBalance],
                          _ tokenUsage: inout Int?, _ requestCount: inout Int?) {
        balances.append(contentsOf: web.balances)
        tokenUsage = web.tokenUsage
        requestCount = web.requestCount
    }

    // MARK: - 网页端用量（platform.deepseek.com，需登录态）

    private static let endpointSummary = "/api/v0/users/get_user_summary"
    private static let endpointAmount = "/api/v0/usage/by_api_key/amount"
    private static let endpointCost = "/api/v0/usage/by_api_key/cost"

    struct WebUsage: Sendable {
        var balances: [MoneyBalance] = []
        var tokenUsage: Int?
        var requestCount: Int?
        var isEmpty: Bool { balances.isEmpty && tokenUsage == nil && requestCount == nil }
    }

    /// 解析内嵌会话收集的三个接口响应体（键为 endpoint path）。
    static func parseWebPayload(_ payload: [String: Any]) -> WebUsage? {
        var result = WebUsage()
        if let summary = payload[endpointSummary] {
            parseSummary(summary, into: &result)
        }
        if let amount = payload[endpointAmount] {
            parseAmount(amount, into: &result)
        }
        if let cost = payload[endpointCost] {
            parseCost(cost, into: &result)
        }
        return result.isEmpty ? nil : result
    }

    /// 用 bearer token（手动 ~/.deepseek/web_token）拉取三接口。
    private func fetchWebUsage(bearer: String) async throws -> WebUsage {
        try await fetchUsageEndpoints(auth: { request in
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        })
    }

    /// 用网页会话 cookie 头（内嵌登录收割的 ~/.deepseek/web_cookies）拉取三接口。
    /// 纯 URLSession，不创建任何 WebView。
    private func fetchWebUsage(cookie: String) async throws -> WebUsage {
        try await fetchUsageEndpoints(auth: { request in
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        })
    }

    /// 三个 /api/v0 接口的共同拉取逻辑，认证方式由 auth 闭包注入。
    /// 数据口径与平台「用量信息」页一致（by_api_key 接口，按东八区每天一个 bucket，共 30 天）。
    private func fetchUsageEndpoints(auth: (inout URLRequest) -> Void) async throws -> WebUsage {
        let base = "https://platform.deepseek.com/api/v0"
        let range = Self.usageRange()
        let tz = 8 * 3600

        func get(_ url: URL) async throws -> Any {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            // 网页接口由华为 WAF 反爬：非浏览器请求会被 "Request Blocked" 拦截，
            // 需带上浏览器 User-Agent + 同源 Referer/Origin 才能通过。
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
                             forHTTPHeaderField: "User-Agent")
            request.setValue("https://platform.deepseek.com/", forHTTPHeaderField: "Referer")
            request.setValue("https://platform.deepseek.com", forHTTPHeaderField: "Origin")
            auth(&request)
            let (data, response) = try await Support.session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw QuotaError.invalidResponse("未收到有效响应")
            }
            Log.append("DS", "后台GET \(url.path) → HTTP \(http.statusCode)")
            guard (200..<300).contains(http.statusCode) else {
                let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
                Log.append("DS", "后台GET失败 HTTP \(http.statusCode) body: \(snippet)")
                throw QuotaError.http(http.statusCode)
            }
            let parsed = try JSONSerialization.jsonObject(with: data)
            if let dict = parsed as? [String: Any] {
                Log.append("DS", "后台GET \(url.path) code=\(dict["code"] ?? "?")")
            }
            return parsed
        }

        var result = WebUsage()

        // 1) 账户摘要：充值余额 / 赠送余额 / 累计消费
        let summary = try await get(URL(string: "\(base)/users/get_user_summary")!)
        try ensureWebSuccess(summary)
        Self.parseSummary(summary, into: &result)

        // 2) Token/请求用量（近 30 天）
        let amount = try await get(URL(string: "\(base)/usage/by_api_key/amount?start=\(Int(range.start))&end=\(Int(range.end))&tz=\(tz)")!)
        try ensureWebSuccess(amount)
        Self.parseAmount(amount, into: &result)

        // 3) 每日费用（近 30 天）
        let cost = try await get(URL(string: "\(base)/usage/by_api_key/cost?start=\(Int(range.start))&end=\(Int(range.end))&tz=\(tz)")!)
        try ensureWebSuccess(cost)
        Self.parseCost(cost, into: &result)

        return result
    }

    // MARK: - 解析（HTTP 与内嵌会话共用）

    /// get_user_summary：赠送余额（非零）/ 累计消费（total_costs CNY）。
    /// 充值余额与官方 API 余额重复，不重复展示。
    private static func parseSummary(_ json: Any, into result: inout WebUsage) {
        guard let biz = bizData(json) else { return }
        if let (bonus, currency) = firstNonZeroWallet(biz["bonus_wallets"]) {
            result.balances.append(MoneyBalance(label: "赠送余额", amount: bonus, currency: currency))
        }
        // 累计消费：CNY 总额（0 也显示，属核心指标）
        if let total = walletAmount(biz["total_costs"], currency: "CNY", key: "amount", includeZero: true) {
            result.balances.append(MoneyBalance(label: "累计消费", amount: total, currency: "CNY"))
        }
    }

    /// by_api_key/amount：series[].buckets[].usage 逐日求和（近 30 天请求数 / Tokens）。
    private static func parseAmount(_ json: Any, into result: inout WebUsage) {
        guard let biz = bizData(json),
              let series = biz["series"] as? [[String: Any]] else { return }
        var requests = 0
        var tokens = 0
        for item in series {
            for bucket in (item["buckets"] as? [[String: Any]] ?? []) {
                guard let usage = bucket["usage"] as? [String: Any] else { continue }
                requests += Int(Support.firstNumber(in: usage, keys: ["REQUEST"]) ?? 0)
                tokens += Int(Support.firstNumber(in: usage, keys: ["PROMPT_CACHE_HIT_TOKEN"]) ?? 0)
                    + Int(Support.firstNumber(in: usage, keys: ["PROMPT_CACHE_MISS_TOKEN"]) ?? 0)
                    + Int(Support.firstNumber(in: usage, keys: ["RESPONSE_TOKEN", "COMPLETION_TOKEN"]) ?? 0)
            }
        }
        result.requestCount = requests
        result.tokenUsage = tokens
    }

    /// by_api_key/cost：data[].series[].buckets[].cost 逐日求和（今日消费 + 近 30 天消费）。
    private static func parseCost(_ json: Any, into result: inout WebUsage) {
        guard let biz = bizData(json),
              let data = biz["data"] as? [[String: Any]] else { return }
        var total = 0.0
        var today = 0.0
        var currency = "CNY"
        // 东八区「今天 00:00」的 bucket（usageRange 的 end 是明天 0 点，往前一天即今天）。
        let todayTime = usageRange().end - 86400
        for entry in data {
            if let c = Support.firstString(in: entry, keys: ["currency"]), !c.isEmpty { currency = c }
            for item in (entry["series"] as? [[String: Any]] ?? []) {
                for bucket in (item["buckets"] as? [[String: Any]] ?? []) {
                    let cost = Support.firstNumber(in: bucket, keys: ["cost", "amount"]) ?? 0
                    total += cost
                    if let t = Support.firstNumber(in: bucket, keys: ["time"]), Int(t) == Int(todayTime) {
                        today += cost
                    }
                }
            }
        }
        // 核心指标：0 也显示
        result.balances.append(MoneyBalance(label: "今日消费", amount: (today * 100).rounded() / 100, currency: currency))
        result.balances.append(MoneyBalance(label: "近30天消费", amount: (total * 100).rounded() / 100, currency: currency))
    }

    /// 页面默认口径：东八区「今天 00:00」到「明天 00:00」为 end，向前 30 天为 start。
    private static func usageRange() -> (start: TimeInterval, end: TimeInterval) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let todayStart = cal.startOfDay(for: Date())
        let end = todayStart.addingTimeInterval(86400)
        let start = end.addingTimeInterval(-30 * 86400)
        return (start.timeIntervalSince1970, end.timeIntervalSince1970)
    }

    /// 在 wallets/costs 数组中取指定币种的值；includeZero 为 true 时金额 0 也返回。
    private static func walletAmount(_ value: Any?, currency: String, key: String, includeZero: Bool = false) -> Double? {
        guard let rows = value as? [[String: Any]] else { return nil }
        for row in rows {
            guard (Support.firstString(in: row, keys: ["currency"]) ?? "").uppercased() == currency else { continue }
            if let amount = Support.firstNumber(in: row, keys: [key]), includeZero || amount > 0 {
                return amount
            }
        }
        return nil
    }

    /// 取第一个非零余额的钱包（币种 + 金额）。
    private static func firstNonZeroWallet(_ value: Any?) -> (Double, String)? {
        guard let rows = value as? [[String: Any]] else { return nil }
        for row in rows {
            if let amount = Support.firstNumber(in: row, keys: ["balance"]), amount > 0 {
                return (amount, Support.firstString(in: row, keys: ["currency"]) ?? "CNY")
            }
        }
        return nil
    }
    private static func bizData(_ json: Any) -> [String: Any]? {
        let dict = json as? [String: Any] ?? [:]
        if let biz = dict["biz_data"] as? [String: Any] { return biz }
        if let d = dict["data"] as? [String: Any], let biz = d["biz_data"] as? [String: Any] { return biz }
        if let d = dict["data"] as? [[String: Any]], let first = d.first { return first }
        return dict.isEmpty ? nil : dict
    }

    /// 网页接口 code != 0 时抛错：40002/40003 视为登录态失效。
    private func ensureWebSuccess(_ json: Any) throws {
        let dict = json as? [String: Any] ?? [:]
        if let code = Support.firstNumber(in: dict, keys: ["code"]), Int(code) != 0 {
            if Int(code) == 40002 || Int(code) == 40003 {
                throw QuotaError.sessionExpired("DeepSeek 网页登录已过期，请在面板内重新登录")
            }
            throw QuotaError.invalidResponse("DeepSeek 网页接口错误（code \(Int(code))）")
        }
    }

    /// 读取内嵌登录收割后落盘的 DeepSeek 网页会话 JWT（由 DeepSeekWebSession 写入 ~/.deepseek/web_token）。
    private func discoverWebToken() -> String? {
        if let value = ProcessInfo.processInfo.environment["DEEPSEEK_WEB_TOKEN"].flatMap(Support.string) { return value }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".deepseek/web_token")
        guard FileManager.default.fileExists(atPath: url.path),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // 兼容 DeepSeek 网页端 JSON 包装格式：{"value":"<token>","__version":"0"} → 取 value。
        if let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = obj["value"] as? String, !value.isEmpty {
            return value
        }
        return trimmed
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
