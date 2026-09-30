import Foundation
import SwiftUI

enum ProviderKind: String, CaseIterable, Identifiable, Sendable {
    case codex, claude, kimi, deepSeek

    var id: String { rawValue }

    var name: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .kimi: "Kimi Code"
        case .deepSeek: "DeepSeek"
        }
    }

    var symbol: String {
        switch self {
        case .codex: "apple.intelligence"
        case .claude: "sparkles"
        case .kimi: "moon.stars.fill"
        case .deepSeek: "wave.3.right"
        }
    }

    var tint: Color {
        switch self {
        case .codex: .blue
        case .claude: .orange
        case .kimi: .green
        case .deepSeek: .cyan
        }
    }

    /// 各厂商官网额度/订阅页，点击厂商名时跳转。
    var website: URL? {
        switch self {
        case .codex: URL(string: "https://chatgpt.com/usage")
        case .claude: URL(string: "https://claude.ai/settings/usage")
        case .kimi: URL(string: "https://www.kimi.com/settings/subscription?tab=quota&from=kfc_console_upgrade")
        case .deepSeek: URL(string: "https://platform.deepseek.com/usage")
        }
    }
}

struct QuotaWindow: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let used: Double
    let limit: Double
    let resetAt: Date?

    init(title: String, used: Double, limit: Double, resetAt: Date?) {
        self.id = "\(title)-\(resetAt?.timeIntervalSince1970 ?? 0)"
        self.title = title
        self.used = max(0, used)
        self.limit = max(0, limit)
        self.resetAt = resetAt
    }

    var fraction: Double { limit > 0 ? min(max(used / limit, 0), 1) : 0 }
}

struct MoneyBalance: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let amount: Double
    let currency: String

    init(label: String, amount: Double, currency: String) {
        self.id = "\(label)-\(currency)"
        self.label = label
        self.amount = amount
        self.currency = currency
    }
}

struct ProviderSnapshot: Identifiable, Equatable, Sendable {
    let kind: ProviderKind
    var plan: String?
    var account: String?
    var windows: [QuotaWindow]
    var balances: [MoneyBalance]
    var tokenUsage: Int?
    var requestCount: Int?
    /// Token 用量的按日精确分解（今日/本周/本月），由能给出精确数据的厂商填充
    /// （如 Codex 本地会话日志统计）；nil 时趋势页回退到采样增量估算。
    var tokenBreakdown: TokenBreakdown? = nil
    /// 近 7 天逐日 token 用量（本地日志精确统计，升序，末位为今天）；
    /// 非 nil 时趋势页用它替换采样百分比曲线。
    var dailyTokens: [DailyTokenUsage]? = nil
    var updatedAt: Date
    var message: String?

    var id: ProviderKind { kind }

    /// 显示优先级：token plan（订阅额度）→ API（按量余额）→ free（免费），free 统一排在最后。
    var planTier: PlanTier {
        let p = plan?.lowercased() ?? ""
        if p.contains("token") || p.contains("coding") || p.contains("plus")
            || p.contains("pro") || p.contains("max") || p.contains("business") {
            return .tokenPlan
        }
        if p.contains("api") { return .api }
        if p.contains("free") { return .free }
        // 未解析到套餐名：存在可用额度（窗口/余额）视为订阅档，否则视为免费。
        if p.isEmpty {
            return (windows.isEmpty && balances.isEmpty) ? .free : .tokenPlan
        }
        return .tokenPlan
    }
}

/// Token 用量按自然周期的分解：今日 / 本周（周一起）/ 本月。
struct TokenBreakdown: Equatable, Sendable {
    let today: Int
    let week: Int
    let month: Int
}

/// 某自然日的 token 用量（本地日志精确统计）。
struct DailyTokenUsage: Equatable, Sendable {
    /// 当日 00:00 本地时间
    let day: Date
    let tokens: Int
}

/// 面板内厂商卡片的显示档位，rawValue 越小越靠前。
enum PlanTier: Int, Comparable, Sendable {
    case tokenPlan = 0
    case api = 1
    case free = 2

    static func < (lhs: PlanTier, rhs: PlanTier) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum ProviderState: Equatable, Sendable {
    case loading
    case notDetected
    case unavailable(String)
    case ready(ProviderSnapshot)
}

protocol QuotaProvider: Sendable {
    var kind: ProviderKind { get }
    func fetch() async throws -> ProviderSnapshot
}

enum QuotaError: LocalizedError {
    case notAuthenticated(String)
    case invalidResponse(String)
    case http(Int)
    case command(String)
    /// 检测到凭据但登录已失效（如 token 过期且刷新失败），应显示提示而非隐藏卡片。
    case sessionExpired(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated(let message), .invalidResponse(let message),
             .command(let message), .sessionExpired(let message): message
        case .http(let status): "服务返回 HTTP \(status)"
        }
    }
}
