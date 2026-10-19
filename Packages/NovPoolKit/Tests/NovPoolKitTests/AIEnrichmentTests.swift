import Foundation
import NovPoolCore
import Testing
@testable import NovPoolSystemBridge

@Suite("AI Structured Enhancement")
struct AIEnrichmentTests {
    private let categories = ["Technology", "Product", "Reading"]

    // MARK: - Prompt

    @Test("System Prompt include Topic category tree, tag limit, and JSON structure")
    func systemPromptContent() {
        let prompt = AIEnrichmentPrompt.systemPrompt(categories: categories, maxTags: 4, maxSummaryCharacters: 80)
        #expect(prompt.contains("Technology, Product, Reading"))
        #expect(prompt.contains("content topic"))
        #expect(prompt.contains("at most 80 characters"))
        #expect(prompt.contains("1–4 refined labels"))
        #expect(prompt.contains("\"summary\""))
        #expect(prompt.contains("never use the resource kind"))
        #expect(prompt.contains("Uncategorized"))
    }

    @Test("When the category tree is not configured, it is required to classify by subject and prohibit format names")
    func systemPromptWithoutCategories() {
        let prompt = AIEnrichmentPrompt.systemPrompt(categories: [], maxTags: 5, maxSummaryCharacters: 100)
        #expect(prompt.contains("topic/domain label"))
        #expect(prompt.contains("do not use format names like Web, Image"))
        #expect(prompt.contains("File, Link, or Text"))
    }

    @Test("User Prompt Truncate Body and Include Source")
    func userPromptTruncation() {
        let request = AIEnrichmentRequest(
            title: "Title",
            text: String(repeating: "A", count: 500),
            contentType: .webLink,
            sourceURL: URL(string: "https://example.com/a"),
            sourceTitle: "Source Title"
        )
        let prompt = AIEnrichmentPrompt.userPrompt(request, maxInputCharacters: 100)
        #expect(prompt.contains("Source: https://example.com/a"))
        let bodyOccurrences = prompt.components(separatedBy: "A").count - 1
        #expect(bodyOccurrences == 100)
    }

    // MARK: - Parse & normalize

    @Test("Parse standard JSON output")
    func parsesPlainJSON() throws {
        let raw = #"{"title":"New title","summary":"One-line summary","category":"Technology","tags":["swift","actor"]}"#
        let enrichment = try #require(AIEnrichmentParser.parse(raw, categories: categories))
        #expect(enrichment.title == "New title")
        #expect(enrichment.summary == "One-line summary")
        #expect(enrichment.category == "Technology")
        #expect(enrichment.tags == ["swift", "actor"])
    }

    @Test("Analyze the output with code block fences and explanations before and after")
    func parsesFencedJSON() {
        let raw = """
        Sure, here is the result:
        ```json
        {"summary": "Abstract content", "tags": ["a", "b"]}
        ```
        Hope this helps.
        """
        let enrichment = AIEnrichmentParser.parse(raw, categories: categories)
        #expect(enrichment?.summary == "Abstract content")
        #expect(enrichment?.tags == ["a", "b"])
    }

    @Test("Categories must fall within the preset topic tree; freely created categories will be discarded.")
    func categoryValidation() {
        let raw = #"{"summary":"Summary","category":"Astrology"}"#
        let enrichment = AIEnrichmentParser.parse(raw, categories: categories)
        #expect(enrichment?.category == nil)
        // For multiple selections, take the first matched preset topic
        let multi = #"{"summary":"Summary","category":"Technology / Programming"}"#
        #expect(AIEnrichmentParser.parse(multi, categories: categories)?.category == "Technology")
        // Retain subject name when category tree is not configured
        #expect(AIEnrichmentParser.parse(raw, categories: [])?.category == "Astrology")
    }

    @Test("File-type categories fall back to Uncategorized when a summary remains")
    func rejectsFormatAsCategory() {
        let asImage = #"{"summary":"Summary","category":"Image"}"#
        #expect(AIEnrichmentParser.parse(asImage, categories: [])?.category == AIEnrichmentQuality.uncategorized)
        let asPDF = #"{"summary":"Summary","category":"PDF"}"#
        #expect(AIEnrichmentParser.parse(asPDF, categories: [])?.category == AIEnrichmentQuality.uncategorized)
        let asWeb = #"{"summary":"Summary","category":"Web"}"#
        #expect(AIEnrichmentParser.parse(asWeb, categories: [])?.category == AIEnrichmentQuality.uncategorized)
        let asFilePhrase = #"{"summary":"Summary","category":"PDF file"}"#
        #expect(AIEnrichmentParser.parse(asFilePhrase, categories: [])?.category == AIEnrichmentQuality.uncategorized)
        let asPNG = #"{"summary":"Summary","category":"png"}"#
        #expect(AIEnrichmentParser.parse(asPNG, categories: [])?.category == AIEnrichmentQuality.uncategorized)
        // Even a topic tree that lists a format name must not store it.
        let inTree = #"{"summary":"Summary","category":"PDF"}"#
        #expect(AIEnrichmentParser.parse(inTree, categories: ["PDF", "Technology"])?.category == AIEnrichmentQuality.uncategorized)
        // Legacy Chinese format words remain rejected when still present in the denylist.
        let asImageZH = #"{"summary":"Summary","category":"图片"}"#
        #expect(AIEnrichmentParser.parse(asImageZH, categories: [])?.category == AIEnrichmentQuality.uncategorized)
        let asWebZH = #"{"summary":"Summary","category":"网页"}"#
        #expect(AIEnrichmentParser.parse(asWebZH, categories: [])?.category == AIEnrichmentQuality.uncategorized)
        let topic = #"{"summary":"Summary","category":"Design"}"#
        #expect(AIEnrichmentParser.parse(topic, categories: [])?.category == "Design")
        #expect(AIEnrichmentParser.parse(#"{"category":"pdf"}"#, categories: []) == nil)
        #expect(AIEnrichmentParser.rejectionReason(for: #"{"category":"pdf"}"#) == AIEnrichmentQuality.fileTypeCategoryReason)
    }

    @Test("Remove duplicate tags, remove # symbols, limit length and quantity, also accepts comma-separated strings")
    func tagNormalization() {
        // Note: #swift tags with quotes cannot be written inside #"..."# raw strings (# will terminate it early).
        let raw = "{\"summary\":\"Summary\",\"tags\":[\"#swift\",\"Swift\",\" swift \",\"actor\",\"\",\"a\",\"b\",\"c\"]}"
        let tags = AIEnrichmentParser.parse(raw, categories: categories, maxTags: 4)?.tags
        #expect(tags == ["swift", "actor", "a", "b"])

        let asString = #"{"summary":"Summary","tags":"alpha, beta,gamma"}"#
        #expect(AIEnrichmentParser.parse(asString, categories: categories)?.tags == ["alpha", "beta", "gamma"])

        let noisy = #"{"summary":"Summary","tags":["swift","!!!","---","***","C++","swift"]}"#
        #expect(AIEnrichmentParser.parse(noisy, categories: categories)?.tags == ["swift", "C++"])
    }

    @Test("The abstract is truncated at the maximum length and an ellipsis is added")
    func summaryClamping() {
        let long = String(repeating: "x", count: 300)
        let raw = #"{"summary":"\#(long)"}"#
        let summary = AIEnrichmentParser.parse(raw, categories: categories, maxSummaryCharacters: 50)?.summary
        #expect(summary?.count == 50)
        #expect(summary?.hasSuffix("…") == true)
    }

    @Test("No valid fields or illegal JSON returns nil")
    func invalidOutputs() {
        #expect(AIEnrichmentParser.parse("Completely not JSON", categories: categories) == nil)
        #expect(AIEnrichmentParser.parse("{}", categories: categories) == nil)
        #expect(AIEnrichmentParser.parse(#"{"summary":""}"#, categories: categories) == nil)
        #expect(AIEnrichmentParser.parse(#"{"summary":{"nested":1}}"#, categories: categories) == nil)
    }

    @Test("When JSON contains curly brace strings, the end position will not be misjudged")
    func braceInsideString() {
        let raw = #"{"summary":"Writing the function as { key: value } is fine too","tags":["json"]}"#
        let summary = AIEnrichmentParser.parse(raw, categories: categories)?.summary
        #expect(summary?.contains("{ key: value }") == true)
    }

    // MARK: - Service

    @Test("Service connects completion, parsing, and embedding")
    func servicePipeline() async throws {
        let completer = FakeCompleter(output: #"{"summary":"On-device OCR summary","category":"Technology","tags":["OCR"]}"#)
        let embedder = FakeEmbedder(vector: [0.1, 0.2, 0.3])
        let service = AIEnhancementService(completer: completer, embedder: embedder)

        let enrichment = try #require(await service.enrich(Self.request(categories: categories)))
        #expect(enrichment.summary == "On-device OCR summary")
        #expect(enrichment.tags == ["OCR"])
        #expect(enrichment.embedding == [0.1, 0.2, 0.3])
        #expect(await completer.calls == 1)
        #expect(await embedder.lastInput?.contains("On-device OCR summary") == true)
    }

    @Test("Service is directly skipped when the model is not configured")
    func serviceDisabledWithoutCompleter() async {
        let service = AIEnhancementService(completer: nil, embedder: FakeEmbedder(vector: [1]))
        #expect(await service.isEnabled == false)
        #expect(await service.enrich(Self.request(categories: [])) == nil)
        if case .failure(let reason) = await service.enrichDetailed(Self.request(categories: [])) {
            #expect(reason.contains("No usable chat model configured"))
        } else {
            Issue.record("Expected failure reason when no model is configured")
        }
    }

    @Test("After hot-swapping the completer, it can immediately summarize without rebuilding the service")
    func updateProvidersHotSwap() async throws {
        let service = AIEnhancementService(completer: nil, embedder: FakeEmbedder(vector: [1]))
        #expect(await service.isEnabled == false)

        let completer = FakeCompleter(output: #"{"summary":"Hot-swap summary","category":"Technology","tags":["hot"]}"#)
        await service.updateProviders(
            completer: completer,
            embedder: FakeEmbedder(vector: [0.5]),
            configuration: .init(isEnabled: true, categories: categories)
        )
        #expect(await service.isEnabled == true)
        let enrichment = try #require(await service.enrich(Self.request(categories: categories)))
        #expect(enrichment.summary == "Hot-swap summary")
        #expect(await completer.calls == 1)
    }

    @Test("A file-type category with no summary fails with a readable reason and does not invent tags")
    func fileTypeCategoryWithoutSummary() async {
        let completer = FakeCompleter(output: #"{"category":"image"}"#)
        let service = AIEnhancementService(completer: completer, embedder: nil)
        if case .failure(let reason) = await service.enrichDetailed(Self.request(categories: [])) {
            #expect(reason == AIEnrichmentQuality.fileTypeCategoryReason)
        } else {
            Issue.record("Expected a file-type category failure")
        }
        #expect(await completer.calls == 1)
    }

    @Test("Settings copy names the summarize route and does not include a secret")
    func summarizeRouteCopy() {
        let llama = SummarizeRouteExplanation.text(kind: .localLlama, prefersChinese: false)
        let ollama = SummarizeRouteExplanation.text(kind: .ollama, prefersChinese: false)
        let compatible = SummarizeRouteExplanation.text(kind: .openAICompatible, prefersChinese: false)
        #expect(llama.contains("llama.cpp"))
        #expect(ollama.contains("Ollama"))
        #expect(compatible.contains("OpenAI-compatible"))
        #expect(compatible.contains("Keychain"))
        #expect(!compatible.contains("sk-"))
        #expect(SummarizeRouteExplanation.text(kind: .off, prefersChinese: true).contains("摘要已关闭"))
    }

    @Test("Return nil when the model reports an error, and provide a readable reason for the failure")
    func serviceSurvivesFailure() async {
        let completer = FakeCompleter(output: "", shouldFail: true)
        let service = AIEnhancementService(completer: completer, embedder: FakeEmbedder(vector: [1]))
        #expect(await service.enrich(Self.request(categories: categories)) == nil)
        if case .failure(let reason) = await service.enrichDetailed(Self.request(categories: categories)) {
            #expect(reason.contains("Model request failed"))
        } else {
            Issue.record("Expected failure reason when the model request fails")
        }
    }

    @Test("Embedding failure does not affect summaries and tags")
    func embeddingFailureIsolated() async throws {
        let completer = FakeCompleter(output: #"{"summary":"Summary","tags":["t"]}"#)
        let embedder = FakeEmbedder(vector: nil, shouldFail: true)
        let service = AIEnhancementService(completer: completer, embedder: embedder)
        let enrichment = try #require(await service.enrich(Self.request(categories: categories)))
        #expect(enrichment.summary == "Summary")
        #expect(enrichment.embedding == nil)
    }

    @Test("After closing the enhancement switch, the model is no longer called")
    func configurationSwitch() async {
        let completer = FakeCompleter(output: #"{"summary":"Summary"}"#)
        let service = AIEnhancementService(
            completer: completer,
            embedder: nil,
            configuration: .init(isEnabled: false)
        )
        #expect(await service.enrich(Self.request(categories: [])) == nil)
        #expect(await completer.calls == 0)
    }

    static func request(categories: [String]) -> AIEnrichmentRequest {
        AIEnrichmentRequest(
            title: "Screenshot entry",
            text: "Apple Neural Engine Neural Network Accelerated OCR Text",
            contentType: .image,
            sourceURL: URL(string: "https://example.com/a"),
            sourceTitle: "Sample Page",
            categories: categories
        )
    }

    // MARK: - Provider line format

    @Test("Ollama Client: Restricted Decoding Request Body + Response Parsing")
    func ollamaWireFormat() async throws {
        let response = #"{"message":{"role":"assistant","content":"{\"summary\":\"Summary\"}"}}"#
        let transport = StubTransport(responses: [
            HTTPPayload(statusCode: 200, headers: [:], body: Data(response.utf8)),
        ])
        let client = OllamaClient(
            configuration: .init(baseURL: URL(string: "http://127.0.0.1:11434")!),
            transport: transport
        )

        let content = try await client.completeJSON(systemPrompt: "sys", userPrompt: "usr")
        #expect(content == #"{"summary":"Summary"}"#)

        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "http://127.0.0.1:11434/api/chat")
        #expect(request.httpMethod == "POST")
        let body = try #require(request.httpBody)
        let json = try #require((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])
        #expect(json["format"] as? String == "json")
        #expect(json["stream"] as? Bool == false)
        #expect((json["messages"] as? [[String: Any]])?.count == 2)
    }

    @Test("OpenAI compatible client: carry the authentication header and parse choices")
    func openAIWireFormat() async throws {
        let response = #"{"choices":[{"message":{"role":"assistant","content":"{\"summary\":\"S\"}"}}]}"#
        let transport = StubTransport(responses: [
            HTTPPayload(statusCode: 200, headers: [:], body: Data(response.utf8)),
        ])
        let client = OpenAICompatibleClient(
            configuration: .init(
                baseURL: URL(string: "https://api.openai.com/v1")!,
                apiKey: "sk-test",
                chatModel: "gpt-4o-mini"
            ),
            transport: transport
        )

        let content = try await client.completeJSON(systemPrompt: "s", userPrompt: "u")
        #expect(content == #"{"summary":"S"}"#)

        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let body = try #require(request.httpBody)
        let json = try #require((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])
        #expect((json["response_format"] as? [String: Any])?["type"] as? String == "json_object")
    }

    @Test("OpenAI Embedding API Analysis data[0].embedding")
    func openAIEmbedding() async throws {
        let response = #"{"data":[{"embedding":[0.5,0.25,-0.125]}]}"#
        let transport = StubTransport(responses: [
            HTTPPayload(statusCode: 200, headers: [:], body: Data(response.utf8)),
        ])
        let client = OpenAICompatibleClient(
            configuration: .init(apiKey: "sk", embeddingModel: "text-embedding-3-small"),
            transport: transport
        )
        #expect(try await client.embed("Text") == [0.5, 0.25, -0.125])
        #expect(transport.requests.first?.url?.absoluteString == "https://api.openai.com/v1/embeddings")
    }

    @Test("Throw an error when the interface returns a non-2xx status, and let the upper layer catch it on a best-effort basis")
    func providerHTTPError() async {
        let transport = StubTransport(responses: [
            HTTPPayload(statusCode: 429, headers: [:], body: Data()),
        ])
        let client = OllamaClient(transport: transport)
        await #expect(throws: NovPoolError.self) {
            _ = try await client.completeJSON(systemPrompt: "s", userPrompt: "u")
        }
    }

    @Test("Embedding fallback chain: automatically use the backup channel when the main channel fails")
    func embeddingChain() async throws {
        let failing = FakeEmbeddingProvider(vector: nil, shouldFail: true)
        let fallback = FakeEmbeddingProvider(vector: [1, 2, 3])
        let chain = ChainedEmbeddingProvider(providers: [failing, fallback])
        #expect(try await chain.embed("Text") == [1, 2, 3])

        let allFailing = ChainedEmbeddingProvider(providers: [failing])
        #expect(try await allFailing.embed("Text") == nil)
        #expect(try await ChainedEmbeddingProvider(providers: []).embed("Text") == nil)
    }
}

/// Simple embedding substitute, for rollback chain testing use.
struct FakeEmbeddingProvider: EmbeddingProviding {
    struct Failure: Error {}
    var vector: [Float]?
    var shouldFail = false

    func embed(_ text: String) async throws -> [Float]? {
        if shouldFail { throw Failure() }
        return vector
    }
}

/// LLM completes the stand-in.
final class FakeCompleter: LLMCompleting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded = 0
    private let output: String
    private let shouldFail: Bool

    init(output: String, shouldFail: Bool = false) {
        self.output = output
        self.shouldFail = shouldFail
    }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func completeJSON(systemPrompt: String, userPrompt: String) async throws -> String {
        bumpCount()
        if shouldFail { throw NovPoolError.notImplemented("Model not available") }
        return output
    }

    /// Synchronous locking helper: `NSLock.lock()` is marked as unavailable in async contexts.
    private func bumpCount() {
        lock.lock()
        recorded += 1
        lock.unlock()
    }
}

/// Embedding-based substitute.
actor FakeEmbedder: EmbeddingProviding {
    private(set) var lastInput: String?
    private let vector: [Float]?
    private let shouldFail: Bool

    init(vector: [Float]?, shouldFail: Bool = false) {
        self.vector = vector
        self.shouldFail = shouldFail
    }

    func embed(_ text: String) async throws -> [Float]? {
        lastInput = text
        if shouldFail { throw NovPoolError.notImplemented("EmbeddingService Unavailable") }
        return vector
    }
}
