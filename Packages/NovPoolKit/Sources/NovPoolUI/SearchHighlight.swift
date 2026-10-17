import Foundation
import SwiftUI

/// 检索关键词高亮：在标题 / 预览里标出与查询串匹配的片段。
public enum SearchHighlight {
    /// 不区分大小写地找出 `query` 在 `text` 中的所有出现区间（按字符边界前进，不重叠）。
    public static func ranges(in text: String, query: String) -> [Range<String.Index>] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, !text.isEmpty else { return [] }

        var ranges: [Range<String.Index>] = []
        var cursor = text.startIndex
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        while cursor < text.endIndex,
              let found = text.range(of: needle, options: options, range: cursor..<text.endIndex) {
            ranges.append(found)
            cursor = found.upperBound
        }
        return ranges
    }

    /// 生成带高亮的 `AttributedString`；无查询或无命中时返回纯文本。
    public static func attributed(
        _ text: String,
        query: String,
        highlightBackground: Color = Color.yellow.opacity(0.45),
        highlightForeground: Color? = nil
    ) -> AttributedString {
        var attributed = AttributedString(text)
        for range in ranges(in: text, query: query) {
            guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed) else {
                continue
            }
            attributed[lower..<upper].backgroundColor = highlightBackground
            if let highlightForeground {
                attributed[lower..<upper].foregroundColor = highlightForeground
            }
        }
        return attributed
    }
}
