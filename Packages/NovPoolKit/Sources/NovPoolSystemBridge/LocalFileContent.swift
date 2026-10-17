import Foundation

/// 本机文件的可读内容提取。
///
/// 文本类文件直接入库，HTML 走现有的正文提取器；无法提取文本的二进制文件
/// 至少生成文件信息，保证检索详情页不会出现空白正文。
enum LocalFileContent {
    struct ExtractedText {
        let markdown: String
        let title: String?
    }

    static let maximumCharacters = 200_000
    static let maximumReadBytes = 20 * 1024 * 1024

    private static let htmlExtensions: Set<String> = ["html", "htm", "xhtml"]
    private static let textExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "csv", "tsv", "json", "xml",
        "yaml", "yml", "log", "rtf",
        "swift", "js", "jsx", "ts", "tsx", "css", "py", "rb", "go", "rs",
        "java", "c", "cc", "cpp", "h", "hpp", "sh", "zsh", "sql",
    ]

    static func extract(from url: URL) -> ExtractedText? {
        let ext = url.pathExtension.lowercased()
        if ext == "docx", let text = DOCXTextExtractor.extract(from: url) {
            return ExtractedText(markdown: text, title: nil)
        }
        guard htmlExtensions.contains(ext) || textExtensions.contains(ext) else { return nil }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maximumReadBytes,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let raw = HTMLCharset.decode(data) else {
            return nil
        }

        if htmlExtensions.contains(ext) {
            let extractor = HTMLExtractor()
            if let article = extractor.extract(html: raw, baseURL: url),
               let markdown = nonEmpty(article.markdown) {
                return ExtractedText(markdown: markdown, title: article.title)
            }

            // 短页面或结构松散的本机 HTML 可能达不到 Readability 的正文阈值，
            // 此时直接渲染正文节点，而不是让条目退化成“没有正文”。
            let document = HTMLParser().parse(raw)
            let body = MarkdownRenderer.firstDescendant(in: document, named: "body") ?? document
            let markdown = MarkdownRenderer(baseURL: url).render(element: body)
            if let markdown = nonEmpty(markdown) {
                return ExtractedText(markdown: markdown, title: nil)
            }
            if let text = nonEmpty(HTMLText.collapseWhitespace(body.textContent)) {
                return ExtractedText(markdown: text, title: nil)
            }
            return nil
        }

        let text = ext == "rtf" ? PasteboardResolver.stripRTF(raw) : raw
        guard let text = nonEmpty(text) else { return nil }
        return ExtractedText(markdown: text, title: nil)
    }

    /// 二进制文件或内容为空的文件也需要可读预览。
    static func summary(for url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let sizeText = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        let ext = url.pathExtension.uppercased()
        let type = ext.isEmpty ? "文件" : "\(ext) 文件"
        return """
        ## 文件信息

        - 文件名：\(url.lastPathComponent)
        - 类型：\(type)
        - 大小：\(sizeText)

        原始文件已保存在 NovPool 暂存目录，可点击「打开」查看。
        """
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > maximumCharacters else { return trimmed }
        return String(trimmed.prefix(maximumCharacters)) + "\n\n…（内容过长，已截断）"
    }
}
