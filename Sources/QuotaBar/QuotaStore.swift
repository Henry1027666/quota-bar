import Foundation
import Combine

@MainActor
final class QuotaStore: ObservableObject {
    @Published private(set) var states: [ProviderKind: ProviderState] = Dictionary(
        uniqueKeysWithValues: ProviderKind.allCases.map { ($0, .loading) }
    )
    @Published private(set) var isRefreshing = false

    /// 最近一次成功完成刷新的时间。
    /// 面板打开时据此判断是否可以直接使用缓存，避免每次都重新读取环境变量/凭据并重复请求接口。
    private(set) var lastRefreshedAt: Date?

    private let providers: [any QuotaProvider] = [
        CodexProvider(), CursorProvider(), ClaudeProvider(), KimiProvider(), DeepSeekProvider()
    ]

    init() {
        // 应用常驻期间后台周期刷新，保证点开面板时数据基本是新鲜的，无需现场重新加载。
        startPeriodicRefresh(interval: Self.defaultRefreshInterval)
    }

    /// 刷新入口。
    /// - 手动刷新按钮传 force=true 无条件刷新；
    /// - 面板打开触发的刷新默认非强制：若在 maxStale 内已刷新过则直接使用缓存，跳过重新加载。
    func refresh(force: Bool = false, maxStale: TimeInterval = QuotaStore.defaultRefreshInterval) async {
        if !force, let last = lastRefreshedAt, Date().timeIntervalSince(last) < maxStale {
            return
        }
        guard !isRefreshing else { return }
        isRefreshing = true
        await withTaskGroup(of: (ProviderKind, ProviderState).self) { group in
            for provider in providers {
                group.addTask {
                    do {
                        return (provider.kind, .ready(try await provider.fetch()))
                    } catch QuotaError.notAuthenticated {
                        return (provider.kind, .notDetected)
                    } catch {
                        return (provider.kind, .unavailable(error.localizedDescription))
                    }
                }
            }
            for await (kind, state) in group { states[kind] = state }
        }
        isRefreshing = false
        lastRefreshedAt = Date()
    }

    /// 后台周期刷新：每次间隔后强制刷新一次，保证面板打开时展示的是近期数据。
    private func startPeriodicRefresh(interval: TimeInterval) {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self else { return }
                await self.refresh(force: true)
            }
        }
    }

    private static let defaultRefreshInterval: TimeInterval = 300 // 5 分钟
}
