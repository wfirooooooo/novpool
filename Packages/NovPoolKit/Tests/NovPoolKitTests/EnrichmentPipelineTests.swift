import Foundation
import CoreGraphics
import NovPoolCore
import NovPoolStorage
import Testing
@testable import NovPoolSystemBridge

@Suite("多模态补齐流水线")
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
        ai: any AIEnriching = FakeAI(enrichment: AIEnrichment(summary: "AI 摘要", category: "技术", tags: ["标签"], embedding: [0.5, 0.25])),
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

    @Test("图片条目：OCR 文本与 AI 标签、向量一并回填并进入 FTS 索引")
    func imageEnrichment() async throws {
        let harness = try await makeHarness(ocr: FakeOCR(imageText: "Apple Neural Engine 神经网络加速"))
        let bytes = try #require(TestSupport.pngData("Apple Neural Engine 神经网络加速"))
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
        #expect(result.record.ocrText == "Apple Neural Engine 神经网络加速")
        #expect(result.record.aiSummary == "AI 摘要")
        #expect(result.record.aiTags == ["标签"])
        #expect(result.record.embedding?.count == 2)

        // 回填后立即可被全文检索命中（FTS 触发器同步）。
        let hits = try await harness.repository.searchFullText("神经网络加速")
        #expect(hits.count == 1)
        #expect(hits.first?.id == result.record.id)
    }

    @Test("网页链接条目：抓取正文写入 markdownBody，弱标题被真实标题替换")
    func webLinkEnrichment() async throws {
        let article = ArticleExtraction(
            title: "多云知识路由实践",
            excerpt: "摘要",
            markdown: "# 多云知识路由实践\n\n正文内容若干。",
            textLength: 300,
            contentSelector: "article"
        )
        let harness = try await makeHarness(fetcher: FakeFetcher(result: .extracted(article)))
        let content = ResolvedDragContent(
            contentType: .webLink,
            pageURL: URL(string: "https://blog.example.com/a"),
            text: "多云知识路由实践"
        )

        let result = try await harness.orchestrator.ingestAndEnrich(
            content,
            sourceContext: SourceContext(appBundleID: "com.google.Chrome")
        )
        // 入库标题来自用户拖拽文本，不用被覆盖
        #expect(result.record.title == "多云知识路由实践")
        #expect(result.record.markdownBody?.contains("正文内容若干") == true)

        let hits = try await harness.repository.searchFullText("正文内容若干")
        #expect(hits.count == 1)
    }

    @Test("弱标题（仅域名）会被抓取到的真实标题替换")
    func weakTitleAdoption() async throws {
        let article = ArticleExtraction(
            title: "真正的文章标题",
            markdown: String(repeating: "正文。", count: 80),
            textLength: 240,
            contentSelector: "article"
        )
        let harness = try await makeHarness(fetcher: FakeFetcher(result: .extracted(article)))
        let content = ResolvedDragContent(contentType: .webLink, pageURL: URL(string: "https://blog.example.com/a"))

        let result = try await harness.orchestrator.ingestAndEnrich(
            content,
            sourceContext: SourceContext(appBundleID: "com.google.Chrome", pageURL: URL(string: "https://blog.example.com/a"))
        )
        #expect(result.record.title == "真正的文章标题")
    }

    @Test("数字版 PDF 走文字层，不消耗 OCR")
    func pdfUsesTextLayer() async throws {
        let harness = try await makeHarness(ocr: FakeOCR(pdfText: "不该被调用"))
        let pdf = harness.directory.appending(path: "report.pdf")
        let body = """
        季度报告核心结论：多云归档流水线在本地完成清洗与索引，随后分发到各类云端知识库；\
        大体积 PDF 先上传网盘拿到预览链接，再注入 Notion 数据库记录完成级联。
        """
        #expect(TestSupport.makePDF(text: body, at: pdf))

        let result = try await harness.orchestrator.ingestAndEnrich(
            ResolvedDragContent(contentType: .documentPDF, fileURLs: [pdf]),
            sourceContext: SourceContext(appBundleID: "com.apple.finder")
        )
        #expect(result.record.ocrText == nil)
        #expect(result.record.markdownBody?.contains("季度报告核心结论") == true)
    }

    @Test("无文字层的 PDF 回退到 OCR")
    func scannedPDFFallsBackToOCR() async throws {
        // 构造一个不含文字层的 PDF：只画图形，不画文字。
        let harness = try await makeHarness(ocr: FakeOCR(pdfText: "扫描件 OCR 结果"))
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
        #expect(result.record.ocrText == "扫描件 OCR 结果")
        #expect(result.record.markdownBody == nil)
    }

    @Test("本机 HTML 文件提取正文并进入全文索引")
    func localHTMLFileEnrichment() async throws {
        let harness = try await makeHarness(ai: FakeAI(enrichment: nil))
        let file = harness.directory.appending(path: "local-report.html")
        let paragraph = String(repeating: "这是拖拽进来的本机 HTML 文件正文，用于验证知识库检索。", count: 6)
        let html = """
        <html><head><title>本机报告</title></head>
        <body><article><h1>本机报告</h1><p>\(paragraph)</p></article></body></html>
        """
        try Data(html.utf8).write(to: file)

        let result = try await harness.orchestrator.ingestAndEnrich(
            ResolvedDragContent(contentType: .genericFile, fileURLs: [file]),
            sourceContext: SourceContext(appBundleID: "com.apple.finder")
        )

        #expect(result.record.markdownBody?.contains("本机 HTML 文件正文") == true)
        let hits = try await harness.repository.searchFullText("拖拽进来的本机 HTML 文件正文")
        #expect(hits.first?.id == result.record.id)
    }

    @Test("本机纯文本与代码文件直接作为正文保存")
    func plainTextFileEnrichment() async throws {
        let harness = try await makeHarness(ai: FakeAI(enrichment: nil))
        let file = harness.directory.appending(path: "release-notes.md")
        try Data("# 发布说明\n\n界面调整与拖拽修复。".utf8).write(to: file)

        let result = try await harness.orchestrator.ingestAndEnrich(
            ResolvedDragContent(contentType: .genericFile, fileURLs: [file]),
            sourceContext: SourceContext(appBundleID: "com.apple.finder")
        )

        #expect(result.record.markdownBody?.contains("拖拽修复") == true)
    }

    @Test("无法提取文本的文件也生成文件信息预览")
    func binaryFileGetsSummary() async throws {
        let harness = try await makeHarness(ai: FakeAI(enrichment: nil))
        let file = harness.directory.appending(path: "archive.docx")
        try Data(repeating: 0x50, count: 512).write(to: file)

        let result = try await harness.orchestrator.ingestAndEnrich(
            ResolvedDragContent(contentType: .genericFile, fileURLs: [file]),
            sourceContext: SourceContext(appBundleID: "com.apple.finder")
        )

        #expect(result.record.markdownBody?.contains("## 文件信息") == true)
        #expect(result.record.markdownBody?.contains("archive.docx") == true)
        #expect(result.record.markdownBody?.contains("DOCX 文件") == true)
    }

    @Test("启动回填能找到并补齐缺正文的本机文件")
    func legacyFileBackfill() async throws {
        let harness = try await makeHarness(ai: FakeAI(enrichment: nil))
        let file = harness.directory.appending(path: "legacy.html")
        let paragraph = String(repeating: "旧版本拖入的本机文件没有正文，启动后应当自动补齐。", count: 6)
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
        #expect(record.markdownBody?.contains("启动后应当自动补齐") == true)
    }

    @Test("OCR 失败不影响入库结果")
    func ocrFailureIsolation() async throws {
        let harness = try await makeHarness(ocr: FakeOCR(shouldFail: true))
        let bytes = try #require(TestSupport.pngData("任意图片"))
        let result = try await harness.orchestrator.ingestAndEnrich(
            ResolvedDragContent(contentType: .image, imageData: bytes, imageTypeIdentifier: "public.png"),
            sourceContext: SourceContext(appBundleID: "com.apple.Safari")
        )
        #expect(result.item.isDuplicate == false)
        #expect(result.record.ocrText == nil)
        #expect(try await harness.repository.count() == 1)
    }

    @Test("抓取失败时不做任何回填，但条目仍在库中")
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

    @Test("关闭 OCR 与 AI 后仍生成本机文件的预览信息")
    func disabledEnrichment() async throws {
        let harness = try await makeHarness(
            configuration: .init(runOCR: false, extractWebContent: false, runAI: false)
        )
        let bytes = try #require(TestSupport.pngData("任意图片"))
        let result = try await harness.orchestrator.ingestAndEnrich(
            ResolvedDragContent(contentType: .image, imageData: bytes, imageTypeIdentifier: "public.png"),
            sourceContext: SourceContext(appBundleID: "com.apple.Safari")
        )
        #expect(result.enrichment?.markdownBody?.contains("## 文件信息") == true)
        #expect(result.record.ocrText == nil)
        #expect(result.record.aiSummary == nil)
    }

    @Test("纯文本条目只在有正文时调用 AI，正文缺失则跳过")
    func plainTextSkipsAIWithoutBody() async throws {
        let ai = FakeAI(enrichment: AIEnrichment(summary: "不该出现"))
        let harness = try await makeHarness(ai: ai)
        let result = try await harness.orchestrator.ingestAndEnrich(
            ResolvedDragContent(contentType: .genericFile, fileURLs: []),
            sourceContext: SourceContext(appBundleID: "com.apple.finder")
        )
        #expect(result.enrichment == nil)
    }

    @Test("补齐状态行用于悬浮窗提示")
    func summaryLine() {
        #expect(ContentEnrichment().summaryLine == "无新增")
        #expect(ContentEnrichment(ocrText: "t", aiSummary: "s").summaryLine == "OCR·AI 标签")
        #expect(ContentEnrichment(markdownBody: "b", embedding: [1]).summaryLine == "正文·向量")
    }

    @Test("标题采纳策略：兜底标题与域名标题可被替换")
    func titleAdoption() {
        #expect(TitleAdoption.shouldAdopt(current: ""))
        #expect(TitleAdoption.shouldAdopt(current: "未命名条目 2026/3/9"))
        #expect(TitleAdoption.shouldAdopt(current: "example.com"))
        #expect(TitleAdoption.shouldAdopt(current: "多云知识路由实践") == false)
    }
}
