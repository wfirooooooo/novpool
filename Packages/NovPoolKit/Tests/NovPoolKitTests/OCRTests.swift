import AppKit
import CoreGraphics
import Foundation
import NovPoolCore
import Testing
import Vision
@testable import NovPoolSystemBridge

/// Vision OCR requires the system ANE service; it is not available in environments without a GUI / with restricted sandbox, and in such cases, the relevant use cases are automatically skipped.
enum VisionEnvironment {
    static let isAvailable: Bool = {
        guard let image = TestSupport.makeTextImage("NovPool") else { return false }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            return !(request.results ?? []).isEmpty
        } catch {
            return false
        }
    }()
}

@Suite("Edge-side OCR and PDF content extraction")
struct OCRTests {
    // MARK: - Reading Order (Pure Logic)

    @Test("Reorder by page → line (top to bottom) → within line (left to right)")
    func readingOrder() {
        let blocks = [
            TextBlock(text: "第二行", boundingBox: CGRect(x: 0.1, y: 0.20, width: 0.3, height: 0.05), confidence: 0.9),
            TextBlock(text: "右", boundingBox: CGRect(x: 0.55, y: 0.60, width: 0.2, height: 0.05), confidence: 0.9),
            TextBlock(text: "左", boundingBox: CGRect(x: 0.10, y: 0.60, width: 0.2, height: 0.05), confidence: 0.9),
            TextBlock(text: "第一行", boundingBox: CGRect(x: 0.1, y: 0.80, width: 0.3, height: 0.05), confidence: 0.9),
        ]
        let text = TextBlockOrdering.orderedText(from: blocks)
        #expect(text == "第一行\n左右\n第二行")
    }

    @Test("Mixed Chinese and English: no spaces between CJK characters, spaces between English words")
    func joinRules() {
        #expect(TextBlockOrdering.needsSpace(between: "多云", and: "路由") == false)
        #expect(TextBlockOrdering.needsSpace(between: "Hello", and: "world"))
        #expect(TextBlockOrdering.needsSpace(between: "多云", and: "Architecture") == true)
    }

    @Test("Low-confidence results are discarded")
    func confidenceFiltering() {
        let blocks = [
            TextBlock(text: "Reliable content", boundingBox: CGRect(x: 0, y: 0.8, width: 0.4, height: 0.05), confidence: 0.95),
            TextBlock(text: "Noise garbled text", boundingBox: CGRect(x: 0, y: 0.5, width: 0.4, height: 0.05), confidence: 0.05),
        ]
        let text = TextBlockOrdering.orderedText(from: blocks)
        #expect(text == "Reliable content")
    }

    @Test("Multi-page results concatenated in page order")
    func multiPageOrdering() {
        let blocks = [
            TextBlock(text: "Page 2", boundingBox: CGRect(x: 0, y: 0.5, width: 0.3, height: 0.05), confidence: 0.9, pageIndex: 1),
            TextBlock(text: "First page", boundingBox: CGRect(x: 0, y: 0.5, width: 0.3, height: 0.05), confidence: 0.9, pageIndex: 0),
        ]
        #expect(TextBlockOrdering.orderedText(from: blocks) == "First page\nPage 2")
    }

    // MARK: - PDF

    @Test("Digital PDF directly reads the text layer, no OCR required")
    func textLayerExtraction() throws {
        let directory = try TestSupport.makeTemporaryDirectory("pdf")
        let url = directory.appending(path: "report.pdf")
        let body = """
        Multi-cloud Cloud Knowledge Routing Hub practice notes: local staging, SHA256 dedupe, on-device OCR, \
        web body extraction and the multi-cloud archive pipeline, plus cascade sync acceptance criteria.
        """
        #expect(TestSupport.makePDF(text: body, at: url, pageCount: 3))

        let layer = try #require(PDFContentExtractor.textLayer(at: url))
        #expect(layer.isUsable)
        #expect(layer.pageCount == 3)
        #expect(layer.text.contains("Cloud Knowledge Routing Hub"))
        #expect(layer.characterCount > PDFContentExtractor.minimumTextLayerCharacters)

        #expect(PDFTextSource.decide(textLayer: layer) == .textLayer(layer.text))
    }

    @Test("Text layer fragments wrap into paragraphs, word breaks and hyphens are joined")
    func textLayerNormalization() {
        let raw = "First line of text\nSecond line of text\n\n\nThird paragraph\n\nmulti-\nline word\n"
        let normalized = PDFContentExtractor.normalize(raw)
        #expect(normalized.contains("First line of text Second line of text"))
        #expect(normalized.contains("multiline word"))
        #expect(normalized.components(separatedBy: "\n\n").count == 3)
    }

    @Test("PDFs missing a text layer are deemed to require OCR")
    func scannedPDFRequiresOCR() {
        #expect(PDFTextSource.decide(textLayer: nil) == .unreadable)
        let thin = PDFContentExtractor.TextLayer(text: "Header", pageCount: 12, characterCount: 2)
        #expect(PDFTextSource.decide(textLayer: thin) == .needsOCR(pageCount: 12))
    }

    @Test("Paginated Rasterization: Size is 2x page size and page content is not blank")
    func rasterization() throws {
        let directory = try TestSupport.makeTemporaryDirectory("raster")
        let url = directory.appending(path: "scan.pdf")
        #expect(TestSupport.makePDF(text: "Scan target", at: url, pageCount: 2))

        let pages = PDFPageRasterizer.rasterize(pagesAt: url, maxPages: 5, scale: 2)
        #expect(pages.count == 2)
        for page in pages {
            #expect(page.image.width == 1224)
            #expect(page.image.height == 1584)
        }
        #expect(Self.hasDarkPixels(pages[0].image))
    }

    @Test("The number of rasterized pages is limited by maxPages")
    func rasterizationPageLimit() throws {
        let directory = try TestSupport.makeTemporaryDirectory("raster-limit")
        let url = directory.appending(path: "many.pdf")
        #expect(TestSupport.makePDF(text: "page", at: url, pageCount: 6))
        #expect(PDFPageRasterizer.rasterize(pagesAt: url, maxPages: 2).count == 2)
    }

    /// After the page is rendered, there should be dark pixels (to prove that the page was indeed drawn into the bitmap).
    static func hasDarkPixels(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data,
              let pointer = CFDataGetBytePtr(data) else { return false }
        let bytesPerPixel = image.bitsPerPixel / 8
        let stride = image.bytesPerRow
        for y in Swift.stride(from: 0, to: image.height, by: 8) {
            for x in Swift.stride(from: 0, to: image.width, by: 8) {
                let offset = y * stride + x * bytesPerPixel
                if pointer[offset] < 100 { return true }
            }
        }
        return false
    }

    // MARK: - Real OCR (relies on system ANE, automatically skipped if the environment is not supported)

    @Test("Edge-side OCR Recognition of Mixed Chinese and English Image", .enabled(if: VisionEnvironment.isAvailable))
    func recognizesMixedTextImage() async throws {
        let data = try #require(TestSupport.pngData("NovPool Cloud Router 2026"))
        let service = VisionOCRService()
        let result = try await service.recognize(imageData: data)
        #expect(result.text.contains("NovPool"))
        #expect(result.text.contains("Cloudy") || result.text.contains("Router"))
        #expect(result.origin == .visionOCR)
        #expect(result.averageConfidence > 0.3)
    }

    @Test("Scanned PDF goes through the OCR branch", .enabled(if: VisionEnvironment.isAvailable))
    func recognizesScannedPDF() async throws {
        let directory = try TestSupport.makeTemporaryDirectory("scan-ocr")
        let url = directory.appending(path: "scan.pdf")
        #expect(TestSupport.makePDF(text: "NovPool scan", at: url, pageCount: 1))

        let service = VisionOCRService()
        let result = try await service.recognizePDF(at: url)
        #expect(result.text.contains("NovPool"))
    }

    @Test("Damaged Image data throws unsupportedContent instead of crashing")
    func rejectsInvalidImageData() async {
        let service = VisionOCRService()
        await #expect(throws: NovPoolError.self) {
            try await service.recognize(imageData: Data([0x00, 0x01, 0x02]))
        }
    }
}
