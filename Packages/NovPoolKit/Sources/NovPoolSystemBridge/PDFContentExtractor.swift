import CoreGraphics
import Foundation
import NovPoolCore
import PDFKit

/// PDF content extraction: prioritize using the text layer built into the file (millisecond-level, zero computing power).
/// Only fallback to page-by-page rasterization + Vision OCR when the text layer is missing (scanned documents).
public enum PDFContentExtractor {
    /// If the number of characters in the text layer is below this threshold, it is considered 'no valid text layer' (scanned copy / pure Image PDF).
    public static let minimumTextLayerCharacters = 40

    public struct TextLayer: Sendable, Equatable {
        public let text: String
        public let pageCount: Int
        public let characterCount: Int

        public var isUsable: Bool { characterCount >= PDFContentExtractor.minimumTextLayerCharacters }
    }

    /// read text layer. Returns `nil` when the file cannot be parsed.
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

    /// Consolidate line breaks in the PDF text layer: merge hard line breaks within the same paragraph into spaces,
    /// Keep blank lines for paragraphs, and avoid breaking the entire document into short lines.
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
                // English word break line: remove the hyphen and directly concatenate.
                current = String(current.dropLast()) + line
            } else {
                current += " " + line
            }
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A page-by-page rasterizer for scanned PDFs.
public enum PDFPageRasterizer {
    public struct RasterizedPage: Sendable {
        public let image: CGImage
        public let pageIndex: Int
    }

    /// Default 2x scaling: balances font clarity and OCR processing time.
    public static let defaultScale: CGFloat = 2
    /// The maximum number of pages a single OCR process can handle, to prevent a 200-page scan from choking the pipeline.
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

        // Lay a white background first: PDF pages are inherently transparent, and performing OCR directly on a transparent background will significantly reduce the recognition rate.
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }
}
