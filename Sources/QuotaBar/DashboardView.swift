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

/// 弹层：顶部为今日/近7天/近30天 token 总用量（纯展示），下方为厂商卡片
/// （完整配额窗口进度条 + 余额行，不含图表）。图表与历史明细在主窗口查看，
/// 点击卡片或底部「打开详情」跳转。
struct DashboardView: View {
    @ObservedObject var store: QuotaStore
    @State private var refreshHovered = false
    @State private var detailsHovered = false
    /// 内容高度变化回调：AppDelegate 据此更新 popover 尺寸，实现窗口随条目自适应。
    var onContentHeightChange: ((CGFloat) -> Void)?
    /// 打开主窗口回调：nil 打开总览页，否则定位到对应厂商详情页。
    var onOpenMainWindow: ((ProviderKind?) -> Void)?

    /// 卡片列表区（ScrollView）最大高度：条目再多也不超过此高度，超出滚动。
    static let maxContentHeight: CGFloat = 560

    private var sortedKinds: [ProviderKind] {
        sortedVisibleKinds(states: store.states)
    }

    var body: some View {
        VStack(spacing: 0) {
            summarySection

            ScrollView {
                LazyVStack(spacing: 8) {
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

/// 弹层厂商卡片：头部（图标/名称开官网/副标题/右侧百分比或余额）+ 全部配额窗口进度条
/// + 余额行 + 提示信息，不含图表。点击卡片打开主窗口并定位到该厂商详情页。
private struct ProviderRowView: View {
    let kind: ProviderKind
    let state: ProviderState
    let onOpen: () -> Void
    @State private var nameHovered = false
    @State private var rowHovered = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 9) {
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

                if case .ready(let snapshot) = state {
                    if !snapshot.windows.isEmpty {
                        VStack(spacing: 8) {
                            ForEach(snapshot.windows.prefix(4)) { window in
                                QuotaRow(window: window, tint: kind.tint)
                            }
                        }
                    }
                    let balances = displayBalances(kind: kind, snapshot: snapshot)
                    if !balances.isEmpty {
                        VStack(spacing: 4) {
                            ForEach(balances, id: \.label) { group in
                                HStack {
                                    Text(group.label).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(group.text)
                                        .monospacedDigit()
                                        .fontWeight(.medium)
                                }
                                .font(.caption)
                            }
                        }
                    }
                    if kind == .deepSeek, snapshot.tokenUsage == nil, snapshot.requestCount == nil {
                        Button {
                            DeepSeekWebSession.shared.showLoginWindow()
                        } label: {
                            Label("登录 DeepSeek 获取今日用量", systemImage: "person.crop.circle.badge.plus")
                                .font(.caption)
                                .foregroundStyle(kind.tint)
                        }
                        .buttonStyle(.plain)
                        .help("在应用内登录 DeepSeek 开放平台，自动统计今日调用次数与消耗")
                    }
                    if let message = snapshot.message {
                        Text(message).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
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
