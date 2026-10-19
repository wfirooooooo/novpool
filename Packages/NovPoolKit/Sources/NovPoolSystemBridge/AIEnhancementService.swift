import Foundation
import NovPoolCore

/// Structured enhancement services (summary, classification, tagging, embedding).
///
/// Best-effort design: If the model is unavailable, times out, or produces non-compliant output, it always returns `nil`.
/// Never block or pollute raw entries that have already been stored in the database.
public actor AIEnhancementService {
    public struct Configuration: Sendable {
        public var isEnabled: Bool
        public var categories: [String]
        public var maxTags: Int
        public var maxSummaryCharacters: Int
        public var maxInputCharacters: Int
        /// Whether to send the title + abstract for embedding (saves tokens compared to the entire body, and the semantics are sufficient).
        public var embedSummaryOnly: Bool

        public init(
            isEnabled: Bool = true,
            categories: [String] = [],
            maxTags: Int = 5,
            maxSummaryCharacters: Int = 100,
            maxInputCharacters: Int = 8_000,
            embedSummaryOnly: Bool = true
        ) {
            self.isEnabled = isEnabled
            self.categories = categories
            self.maxTags = maxTags
            self.maxSummaryCharacters = maxSummaryCharacters
            self.maxInputCharacters = maxInputCharacters
            self.embedSummaryOnly = embedSummaryOnly
        }
    }

    private var completer: (any LLMCompleting)?
    private var embedder: (any EmbeddingProviding)?
    private var configuration: Configuration

    public init(
        completer: (any LLMCompleting)? = nil,
        embedder: (any EmbeddingProviding)? = NaturalLanguageEmbeddingProvider(),
        configuration: Configuration = Configuration()
    ) {
        self.completer = completer
        self.embedder = embedder
        self.configuration = configuration
    }

    public var isEnabled: Bool { configuration.isEnabled && completer != nil }

    public func update(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Set Save or local model start/stop for hot switching, without needing to restart the process.
    public func updateProviders(
        completer: (any LLMCompleting)?,
        embedder: (any EmbeddingProviding)?,
        configuration: Configuration? = nil
    ) {
        self.completer = completer
        self.embedder = embedder
        if let configuration {
            self.configuration = configuration
        }
    }

    public func enrichDetailed(_ request: AIEnrichmentRequest) async -> AIEnrichmentOutcome {
        guard configuration.isEnabled else {
            return .failure("AI enrichment is off (Settings → Search & AI)")
        }
        guard let completer else {
            return .failure("No usable chat model configured (Ollama / OpenAI-compatible / local llama-server)")
        }

        let systemPrompt = AIEnrichmentPrompt.systemPrompt(
            categories: configuration.categories,
            maxTags: configuration.maxTags,
            maxSummaryCharacters: configuration.maxSummaryCharacters
        )
        let userPrompt = AIEnrichmentPrompt.userPrompt(
            request,
            maxInputCharacters: configuration.maxInputCharacters
        )

        let enrichment: AIEnrichment?
        do {
            let raw = try await completer.completeJSON(systemPrompt: systemPrompt, userPrompt: userPrompt)
            enrichment = AIEnrichmentParser.parse(
                raw,
                categories: configuration.categories,
                maxTags: configuration.maxTags,
                maxSummaryCharacters: configuration.maxSummaryCharacters
            )
            if enrichment == nil {
                let reason = AIEnrichmentParser.rejectionReason(for: raw)
                    ?? "Model response could not be parsed as summary JSON"
                return .failure(reason)
            }
        } catch {
            return .failure("Model request failed: \(error.localizedDescription)")
        }

        guard var result = enrichment else {
            return .failure("Model response could not be parsed as summary JSON")
        }
        result = AIEnrichmentQuality.sanitize(
            result,
            maxTags: configuration.maxTags
        )
        result.embedding = await embedding(for: request, enrichment: result)
        return .success(result)
    }

    /// best-effort: returns `nil` on failure (does not block the main storage path).
    public func enrich(_ request: AIEnrichmentRequest) async -> AIEnrichment? {
        await enrichDetailed(request).enrichment
    }

    /// Generate one cross-item digest through the same configured chat backend as item summaries.
    public func digest(_ sources: [DigestSource], maxInputCharacters: Int = 12_000) async -> DigestOutcome {
        guard configuration.isEnabled else {
            return .failure("AI enrichment is off (Settings → Search & AI)")
        }
        guard let completer else {
            return .failure("No usable chat model configured (Ollama / OpenAI-compatible / local llama-server)")
        }
        guard !sources.isEmpty else {
            return .failure("No items selected for digest")
        }

        do {
            let raw = try await completer.completeJSON(
                systemPrompt: DigestPrompt.systemPrompt,
                userPrompt: DigestPrompt.userPrompt(sources: sources, maxInputCharacters: maxInputCharacters)
            )
            guard let draft = DigestParser.parse(raw, sources: sources) else {
                return .failure("Model response could not be parsed as a digest")
            }
            return .success(draft)
        } catch {
            return .failure("Model request failed: \(error.localizedDescription)")
        }
    }

    private func embedding(for request: AIEnrichmentRequest, enrichment: AIEnrichment) async -> [Float]? {
        guard let embedder else { return nil }
        let text: String
        if configuration.embedSummaryOnly {
            let summaryText = [enrichment.title ?? request.title, enrichment.summary]
                .compactMap { $0 }
                .joined(separator: ". ")
            text = summaryText.isEmpty ? String(request.text.prefix(1_000)) : summaryText
        } else {
            text = String(request.text.prefix(configuration.maxInputCharacters))
        }
        // Embedding failure does not affect the storage of summaries/tags.
        return (try? await embedder.embed(text)) ?? nil
    }
}
