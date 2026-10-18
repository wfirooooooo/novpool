import Foundation
import SwiftUI

/// Keyword Highlight in Search: Highlight the segments that match the query string in the title/preview.
public enum SearchHighlight {
    /// Find all occurrences of `query` in `text` case-insensitively (advance by character boundaries, non-overlapping).
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

    /// Generate an `AttributedString` with highlights; return Plain Text when there is no query or no hit.
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
