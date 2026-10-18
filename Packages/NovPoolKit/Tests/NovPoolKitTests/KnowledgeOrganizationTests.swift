import Foundation
import NovPoolCore
import NovPoolStorage
import Testing

@Suite("Manual Organize")
struct KnowledgeOrganizationTests {
    @Test("Tag parsing: remove duplicates while keeping order with commas and enumeration commas")
    func parseTags() {
        #expect(KnowledgeOrganization.parseTags("a, b，a,c; d") == ["a", "b", "c", "d"])
        #expect(KnowledgeOrganization.parseTags("  ").isEmpty)
    }

    @Test("Empty categories are unified as nil")
    func normalizedCategory() {
        let org = KnowledgeOrganization.fromRaw(
            category: "  ",
            tagsText: "swift, macos",
            isPinned: true,
            isFavorite: false
        )
        #expect(org.category == nil)
        #expect(org.tags == ["swift", "macos"])
        #expect(org.isPinned)
        #expect(!org.isFavorite)
    }

    @Test("updateOrganization write and can clear categories")
    func repositoryUpdate() async throws {
        let directory = try TestSupport.makeTemporaryDirectory("org")
        let database = try NovPoolDatabase(path: directory.appending(path: "org.sqlite").path(percentEncoded: false))
        try await SchemaMigrator.migrate(database)
        let repository = KnowledgeRepository(database: database)
        let id = UUID()
        try await repository.insert(
            KnowledgeItemRecord(
                id: id,
                contentType: .plainText,
                title: "Notes",
                aiCategory: "Old category",
                aiTags: ["old"]
            )
        )

        try await repository.updateOrganization(
            id: id,
            organization: KnowledgeOrganization(
                category: "Technology",
                tags: ["swift", "Local"],
                isPinned: true,
                isFavorite: true
            )
        )
        var record = try #require(await repository.fetch(id: id))
        #expect(record.aiCategory == "Technology")
        #expect(record.aiTags == ["swift", "Local"])
        #expect(record.isPinned)
        #expect(record.isFavorite)

        try await repository.updateOrganization(
            id: id,
            organization: KnowledgeOrganization(category: nil, tags: [], isPinned: false, isFavorite: true)
        )
        record = try #require(await repository.fetch(id: id))
        #expect(record.aiCategory == nil)
        #expect(record.aiTags.isEmpty)
        #expect(!record.isPinned)
        #expect(record.isFavorite)
    }

    @Test("Recent list pinned priority")
    func recentPinnedFirst() async throws {
        let directory = try TestSupport.makeTemporaryDirectory("org-pin")
        let database = try NovPoolDatabase(path: directory.appending(path: "org.sqlite").path(percentEncoded: false))
        try await SchemaMigrator.migrate(database)
        let repository = KnowledgeRepository(database: database)
        let older = UUID()
        let newer = UUID()
        let pinned = UUID()
        let now = Date()
        try await repository.insert(
            KnowledgeItemRecord(
                id: older,
                contentType: .plainText,
                title: "old",
                createdAt: now.addingTimeInterval(-100)
            )
        )
        try await repository.insert(
            KnowledgeItemRecord(
                id: newer,
                contentType: .plainText,
                title: "New",
                createdAt: now
            )
        )
        try await repository.insert(
            KnowledgeItemRecord(
                id: pinned,
                contentType: .plainText,
                title: "Pinned item",
                isPinned: true,
                createdAt: now.addingTimeInterval(-50)
            )
        )
        let recent = try await repository.recent(limit: 10)
        #expect(recent.map(\.id) == [pinned, newer, older])
    }
}
