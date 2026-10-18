import Foundation
import NovPoolCore

/// The read/write interface of `knowledge_items` + FTS5.
public struct KnowledgeRepository: Sendable {
    private let database: NovPoolDatabase

    public init(database: NovPoolDatabase) {
        self.database = database
    }

    private static let columns = """
        id, contentType, title, markdownBody, ocrText, aiSummary, aiCategory, aiTagsJSON, \
        sourceApp, sourceURL, sourceTitle, fileHashSHA256, localRelativePath, embeddingBlob, \
        isPinned, isFavorite, createdAt, updatedAt
        """

    // MARK: - write

    public func insert(_ record: KnowledgeItemRecord) async throws {
        try await database.execute(
            """
            INSERT INTO knowledge_items (\(Self.columns))
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            Self.bindings(for: record)
        )
    }

    /// Backfilling of OCR / WebBody / AI enhanced results. FTS5 index is automatically synchronized by triggers.
    public func updateEnrichment(
        id: UUID,
        markdownBody: String? = nil,
        ocrText: String? = nil,
        aiSummary: String? = nil,
        aiCategory: String? = nil,
        aiTags: [String]? = nil,
        embedding: [Float]? = nil,
        title: String? = nil
    ) async throws {
        var assignments: [String] = []
        var arguments: [SQLValue] = []

        func set(_ column: String, _ value: SQLValue) {
            assignments.append("\(column) = ?")
            arguments.append(value)
        }

        if let title { set("title", .text(title)) }
        if let markdownBody { set("markdownBody", .text(markdownBody)) }
        if let ocrText { set("ocrText", .text(ocrText)) }
        if let aiSummary { set("aiSummary", .text(aiSummary)) }
        if let aiCategory { set("aiCategory", .text(aiCategory)) }
        if let aiTags {
            let json = (try? JSONEncoder().encode(aiTags)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            set("aiTagsJSON", .text(json))
        }
        if let embedding {
            set("embeddingBlob", .blob(VectorMath.encode(embedding)))
        }
        guard !assignments.isEmpty else { return }
        assignments.append("updatedAt = ?")
        arguments.append(.date(Date()))
        arguments.append(.text(id.uuidString))

        try await database.execute(
            "UPDATE knowledge_items SET \(assignments.joined(separator: ", ")) WHERE id = ?",
            arguments
        )
    }

    /// Manual Organize: Category / Tag / Pinned / Favorite. If the category is left empty, it will be written as SQL NULL.
    public func updateOrganization(id: UUID, organization: KnowledgeOrganization) async throws {
        let tagsJSON = (try? JSONEncoder().encode(organization.tags))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        try await database.execute(
            """
            UPDATE knowledge_items SET
                aiCategory = ?,
                aiTagsJSON = ?,
                isPinned = ?,
                isFavorite = ?,
                updatedAt = ?
            WHERE id = ?
            """,
            [
                organization.category.map { SQLValue.text($0) } ?? .null,
                .text(tagsJSON),
                .integer(organization.isPinned ? 1 : 0),
                .integer(organization.isFavorite ? 1 : 0),
                .date(Date()),
                .text(id.uuidString),
            ]
        )
    }

    @discardableResult
    public func delete(id: UUID) async throws -> Bool {
        let changed = try await database.execute(
            "DELETE FROM knowledge_items WHERE id = ?",
            [.text(id.uuidString)]
        )
        return changed > 0
    }

    // MARK: - read

    public func fetch(id: UUID) async throws -> KnowledgeItemRecord? {
        let rows = try await database.query(
            "SELECT \(Self.columns) FROM knowledge_items WHERE id = ?",
            [.text(id.uuidString)]
        )
        return try rows.first.map(Self.decode)
    }

    /// Deduplicate by content hash (File bytes / Link / Text fingerprints all write to this column).
    public func fetchByHash(_ sha256: String) async throws -> KnowledgeItemRecord? {
        let rows = try await database.query(
            "SELECT \(Self.columns) FROM knowledge_items WHERE fileHashSHA256 = ? ORDER BY createdAt DESC LIMIT 1",
            [.text(sha256)]
        )
        return try rows.first.map(Self.decode)
    }

    /// Find by source URL (compatible with historical WebLink entries that have not yet written content fingerprints).
    public func fetchBySourceURL(_ sourceURL: String) async throws -> KnowledgeItemRecord? {
        let rows = try await database.query(
            "SELECT \(Self.columns) FROM knowledge_items WHERE sourceURL = ? ORDER BY createdAt DESC LIMIT 1",
            [.text(sourceURL)]
        )
        return try rows.first.map(Self.decode)
    }

    public func recent(limit: Int = 20) async throws -> [KnowledgeSearchHit] {
        let rows = try await database.query(
            """
            SELECT id, title, aiSummary, aiCategory, aiTagsJSON, contentType, sourceURL, sourceTitle, createdAt
            FROM knowledge_items
            ORDER BY isPinned DESC, createdAt DESC
            LIMIT ?
            """,
            [.integer(Int64(limit))]
        )
        return rows.map(Self.decodeHit)
    }

    public func count() async throws -> Int {
        Int(try await database.scalarInt("SELECT COUNT(*) AS value FROM knowledge_items") ?? 0)
    }

    /// AI categories that have appeared in the database (remove empty, sorted by frequency of appearance), for filtering in the search panel.
    public func distinctCategories(limit: Int = 40) async throws -> [String] {
        let rows = try await database.query(
            """
            SELECT aiCategory AS value, COUNT(*) AS c
            FROM knowledge_items
            WHERE aiCategory IS NOT NULL AND TRIM(aiCategory) != ''
            GROUP BY aiCategory
            ORDER BY c DESC, aiCategory ASC
            LIMIT ?
            """,
            [.integer(Int64(limit))]
        )
        return rows.compactMap { $0.text("value") }
    }

    /// Full-text search.
    ///
    /// Use the FTS5 trigram tokenizer; since the minimum matching unit of the trigram index is 3 characters,
    /// Queries with length < 3 (for example, two-character Chinese words like "AI" or "note") are automatically downgraded to `LIKE` substring scans.
    public func searchFullText(_ rawQuery: String, limit: Int = 20) async throws -> [KnowledgeSearchHit] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return try await recent(limit: limit) }

        if query.count >= 3 {
            let phrase = "\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            let rows = try await database.query(
                """
                SELECT k.id, k.title, k.aiSummary, k.aiCategory, k.aiTagsJSON, k.contentType,
                       k.sourceURL, k.sourceTitle, k.createdAt,
                       snippet(knowledge_items_fts, 1, '', '', '…', 16) AS snippet,
                       bm25(knowledge_items_fts, 10.0, 4.0, 3.0, 4.0, 6.0, 3.0) AS rank
                FROM knowledge_items_fts
                JOIN knowledge_items k ON k.rowid = knowledge_items_fts.rowid
                WHERE knowledge_items_fts MATCH ?
                ORDER BY rank, k.createdAt DESC
                LIMIT ?
                """,
                [.text(phrase), .integer(Int64(limit))]
            )
            if !rows.isEmpty { return rows.map(Self.decodeHit) }
        }

        return try await searchSubstring(query, limit: limit)
    }

    /// LIKE fallback search (short queries / FTS no hits / scenarios not covered by trigram index).
    public func searchSubstring(_ query: String, limit: Int = 20) async throws -> [KnowledgeSearchHit] {
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%\(escaped)%"
        let rows = try await database.query(
            """
            SELECT id, title, aiSummary, aiCategory, aiTagsJSON, contentType, sourceURL, sourceTitle,
                   createdAt,
                   substr(COALESCE(markdownBody, ocrText, ''), 1, 160) AS snippet
            FROM knowledge_items
            WHERE title LIKE ?1 ESCAPE '\\'
               OR markdownBody LIKE ?1 ESCAPE '\\'
               OR ocrText LIKE ?1 ESCAPE '\\'
               OR aiSummary LIKE ?1 ESCAPE '\\'
               OR aiTagsJSON LIKE ?1 ESCAPE '\\'
               OR sourceTitle LIKE ?1 ESCAPE '\\'
            ORDER BY createdAt DESC
            LIMIT ?2
            """,
            [.text(pattern), .integer(Int64(limit))]
        )
        return rows.map(Self.decodeHit)
    }

    /// readAllEmbedding matrix (used in Phase 4 hybrid retrieval).
    public func embeddingRows() async throws -> [(id: UUID, vector: [Float])] {
        let rows = try await database.query(
            "SELECT id, embeddingBlob FROM knowledge_items WHERE embeddingBlob IS NOT NULL"
        )
        return rows.compactMap { row in
            guard let idText = row.text("id"), let id = UUID(uuidString: idText), let blob = row.blob("embeddingBlob") else {
                return nil
            }
            return (id, VectorMath.decode(blob))
        }
    }

    public func fetchMany(ids: [UUID]) async throws -> [KnowledgeItemRecord] {
        guard !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        let rows = try await database.query(
            "SELECT \(Self.columns) FROM knowledge_items WHERE id IN (\(placeholders))",
            ids.map { .text($0.uuidString) }
        )
        return try rows.map(Self.decode)
    }

    /// There are no entries summarized by AI yet (with Body or OCR available for summarization) for batch processing with the 'Re-summarize' setting.
    public func recordsNeedingAISummary(limit: Int = 40) async throws -> [KnowledgeItemRecord] {
        let rows = try await database.query(
            """
            SELECT \(Self.columns) FROM knowledge_items
            WHERE (aiSummary IS NULL OR TRIM(aiSummary) = '')
              AND (
                (markdownBody IS NOT NULL AND TRIM(markdownBody) != '')
                OR (ocrText IS NOT NULL AND TRIM(ocrText) != '')
              )
            ORDER BY isPinned DESC, createdAt DESC
            LIMIT ?
            """,
            [.integer(Int64(limit))]
        )
        return try rows.map(Self.decode)
    }

    /// Early versions only temporarily stored the local File and did not extract the Body. During startup, use this batch of records to perform a completion.
    public func recordsNeedingLocalFileContent(limit: Int = 100) async throws -> [KnowledgeItemRecord] {
        let rows = try await database.query(
            """
            SELECT \(Self.columns) FROM knowledge_items
            WHERE localRelativePath IS NOT NULL
              AND (markdownBody IS NULL OR TRIM(markdownBody) = '')
              AND (ocrText IS NULL OR TRIM(ocrText) = '')
            ORDER BY createdAt DESC LIMIT ?
            """,
            [.integer(Int64(limit))]
        )
        return try rows.map(Self.decode)
    }

    // MARK: - Mapping

    private static func bindings(for record: KnowledgeItemRecord) -> [SQLValue] {
        [
            .text(record.id.uuidString),
            .text(record.contentType.rawValue),
            .text(record.title),
            record.markdownBody.map { SQLValue.text($0) } ?? .null,
            record.ocrText.map { SQLValue.text($0) } ?? .null,
            record.aiSummary.map { SQLValue.text($0) } ?? .null,
            record.aiCategory.map { SQLValue.text($0) } ?? .null,
            .text(record.tagsJSON),
            record.sourceApp.map { SQLValue.text($0) } ?? .null,
            record.sourceURL.map { SQLValue.text($0) } ?? .null,
            record.sourceTitle.map { SQLValue.text($0) } ?? .null,
            record.fileHashSHA256.map { SQLValue.text($0) } ?? .null,
            record.localRelativePath.map { SQLValue.text($0) } ?? .null,
            record.embedding.map { SQLValue.blob(VectorMath.encode($0)) } ?? .null,
            .integer(record.isPinned ? 1 : 0),
            .integer(record.isFavorite ? 1 : 0),
            .date(record.createdAt),
            .date(record.updatedAt),
        ]
    }

    private static func decode(_ row: SQLRow) throws -> KnowledgeItemRecord {
        guard let idText = row.text("id"), let id = UUID(uuidString: idText) else {
            throw NovPoolError.database("Illegal knowledge_items.id: \(row.text("id") ?? "nil")")
        }
        guard let contentTypeRaw = row.text("contentType"),
              let contentType = ContentType(rawValue: contentTypeRaw) else {
            throw NovPoolError.database("Illegal knowledge_items.contentType")
        }
        let tags = row.text("aiTagsJSON")
            .flatMap { Data($0.utf8) }
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []

        return KnowledgeItemRecord(
            id: id,
            contentType: contentType,
            title: row.text("title") ?? "",
            markdownBody: row.text("markdownBody"),
            ocrText: row.text("ocrText"),
            aiSummary: row.text("aiSummary"),
            aiCategory: row.text("aiCategory"),
            aiTags: tags,
            sourceApp: row.text("sourceApp"),
            sourceURL: row.text("sourceURL"),
            sourceTitle: row.text("sourceTitle"),
            fileHashSHA256: row.text("fileHashSHA256"),
            localRelativePath: row.text("localRelativePath"),
            embedding: row.blob("embeddingBlob").map(VectorMath.decode),
            isPinned: (row.int("isPinned") ?? 0) != 0,
            isFavorite: (row.int("isFavorite") ?? 0) != 0,
            createdAt: row.date("createdAt") ?? Date(),
            updatedAt: row.date("updatedAt") ?? Date()
        )
    }

    private static func decodeHit(_ row: SQLRow) -> KnowledgeSearchHit {
        let tags = row.text("aiTagsJSON")
            .flatMap { Data($0.utf8) }
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        return KnowledgeSearchHit(
            id: row.text("id").flatMap(UUID.init(uuidString:)) ?? UUID(),
            title: row.text("title") ?? "",
            summary: row.text("aiSummary"),
            category: row.text("aiCategory"),
            tags: tags,
            contentType: row.text("contentType").flatMap(ContentType.init(rawValue:)) ?? .plainText,
            sourceURL: row.text("sourceURL").flatMap(URL.init(string:)),
            sourceTitle: row.text("sourceTitle"),
            createdAt: row.date("createdAt") ?? Date(),
            snippet: row.text("snippet")
        )
    }
}
