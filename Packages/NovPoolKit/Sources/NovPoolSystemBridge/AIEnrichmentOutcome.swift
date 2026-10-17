import Foundation
import NovPoolCore

/// AI 结构化增强的显式结果（成功或带可读原因的失败）。
public enum AIEnrichmentOutcome: Sendable, Equatable {
    case success(AIEnrichment)
    case failure(String)

    public var enrichment: AIEnrichment? {
        if case .success(let value) = self { return value }
        return nil
    }

    public var failureReason: String? {
        if case .failure(let reason) = self { return reason }
        return nil
    }
}
