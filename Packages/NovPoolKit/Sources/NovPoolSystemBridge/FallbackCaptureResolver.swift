import Foundation
import NovPoolCore

/// 全局拖拽兜底的内容解析顺序。
///
/// 优先读真实拖拽粘贴板，避免把「当前选中文字」或「旧粘贴板」误当成本次拖拽载荷。
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
    }

    public struct Decision: Sendable, Equatable {
        public var content: ResolvedDragContent
        public var source: String

        public init(content: ResolvedDragContent, source: String) {
            self.content = content
            self.source = source
        }
    }

    /// 解析顺序：拖拽粘贴板 → 通用粘贴板 → 浏览器活跃标签 → 选中文字。
    public static func resolve(
        dragPasteboard: (any PasteboardReading)?,
        generalPasteboard: (any PasteboardReading)?,
        browser: BrowserFallback,
        selectedText: String?,
        resolver: PasteboardResolver = PasteboardResolver()
    ) -> Decision? {
        if let dragPasteboard, let content = resolver.resolve(from: dragPasteboard) {
            return Decision(content: content, source: "拖拽粘贴板")
        }
        if let generalPasteboard, let content = resolver.resolve(from: generalPasteboard) {
            return Decision(content: content, source: "通用粘贴板")
        }
        if let url = browser.pageURL {
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
            return Decision(
                content: ResolvedDragContent(
                    contentType: .webLink,
                    pageURL: url,
                    linkTitle: browser.pageTitle
                ),
                source: "浏览器标签"
            )
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
}
