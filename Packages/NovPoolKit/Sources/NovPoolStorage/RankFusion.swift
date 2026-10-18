import Foundation

/// Reciprocal Rank Fusion (RRF).
///
/// Full-text search (BM25 scale) and embedding similarity (cosine scale) cannot be directly added; RRF only uses "rank".
/// Therefore, the natural immunity dimensional difference: `score = Σ 1 / (k + rank)`, the larger the `k`, the more it weakens the head advantage.
public enum RankFusion {
    /// Values commonly used in the industry, with priors coming from Cormack and others' RRF paper.
    public static let defaultK = 60

    /// Merge multiple sorting results and return id → score.
    ///
    /// When the same ID appears in multiple paths, the scores will accumulate (this is precisely the effect of RRF:
    /// Entries that rank high in both categories will significantly stand out.
    public static func fuse(_ rankings: [[UUID]], k: Int = RankFusion.defaultK) -> [UUID: Double] {
        var scores: [UUID: Double] = [:]
        for ranking in rankings {
            for (index, id) in ranking.enumerated() {
                scores[id, default: 0] += 1.0 / Double(k + index + 1)
            }
        }
        return scores
    }

    /// Output the IDs in descending order of fusion score; if the scores are the same, maintain the original order of appearance.
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
