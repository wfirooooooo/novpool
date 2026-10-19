import Foundation
import NovPoolCore
import NovPoolStorage
import NovPoolUI
import NovPoolSystemBridge

/// Runtime settings.
///
/// Most keys live in `UserDefaults`; the OpenAI API key goes in Keychain (D4).
struct NovPoolSettings: Sendable {
    static let openAIAPIKeyAccount = "openai.apiKey"
    static let openAIAPIKeyDefaultsKey = "novpool.openai.apiKey"
    var isAIEnabled: Bool
    /// Active AI backend (with `isAIEnabled`; master off skips model calls).
    var aiProvider: AIProvider
    var ollamaBaseURL: URL
    var chatModel: String
    var embeddingModel: String
    var categories: [String]
    /// Maximum items in one cross-item digest (10–50).
    var digestMaxItems: Int
    /// OpenAI-compatible config (used when `aiProvider` is `.openAICompatible` or local llama).
    var openAIBaseURL: URL?
    var openAIAPIKey: String?
    var uiLanguage: AppLanguage
    /// Global hotkey that opens the search panel.
    var searchHotKey: HotKeySpec
    /// Whether background cloud sync (outbox worker) is enabled.
    var isSyncEnabled: Bool
    /// Route rules JSON (editable in Settings).
    var routeRulesJSON: String
    /// Fallback connectors when no rule matches.
    var defaultConnectorIDs: [String]
    /// Drop-zone sectors shown on drag (customizable in Settings).
    var zones: [DropZone]

    static let defaults = NovPoolSettings(
        isAIEnabled: true,
        aiProvider: .ollama,
        ollamaBaseURL: URL(string: "http://127.0.0.1:11434")!,
        chatModel: "qwen2.5:7b",
        embeddingModel: "bge-m3",
        // Topic tree (by meaning, not file type). Editable in Settings.
        categories: ["Tech", "Product", "Life", "Reading", "Work", "Other"],
        digestMaxItems: 30,
        openAIBaseURL: nil,
        openAIAPIKey: nil,
        uiLanguage: .en,
        searchHotKey: .default,
        isSyncEnabled: false,
        routeRulesJSON: "",
        defaultConnectorIDs: [],
        zones: DropZone.defaultZones
    )

    static func load(
        _ defaults: UserDefaults = .standard,
        keychain: KeychainStore = KeychainStore()
    ) -> NovPoolSettings {
        let settings = NovPoolSettings.defaults
        return NovPoolSettings(
            isAIEnabled: defaults.object(forKey: "novpool.ai.enabled") as? Bool ?? settings.isAIEnabled,
            aiProvider: AIProvider.load(defaults),
            ollamaBaseURL: (defaults.string(forKey: "novpool.ollama.baseURL").flatMap(URL.init(string:)))
                ?? settings.ollamaBaseURL,
            chatModel: defaults.string(forKey: "novpool.ai.chatModel") ?? settings.chatModel,
            embeddingModel: defaults.string(forKey: "novpool.ai.embeddingModel") ?? settings.embeddingModel,
            categories: defaults.stringArray(forKey: "novpool.ai.categories") ?? settings.categories,
            digestMaxItems: clampedDigestItems(defaults.object(forKey: "novpool.digest.maxItems") as? Int),
            openAIBaseURL: defaults.string(forKey: "novpool.openai.baseURL").flatMap(URL.init(string:)),
            openAIAPIKey: loadOpenAIAPIKey(defaults: defaults, keychain: keychain),
            uiLanguage: AppLanguage.load(defaults),
            searchHotKey: defaults.string(forKey: "novpool.hotkey")
                .flatMap(HotKeySpec.init(named:)) ?? settings.searchHotKey,
            isSyncEnabled: defaults.object(forKey: "novpool.sync.enabled") as? Bool ?? settings.isSyncEnabled,
            routeRulesJSON: defaults.string(forKey: "novpool.routes") ?? settings.routeRulesJSON,
            defaultConnectorIDs: defaults.stringArray(forKey: "novpool.connectors.default")
                ?? settings.defaultConnectorIDs,
            zones: DropZoneConfiguration.zones(from: defaults.string(forKey: DropZoneConfiguration.defaultsKey))
        )
    }

    static func clampedDigestItems(_ value: Int?) -> Int {
        DigestLimits.clamp(value ?? DigestLimits.defaultMaxItems)
    }

    /// Keychain first; migrate a legacy UserDefaults plaintext value if present, then remove it.
    static func loadOpenAIAPIKey(
        defaults: UserDefaults,
        keychain: KeychainStore
    ) -> String? {
        if let fromKeychain = try? keychain.loadString(account: openAIAPIKeyAccount),
           !fromKeychain.isEmpty {
            return fromKeychain
        }
        guard let legacy = defaults.string(forKey: openAIAPIKeyDefaultsKey), !legacy.isEmpty else {
            return nil
        }
        try? keychain.store(legacy, account: openAIAPIKeyAccount)
        defaults.removeObject(forKey: openAIAPIKeyDefaultsKey)
        return legacy
    }

    static func saveOpenAIAPIKey(
        _ key: String?,
        defaults: UserDefaults,
        keychain: KeychainStore
    ) throws {
        defaults.removeObject(forKey: openAIAPIKeyDefaultsKey)
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            try keychain.delete(account: openAIAPIKeyAccount)
        } else {
            try keychain.store(trimmed, account: openAIAPIKeyAccount)
        }
    }

    /// Parse route rules: on bad JSON treat as no rules so the app still launches.
    var routeRules: [RouteRule] {
        guard let data = routeRulesJSON.data(using: .utf8), !routeRulesJSON.isEmpty else { return [] }
        return (try? JSONDecoder().decode([RouteRule].self, from: data)) ?? []
    }

    var routeEvaluator: RouteEvaluator {
        RouteEvaluator(rules: routeRules, defaultConnectorIDs: defaultConnectorIDs)
    }

    /// Build a chat client for the currently selected backend.
    func makeCompleter() -> (any LLMCompleting)? {
        guard isAIEnabled else { return nil }
        switch aiProvider {
        case .ollama:
            return OllamaClient(
                configuration: .init(baseURL: ollamaBaseURL, chatModel: chatModel, embeddingModel: embeddingModel)
            )
        case .openAICompatible, .localLlama:
            guard let openAIBaseURL else { return nil }
            return OpenAICompatibleClient(
                configuration: .init(
                    baseURL: openAIBaseURL,
                    apiKey: aiProvider == .localLlama ? nil : openAIAPIKey,
                    chatModel: chatModel,
                    embeddingModel: embeddingModel
                )
            )
        }
    }

    /// Embedding fallback chain: current backend → macOS NaturalLanguage.
    func makeEmbedder() -> any EmbeddingProviding {
        var providers: [any EmbeddingProviding] = []
        if isAIEnabled {
            switch aiProvider {
            case .ollama:
                providers.append(
                    OllamaClient(
                        configuration: .init(
                            baseURL: ollamaBaseURL,
                            chatModel: chatModel,
                            embeddingModel: embeddingModel
                        )
                    )
                )
            case .openAICompatible, .localLlama:
                if let openAIBaseURL {
                    providers.append(
                        OpenAICompatibleClient(
                            configuration: .init(
                                baseURL: openAIBaseURL,
                                apiKey: aiProvider == .localLlama ? nil : openAIAPIKey,
                                chatModel: chatModel,
                                embeddingModel: embeddingModel
                            )
                        )
                    )
                }
            }
        }
        providers.append(NaturalLanguageEmbeddingProvider())
        return ChainedEmbeddingProvider(providers: providers)
    }
}
