import AppKit
import SwiftUI

struct DashboardView: View {
    @ObservedObject var store: QuotaStore

    /// 可见厂商按「token plan → API → free」排序，free 统一排最下方；同档保持稳定顺序。
    private var sortedKinds: [ProviderKind] {
        let visible = ProviderKind.allCases.filter {
            if case .notDetected = store.states[$0] { return false }
            return true
        }
        return visible.sorted { lhs, rhs in
            let lt = store.states[lhs]?.tier ?? .free
            let rt = store.states[rhs]?.tier ?? .free
            if lt != rt { return lt < rt }
            return lhs.rawValue < rhs.rawValue
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(sortedKinds.enumerated()), id: \.element) { index, kind in
                        ProviderCard(kind: kind, state: store.states[kind] ?? .loading)
                        if index < sortedKinds.count - 1 {
                            Divider().opacity(0.35)
                                .padding(.horizontal, 2)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)

            Divider().opacity(0.35)
            footer
        }
        .padding(14)
        .frame(width: 430, height: 620)
        .background(.ultraThinMaterial)
        .task { await store.refresh() }
    }

    private var footer: some View {
        HStack {
            Label("仅在本机读取认证", systemImage: "lock.fill")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                Task { await store.refresh(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .symbolEffect(.rotate, isActive: store.isRefreshing)
            }
            .buttonStyle(.glass)
            .help("刷新")
            .disabled(store.isRefreshing)
        }
        .padding(.top, 10)
    }
}

private struct ProviderCard: View {
    let kind: ProviderKind
    let state: ProviderState
    @State private var nameHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(kind.tint)
                    .frame(width: 24, height: 24)
                    .background(kind.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 1) {
                    Button {
                        if let url = kind.website { NSWorkspace.shared.open(url) }
                    } label: {
                        HStack(spacing: 3) {
                            Text(kind.name).font(.system(size: 13, weight: .semibold))
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.tertiary)
                        }
                        .foregroundStyle(nameHovered ? kind.tint : .primary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { nameHovered = $0 }
                    .help("打开官网额度页")
                    subtitle
                }

                Spacer()
                trailingSummary
            }

            if case .ready(let snapshot) = state {
                if !snapshot.windows.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(snapshot.windows.prefix(4)) { window in
                            QuotaRow(window: window, tint: kind.tint)
                        }
                    }
                }
                if !snapshot.balances.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(snapshot.balances) { balance in
                            HStack {
                                Text(balance.label).foregroundStyle(.secondary)
                                Spacer()
                                Text(balanceText(balance))
                                    .monospacedDigit()
                                    .fontWeight(.medium)
                            }
                            .font(.caption)
                        }
                    }
                }
                if snapshot.tokenUsage != nil || snapshot.requestCount != nil {
                    HStack(spacing: 16) {
                        if let tokens = snapshot.tokenUsage {
                            metric("Tokens", value: tokens.formatted(.number.notation(.compactName)))
                        }
                        if let requests = snapshot.requestCount {
                            metric("请求", value: requests.formatted())
                        }
                        Spacer()
                    }
                }
                if let message = snapshot.message {
                    Text(message).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var subtitle: some View {
        switch state {
        case .loading:
            Text("正在检测…").foregroundStyle(.secondary)
        case .notDetected:
            EmptyView()
        case .unavailable(let message):
            Text(message).foregroundStyle(.tertiary).lineLimit(1)
        case .ready(let snapshot):
            Text([snapshot.plan, snapshot.account].compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? "已连接")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var trailingSummary: some View {
        switch state {
        case .loading:
            ProgressView().controlSize(.small)
        case .notDetected:
            EmptyView()
        case .unavailable:
            Image(systemName: "minus.circle").foregroundStyle(.tertiary)
        case .ready(let snapshot):
            if let balance = snapshot.balances.first {
                Text(balanceText(balance)).font(.caption).fontWeight(.semibold).monospacedDigit()
            } else if let window = snapshot.windows.first {
                Text(window.fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.caption).fontWeight(.semibold).monospacedDigit()
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
    }

    private func metric(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).fontWeight(.semibold).monospacedDigit()
            Text(label).foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private func balanceText(_ balance: MoneyBalance) -> String {
        if balance.currency.lowercased() == "credits" {
            return "\(balance.amount.formatted(.number.precision(.fractionLength(0...2)))) credits"
        }
        return "\(balance.currency) \(balance.amount.formatted(.number.precision(.fractionLength(2))))"
    }
}

private struct QuotaRow: View {
    let window: QuotaWindow
    let tint: Color

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(window.title)
                Spacer()
                Text("已用 \(window.fraction.formatted(.percent.precision(.fractionLength(0))))")
                    .monospacedDigit()
                if let resetAt = window.resetAt {
                    Text("·").foregroundStyle(.tertiary)
                    Text(resetAt, style: .relative)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            ProgressView(value: window.fraction)
                .progressViewStyle(.linear)
                .tint(progressTint)
        }
    }

    private var progressTint: Color {
        if window.fraction >= 0.9 { return .red }
        if window.fraction >= 0.7 { return .orange }
        return tint
    }
}

private extension ProviderState {
    var tier: PlanTier {
        if case .ready(let snapshot) = self { return snapshot.planTier }
        return .free
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
