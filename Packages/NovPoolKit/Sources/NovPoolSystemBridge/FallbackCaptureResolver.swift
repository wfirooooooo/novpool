import Foundation
import NovPoolCore

/// 全局拖拽兜底的内容解析顺序。
///
/// 优先读真实拖拽粘贴板；但拖拽粘贴板会残留上一次 Finder 文件，
/// 拖网页标签时常被误当成「又拖了那份文档」。此时若能拿到浏览器活跃标签，改用标签。
public enum FallbackCaptureResolver: Sendable {
    public struct BrowserFallback: Sendable, Equatable {
        public var pageURL: URL?
        public var pageTitle: String?
        public var fileExistsAtPageURL: Bool

        public init(pageURL: URL?, pageTitle: String?, fileExistsAtPageURL: Bool = false) {
            self.pageURL = pageURL
            self.pageTitle = pageTitle
            self.fileExistsAtPageURL = fileExistsAtPageURL
        }

        /// 前台浏览器有可归档的 http(s) 标签。
        public var hasWebPage: Bool {
            guard let pageURL, let scheme = pageURL.scheme?.lowercased() else { return false }
            return scheme == "http" || scheme == "https"
        }
    }

    public struct Decision: Sendable, Equatable {
        public var content: ResolvedDragContent
        public var source: String

        public init(content: ResolvedDragContent, source: String) {
            self.content = content
            self.source = source
        }
    }

    /// 解析顺序：拖拽粘贴板（链接优先）→ 通用粘贴板 → 浏览器活跃标签 → 选中文字。
    /// 仅含文件、且浏览器有网页标签时，跳过粘贴板文件（视为上一次拖拽残留）。
    public static func resolve(
        dragPasteboard: (any PasteboardReading)?,
        generalPasteboard: (any PasteboardReading)?,
        browser: BrowserFallback,
        selectedText: String?,
        resolver: PasteboardResolver = PasteboardResolver(),
        fileExists: @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    ) -> Decision? {
        if let dragPasteboard,
           let content = resolver.resolve(from: dragPasteboard, preferWebLinksOverFiles: true),
           let decision = acceptPasteboardContent(
               content,
               source: "拖拽粘贴板",
               browser: browser,
               fileExists: fileExists
           ) {
            return decision
        }
        if let generalPasteboard,
           let content = resolver.resolve(from: generalPasteboard, preferWebLinksOverFiles: true),
           let decision = acceptPasteboardContent(
               content,
               source: "通用粘贴板",
               browser: browser,
               fileExists: fileExists
           ) {
            return decision
        }
        if let browserDecision = browserDecision(browser) {
            return browserDecision
        }
        if let selectedText {
            let trimmed = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return Decision(
                    content: ResolvedDragContent(contentType: .plainText, text: selectedText),
                    source: "选中文字"
                )
            }
        }
        return nil
    }

    /// 文件型载荷在「浏览器有网页标签」时视为陈旧残留，让位给标签。
    static func acceptPasteboardContent(
        _ content: ResolvedDragContent,
        source: String,
        browser: BrowserFallback,
        fileExists: @Sendable (URL) -> Bool
    ) -> Decision? {
        if isFileOnlyPayload(content) {
            if browser.hasWebPage {
                return nil
            }
            let existing = content.fileURLs.filter(fileExists)
            guard !existing.isEmpty else { return nil }
            var cleaned = content
            cleaned.fileURLs = existing
            return Decision(content: cleaned, source: source)
        }
        return Decision(content: content, source: source)
    }

    /// 只有本地文件、没有网页链接/正文时，判定为「文件型载荷」。
    public static func isFileOnlyPayload(_ content: ResolvedDragContent) -> Bool {
        guard !content.fileURLs.isEmpty else { return false }
        if content.pageURL != nil { return false }
        if let text = content.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        if let html = content.html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        switch content.contentType {
        case .image, .video, .documentPDF, .genericFile:
            return true
        case .webLink, .plainText, .richHTML:
            return false
        }
    }

    private static func browserDecision(_ browser: BrowserFallback) -> Decision? {
        guard let url = browser.pageURL else { return nil }
        if url.isFileURL, browser.fileExistsAtPageURL {
            return Decision(
                content: ResolvedDragContent(
                    contentType: FileKind.of(url: url).contentType,
                    fileURLs: [url],
                    linkTitle: browser.pageTitle
                ),
                source: "浏览器本地文件"
            )
        }
        guard browser.hasWebPage else { return nil }
        return Decision(
            content: ResolvedDragContent(
                contentType: .webLink,
                pageURL: url,
                linkTitle: browser.pageTitle
            ),
            source: "浏览器标签"
        )
    }
}
