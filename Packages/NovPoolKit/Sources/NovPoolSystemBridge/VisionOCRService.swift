import CoreGraphics
import Foundation
import ImageIO
import NovPoolCore
import Vision

/// Edge-side ANE Text Recognition (Chinese-English Mixed)
///
/// Using `Vision.framework`: zero network, zero third-party dependencies, Neural Engine hardware acceleration.
public actor VisionOCRService {
    public struct Configuration: Sendable, Equatable {
        public var recognitionLanguages: [String]
        public var usesLanguageCorrection: Bool
        public var minimumConfidence: Float
        public var pdfRenderScale: CGFloat
        public var maxPDFPages: Int

        public init(
            recognitionLanguages: [String] = ["zh-Hans", "zh-Hant", "en-US"],
            usesLanguageCorrection: Bool = true,
            minimumConfidence: Float = TextBlockOrdering.minimumConfidence,
            pdfRenderScale: CGFloat = PDFPageRasterizer.defaultScale,
            maxPDFPages: Int = PDFPageRasterizer.defaultMaxPages
        ) {
            self.recognitionLanguages = recognitionLanguages
            self.usesLanguageCorrection = usesLanguageCorrection
            self.minimumConfidence = minimumConfidence
            self.pdfRenderScale = pdfRenderScale
            self.maxPDFPages = maxPDFPages
        }
    }

    private let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Identify the Image byte stream in memory (WebImage dragged into P1 follows this path).
    public func recognize(imageData: Data) throws -> TextRecognitionResult {
        guard let image = Self.decodeImage(imageData) else {
            throw NovPoolError.unsupportedContent
        }
        return try recognize(cgImage: image)
    }

    /// Recognize a single bitmap.
    public func recognize(cgImage: CGImage, pageIndex: Int = 0) throws -> TextRecognitionResult {
        let request = makeRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        let blocks = (request.results ?? []).compactMap { observation -> TextBlock? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return TextBlock(
                text: candidate.string,
                boundingBox: observation.boundingBox,
                confidence: candidate.confidence,
                pageIndex: pageIndex
            )
        }
        return Self.makeResult(from: blocks)
    }

    /// Scanned PDF: OCR after rasterizing page by page, separated by blank lines between pages.
    public func recognizePDF(at url: URL) throws -> TextRecognitionResult {
        let pages = PDFPageRasterizer.rasterize(
            pagesAt: url,
            maxPages: configuration.maxPDFPages,
            scale: configuration.pdfRenderScale
        )
        guard !pages.isEmpty else { throw NovPoolError.unsupportedContent }

        var allBlocks: [TextBlock] = []
        var pageTexts: [String] = []
        for page in pages {
            let result = try recognize(cgImage: page.image, pageIndex: page.pageIndex)
            allBlocks.append(contentsOf: result.blocks)
            if !result.text.isEmpty { pageTexts.append(result.text) }
        }
        return TextRecognitionResult(
            text: pageTexts.joined(separator: "\n\n"),
            blocks: allBlocks,
            origin: .visionOCR
        )
    }

    // MARK: - Internals

    private func makeRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = configuration.recognitionLanguages
        request.usesLanguageCorrection = configuration.usesLanguageCorrection
        return request
    }

    static func makeResult(from blocks: [TextBlock]) -> TextRecognitionResult {
        TextRecognitionResult(
            text: TextBlockOrdering.orderedText(from: blocks),
            blocks: blocks,
            origin: .visionOCR
        )
    }

    static func decodeImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
