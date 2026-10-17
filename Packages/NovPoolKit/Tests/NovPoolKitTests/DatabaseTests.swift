import Foundation
import NovPoolCore
import Testing
@testable import NovPoolStorage

@Suite("GRDB 等价的 Schema 与检索")
struct DatabaseTests {
    private func makeDatabase() async throws -> (NovPoolDatabase, KnowledgeRepository, URL) {
        let directory = try TestSupport.makeTemporaryDirectory("db")
        let database = try NovPoolDatabase(path: directory.appending(path: "test.sqlite").path(percentEncoded: false))
        try await SchemaMigrator.migrate(database)
        return (database, KnowledgeRepository(database: database), directory)
    }

    @Test("迁移可重复执行且幂等")
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

    @Test("WAL 模式已开启")
    func walEnabled() async throws {
        let (database, _, _) = try await makeDatabase()
        let rows = try await database.query("PRAGMA journal_mode")
        #expect(rows.first?.text("journal_mode")?.lowercased() == "wal")
    }

    @Test("写入后可读回全部字段")
    func insertAndFetch() async throws {
        let (_, repository, _) = try await makeDatabase()
        let payload = TestSupport.samplePayload(title: "架构白皮书", tags: ["swift", "架构"])
        var record = KnowledgeItemRecord(payload: payload, localRelativePath: "uuid/asset.png")
        record.fileHashSHA256 = "deadbeef"
        try await repository.insert(record)

        let loaded = try #require(try await repository.fetch(id: record.id))
        #expect(loaded.title == "架构白皮书")
        #expect(loaded.aiTags == ["swift", "架构"])
        #expect(loaded.sourceApp == "com.google.Chrome")
        #expect(loaded.sourceURL == "https://example.com/a")
        #expect(loaded.localRelativePath == "uuid/asset.png")
        #expect(try await repository.fetchByHash("deadbeef")?.id == record.id)
    }

    @Test("FTS5 trigram 支持中文子串检索")
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

    @Test("少于 3 个字符的查询自动降级为 LIKE 子串扫描")
    func shortQueryFallsBackToLike() async throws {
        let (_, repository, _) = try await makeDatabase()
        try await repository.insert(KnowledgeItemRecord(
            payload: TestSupport.samplePayload(title: "AI 摘要流水线", body: nil),
            localRelativePath: nil
        ))

        // trigram 索引无法命中 2 字符查询，必须由 LIKE 兜底。
        let twoCharacterHits = try await repository.searchFullText("AI")
        #expect(twoCharacterHits.count == 1)
        let chineseHits = try await repository.searchFullText("摘要")
        #expect(chineseHits.count == 1)
    }

    @Test("包含引号与通配符的查询不会破坏 SQL")
    func hostileQueryIsEscaped() async throws {
        let (_, repository, _) = try await makeDatabase()
        try await repository.insert(KnowledgeItemRecord(
            payload: TestSupport.samplePayload(title: "含 100% 与 \"引号\" 的标题"),
            localRelativePath: nil
        ))
        let quoted = try await repository.searchFullText("\"引号\"")
        #expect(quoted.count == 1)
        let percent = try await repository.searchFullText("100%")
        #expect(percent.count == 1)
    }

    @Test("OCR / AI 回填后 FTS 索引由触发器自动同步")
    func enrichmentUpdatesIndex() async throws {
        let (_, repository, _) = try await makeDatabase()
        let record = KnowledgeItemRecord(
            payload: TestSupport.samplePayload(title: "截图条目", body: nil),
            localRelativePath: "uuid/asset.png"
        )
        try await repository.insert(record)
        #expect(try await repository.searchFullText("神经网络加速").isEmpty)

        try await repository.updateEnrichment(
            id: record.id,
            ocrText: "Apple Neural Engine 神经网络加速",
            aiSummary: "端侧 OCR 摘要",
            aiCategory: "技术",
            aiTags: ["OCR", "ANE"],
            embedding: [0.1, 0.2, 0.3]
        )

        let hits = try await repository.searchFullText("神经网络加速")
        #expect(hits.count == 1)
        #expect(hits.first?.category == "技术")
        #expect(hits.first?.tags == ["OCR", "ANE"])

        let embeddings = try await repository.embeddingRows()
        #expect(embeddings.count == 1)
        #expect(embeddings[0].vector.count == 3)
    }

    @Test("删除条目后索引同步清理")
    func deleteClearsIndex() async throws {
        let (_, repository, _) = try await makeDatabase()
        let record = KnowledgeItemRecord(
            payload: TestSupport.samplePayload(title: "临时笔记"),
            localRelativePath: nil
        )
        try await repository.insert(record)
        #expect(try await repository.count() == 1)

        #expect(try await repository.delete(id: record.id))
        #expect(try await repository.count() == 0)
        #expect(try await repository.searchFullText("临时笔记").isEmpty)
        #expect(try await repository.searchSubstring("临时笔记").isEmpty)
    }

    @Test("条目删除后级联清理发件箱任务")
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

    @Test("连接器配置可增删改查，敏感字段不落库")
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
}
