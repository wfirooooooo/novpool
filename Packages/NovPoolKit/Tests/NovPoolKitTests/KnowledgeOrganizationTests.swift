import Foundation
import NovPoolCore
import NovPoolStorage
import Testing

@Suite("人工整理")
struct KnowledgeOrganizationTests {
    @Test("标签解析：逗号顿号去重保序")
    func parseTags() {
        #expect(KnowledgeOrganization.parseTags("a, b，a、c; d") == ["a", "b", "c", "d"])
        #expect(KnowledgeOrganization.parseTags("  ").isEmpty)
    }

    @Test("空分类归一为 nil")
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

    @Test("updateOrganization 写入并可清空分类")
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
                title: "笔记",
                aiCategory: "旧分类",
                aiTags: ["旧"]
            )
        )

        try await repository.updateOrganization(
            id: id,
            organization: KnowledgeOrganization(
                category: "技术",
                tags: ["swift", "本地"],
                isPinned: true,
                isFavorite: true
            )
        )
        var record = try #require(await repository.fetch(id: id))
        #expect(record.aiCategory == "技术")
        #expect(record.aiTags == ["swift", "本地"])
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

    @Test("最近列表置顶优先")
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
                title: "旧",
                createdAt: now.addingTimeInterval(-100)
            )
        )
        try await repository.insert(
            KnowledgeItemRecord(
                id: newer,
                contentType: .plainText,
                title: "新",
                createdAt: now
            )
        )
        try await repository.insert(
            KnowledgeItemRecord(
                id: pinned,
                contentType: .plainText,
                title: "置顶项",
                isPinned: true,
                createdAt: now.addingTimeInterval(-50)
            )
        )
        let recent = try await repository.recent(limit: 10)
        #expect(recent.map(\.id) == [pinned, newer, older])
    }
}
