import AppKit
import Foundation
import SwiftUI
import Testing
@testable import QuotaBar

/// 把视图渲染为位图（不落盘）。
/// 用真实 NSWindow 承载：ScrollView / onAppear 等依赖视图生命周期的组件只有在此才生效
/// （ImageRenderer 不跑生命周期，点阵图的「默认滚到最新」不会执行，会渲染成空白）。
@MainActor
private func renderToBitmap<V: View>(_ view: V, size: CGSize) -> NSBitmapImageRep? {
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    let host = NSHostingView(rootView: view
        .frame(width: size.width, height: size.height)
        .background(Color(nsColor: .windowBackgroundColor)))
    host.frame = NSRect(origin: .zero, size: size)
    window.contentView = host
    window.orderFront(nil)
    // 让 SwiftUI 完成一次布局与 onAppear 滚动
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    defer { window.orderOut(nil) }
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: rep)
    return rep
}

/// 位图里除背景色外的着色像素数：用于确认「确实画出了东西」而不只是白底。
@MainActor
private func coloredPixelCount(_ rep: NSBitmapImageRep) -> Int {
    var count = 0
    for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
        for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
            guard let c = rep.colorAt(x: x, y: y) else { continue }
            let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
            let maxC = max(r, g, b), minC = min(r, g, b)
            if (maxC - minC) > 0.12 || maxC < 0.75 { count += 1 }
        }
    }
    return count
}

/// 位图里出现的不同色簇数量（量化到 24 级，排除接近白底的像素）。
/// 堆叠柱的每个分段应各占一簇，用它验证「各模型确实异色」而非糊成一片。
@MainActor
private func distinctColorClusters(_ rep: NSBitmapImageRep) -> Int {
    var seen: Set<String> = []
    for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            guard let c = rep.colorAt(x: x, y: y) else { continue }
            let r = Int(c.redComponent * 255), g = Int(c.greenComponent * 255), b = Int(c.blueComponent * 255)
            guard max(r, g, b) - min(r, g, b) > 40 else { continue }
            seen.insert("\(r / 24),\(g / 24),\(b / 24)")
        }
    }
    return seen.count
}

@MainActor
private func points(_ values: [Int], unit: Calendar.Component = .day) -> [DailyTokenUsage] {
    let cal = Calendar(identifier: .gregorian)
    let today = cal.startOfDay(for: Date())
    return values.enumerated().map { i, v in
        DailyTokenUsage(day: cal.date(byAdding: unit, value: i, to: today)!, tokens: v)
    }
}

@MainActor
private func sampleSeries() -> [ChartSeries] {
    let total = [12, 40, 85, 30, 120, 200, 160].map { $0 * 100_000 }
    let m1 = [8, 30, 60, 20, 70, 120, 90].map { $0 * 100_000 }
    let m2 = [3, 8, 20, 8, 40, 60, 50].map { $0 * 100_000 }
    return [
        ChartSeries(name: "Codex", points: points(total),
                    color: ProviderKind.codex.tint, isPrimary: true),
        ChartSeries(name: "gpt-6-sol", points: points(m1),
                    color: modelTint(ProviderKind.codex.tint, index: 0), isPrimary: false),
        ChartSeries(name: "gpt-6.1-sol", points: points(m2),
                    color: modelTint(ProviderKind.codex.tint, index: 1), isPrimary: false)
    ]
}

/// 各图表都能渲染出实际内容（防回归：图形被裁空/渲染成白板）。
@MainActor
@Test func multiSeriesChartsRenderContent() throws {
    let trendRep = try #require(renderToBitmap(
        MultiSeriesTrendChart(series: sampleSeries(), tint: ProviderKind.codex.tint),
        size: CGSize(width: 640, height: 240)))
    #expect(coloredPixelCount(trendRep) > 50, "逐日堆叠柱应画出可见柱体")

    let hourly = [
        ChartSeries(name: "Kimi Code", points: points((0..<14).map { $0 * 90_000 }, unit: .hour),
                    color: ProviderKind.kimi.tint, isPrimary: true)
    ]
    let hourlyRep = try #require(renderToBitmap(
        MultiSeriesHourlyChart(series: hourly, tint: ProviderKind.kimi.tint),
        size: CGSize(width: 640, height: 240)))
    #expect(coloredPixelCount(hourlyRep) > 50, "逐小时堆叠柱应画出可见柱体")

    let yearPoints = (0..<365).map { i in
        let cal = Calendar(identifier: .gregorian)
        return DailyTokenUsage(
            day: cal.date(byAdding: .day, value: i - 364, to: cal.startOfDay(for: Date()))!,
            tokens: (i % 11) * (i % 7) * 40_000)
    }
    let gridRep = try #require(renderToBitmap(
        MultiSeriesContributionGrid(series: [
            ChartSeries(name: "Codex", points: yearPoints,
                        color: ProviderKind.codex.tint, isPrimary: true)
        ]),
        size: CGSize(width: 640, height: 200)))
    #expect(coloredPixelCount(gridRep) > 50, "近一年点阵图应画出格子")
}

/// 堆叠柱的各模型分段必须异色——若糊成同一色就无法分辨模型占比（这正是改堆叠要解决的问题）。
@MainActor
@Test func stackedBarsUseDistinctColorsPerModel() throws {
    let base = ProviderKind.deepSeek.tint
    // 三段量级相当，确保每段都有足够像素参与判色
    let series = [
        ChartSeries(name: "m0", points: points([300, 300, 300]),
                    color: modelTint(base, index: 0), isPrimary: false),
        ChartSeries(name: "m1", points: points([200, 200, 200]),
                    color: modelTint(base, index: 1), isPrimary: false),
        ChartSeries(name: "m2", points: points([100, 100, 100]),
                    color: modelTint(base, index: 2), isPrimary: false)
    ]
    let rep = try #require(renderToBitmap(
        MultiSeriesTrendChart(series: series, tint: base),
        size: CGSize(width: 400, height: 200)))
    #expect(distinctColorClusters(rep) >= 3, "堆叠柱各分段应使用不同颜色")
}

/// 总量序列（isPrimary）在有模型时不参与堆叠绘制：即使它远大于各模型之和，柱高也只由模型决定。
/// 这是「总量不再单独画一条线」的核心契约。
@MainActor
@Test func totalSeriesIsNotDrawnWhenModelsExist() throws {
    let base = ProviderKind.deepSeek.tint
    let models = [
        ChartSeries(name: "m0", points: points([100, 100, 100]),
                    color: modelTint(base, index: 0), isPrimary: false),
        ChartSeries(name: "m1", points: points([50, 50, 50]),
                    color: modelTint(base, index: 1), isPrimary: false)
    ]
    let withoutTotal = try #require(renderToBitmap(
        MultiSeriesTrendChart(series: models, tint: base),
        size: CGSize(width: 400, height: 200)))

    // 总量刻意设成模型的 1000 倍：若被画进图里，纵轴会被拉高、柱体像素大幅减少
    var withHugeTotal = models
    withHugeTotal.insert(
        ChartSeries(name: "DeepSeek", points: points([150_000, 150_000, 150_000]),
                    color: base, isPrimary: true),
        at: 0)
    let withTotal = try #require(renderToBitmap(
        MultiSeriesTrendChart(series: withHugeTotal, tint: base),
        size: CGSize(width: 400, height: 200)))

    let a = coloredPixelCount(withoutTotal)
    let b = coloredPixelCount(withTotal)
    #expect(a > 0)
    // 总量若被绘制，纵轴会撑到 150000，模型柱高被压缩到几乎不可见
    #expect(abs(a - b) < a / 4, "加入总量序列不应改变柱体高度（总量不该被画进图里）")
}

/// 没有模型维度时退回「画总量一根柱」，避免整张图空白。
@MainActor
@Test func fallsBackToTotalBarWhenNoModels() throws {
    let base = ProviderKind.codex.tint
    let onlyTotal = [
        ChartSeries(name: "Codex", points: points([100, 200, 150]),
                    color: base, isPrimary: true)
    ]
    let rep = try #require(renderToBitmap(
        MultiSeriesTrendChart(series: onlyTotal, tint: base),
        size: CGSize(width: 400, height: 200)))
    #expect(coloredPixelCount(rep) > 50, "无模型维度时应画出总量柱而非空白")

    let hourlyOnlyTotal = [
        ChartSeries(name: "Kimi Code", points: points([100, 200, 150], unit: .hour),
                    color: ProviderKind.kimi.tint, isPrimary: true)
    ]
    let hourlyRep = try #require(renderToBitmap(
        MultiSeriesHourlyChart(series: hourlyOnlyTotal, tint: ProviderKind.kimi.tint),
        size: CGSize(width: 400, height: 200)))
    #expect(coloredPixelCount(hourlyRep) > 50, "逐小时图同理，不应空白")
}

/// 全部数据为 0 时不应崩溃（坐标轴不退化）。
@MainActor
@Test func multiSeriesChartsHandleAllZeroData() throws {
    let series = [
        ChartSeries(name: "Codex", points: points([0, 0, 0, 0, 0, 0, 0]),
                    color: ProviderKind.codex.tint, isPrimary: true)
    ]
    let rep = try #require(renderToBitmap(
        MultiSeriesTrendChart(series: series, tint: ProviderKind.codex.tint),
        size: CGSize(width: 640, height: 240)))
    #expect(rep.pixelsWide > 0)
}
