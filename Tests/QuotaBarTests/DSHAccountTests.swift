import Foundation
import Testing
@testable import QuotaBar

/// 凭据解析：只取 platform grant 的 token，且必须是 platform.deepseek.com 签发。
@Test func parsesDSHTokenFromCredentials() {
    let yaml = """
    version: 1
    refs:
      DEEPSEEK_API_KEY: sk-abc123
    records:
      client-connection/browser-session:
        kind: grant
        payload:
          version: 1
          secret: should-not-be-picked
      deepseek-account-platform/device:
        kind: grant
        payload:
          id: 98853de8-3959-4170-b3b2-44dc2630531e
      deepseek-account-platform/default:
        kind: grant
        payload:
          version: 1
          token: THE-PLATFORM-TOKEN
          issuer: https://platform.deepseek.com
    """
    #expect(DSHDeepSeekAccount.parseToken(from: yaml) == "THE-PLATFORM-TOKEN")
}

/// 必须校验 issuer：其它 origin 的 grant 不能拿来调 platform 接口。
@Test func rejectsNonPlatformIssuer() {
    let yaml = """
    records:
      deepseek-account-platform/default:
        kind: grant
        payload:
          token: OTHER-TOKEN
          issuer: https://evil.example.com
    """
    #expect(DSHDeepSeekAccount.parseToken(from: yaml) == nil)
}

/// 缺 token / 缺 grant / 空文件都应安全返回 nil，不能崩也不能误取。
@Test func handlesMalformedCredentials() {
    #expect(DSHDeepSeekAccount.parseToken(from: "") == nil)
    #expect(DSHDeepSeekAccount.parseToken(from: "version: 1\nrecords: {}\n") == nil)
    // 只有 device grant，没有 default grant
    let onlyDevice = """
    records:
      deepseek-account-platform/device:
        kind: grant
        payload:
          id: 98853de8
    """
    #expect(DSHDeepSeekAccount.parseToken(from: onlyDevice) == nil)
    // token 为空
    let emptyToken = """
    records:
      deepseek-account-platform/default:
        payload:
          token:
    """
    #expect(DSHDeepSeekAccount.parseToken(from: emptyToken) == nil)
}

/// grant 块结束判定：后续同级键的字段不能被误当成该 grant 的内容。
@Test func stopsAtSiblingGrant() {
    let yaml = """
    records:
      deepseek-account-platform/default:
        kind: grant
        payload:
          token: REAL-TOKEN
      deepseek-account-platform/device:
        kind: grant
        payload:
          token: DECOY-TOKEN
    """
    #expect(DSHDeepSeekAccount.parseToken(from: yaml) == "REAL-TOKEN")
}

/// 端到端：真实凭据能拉到余额与逐日用量，且与已知口径一致。
@MainActor
@Test func fetchesRealUsageViaDSHCredential() async throws {
    guard DSHDeepSeekAccount.token() != nil else {
        print("DSH-PROBE: 本机无 DSH 凭据，跳过"); return
    }
    let provider = DeepSeekProvider()
    let snapshot = try await provider.fetch()
    print("DSH-PROBE balances=\(displayBalances(kind: .deepSeek, snapshot: snapshot))")
    print("DSH-PROBE today=\(String(describing: snapshot.tokenUsage)) req=\(String(describing: snapshot.requestCount))")
    print("DSH-PROBE last365=\(String(describing: snapshot.last365Tokens))")
    print("DSH-PROBE dailyDays=\(snapshot.dailyTokens?.count ?? 0) models=\(snapshot.dailyTokensByModel?.count ?? 0)")
    for m in snapshot.dailyTokensByModel ?? [] {
        print("DSH-PROBE model=\(m.model) total=\(m.total)")
    }
    #expect(!snapshot.balances.isEmpty, "应拿到余额")
    #expect(snapshot.dailyTokens != nil, "应拿到逐日用量")
    #expect((snapshot.last365Tokens ?? 0) > 0, "应拿到近一年合计")
}
