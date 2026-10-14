import Foundation

/// DeepSeek 平台账户凭据：从 DeepSeek Harness（DSH）的本地凭据存储读取。
///
/// 背景：Quota Bar 原先靠内嵌 WKWebView 登录平台、收割 localStorage 的 JWT 再以
/// `Authorization: Bearer` 调 `platform.deepseek.com`。DSH 登录后，凭据已经落在
/// `$DSH_HOME/.credentials.yaml`（默认 `~/.dsh/.credentials.yaml`），可以直接复用，
/// 从而彻底去掉 WebView 与「登录 DeepSeek」按钮——与 Codex / Kimi 一样自动从本地获取。
///
/// 关键差异（实测确认，最容易踩的坑）：DSH 的凭据**不是 JWT**，而是一段 64 字符不透明串，
/// 且**不能**用 `Authorization: Bearer`（会返回 `code 40003 invalid token`），
/// 必须用 DSH 自己的自定义头 `x-dsh-auth-token`（见其
/// `@deepseek-ai/dsh-deepseek-account-platform` 插件的 `accountHeaders()`）。
///
/// 凭据结构：
/// ```yaml
/// records:
///   deepseek-account-platform/default:
///     kind: grant
///     payload:
///       version: 1
///       token: <64 字符>
///       issuer: https://platform.deepseek.com
/// ```
///
/// 这里不引入 YAML 依赖（只为读一个字段，不值得）：DSH 的凭据文件由机器稳定生成，
/// 缩进固定，按行定位 `deepseek-account-platform/default` 段再取 `token:` 即可；
/// 同时校验 `issuer` 指向 platform.deepseek.com，避免误用其它来源的 grant。
enum DSHDeepSeekAccount {
    /// 平台凭据的 grant 键（DSH 约定）。
    static let grantKey = "deepseek-account-platform/default"
    /// 期望的签发方；不匹配则不使用该凭据。
    static let expectedIssuer = "https://platform.deepseek.com"

    /// DSH 凭据文件路径（可用 DSH_HOME 覆盖，与 DSH 自身一致）。
    static func credentialsURL(home: URL? = nil) -> URL {
        let base = home ?? ProcessInfo.processInfo.environment["DSH_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh")
        return base.appendingPathComponent(".credentials.yaml")
    }

    /// 读取 DSH 的平台账户 token；文件缺失、结构不符或 issuer 不匹配时返回 nil。
    static func token(home: URL? = nil) -> String? {
        token(at: credentialsURL(home: home))
    }

    static func token(at url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parseToken(from: text)
    }

    /// 从凭据 YAML 文本中取出 grant 的 token 与 issuer。
    /// 按行扫描：找到 grantKey 所在行后，在其后续缩进块内取 token/issuer，
    /// 遇到下一个同级或更浅缩进的键即结束（避免误取到其它 grant 的字段）。
    static func parseToken(from text: String) -> String? {
        var inGrant = false
        var grantIndent = 0
        var token: String?
        var issuer: String?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let indent = line.prefix { $0 == " " }.count

            if !inGrant {
                // 定位 grant 键（形如 "  deepseek-account-platform/default:"）
                if trimmed.hasPrefix("\(grantKey):") {
                    inGrant = true
                    grantIndent = indent
                }
                continue
            }
            // 已进入 grant 块：缩进回落到同级或更浅，说明该块结束
            if indent <= grantIndent { break }
            if trimmed.hasPrefix("token:") {
                token = value(of: trimmed, key: "token")
            } else if trimmed.hasPrefix("issuer:") {
                issuer = value(of: trimmed, key: "issuer")
            }
        }

        guard let token, !token.isEmpty else { return nil }
        // issuer 必须指向平台，避免误用其它 origin 的 grant
        if let issuer, !issuer.hasPrefix(expectedIssuer) { return nil }
        return token
    }

    /// 取 "key: value" 中的 value，去掉包裹的引号。
    private static func value(of line: String, key: String) -> String? {
        let raw = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        let unquoted = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return unquoted.isEmpty ? nil : unquoted
    }
}
