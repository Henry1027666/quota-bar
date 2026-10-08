import AppKit
import SwiftUI

/// 透明毛玻璃背景：behindWindow 混合模式让面板真正透出并模糊桌面，
/// hudWindow 材质比 ultraThinMaterial 更轻更透（菜单栏 HUD 同款质感）。
private struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var opacity: Double = 1.0

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: NSVisualEffectView) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
        view.alphaValue = opacity
    }
}

/// 精简弹层：顶部为今日/近7天/近30天 token 总用量（纯展示），下方为厂商紧凑行
/// （图标/名称/副标题/百分比/一条细进度条）。图表与明细全部移至主窗口，
/// 点击紧凑行或底部「打开详情」跳转。
struct DashboardView: View {
    @ObservedObject var store: QuotaStore
    @State private var refreshHovered = false
    @State private var detailsHovered = false
    /// 内容高度变化回调：AppDelegate 据此更新 popover 尺寸，实现窗口随条目自适应。
    var onContentHeightChange: ((CGFloat) -> Void)?
    /// 打开主窗口回调：nil 打开总览页，否则定位到对应厂商详情页。
    var onOpenMainWindow: ((ProviderKind?) -> Void)?

    /// 卡片列表区（ScrollView）最大高度：条目再多也不超过此高度，超出滚动。
    static let maxContentHeight: CGFloat = 320

    private var sortedKinds: [ProviderKind] {
        sortedVisibleKinds(states: store.states)
    }

    var body: some View {
        VStack(spacing: 0) {
            summarySection

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(sortedKinds) { kind in
                        ProviderRowView(kind: kind, state: store.states[kind] ?? .loading) {
                            onOpenMainWindow?(kind)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: Self.maxContentHeight)

            Divider().opacity(0.35)
            footer
        }
        .padding(.horizontal, 14)
        .padding(.top, 24)
        .padding(.bottom, 14)
        .frame(width: 350)
        .background(VisualEffectBackground(opacity: 0.7))
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { onContentHeightChange?(geo.size.height) }
                    .onChange(of: geo.size.height) { _, newHeight in
                        onContentHeightChange?(newHeight)
                    }
            }
        )
        .fixedSize(horizontal: false, vertical: true)
        .task { await store.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .dsWebUsageUpdated)) { _ in
            Task { await store.refresh(force: true) }
        }
    }

    // MARK: - 顶部总用量（纯展示，图表在主窗口总览页）

    @ViewBuilder
    private var summarySection: some View {
        if let deltas = tokenDeltas(kinds: sortedKinds, states: store.states) {
            HStack(spacing: 4) {
                summaryStat(title: "今日用量", value: deltas.today)
                summaryStat(title: "近7天用量", value: deltas.last7)
                summaryStat(title: "近30天用量", value: deltas.last30)
            }
            .padding(.bottom, 6)

            Divider().opacity(0.35)
        }
    }

    private func summaryStat(title: String, value: Int) -> some View {
        VStack(spacing: 2) {
            Text(value.formatted(.number.notation(.compactName)))
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Label("仅在本机读取认证", systemImage: "lock.fill")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                onOpenMainWindow?(nil)
            } label: {
                Label("打开详情", systemImage: "rectangle.expand.vertical")
                    .font(.caption2)
                    .foregroundStyle(detailsHovered ? .primary : .secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { detailsHovered = $0 }
            .help("打开主窗口查看图表与明细")
            Button {
                Task { await store.refresh(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .symbolEffect(.rotate, isActive: store.isRefreshing)
                    .foregroundStyle(refreshHovered ? .primary : .secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { refreshHovered = $0 }
            .help("刷新")
            .disabled(store.isRefreshing)
        }
        .padding(.top, 10)
    }
}

/// 弹层厂商紧凑行：图标 + 名称（点击开官网）+ 副标题 + 右侧百分比/余额 + 一条细进度条
/// （取第一个配额窗口，无窗口则不显示）。点击整行打开主窗口并定位到该厂商详情页。
private struct ProviderRowView: View {
    let kind: ProviderKind
    let state: ProviderState
    let onOpen: () -> Void
    @State private var nameHovered = false
    @State private var rowHovered = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: kind.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(kind.tint)
                        .frame(width: 22, height: 22)
                        .background(kind.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                    VStack(alignment: .leading, spacing: 1) {
                        Button {
                            if let url = kind.website { NSWorkspace.shared.open(url) }
                        } label: {
                            HStack(spacing: 3) {
                                Text(kind.name).font(.system(size: 12, weight: .semibold))
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 7, weight: .bold))
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

                if case .ready(let snapshot) = state, let window = snapshot.windows.first {
                    thinBar(fraction: window.fraction)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                .quaternary.opacity(rowHovered ? 0.6 : 0.35),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { rowHovered = $0 }
        .help("打开主窗口查看 \(kind.name) 详情")
    }

    /// 细进度条：阈值配色与 QuotaRow 一致（≥90% 红、≥70% 橙）。
    private func thinBar(fraction: Double) -> some View {
        let tint: Color = fraction >= 0.9 ? .red : fraction >= 0.7 ? .orange : kind.tint
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(tint)
                    .frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 3)
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
}
