import CoreGraphics
import Foundation
import NovPoolCore
import PDFKit

/// PDF 内容提取：优先使用文件自带的文字层（毫秒级、零算力），
/// 仅当文字层缺失（扫描件）时才回退到逐页栅格化 + Vision OCR。
public enum PDFContentExtractor {
    /// 文字层字符数低于该阈值即认为「无有效文字层」（扫描件 / 纯图片 PDF）。
    public static let minimumTextLayerCharacters = 40

    public struct TextLayer: Sendable, Equatable {
        public let text: String
        public let pageCount: Int
        public let characterCount: Int

        public var isUsable: Bool { characterCount >= PDFContentExtractor.minimumTextLayerCharacters }
    }

    /// 读取文字层。文件不可解析时返回 `nil`。
    public static func textLayer(at url: URL) -> TextLayer? {
        guard let document = PDFDocument(url: url) else { return nil }
        let raw = document.string ?? ""
        let normalized = normalize(raw)
        return TextLayer(
            text: normalized,
            pageCount: document.pageCount,
            characterCount: normalized.count
        )
    }

    /// 收敛 PDF 文字层里的碎片换行：同一段落内的硬换行合并为空格，
    /// 保留空行分段，避免把整篇文档打散成一行行短句。
    public static func normalize(_ raw: String) -> String {
        let lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        var paragraphs: [String] = []
        var current = ""
        for line in lines {
            if line.isEmpty {
                if !current.isEmpty {
                    paragraphs.append(current)
                    current = ""
                }
                continue
            }
            if current.isEmpty {
                current = line
            } else if current.hasSuffix("-") {
                // 英文断词换行：去掉连字符直接拼接。
                current = String(current.dropLast()) + line
            } else {
                current += " " + line
            }
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 扫描版 PDF 的逐页栅格化器。
public enum PDFPageRasterizer {
    public struct RasterizedPage: Sendable {
        public let image: CGImage
        public let pageIndex: Int
    }

    /// 默认 2x 缩放：在字体清晰度与 OCR 耗时之间取平衡。
    public static let defaultScale: CGFloat = 2
    /// 单次 OCR 最多处理的页数，避免 200 页扫描件把流水线拖死。
    public static let defaultMaxPages = 10

    public static func rasterize(
        pagesAt url: URL,
        maxPages: Int = PDFPageRasterizer.defaultMaxPages,
        scale: CGFloat = PDFPageRasterizer.defaultScale
    ) -> [RasterizedPage] {
        guard let document = PDFDocument(url: url) else { return [] }
        let limit = max(0, min(maxPages, document.pageCount))
        return (0..<limit).compactMap { index in
            guard let page = document.page(at: index), let image = rasterize(page: page, scale: scale) else {
                return nil
            }
            return RasterizedPage(image: image, pageIndex: index)
        }
    }

    public static func rasterize(page: PDFPage, scale: CGFloat = PDFPageRasterizer.defaultScale) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let width = Int((bounds.width * scale).rounded())
        let height = Int((bounds.height * scale).rounded())
        guard width > 0, height > 0 else { return nil }

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        // 先铺白底：PDF 页面本身透明，直接 OCR 透明背景会显著降低识别率。
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }
}
