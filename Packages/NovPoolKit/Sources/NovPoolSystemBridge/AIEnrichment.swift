import Foundation
import NovPoolCore
import NovPoolStorage

/// Enrichment request sent to the LLM.
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

/// Structured enrichment result.
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

/// JSON structured-completion interface (OpenAI-compatible or Ollama).
public protocol LLMCompleting: Sendable {
    func completeJSON(systemPrompt: String, userPrompt: String) async throws -> String
}

/// Embedding interface. Offline, `NaturalLanguage` sentence embeddings can serve as a fallback.
///
/// Inherits storage-layer `QueryEmbeddingProviding` so one implementation can power both AI
/// enrichment and semantic recall in the search panel without an adapter.
public protocol EmbeddingProviding: QueryEmbeddingProviding {}

// MARK: - Prompt

public enum AIEnrichmentPrompt {
    /// Expected JSON shape, inlined into the system prompt for local models without JSON Schema.
    public static let jsonSchemaHint = """
    {"title": "string (optional; only when the original title is unusable)", "summary": "string", "category": "string", "tags": ["string"]}
    """

    public static func systemPrompt(
        categories: [String],
        maxTags: Int,
        maxSummaryCharacters: Int
    ) -> String {
        let categoryInstruction = categories.isEmpty
            ? "category is a short English topic/domain label for the body (e.g. Technology, Product, Life, Reading), 2–6 words; do not use format names like Web, Image, Video, PDF, File, Link, or Text."
            : "category must be exactly one of the following topics (return it verbatim): \(categories.joined(separator: ", ")). This is a content topic, not a file format."
        return """
        You are a knowledge-base assistant. Organize metadata for a newly captured item by its content meaning.
        Output exactly one JSON object — no Markdown fences, explanations, or extra text.
        JSON shape: \(jsonSchemaHint)
        Requirements:
        1. summary is a concise distillation of at most \(maxSummaryCharacters) characters; hit the point; avoid boilerplate like "This article introduces…". Match the body's language when helpful.
        2. tags: 1–\(maxTags) refined labels reflecting topic keywords (any language); no leading #.
        3. \(categoryInstruction)
        4. The "resource kind" below is for reference only (Image/PDF/Web, etc.). category must reflect what the body is about — never use the resource kind as category.
        """
    }

    public static func userPrompt(_ request: AIEnrichmentRequest, maxInputCharacters: Int) -> String {
        var lines: [String] = ["Title: \(request.title)"]
        if let sourceURL = request.sourceURL {
            lines.append("Source: \(sourceURL.absoluteString)")
        }
        if let sourceTitle = request.sourceTitle, sourceTitle != request.title {
            lines.append("Source title: \(sourceTitle)")
        }
        lines.append("Resource kind (not a category): \(request.contentType.rawValue)")
        lines.append("Body:")
        lines.append(String(request.text.prefix(maxInputCharacters)))
        return lines.joined(separator: "\n")
    }
}

// MARK: - Parse & normalize

/// Tolerant parser: models often add fences, surrounding prose, or comma-separated tags strings.
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

    /// Extract the first complete JSON object from possibly fenced / padded model output.
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

    /// Common resource-kind words: drop them if the model mistakes them for a topic category.
    private static let rejectedFormatCategories: Set<String> = [
        "Web", "Image", "Video", "File", "Document", "Link", "Text", "PlainText", "Attachment",
        "pdf", "image", "video", "file", "document", "weblink", "web", "link",
        "plaintext", "richhtml", "genericfile", "documentpdf",
        // Chinese format words still rejected when used as free-form categories.
        "图片", "网页", "视频", "文件", "文档", "链接", "文本", "附件",
    ]

    /// Category must land in the user's topic tree; with no tree, accept free topics but reject format names.
    static func resolveCategory(_ raw: String?, categories: [String]) -> String? {
        guard let raw else { return nil }
        guard !categories.isEmpty else {
            return isFormatLikeCategory(raw) ? nil : raw
        }
        if let exact = categories.first(where: { $0.caseInsensitiveCompare(raw) == .orderedSame }) {
            return exact
        }
        // Tolerate multi-pick output like "Technology / Programming": take the first preset hit.
        let separators: Set<Character> = ["/", ",", "，", "|"]
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
            let separators: Set<Character> = [",", "，", ",", ";", " "]
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
