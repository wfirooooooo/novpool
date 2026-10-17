import Foundation
import Testing
@testable import NovPoolUI

@Suite("检索关键词高亮")
struct SearchHighlightTests {
    @Test("空查询或空文本不产生区间")
    func emptyInputs() {
        #expect(SearchHighlight.ranges(in: "标题", query: "").isEmpty)
        #expect(SearchHighlight.ranges(in: "标题", query: "   ").isEmpty)
        #expect(SearchHighlight.ranges(in: "", query: "词").isEmpty)
    }

    @Test("不区分大小写匹配英文")
    func caseInsensitive() {
        let text = "Apple Neural Engine"
        let ranges = SearchHighlight.ranges(in: text, query: "neural")
        #expect(ranges.count == 1)
        #expect(String(text[ranges[0]]) == "Neural")
    }

    @Test("中文子串多次出现全部标出")
    func chineseMultiple() {
        let text = "多云路由与多云治理"
        let ranges = SearchHighlight.ranges(in: text, query: "多云")
        #expect(ranges.count == 2)
        #expect(ranges.map { String(text[$0]) } == ["多云", "多云"])
    }

    @Test("AttributedString 在命中处带背景色")
    func attributedMarksHits() {
        let attributed = SearchHighlight.attributed("hello world", query: "WORLD")
        let plain = String(attributed.characters)
        #expect(plain == "hello world")
        let ranges = SearchHighlight.ranges(in: "hello world", query: "WORLD")
        #expect(ranges.count == 1)
        let hit = ranges[0]
        guard let lower = AttributedString.Index(hit.lowerBound, within: attributed),
              let upper = AttributedString.Index(hit.upperBound, within: attributed) else {
            Issue.record("无法映射高亮区间")
            return
        }
        #expect(attributed[lower..<upper].backgroundColor != nil)
    }
}
