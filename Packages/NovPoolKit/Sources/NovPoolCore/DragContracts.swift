import Foundation

/// Clipboard read abstraction.
///
/// Truly implement wrapping `NSPasteboard`; use in-memory substitutes for testing to avoid depending on WindowServer
/// With the `pboard` daemon (not available in CI/sandbox environments without a GUI session).
public protocol PasteboardReading: Sendable {
    /// All type identifiers currently present in the clipboard (such as `public.utf8-plain-text`).
    var availableTypeIdentifiers: [String] { get }
    func data(forTypeIdentifier typeIdentifier: String) -> Data?
    func string(forTypeIdentifier typeIdentifier: String) -> String?
    /// All strings of the same type on multiple pasteboard items.
    ///
    /// Finder often treats multiple file drag-and-drop as 'one item per file', in which case `string(forType:)` only returns the first item;
    /// The default implementation degenerates into a single-value array, while the real `NSPasteboardReader` enumerates all items.
    func allStrings(forTypeIdentifier typeIdentifier: String) -> [String]
}

extension PasteboardReading {
    public func allStrings(forTypeIdentifier typeIdentifier: String) -> [String] {
        string(forTypeIdentifier: typeIdentifier).map { [$0] } ?? []
    }
}

/// Clipboard type identifier constant (to avoid `NovPoolCore` depending on AppKit).
public enum PasteboardTypeID {
    public static let fileURL = "public.file-url"
    public static let url = "public.url"
    /// Safari uses `public.url-name` to carry Link/label titles.
    public static let urlName = "public.url-name"
    /// URL list (will be included when dragging tabs in Chrome/Edge/Firefox).
    public static let uriList = "text/uri-list"
    /// Firefox/Zen's tab drag format, content is UTF-16LE 'URL\nTitle'.
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

/// Analysis results for priority P0 to P3. All fields are value types and can be safely passed across Actors.
public struct ResolvedDragContent: Sendable, Equatable {
    public var contentType: ContentType
    /// P0: Local File / Offline Document.
    public var fileURLs: [URL]
    /// P1: Directly read the bitmap byte stream from clipboard memory (never download it again via URL).
    public var imageData: Data?
    /// P1: The original UTI of the bitmap (`public.png` / `public.jpeg` / `public.tiff`).
    public var imageTypeIdentifier: String?
    /// P2: Web hyperlink target.
    public var pageURL: URL?
    /// The dragged content comes with a title (Browser tab title / Link text).
    public var linkTitle: String?
    /// P3: plain text body.
    public var text: String?
    /// P3: Rich Text HTML snippet.
    public var html: String?
    /// The clipboard type in use, convenient for diagnostics.
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

    /// When dragging multiple files, split them into 'one file per item'; other types are returned as a single-element array as is.
    public func expandedForIngest() -> [ResolvedDragContent] {
        guard fileURLs.count > 1 else { return [self] }
        return fileURLs.map { url in
            ResolvedDragContent(
                contentType: FileKind.of(url: url).contentType,
                fileURLs: [url],
                matchedTypeIdentifiers: matchedTypeIdentifiers
            )
        }
    }
}
