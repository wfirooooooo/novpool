import Foundation
import NovPoolCore

/// Explicit results of AI-structured enhancement (success or failure with readable reasons).
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
