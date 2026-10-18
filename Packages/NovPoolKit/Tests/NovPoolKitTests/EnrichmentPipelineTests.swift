import Foundation
import CoreGraphics
import NovPoolCore
import NovPoolStorage
import Testing
@testable import NovPoolSystemBridge

@Suite("Multimodal Completion Pipeline")
struct EnrichmentPipelineTests {
    private struct Harness {
        let database: NovPoolDatabase
        let repository: KnowledgeRepository
        let staging: StagingStore
        let orchestrator: IngestionOrchestrator
        let directory: URL
    }

    private func makeHarness(
        ocr: any ImageTextRecognizing = FakeOCR(),
        fetcher: any ArticleFetching = FakeFetcher(result: .unparseable),
        ai: any AIEnriching = FakeAI(enrichment: AIEnrichment(summary: "AI Summary", category: "Technology", tags: ["Label"], embedding: [0.5, 0.25])),
        configuration: EnrichmentPipeline.Configuration = .init()
    ) async throws -> Harness {
        let directory = try TestSupport.makeTemporaryDirectory("enrich")
        let database = try NovPoolDatabase(path: directory.appending(path: "db.sqlite").path(percentEncoded: false))
        try await SchemaMigrator.migrate(database)
        let staging = try StagingStore(root: directory.appending(path: "Staging", directoryHint: .isDirectory))
        let pipeline = EnrichmentPipeline(
            ocr: ocr,
            fetcher: fetcher,
            ai: ai,
            staging: staging,
            configuration: configuration
        )
        let orchestrator = IngestionOrchestrator(
            database: database,
            staging: staging,
            browserContext: FakeBrowserContext(context: SourceContext(appBundleID: "com.google.Chrome")),
            enricher: pipeline
        )
        return Harness(
            database: database,
            repository: KnowledgeRepository(database: database),
            staging: staging,
            orchestrator: orchestrator,
            directory: directory
        )
    }

    @Test("Image entry: OCR text and AI tags, embedding batched back and entered into FTS index")
    func imageEnrichment() async throws {
        let harness = try await makeHarness(ocr: FakeOCR(imageText: "Apple Neural Engine Neural network acceleration"))
        let bytes = try #require(TestSupport.pngData("Apple Neural Engine Neural network acceleration"))
        let content = ResolvedDragContent(
            contentType: .image,
            imageData: bytes,
            imageTypeIdentifier: "public.png"
        )

        let result = try await harness.orchestrator.ingestAndEnrich(
            content,
            sourceContext: SourceContext(appBundleID: "com.apple.Safari", pageURL: URL(string: "https://x.com/a"))
        )

        #expect(result.enrichment?.ocrText != nil)
        #expect(result.record.ocrText == "Apple Neural Engine Neural network acceleration")
        #expect(result.record.aiSummary == "AI Summary")
        #expect(result.record.aiTags == ["Label"])
        #expect(result.record.embedding?.count == 2)

        // After backfilling, it can be immediately hit by full-text search (FTS trigger synchronization).
        let hits = try await harness.repository.searchFullText("Neural network acceleration")
        #expect(hits.count == 1)
        #expect(hits.first?.id == result.record.id)
    }

    @Test("WebLink entry: fetch Bodywrite markdownBody, weak headings are replaced by real headings")
    func webLinkEnrichment() async throws {
        let article = ArticleExtraction(
            title: "Cloudy Knowledge Routing Practice",
            excerpt: "Summary",
            markdown: "# Cloudy Knowledge Routing Practice\n\nBodySome content.",
            textLength: 300,
            contentSelector: "article"
        )
        let harness = try await makeHarness(fetcher: FakeFetcher(result: .extracted(article)))
        let content = ResolvedDragContent(
            contentType: .webLink,
            pageURL: URL(string: "https://blog.example.com/a"),
            text: "Cloudy Knowledge Routing Practice"
        )

        let result = try await harness.orchestrator.ingestAndEnrich(
            content,
            sourceContext: SourceContext(appBundleID: "com.google.Chrome")
        )
        // The inventory title comes from the user dragging the text and does not need to be overwritten
        #expect(result.record.title == "Cloudy Knowledge Routing Practice")
        #expect(result.record.markdownBody?.contains("BodySome content") == true)

        let hits = try await harness.repository.searchFullText("BodySome content")
        #expect(hits.count == 1)
    }

    @Test("Weak titles (domain only) will be replaced by the actual titles that are crawled")
    func weakTitleAdoption() async throws {
        let article = ArticleExtraction(
            title: "The Real Article Title",
            markdown: String(repeating: "Body。", count: 80),
            textLength: 240,
            contentSelector: "article"
        )
        let harness = try await makeHarness(fetcher: FakeFetcher(result: .extracted(article)))
        let content = ResolvedDragContent(contentType: .webLink, pageURL: URL(string: "https://blog.example.com/a"))

        let result = try await harness.orchestrator.ingestAndEnrich(
            content,
            sourceContext: SourceContext(appBundleID: "com.google.Chrome", pageURL: URL(string: "https://blog.example.com/a"))
        )
        #expect(result.record.title == "The Real Article Title")
    }

    @Test("Digital PDF uses a text layer, does not consume OCR")
    func pdfUsesTextLayer() async throws {
        let harness = try await makeHarness(ocr: FakeOCR(pdfText: "Should not be called"))
        let pdf = harness.directory.appending(path: "report.pdf")
        // Avoid mid-word hyphens: PDF line wrapping + normalize() joins "multi-"+"cloud" into "multicloud".
        let body = "Key Conclusions of the Quarterly Report: the multicloud archive pipeline cleans and indexes locally, then fans out to cloud knowledge bases; large PDFs upload to drive first for a PreviewLink, then cascade into a Notion database record."
        #expect(TestSupport.makePDF(text: body, at: pdf))

        let result = try await harness.orchestrator.ingestAndEnrich(
            ResolvedDragContent(contentType: .documentPDF, fileURLs: [pdf]),
            sourceContext: SourceContext(appBundleID: "com.apple.finder")
        )
        #expect(result.record.ocrText == nil)
        // PDFKit may wrap/normalize spaces; assert on a contiguous token from the text layer.
        #expect(result.record.markdownBody?.contains("PreviewLink") == true)
    }

    @Test("PDF without text layer reverts to OCR")
    func scannedPDFFallsBackToOCR() async throws {
        // Create a PDF without a text layer: only draw graphics, no text.
        let harness = try await makeHarness(ocr: FakeOCR(pdfText: "Scanned OCR results"))
        let pdf = harness.directory.appending(path: "scanned.pdf")
        let url = pdf
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = CGDataConsumer(url: url as CFURL)!
        let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
        context.beginPDFPage(nil)
        context.setFillColor(gray: 0.2, alpha: 1)
        context.fill(CGRect(x: 100, y: 400, width: 200, height: 40))
        context.endPDFPage()
        context.closePDF()

        let result = try await harness.orchestrator.ingestAndEnrich(
            ResolvedDragContent(contentType: .documentPDF, fileURLs: [pdf]),
            sourceContext: SourceContext(appBundleID: "com.apple.finder")
        )
        #expect(result.record.ocrText == "Scanned OCR results")
        #expect(result.record.markdownBody == nil)
    }

    @Test("Local HTML file extracts the Body and enters full-text indexing")
    func localHTMLFileEnrichment() async throws {
        let harness = try await makeHarness(ai: FakeAI(enrichment: nil))
        let file = harness.directory.appending(path: "local-report.html")
        let paragraph = String(repeating: "This is a locally dragged-in HTML FileBody, used to verify knowledge base retrieval.", count: 6)
        let html = """
        <html><head><title>Local report</title></head>
        <body><article><h1>Local report</h1><p>\(paragraph)</p></article></body></html>
        """
        try Data(html.utf8).write(to: file)

        let result = try await harness.orchestrator.ingestAndEnrich(
            ResolvedDragContent(contentType: .genericFile, fileURLs: [file]),
            sourceContext: SourceContext(appBundleID: "com.apple.finder")
        )

        #expect(result.record.markdownBody?.contains("locally dragged-in HTML FileBody") == true)
        let hits = try await harness.repository.searchFullText("locally dragged-in HTML FileBody")
        #expect(hits.first?.id == result.record.id)
    }

    @Test("This machine's Plain Text and code File are directly used as BodySave")
    func plainTextFileEnrichment() async throws {
        let harness = try await makeHarness(ai: FakeAI(enrichment: nil))
        let file = harness.directory.appending(path: "release-notes.md")
        try Data("# Release Notes\n\nInterface adjustments and drag-and-drop fixes.".utf8).write(to: file)

        let result = try await harness.orchestrator.ingestAndEnrich(
            ResolvedDragContent(contentType: .genericFile, fileURLs: [file]),
            sourceContext: SourceContext(appBundleID: "com.apple.finder")
        )

        #expect(result.record.markdownBody?.contains("drag-and-drop fixes") == true)
    }

    @Test("Unable to extract Text from the File, but still generate File information Preview")
    func binaryFileGetsSummary() async throws {
        let harness = try await makeHarness(ai: FakeAI(enrichment: nil))
        let file = harness.directory.appending(path: "archive.docx")
        try Data(repeating: 0x50, count: 512).write(to: file)

        let result = try await harness.orchestrator.ingestAndEnrich(
            ResolvedDragContent(contentType: .genericFile, fileURLs: [file]),
            sourceContext: SourceContext(appBundleID: "com.apple.finder")
        )

        #expect(result.record.markdownBody?.contains("## File info") == true)
        #expect(result.record.markdownBody?.contains("archive.docx") == true)
        #expect(result.record.markdownBody?.contains("DOCX file") == true)
    }

    @Test("Enabling backfill can find and complete local files missing a Body")
    func legacyFileBackfill() async throws {
        let harness = try await makeHarness(ai: FakeAI(enrichment: nil))
        let file = harness.directory.appending(path: "legacy.html")
        let paragraph = String(repeating: "Native Files dragged in from the old version have no Body, and it should be automatically completed upon startup.", count: 6)
        try Data("<html><body><article><p>\(paragraph)</p></article></body></html>".utf8).write(to: file)

        let item = try await harness.orchestrator.ingest(
            ResolvedDragContent(contentType: .genericFile, fileURLs: [file]),
            sourceContext: SourceContext(appBundleID: "com.apple.finder")
        )
        #expect(item.record.markdownBody == nil)
        #expect(try await harness.repository.recordsNeedingLocalFileContent().map(\.id) == [item.record.id])

        _ = await harness.orchestrator.enrichAfterIngest(itemID: item.record.id)

        #expect(try await harness.repository.recordsNeedingLocalFileContent().isEmpty)
        let record = try #require(try await harness.repository.fetch(id: item.record.id))
        #expect(record.markdownBody?.contains("automatically completed") == true)
    }

    @Test("OCR failure does not affect the storage result")
    func ocrFailureIsolation() async throws {
        let harness = try await makeHarness(ocr: FakeOCR(shouldFail: true))
        let bytes = try #require(TestSupport.pngData("Any Image"))
        let result = try await harness.orchestrator.ingestAndEnrich(
            ResolvedDragContent(contentType: .image, imageData: bytes, imageTypeIdentifier: "public.png"),
            sourceContext: SourceContext(appBundleID: "com.apple.Safari")
        )
        #expect(result.item.isDuplicate == false)
        #expect(result.record.ocrText == nil)
        #expect(try await harness.repository.count() == 1)
    }

    @Test("When capture fails, no backfill is done, but the item remains in the database")
    func fetchFailureIsolation() async throws {
        let harness = try await makeHarness(fetcher: FakeFetcher(result: .httpError(status: 403)))
        let result = try await harness.orchestrator.ingestAndEnrich(
            ResolvedDragContent(contentType: .webLink, pageURL: URL(string: "https://blocked.example.com/a")),
            sourceContext: SourceContext(appBundleID: "com.google.Chrome")
        )
        #expect(result.record.markdownBody == nil)
        #expect(result.enrichment == nil)
        #expect(try await harness.repository.count() == 1)
    }

    @Test("After closing OCR and AI, still generate the preview information of the local file")
    func disabledEnrichment() async throws {
        let harness = try await makeHarness(
            configuration: .init(runOCR: false, extractWebContent: false, runAI: false)
        )
        let bytes = try #require(TestSupport.pngData("Any Image"))
        let result = try await harness.orchestrator.ingestAndEnrich(
            ResolvedDragContent(contentType: .image, imageData: bytes, imageTypeIdentifier: "public.png"),
            sourceContext: SourceContext(appBundleID: "com.apple.Safari")
        )
        #expect(result.enrichment?.markdownBody?.contains("## File info") == true)
        #expect(result.record.ocrText == nil)
        #expect(result.record.aiSummary == nil)
    }

    @Test("Plain Text entries only call AI when there is a Body; if the Body is missing, it is skipped.")
    func plainTextSkipsAIWithoutBody() async throws {
        let ai = FakeAI(enrichment: AIEnrichment(summary: "Should not appear"))
        let harness = try await makeHarness(ai: ai)
        let result = try await harness.orchestrator.ingestAndEnrich(
            ResolvedDragContent(contentType: .genericFile, fileURLs: []),
            sourceContext: SourceContext(appBundleID: "com.apple.finder")
        )
        #expect(result.enrichment == nil)
    }

    @Test("Complete the status bar for floating window notifications")
    func summaryLine() {
        #expect(ContentEnrichment().summaryLine == "Nothing new")
        #expect(ContentEnrichment(ocrText: "t", aiSummary: "s").summaryLine == "OCR·AI tags")
        #expect(ContentEnrichment(markdownBody: "b", embedding: [1]).summaryLine == "Body·Embedding")
    }

    @Test("Title Adoption Strategy: Fallback Titles and Domain Titles Can Be Replaced")
    func titleAdoption() {
        #expect(TitleAdoption.shouldAdopt(current: ""))
        #expect(TitleAdoption.shouldAdopt(current: "Untitled item 2026/3/9"))
        #expect(TitleAdoption.shouldAdopt(current: "example.com"))
        #expect(TitleAdoption.shouldAdopt(current: "Cloudy Knowledge Routing Practice") == false)
    }
}
