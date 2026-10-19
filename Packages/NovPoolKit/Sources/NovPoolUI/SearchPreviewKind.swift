import Foundation
import NovPoolCore
import NovPoolStorage

/// The rich PreviewKind that should be rendered in the search details area.
public enum SearchPreviewKind: String, Sendable, Equatable {
    /// Local Image: Decode and display directly.
    case image
    /// PDF: PDFKit page flip preview within the panel.
    case pdf
    /// Video: Capture poster frame.
    case video
    /// Other local machine File: Quick Look thumbnails.
    case fileThumbnail
    /// No visual media (Plain Text / Web, etc.).
    case none

    /// Determine PreviewKind based on content type and local file extension; if there is no local file, always `none`.
    public static func resolve(
        contentType: ContentType,
        localFileURL: URL?
    ) -> SearchPreviewKind {
        guard let localFileURL else { return .none }
        let kind = FileKind.of(pathExtension: localFileURL.pathExtension)
        switch contentType {
        case .image:
            return .image
        case .documentPDF:
            return .pdf
        case .video:
            return .video
        case .genericFile, .plainText, .richHTML, .webLink, .digest:
            switch kind {
            case .image: return .image
            case .pdf: return .pdf
            case .video: return .video
            case .other: return .fileThumbnail
            }
        }
    }

    public static func resolve(_ result: KnowledgeSearchResult) -> SearchPreviewKind {
        resolve(contentType: result.contentType, localFileURL: result.localFileURL)
    }

    public var showsMediaPane: Bool { self != .none }
}
