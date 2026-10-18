import Foundation

/// Extraction of readable content from this machine's files.
///
/// Text type Files go directly into the database, HTML uses the existing Body extractor; binary Files whose Text cannot be extracted
/// At least generate File information to ensure that the detailed page will not show a blank Body.
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

            // Short pages or natively HTML with loose structure may not reach Readability's Body threshold.
            // At this time, directly render the Body node, rather than letting the item degrade to 'no Body'.
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

    /// Binary files or files with empty content also need to be readable in preview.
    static func summary(for url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let sizeText = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        let ext = url.pathExtension.uppercased()
        let type = ext.isEmpty ? "File" : "\(ext) file"
        return """
        ## File info

        - Name: \(url.lastPathComponent)
        - Type: \(type)
        - Size: \(sizeText)

        The original file is saved in the NovPool staging directory. Use Open to view it.
        """
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > maximumCharacters else { return trimmed }
        return String(trimmed.prefix(maximumCharacters)) + "\n\n… (truncated; content too long)"
    }
}
