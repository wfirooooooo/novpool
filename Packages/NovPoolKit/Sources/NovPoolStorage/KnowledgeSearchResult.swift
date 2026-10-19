import Foundation
import NovPoolCore

/// Search hits (including all fields required for rendering and operations).
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
    /// Full-text search hit snippet (FTS5 `snippet()`).
    public var snippet: String?
    /// Details PreviewBody: Markdown Body takes priority, followed by OCR Text.
    public var previewBody: String?
    /// Hit method, used to distinguish between 'Keyword Hit' and 'Semantic Hit' on the UI.
    public var isFullTextMatch: Bool
    public var isSemanticMatch: Bool
    /// Local cached file (existence verified). `nil` indicates that this entry has no persisted file or the file has been cleaned up.
    public var localFileURL: URL?
    public var isPinned: Bool
    public var isFavorite: Bool
    /// Last summarize failure, when the item still has no usable summary.
    public var aiFailureReason: String?
    /// Source item IDs when this result is a saved digest.
    public var digestSourceIDs: [UUID]

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
        isFavorite: Bool = false,
        aiFailureReason: String? = nil,
        digestSourceIDs: [UUID] = []
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
        self.aiFailureReason = aiFailureReason
        self.digestSourceIDs = digestSourceIDs
    }

    /// Non-empty summary already stored. Re-running it replaces that summary.
    public var hasExistingSummary: Bool {
        guard let summary else { return false }
        return !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var organization: KnowledgeOrganization {
        KnowledgeOrganization(
            category: category,
            tags: tags,
            isPinned: isPinned,
            isFavorite: isFavorite
        )
    }

    /// Readable annotation of the hit method.
    public var matchLabel: String {
        switch (isFullTextMatch, isSemanticMatch) {
        case (true, true): "Keyword + Semantic"
        case (true, false): "Keyword"
        case (false, true): "Semantic"
        case (false, false): "Recent"
        }
    }

    public var hasLocalFile: Bool { localFileURL != nil }

    /// Resource Kind tag (Web / Image / PDF…), always follows the entry.
    public var resourceTypeTag: String { contentType.displayTag }

    /// Display tags: Kind tag first, followed by content Keyword tag (deduplicated).
    public var displayTags: [String] {
        var ordered: [String] = [resourceTypeTag]
        for tag in tags where ordered.allSatisfy({ $0.caseInsensitiveCompare(tag) != .orderedSame }) {
            ordered.append(tag)
        }
        return ordered
    }

    /// The default action when pressing Enter.
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

/// The executable action of the item.
public enum SearchResultAction: Sendable, Equatable {
    case openURL(URL)
    case revealFile(URL)
    case none

    public var isEnabled: Bool {
        if case .none = self { return false }
        return true
    }
}
