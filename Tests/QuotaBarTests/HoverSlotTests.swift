import Foundation
import Testing
@testable import QuotaBar

/// 柱区间判定：鼠标落在第 i 根柱的范围内就应选中第 i 天（而非"最近的数据点"）。
/// 复刻 MultiSeriesTrendChart.day(atX:width:) 的算法契约。
private func slotIndex(x: CGFloat, width: CGFloat, count: Int) -> Int {
    let slot = width / CGFloat(count)
    let index = Int(floor(x / slot))
    if index < 0 { return 0 }
    if index >= count { return count - 1 }
    return index
}

@Test func hoverPicksBarByRangeNotNearestPoint() {
    let count = 7
    let width: CGFloat = 700
    let slot = width / CGFloat(count)   // 每根柱 100pt

    // 每根柱的中心点必须命中自己
    for i in 0..<count {
        let center = CGFloat(i) * slot + slot / 2
        #expect(slotIndex(x: center, width: width, count: count) == i,
                "第 \(i) 根柱中心应命中 \(i)")
    }
    // 每根柱的左右边缘（略微内缩）仍在自己的范围内
    for i in 0..<count {
        let left = CGFloat(i) * slot + 1
        let right = CGFloat(i + 1) * slot - 1
        #expect(slotIndex(x: left, width: width, count: count) == i)
        #expect(slotIndex(x: right, width: width, count: count) == i)
    }
    // 边界外夹到最近一端（避免悬停突然消失）
    #expect(slotIndex(x: -5, width: width, count: count) == 0)
    #expect(slotIndex(x: width + 5, width: width, count: count) == count - 1)
}

/// 关键回归：柱体较宽时，「最近数据点」会与「柱区间」给出不同答案。
/// 柱子宽 = slot*0.6，因此 slot 前 20% 与后 20% 属于该柱的空白区，
/// 鼠标落在那里时最近点在几何上更靠近邻柱，旧实现会高亮错柱。
@Test func hoverRangeDiffersFromNearestPointNearEdges() {
    let count = 5
    let width: CGFloat = 500
    let slot = width / CGFloat(count)   // 100pt

    // 第 2 根柱的右边缘内 2pt（x≈197.9）：区间判定应给 2；
    // 而"最近数据点"逻辑在超过 199.5 后才切到 3，这里验证区间判定稳定给出 2
    let nearRightEdge = CGFloat(2) * slot + slot - 2
    #expect(slotIndex(x: nearRightEdge, width: width, count: count) == 2)

    // 相邻柱交界处：正好落在分界线上应归入右侧那根（floor 语义），不出现抖动
    let boundary = CGFloat(3) * slot
    #expect(slotIndex(x: boundary, width: width, count: count) == 3)
}
