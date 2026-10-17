import Foundation

/// 粘贴板读取抽象。
///
/// 真实实现包装 `NSPasteboard`；测试使用内存替身，避免依赖 WindowServer
/// 与 `pboard` 守护进程（在无 GUI 会话的 CI / 沙盒环境中不可用）。
public protocol PasteboardReading: Sendable {
    /// 粘贴板中当前存在的所有类型标识符（如 `public.utf8-plain-text`）。
    var availableTypeIdentifiers: [String] { get }
    func data(forTypeIdentifier typeIdentifier: String) -> Data?
    func string(forTypeIdentifier typeIdentifier: String) -> String?
}

/// 粘贴板类型标识符常量（避免 `NovPoolCore` 依赖 AppKit）。
public enum PasteboardTypeID {
    public static let fileURL = "public.file-url"
    public static let url = "public.url"
    /// Safari 用 `public.url-name` 携带链接/标签标题。
    public static let urlName = "public.url-name"
    /// URL 列表（Chrome/Edge/Firefox 拖标签时会带）。
    public static let uriList = "text/uri-list"
    /// Firefox / Zen 的标签拖拽格式，内容为 UTF-16LE 的「URL\n标题」。
    public static let mozURL = "text/x-moz-url"
    public static let mozURLData = "text/x-moz-url-data"
    public static let html = "public.html"
    public static let plainText = "public.utf8-plain-text"
    public static let png = "public.png"
    public static let tiff = "public.tiff"
    public static let jpeg = "public.jpeg"
    public static let mpeg4Movie = "public.mpeg-4"
    public static let movie = "public.movie"
    public static let quickTimeMovie = "com.apple.quicktime-movie"
    public static let pdf = "com.adobe.pdf"
    public static let rtf = "public.rtf"
}

/// 优先级 P0～P3 解析结果。所有字段均为值类型，可安全跨 Actor 传递。
public struct ResolvedDragContent: Sendable, Equatable {
    public var contentType: ContentType
    /// P0：本地文件 / 离线文档。
    public var fileURLs: [URL]
    /// P1：直接从粘贴板内存读取的位图字节流（绝不通过 URL 二次下载）。
    public var imageData: Data?
    /// P1：位图的原始 UTI（`public.png` / `public.jpeg` / `public.tiff`）。
    public var imageTypeIdentifier: String?
    /// P2：网页超链接目标。
    public var pageURL: URL?
    /// 拖拽内容自带的标题（浏览器标签标题 / 链接文字）。
    public var linkTitle: String?
    /// P3：纯文本正文。
    public var text: String?
    /// P3：富文本 HTML 片段。
    public var html: String?
    /// 命中的粘贴板类型，便于诊断。
    public var matchedTypeIdentifiers: [String]

    public init(
        contentType: ContentType,
        fileURLs: [URL] = [],
        imageData: Data? = nil,
        imageTypeIdentifier: String? = nil,
        pageURL: URL? = nil,
        linkTitle: String? = nil,
        text: String? = nil,
        html: String? = nil,
        matchedTypeIdentifiers: [String] = []
    ) {
        self.contentType = contentType
        self.fileURLs = fileURLs
        self.imageData = imageData
        self.imageTypeIdentifier = imageTypeIdentifier
        self.pageURL = pageURL
        self.linkTitle = linkTitle
        self.text = text
        self.html = html
        self.matchedTypeIdentifiers = matchedTypeIdentifiers
    }
}
