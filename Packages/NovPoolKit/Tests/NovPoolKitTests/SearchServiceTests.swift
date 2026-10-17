import Foundation
import NovPoolCore
import Testing
@testable import NovPoolStorage

/// 查询向量替身：返回固定向量。
struct FakeQueryEmbedder: QueryEmbeddingProviding {
    var vector: [Float]?

    func embed(_ text: String) async throws -> [Float]? { vector }
}

@Suite("混合检索（FTS5 + vDSP + RRF）")
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
                pageTitle: "来源页",
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

    @Test("RRF：奖励跨路一致性——两路都靠后的条目胜过只在单路靠前的条目")
    func rrfFusion() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        // a 两路都第 1；b 只在全文路第 2；c 只在向量路第 2；d 两路都第 3
        let fullText = [a, b, d]
        let vector = [a, c, d]
        let scores = RankFusion.fuse([fullText, vector])
        let ranked = RankFusion.ranked([fullText, vector])

        #expect(ranked.count == 4)                        // 重复 id 不产生重复条目
        #expect(ranked.first == a)
        #expect(ranked.filter { $0 == a }.count == 1)
        // d 虽然两路都只排第 3，但两路一致同意它相关，于是压过只在单路排第 2 的 b / c。
        #expect(scores[a]! > scores[d]!)
        #expect(scores[d]! > scores[b]!)
        #expect(ranked[1] == d)
        // b 与 c 分数相同，按首次出现顺序稳定排列。
        #expect(Array(ranked.suffix(2)) == [b, c])
    }

    @Test("RRF：k 值越小头部优势越大")
    func rrfKSensitivity() {
        let first = UUID(), second = UUID()
        let small = RankFusion.fuse([[first, second]], k: 1)
        let large = RankFusion.fuse([[first, second]], k: 100)
        #expect(small[first]! - small[second]! > large[first]! - large[second]!)
    }

    // MARK: - 全文

    @Test("无向量通道时退化为纯 FTS5 检索")
    func fullTextOnly() async throws {
        let (harness, service) = try await makeHarness()
        try await insert(harness.repository, title: "多云知识路由中枢", body: "拖拽收集与自动归档")
        try await insert(harness.repository, title: "无关条目", body: "完全不同的内容")

        let results = try await service.search("知识路由")
        #expect(results.count == 1)
        #expect(results[0].title == "多云知识路由中枢")
        #expect(results[0].isFullTextMatch)
        #expect(results[0].isSemanticMatch == false)
        #expect(results[0].matchLabel == "关键词")
        #expect(results[0].previewBody?.contains("拖拽收集") == true)
    }

    @Test("短查询（<3 字符）走 LIKE 兜底仍能命中")
    func shortQueryFallback() async throws {
        let (harness, service) = try await makeHarness()
        try await insert(harness.repository, title: "AI 摘要流水线")

        let results = try await service.search("AI")
        #expect(results.count == 1)
        #expect(results[0].isFullTextMatch)
    }

    @Test("空查询返回最近条目，按时间倒序")
    func recentItems() async throws {
        let (harness, service) = try await makeHarness()
        let old = try await insert(
            harness.repository,
            title: "较早的条目",
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let fresh = try await insert(
            harness.repository,
            title: "最新的条目",
            createdAt: Date(timeIntervalSince1970: 2_000)
        )

        let results = try await service.recent(limit: 10)
        #expect(results.map(\.id) == [fresh, old])
        #expect(results.allSatisfy { $0.matchLabel == "最近" })
        #expect(try await service.search("   ").map(\.id) == [fresh, old])
    }

    // MARK: - 语义

    @Test("语义召回：关键词完全没命中的条目也能被向量找到")
    func semanticRecall() async throws {
        let embedder = FakeQueryEmbedder(vector: [1, 0, 0])
        let (harness, service) = try await makeHarness(embedder: embedder)
        let onTopic = try await insert(
            harness.repository,
            title: "端侧推理优化",
            body: "量化与算子融合",
            embedding: [1, 0, 0]
        )
        try await insert(harness.repository, title: "无关条目", body: "完全不同的内容", embedding: [0, 1, 0])

        // 查询词与该条目文本毫无重合，只能靠向量召回。
        let results = try await service.search("模型加速")
        #expect(results.count == 1)
        #expect(results[0].id == onTopic)
        #expect(results[0].isSemanticMatch)
        #expect(results[0].isFullTextMatch == false)
        #expect(results[0].matchLabel == "语义")
    }

    @Test("两路同时命中：融合去重且标记为关键词 + 语义")
    func hybridDeduplication() async throws {
        let embedder = FakeQueryEmbedder(vector: [1, 0, 0])
        let (harness, service) = try await makeHarness(embedder: embedder)
        let both = try await insert(
            harness.repository,
            title: "多云知识路由中枢",
            body: "拖拽收集",
            embedding: [1, 0, 0]
        )
        let onlyText = try await insert(harness.repository, title: "多云知识路由的另一种实现")
        let onlyVector = try await insert(harness.repository, title: "端侧推理", embedding: [0.9, 0.1, 0])

        let results = try await service.search("知识路由")
        #expect(Set(results.map(\.id)) == Set([both, onlyText, onlyVector]))
        let top = try #require(results.first)
        #expect(top.id == both)
        #expect(top.isFullTextMatch && top.isSemanticMatch)
        #expect(top.matchLabel == "关键词 + 语义")
    }

    @Test("相似度过低的向量候选被丢弃；维度不一致不会崩溃")
    func vectorThresholdAndDimensionMismatch() async throws {
        let embedder = FakeQueryEmbedder(vector: [1, 0, 0])
        let (harness, service) = try await makeHarness(embedder: embedder)
        try await insert(harness.repository, title: "弱相关条目", embedding: [0.1, 0.9, 0])
        try await insert(harness.repository, title: "维度不一致条目", embedding: [1, 0])

        #expect(try await service.search("没有关键词命中的查询").isEmpty)
    }

    @Test("向量模型不可用时静默退化为纯全文检索")
    func embedderFailureDegrades() async throws {
        let (harness, service) = try await makeHarness(embedder: FakeQueryEmbedder(vector: nil))
        try await insert(harness.repository, title: "多云知识路由中枢", embedding: [1, 0, 0])
        let results = try await service.search("知识路由")
        #expect(results.count == 1)
        #expect(results[0].isSemanticMatch == false)
    }

    // MARK: - 结果装配

    @Test("OCR 文本作为无正文条目的预览内容")
    func previewFallsBackToOCR() async throws {
        let (harness, service) = try await makeHarness()
        try await insert(harness.repository, title: "截图条目", ocr: "Apple Neural Engine 神经网络加速")
        let results = try await service.search("神经网络")
        #expect(results.first?.previewBody == "Apple Neural Engine 神经网络加速")
    }

    @Test("暂存文件存在时给出本地路径，被清理后返回 nil")
    func localFileResolution() async throws {
        let (harness, service) = try await makeHarness()
        let asset = try await harness.staging.stage(data: Data("fake".utf8), preferredExtension: "png")
        try await insert(
            harness.repository,
            title: "带文件的条目",
            body: "正文内容",
            relativePath: asset.relativePath
        )
        let results = try await service.search("正文内容")
        #expect(results.first?.localFileURL == asset.absoluteURL)
        #expect(results.first?.hasLocalFile == true)

        try await harness.staging.remove(relativePath: asset.relativePath)
        let afterCleanup = try await service.search("正文内容")
        #expect(afterCleanup.first?.localFileURL == nil)
    }

    @Test("limit 生效，且结果数不超过命中数")
    func limitRespected() async throws {
        let (harness, service) = try await makeHarness()
        for index in 0..<12 {
            try await insert(harness.repository, title: "云路由实践 \(index)", body: "共同关键词：多云路由")
        }
        #expect(try await service.search("多云路由", limit: 5).count == 5)
        #expect(try await service.search("多云路由", limit: 100).count == 12)
    }

    @Test("回车动作：网页优先、其次本地文件、都没有则不可用")
    func defaultActionResolution() {
        let web = KnowledgeSearchResult(
            id: UUID(),
            title: "网页条目",
            contentType: .webLink,
            sourceURL: URL(string: "https://example.com/a"),
            localFileURL: URL(filePath: "/tmp/a.png")
        )
        #expect(web.defaultAction == .openURL(URL(string: "https://example.com/a")!))

        let fileOnly = KnowledgeSearchResult(
            id: UUID(),
            title: "本地文件",
            contentType: .image,
            localFileURL: URL(filePath: "/tmp/b.png")
        )
        #expect(fileOnly.defaultAction == .revealFile(URL(filePath: "/tmp/b.png")))

        let neither = KnowledgeSearchResult(id: UUID(), title: "纯文本", contentType: .plainText)
        #expect(neither.defaultAction == SearchResultAction.none)
        #expect(neither.defaultAction.isEnabled == false)
    }

    @Test("复制到剪贴板时带上标题、摘要、来源与正文")
    func clipboardText() {
        let result = KnowledgeSearchResult(
            id: UUID(),
            title: "多云知识路由中枢",
            summary: "一句话摘要",
            contentType: .webLink,
            sourceURL: URL(string: "https://example.com/a"),
            previewBody: "# 正文"
        )
        let text = result.clipboardText
        #expect(text.contains("# 多云知识路由中枢"))
        #expect(text.contains("> 一句话摘要"))
        #expect(text.contains("https://example.com/a"))
        #expect(text.contains("# 正文"))
    }
}
