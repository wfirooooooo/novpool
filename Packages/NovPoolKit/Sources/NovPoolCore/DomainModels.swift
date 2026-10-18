import Foundation

// MARK: - 拖拽资源形态

/// 一次拖拽被归一化后的资源形态（网页 / 图片 / PDF…）。
/// 决定清洗流水线分支；在 UI 里作为固定 tag 跟随条目显示，不等于主题分类。
public enum ContentType: String, Codable, Sendable, CaseIterable {
    case plainText
    case richHTML
    case webLink
    case image
    case video
    case documentPDF
    case genericFile

    /// 跟随资源显示的形态 tag（中文短标签）。
    public var displayTag: String {
        switch self {
        case .webLink: "网页"
        case .image: "图片"
        case .video: "视频"
        case .documentPDF: "PDF"
        case .plainText: "文本"
        case .richHTML: "富文本"
        case .genericFile: "文件"
        }
    }
}

/// 按扩展名归类文件资源。拖拽进来的文件要先分清是图片、视频、PDF 还是普通文件，
/// 后续的暂存、OCR/摘要、云端命名与图标展示都依赖这个判断。
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

// MARK: - 溯源上下文

/// 捕获瞬间的浏览器 / 应用上下文（静默溯源结果）。
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

// MARK: - 标准化知识载荷

/// 流水线中间与出口的统一载荷形态。可持久化、可跨 Actor 传递。
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
    /// 跨云级联时，前置网盘连接器回填的云端预览链接。
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

// MARK: - 云端回执

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

// MARK: - 扇区投递槽位

/// 悬浮窗拖拽悬停时展开的快捷投递槽位（最多 4 个）。
public struct DropZone: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public var title: String
    public var systemImage: String
    /// `nil` 表示“智能路由”槽位，由 `RouteEvaluator` 决定目标连接器。
    public var connectorID: String?

    public init(id: String, title: String, systemImage: String, connectorID: String? = nil) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.connectorID = connectorID
    }

    public var isSmartRoute: Bool { connectorID == nil }

    /// 本地优先默认槽位：只本机入库。云端扇区可在设置里自行添加。
    public static let defaultZones: [DropZone] = [
        DropZone(id: "local", title: "本机入库", systemImage: "internaldrive"),
    ]
}

// MARK: - 错误

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
            "粘贴板中不包含可归档的内容表示层。"
        case .stagingFailure(let detail):
            "本地暂存失败：\(detail)"
        case .database(let detail):
            "数据库错误：\(detail)"
        case .connectorNotConfigured(let connectorID):
            "连接器未配置或已禁用：\(connectorID)"
        case .authenticationRequired(let detail):
            // detail 可能是连接器 ID，也可能是刷新失败原因；统一引导用户去设置重授。
            "授权失效：\(SecretRedactor.redact(detail))。请打开设置重新授权对应云服务。"
        case .notImplemented(let feature):
            "功能尚未实现：\(feature)"
        }
    }
}
