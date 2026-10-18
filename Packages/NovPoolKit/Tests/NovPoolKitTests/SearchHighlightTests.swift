import Foundation
import Testing
@testable import NovPoolUI

@Suite("Search Keyword Highlight")
struct SearchHighlightTests {
    @Test("Empty query or empty text does not generate an interval")
    func emptyInputs() {
        #expect(SearchHighlight.ranges(in: "Title", query: "").isEmpty)
        #expect(SearchHighlight.ranges(in: "Title", query: "   ").isEmpty)
        #expect(SearchHighlight.ranges(in: "", query: "Word").isEmpty)
    }

    @Test("Case-insensitive match in English")
    func caseInsensitive() {
        let text = "Apple Neural Engine"
        let ranges = SearchHighlight.ranges(in: text, query: "neural")
        #expect(ranges.count == 1)
        #expect(String(text[ranges[0]]) == "Neural")
    }

    @Test("All occurrences of a Chinese substring are marked")
    func chineseMultiple() {
        let text = "多云路由与多云治理"
        let ranges = SearchHighlight.ranges(in: text, query: "多云")
        #expect(ranges.count == 2)
        #expect(ranges.map { String(text[$0]) } == ["多云", "多云"])
    }

    @Test("AttributedString with background color at the hit location")
    func attributedMarksHits() {
        let attributed = SearchHighlight.attributed("hello world", query: "WORLD")
        let plain = String(attributed.characters)
        #expect(plain == "hello world")
        let ranges = SearchHighlight.ranges(in: "hello world", query: "WORLD")
        #expect(ranges.count == 1)
        let hit = ranges[0]
        guard let lower = AttributedString.Index(hit.lowerBound, within: attributed),
              let upper = AttributedString.Index(hit.upperBound, within: attributed) else {
            Issue.record("Unable to map highlight range")
            return
        }
        #expect(attributed[lower..<upper].backgroundColor != nil)
    }
}
