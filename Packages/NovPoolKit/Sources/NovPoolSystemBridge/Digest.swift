import Foundation
import NovPoolCore
import NovPoolStorage

/// Product limits for one cross-item digest.
public enum DigestLimits {
    public static let defaultMaxItems = 30
    public static let minimumItems = 10
    public static let maximumItems = 50

    public static func clamp(_ value: Int) -> Int {
        min(max(value, minimumItems), maximumItems)
    }
}

/// One item offered to the digest model.
public struct DigestSource: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    /// Stored AI summary. Preferred over body text, per the L8 long-context decision.
    public var summary: String?
    /// Short body excerpt, used only when the item has no summary yet.
    public var bodyExcerpt: String?

    public init(id: UUID, title: String, summary: String? = nil, bodyExcerpt: String? = nil) {
        self.id = id
        self.title = title
        self.summary = summary
        self.bodyExcerpt = bodyExcerpt
    }
}

public struct DigestCitation: Sendable, Equatable, Identifiable {
    public var sourceID: UUID
    public var title: String

    public var id: UUID { sourceID }

    public init(sourceID: UUID, title: String) {
        self.sourceID = sourceID
        self.title = title
    }
}

/// Ephemeral digest result. `savedItemID` is filled after "Save to knowledge base".
public struct DigestDraft: Sendable, Equatable {
    public var title: String
    public var overview: String
    public var keyPoints: [String]
    public var openQuestions: [String]
    public var citations: [DigestCitation]
    public var savedItemID: UUID?

    public init(
        title: String,
        overview: String,
        keyPoints: [String] = [],
        openQuestions: [String] = [],
        citations: [DigestCitation],
        savedItemID: UUID? = nil
    ) {
        self.title = title
        self.overview = overview
        self.keyPoints = keyPoints
        self.openQuestions = openQuestions
        self.citations = citations
        self.savedItemID = savedItemID
    }

    /// Short text used for the search-result line and as the stored AI summary.
    public var summaryText: String {
        String(overview.prefix(500))
    }

    /// Markdown body stored for a saved digest.
    public var markdownBody: String {
        var sections: [String] = []
        if !overview.isEmpty {
            sections.append("## Overview\n\(overview)")
        }
        if !keyPoints.isEmpty {
            sections.append("## Key points\n" + keyPoints.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !openQuestions.isEmpty {
            sections.append("## Open questions\n" + openQuestions.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !citations.isEmpty {
            let sources = citations.enumerated()
                .map { "\($0.offset + 1). \($0.element.title)" }
                .joined(separator: "\n")
            sections.append("## Sources\n\(sources)")
        }
        return sections.joined(separator: "\n\n")
    }

    /// Persisted knowledge item. Source IDs stay in their own column for citation navigation.
    public func makeRecord(id: UUID = UUID(), now: Date = Date()) -> KnowledgeItemRecord {
        KnowledgeItemRecord(
            id: id,
            contentType: .digest,
            title: title,
            markdownBody: markdownBody,
            aiSummary: summaryText,
            aiTags: [],
            digestSourceIDs: citations.map(\.sourceID),
            createdAt: now,
            updatedAt: now
        )
    }
}

public enum DigestOutcome: Sendable, Equatable {
    case success(DigestDraft)
    case failure(String)
}

public enum DigestPrompt {
    public static let jsonSchemaHint = """
    {"title": "string", "overview": "string", "keyPoints": ["string"], "openQuestions": ["string"]}
    """

    public static let systemPrompt = """
    You are a knowledge-base assistant. The user selected several saved items and wants one cross-item digest.
    Output exactly one JSON object — no Markdown fences, explanations, or extra text.
    JSON shape: \(jsonSchemaHint)
    Requirements:
    1. title: short and specific to this set (at most 12 words). Do not use "Digest" alone.
    2. overview: 2–4 sentences describing what this set is about together.
    3. keyPoints: 3–7 concrete points supported by the item summaries.
    4. openQuestions: 0–3 gaps, disagreements, or follow-ups worth checking; omit when there is nothing useful.
    5. Stay grounded in the provided titles and summaries. Never invent facts or citations.
    6. Write in the language most items use.
    """

    /// Concatenates item summaries. Body excerpts are a fallback for items that lack a summary.
    public static func userPrompt(sources: [DigestSource], maxInputCharacters: Int = 12_000) -> String {
        let header = "Items (\(sources.count)):\n"
        var blocks: [String] = []
        for (index, source) in sources.enumerated() {
            var lines = ["[\(index + 1)] \(source.title)"]
            if let summary = normalized(source.summary) {
                lines.append("Summary: \(String(summary.prefix(600)))")
            } else if let excerpt = normalized(source.bodyExcerpt) {
                lines.append("Excerpt: \(String(excerpt.prefix(400)))")
            } else {
                lines.append("Summary: (none available)")
            }
            blocks.append(lines.joined(separator: "\n"))
        }

        var text = header + blocks.joined(separator: "\n\n")
        if text.count > maxInputCharacters {
            let budget = max(maxInputCharacters - 60, 0)
            text = String(text.prefix(budget)) + "\n(Some item text was shortened to fit the context.)"
        }
        return text
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum DigestParser {
    /// Tolerant parser for fenced / padded model output.
    public static func parse(_ raw: String, sources: [DigestSource]) -> DigestDraft? {
        guard let jsonText = AIEnrichmentParser.extractJSONObject(from: raw),
              let data = jsonText.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }

        guard let title = AIEnrichmentParser.string(object["title"]).map({ String($0.prefix(120)) }) else {
            return nil
        }
        let overview = AIEnrichmentParser.string(object["overview"])
            ?? AIEnrichmentParser.string(object["summary"])
        let keyPoints = stringList(object["keyPoints"])
        guard overview != nil || !keyPoints.isEmpty else { return nil }

        return DigestDraft(
            title: title,
            overview: overview.map { String($0.prefix(2_000)) } ?? "",
            keyPoints: keyPoints,
            openQuestions: stringList(object["openQuestions"]),
            citations: sources.map { DigestCitation(sourceID: $0.id, title: $0.title) }
        )
    }

    /// Accepts an array of strings or one newline / semicolon separated string.
    static func stringList(_ any: Any?) -> [String] {
        var values: [String] = []
        switch any {
        case let list as [Any]:
            values = list.compactMap { AIEnrichmentParser.string($0) }
        case let text as String:
            let separators: Set<Character> = ["\n", ";", "；"]
            values = text.split(whereSeparator: { separators.contains($0) }).map(String.init)
        default:
            break
        }
        var seen = Set<String>()
        return values.compactMap { value in
            let cleaned = AIEnrichmentParser.string(value)
            guard let cleaned, seen.insert(cleaned.lowercased()).inserted else { return nil }
            return cleaned
        }
    }
}
