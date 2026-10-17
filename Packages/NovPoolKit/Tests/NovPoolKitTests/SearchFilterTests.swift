import Foundation
import NovPoolCore
import NovPoolStorage
import Testing
@testable import NovPoolUI

@Suite("检索过滤")
struct SearchFilterTests {
    private func result(
        type: ContentType,
        category: String? = nil,
        createdAt: Date = Date()
    ) -> KnowledgeSearchResult {
        KnowledgeSearchResult(
            id: UUID(),
            title: "条目",
            category: category,
            contentType: type,
            createdAt: createdAt
        )
    }

    @Test("类型过滤")
    func contentKind() {
        #expect(SearchContentKindFilter.web.matches(.webLink))
        #expect(SearchContentKindFilter.text.matches(.plainText))
        #expect(SearchContentKindFilter.text.matches(.richHTML))
        #expect(!SearchContentKindFilter.image.matches(.video))
    }

    @Test("时间过滤")
    func timeFilter() {
        let now = Date()
        let yesterday = now.addingTimeInterval(-24 * 3600)
        let old = now.addingTimeInterval(-40 * 24 * 3600)
        #expect(SearchTimeFilter.today.matches(now, now: now))
        #expect(!SearchTimeFilter.today.matches(yesterday, now: now))
        #expect(SearchTimeFilter.week.matches(yesterday, now: now))
        #expect(!SearchTimeFilter.month.matches(old, now: now))
    }

    @Test("组合过滤")
    func combined() {
        let items = [
            result(type: .webLink, category: "技术"),
            result(type: .image, category: "技术"),
            result(type: .webLink, category: "生活"),
        ]
        let filter = SearchFilterState(contentKind: .web, category: "技术", time: .all)
        #expect(filter.applying(to: items).count == 1)
        #expect(filter.applying(to: items).first?.category == "技术")
    }
}
