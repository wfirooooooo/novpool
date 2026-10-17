import Foundation
import Testing
@testable import NovPoolStorage

@Suite("Accelerate 向量运算")
struct VectorMathTests {
    @Test("余弦相似度：同向为 1，正交为 0，反向为 -1")
    func cosineBasics() {
        #expect(abs(VectorMath.cosineSimilarity([1, 2, 3], [2, 4, 6]) - 1) < 1e-6)
        #expect(abs(VectorMath.cosineSimilarity([1, 0], [0, 1])) < 1e-6)
        #expect(abs(VectorMath.cosineSimilarity([1, 0], [-1, 0]) + 1) < 1e-6)
    }

    @Test("维度不一致或空向量返回 0，不崩溃")
    func degenerateInputs() {
        #expect(VectorMath.cosineSimilarity([1, 2, 3], [1, 2]) == 0)
        #expect(VectorMath.cosineSimilarity([], []) == 0)
        #expect(VectorMath.cosineSimilarity([0, 0], [0, 0]) == 0)
    }

    @Test("Float 数组编解码往返无损")
    func encodeDecodeRoundTrip() {
        let vector: [Float] = [0.5, -1.25, 3.75, 1e-8]
        let restored = VectorMath.decode(VectorMath.encode(vector))
        #expect(restored == vector)
        #expect(VectorMath.encode(vector).count == vector.count * MemoryLayout<Float>.size)
    }
}
