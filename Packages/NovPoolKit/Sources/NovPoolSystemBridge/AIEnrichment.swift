import Foundation
import NovPoolCore
import NovPoolStorage

/// 送进 LLM 的增强请求。
public struct AIEnrichmentRequest: Sendable, Equatable {
    public var title: String
    public var text: String
    public var contentType: ContentType
    public var sourceURL: URL?
    public var sourceTitle: String?
    public var categories: [String]

    public init(
        title: String,
        text: String,
        contentType: ContentType,
        sourceURL: URL? = nil,
        sourceTitle: String? = nil,
        categories: [String] = []
    ) {
        self.title = title
        self.text = text
        self.contentType = contentType
        self.sourceURL = sourceURL
        self.sourceTitle = sourceTitle
        self.categories = categories
    }
}

/// 结构化增强结果。
public struct AIEnrichment: Sendable, Equatable {
    public var title: String?
    public var summary: String?
    public var category: String?
    public var tags: [String]
    public var embedding: [Float]?

    public init(
        title: String? = nil,
        summary: String? = nil,
        category: String? = nil,
        tags: [String] = [],
        embedding: [Float]? = nil
    ) {
        self.title = title
        self.summary = summary
        self.category = category
        self.tags = tags
        self.embedding = embedding
    }
}

/// JSON 结构化输出的补全接口（OpenAI 兼容 / Ollama 均可实现）。
public protocol LLMCompleting: Sendable {
    func completeJSON(systemPrompt: String, userPrompt: String) async throws -> String
}

/// 向量化接口。离线环境下可由 `NaturalLanguage` 句向量兜底。
///
/// 继承存储层的 `QueryEmbeddingProviding`，这样同一个实现既能给 AI 增强用，
/// 也能直接注入检索面板做语义召回，无需适配层。
public protocol EmbeddingProviding: QueryEmbeddingProviding {}

// MARK: - Prompt

public enum AIEnrichmentPrompt {
    /// 期望的 JSON 形状，直接写进 system prompt，兼容不支持 JSON Schema 的本地模型。
    public static let jsonSchemaHint = """
    {"title": "string(可选，仅当原标题不可用时给出)", "summary": "string", "category": "string", "tags": ["string"]}
    """

    public static func systemPrompt(
        categories: [String],
        maxTags: Int,
        maxSummaryCharacters: Int
    ) -> String {
        let categoryInstruction = categories.isEmpty
            ? "category 是按正文主题/领域归类的中文名（如 技术、产品、生活、阅读），2～6 字；禁止用网页、图片、视频、PDF、文件、链接、文本等格式名。"
            : "category 必须严格从以下主题列表中选一个（原样返回）：\(categories.joined(separator: "、"))。这是内容主题，不是文件格式。"
        return """
        你是知识库助手，负责为一条刚捕获的资料按「内容含义」整理元数据。
        只输出一个 JSON 对象，不要输出 Markdown 代码块、解释或多余文本。
        JSON 形状：\(jsonSchemaHint)
        要求：
        1. summary 为不超过 \(maxSummaryCharacters) 字的中文提炼，直击要点，不要「本文介绍了」这类套话。
        2. tags 给出 1～\(maxTags) 个精炼标签，反映主题关键词，中英文均可，不要带 # 号。
        3. \(categoryInstruction)
        4. 下方「资源形态」仅供参考（图片/PDF/网页等），分类必须依据正文讲了什么，绝不能把资源形态当作 category。
        """
    }

    public static func userPrompt(_ request: AIEnrichmentRequest, maxInputCharacters: Int) -> String {
        var lines: [String] = ["标题：\(request.title)"]
        if let sourceURL = request.sourceURL {
            lines.append("来源：\(sourceURL.absoluteString)")
        }
        if let sourceTitle = request.sourceTitle, sourceTitle != request.title {
            lines.append("来源标题：\(sourceTitle)")
        }
        lines.append("资源形态（非分类）：\(request.contentType.rawValue)")
        lines.append("正文：")
        lines.append(String(request.text.prefix(maxInputCharacters)))
        return lines.joined(separator: "\n")
    }
}

// MARK: - 解析与归一化

/// 容错解析：模型常常会加代码块围栏、前后解释文本，甚至把 tags 写成逗号分隔字符串。
public enum AIEnrichmentParser {
    public static func parse(
        _ raw: String,
        categories: [String],
        maxTags: Int = 5,
        maxSummaryCharacters: Int = 100
    ) -> AIEnrichment? {
        guard let jsonText = extractJSONObject(from: raw),
              let data = jsonText.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }

        let title = string(object["title"]).map { clamp($0, to: 120) }
        let summary = string(object["summary"]).map { clamp($0, to: maxSummaryCharacters) }
        let category = resolveCategory(string(object["category"]), categories: categories)
        let tags = normalizeTags(object["tags"], maxTags: maxTags)

        guard title != nil || summary != nil || category != nil || !tags.isEmpty else { return nil }
        return AIEnrichment(title: title, summary: summary, category: category, tags: tags)
    }

    /// 从可能带围栏与前后文的输出里截出第一个完整 JSON 对象。
    static func extractJSONObject(from raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let firstNewline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: firstNewline)...])
            }
            if let fence = text.range(of: "```", options: .backwards) {
                text = String(text[..<fence.lowerBound])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let start = text.firstIndex(of: "{") else { return nil }

        var depth = 0
        var isInsideString = false
        var isEscaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if isEscaped {
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                isInsideString.toggle()
            } else if !isInsideString {
                if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 { return String(text[start...index]) }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    static func string(_ any: Any?) -> String? {
        switch any {
        case let value as String:
            let trimmed = HTMLText.collapseWhitespace(value)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    /// 常见「资源形态」词：误当成主题分类时丢弃。
    private static let rejectedFormatCategories: Set<String> = [
        "网页", "图片", "视频", "文件", "文档", "链接", "文本", "纯文本", "附件",
        "pdf", "image", "video", "file", "document", "weblink", "web", "link",
        "plaintext", "richhtml", "genericfile", "documentpdf",
    ]

    /// 分类必须落在用户预设主题树内；未配置时接受自由主题名，但拒绝文件格式名。
    static func resolveCategory(_ raw: String?, categories: [String]) -> String? {
        guard let raw else { return nil }
        guard !categories.isEmpty else {
            return isFormatLikeCategory(raw) ? nil : raw
        }
        if let exact = categories.first(where: { $0.caseInsensitiveCompare(raw) == .orderedSame }) {
            return exact
        }
        // 容忍「技术 / 编程」这类多选输出：取第一个命中的预设分类。
        let separators: Set<Character> = ["/", "、", ",", "|"]
        for piece in raw.split(whereSeparator: { separators.contains($0) }) {
            let candidate = piece.trimmingCharacters(in: .whitespaces)
            if let match = categories.first(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
                return match
            }
        }
        return nil
    }

    static func isFormatLikeCategory(_ raw: String) -> Bool {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        return rejectedFormatCategories.contains(normalized)
    }

    static func normalizeTags(_ any: Any?, maxTags: Int) -> [String] {
        var rawTags: [String] = []
        switch any {
        case let values as [Any]:
            rawTags = values.compactMap { string($0) }
        case let value as String:
            let separators: Set<Character> = [",", "，", "、", ";", " "]
            rawTags = value.split(whereSeparator: { separators.contains($0) }).map(String.init)
        default:
            break
        }

        var seen = Set<String>()
        var result: [String] = []
        for raw in rawTags {
            var tag = HTMLText.collapseWhitespace(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            while tag.hasPrefix("#") { tag.removeFirst() }
            tag = clamp(tag, to: 24)
            guard !tag.isEmpty else { continue }
            guard seen.insert(tag.lowercased()).inserted else { continue }
            result.append(tag)
            if result.count >= maxTags { break }
        }
        return result
    }

    static func clamp(_ value: String, to limit: Int) -> String {
        guard value.count > limit, limit > 1 else { return value }
        return String(value.prefix(limit - 1)) + "…"
    }
}
