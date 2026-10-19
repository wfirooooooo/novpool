import Foundation
import NovPoolCore
import NovPoolStorage
import Testing
@testable import NovPoolUI

@Suite("Search Filter")
struct SearchFilterTests {
    private func result(
        type: ContentType,
        category: String? = nil,
        createdAt: Date = Date()
    ) -> KnowledgeSearchResult {
        KnowledgeSearchResult(
            id: UUID(),
            title: "entry",
            category: category,
            contentType: type,
            createdAt: createdAt
        )
    }

    @Test("Type Filtering")
    func contentKind() {
        #expect(SearchContentKindFilter.web.matches(.webLink))
        #expect(SearchContentKindFilter.text.matches(.plainText))
        #expect(SearchContentKindFilter.text.matches(.richHTML))
        #expect(SearchContentKindFilter.digest.matches(.digest))
        #expect(!SearchContentKindFilter.digest.matches(.plainText))
        #expect(!SearchContentKindFilter.image.matches(.video))
    }

    @Test("Time Filter")
    func timeFilter() {
        let now = Date()
        let yesterday = now.addingTimeInterval(-24 * 3600)
        let old = now.addingTimeInterval(-40 * 24 * 3600)
        #expect(SearchTimeFilter.today.matches(now, now: now))
        #expect(!SearchTimeFilter.today.matches(yesterday, now: now))
        #expect(SearchTimeFilter.week.matches(yesterday, now: now))
        #expect(!SearchTimeFilter.month.matches(old, now: now))
    }

    @Test("Combined Filtering")
    func combined() {
        let items = [
            result(type: .webLink, category: "Technology"),
            result(type: .image, category: "Technology"),
            result(type: .webLink, category: "Life"),
        ]
        let filter = SearchFilterState(contentKind: .web, category: "Technology", time: .all)
        #expect(filter.applying(to: items).count == 1)
        #expect(filter.applying(to: items).first?.category == "Technology")
    }

    @Test("Favorite and Pinned filtering")
    func favoriteAndPinned() {
        let starred = KnowledgeSearchResult(
            id: UUID(),
            title: "Favorite",
            contentType: .plainText,
            isFavorite: true
        )
        let pinned = KnowledgeSearchResult(
            id: UUID(),
            title: "Pinned",
            contentType: .plainText,
            isPinned: true
        )
        let plain = KnowledgeSearchResult(id: UUID(), title: "Ordinary", contentType: .plainText)
        let items = [starred, pinned, plain]
        #expect(SearchFilterState(favoritesOnly: true).applying(to: items).map(\.title) == ["Favorite"])
        #expect(SearchFilterState(pinnedOnly: true).applying(to: items).map(\.title) == ["Pinned"])
    }
}
