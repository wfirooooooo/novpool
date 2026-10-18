import Foundation
import NovPoolCore
import NovPoolStorage
import NovPoolUI
import NovPoolSystemBridge

/// 运行期设置。
///
/// 多数项在 `UserDefaults`；OpenAI API Key 走钥匙串（D4）。
struct NovPoolSettings: Sendable {
    static let openAIAPIKeyAccount = "openai.apiKey"
    static let openAIAPIKeyDefaultsKey = "novpool.openai.apiKey"
    var isAIEnabled: Bool
    /// 当前 AI 后端（与 `isAIEnabled` 联用；关闭总开关时不发起模型请求）。
    var aiProvider: AIProvider
    var ollamaBaseURL: URL
    var chatModel: String
    var embeddingModel: String
    var categories: [String]
    /// OpenAI 兼容接口配置（仅在 `aiProvider == .openAICompatible` 或本机 llama 时使用）。
    var openAIBaseURL: URL?
    var openAIAPIKey: String?
    var uiLanguage: AppLanguage
    /// 呼出检索面板的全局快捷键。
    var searchHotKey: HotKeySpec
    /// 是否启用后台云同步（发件箱工作器）。
    var isSyncEnabled: Bool
    /// 路由规则（JSON 字符串，设置面板可编辑）。
    var routeRulesJSON: String
    /// 默认兜底连接器（无规则命中时使用）。
    var defaultConnectorIDs: [String]
    /// 悬浮窗拖拽展开的槽位（用户可在设置面板里自定义）。
    var zones: [DropZone]

    static let defaults = NovPoolSettings(
        isAIEnabled: true,
        aiProvider: .ollama,
        ollamaBaseURL: URL(string: "http://127.0.0.1:11434")!,
        chatModel: "qwen2.5:7b",
        embeddingModel: "bge-m3",
        // 主题分类树（按内容含义，不是文件类型）。用户可在设置里改。
        categories: ["技术", "产品", "生活", "阅读", "工作", "其他"],
        openAIBaseURL: nil,
        openAIAPIKey: nil,
        uiLanguage: .zh,
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

    /// 钥匙串优先；若仅有 UserDefaults 遗留值则迁移后删除偏好设置里的明文。
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

    /// 解析路由规则：容错——JSON 写错时按「无规则」处理，不让整个 app 起不来。
    var routeRules: [RouteRule] {
        guard let data = routeRulesJSON.data(using: .utf8), !routeRulesJSON.isEmpty else { return [] }
        return (try? JSONDecoder().decode([RouteRule].self, from: data)) ?? []
    }

    var routeEvaluator: RouteEvaluator {
        RouteEvaluator(rules: routeRules, defaultConnectorIDs: defaultConnectorIDs)
    }

    /// 按当前互斥选中的后端构造对话客户端。
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

    /// 向量化回退链：当前后端 → macOS 原生句向量。
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
