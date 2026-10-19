import Foundation
import NovPoolCore
import Testing
@testable import NovPoolStorage
@testable import NovPoolSystemBridge

@Suite("GRDB Equivalent Schema and Retrieval")
struct DatabaseTests {
    private func makeDatabase() async throws -> (NovPoolDatabase, KnowledgeRepository, URL) {
        let directory = try TestSupport.makeTemporaryDirectory("db")
        let database = try NovPoolDatabase(path: directory.appending(path: "test.sqlite").path(percentEncoded: false))
        try await SchemaMigrator.migrate(database)
        return (database, KnowledgeRepository(database: database), directory)
    }

    @Test("Migrations can be executed repeatedly and are idempotent")
    func migrationIsIdempotent() async throws {
        let (database, _, _) = try await makeDatabase()
        try await SchemaMigrator.migrate(database)
        let applied = try await database.query("SELECT name FROM novpool_migrations")
        #expect(applied.count == SchemaMigration.all.count)
        let tables = try await database.query(
            "SELECT name FROM sqlite_master WHERE type IN ('table','trigger') ORDER BY name"
        )
        let names = Set(tables.compactMap { $0.text("name") })
        #expect(names.isSuperset(of: [
            "knowledge_items", "knowledge_items_fts", "connectors", "sync_outbox_jobs",
            "knowledge_items_fts_ai", "knowledge_items_fts_au", "knowledge_items_fts_ad",
        ]))
    }

    @Test("WAL mode is enabled")
    func walEnabled() async throws {
        let (database, _, _) = try await makeDatabase()
        let rows = try await database.query("PRAGMA journal_mode")
        #expect(rows.first?.text("journal_mode")?.lowercased() == "wal")
    }

    @Test("After write, all fields can be read back")
    func insertAndFetch() async throws {
        let (_, repository, _) = try await makeDatabase()
        let payload = TestSupport.samplePayload(title: "Architecture whitepaper", tags: ["swift", "architecture"])
        var record = KnowledgeItemRecord(payload: payload, localRelativePath: "uuid/asset.png")
        record.fileHashSHA256 = "deadbeef"
        try await repository.insert(record)

        let loaded = try #require(try await repository.fetch(id: record.id))
        #expect(loaded.title == "Architecture whitepaper")
        #expect(loaded.aiTags == ["swift", "architecture"])
        #expect(loaded.sourceApp == "com.google.Chrome")
        #expect(loaded.sourceURL == "https://example.com/a")
        #expect(loaded.localRelativePath == "uuid/asset.png")
        #expect(try await repository.fetchByHash("deadbeef")?.id == record.id)
    }

    @Test("FTS5 trigram supports Chinese substring search")
    func chineseFullTextSearch() async throws {
        let (_, repository, _) = try await makeDatabase()
        try await repository.insert(KnowledgeItemRecord(
            payload: TestSupport.samplePayload(title: "多云知识路由中枢", body: "拖拽收集与自动归档"),
            localRelativePath: nil
        ))
        try await repository.insert(KnowledgeItemRecord(
            payload: TestSupport.samplePayload(title: "无关条目", body: "完全不同的内容"),
            localRelativePath: nil
        ))

        let hits = try await repository.searchFullText("知识路由")
        #expect(hits.count == 1)
        #expect(hits.first?.title == "多云知识路由中枢")
    }

    @Test("Queries with fewer than 3 characters are automatically downgraded to LIKE substring scans")
    func shortQueryFallsBackToLike() async throws {
        let (_, repository, _) = try await makeDatabase()
        try await repository.insert(KnowledgeItemRecord(
            payload: TestSupport.samplePayload(title: "AI 摘要 pipeline", body: nil),
            localRelativePath: nil
        ))

        // Trigram indexing cannot hit 2-character queries and must fall back to LIKE.
        let twoCharacterHits = try await repository.searchFullText("AI")
        #expect(twoCharacterHits.count == 1)
        // Keep a 2-character Chinese query to verify CJK short-query LIKE fallback.
        let chineseHits = try await repository.searchFullText("摘要")
        #expect(chineseHits.count == 1)
    }

    @Test("Queries containing quotes and wildcards will not break SQL")
    func hostileQueryIsEscaped() async throws {
        let (_, repository, _) = try await makeDatabase()
        try await repository.insert(KnowledgeItemRecord(
            payload: TestSupport.samplePayload(title: "Title with 100% and \"quotes\""),
            localRelativePath: nil
        ))
        let quoted = try await repository.searchFullText("\"quotes\"")
        #expect(quoted.count == 1)
        let percent = try await repository.searchFullText("100%")
        #expect(percent.count == 1)
    }

    @Test("After OCR / AI backfill, the FTS index is automatically synchronized by triggers")
    func enrichmentUpdatesIndex() async throws {
        let (_, repository, _) = try await makeDatabase()
        let record = KnowledgeItemRecord(
            payload: TestSupport.samplePayload(title: "Screenshot item", body: nil),
            localRelativePath: "uuid/asset.png"
        )
        try await repository.insert(record)
        #expect(try await repository.searchFullText("neural acceleration").isEmpty)

        try await repository.updateEnrichment(
            id: record.id,
            ocrText: "Apple Neural Engine neural acceleration",
            aiSummary: "On-device OCR summary",
            aiCategory: "Technology",
            aiTags: ["OCR", "ANE"],
            embedding: [0.1, 0.2, 0.3]
        )

        let hits = try await repository.searchFullText("neural acceleration")
        #expect(hits.count == 1)
        #expect(hits.first?.category == "Technology")
        #expect(hits.first?.tags == ["OCR", "ANE"])

        let embeddings = try await repository.embeddingRows()
        #expect(embeddings.count == 1)
        #expect(embeddings[0].vector.count == 3)
    }

    @Test("Index synchronization cleanup after deleting an entry")
    func deleteClearsIndex() async throws {
        let (_, repository, _) = try await makeDatabase()
        let record = KnowledgeItemRecord(
            payload: TestSupport.samplePayload(title: "Temporary note"),
            localRelativePath: nil
        )
        try await repository.insert(record)
        #expect(try await repository.count() == 1)

        #expect(try await repository.delete(id: record.id))
        #expect(try await repository.count() == 0)
        #expect(try await repository.searchFullText("Temporary note").isEmpty)
        #expect(try await repository.searchSubstring("Temporary note").isEmpty)
    }

    @Test("Cascade clean-up of outbox tasks after item deletion")
    func outboxCascadeDelete() async throws {
        let (database, repository, _) = try await makeDatabase()
        let connectors = ConnectorRepository(database: database)
        try await connectors.upsert(ConnectorRecord(id: "obsidian", name: "Obsidian", connectorType: "local_mount"))

        let record = KnowledgeItemRecord(payload: TestSupport.samplePayload(), localRelativePath: nil)
        try await repository.insert(record)
        try await database.execute(
            """
            INSERT INTO sync_outbox_jobs
                (jobID, itemID, connectorID, status, retryCount, nextRetryAt, updatedAt)
            VALUES (?, ?, ?, 'PENDING', 0, ?, ?)
            """,
            [
                .text(UUID().uuidString), .text(record.id.uuidString), .text("obsidian"),
                .date(Date()), .date(Date()),
            ]
        )

        try await repository.delete(id: record.id)
        let remaining = try await database.query("SELECT COUNT(*) AS value FROM sync_outbox_jobs")
        #expect(remaining.first?.int("value") == 0)
    }

    @Test("Connector configuration can be added, deleted, modified, and queried, and sensitive fields are not stored in the database.")
    func connectorCRUD() async throws {
        let (database, _, _) = try await makeDatabase()
        let connectors = ConnectorRepository(database: database)
        try await connectors.upsert(ConnectorRecord(
            id: "gdrive",
            name: "Google Drive",
            connectorType: "local_mount",
            keychainAccountRef: "gdrive.refresh_token",
            bookmarkData: Data([1, 2, 3]),
            configJSON: #"{"rootPath":"/tmp/gdrive"}"#
        ))
        try await connectors.setEnabled(false, id: "gdrive")

        let loaded = try #require(try await connectors.fetch(id: "gdrive"))
        #expect(loaded.isEnabled == false)
        #expect(loaded.keychainAccountRef == "gdrive.refresh_token")
        #expect(loaded.bookmarkData == Data([1, 2, 3]))
        #expect(!loaded.configJSON.contains("token"))

        try await connectors.delete(id: "gdrive")
        #expect(try await connectors.list().isEmpty)
    }

    @Test("Failure reason round-trips and is cleared when a summary is written")
    func aiFailureReasonRoundTrip() async throws {
        let (_, repository, _) = try await makeDatabase()
        let record = KnowledgeItemRecord(
            id: UUID(),
            contentType: .plainText,
            title: "Missing",
            markdownBody: "An unread essay about tide pools and kelp.",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        try await repository.insert(record)
        try await repository.updateEnrichment(
            id: record.id,
            aiFailureReason: AIEnrichmentQuality.noBodyReason,
            writeAIFailureReason: true
        )
        let failed = try #require(try await repository.fetch(id: record.id))
        #expect(failed.aiFailureReason == AIEnrichmentQuality.noBodyReason)

        try await repository.updateEnrichment(
            id: record.id,
            aiSummary: "Tide pools at low water",
            aiCategory: "Science",
            aiTags: ["kelp"],
            writeAIFailureReason: true
        )
        let fixed = try #require(try await repository.fetch(id: record.id))
        #expect(fixed.aiSummary == "Tide pools at low water")
        #expect(fixed.aiCategory == "Science")
        #expect(fixed.aiTags == ["kelp"])
        #expect(fixed.aiFailureReason == nil)
        #expect(try await repository.searchFullText("Tide pools at low water").first?.id == record.id)
    }

    @Test("Fill-missing ignores existing summaries and file-info stubs")
    func recordsNeedingSummarySkipStubsAndExisting() async throws {
        let (_, repository, _) = try await makeDatabase()
        let stub = """
        ## File info

        - Name: a.bin
        - Type: BIN file
        - Size: 1 KB

        \(FileInfoStub.marker) Use Open to view it.
        """
        try await repository.insert(KnowledgeItemRecord(
            id: UUID(),
            contentType: .plainText,
            title: "Done",
            markdownBody: "A finished article about kelp forests.",
            aiSummary: "Already summarized",
            createdAt: Date(timeIntervalSince1970: 30),
            updatedAt: Date(timeIntervalSince1970: 30)
        ))
        try await repository.insert(KnowledgeItemRecord(
            id: UUID(),
            contentType: .genericFile,
            title: "Stub",
            markdownBody: stub,
            createdAt: Date(timeIntervalSince1970: 20),
            updatedAt: Date(timeIntervalSince1970: 20)
        ))
        let missingID = UUID()
        try await repository.insert(KnowledgeItemRecord(
            id: missingID,
            contentType: .plainText,
            title: "Missing",
            markdownBody: "An unread essay about tide pools.",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        ))

        let needing = try await repository.recordsNeedingAISummary()
        #expect(needing.map(\.id) == [missingID])
    }
}
