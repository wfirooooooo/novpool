import Foundation

/// Which chat path the next summary will use. Settings copy only — no URLs, model ids, or secrets.
public enum SummarizeRouteKind: String, Sendable, Equatable {
    case off
    case localLlama
    case ollama
    case openAICompatible
}

public enum SummarizeRouteExplanation {
    /// Short settings blurb. The next ingest, single-item, or fill-missing run uses this route immediately.
    public static func text(kind: SummarizeRouteKind, prefersChinese: Bool) -> String {
        switch (kind, prefersChinese) {
        case (.off, false):
            "Summaries are off. Turn on one backend above. The next summary — on ingest, on one item, or when filling missing summaries — uses that route immediately, without a restart."
        case (.off, true):
            "摘要已关闭。打开上方任一后端后，下一次总结（入库、单条，或补缺失摘要）会立即走该路由，无需重启。"
        case (.localLlama, false):
            "Summaries use on-device llama.cpp (llama-server, OpenAI-compatible). Text stays on this Mac. The next summary uses this route immediately, without a restart."
        case (.localLlama, true):
            "摘要走本机 llama.cpp（llama-server，OpenAI 兼容接口），文本不出这台 Mac。下一次总结会立即使用该路由，无需重启。"
        case (.ollama, false):
            "Summaries use your local Ollama server and the chat model named above. The next summary uses this route immediately, without a restart."
        case (.ollama, true):
            "摘要走本机 Ollama，以及上方填写的对话模型。下一次总结会立即使用该路由，无需重启。"
        case (.openAICompatible, false):
            "Summaries use the OpenAI-compatible API at the Base URL in this section. The API key stays in Keychain and is not shown here. The next summary uses this route immediately, without a restart."
        case (.openAICompatible, true):
            "摘要走本节 Base URL 上的 OpenAI 兼容接口。API Key 只在钥匙串里，这里不显示。下一次总结会立即使用该路由，无需重启。"
        }
    }
}
