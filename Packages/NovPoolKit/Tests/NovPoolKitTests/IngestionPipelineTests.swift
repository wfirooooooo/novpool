import Foundation
import NovPoolCore
import NovPoolStorage
import Testing
@testable import NovPoolSystemBridge

@Suite("捕获 → 暂存 → 溯源 → 落库 主流水线")
struct IngestionPipelineTests {
    private struct Harness {
        let database: NovPoolDatabase
        let repository: KnowledgeRepository
        let staging: StagingStore
        let orchestrator: IngestionOrchestrator
    }

    private func makeHarness(context: SourceContext) async throws -> Harness {
        let directory = try TestSupport.makeTemporaryDirectory("pipeline")
        let database = try NovPoolDatabase(path: directory.appending(path: "novpool.sqlite").path(percentEncoded: false))
        try await SchemaMigrator.migrate(database)
        let staging = try StagingStore(root: directory.appending(path: "Staging", directoryHint: .isDirectory))
        let repository = KnowledgeRepository(database: database)
        let orchestrator = IngestionOrchestrator(
            database: database,
            staging: staging,
            browserContext: FakeBrowserContext(context: context)
        )
        return Harness(database: database, repository: repository, staging: staging, orchestrator: orchestrator)
    }

    @Test("拖拽选中文字：写入标题、正文与浏览器溯源")
    func ingestPlainText() async throws {
        let context = SourceContext(
            appBundleID: "com.google.Chrome",
            pageURL: URL(string: "https://example.com/arch"),
            pageTitle: "架构设计"
        )
        let harness = try await makeHarness(context: context)
        let content = ResolvedDragContent(
            contentType: .plainText,
            text: "第一行标题\n第二行内容",
            matchedTypeIdentifiers: [PasteboardTypeID.plainText]
        )

        let result = try await harness.orchestrator.ingest(content)
        #expect(result.isDuplicate == false)
        #expect(result.record.title == "第一行标题")
        #expect(result.record.markdownBody == "第一行标题\n第二行内容")
        #expect(result.record.sourceApp == "com.google.Chrome")
        #expect(result.record.sourceURL == "https://example.com/arch")
        #expect(result.record.sourceTitle == "架构设计")
        #expect(result.stagedAsset == nil)

        let stored = try await harness.repository.fetch(id: result.record.id)
        #expect(stored?.title == "第一行标题")
    }

    @Test("拖拽网页图片：内存字节流落盘并记录哈希")
    func ingestImage() async throws {
        let harness = try await makeHarness(context: SourceContext(
            appBundleID: "com.brave.Browser",
            pageURL: URL(string: "https://example.com/pic"),
            pageTitle: "示意图"
        ))
        let bytes = Data(repeating: 0x42, count: 128)
        let content = ResolvedDragContent(
            contentType: .image,
            imageData: bytes,
            imageTypeIdentifier: PasteboardTypeID.jpeg,
            pageURL: URL(string: "https://example.com/pic"),
            matchedTypeIdentifiers: [PasteboardTypeID.jpeg]
        )

        let result = try await harness.orchestrator.ingest(content)
        let asset = try #require(result.stagedAsset)
        #expect(asset.relativePath.hasSuffix(".jpg"))
        #expect(result.record.fileHashSHA256 == StagingStore.sha256Hex(of: bytes))
        #expect(result.record.localRelativePath == asset.relativePath)
        #expect(result.record.title == "示意图")
        #expect(FileManager.default.fileExists(atPath: asset.absoluteURL.path(percentEncoded: false)))
    }

    @Test("拖拽 PDF：按其扩展名暂存并生成标题")
    func ingestPDF() async throws {
        let harness = try await makeHarness(context: SourceContext(appBundleID: "com.apple.finder"))
        let sourceDirectory = try TestSupport.makeTemporaryDirectory("pdf")
        let pdf = sourceDirectory.appending(path: "2026 季度报告.pdf")
        try Data(repeating: 0x25, count: 512).write(to: pdf)

        let result = try await harness.orchestrator.ingest(
            ResolvedDragContent(contentType: .documentPDF, fileURLs: [pdf])
        )
        #expect(result.record.title == "2026 季度报告")
        #expect(result.record.localRelativePath?.hasSuffix("2026 季度报告.pdf") == true)
        #expect(result.record.fileHashSHA256?.count == 64)
    }

    @Test("相同内容重复拖拽命中哈希去重，不产生第二条记录")
    func deduplication() async throws {
        let harness = try await makeHarness(context: SourceContext(appBundleID: "com.apple.finder"))
        let sourceDirectory = try TestSupport.makeTemporaryDirectory("dedupe")
        let source = sourceDirectory.appending(path: "note.txt")
        try Data("同样的内容".utf8).write(to: source)
        let content = ResolvedDragContent(contentType: .genericFile, fileURLs: [source])

        let first = try await harness.orchestrator.ingest(content)
        let second = try await harness.orchestrator.ingest(content)

        #expect(first.isDuplicate == false)
        #expect(second.isDuplicate == true)
        #expect(second.record.id == first.record.id)
        #expect(try await harness.repository.count() == 1)
    }

    @Test("扇区指定目标时按强制路由返回连接器")
    func sectorRouting() async throws {
        let harness = try await makeHarness(context: SourceContext(appBundleID: "com.google.Chrome"))
        let zone = DropZone(id: "notion", title: "Notion", systemImage: "doc.richtext", connectorID: "notion")
        let result = try await harness.orchestrator.ingest(
            ResolvedDragContent(contentType: .plainText, text: "笔记内容"),
            forcedZone: zone
        )
        #expect(result.routeDecision.connectorIDs == ["notion"])
        #expect(result.routeDecision.reason == .sectorForced(zoneID: "notion"))
    }

    @Test("网页链接条目只记录 URL，正文留给 Phase 2 的正文提取器")
    func webLinkKeepsURLOnly() async throws {
        let harness = try await makeHarness(context: SourceContext(
            appBundleID: "com.google.Chrome",
            pageURL: URL(string: "https://example.com/article"),
            pageTitle: "深度技术文章"
        ))
        let result = try await harness.orchestrator.ingest(
            ResolvedDragContent(
                contentType: .webLink,
                pageURL: URL(string: "https://example.com/article"),
                text: "深度技术文章"
            )
        )
        #expect(result.record.contentType == .webLink)
        #expect(result.record.title == "深度技术文章")
        #expect(result.record.markdownBody == nil)
        #expect(result.record.sourceURL == "https://example.com/article")
    }

    @Test("拖拽浏览器标签：来源用被拖标签的 URL，标题用标签标题")
    func browserTabDrag() async throws {
        // 溯源到的是浏览器「当前激活标签」，与被拖拽的标签不是同一个页面
        let harness = try await makeHarness(context: SourceContext(
            appBundleID: "org.mozilla.firefox",
            pageURL: URL(string: "https://other.example.com/active"),
            pageTitle: "另一个激活标签"
        ))
        let content = ResolvedDragContent(
            contentType: .webLink,
            pageURL: URL(string: "https://example.com/dragged-tab"),
            linkTitle: "被拖拽的标签标题"
        )

        let result = try await harness.orchestrator.ingest(content)
        #expect(result.record.title == "被拖拽的标签标题")
        #expect(result.record.sourceURL == "https://example.com/dragged-tab")
        // 溯源信息仍然保留，便于知道「从哪拖来的」
        #expect(result.record.sourceApp == "org.mozilla.firefox")
        #expect(result.record.sourceTitle == "另一个激活标签")
    }

    @Test("标题拟定：截断超长标题并为无标题内容兜底")
    func titleBuilder() {
        let context = SourceContext(appBundleID: "com.apple.finder")
        let long = ResolvedDragContent(
            contentType: .plainText,
            text: String(repeating: "很长的标题", count: 40)
        )
        let title = TitleBuilder.suggest(for: long, sourceContext: context)
        #expect(title.count == TitleBuilder.maxTitleLength + 1)
        #expect(title.hasSuffix("…"))

        let empty = ResolvedDragContent(contentType: .plainText, text: "   \n  ")
        #expect(TitleBuilder.suggest(for: empty, sourceContext: context).hasPrefix("未命名条目"))
    }
}
