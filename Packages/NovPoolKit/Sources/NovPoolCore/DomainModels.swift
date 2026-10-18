import Foundation

// MARK: - Drag content type

/// Normalized shape of a dropped item (web / image / PDF…).
/// Chooses the enrichment branch; shown in UI as a fixed type tag, not a topic category.
public enum ContentType: String, Codable, Sendable, CaseIterable {
    case plainText
    case richHTML
    case webLink
    case image
    case video
    case documentPDF
    case genericFile

    /// Short type tag shown with the item.
    public var displayTag: String {
        switch self {
        case .webLink: "Web"
        case .image: "Image"
        case .video: "Video"
        case .documentPDF: "PDF"
        case .plainText: "Text"
        case .richHTML: "Rich text"
        case .genericFile: "File"
        }
    }
}

/// Classify a file by extension (image / video / PDF / other).
/// Staging, OCR/summary, cloud naming, and icons all depend on this.
public enum FileKind: String, Sendable, Equatable {
    case image
    case video
    case pdf
    case other

    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "svg",
    ]
    public static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mkv", "webm", "flv", "wmv", "mpeg", "mpg", "3gp",
    ]

    public static func of(pathExtension raw: String) -> FileKind {
        let ext = raw.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        if ext == "pdf" { return .pdf }
        return .other
    }

    public static func of(url: URL) -> FileKind {
        of(pathExtension: url.pathExtension)
    }

    public var contentType: ContentType {
        switch self {
        case .image: .image
        case .video: .video
        case .pdf: .documentPDF
        case .other: .genericFile
        }
    }
}

// MARK: - Provenance context

/// Browser / app context captured at drop time (silent provenance).
public struct SourceContext: Codable, Sendable, Equatable {
    public let appBundleID: String
    public let pageURL: URL?
    public let pageTitle: String?
    public let capturedAt: Date

    public init(
        appBundleID: String,
        pageURL: URL? = nil,
        pageTitle: String? = nil,
        capturedAt: Date = Date()
    ) {
        self.appBundleID = appBundleID
        self.pageURL = pageURL
        self.pageTitle = pageTitle
        self.capturedAt = capturedAt
    }
}

// MARK: - Normalized knowledge payload

/// Unified payload for pipeline stages. Codable and Sendable across actors.
public struct NormalizedPayload: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let contentType: ContentType
    public var title: String
    public var markdownBody: String?
    public var ocrText: String?
    public var aiSummary: String?
    public var aiCategory: String?
    public var aiTags: [String]
    public var localStagedURL: URL?
    public var fileHashSHA256: String?
    public var sourceContext: SourceContext
    /// Cloud preview URL filled in by an upstream drive connector during cascade sync.
    public var upstreamAssetURL: URL?

    public init(
        id: UUID = UUID(),
        contentType: ContentType,
        title: String,
        markdownBody: String? = nil,
        ocrText: String? = nil,
        aiSummary: String? = nil,
        aiCategory: String? = nil,
        aiTags: [String] = [],
        localStagedURL: URL? = nil,
        fileHashSHA256: String? = nil,
        sourceContext: SourceContext,
        upstreamAssetURL: URL? = nil
    ) {
        self.id = id
        self.contentType = contentType
        self.title = title
        self.markdownBody = markdownBody
        self.ocrText = ocrText
        self.aiSummary = aiSummary
        self.aiCategory = aiCategory
        self.aiTags = aiTags
        self.localStagedURL = localStagedURL
        self.fileHashSHA256 = fileHashSHA256
        self.sourceContext = sourceContext
        self.upstreamAssetURL = upstreamAssetURL
    }
}

// MARK: - Remote receipt

public struct RemoteReceipt: Codable, Sendable, Equatable {
    public let connectorID: String
    public let remoteItemID: String
    public let remoteWebURL: URL
    public let syncedAt: Date

    public init(connectorID: String, remoteItemID: String, remoteWebURL: URL, syncedAt: Date = Date()) {
        self.connectorID = connectorID
        self.remoteItemID = remoteItemID
        self.remoteWebURL = remoteWebURL
        self.syncedAt = syncedAt
    }
}

// MARK: - Drop sectors

/// Quick-drop sectors expanded while hovering the float icon (up to 4).
public struct DropZone: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public var title: String
    public var systemImage: String
    /// `nil` means the smart-route sector; `RouteEvaluator` picks the connector.
    public var connectorID: String?

    public init(id: String, title: String, systemImage: String, connectorID: String? = nil) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.connectorID = connectorID
    }

    public var isSmartRoute: Bool { connectorID == nil }

    /// Local-first default: save on this Mac only. Add cloud sectors in Settings.
    public static let defaultZones: [DropZone] = [
        DropZone(id: "local", title: "Save locally", systemImage: "internaldrive"),
    ]
}

// MARK: - Errors

public enum NovPoolError: Error, Sendable, Equatable {
    case unsupportedContent
    case stagingFailure(String)
    case database(String)
    case connectorNotConfigured(String)
    case authenticationRequired(String)
    case notImplemented(String)
}

extension NovPoolError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedContent:
            "The pasteboard has no archivable content representation."
        case .stagingFailure(let detail):
            "Staging failed: \(detail)"
        case .database(let detail):
            "Database error: \(detail)"
        case .connectorNotConfigured(let connectorID):
            "Connector not configured or disabled: \(connectorID)"
        case .authenticationRequired(let detail):
            // detail may be a connector id or a refresh failure reason.
            "Authorization expired: \(SecretRedactor.redact(detail)). Open Settings to re-authorize the cloud service."
        case .notImplemented(let feature):
            "Not implemented: \(feature)"
        }
    }
}
