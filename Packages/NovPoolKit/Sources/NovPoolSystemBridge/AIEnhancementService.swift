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

    /// 设置保存或本机模型启停后热切换，无需重启进程。
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
            return .failure("AI 增强已关闭（设置 → 检索与 AI）")
        }
        guard let completer else {
            return .failure("未配置可用的对话模型（Ollama / OpenAI 兼容 / 本机 llama-server）")
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
                return .failure("模型返回无法解析为摘要 JSON")
            }
        } catch {
            return .failure("模型请求失败：\(error.localizedDescription)")
        }

        guard var result = enrichment else {
            return .failure("模型返回无法解析为摘要 JSON")
        }
        result.embedding = await embedding(for: request, enrichment: result)
        return .success(result)
    }

    /// best-effort：失败时返回 `nil`（入库主路径不阻塞）。
    public func enrich(_ request: AIEnrichmentRequest) async -> AIEnrichment? {
        await enrichDetailed(request).enrichment
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
