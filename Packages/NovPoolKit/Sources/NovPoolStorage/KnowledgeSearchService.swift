import Foundation
import NovPoolCore

/// Query the embedding provider.
///
/// Defined at the storage layer to maintain the direction of dependency: Embedding model implementation (Ollama / OpenAI / NLEmbedding)
/// Located in the upper-level module, it can be injected as long as this protocol is met.
public protocol QueryEmbeddingProviding: Sendable {
    func embed(_ text: String) async throws -> [Float]?
}

/// Hybrid search: GRDB equivalent FTS5 full text + Accelerate vDSP Embedding similarity, fused using RRF.
public actor KnowledgeSearchService {
    public struct Configuration: Sendable {
        /// Embeddings with a similarity below this value will not participate in semantic ranking (cosine below 0.2 is basically irrelevant).
        public var minimumVectorScore: Float
        /// Single-path recall scale multiplier: first recall more separately, then merge and truncate, to avoid missing entries that appear only in a single path.
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
    private var embedder: (any QueryEmbeddingProviding)?
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

    public func update(embedder: (any QueryEmbeddingProviding)?) {
        self.embedder = embedder
    }

    /// Hybrid search. An empty query returns Recent entries.
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

    /// Recent entries (the default list when the panel is just opened and nothing has been entered yet).
    public func recent(limit: Int = 20) async throws -> [KnowledgeSearchResult] {
        let hits = try await repository.recent(limit: limit)
        return try await assemble(
            ids: hits.map(\.id),
            snippetByID: [:],
            textIDs: [],
            vectorIDs: []
        )
    }

    /// Load one item by ID for citation navigation (the source may be outside the current results).
    public func item(id: UUID) async throws -> KnowledgeSearchResult? {
        try await assemble(
            ids: [id],
            snippetByID: [:],
            textIDs: [],
            vectorIDs: []
        ).first
    }

    /// Semantic recall: Calculate the cosine similarity between the query embedding and each embedding in the database matrix one by one.
    private func vectorRanking(for query: String, limit: Int) async -> [UUID] {
        guard let embedder,
              let queryVector = try? await embedder.embed(query),
              !queryVector.isEmpty else {
            return []
        }
        guard let rows = try? await repository.embeddingRows(), !rows.isEmpty else { return [] }

        // First, get the value in the method scope: read the actor-isolated property in a non-isolated closure (compactMap/sorted/map)
        // Runtime isolation checks will be inserted.
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

    /// Retrieve the complete records in the given order and fill in the fields required by the UI.
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
                    isFavorite: record.isFavorite,
                    aiFailureReason: record.aiFailureReason,
                    digestSourceIDs: record.digestSourceIDs
                )
            )
        }
        return results
    }

    /// Manually organize and write back categories / tags / pinned / favorite.
    public func updateOrganization(id: UUID, organization: KnowledgeOrganization) async throws {
        try await repository.updateOrganization(id: id, organization: organization)
    }

    /// Delete the knowledge entry and clean up the corresponding Staging directory (if any).
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

    /// Parse and validate the temporary File; if the Staging has been cleared, return nil to avoid the UI showing a dead path.
    private func localFileURL(for record: KnowledgeItemRecord) async -> URL? {
        guard let staging, let relativePath = record.localRelativePath else { return nil }
        let url = await staging.absoluteURL(forRelativePath: relativePath)
        return fileManager.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    /// Priority to Body; if still empty but there is a local File, provide File information to avoid a blank detail page.
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

/// File-info fallback for search details (self-contained in Storage; no SystemBridge dependency).
public enum LocalFilePreview {
    public static func summary(for url: URL, fileManager: FileManager = .default) -> String {
        let path = url.path(percentEncoded: false)
        let size = (try? fileManager.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
        let sizeText = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        let ext = url.pathExtension.uppercased()
        let type = ext.isEmpty ? "File" : "\(ext) file"
        return """
        ## File info

        - Name: \(url.lastPathComponent)
        - Type: \(type)
        - Size: \(sizeText)

        The original file is saved in the NovPool staging directory. Use Open or Finder to view it.
        """
    }
}

extension KnowledgeSearchResult {
    /// Text copied to clipboard (Markdown preferred).
    public var clipboardText: String {
        var parts: [String] = ["# \(title)"]
        let tagLine = displayTags.map { "#\($0)" }.joined(separator: " ")
        if !tagLine.isEmpty { parts.append(tagLine) }
        if let category { parts.append("Topic: \(category)") }
        if let summary { parts.append("> \(summary)") }
        if let sourceURL { parts.append(sourceURL.absoluteString) }
        if let previewBody { parts.append(previewBody) }
        return parts.joined(separator: "\n\n")
    }
}
