import Foundation
import NovPoolCore
import NovPoolStorage

/// Image / PDF Text Recognition Abstraction (the real implementation of `VisionOCRService` depends on ANE, a substitute can be injected for testing).
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

/// Web scraping abstraction.
public protocol ArticleFetching: Sendable {
    func fetchArticle(from url: URL) async -> WebFetchResult
}

extension WebContentFetcher: ArticleFetching {}

/// Structured enhanced abstraction (returns explicit success/failure, making it easier to display the reason in settings).
public protocol AIEnriching: Sendable {
    func enrichDetailed(_ request: AIEnrichmentRequest) async -> AIEnrichmentOutcome
}

extension AIEnriching {
    public func enrich(_ request: AIEnrichmentRequest) async -> AIEnrichment? {
        await enrichDetailed(request).enrichment
    }
}

extension AIEnhancementService: AIEnriching {}

/// Multimodal Completion Pipeline of Phase 2:
/// Image → ANE OCR; PDF → text layer preferred, scanned copies OCR; WebLink → Body capture + Markdown;
/// Finally, unify with AI structured enhancement and embedding.
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
            // Video does not perform OCR; if there are subtitles/AI descriptions in the future, connect them here.
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

        case .richHTML, .plainText, .digest:
            break
        }

        // Image OCR Close/Failed, PDF unreadable, Video and binary files will not generate a Body.
        // At least write the file information to ensure that the retrieval details contain content, and also prevent empty entries from appearing outside FTS.
        if result.markdownBody == nil, result.ocrText == nil,
           let url = await stagedURL(for: record) {
            result.markdownBody = LocalFileContent.summary(for: url)
        }

        if analysisText.isEmpty {
            analysisText = [record.markdownBody, record.ocrText]
                .compactMap { $0 }
                .joined(separator: "\n\n")
        }

        if configuration.runAI {
            let body = analysisText.trimmingCharacters(in: .whitespacesAndNewlines)
            // File-info cards are previews, not source text. Same rule for ingest, re-summarize, and fill-missing.
            if body.isEmpty || FileInfoStub.isOnlyStub(body) {
                result.aiFailureReason = AIEnrichmentQuality.noBodyReason
            } else {
                let request = AIEnrichmentRequest(
                    title: result.title ?? record.title,
                    text: analysisText,
                    contentType: record.contentType,
                    sourceURL: record.sourceURL.flatMap(URL.init(string:)),
                    sourceTitle: record.sourceTitle,
                    categories: configuration.categories
                )
                switch await ai.enrichDetailed(request) {
                case .success(let enrichment):
                    applyModelResult(enrichment, to: &result, record: record)
                case .failure(let reason):
                    result.aiFailureReason = reason
                }
            }
        }

        return result
    }

    /// Writes summary / topic / tags, or a readable failure when the model only returned a file type.
    private func applyModelResult(
        _ enrichment: AIEnrichment,
        to result: inout ContentEnrichment,
        record: KnowledgeItemRecord
    ) {
        let cleaned = AIEnrichmentQuality.sanitize(enrichment)
        let hasTopicFields = cleaned.summary != nil || cleaned.category != nil || !cleaned.tags.isEmpty
        guard hasTopicFields else {
            result.aiFailureReason = AIEnrichmentQuality.fileTypeCategoryReason
            return
        }
        result.aiSummary = cleaned.summary
        result.aiCategory = cleaned.category
        result.aiTags = cleaned.tags.isEmpty ? nil : cleaned.tags
        result.embedding = cleaned.embedding
        if result.title == nil,
           let extracted = cleaned.title,
           TitleAdoption.shouldAdopt(current: record.title) {
            result.title = extracted
        }
    }

    private func enrichPDF(
        record: KnowledgeItemRecord,
        result: inout ContentEnrichment,
        analysisText: inout String
    ) async {
        guard let url = await stagedURL(for: record) else { return }
        switch PDFTextSource.decide(textLayer: PDFContentExtractor.textLayer(at: url)) {
        case .textLayer(let text):
            // The digital PDF directly uses its built-in text layer: millisecond-level, zero computing power, and more accurate than OCR.
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
