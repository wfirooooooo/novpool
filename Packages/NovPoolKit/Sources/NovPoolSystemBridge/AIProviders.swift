import Foundation
import NaturalLanguage
import NovPoolCore

// MARK: - OpenAI 兼容

/// OpenAI 兼容接口（OpenAI / DeepSeek / 兼容网关 / 自建 vLLM 等）。
public struct OpenAICompatibleClient: LLMCompleting, EmbeddingProviding {
    public struct Configuration: Sendable {
        public var baseURL: URL
        public var apiKey: String?
        public var chatModel: String
        public var embeddingModel: String?
        public var timeout: TimeInterval

        public init(
            baseURL: URL = URL(string: "https://api.openai.com/v1")!,
            apiKey: String? = nil,
            chatModel: String = "gpt-4o-mini",
            embeddingModel: String? = "text-embedding-3-small",
            timeout: TimeInterval = 20
        ) {
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.chatModel = chatModel
            self.embeddingModel = embeddingModel
            self.timeout = timeout
        }
    }

    private let configuration: Configuration
    private let transport: any HTTPTransport

    public init(configuration: Configuration, transport: any HTTPTransport = URLSessionTransport()) {
        self.configuration = configuration
        self.transport = transport
    }

    public func completeJSON(systemPrompt: String, userPrompt: String) async throws -> String {
        let body: [String: Any] = [
            "model": configuration.chatModel,
            "temperature": 0.2,
            // Structured Outputs：由服务端保证返回合法 JSON 对象。
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt],
            ],
        ]
        let payload = try await post(path: "chat/completions", body: body)
        guard let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NovPoolError.notImplemented("LLM 响应结构不符合 OpenAI 兼容格式")
        }
        return content
    }

    public func embed(_ text: String) async throws -> [Float]? {
        guard let model = configuration.embeddingModel else { return nil }
        let body: [String: Any] = ["model": model, "input": text]
        let payload = try await post(path: "embeddings", body: body)
        guard let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let data = object["data"] as? [[String: Any]],
              let vector = data.first?["embedding"] as? [Double] else {
            return nil
        }
        return vector.map(Float.init)
    }

    private func post(path: String, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: configuration.baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = configuration.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let payload = try await transport.get(request)
        guard (200..<300).contains(payload.statusCode) else {
            throw NovPoolError.notImplemented("LLM 接口返回 HTTP \(payload.statusCode)")
        }
        return payload.body
    }
}

// MARK: - Ollama

/// 本地 Ollama（默认 `http://127.0.0.1:11434`），完全离线可用。
public struct OllamaClient: LLMCompleting, EmbeddingProviding {
    public struct Configuration: Sendable {
        public var baseURL: URL
        public var chatModel: String
        public var embeddingModel: String
        public var timeout: TimeInterval

        public init(
            baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
            chatModel: String = "qwen2.5:7b",
            embeddingModel: String = "bge-m3",
            timeout: TimeInterval = 60
        ) {
            self.baseURL = baseURL
            self.chatModel = chatModel
            self.embeddingModel = embeddingModel
            self.timeout = timeout
        }
    }

    private let configuration: Configuration
    private let transport: any HTTPTransport

    public init(
        configuration: Configuration = Configuration(),
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        self.configuration = configuration
        self.transport = transport
    }

    public func completeJSON(systemPrompt: String, userPrompt: String) async throws -> String {
        let body: [String: Any] = [
            "model": configuration.chatModel,
            "stream": false,
            // Ollama 的 `format: json` 等价于受限解码，保证输出是合法 JSON。
            "format": "json",
            "options": ["temperature": 0.2],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt],
            ],
        ]
        let payload = try await post(path: "api/chat", body: body)
        guard let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let message = object["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NovPoolError.notImplemented("Ollama 响应结构不符合预期")
        }
        return content
    }

    public func embed(_ text: String) async throws -> [Float]? {
        let body: [String: Any] = ["model": configuration.embeddingModel, "input": text]
        let payload = try await post(path: "api/embed", body: body)
        guard let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let vectors = object["embeddings"] as? [[Double]],
              let vector = vectors.first else {
            return nil
        }
        return vector.map(Float.init)
    }

    private func post(path: String, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: configuration.baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let payload = try await transport.get(request)
        guard (200..<300).contains(payload.statusCode) else {
            throw NovPoolError.notImplemented("Ollama 接口返回 HTTP \(payload.statusCode)")
        }
        return payload.body
    }
}

// MARK: - 端侧句向量兜底

/// 向量化回退链：按顺序尝试，前一个返回 `nil` 或抛错时用下一个。
///
/// 对应白皮书的「向量化双模式」——优先配置的 embedding 模型（云端或 Ollama），
/// 完全离线时回退到 macOS 原生 `NLEmbedding`。
public struct ChainedEmbeddingProvider: EmbeddingProviding {
    private let providers: [any EmbeddingProviding]

    public init(providers: [any EmbeddingProviding]) {
        self.providers = providers
    }

    public func embed(_ text: String) async throws -> [Float]? {
        for provider in providers {
            if let vector = try? await provider.embed(text), !vector.isEmpty {
                return vector
            }
        }
        return nil
    }
}

/// 完全离线时的向量兜底：macOS 原生 `NLEmbedding` 句向量。
///
/// 该接口依赖系统语言资源；资源缺失时返回 `nil`，流水线跳过向量化而不是整条失败。
public struct NaturalLanguageEmbeddingProvider: EmbeddingProviding {
    private let language: NLLanguage

    public init(language: NLLanguage = .simplifiedChinese) {
        self.language = language
    }

    public func embed(_ text: String) async throws -> [Float]? {
        guard !text.isEmpty, let embedding = NLEmbedding.sentenceEmbedding(for: language) else {
            return nil
        }
        return embedding.vector(for: text)?.map(Float.init)
    }
}
