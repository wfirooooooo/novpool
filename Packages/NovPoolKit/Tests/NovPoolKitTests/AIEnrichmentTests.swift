import Foundation
import NovPoolCore
import Testing
@testable import NovPoolSystemBridge

@Suite("AI 结构化增强")
struct AIEnrichmentTests {
    private let categories = ["技术", "产品", "阅读"]

    // MARK: - Prompt

    @Test("System Prompt 带上分类树、标签上限与 JSON 形状")
    func systemPromptContent() {
        let prompt = AIEnrichmentPrompt.systemPrompt(categories: categories, maxTags: 4, maxSummaryCharacters: 80)
        #expect(prompt.contains("技术、产品、阅读"))
        #expect(prompt.contains("不超过 80 字"))
        #expect(prompt.contains("1～4 个精炼标签"))
        #expect(prompt.contains("\"summary\""))
    }

    @Test("未配置分类树时允许自由分类")
    func systemPromptWithoutCategories() {
        let prompt = AIEnrichmentPrompt.systemPrompt(categories: [], maxTags: 5, maxSummaryCharacters: 100)
        #expect(prompt.contains("简洁的中文分类名"))
    }

    @Test("User Prompt 截断正文并带上来源")
    func userPromptTruncation() {
        let request = AIEnrichmentRequest(
            title: "标题",
            text: String(repeating: "甲", count: 500),
            contentType: .webLink,
            sourceURL: URL(string: "https://example.com/a"),
            sourceTitle: "来源标题"
        )
        let prompt = AIEnrichmentPrompt.userPrompt(request, maxInputCharacters: 100)
        #expect(prompt.contains("来源：https://example.com/a"))
        let bodyOccurrences = prompt.components(separatedBy: "甲").count - 1
        #expect(bodyOccurrences == 100)
    }

    // MARK: - 解析与归一化

    @Test("解析标准 JSON 输出")
    func parsesPlainJSON() throws {
        let raw = #"{"title":"新标题","summary":"一句话摘要","category":"技术","tags":["swift","actor"]}"#
        let enrichment = try #require(AIEnrichmentParser.parse(raw, categories: categories))
        #expect(enrichment.title == "新标题")
        #expect(enrichment.summary == "一句话摘要")
        #expect(enrichment.category == "技术")
        #expect(enrichment.tags == ["swift", "actor"])
    }

    @Test("解析带代码块围栏与前后解释的输出")
    func parsesFencedJSON() {
        let raw = """
        好的，这是结果：
        ```json
        {"summary": "摘要内容", "tags": ["a", "b"]}
        ```
        希望有帮助。
        """
        let enrichment = AIEnrichmentParser.parse(raw, categories: categories)
        #expect(enrichment?.summary == "摘要内容")
        #expect(enrichment?.tags == ["a", "b"])
    }

    @Test("分类必须落在预设分类树内，自由发挥的分类被丢弃")
    func categoryValidation() {
        let raw = #"{"summary":"摘要","category":"玄学"}"#
        let enrichment = AIEnrichmentParser.parse(raw, categories: categories)
        #expect(enrichment?.category == nil)
        // 多选输出取第一个命中项
        let multi = #"{"summary":"摘要","category":"技术 / 编程"}"#
        #expect(AIEnrichmentParser.parse(multi, categories: categories)?.category == "技术")
        // 未配置分类树时保留原样
        #expect(AIEnrichmentParser.parse(raw, categories: [])?.category == "玄学")
    }

    @Test("标签去重、去 # 号、限长限量，也接受逗号分隔字符串")
    func tagNormalization() {
        // 注意：#swift 这类带引号的标签不能写进 #"..."# 原始字符串（"# 会提前终止它）。
        let raw = "{\"summary\":\"摘要\",\"tags\":[\"#swift\",\"Swift\",\" swift \",\"actor\",\"\",\"a\",\"b\",\"c\"]}"
        let tags = AIEnrichmentParser.parse(raw, categories: categories, maxTags: 4)?.tags
        #expect(tags == ["swift", "actor", "a", "b"])

        let asString = #"{"summary":"摘要","tags":"alpha, beta、gamma"}"#
        #expect(AIEnrichmentParser.parse(asString, categories: categories)?.tags == ["alpha", "beta", "gamma"])
    }

    @Test("摘要超长按上限截断并加省略号")
    func summaryClamping() {
        let long = String(repeating: "字", count: 300)
        let raw = #"{"summary":"\#(long)"}"#
        let summary = AIEnrichmentParser.parse(raw, categories: categories, maxSummaryCharacters: 50)?.summary
        #expect(summary?.count == 50)
        #expect(summary?.hasSuffix("…") == true)
    }

    @Test("无有效字段或非法 JSON 返回 nil")
    func invalidOutputs() {
        #expect(AIEnrichmentParser.parse("完全不是 JSON", categories: categories) == nil)
        #expect(AIEnrichmentParser.parse("{}", categories: categories) == nil)
        #expect(AIEnrichmentParser.parse(#"{"summary":""}"#, categories: categories) == nil)
        #expect(AIEnrichmentParser.parse(#"{"summary":{"nested":1}}"#, categories: categories) == nil)
    }

    @Test("JSON 里包含花括号字符串时不会误判结束位置")
    func braceInsideString() {
        let raw = #"{"summary":"函数写成 { key: value } 也不错","tags":["json"]}"#
        let summary = AIEnrichmentParser.parse(raw, categories: categories)?.summary
        #expect(summary?.contains("{ key: value }") == true)
    }

    // MARK: - 服务

    @Test("服务串起补全、解析与向量化")
    func servicePipeline() async throws {
        let completer = FakeCompleter(output: #"{"summary":"端侧 OCR 摘要","category":"技术","tags":["OCR"]}"#)
        let embedder = FakeEmbedder(vector: [0.1, 0.2, 0.3])
        let service = AIEnhancementService(completer: completer, embedder: embedder)

        let enrichment = try #require(await service.enrich(Self.request(categories: categories)))
        #expect(enrichment.summary == "端侧 OCR 摘要")
        #expect(enrichment.tags == ["OCR"])
        #expect(enrichment.embedding == [0.1, 0.2, 0.3])
        #expect(await completer.calls == 1)
        #expect(await embedder.lastInput?.contains("端侧 OCR 摘要") == true)
    }

    @Test("未配置模型时服务直接跳过")
    func serviceDisabledWithoutCompleter() async {
        let service = AIEnhancementService(completer: nil, embedder: FakeEmbedder(vector: [1]))
        #expect(await service.isEnabled == false)
        #expect(await service.enrich(Self.request(categories: [])) == nil)
        if case .failure(let reason) = await service.enrichDetailed(Self.request(categories: [])) {
            #expect(reason.contains("未配置"))
        } else {
            Issue.record("应返回未配置模型的失败原因")
        }
    }

    @Test("模型报错时返回 nil，并给出可读失败原因")
    func serviceSurvivesFailure() async {
        let completer = FakeCompleter(output: "", shouldFail: true)
        let service = AIEnhancementService(completer: completer, embedder: FakeEmbedder(vector: [1]))
        #expect(await service.enrich(Self.request(categories: categories)) == nil)
        if case .failure(let reason) = await service.enrichDetailed(Self.request(categories: categories)) {
            #expect(reason.contains("模型请求失败"))
        } else {
            Issue.record("应返回模型请求失败原因")
        }
    }

    @Test("向量化失败不影响摘要与标签")
    func embeddingFailureIsolated() async throws {
        let completer = FakeCompleter(output: #"{"summary":"摘要","tags":["t"]}"#)
        let embedder = FakeEmbedder(vector: nil, shouldFail: true)
        let service = AIEnhancementService(completer: completer, embedder: embedder)
        let enrichment = try #require(await service.enrich(Self.request(categories: categories)))
        #expect(enrichment.summary == "摘要")
        #expect(enrichment.embedding == nil)
    }

    @Test("关闭增强开关后不再调用模型")
    func configurationSwitch() async {
        let completer = FakeCompleter(output: #"{"summary":"摘要"}"#)
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
            title: "截图条目",
            text: "Apple Neural Engine 神经网络加速 OCR 文本",
            contentType: .image,
            sourceURL: URL(string: "https://example.com/a"),
            sourceTitle: "示例页",
            categories: categories
        )
    }

    // MARK: - Provider 线格式

    @Test("Ollama 客户端：受限解码请求体 + 响应解析")
    func ollamaWireFormat() async throws {
        let response = #"{"message":{"role":"assistant","content":"{\"summary\":\"摘要\"}"}}"#
        let transport = StubTransport(responses: [
            HTTPPayload(statusCode: 200, headers: [:], body: Data(response.utf8)),
        ])
        let client = OllamaClient(
            configuration: .init(baseURL: URL(string: "http://127.0.0.1:11434")!),
            transport: transport
        )

        let content = try await client.completeJSON(systemPrompt: "sys", userPrompt: "usr")
        #expect(content == #"{"summary":"摘要"}"#)

        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "http://127.0.0.1:11434/api/chat")
        #expect(request.httpMethod == "POST")
        let body = try #require(request.httpBody)
        let json = try #require((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])
        #expect(json["format"] as? String == "json")
        #expect(json["stream"] as? Bool == false)
        #expect((json["messages"] as? [[String: Any]])?.count == 2)
    }

    @Test("OpenAI 兼容客户端：携带鉴权头并解析 choices")
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

    @Test("OpenAI 向量接口解析 data[0].embedding")
    func openAIEmbedding() async throws {
        let response = #"{"data":[{"embedding":[0.5,0.25,-0.125]}]}"#
        let transport = StubTransport(responses: [
            HTTPPayload(statusCode: 200, headers: [:], body: Data(response.utf8)),
        ])
        let client = OpenAICompatibleClient(
            configuration: .init(apiKey: "sk", embeddingModel: "text-embedding-3-small"),
            transport: transport
        )
        #expect(try await client.embed("文本") == [0.5, 0.25, -0.125])
        #expect(transport.requests.first?.url?.absoluteString == "https://api.openai.com/v1/embeddings")
    }

    @Test("接口返回非 2xx 时抛错，由上层 best-effort 兜住")
    func providerHTTPError() async {
        let transport = StubTransport(responses: [
            HTTPPayload(statusCode: 429, headers: [:], body: Data()),
        ])
        let client = OllamaClient(transport: transport)
        await #expect(throws: NovPoolError.self) {
            _ = try await client.completeJSON(systemPrompt: "s", userPrompt: "u")
        }
    }

    @Test("向量回退链：主通道失败时自动用兜底通道")
    func embeddingChain() async throws {
        let failing = FakeEmbeddingProvider(vector: nil, shouldFail: true)
        let fallback = FakeEmbeddingProvider(vector: [1, 2, 3])
        let chain = ChainedEmbeddingProvider(providers: [failing, fallback])
        #expect(try await chain.embed("文本") == [1, 2, 3])

        let allFailing = ChainedEmbeddingProvider(providers: [failing])
        #expect(try await allFailing.embed("文本") == nil)
        #expect(try await ChainedEmbeddingProvider(providers: []).embed("文本") == nil)
    }
}

/// 简单向量替身，供回退链测试使用。
struct FakeEmbeddingProvider: EmbeddingProviding {
    struct Failure: Error {}
    var vector: [Float]?
    var shouldFail = false

    func embed(_ text: String) async throws -> [Float]? {
        if shouldFail { throw Failure() }
        return vector
    }
}

/// LLM 补全替身。
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
        if shouldFail { throw NovPoolError.notImplemented("模型不可用") }
        return output
    }

    /// 同步加锁助手：`NSLock.lock()` 在 async 上下文中被标记为不可用。
    private func bumpCount() {
        lock.lock()
        recorded += 1
        lock.unlock()
    }
}

/// 向量化替身。
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
        if shouldFail { throw NovPoolError.notImplemented("向量服务不可用") }
        return vector
    }
}
