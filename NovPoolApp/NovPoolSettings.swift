import Foundation
import NovPoolCore
import NovPoolUI
import NovPoolSystemBridge

/// 运行期设置。
///
/// Phase 2 先用 `UserDefaults`（可用 `defaults write com.novpool.app ...` 配置）；
/// Phase 4 的设置面板会把这些键接到 UI 上。
struct NovPoolSettings: Sendable {
    var isAIEnabled: Bool
    var ollamaBaseURL: URL
    var chatModel: String
    var embeddingModel: String
    var categories: [String]
    /// 预留：配置后改用 OpenAI 兼容接口（留空则走 Ollama）。
    var openAIBaseURL: URL?
    var openAIAPIKey: String?
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
        ollamaBaseURL: URL(string: "http://127.0.0.1:11434")!,
        chatModel: "qwen2.5:7b",
        embeddingModel: "bge-m3",
        categories: [],
        openAIBaseURL: nil,
        openAIAPIKey: nil,
        searchHotKey: .default,
        isSyncEnabled: true,
        routeRulesJSON: "",
        defaultConnectorIDs: [],
        zones: DropZone.defaultZones
    )

    static func load(_ defaults: UserDefaults = .standard) -> NovPoolSettings {
        let settings = NovPoolSettings.defaults
        return NovPoolSettings(
            isAIEnabled: defaults.object(forKey: "novpool.ai.enabled") as? Bool ?? settings.isAIEnabled,
            ollamaBaseURL: (defaults.string(forKey: "novpool.ollama.baseURL").flatMap(URL.init(string:)))
                ?? settings.ollamaBaseURL,
            chatModel: defaults.string(forKey: "novpool.ai.chatModel") ?? settings.chatModel,
            embeddingModel: defaults.string(forKey: "novpool.ai.embeddingModel") ?? settings.embeddingModel,
            categories: defaults.stringArray(forKey: "novpool.ai.categories") ?? settings.categories,
            openAIBaseURL: defaults.string(forKey: "novpool.openai.baseURL").flatMap(URL.init(string:)),
            openAIAPIKey: defaults.string(forKey: "novpool.openai.apiKey"),
            searchHotKey: defaults.string(forKey: "novpool.hotkey")
                .flatMap(HotKeySpec.init(named:)) ?? settings.searchHotKey,
            isSyncEnabled: defaults.object(forKey: "novpool.sync.enabled") as? Bool ?? settings.isSyncEnabled,
            routeRulesJSON: defaults.string(forKey: "novpool.routes") ?? settings.routeRulesJSON,
            defaultConnectorIDs: defaults.stringArray(forKey: "novpool.connectors.default")
                ?? settings.defaultConnectorIDs,
            zones: DropZoneConfiguration.zones(from: defaults.string(forKey: DropZoneConfiguration.defaultsKey))
        )
    }

    /// 解析路由规则：容错——JSON 写错时按「无规则」处理，不让整个 app 起不来。
    var routeRules: [RouteRule] {
        guard let data = routeRulesJSON.data(using: .utf8), !routeRulesJSON.isEmpty else { return [] }
        return (try? JSONDecoder().decode([RouteRule].self, from: data)) ?? []
    }

    var routeEvaluator: RouteEvaluator {
        RouteEvaluator(rules: routeRules, defaultConnectorIDs: defaultConnectorIDs)
    }

    /// 优先使用 OpenAI 兼容接口（若已配置），否则用本地 Ollama。
    func makeCompleter() -> (any LLMCompleting)? {
        guard isAIEnabled else { return nil }
        if let openAIBaseURL {
            return OpenAICompatibleClient(
                configuration: .init(
                    baseURL: openAIBaseURL,
                    apiKey: openAIAPIKey,
                    chatModel: chatModel,
                    embeddingModel: embeddingModel
                )
            )
        }
        return OllamaClient(
            configuration: .init(baseURL: ollamaBaseURL, chatModel: chatModel, embeddingModel: embeddingModel)
        )
    }

    /// 向量化回退链：配置的模型 → macOS 原生句向量。
    func makeEmbedder() -> any EmbeddingProviding {
        var providers: [any EmbeddingProviding] = []
        if isAIEnabled {
            providers.append(
                OllamaClient(
                    configuration: .init(
                        baseURL: ollamaBaseURL,
                        chatModel: chatModel,
                        embeddingModel: embeddingModel
                    )
                )
            )
        }
        providers.append(NaturalLanguageEmbeddingProvider())
        return ChainedEmbeddingProvider(providers: providers)
    }
}
