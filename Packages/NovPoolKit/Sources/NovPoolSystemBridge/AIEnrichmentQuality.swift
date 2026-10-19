import Foundation

/// Product guards shared by ingest, single-item re-summarize, and fill-missing.
///
/// Category is a topic. A file-type name is never stored. Tags are capped, de-duplicated,
/// and stripped of symbol-only noise. Callers that have no body must not reach the model.
public enum AIEnrichmentQuality {
    /// Fallback topic when the model answers with a file type but the summary or tags are usable.
    public static let uncategorized = "Uncategorized"
    public static let noBodyReason = "No body text available for summarizing"
    public static let fileTypeCategoryReason = "Model returned a file-type category and no usable summary"

    /// Last-line guard for any `AIEnriching` result, including ones that skipped JSON parsing.
    public static func sanitize(_ enrichment: AIEnrichment, maxTags: Int = 5) -> AIEnrichment {
        var copy = enrichment
        copy.tags = AIEnrichmentParser.normalizeTagList(copy.tags, maxTags: maxTags)
        if let category = copy.category, isFormatLikeCategory(category) {
            copy.category = (copy.summary != nil || !copy.tags.isEmpty) ? uncategorized : nil
        }
        return copy
    }

    public static func isMeaningfulTag(_ tag: String) -> Bool {
        tag.contains { $0.isLetter || $0.isNumber }
    }

    /// File-type names and short "pdf file" phrases. Not a topic.
    public static func isFormatLikeCategory(_ raw: String) -> Bool {
        let normalized = normalize(raw)
        if normalized.isEmpty { return true }
        if rejectedFormatCategories.contains(normalized) { return true }
        for suffix in ["file", "document", "attachment"] where normalized.hasSuffix(suffix) {
            let stem = String(normalized.dropLast(suffix.count))
            if rejectedFormatCategories.contains(stem) { return true }
        }
        return false
    }

    private static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    /// Resource-kind words and common extensions. Compared after letters/digits are kept and lowercased.
    private static let rejectedFormatCategories: Set<String> = [
        "web", "image", "video", "file", "document", "link", "text", "plaintext", "attachment",
        "weblink", "richhtml", "richtext", "genericfile", "documentpdf",
        "pdf", "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp", "svg",
        "mp4", "mov", "m4v", "avi", "mkv", "webm", "mp3", "wav", "aac",
        "doc", "docx", "ppt", "pptx", "xls", "xlsx", "txt", "html", "htm", "md", "markdown",
        "audio", "photo", "screenshot", "archive", "zip",
        "图片", "网页", "视频", "文件", "文档", "链接", "文本", "附件", "截图", "照片",
    ]
}
