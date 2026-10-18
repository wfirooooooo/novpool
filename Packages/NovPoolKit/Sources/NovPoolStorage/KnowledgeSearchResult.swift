import Foundation
import NovPoolCore

/// 检索命中（含渲染与操作所需的全部字段）。
public struct KnowledgeSearchResult: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var summary: String?
    public var category: String?
    public var tags: [String]
    public var contentType: ContentType
    public var sourceURL: URL?
    public var sourceTitle: String?
    public var createdAt: Date
    /// 全文检索命中片段（FTS5 `snippet()`）。
    public var snippet: String?
    /// 详情预览正文：Markdown 正文优先，其次 OCR 文本。
    public var previewBody: String?
    /// 命中方式，用于在 UI 上区分「关键词命中」与「语义命中」。
    public var isFullTextMatch: Bool
    public var isSemanticMatch: Bool
    /// 本地暂存文件（已校验存在）。`nil` 表示该条目没有落盘文件或文件已被清理。
    public var localFileURL: URL?
    public var isPinned: Bool
    public var isFavorite: Bool

    public init(
        id: UUID,
        title: String,
        summary: String? = nil,
        category: String? = nil,
        tags: [String] = [],
        contentType: ContentType,
        sourceURL: URL? = nil,
        sourceTitle: String? = nil,
        createdAt: Date = Date(),
        snippet: String? = nil,
        previewBody: String? = nil,
        isFullTextMatch: Bool = false,
        isSemanticMatch: Bool = false,
        localFileURL: URL? = nil,
        isPinned: Bool = false,
        isFavorite: Bool = false
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.category = category
        self.tags = tags
        self.contentType = contentType
        self.sourceURL = sourceURL
        self.sourceTitle = sourceTitle
        self.createdAt = createdAt
        self.snippet = snippet
        self.previewBody = previewBody
        self.isFullTextMatch = isFullTextMatch
        self.isSemanticMatch = isSemanticMatch
        self.localFileURL = localFileURL
        self.isPinned = isPinned
        self.isFavorite = isFavorite
    }

    public var organization: KnowledgeOrganization {
        KnowledgeOrganization(
            category: category,
            tags: tags,
            isPinned: isPinned,
            isFavorite: isFavorite
        )
    }

    /// 命中方式的可读标注。
    public var matchLabel: String {
        switch (isFullTextMatch, isSemanticMatch) {
        case (true, true): "关键词 + 语义"
        case (true, false): "关键词"
        case (false, true): "语义"
        case (false, false): "最近"
        }
    }

    public var hasLocalFile: Bool { localFileURL != nil }

    /// 资源形态 tag（网页 / 图片 / PDF…），始终跟随条目。
    public var resourceTypeTag: String { contentType.displayTag }

    /// 展示用标签：形态 tag 在前，其后是内容关键词 tag（去重）。
    public var displayTags: [String] {
        var ordered: [String] = [resourceTypeTag]
        for tag in tags where ordered.allSatisfy({ $0.caseInsensitiveCompare(tag) != .orderedSame }) {
            ordered.append(tag)
        }
        return ordered
    }

    /// 回车时的默认动作。
    public var defaultAction: SearchResultAction {
        if let sourceURL, Self.isWebURL(sourceURL) { return .openURL(sourceURL) }
        if let localFileURL { return .revealFile(localFileURL) }
        if let sourceURL { return .openURL(sourceURL) }
        return .none
    }

    static func isWebURL(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }
}

/// 条目的可执行动作。
public enum SearchResultAction: Sendable, Equatable {
    case openURL(URL)
    case revealFile(URL)
    case none

    public var isEnabled: Bool {
        if case .none = self { return false }
        return true
    }
}
