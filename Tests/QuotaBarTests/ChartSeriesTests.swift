import AppKit
import Foundation
import SwiftUI
import Testing
@testable import QuotaBar

/// 单厂商曲线组装配：总量在前（粗线）、模型按合计降序在后（细线），零用量模型被过滤。
@Test func chartSeriesOrdersTotalFirstThenModels() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("chart-series-\(UUID().uuidString)")
    let sessions = root.appendingPathComponent("sessions")
    let dayStart = Calendar(identifier: .gregorian).startOfDay(for: Date())
    let comps = Calendar(identifier: .gregorian)
        .dateComponents([.year, .month, .day], from: dayStart)
    let dir = sessions.appendingPathComponent(
        String(format: "%04d/%02d/%02d", comps.year!, comps.month!, comps.day!))
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let iso = ISO8601DateFormatter().string(from: dayStart.addingTimeInterval(12 * 3600))

    // small 用量小于 big，验证接口按合计降序而非文件出现顺序
    let lines = [
        #"{"timestamp":"\#(iso)","type":"turn_context","payload":{"model":"small"}}"#,
        #"{"timestamp":"\#(iso)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":10}}}}"#,
        #"{"timestamp":"\#(iso)","type":"turn_context","payload":{"model":"big"}}"#,
        #"{"timestamp":"\#(iso)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":900}}}}"#
    ]
    try lines.joined(separator: "\n").write(
        to: dir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)

    let byModel = CodexLocalLogs.dailyTokensByModel(sessionsRoot: sessions, days: 7, now: Date())
    #expect(byModel.map(\.model) == ["big", "small"], "模型应按合计降序")

    // 复刻 TrendChartPager.buildSeries 的装配顺序契约：总量第 0 条且 isPrimary
    let daily = CodexLocalLogs.dailyTokens(sessionsRoot: sessions, days: 7, now: Date())
    var series: [ChartSeries] = [ChartSeries(
        name: ProviderKind.codex.name,
        points: daily,
        color: ProviderKind.codex.tint,
        isPrimary: true
    )]
    for (index, model) in byModel.enumerated() where model.total > 0 {
        series.append(ChartSeries(
            name: model.model,
            points: model.points,
            color: modelTint(ProviderKind.codex.tint, index: index),
            isPrimary: false
        ))
    }
    #expect(series.count == 3, "1 条总量 + 2 条模型")
    #expect(series[0].isPrimary)
    #expect(series[0].name == "Codex")
    #expect(series.dropFirst().allSatisfy { !$0.isPrimary })
    #expect(series[1].name == "big")
    #expect(series[2].name == "small")
    // 总量 = 各模型之和
    #expect(series[0].total == series.dropFirst().reduce(0) { $0 + $1.total })

    try FileManager.default.removeItem(at: root)
}

/// 零用量模型不产生曲线（真实 DeepSeek 响应里 6 个模型有 5 个是 0）。
@Test func chartSeriesDropsZeroUsageModels() {
    let day = Calendar(identifier: .gregorian).startOfDay(for: Date())
    // dailyModelSeries 的 key 是东八区 "yyyy-MM-dd"，与 periodStats 的日期轴口径一致
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd"
    fmt.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
    let key = fmt.string(from: day)
    let byModel = [
        "used": [key: 500],
        "empty": [key: 0]
    ]
    let series = DeepSeekProvider.dailyModelSeries(byModel, days: [day])
    #expect(series?.count == 1)
    #expect(series?.first?.model == "used")
}

/// 逐小时序列装配与逐日一致。
@Test func hourlyModelSeriesAlignsToHourAxis() {
    let hour = Calendar(identifier: .gregorian).startOfDay(for: Date())
    let ts = Int(hour.timeIntervalSince1970)
    let series = DeepSeekProvider.hourlyModelSeries(
        ["m1": [ts: 40], "m2": [ts: 0]], hours: [hour]
    )
    #expect(series?.count == 1)
    #expect(series?.first?.model == "m1")
    #expect(series?.first?.total == 40)
}

/// 模型配色：相邻档位必须产生肉眼可辨的差异（亮度/色相/饱和度任一维度）。
@Test func modelTintProducesDistinctColors() {
    for base in [Color.blue, .green, .cyan] {
        let tints = (0..<6).map { modelTint(base, index: $0) }
        var components: [(CGFloat, CGFloat, CGFloat)] = []
        for tint in tints {
            let ns = NSColor(tint).usingColorSpace(.deviceRGB) ?? .black
            components.append((ns.hueComponent, ns.brightnessComponent, ns.saturationComponent))
        }
        // 相邻两档至少在一个维度上差异明显
        for i in 1..<components.count {
            let (h0, b0, s0) = components[i - 1]
            let (h1, b1, s1) = components[i]
            let hueGap = min(abs(h0 - h1), 1 - abs(h0 - h1))
            let differs = hueGap > 0.02 || abs(b0 - b1) > 0.08 || abs(s0 - s1) > 0.08
            #expect(differs, "第 \(i) 档与前一档颜色过于接近")
        }
    }
}
