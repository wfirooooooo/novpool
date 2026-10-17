import Foundation
import NovPoolCore
import NovPoolStorage

/// 检索结果客户端过滤（在混合检索召回之后再收窄）。
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
        case .all: "全部"
        case .web: "网页"
        case .image: "图片"
        case .video: "视频"
        case .document: "PDF"
        case .text: "文本"
        case .file: "文件"
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
        case .all: "不限时间"
        case .today: "今天"
        case .week: "近 7 天"
        case .month: "近 30 天"
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

    public init(
        contentKind: SearchContentKindFilter = .all,
        category: String? = nil,
        time: SearchTimeFilter = .all
    ) {
        self.contentKind = contentKind
        self.category = category
        self.time = time
    }

    public var isActive: Bool {
        contentKind != .all || category != nil || time != .all
    }

    public func matches(_ result: KnowledgeSearchResult, now: Date = Date()) -> Bool {
        guard contentKind.matches(result.contentType) else { return false }
        guard time.matches(result.createdAt, now: now) else { return false }
        if let category {
            guard result.category == category else { return false }
        }
        return true
    }

    public func applying(to results: [KnowledgeSearchResult], now: Date = Date()) -> [KnowledgeSearchResult] {
        guard isActive else { return results }
        return results.filter { matches($0, now: now) }
    }
}
