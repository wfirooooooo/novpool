import Foundation
import NovPoolCore
import NovPoolStorage

/// 检索详情区应渲染的富预览形态。
public enum SearchPreviewKind: String, Sendable, Equatable {
    /// 本机图片：直接解码显示。
    case image
    /// PDF：面板内 PDFKit 翻页预览。
    case pdf
    /// 视频：截取海报帧。
    case video
    /// 其他本机文件：Quick Look 缩略图。
    case fileThumbnail
    /// 无可视化媒体（纯文本 / 网页等）。
    case none

    /// 按内容类型与本地文件扩展名决定预览形态；无本地文件时一律 `none`。
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
        case .genericFile, .plainText, .richHTML, .webLink:
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
