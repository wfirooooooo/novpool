import AppKit
import CoreGraphics
import Foundation
import NovPoolCore
import Testing
import Vision
@testable import NovPoolSystemBridge

/// Vision OCR 需要系统 ANE 服务；在无 GUI / 受限沙盒环境中不可用，此时相关用例自动跳过。
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

@Suite("端侧 OCR 与 PDF 内容提取")
struct OCRTests {
    // MARK: - 阅读顺序（纯逻辑）

    @Test("按页 → 行（上到下）→ 行内（左到右）重排")
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

    @Test("中英混排：中文之间不补空格，英文之间补空格")
    func joinRules() {
        #expect(TextBlockOrdering.needsSpace(between: "多云", and: "路由") == false)
        #expect(TextBlockOrdering.needsSpace(between: "Hello", and: "world"))
        #expect(TextBlockOrdering.needsSpace(between: "多云", and: "Architecture") == true)
    }

    @Test("低置信度结果被丢弃")
    func confidenceFiltering() {
        let blocks = [
            TextBlock(text: "可信内容", boundingBox: CGRect(x: 0, y: 0.8, width: 0.4, height: 0.05), confidence: 0.95),
            TextBlock(text: "噪声乱码", boundingBox: CGRect(x: 0, y: 0.5, width: 0.4, height: 0.05), confidence: 0.05),
        ]
        let text = TextBlockOrdering.orderedText(from: blocks)
        #expect(text == "可信内容")
    }

    @Test("多页结果按页序拼接")
    func multiPageOrdering() {
        let blocks = [
            TextBlock(text: "第二页", boundingBox: CGRect(x: 0, y: 0.5, width: 0.3, height: 0.05), confidence: 0.9, pageIndex: 1),
            TextBlock(text: "第一页", boundingBox: CGRect(x: 0, y: 0.5, width: 0.3, height: 0.05), confidence: 0.9, pageIndex: 0),
        ]
        #expect(TextBlockOrdering.orderedText(from: blocks) == "第一页\n第二页")
    }

    // MARK: - PDF

    @Test("数字版 PDF 直接读文字层，无需 OCR")
    func textLayerExtraction() throws {
        let directory = try TestSupport.makeTemporaryDirectory("pdf")
        let url = directory.appending(path: "report.pdf")
        let body = """
        多云知识路由中枢实践记录：本文说明本地暂存、SHA256 去重、端侧 OCR、\
        网页正文提取与多云归档流水线的整体设计，并给出跨云级联同步的验收标准。
        """
        #expect(TestSupport.makePDF(text: body, at: url, pageCount: 3))

        let layer = try #require(PDFContentExtractor.textLayer(at: url))
        #expect(layer.isUsable)
        #expect(layer.pageCount == 3)
        #expect(layer.text.contains("多云知识路由中枢"))
        #expect(layer.characterCount > PDFContentExtractor.minimumTextLayerCharacters)

        #expect(PDFTextSource.decide(textLayer: layer) == .textLayer(layer.text))
    }

    @Test("文字层碎片换行收敛为段落，断词连字符拼接")
    func textLayerNormalization() {
        let raw = "第一行文字\n第二行文字\n\n\n第三段\n\nmulti-\nline word\n"
        let normalized = PDFContentExtractor.normalize(raw)
        #expect(normalized.contains("第一行文字 第二行文字"))
        #expect(normalized.contains("multiline word"))
        #expect(normalized.components(separatedBy: "\n\n").count == 3)
    }

    @Test("缺失文字层的 PDF 判定为需要 OCR")
    func scannedPDFRequiresOCR() {
        #expect(PDFTextSource.decide(textLayer: nil) == .unreadable)
        let thin = PDFContentExtractor.TextLayer(text: "页眉", pageCount: 12, characterCount: 2)
        #expect(PDFTextSource.decide(textLayer: thin) == .needsOCR(pageCount: 12))
    }

    @Test("逐页栅格化：尺寸为 2x 页面尺寸且页面内容非空白")
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

    @Test("栅格化页数受 maxPages 限制")
    func rasterizationPageLimit() throws {
        let directory = try TestSupport.makeTemporaryDirectory("raster-limit")
        let url = directory.appending(path: "many.pdf")
        #expect(TestSupport.makePDF(text: "page", at: url, pageCount: 6))
        #expect(PDFPageRasterizer.rasterize(pagesAt: url, maxPages: 2).count == 2)
    }

    /// 页面渲染后应存在深色像素（证明确实把页面画进了位图）。
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

    // MARK: - 真实 OCR（依赖系统 ANE，环境不支持时自动跳过）

    @Test("端侧 OCR 识别中英混排图片", .enabled(if: VisionEnvironment.isAvailable))
    func recognizesMixedTextImage() async throws {
        let data = try #require(TestSupport.pngData("NovPool 多云路由 2026"))
        let service = VisionOCRService()
        let result = try await service.recognize(imageData: data)
        #expect(result.text.contains("NovPool"))
        #expect(result.text.contains("多云") || result.text.contains("路由"))
        #expect(result.origin == .visionOCR)
        #expect(result.averageConfidence > 0.3)
    }

    @Test("扫描版 PDF 走 OCR 分支", .enabled(if: VisionEnvironment.isAvailable))
    func recognizesScannedPDF() async throws {
        let directory = try TestSupport.makeTemporaryDirectory("scan-ocr")
        let url = directory.appending(path: "scan.pdf")
        #expect(TestSupport.makePDF(text: "NovPool scan", at: url, pageCount: 1))

        let service = VisionOCRService()
        let result = try await service.recognizePDF(at: url)
        #expect(result.text.contains("NovPool"))
    }

    @Test("损坏的图片数据抛出 unsupportedContent 而非崩溃")
    func rejectsInvalidImageData() async {
        let service = VisionOCRService()
        await #expect(throws: NovPoolError.self) {
            try await service.recognize(imageData: Data([0x00, 0x01, 0x02]))
        }
    }
}
