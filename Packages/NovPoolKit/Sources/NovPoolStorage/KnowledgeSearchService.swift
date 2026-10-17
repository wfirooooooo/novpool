import Foundation
import NovPoolCore

/// 查询向量提供者。
///
/// 定义在存储层是为了保持依赖方向：向量模型实现（Ollama / OpenAI / NLEmbedding）
/// 位于上层模块，只要满足本协议即可注入。
public protocol QueryEmbeddingProviding: Sendable {
    func embed(_ text: String) async throws -> [Float]?
}

/// 混合检索：GRDB 等价的 FTS5 全文 + Accelerate vDSP 向量相似度，用 RRF 融合。
public actor KnowledgeSearchService {
    public struct Configuration: Sendable {
        /// 向量相似度低于该值不参与语义排序（余弦 0.2 以下基本无关）。
        public var minimumVectorScore: Float
        /// 单路召回规模倍数：先各自多召回，再融合截断，避免漏掉只在单路出现的条目。
        public var candidateMultiplier: Int
        public var fusionK: Int

        public init(
            minimumVectorScore: Float = 0.2,
            candidateMultiplier: Int = 3,
            fusionK: Int = RankFusion.defaultK
        ) {
            self.minimumVectorScore = minimumVectorScore
            self.candidateMultiplier = candidateMultiplier
            self.fusionK = fusionK
        }
    }

    private let repository: KnowledgeRepository
    private let staging: StagingStore?
    private let embedder: (any QueryEmbeddingProviding)?
    private let fileManager: FileManager
    public var configuration: Configuration

    public init(
        repository: KnowledgeRepository,
        staging: StagingStore? = nil,
        embedder: (any QueryEmbeddingProviding)? = nil,
        configuration: Configuration = Configuration(),
        fileManager: FileManager = .default
    ) {
        self.repository = repository
        self.staging = staging
        self.embedder = embedder
        self.configuration = configuration
        self.fileManager = fileManager
    }

    /// 混合检索。空查询返回最近条目。
    public func search(_ rawQuery: String, limit: Int = 20) async throws -> [KnowledgeSearchResult] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return try await recent(limit: limit) }

        let candidateLimit = max(limit * configuration.candidateMultiplier, limit)
        let textHits = try await repository.searchFullText(query, limit: candidateLimit)
        let textRanking = textHits.map(\.id)
        let vectorRanking = await vectorRanking(for: query, limit: candidateLimit)

        guard !textRanking.isEmpty || !vectorRanking.isEmpty else { return [] }
        let fused = RankFusion.ranked([textRanking, vectorRanking], k: configuration.fusionK)
        let orderedIDs = Array(fused.prefix(limit))

        let snippetByID = Dictionary(
            textHits.map { ($0.id, $0.snippet) },
            uniquingKeysWith: { first, _ in first }
        )
        let textIDs = Set(textRanking)
        let vectorIDs = Set(vectorRanking)

        return try await assemble(
            ids: orderedIDs,
            snippetByID: snippetByID,
            textIDs: textIDs,
            vectorIDs: vectorIDs
        )
    }

    /// 最近条目（面板刚打开、还没输入时的默认列表）。
    public func recent(limit: Int = 20) async throws -> [KnowledgeSearchResult] {
        let hits = try await repository.recent(limit: limit)
        return try await assemble(
            ids: hits.map(\.id),
            snippetByID: [:],
            textIDs: [],
            vectorIDs: []
        )
    }

    /// 语义召回：查询向量与库内向量矩阵逐条算余弦相似度。
    private func vectorRanking(for query: String, limit: Int) async -> [UUID] {
        guard let embedder,
              let queryVector = try? await embedder.embed(query),
              !queryVector.isEmpty else {
            return []
        }
        guard let rows = try? await repository.embeddingRows(), !rows.isEmpty else { return [] }

        // 先在方法作用域取值：actor 隔离属性在非隔离闭包（compactMap/sorted/map）里读
        // 会插入运行时隔离检查。
        let minimumScore = configuration.minimumVectorScore
        return rows
            .compactMap { row -> (UUID, Float)? in
                let score = VectorMath.cosineSimilarity(queryVector, row.vector)
                return score >= minimumScore ? (row.id, score) : nil
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    /// 按给定顺序取出完整记录并补齐 UI 需要的字段。
    private func assemble(
        ids: [UUID],
        snippetByID: [UUID: String?],
        textIDs: Set<UUID>,
        vectorIDs: Set<UUID>
    ) async throws -> [KnowledgeSearchResult] {
        guard !ids.isEmpty else { return [] }
        let records = try await repository.fetchMany(ids: ids)
        let recordByID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var results: [KnowledgeSearchResult] = []
        results.reserveCapacity(ids.count)
        for id in ids {
            guard let record = recordByID[id] else { continue }
            let fileURL = await localFileURL(for: record)
            results.append(
                KnowledgeSearchResult(
                    id: record.id,
                    title: record.title,
                    summary: record.aiSummary,
                    category: record.aiCategory,
                    tags: record.aiTags,
                    contentType: record.contentType,
                    sourceURL: record.sourceURL.flatMap(URL.init(string:)),
                    sourceTitle: record.sourceTitle,
                    createdAt: record.createdAt,
                    snippet: snippetByID[id] ?? nil,
                    previewBody: previewBody(for: record, localFileURL: fileURL),
                    isFullTextMatch: textIDs.contains(id),
                    isSemanticMatch: vectorIDs.contains(id),
                    localFileURL: fileURL,
                    isPinned: record.isPinned,
                    isFavorite: record.isFavorite
                )
            )
        }
        return results
    }

    /// 人工整理并回写分类 / 标签 / 置顶 / 收藏。
    public func updateOrganization(id: UUID, organization: KnowledgeOrganization) async throws {
        try await repository.updateOrganization(id: id, organization: organization)
    }

    /// 删除知识条目，并清理对应 Staging 目录（若有）。
    @discardableResult
    public func deleteItem(id: UUID) async throws -> Bool {
        let record = try await repository.fetch(id: id)
        let removed = try await repository.delete(id: id)
        if removed, let staging, let relativePath = record?.localRelativePath {
            try? await staging.remove(relativePath: relativePath)
        }
        return removed
    }

    public func distinctCategories(limit: Int = 40) async throws -> [String] {
        try await repository.distinctCategories(limit: limit)
    }

    /// 解析并校验暂存文件；Staging 被清理过时返回 nil，避免 UI 给出死路径。
    private func localFileURL(for record: KnowledgeItemRecord) async -> URL? {
        guard let staging, let relativePath = record.localRelativePath else { return nil }
        let url = await staging.absoluteURL(forRelativePath: relativePath)
        return fileManager.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    /// 正文优先；仍为空但有本地文件时给出文件信息，避免详情页空白。
    private func previewBody(for record: KnowledgeItemRecord, localFileURL: URL?) -> String? {
        if let body = record.markdownBody ?? record.ocrText,
           !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return body
        }
        if let localFileURL {
            return LocalFilePreview.summary(for: localFileURL, fileManager: fileManager)
        }
        return nil
    }
}

/// 检索详情页的文件信息兜底（Storage 层自包含，不依赖 SystemBridge）。
public enum LocalFilePreview {
    public static func summary(for url: URL, fileManager: FileManager = .default) -> String {
        let path = url.path(percentEncoded: false)
        let size = (try? fileManager.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
        let sizeText = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        let ext = url.pathExtension.uppercased()
        let type = ext.isEmpty ? "文件" : "\(ext) 文件"
        return """
        ## 文件信息

        - 文件名：\(url.lastPathComponent)
        - 类型：\(type)
        - 大小：\(sizeText)

        原始文件已保存在 NovPool 暂存目录，可点击「打开」或「访达」查看。
        """
    }
}

extension KnowledgeSearchResult {
    /// 复制到剪贴板的文本（Markdown 优先）。
    public var clipboardText: String {
        var parts: [String] = ["# \(title)"]
        if let summary { parts.append("> \(summary)") }
        if let sourceURL { parts.append(sourceURL.absoluteString) }
        if let previewBody { parts.append(previewBody) }
        return parts.joined(separator: "\n\n")
    }
}
