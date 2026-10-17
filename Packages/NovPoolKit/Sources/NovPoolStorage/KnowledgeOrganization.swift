import Foundation

/// 人工整理字段（分类 / 标签 / 置顶 / 收藏）。
public struct KnowledgeOrganization: Sendable, Equatable {
    public var category: String?
    public var tags: [String]
    public var isPinned: Bool
    public var isFavorite: Bool

    public init(
        category: String? = nil,
        tags: [String] = [],
        isPinned: Bool = false,
        isFavorite: Bool = false
    ) {
        self.category = Self.normalizedCategory(category)
        self.tags = Self.normalizedTags(tags)
        self.isPinned = isPinned
        self.isFavorite = isFavorite
    }

    /// 从自由文本标签串构造（逗号 / 顿号 / 分号分隔）。
    public static func fromRaw(
        category: String?,
        tagsText: String,
        isPinned: Bool,
        isFavorite: Bool
    ) -> KnowledgeOrganization {
        KnowledgeOrganization(
            category: category,
            tags: parseTags(tagsText),
            isPinned: isPinned,
            isFavorite: isFavorite
        )
    }

    public static func parseTags(_ raw: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",，、;；\n\t")
        var seen = Set<String>()
        var result: [String] = []
        for part in raw.components(separatedBy: separators) {
            let tag = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty, !seen.contains(tag) else { continue }
            seen.insert(tag)
            result.append(tag)
        }
        return result
    }

    private static func normalizedCategory(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in tags {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }
}
