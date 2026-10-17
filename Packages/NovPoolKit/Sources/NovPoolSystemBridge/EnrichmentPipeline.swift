import Foundation
import NovPoolCore
import NovPoolStorage

/// 图像 / PDF 文本识别抽象（`VisionOCRService` 的真实实现依赖 ANE，测试可注入替身）。
public protocol ImageTextRecognizing: Sendable {
    func recognizeImageText(data: Data) async throws -> TextRecognitionResult
    func recognizePDFText(at url: URL) async throws -> TextRecognitionResult
}

extension VisionOCRService: ImageTextRecognizing {
    public func recognizeImageText(data: Data) async throws -> TextRecognitionResult {
        try recognize(imageData: data)
    }

    public func recognizePDFText(at url: URL) async throws -> TextRecognitionResult {
        try recognizePDF(at: url)
    }
}

/// 网页抓取抽象。
public protocol ArticleFetching: Sendable {
    func fetchArticle(from url: URL) async -> WebFetchResult
}

extension WebContentFetcher: ArticleFetching {}

/// 结构化增强抽象。
public protocol AIEnriching: Sendable {
    func enrich(_ request: AIEnrichmentRequest) async -> AIEnrichment?
}

extension AIEnhancementService: AIEnriching {}

/// Phase 2 的多模态补齐流水线：
/// 图片 → ANE OCR；PDF → 文字层优先、扫描件 OCR；网页链接 → 正文抓取 + Markdown；
/// 最后统一走 AI 结构化增强与向量化。
public actor EnrichmentPipeline: ContentEnriching {
    public struct Configuration: Sendable {
        public var runOCR: Bool
        public var extractWebContent: Bool
        public var runAI: Bool
        public var categories: [String]

        public init(
            runOCR: Bool = true,
            extractWebContent: Bool = true,
            runAI: Bool = true,
            categories: [String] = []
        ) {
            self.runOCR = runOCR
            self.extractWebContent = extractWebContent
            self.runAI = runAI
            self.categories = categories
        }
    }

    private let ocr: any ImageTextRecognizing
    private let fetcher: any ArticleFetching
    private let ai: any AIEnriching
    private let staging: StagingStore?
    private var configuration: Configuration

    public init(
        ocr: any ImageTextRecognizing,
        fetcher: any ArticleFetching,
        ai: any AIEnriching,
        staging: StagingStore? = nil,
        configuration: Configuration = Configuration()
    ) {
        self.ocr = ocr
        self.fetcher = fetcher
        self.ai = ai
        self.staging = staging
        self.configuration = configuration
    }

    public func update(configuration: Configuration) {
        self.configuration = configuration
    }

    public func enrich(record: KnowledgeItemRecord) async -> ContentEnrichment {
        var result = ContentEnrichment()
        var analysisText = ""

        switch record.contentType {
        case .image:
            if configuration.runOCR, let data = await stagedData(for: record) {
                if let recognized = try? await ocr.recognizeImageText(data: data), !recognized.isEmpty {
                    result.ocrText = recognized.text
                    analysisText = recognized.text
                }
            }

        case .documentPDF:
            await enrichPDF(record: record, result: &result, analysisText: &analysisText)

        case .video:
            // 视频不做 OCR；若将来有字幕/AI 描述，在这里接入。
            break

        case .webLink:
            if configuration.extractWebContent,
               let url = record.sourceURL.flatMap(URL.init(string:)) {
                let fetched = await fetcher.fetchArticle(from: url)
                if let article = fetched.article {
                    result.markdownBody = article.markdown
                    analysisText = article.markdown
                    if TitleAdoption.shouldAdopt(current: record.title) {
                        result.title = article.title
                    }
                }
            }

        case .genericFile:
            await enrichLocalFile(record: record, result: &result, analysisText: &analysisText)

        case .richHTML, .plainText:
            break
        }

        // 图片 OCR 关闭/失败、PDF 不可读、视频与二进制文件都不会产生正文。
        // 至少写入文件信息，保证检索详情有内容，也避免空条目出现在 FTS 之外。
        if result.markdownBody == nil, result.ocrText == nil,
           let url = await stagedURL(for: record) {
            result.markdownBody = LocalFileContent.summary(for: url)
        }

        if analysisText.isEmpty {
            analysisText = [record.markdownBody, record.ocrText]
                .compactMap { $0 }
                .joined(separator: "\n\n")
        }

        if configuration.runAI, !analysisText.isEmpty {
            let request = AIEnrichmentRequest(
                title: result.title ?? record.title,
                text: analysisText,
                contentType: record.contentType,
                sourceURL: record.sourceURL.flatMap(URL.init(string:)),
                sourceTitle: record.sourceTitle,
                categories: configuration.categories
            )
            if let enrichment = await ai.enrich(request) {
                result.aiSummary = enrichment.summary
                result.aiCategory = enrichment.category
                result.aiTags = enrichment.tags.isEmpty ? nil : enrichment.tags
                result.embedding = enrichment.embedding
                if result.title == nil,
                   let extracted = enrichment.title,
                   TitleAdoption.shouldAdopt(current: record.title) {
                    result.title = extracted
                }
            }
        }

        return result
    }

    private func enrichPDF(
        record: KnowledgeItemRecord,
        result: inout ContentEnrichment,
        analysisText: inout String
    ) async {
        guard let url = await stagedURL(for: record) else { return }
        switch PDFTextSource.decide(textLayer: PDFContentExtractor.textLayer(at: url)) {
        case .textLayer(let text):
            // 数字版 PDF 直接使用自带文字层：毫秒级、零算力，且比 OCR 更准。
            result.markdownBody = text
            analysisText = text
        case .needsOCR:
            guard configuration.runOCR else { return }
            if let recognized = try? await ocr.recognizePDFText(at: url), !recognized.isEmpty {
                result.ocrText = recognized.text
                analysisText = recognized.text
            }
        case .unreadable:
            break
        }
    }

    private func enrichLocalFile(
        record: KnowledgeItemRecord,
        result: inout ContentEnrichment,
        analysisText: inout String
    ) async {
        guard let url = await stagedURL(for: record),
              let extracted = LocalFileContent.extract(from: url) else {
            return
        }
        result.markdownBody = extracted.markdown
        analysisText = extracted.markdown
        if let title = extracted.title,
           TitleAdoption.shouldAdopt(current: record.title) {
            result.title = title
        }
    }

    private func stagedURL(for record: KnowledgeItemRecord) async -> URL? {
        guard let staging, let relativePath = record.localRelativePath else { return nil }
        let url = await staging.absoluteURL(forRelativePath: relativePath)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    private func stagedData(for record: KnowledgeItemRecord) async -> Data? {
        guard let url = await stagedURL(for: record) else { return nil }
        return try? Data(contentsOf: url)
    }
}
