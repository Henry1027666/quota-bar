import Foundation
import SwiftUI

enum ProviderKind: String, CaseIterable, Identifiable, Sendable {
    case codex, cursor, claude, kimi, deepSeek

    var id: String { rawValue }

    var name: String {
        switch self {
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .claude: "Claude Code"
        case .kimi: "Kimi Code"
        case .deepSeek: "DeepSeek"
        }
    }

    var symbol: String {
        switch self {
        case .codex: "apple.intelligence"
        case .cursor: "cursorarrow.rays"
        case .claude: "sparkles"
        case .kimi: "moon.stars.fill"
        case .deepSeek: "wave.3.right"
        }
    }

    var tint: Color {
        switch self {
        case .codex: .blue
        case .cursor: .indigo
        case .claude: .orange
        case .kimi: .green
        case .deepSeek: .cyan
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
        if p == "api" || p.contains("api") { return .api }
        if p.contains("free") { return .free }
        // 未解析到套餐名：存在可用额度（窗口/余额）视为订阅档，否则视为免费。
        if p.isEmpty {
            return (windows.isEmpty && balances.isEmpty) ? .free : .tokenPlan
        }
        return .tokenPlan
    }
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

    var errorDescription: String? {
        switch self {
        case .notAuthenticated(let message), .invalidResponse(let message), .command(let message): message
        case .http(let status): "服务返回 HTTP \(status)"
        }
    }
}
