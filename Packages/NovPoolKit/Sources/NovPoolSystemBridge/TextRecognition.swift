import CoreGraphics
import Foundation

/// 一个已识别文本块。坐标沿用 Vision 约定：归一化、原点在左下。
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

/// 识别结果。
public struct TextRecognitionResult: Sendable, Equatable {
    public let text: String
    public let blocks: [TextBlock]
    /// 数据来源：PDF 自带文字层、或端侧 OCR。
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

/// 阅读顺序重排。
///
/// Vision 返回的文本块顺序不保证符合人眼阅读顺序（尤其是中英混排、多列排版）。
/// 这里按「页 → 行（上到下）→ 行内（左到右）」重排，并对行内相邻块决定是否补空格。
public enum TextBlockOrdering {
    /// 行归并容差（归一化高度）。同一行的块中心 y 差异小于该值即视为同一行。
    public static let lineTolerance: CGFloat = 0.02
    /// 低于该置信度的识别结果直接丢弃。
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
            // 自上而下：Vision 的 y 轴原点在下方，因此 midY 越大越靠上。
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

    /// 行内拼接：按 x 排序，中英之间按需补空格。
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

    /// CJK 与 CJK 相邻时不补空格；其余情况补空格以免英文单词粘连。
    static func needsSpace(between left: String, and right: String) -> Bool {
        guard let last = left.unicodeScalars.last, let first = right.unicodeScalars.first else {
            return false
        }
        return !(isCJK(last) && isCJK(first))
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F,   // CJK 标点
             0x3040...0x30FF,   // 平假名 / 片假名
             0x3400...0x4DBF,   // 扩展 A
             0x4E00...0x9FFF,   // 基本汉字
             0xAC00...0xD7AF,   // 谚文
             0xF900...0xFAFF,   // 兼容汉字
             0xFF00...0xFFEF:   // 全角字符
            true
        default:
            false
        }
    }
}
