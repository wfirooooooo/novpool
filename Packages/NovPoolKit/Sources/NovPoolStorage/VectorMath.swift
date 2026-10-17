import Accelerate
import Foundation

/// Apple Silicon 硬件加速向量运算（Accelerate / vDSP）。
public enum VectorMath {
    /// 余弦相似度。维度不一致或空向量返回 0。
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        let n = vDSP_Length(a.count)

        vDSP_dotpr(a, 1, b, 1, &dotProduct, n)
        vDSP_svesq(a, 1, &normA, n)
        vDSP_svesq(b, 1, &normB, n)

        let denominator = sqrt(normA) * sqrt(normB)
        return denominator > 0 ? dotProduct / denominator : 0
    }

    /// `[Float]` → 连续内存字节，用于写入 `embeddingBlob` 列。
    public static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// `embeddingBlob` → `[Float]`。
    public static func decode(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self).prefix(count))
        }
    }
}
