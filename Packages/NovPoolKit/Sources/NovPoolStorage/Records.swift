import Foundation
import NovPoolCore

/// `knowledge_items` 行模型。
public struct KnowledgeItemRecord: Codable, Sendable, Equatable {
    public var id: UUID
    public var contentType: ContentType
    public var title: String
    public var markdownBody: String?
    public var ocrText: String?
    public var aiSummary: String?
    public var aiCategory: String?
    public var aiTags: [String]
    public var sourceApp: String?
    public var sourceURL: String?
    public var sourceTitle: String?
    public var fileHashSHA256: String?
    public var localRelativePath: String?
    public var embedding: [Float]?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID,
        contentType: ContentType,
        title: String,
        markdownBody: String? = nil,
        ocrText: String? = nil,
        aiSummary: String? = nil,
        aiCategory: String? = nil,
        aiTags: [String] = [],
        sourceApp: String? = nil,
        sourceURL: String? = nil,
        sourceTitle: String? = nil,
        fileHashSHA256: String? = nil,
        localRelativePath: String? = nil,
        embedding: [Float]? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.contentType = contentType
        self.title = title
        self.markdownBody = markdownBody
        self.ocrText = ocrText
        self.aiSummary = aiSummary
        self.aiCategory = aiCategory
        self.aiTags = aiTags
        self.sourceApp = sourceApp
        self.sourceURL = sourceURL
        self.sourceTitle = sourceTitle
        self.fileHashSHA256 = fileHashSHA256
        self.localRelativePath = localRelativePath
        self.embedding = embedding
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 由流水线载荷构造行模型。
    public init(payload: NormalizedPayload, localRelativePath: String?, now: Date = Date()) {
        self.init(
            id: payload.id,
            contentType: payload.contentType,
            title: payload.title,
            markdownBody: payload.markdownBody,
            ocrText: payload.ocrText,
            aiSummary: payload.aiSummary,
            aiCategory: payload.aiCategory,
            aiTags: payload.aiTags,
            sourceApp: payload.sourceContext.appBundleID,
            sourceURL: payload.sourceContext.pageURL?.absoluteString,
            sourceTitle: payload.sourceContext.pageTitle,
            fileHashSHA256: payload.fileHashSHA256,
            localRelativePath: localRelativePath,
            embedding: nil,
            createdAt: now,
            updatedAt: now
        )
    }

    /// 还原为流水线载荷（供连接器推送使用）。
    public func toPayload() -> NormalizedPayload {
        NormalizedPayload(
            id: id,
            contentType: contentType,
            title: title,
            markdownBody: markdownBody,
            ocrText: ocrText,
            aiSummary: aiSummary,
            aiCategory: aiCategory,
            aiTags: aiTags,
            localStagedURL: nil,
            fileHashSHA256: fileHashSHA256,
            sourceContext: SourceContext(
                appBundleID: sourceApp ?? "unknown",
                pageURL: sourceURL.flatMap(URL.init(string:)),
                pageTitle: sourceTitle,
                capturedAt: createdAt
            )
        )
    }

    public var tagsJSON: String {
        (try? String(decoding: JSONEncoder().encode(aiTags), as: UTF8.self)) ?? "[]"
    }
}

/// `connectors` 行模型。敏感凭据只存 Keychain，这里仅存引用与书签。
public struct ConnectorRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var connectorType: String
    public var keychainAccountRef: String?
    public var bookmarkData: Data?
    public var configJSON: String
    public var isEnabled: Bool
    public var createdAt: Date

    public init(
        id: String,
        name: String,
        connectorType: String,
        keychainAccountRef: String? = nil,
        bookmarkData: Data? = nil,
        configJSON: String = "{}",
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.connectorType = connectorType
        self.keychainAccountRef = keychainAccountRef
        self.bookmarkData = bookmarkData
        self.configJSON = configJSON
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }

    public var configData: Data { Data(configJSON.utf8) }
}

/// `sync_outbox_jobs` 行模型。
public struct OutboxJobRecord: Codable, Sendable, Equatable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case pending = "PENDING"
        case running = "RUNNING"
        case blocked = "BLOCKED"
        case succeeded = "SUCCEEDED"
        case failed = "FAILED"
    }

    public var id: UUID
    public var itemID: UUID
    public var connectorID: String
    public var dependsOnJobID: UUID?
    public var status: Status
    public var retryCount: Int
    public var nextRetryAt: Date
    public var lastError: String?
    public var remoteItemID: String?
    public var remoteWebURL: String?
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        itemID: UUID,
        connectorID: String,
        dependsOnJobID: UUID? = nil,
        status: Status = .pending,
        retryCount: Int = 0,
        nextRetryAt: Date = Date(),
        lastError: String? = nil,
        remoteItemID: String? = nil,
        remoteWebURL: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.itemID = itemID
        self.connectorID = connectorID
        self.dependsOnJobID = dependsOnJobID
        self.status = status
        self.retryCount = retryCount
        self.nextRetryAt = nextRetryAt
        self.lastError = lastError
        self.remoteItemID = remoteItemID
        self.remoteWebURL = remoteWebURL
        self.updatedAt = updatedAt
    }
}

/// 检索命中结果。
public struct KnowledgeSearchHit: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var summary: String?
    public var category: String?
    public var tags: [String]
    public var contentType: ContentType
    public var sourceURL: URL?
    public var sourceTitle: String?
    public var createdAt: Date
    /// FTS5 `snippet()` 片段，或向量检索的正文截断。
    public var snippet: String?

    public init(
        id: UUID,
        title: String,
        summary: String?,
        category: String?,
        tags: [String],
        contentType: ContentType,
        sourceURL: URL?,
        sourceTitle: String?,
        createdAt: Date,
        snippet: String?
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.category = category
        self.tags = tags
        self.contentType = contentType
        self.sourceURL = sourceURL
        self.sourceTitle = sourceTitle
        self.createdAt = createdAt
        self.snippet = snippet
    }
}
