import Foundation
import NovPoolCore
import NovPoolStorage

/// Client-side filter applied after hybrid search recall.
public enum SearchContentKindFilter: String, Sendable, CaseIterable, Identifiable, Equatable {
    case all
    case web
    case image
    case video
    case document
    case text
    case file

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "All"
        case .web: "Web"
        case .image: "Image"
        case .video: "Video"
        case .document: "PDF"
        case .text: "Text"
        case .file: "File"
        }
    }

    public func matches(_ type: ContentType) -> Bool {
        switch self {
        case .all: true
        case .web: type == .webLink
        case .image: type == .image
        case .video: type == .video
        case .document: type == .documentPDF
        case .text: type == .plainText || type == .richHTML
        case .file: type == .genericFile
        }
    }
}

public enum SearchTimeFilter: String, Sendable, CaseIterable, Identifiable, Equatable {
    case all
    case today
    case week
    case month

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "Any time"
        case .today: "Today"
        case .week: "Last 7 days"
        case .month: "Last 30 days"
        }
    }

    public func matches(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch self {
        case .all:
            return true
        case .today:
            return calendar.isDate(date, inSameDayAs: now)
        case .week:
            guard let start = calendar.date(byAdding: .day, value: -7, to: now) else { return true }
            return date >= start
        case .month:
            guard let start = calendar.date(byAdding: .day, value: -30, to: now) else { return true }
            return date >= start
        }
    }
}

public struct SearchFilterState: Sendable, Equatable {
    public var contentKind: SearchContentKindFilter
    public var category: String?
    public var time: SearchTimeFilter
    /// Favorites only.
    public var favoritesOnly: Bool
    /// Pinned only.
    public var pinnedOnly: Bool

    public init(
        contentKind: SearchContentKindFilter = .all,
        category: String? = nil,
        time: SearchTimeFilter = .all,
        favoritesOnly: Bool = false,
        pinnedOnly: Bool = false
    ) {
        self.contentKind = contentKind
        self.category = category
        self.time = time
        self.favoritesOnly = favoritesOnly
        self.pinnedOnly = pinnedOnly
    }

    public var isActive: Bool {
        contentKind != .all || category != nil || time != .all || favoritesOnly || pinnedOnly
    }

    public func matches(_ result: KnowledgeSearchResult, now: Date = Date()) -> Bool {
        guard contentKind.matches(result.contentType) else { return false }
        guard time.matches(result.createdAt, now: now) else { return false }
        if let category {
            guard result.category == category else { return false }
        }
        if favoritesOnly, !result.isFavorite { return false }
        if pinnedOnly, !result.isPinned { return false }
        return true
    }

    public func applying(to results: [KnowledgeSearchResult], now: Date = Date()) -> [KnowledgeSearchResult] {
        guard isActive else { return results }
        return results.filter { matches($0, now: now) }
    }
}
