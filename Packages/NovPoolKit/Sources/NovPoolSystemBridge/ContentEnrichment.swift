import Foundation
import NovPoolStorage

/// 条目补齐结果。`nil` 字段表示「本次没有产出」，不会覆盖库中已有值。
public struct ContentEnrichment: Sendable, Equatable {
    public var title: String?
    public var markdownBody: String?
    public var ocrText: String?
    public var aiSummary: String?
    public var aiCategory: String?
    public var aiTags: [String]?
    public var embedding: [Float]?
    /// AI 未产出时的可读原因（不影响 OCR/正文落库）。
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

    /// 供悬浮窗展示的一句话描述。
    public var summaryLine: String {
        var parts: [String] = []
        if ocrText != nil { parts.append("OCR") }
        if markdownBody != nil { parts.append("正文") }
        if aiSummary != nil || aiTags != nil { parts.append("AI 标签") }
        if embedding != nil { parts.append("向量") }
        return parts.isEmpty ? "无新增" : parts.joined(separator: "·")
    }
}

/// 条目补齐器抽象。
public protocol ContentEnriching: Sendable {
    func enrich(record: KnowledgeItemRecord) async -> ContentEnrichment
}

/// PDF 内容来源决策：优先文字层，扫描件才走 OCR。
public enum PDFTextSource: Sendable, Equatable {
    case textLayer(String)
    case needsOCR(pageCount: Int)
    case unreadable

    public static func decide(textLayer: PDFContentExtractor.TextLayer?) -> PDFTextSource {
        guard let textLayer else { return .unreadable }
        return textLayer.isUsable ? .textLayer(textLayer.text) : .needsOCR(pageCount: textLayer.pageCount)
    }
}

/// 标题采纳策略：只有当现标题明显是兜底值（未命名 / 域名）时才用提取到的标题覆盖。
public enum TitleAdoption {
    public static func shouldAdopt(current: String, fallbackMarker: String = "未命名条目") -> Bool {
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if trimmed.hasPrefix(fallbackMarker) { return true }
        // 纯域名/主机名形式的标题（无空格且含点）视为弱标题。
        if !trimmed.contains(" "), trimmed.contains("."), !trimmed.contains("。") { return true }
        return false
    }
}
