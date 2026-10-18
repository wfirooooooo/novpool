import Foundation
import NaturalLanguage
import NovPoolCore

// MARK: - OpenAI compatible

/// OpenAI compatible interfaces (OpenAI / DeepSeek / compatible gateway / self-built vLLM, etc.).
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
            // Structured Outputs: The server ensures that a valid JSON object is returned.
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
            throw NovPoolError.notImplemented("LLM response structure is not OpenAI-compatible")
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
            throw NovPoolError.notImplemented("LLM API returned HTTP\(payload.statusCode)")
        }
        return payload.body
    }
}

// MARK: - Ollama

/// Local Ollama (default `http://127.0.0.1:11434`), fully functional offline.
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
            // `format: json` in Ollama is equivalent to constrained decoding, ensuring the output is valid JSON.
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
            throw NovPoolError.notImplemented("Ollama response structure unexpected")
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
            throw NovPoolError.notImplemented("Ollama API returned HTTP\(payload.statusCode)")
        }
        return payload.body
    }
}

// MARK: - Fallback for terminal-side sentence embedding

/// Embedding fallback chain: try in order, use the next one when the previous returns `nil` or throws an error.
///
/// Corresponding to the white paper's 'Embedding-based dual mode' — the embedding model of priority configuration (cloud or Ollama),
/// Fallback to macOS native `NLEmbedding` when completely offline.
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

/// Fallback Embedding when completely offline: native macOS `NLEmbedding` sentence embedding.
///
/// This interface relies on system language resources; if resources are missing, it returns `nil`, and the pipeline skips embedding instead of failing entirely.
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
