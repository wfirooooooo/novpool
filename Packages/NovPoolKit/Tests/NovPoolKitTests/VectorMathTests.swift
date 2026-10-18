import Foundation
import Testing
@testable import NovPoolStorage

@Suite("Accelerate Embedding operation")
struct VectorMathTests {
    @Test("Cosine similarity: 1 for same direction, 0 for orthogonal, -1 for opposite direction")
    func cosineBasics() {
        #expect(abs(VectorMath.cosineSimilarity([1, 2, 3], [2, 4, 6]) - 1) < 1e-6)
        #expect(abs(VectorMath.cosineSimilarity([1, 0], [0, 1])) < 1e-6)
        #expect(abs(VectorMath.cosineSimilarity([1, 0], [-1, 0]) + 1) < 1e-6)
    }

    @Test("Return 0 for inconsistent dimensions or empty embeddings, without crashing")
    func degenerateInputs() {
        #expect(VectorMath.cosineSimilarity([1, 2, 3], [1, 2]) == 0)
        #expect(VectorMath.cosineSimilarity([], []) == 0)
        #expect(VectorMath.cosineSimilarity([0, 0], [0, 0]) == 0)
    }

    @Test("Lossless round-trip encoding and decoding of Float arrays")
    func encodeDecodeRoundTrip() {
        let vector: [Float] = [0.5, -1.25, 3.75, 1e-8]
        let restored = VectorMath.decode(VectorMath.encode(vector))
        #expect(restored == vector)
        #expect(VectorMath.encode(vector).count == vector.count * MemoryLayout<Float>.size)
    }
}
