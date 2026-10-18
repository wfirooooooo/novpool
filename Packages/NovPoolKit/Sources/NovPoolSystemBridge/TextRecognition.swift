import CoreGraphics
import Foundation

/// A recognized text block. Coordinates follow the Vision convention: normalized, origin at the bottom left.
public struct TextBlock: Sendable, Equatable {
    public let text: String
    public let boundingBox: CGRect
    public let confidence: Float
    public let pageIndex: Int

    public init(text: String, boundingBox: CGRect, confidence: Float, pageIndex: Int = 0) {
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.pageIndex = pageIndex
    }
}

/// Recognition result.
public struct TextRecognitionResult: Sendable, Equatable {
    public let text: String
    public let blocks: [TextBlock]
    /// Data source: PDF with built-in text layer, or edge-side OCR.
    public let origin: Origin

    public enum Origin: String, Sendable, Equatable {
        case pdfTextLayer
        case visionOCR
    }

    public init(text: String, blocks: [TextBlock], origin: Origin) {
        self.text = text
        self.blocks = blocks
        self.origin = origin
    }

    public var isEmpty: Bool { text.isEmpty }

    public var averageConfidence: Float {
        guard !blocks.isEmpty else { return 0 }
        return blocks.reduce(0) { $0 + $1.confidence } / Float(blocks.count)
    }

    public static let empty = TextRecognitionResult(text: "", blocks: [], origin: .visionOCR)
}

/// Rearrange the reading order.
///
/// The order of text blocks returned by Vision is not guaranteed to match the order in which the human eye reads them (especially in mixed Chinese and English text or multi-column layouts).
/// Here, reorder according to 'Page → Line (top to bottom) → Inline (left to right)', and decide whether to add a space between adjacent blocks within a line.
public enum TextBlockOrdering {
    /// Row merging tolerance (normalized height). Blocks in the same row are considered the same row if the difference in their center y values is less than this value.
    public static let lineTolerance: CGFloat = 0.02
    /// Recognition results below this confidence level are directly discarded.
    public static let minimumConfidence: Float = 0.3

    public static func orderedText(
        from blocks: [TextBlock],
        lineTolerance: CGFloat = TextBlockOrdering.lineTolerance,
        minimumConfidence: Float = TextBlockOrdering.minimumConfidence
    ) -> String {
        let usable = blocks.filter {
            $0.confidence >= minimumConfidence
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !usable.isEmpty else { return "" }

        var lines: [String] = []
        let pages = Dictionary(grouping: usable, by: \.pageIndex)
        for pageIndex in pages.keys.sorted() {
            guard let pageBlocks = pages[pageIndex] else { continue }
            // Top-down: In Vision, the origin of the y-axis is at the bottom, so the larger the midY, the higher it is.
            let sorted = pageBlocks.sorted { lhs, rhs in
                if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) > lineTolerance {
                    return lhs.boundingBox.midY > rhs.boundingBox.midY
                }
                return lhs.boundingBox.minX < rhs.boundingBox.minX
            }

            var currentLine: [TextBlock] = []
            var currentMidY: CGFloat = 0
            for block in sorted {
                if currentLine.isEmpty {
                    currentLine = [block]
                    currentMidY = block.boundingBox.midY
                    continue
                }
                if abs(block.boundingBox.midY - currentMidY) <= lineTolerance {
                    currentLine.append(block)
                    currentMidY = (currentMidY * CGFloat(currentLine.count - 1) + block.boundingBox.midY)
                        / CGFloat(currentLine.count)
                } else {
                    lines.append(join(currentLine))
                    currentLine = [block]
                    currentMidY = block.boundingBox.midY
                }
            }
            if !currentLine.isEmpty { lines.append(join(currentLine)) }
        }
        return lines.joined(separator: "\n")
    }

    /// Inline concatenation: sort by x, and add spaces between Chinese and English as needed.
    static func join(_ line: [TextBlock]) -> String {
        let ordered = line.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
        return ordered.reduce(into: "") { partial, block in
            let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if partial.isEmpty {
                partial = text
            } else if Self.needsSpace(between: partial, and: text) {
                partial += " " + text
            } else {
                partial += text
            }
        }
    }

    /// No spaces are added when CJK characters are next to each other; in other cases, spaces are added to prevent English words from sticking together.
    static func needsSpace(between left: String, and right: String) -> Bool {
        guard let last = left.unicodeScalars.last, let first = right.unicodeScalars.first else {
            return false
        }
        return !(isCJK(last) && isCJK(first))
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F,   // CJK punctuation
             0x3040...0x30FF,   // Hiragana / Katakana
             0x3400...0x4DBF,   // Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xAC00...0xD7AF,   // Hangul
             0xF900...0xFAFF,   // CJK Compatibility Ideographs
             0xFF00...0xFFEF:   // Fullwidth forms
            true
        default:
            false
        }
    }
}
