import Foundation

/// Schema migration. v1 corresponds one-to-one with §4.2 of the product white paper.
public enum SchemaMigration {
    public struct Migration: Sendable {
        public let name: String
        public let statements: [String]

        public init(name: String, statements: [String]) {
            self.name = name
            self.statements = statements
        }
    }

    public static let all: [Migration] = [SchemaMigration.v1, SchemaMigration.v2, SchemaMigration.v3, SchemaMigration.v4]

    public static let v1 = Migration(
        name: "v1_initial_schema",
        statements: [
            """
            CREATE TABLE knowledge_items (
                id TEXT PRIMARY KEY NOT NULL,
                contentType TEXT NOT NULL,
                title TEXT NOT NULL,
                markdownBody TEXT,
                ocrText TEXT,
                aiSummary TEXT,
                aiCategory TEXT,
                aiTagsJSON TEXT NOT NULL DEFAULT '[]',
                sourceApp TEXT,
                sourceURL TEXT,
                sourceTitle TEXT,
                fileHashSHA256 TEXT,
                localRelativePath TEXT,
                embeddingBlob BLOB,
                createdAt TEXT NOT NULL,
                updatedAt TEXT NOT NULL
            )
            """,
            "CREATE INDEX idx_knowledge_items_aiCategory ON knowledge_items(aiCategory)",
            "CREATE INDEX idx_knowledge_items_fileHash ON knowledge_items(fileHashSHA256)",
            "CREATE INDEX idx_knowledge_items_createdAt ON knowledge_items(createdAt)",

            // FTS5 external content table + trigram tokenizer: supports mixed Chinese and English substring search.
            """
            CREATE VIRTUAL TABLE knowledge_items_fts USING fts5(
                title,
                markdownBody,
                ocrText,
                aiSummary,
                aiTagsJSON,
                sourceTitle,
                content='knowledge_items',
                content_rowid='rowid',
                tokenize='trigram'
            )
            """,
            """
            CREATE TRIGGER knowledge_items_fts_ai AFTER INSERT ON knowledge_items BEGIN
                INSERT INTO knowledge_items_fts(rowid, title, markdownBody, ocrText, aiSummary, aiTagsJSON, sourceTitle)
                VALUES (new.rowid, new.title, new.markdownBody, new.ocrText, new.aiSummary, new.aiTagsJSON, new.sourceTitle);
            END
            """,
            """
            CREATE TRIGGER knowledge_items_fts_ad AFTER DELETE ON knowledge_items BEGIN
                INSERT INTO knowledge_items_fts(knowledge_items_fts, rowid, title, markdownBody, ocrText, aiSummary, aiTagsJSON, sourceTitle)
                VALUES ('delete', old.rowid, old.title, old.markdownBody, old.ocrText, old.aiSummary, old.aiTagsJSON, old.sourceTitle);
            END
            """,
            """
            CREATE TRIGGER knowledge_items_fts_au AFTER UPDATE ON knowledge_items BEGIN
                INSERT INTO knowledge_items_fts(knowledge_items_fts, rowid, title, markdownBody, ocrText, aiSummary, aiTagsJSON, sourceTitle)
                VALUES ('delete', old.rowid, old.title, old.markdownBody, old.ocrText, old.aiSummary, old.aiTagsJSON, old.sourceTitle);
                INSERT INTO knowledge_items_fts(rowid, title, markdownBody, ocrText, aiSummary, aiTagsJSON, sourceTitle)
                VALUES (new.rowid, new.title, new.markdownBody, new.ocrText, new.aiSummary, new.aiTagsJSON, new.sourceTitle);
            END
            """,

            """
            CREATE TABLE connectors (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                connectorType TEXT NOT NULL,
                keychainAccountRef TEXT,
                bookmarkData BLOB,
                configJSON TEXT NOT NULL,
                isEnabled BOOLEAN NOT NULL DEFAULT 1,
                createdAt TEXT NOT NULL
            )
            """,

            """
            CREATE TABLE sync_outbox_jobs (
                jobID TEXT PRIMARY KEY NOT NULL,
                itemID TEXT NOT NULL REFERENCES knowledge_items(id) ON DELETE CASCADE,
                connectorID TEXT NOT NULL REFERENCES connectors(id) ON DELETE CASCADE,
                dependsOnJobID TEXT,
                status TEXT NOT NULL DEFAULT 'PENDING',
                retryCount INTEGER NOT NULL DEFAULT 0,
                nextRetryAt TEXT NOT NULL,
                lastError TEXT,
                remoteItemID TEXT,
                remoteWebURL TEXT,
                updatedAt TEXT NOT NULL
            )
            """,
            "CREATE INDEX idx_outbox_poll ON sync_outbox_jobs(status, nextRetryAt)",
        ]
    )

    /// Phase C: Manual Organize — Pinned and Favorite.
    public static let v2 = Migration(
        name: "v2_organization_flags",
        statements: [
            "ALTER TABLE knowledge_items ADD COLUMN isPinned INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE knowledge_items ADD COLUMN isFavorite INTEGER NOT NULL DEFAULT 0",
            "CREATE INDEX idx_knowledge_items_pinned ON knowledge_items(isPinned DESC, createdAt DESC)",
            "CREATE INDEX idx_knowledge_items_favorite ON knowledge_items(isFavorite DESC, createdAt DESC)",
        ]
    )

    /// L7: readable reason when summarize did not produce a summary. Cleared on the next successful AI write.
    public static let v3 = Migration(
        name: "v3_ai_failure_reason",
        statements: [
            "ALTER TABLE knowledge_items ADD COLUMN aiFailureReason TEXT",
        ]
    )

    /// L8: source item IDs for a saved cross-item digest, so citations stay navigable.
    public static let v4 = Migration(
        name: "v4_digest_source_ids",
        statements: [
            "ALTER TABLE knowledge_items ADD COLUMN digestSourceIDsJSON TEXT",
        ]
    )
}

/// Migration executor: Records applied migration names in the `novpool_migrations` table.
public enum SchemaMigrator {
    public static func migrate(_ database: NovPoolDatabase, migrations: [SchemaMigration.Migration] = SchemaMigration.all) async throws {
        try await database.execute(
            "CREATE TABLE IF NOT EXISTS novpool_migrations (name TEXT PRIMARY KEY NOT NULL, appliedAt TEXT NOT NULL)"
        )
        let applied = try await database.query("SELECT name FROM novpool_migrations")
        let appliedNames = Set(applied.compactMap { $0.text("name") })

        for migration in migrations where !appliedNames.contains(migration.name) {
            try await database.executeBatch(
                migration.statements,
                [
                    (
                        "INSERT INTO novpool_migrations(name, appliedAt) VALUES (?, ?)",
                        [.text(migration.name), .date(Date())]
                    )
                ]
            )
        }
    }
}
