import Foundation

/// Reciprocal Rank Fusion（RRF）。
///
/// 全文检索（BM25 量纲）与向量相似度（余弦量纲）不可直接相加，RRF 只使用「名次」，
/// 因此天然免疫量纲差异：`score = Σ 1 / (k + rank)`，`k` 越大越削弱头部优势。
public enum RankFusion {
    /// 业界常用取值，先验来自 Cormack 等人的 RRF 论文。
    public static let defaultK = 60

    /// 融合多路排序结果，返回 id → 分数。
    ///
    /// 同一个 id 在多路中都出现时会累加分数（这正是 RRF 的效果：
    /// 两路排名都靠前的条目会显著胜出）。
    public static func fuse(_ rankings: [[UUID]], k: Int = RankFusion.defaultK) -> [UUID: Double] {
        var scores: [UUID: Double] = [:]
        for ranking in rankings {
            for (index, id) in ranking.enumerated() {
                scores[id, default: 0] += 1.0 / Double(k + index + 1)
            }
        }
        return scores
    }

    /// 按融合分数降序输出 id；分数相同则按原始出现顺序稳定排列。
    public static func ranked(_ rankings: [[UUID]], k: Int = RankFusion.defaultK) -> [UUID] {
        let scores = fuse(rankings, k: k)
        var order: [UUID: Int] = [:]
        for ranking in rankings {
            for id in ranking where order[id] == nil {
                order[id] = order.count
            }
        }
        return scores.keys.sorted { lhs, rhs in
            let left = scores[lhs] ?? 0
            let right = scores[rhs] ?? 0
            if left == right { return (order[lhs] ?? 0) < (order[rhs] ?? 0) }
            return left > right
        }
    }
}
