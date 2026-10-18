import Foundation
import NovPoolStorage

/// Entry completion result. The `nil` field indicates 'no output this time' and will not overwrite existing values in the database.
public struct ContentEnrichment: Sendable, Equatable {
    public var title: String?
    public var markdownBody: String?
    public var ocrText: String?
    public var aiSummary: String?
    public var aiCategory: String?
    public var aiTags: [String]?
    public var embedding: [Float]?
    /// Readable reasons when AI has not produced output (does not affect OCR/Body storage).
    public var aiFailureReason: String?

    public init(
        title: String? = nil,
        markdownBody: String? = nil,
        ocrText: String? = nil,
        aiSummary: String? = nil,
        aiCategory: String? = nil,
        aiTags: [String]? = nil,
        embedding: [Float]? = nil,
        aiFailureReason: String? = nil
    ) {
        self.title = title
        self.markdownBody = markdownBody
        self.ocrText = ocrText
        self.aiSummary = aiSummary
        self.aiCategory = aiCategory
        self.aiTags = aiTags
        self.embedding = embedding
        self.aiFailureReason = aiFailureReason
    }

    public var isEmpty: Bool {
        title == nil && markdownBody == nil && ocrText == nil
            && aiSummary == nil && aiCategory == nil && aiTags == nil && embedding == nil
    }

    public var hasAIFields: Bool {
        aiSummary != nil || aiCategory != nil || aiTags != nil || embedding != nil
    }

    /// A brief description for display in the floating window.
    public var summaryLine: String {
        var parts: [String] = []
        if ocrText != nil { parts.append("OCR") }
        if markdownBody != nil { parts.append("Body") }
        if aiSummary != nil || aiTags != nil { parts.append("AI tags") }
        if embedding != nil { parts.append("Embedding") }
        return parts.isEmpty ? "Nothing new" : parts.joined(separator: "·")
    }
}

/// Entry completer abstraction.
public protocol ContentEnriching: Sendable {
    func enrich(record: KnowledgeItemRecord) async -> ContentEnrichment
}

/// PDF content source decision: prioritize the text layer, only use OCR for scanned documents.
public enum PDFTextSource: Sendable, Equatable {
    case textLayer(String)
    case needsOCR(pageCount: Int)
    case unreadable

    public static func decide(textLayer: PDFContentExtractor.TextLayer?) -> PDFTextSource {
        guard let textLayer else { return .unreadable }
        return textLayer.isUsable ? .textLayer(textLayer.text) : .needsOCR(pageCount: textLayer.pageCount)
    }
}

/// Title adoption strategy: Only use the extracted title to override when the current title is obviously a fallback value (Untitled / domain).
public enum TitleAdoption {
    public static func shouldAdopt(current: String, fallbackMarker: String = "Untitled item") -> Bool {
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if trimmed.hasPrefix(fallbackMarker) { return true }
        // A title in the form of a pure domain/hostname (no spaces and containing dots) is considered a weak title.
        if !trimmed.contains(" "), trimmed.contains("."), !trimmed.contains("。") { return true }
        return false
    }
}
