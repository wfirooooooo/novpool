import Foundation
import NovPoolCore
import NovPoolStorage
import Testing
@testable import NovPoolSystemBridge

@Suite("Capture → Staging → Traceability → Storage Main Pipeline")
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

    @Test("Multiple file drag-and-drop: each path is stored separately")
    func ingestMultipleFilesSeparately() async throws {
        let harness = try await makeHarness(context: SourceContext(appBundleID: "com.apple.finder"))
        let directory = try TestSupport.makeTemporaryDirectory("multifile")
        let first = directory.appending(path: "one.txt")
        let second = directory.appending(path: "two.md")
        try "alpha".write(to: first, atomically: true, encoding: .utf8)
        try "beta".write(to: second, atomically: true, encoding: .utf8)

        let content = ResolvedDragContent(
            contentType: .genericFile,
            fileURLs: [first, second]
        )
        var records: [KnowledgeItemRecord] = []
        for item in content.expandedForIngest() {
            let result = try await harness.orchestrator.ingest(item)
            records.append(result.record)
        }
        #expect(records.count == 2)
        #expect(Set(records.map(\.title)) == Set(["one", "two"]))
        #expect(try await harness.repository.count() == 2)
    }

    @Test("Drag Selected text: write Title, Body and browser tracing")
    func ingestPlainText() async throws {
        let context = SourceContext(
            appBundleID: "com.google.Chrome",
            pageURL: URL(string: "https://example.com/arch"),
            pageTitle: "Architectural Design"
        )
        let harness = try await makeHarness(context: context)
        let content = ResolvedDragContent(
            contentType: .plainText,
            text: "First Line Title\nSecond line content",
            matchedTypeIdentifiers: [PasteboardTypeID.plainText]
        )

        let result = try await harness.orchestrator.ingest(content)
        #expect(result.isDuplicate == false)
        #expect(result.record.title == "First Line Title")
        #expect(result.record.markdownBody == "First Line Title\nSecond line content")
        #expect(result.record.sourceApp == "com.google.Chrome")
        #expect(result.record.sourceURL == "https://example.com/arch")
        #expect(result.record.sourceTitle == "Architectural Design")
        #expect(result.stagedAsset == nil)

        let stored = try await harness.repository.fetch(id: result.record.id)
        #expect(stored?.title == "First Line Title")
    }

    @Test("Drag WebImage: Memory byte stream dumped to disk and hash recorded")
    func ingestImage() async throws {
        let harness = try await makeHarness(context: SourceContext(
            appBundleID: "com.brave.Browser",
            pageURL: URL(string: "https://example.com/pic"),
            pageTitle: "Illustration"
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
        #expect(result.record.title == "Illustration")
        #expect(FileManager.default.fileExists(atPath: asset.absoluteURL.path(percentEncoded: false)))
    }

    @Test("Drag and drop PDF: temporarily store according to its extension and generate a title")
    func ingestPDF() async throws {
        let harness = try await makeHarness(context: SourceContext(appBundleID: "com.apple.finder"))
        let sourceDirectory = try TestSupport.makeTemporaryDirectory("pdf")
        let pdf = sourceDirectory.appending(path: "2026 Quarterly report.pdf")
        try Data(repeating: 0x25, count: 512).write(to: pdf)

        let result = try await harness.orchestrator.ingest(
            ResolvedDragContent(contentType: .documentPDF, fileURLs: [pdf])
        )
        #expect(result.record.title == "2026 Quarterly report")
        #expect(result.record.localRelativePath?.hasSuffix("2026 Quarterly report.pdf") == true)
        #expect(result.record.fileHashSHA256?.count == 64)
    }

    @Test("Duplicate dragging of the same content hits the hash for deduplication and does not generate a second record")
    func deduplication() async throws {
        let harness = try await makeHarness(context: SourceContext(appBundleID: "com.apple.finder"))
        let sourceDirectory = try TestSupport.makeTemporaryDirectory("dedupe")
        let source = sourceDirectory.appending(path: "note.txt")
        try Data("The same content".utf8).write(to: source)
        let content = ResolvedDragContent(contentType: .genericFile, fileURLs: [source])

        let first = try await harness.orchestrator.ingest(content)
        let second = try await harness.orchestrator.ingest(content)

        #expect(first.isDuplicate == false)
        #expect(second.isDuplicate == true)
        #expect(second.record.id == first.record.id)
        #expect(try await harness.repository.count() == 1)
    }

    @Test("Remove duplicates when dragging the same WebLink repeatedly")
    func dedupeWebLink() async throws {
        let harness = try await makeHarness(context: SourceContext(appBundleID: "com.apple.Safari"))
        let content = ResolvedDragContent(
            contentType: .webLink,
            pageURL: URL(string: "https://Example.com/path/#frag"),
            linkTitle: "Example"
        )
        let first = try await harness.orchestrator.ingest(content)
        let second = try await harness.orchestrator.ingest(
            ResolvedDragContent(
                contentType: .webLink,
                pageURL: URL(string: "https://example.com/path"),
                linkTitle: "Here comes the example again"
            )
        )
        #expect(first.isDuplicate == false)
        #expect(second.isDuplicate == true)
        #expect(second.record.id == first.record.id)
        #expect(try await harness.repository.count() == 1)
        #expect(first.record.fileHashSHA256?.count == 64)
    }

    @Test("Remove duplicates by repeatedly dragging the same plain text")
    func dedupePlainText() async throws {
        let harness = try await makeHarness(context: SourceContext(appBundleID: "com.google.Chrome"))
        let content = ResolvedDragContent(contentType: .plainText, text: "  The same paragraph of Selected text\n")
        let first = try await harness.orchestrator.ingest(content)
        let second = try await harness.orchestrator.ingest(
            ResolvedDragContent(contentType: .plainText, text: "The same paragraph of Selected text")
        )
        #expect(first.isDuplicate == false)
        #expect(second.isDuplicate == true)
        #expect(try await harness.repository.count() == 1)
    }

    @Test("Different links or different bodies will not be mistakenly judged as duplicates")
    func differentContentNotDeduped() async throws {
        let harness = try await makeHarness(context: SourceContext(appBundleID: "com.apple.Safari"))
        _ = try await harness.orchestrator.ingest(
            ResolvedDragContent(contentType: .webLink, pageURL: URL(string: "https://example.com/a"))
        )
        _ = try await harness.orchestrator.ingest(
            ResolvedDragContent(contentType: .webLink, pageURL: URL(string: "https://example.com/b"))
        )
        _ = try await harness.orchestrator.ingest(
            ResolvedDragContent(contentType: .plainText, text: "BodyA")
        )
        _ = try await harness.orchestrator.ingest(
            ResolvedDragContent(contentType: .plainText, text: "BodyB")
        )
        #expect(try await harness.repository.count() == 4)
    }

    @Test("History Links without fingerprints can still be deduplicated according to sourceURL")
    func dedupeLegacyWebLinkBySourceURL() async throws {
        let harness = try await makeHarness(context: SourceContext(appBundleID: "com.apple.Safari"))
        let url = URL(string: "https://example.com/legacy")!
        var legacy = KnowledgeItemRecord(
            payload: NormalizedPayload(
                contentType: .webLink,
                title: "Old entry",
                sourceContext: SourceContext(appBundleID: "com.apple.Safari", pageURL: url)
            ),
            localRelativePath: nil
        )
        legacy.fileHashSHA256 = nil
        try await harness.repository.insert(legacy)

        let second = try await harness.orchestrator.ingest(
            ResolvedDragContent(contentType: .webLink, pageURL: url, linkTitle: "Drag again")
        )
        #expect(second.isDuplicate == true)
        #expect(second.record.id == legacy.id)
        #expect(try await harness.repository.count() == 1)
    }

    @Test("When the sector specifies the target, return the connector according to the forced route")
    func sectorRouting() async throws {
        let harness = try await makeHarness(context: SourceContext(appBundleID: "com.google.Chrome"))
        let zone = DropZone(id: "notion", title: "Notion", systemImage: "doc.richtext", connectorID: "notion")
        let result = try await harness.orchestrator.ingest(
            ResolvedDragContent(contentType: .plainText, text: "Notes content"),
            forcedZone: zone
        )
        #expect(result.routeDecision.connectorIDs == ["notion"])
        #expect(result.routeDecision.reason == .sectorForced(zoneID: "notion"))
    }

    @Test("WebLink entries only record the URL, the Body is left for the Phase 2 Body extractor")
    func webLinkKeepsURLOnly() async throws {
        let harness = try await makeHarness(context: SourceContext(
            appBundleID: "com.google.Chrome",
            pageURL: URL(string: "https://example.com/article"),
            pageTitle: "In-depth technical article"
        ))
        let result = try await harness.orchestrator.ingest(
            ResolvedDragContent(
                contentType: .webLink,
                pageURL: URL(string: "https://example.com/article"),
                text: "In-depth technical article"
            )
        )
        #expect(result.record.contentType == .webLink)
        #expect(result.record.title == "In-depth technical article")
        #expect(result.record.markdownBody == nil)
        #expect(result.record.sourceURL == "https://example.com/article")
    }

    @Test("Drag Browser tab: Use the URL of the dragged tab as the source, and the tab title as the title")
    func browserTabDrag() async throws {
        // The origin traces back to the browser's 'currently active tab', which is not the same page as the dragged tab.
        let harness = try await makeHarness(context: SourceContext(
            appBundleID: "org.mozilla.firefox",
            pageURL: URL(string: "https://other.example.com/active"),
            pageTitle: "Another active tab"
        ))
        let content = ResolvedDragContent(
            contentType: .webLink,
            pageURL: URL(string: "https://example.com/dragged-tab"),
            linkTitle: "Dragged tab title"
        )

        let result = try await harness.orchestrator.ingest(content)
        #expect(result.record.title == "Dragged tab title")
        #expect(result.record.sourceURL == "https://example.com/dragged-tab")
        // The source information is still retained, making it easy to know 'where it was dragged from'.
        #expect(result.record.sourceApp == "org.mozilla.firefox")
        #expect(result.record.sourceTitle == "Another active tab")
    }

    @Test("Title drafting: truncate excessively long titles and provide a fallback for content without a title")
    func titleBuilder() {
        let context = SourceContext(appBundleID: "com.apple.finder")
        let long = ResolvedDragContent(
            contentType: .plainText,
            text: String(repeating: "A very long title", count: 40)
        )
        let title = TitleBuilder.suggest(for: long, sourceContext: context)
        #expect(title.count == TitleBuilder.maxTitleLength + 1)
        #expect(title.hasSuffix("…"))

        let empty = ResolvedDragContent(contentType: .plainText, text: "   \n  ")
        #expect(TitleBuilder.suggest(for: empty, sourceContext: context).hasPrefix("Untitled item"))
    }
}
