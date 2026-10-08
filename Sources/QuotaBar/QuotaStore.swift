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
        CodexProvider(), ClaudeProvider(), KimiProvider(), DeepSeekProvider()
    ]

    /// 周期刷新任务句柄：设置页修改刷新频率后取消旧任务、按新间隔重启。
    private var refreshTask: Task<Void, Never>?

    init() {
        // 应用常驻期间后台周期刷新，保证点开面板时数据基本是新鲜的，无需现场重新加载。
        startPeriodicRefresh(interval: Self.currentRefreshInterval)
    }

    /// 刷新间隔（分钟）的 UserDefaults 键，设置页 Picker 与本类共用。
    nonisolated static let refreshIntervalKey = "refreshIntervalMinutes"

    /// 当前生效的刷新间隔：读 UserDefaults（默认 5 分钟），非法值回退默认。
    nonisolated static var currentRefreshInterval: TimeInterval {
        let minutes = UserDefaults.standard.integer(forKey: refreshIntervalKey)
        return TimeInterval((minutes > 0 ? minutes : 5) * 60)
    }

    /// 设置页修改刷新频率后调用：持久化并重启周期任务使新间隔生效。
    func updateRefreshInterval(minutes: Int) {
        UserDefaults.standard.set(minutes, forKey: Self.refreshIntervalKey)
        startPeriodicRefresh(interval: Self.currentRefreshInterval)
    }

    /// 刷新入口。
    /// - 手动刷新按钮传 force=true 无条件刷新；
    /// - 面板打开触发的刷新默认非强制：若在 maxStale 内已刷新过则直接使用缓存，跳过重新加载。
    func refresh(force: Bool = false, maxStale: TimeInterval = QuotaStore.defaultRefreshInterval) async {
        if !force, let last = lastRefreshedAt, Date().timeIntervalSince(last) < maxStale {
            return
        }
        // 与进行中的刷新撞车：非强制直接跳过；强制刷新等当前一轮结束后自己再跑，
        // 避免用户点刷新按钮时请求被静默丢弃、界面毫无反应。
        while isRefreshing {
            guard force else { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
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
        // 落盘本轮快照供「近 7 天趋势」使用
        for state in states.values {
            if case .ready(let snapshot) = state {
                UsageHistory.shared.record(snapshot)
            }
        }
        isRefreshing = false
        lastRefreshedAt = Date()
    }

    /// 后台周期刷新：每次间隔后强制刷新一次，保证面板打开时展示的是近期数据。
    private func startPeriodicRefresh(interval: TimeInterval) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self else { return }
                await self.refresh(force: true)
            }
        }
    }

    private nonisolated static let defaultRefreshInterval: TimeInterval = 300 // 5 分钟
}
