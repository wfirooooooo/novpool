import Foundation
import NovPoolCore

/// Content resolution order for the global drag fallback.
///
/// Prefer the real drag pasteboard; it may still hold the previous Finder file,
/// so dragging a browser tab can look like that old document. Prefer the active browser tab when available.
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

        /// Frontmost browser has an archivable http(s) tab.
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

    /// Order: drag pasteboard (links first) → general pasteboard → active browser tab → selected text.
    /// When only files are present and the browser has a web tab, skip pasteboard files (stale drag residue).
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
               source: "Drag pasteboard",
               browser: browser,
               fileExists: fileExists
           ) {
            return decision
        }
        if let generalPasteboard,
           let content = resolver.resolve(from: generalPasteboard, preferWebLinksOverFiles: true),
           let decision = acceptPasteboardContent(
               content,
               source: "General pasteboard",
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
                    source: "Selected text"
                )
            }
        }
        return nil
    }

    /// File-only payloads yield to the browser tab when a web tab is present (treat as stale residue).
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

    /// File-only payload: local files with no web link or body text.
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
        case .webLink, .plainText, .richHTML, .digest:
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
                source: "Browser local file"
            )
        }
        guard browser.hasWebPage else { return nil }
        return Decision(
            content: ResolvedDragContent(
                contentType: .webLink,
                pageURL: url,
                linkTitle: browser.pageTitle
            ),
            source: "Browser tab"
        )
    }
}
