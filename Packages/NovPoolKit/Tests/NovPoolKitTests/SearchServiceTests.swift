import Foundation
import NovPoolCore
import Testing
@testable import NovPoolStorage

/// Query Embedding proxy: returns a fixed Embedding.
struct FakeQueryEmbedder: QueryEmbeddingProviding {
    var vector: [Float]?

    func embed(_ text: String) async throws -> [Float]? { vector }
}

@Suite("Hybrid Search (FTS5 + vDSP + RRF)")
struct SearchServiceTests {
    private struct Harness {
        let repository: KnowledgeRepository
        let staging: StagingStore
        let directory: URL
    }

    private func makeHarness(embedder: (any QueryEmbeddingProviding)? = nil) async throws -> (
        harness: Harness,
        service: KnowledgeSearchService
    ) {
        let directory = try TestSupport.makeTemporaryDirectory("search")
        let database = try NovPoolDatabase(path: directory.appending(path: "db.sqlite").path(percentEncoded: false))
        try await SchemaMigrator.migrate(database)
        let repository = KnowledgeRepository(database: database)
        let staging = try StagingStore(root: directory.appending(path: "Staging", directoryHint: .isDirectory))
        let service = KnowledgeSearchService(repository: repository, staging: staging, embedder: embedder)
        return (Harness(repository: repository, staging: staging, directory: directory), service)
    }

    @discardableResult
    private func insert(
        _ repository: KnowledgeRepository,
        title: String,
        body: String? = nil,
        ocr: String? = nil,
        tags: [String] = [],
        url: String? = nil,
        embedding: [Float]? = nil,
        relativePath: String? = nil,
        createdAt: Date = Date()
    ) async throws -> UUID {
        let payload = NormalizedPayload(
            contentType: .plainText,
            title: title,
            markdownBody: body,
            sourceContext: SourceContext(
                appBundleID: "com.google.Chrome",
                pageURL: url.flatMap(URL.init(string:)),
                pageTitle: "Source page",
                capturedAt: createdAt
            )
        )
        var record = KnowledgeItemRecord(payload: payload, localRelativePath: relativePath, now: createdAt)
        record.ocrText = ocr
        record.aiTags = tags
        try await repository.insert(record)
        if let embedding {
            try await repository.updateEnrichment(id: record.id, embedding: embedding)
        }
        return record.id
    }

    // MARK: - RRF

    @Test("RRF: Reward cross-list consistency — entries that are ranked lower in both lists are favored over entries that are ranked high in only one list")
    func rrfFusion() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        // a Both paths are 1; b Only 2 in the full-text path; c Only 2 in the embedding path; d Both paths are 3
        let fullText = [a, b, d]
        let vector = [a, c, d]
        let scores = RankFusion.fuse([fullText, vector])
        let ranked = RankFusion.ranked([fullText, vector])

        #expect(ranked.count == 4)                        // Duplicate IDs do not generate duplicate entries
        #expect(ranked.first == a)
        #expect(ranked.filter { $0 == a }.count == 1)
        // d, although ranked only 3rd in both routes, was agreed by both routes to be relevant, thus overriding b/c, which was ranked 2nd in only one route.
        #expect(scores[a]! > scores[d]!)
        #expect(scores[d]! > scores[b]!)
        #expect(ranked[1] == d)
        // b and c have the same score and are sorted stably according to their first occurrence.
        #expect(Array(ranked.suffix(2)) == [b, c])
    }

    @Test("RRF: The smaller the k value, the greater the head advantage")
    func rrfKSensitivity() {
        let first = UUID(), second = UUID()
        let small = RankFusion.fuse([[first, second]], k: 1)
        let large = RankFusion.fuse([[first, second]], k: 100)
        #expect(small[first]! - small[second]! > large[first]! - large[second]!)
    }

    // MARK: - Full text

    @Test("Degrades to pure FTS5 retrieval when there is no Embedding channel")
    func fullTextOnly() async throws {
        let (harness, service) = try await makeHarness()
        try await insert(harness.repository, title: "Cloud Knowledge Routing Hub", body: "Drag-and-drop collection and automatic archiving")
        try await insert(harness.repository, title: "Unrelated entry", body: "Completely different content")

        let results = try await service.search("Knowledge Routing")
        #expect(results.count == 1)
        #expect(results[0].title == "Cloud Knowledge Routing Hub")
        #expect(results[0].isFullTextMatch)
        #expect(results[0].isSemanticMatch == false)
        #expect(results[0].matchLabel == "Keyword")
        #expect(results[0].previewBody?.contains("Drag-and-drop collection") == true)
    }

    @Test("Short queries (<3 characters) using LIKE fallback can still hit")
    func shortQueryFallback() async throws {
        let (harness, service) = try await makeHarness()
        try await insert(harness.repository, title: "AI Abstract Pipeline")

        let results = try await service.search("AI")
        #expect(results.count == 1)
        #expect(results[0].isFullTextMatch)
    }

    @Test("An empty query returns recent entries, sorted by time in descending order.")
    func recentItems() async throws {
        let (harness, service) = try await makeHarness()
        let old = try await insert(
            harness.repository,
            title: "Earlier entries",
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let fresh = try await insert(
            harness.repository,
            title: "Latest entry",
            createdAt: Date(timeIntervalSince1970: 2_000)
        )

        let results = try await service.recent(limit: 10)
        #expect(results.map(\.id) == [fresh, old])
        #expect(results.allSatisfy { $0.matchLabel == "Recent" })
        #expect(try await service.search("   ").map(\.id) == [fresh, old])
    }

    // MARK: - Semantic

    @Test("Semantic recall: Items that are completely missed by keywords can also be found through Embedding")
    func semanticRecall() async throws {
        let embedder = FakeQueryEmbedder(vector: [1, 0, 0])
        let (harness, service) = try await makeHarness(embedder: embedder)
        let onTopic = try await insert(
            harness.repository,
            title: "Edge-side Inference Optimization",
            body: "Quantization and Operator Fusion",
            embedding: [1, 0, 0]
        )
        try await insert(harness.repository, title: "Unrelated entry", body: "Completely different content", embedding: [0, 1, 0])

        // The query terms have no overlap with the text of this entry, so it can only be retrieved through embedding.
        let results = try await service.search("Model Acceleration")
        #expect(results.count == 1)
        #expect(results[0].id == onTopic)
        #expect(results[0].isSemanticMatch)
        #expect(results[0].isFullTextMatch == false)
        #expect(results[0].matchLabel == "Semantic")
    }

    @Test("Hit by both routes simultaneously: merge and deduplicate while marking as Keyword + Semantic")
    func hybridDeduplication() async throws {
        let embedder = FakeQueryEmbedder(vector: [1, 0, 0])
        let (harness, service) = try await makeHarness(embedder: embedder)
        let both = try await insert(
            harness.repository,
            title: "Cloud Knowledge Routing Hub",
            body: "Drag-and-drop collection",
            embedding: [1, 0, 0]
        )
        let onlyText = try await insert(harness.repository, title: "Another implementation of cloudy knowledge routing")
        let onlyVector = try await insert(harness.repository, title: "Edge inference", embedding: [0.9, 0.1, 0])

        let results = try await service.search("Knowledge Routing")
        #expect(Set(results.map(\.id)) == Set([both, onlyText, onlyVector]))
        let top = try #require(results.first)
        #expect(top.id == both)
        #expect(top.isFullTextMatch && top.isSemanticMatch)
        #expect(top.matchLabel == "Keyword + Semantic")
    }

    @Test("Embedding candidates with too low similarity are discarded; inconsistent dimensions will not cause a crash")
    func vectorThresholdAndDimensionMismatch() async throws {
        let embedder = FakeQueryEmbedder(vector: [1, 0, 0])
        let (harness, service) = try await makeHarness(embedder: embedder)
        try await insert(harness.repository, title: "Weakly related item", embedding: [0.1, 0.9, 0])
        try await insert(harness.repository, title: "Entries with inconsistent dimensions", embedding: [1, 0])

        #expect(try await service.search("Query with no Keyword matches").isEmpty)
    }

    @Test("When the embedding model is unavailable, silently degrade to pure full-text search")
    func embedderFailureDegrades() async throws {
        let (harness, service) = try await makeHarness(embedder: FakeQueryEmbedder(vector: nil))
        try await insert(harness.repository, title: "Cloud Knowledge Routing Hub", embedding: [1, 0, 0])
        let results = try await service.search("Knowledge Routing")
        #expect(results.count == 1)
        #expect(results[0].isSemanticMatch == false)
    }

    // MARK: - Result assembly

    @Test("OCR text as the preview content for entries without a body")
    func previewFallsBackToOCR() async throws {
        let (harness, service) = try await makeHarness()
        try await insert(harness.repository, title: "Screenshot entry", ocr: "Apple Neural Engine Neural network acceleration")
        let results = try await service.search("Neural Network")
        #expect(results.first?.previewBody == "Apple Neural Engine Neural network acceleration")
    }

    @Test("When the temporary file exists, return the local path; after it is cleared, return nil")
    func localFileResolution() async throws {
        let (harness, service) = try await makeHarness()
        let asset = try await harness.staging.stage(data: Data("fake".utf8), preferredExtension: "png")
        try await insert(
            harness.repository,
            title: "Entries with File",
            body: "BodyContent",
            relativePath: asset.relativePath
        )
        let results = try await service.search("BodyContent")
        #expect(results.first?.localFileURL == asset.absoluteURL)
        #expect(results.first?.hasLocalFile == true)

        try await harness.staging.remove(relativePath: asset.relativePath)
        let afterCleanup = try await service.search("BodyContent")
        #expect(afterCleanup.first?.localFileURL == nil)
    }

    @Test("When there is no Body but a local File exists, provide the File information as a fallback in detail")
    func previewFallsBackToFileInfo() async throws {
        let (harness, service) = try await makeHarness()
        let asset = try await harness.staging.stage(data: Data(repeating: 0x01, count: 32), preferredExtension: "bin")
        try await insert(
            harness.repository,
            title: "Binary Attachment",
            body: nil,
            relativePath: asset.relativePath
        )
        let results = try await service.recent(limit: 5)
        let preview = try #require(results.first?.previewBody)
        #expect(preview.contains("File info"))
        #expect(preview.contains(asset.absoluteURL.lastPathComponent))
    }

    @Test("Delete entry and clean Staging at the same time")
    func deleteItemRemovesStaging() async throws {
        let (harness, service) = try await makeHarness()
        let asset = try await harness.staging.stage(data: Data("to-delete".utf8), preferredExtension: "txt")
        let id = try await insert(
            harness.repository,
            title: "To be deleted",
            body: "to-delete-body-unique",
            relativePath: asset.relativePath
        )
        #expect(FileManager.default.fileExists(atPath: asset.absoluteURL.path(percentEncoded: false)))
        #expect(try await service.deleteItem(id: id) == true)
        #expect(try await harness.repository.fetch(id: id) == nil)
        #expect(!FileManager.default.fileExists(atPath: asset.absoluteURL.path(percentEncoded: false)))
    }

    @Test("limit takes effect, and the number of results does not exceed the number of hits")
    func limitRespected() async throws {
        let (harness, service) = try await makeHarness()
        for index in 0..<12 {
            try await insert(harness.repository, title: "Cloud Routing Practice\(index)", body: "Common Keyword:Cloud Routing")
        }
        #expect(try await service.search("Cloud Routing", limit: 5).count == 5)
        #expect(try await service.search("Cloud Routing", limit: 100).count == 12)
    }

    @Test("Enter action: Web preferred, then local File; if neither is available, it is not usable")
    func defaultActionResolution() {
        let web = KnowledgeSearchResult(
            id: UUID(),
            title: "Webentry",
            contentType: .webLink,
            sourceURL: URL(string: "https://example.com/a"),
            localFileURL: URL(filePath: "/tmp/a.png")
        )
        #expect(web.defaultAction == .openURL(URL(string: "https://example.com/a")!))

        let fileOnly = KnowledgeSearchResult(
            id: UUID(),
            title: "Local File",
            contentType: .image,
            localFileURL: URL(filePath: "/tmp/b.png")
        )
        #expect(fileOnly.defaultAction == .revealFile(URL(filePath: "/tmp/b.png")))

        let neither = KnowledgeSearchResult(id: UUID(), title: "Plain Text", contentType: .plainText)
        #expect(neither.defaultAction == SearchResultAction.none)
        #expect(neither.defaultAction.isEnabled == false)
    }

    @Test("Include title, Kind tag, summary, source, and body when copying to clipboard")
    func clipboardText() {
        let result = KnowledgeSearchResult(
            id: UUID(),
            title: "Cloud Knowledge Routing Hub",
            summary: "A one-sentence summary",
            category: "Technology",
            tags: ["Router", "Swift"],
            contentType: .webLink,
            sourceURL: URL(string: "https://example.com/a"),
            previewBody: "# Body"
        )
        let text = result.clipboardText
        #expect(text.contains("# Cloud Knowledge Routing Hub"))
        #expect(text.contains("#Web"))
        #expect(text.contains("#Router"))
        #expect(text.contains("Topic: Technology"))
        #expect(text.contains("> A one-sentence summary"))
        #expect(text.contains("https://example.com/a"))
        #expect(text.contains("# Body"))
    }

    @Test("Display tags: Resource Kind first, content Keyword second, and do not deduplicate conflicts")
    func displayTagsPrecedeWithResourceType() {
        let result = KnowledgeSearchResult(
            id: UUID(),
            title: "Picture",
            tags: ["Design", "Image"],
            contentType: .image
        )
        #expect(result.resourceTypeTag == "Image")
        #expect(result.displayTags == ["Image", "Design"])
    }
}
