import Foundation
import NovPoolCore

/// 结构化增强服务（摘要、分类、标签、向量）。
///
/// best-effort 设计：模型不可用、超时或输出不合规时一律返回 `nil`，
/// 绝不阻塞或污染已经落库的原始条目。
public actor AIEnhancementService {
    public struct Configuration: Sendable {
        public var isEnabled: Bool
        public var categories: [String]
        public var maxTags: Int
        public var maxSummaryCharacters: Int
        public var maxInputCharacters: Int
        /// 是否把标题 + 摘要送去向量化（比整篇正文更省 token，语义也足够）。
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

    private let completer: (any LLMCompleting)?
    private let embedder: (any EmbeddingProviding)?
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

    public func enrich(_ request: AIEnrichmentRequest) async -> AIEnrichment? {
        guard configuration.isEnabled, let completer else { return nil }

        let systemPrompt = AIEnrichmentPrompt.systemPrompt(
            categories: configuration.categories,
            maxTags: configuration.maxTags,
            maxSummaryCharacters: configuration.maxSummaryCharacters
        )
        let userPrompt = AIEnrichmentPrompt.userPrompt(
            request,
            maxInputCharacters: configuration.maxInputCharacters
        )

        var enrichment: AIEnrichment?
        do {
            let raw = try await completer.completeJSON(systemPrompt: systemPrompt, userPrompt: userPrompt)
            enrichment = AIEnrichmentParser.parse(
                raw,
                categories: configuration.categories,
                maxTags: configuration.maxTags,
                maxSummaryCharacters: configuration.maxSummaryCharacters
            )
        } catch {
            enrichment = nil
        }

        guard var result = enrichment else { return nil }
        result.embedding = await embedding(for: request, enrichment: result)
        return result
    }

    private func embedding(for request: AIEnrichmentRequest, enrichment: AIEnrichment) async -> [Float]? {
        guard let embedder else { return nil }
        let text: String
        if configuration.embedSummaryOnly {
            let summaryText = [enrichment.title ?? request.title, enrichment.summary]
                .compactMap { $0 }
                .joined(separator: "。")
            text = summaryText.isEmpty ? String(request.text.prefix(1_000)) : summaryText
        } else {
            text = String(request.text.prefix(configuration.maxInputCharacters))
        }
        // 向量化失败不影响摘要/标签的落库。
        return (try? await embedder.embed(text)) ?? nil
    }
}
