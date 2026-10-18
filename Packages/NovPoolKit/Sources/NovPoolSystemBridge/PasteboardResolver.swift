import Foundation
import NovPoolCore

/// Multi-source UTI drag resolver: normalize the pasteboard to `ResolvedDragContent` with strict P0→P3 priority.
///
/// Priority follows product whitepaper §3.2:
/// P0 local files → P1 in-memory bitmaps → P2 web links → P3 rich text / plain text.
public struct PasteboardResolver: Sendable {
    /// Beyond this length, `.string` is body text not link text; HTML is treated as a body fragment (P3).
    public static let articleTextThreshold = 120

    public init() {}

    public func resolve(
        from pasteboard: PasteboardReading,
        preferWebLinksOverFiles: Bool = false
    ) -> ResolvedDragContent? {
        let types = Set(pasteboard.availableTypeIdentifiers)

        // During global fallback of a browser-tab drag, the drag pasteboard often still holds the last Finder file.
        // If this drag also has a link/body, prefer the link so a tab drag does not archive the old document.
        if preferWebLinksOverFiles, let web = resolveWebOrText(from: pasteboard, types: types) {
            return web
        }

        if let files = fileURLs(in: pasteboard), !files.isEmpty {
            // Classify by the first file's extension; image/video files still go through file staging,
            // with OCR, cloud naming, and icons branching afterward.
            let kind = FileKind.of(url: files[0])
            return ResolvedDragContent(
                contentType: kind.contentType,
                fileURLs: files,
                matchedTypeIdentifiers: [PasteboardTypeID.fileURL]
            )
        }

        if let image = imagePayload(in: pasteboard, types: types) {
            return image
        }

        return resolveWebOrText(from: pasteboard, types: types)
    }

    /// Link / HTML / plain-text branch (excludes files and in-memory bitmaps).
    private func resolveWebOrText(
        from pasteboard: PasteboardReading,
        types: Set<String>
    ) -> ResolvedDragContent? {
        let url = linkURL(in: pasteboard)
        let linkTitle = title(in: pasteboard)
        let html = pasteboard.string(forTypeIdentifier: PasteboardTypeID.html)
        let text = pasteboard.string(forTypeIdentifier: PasteboardTypeID.plainText)
            ?? pasteboard.string(forTypeIdentifier: PasteboardTypeID.rtf).map(Self.stripRTF)

        var matched: [String] = []
        if url != nil { matched.append(PasteboardTypeID.url) }
        if html != nil { matched.append(PasteboardTypeID.html) }
        if text != nil { matched.append(PasteboardTypeID.plainText) }

        // Only case where P3 beats P2: the pasteboard holds a body paragraph, not a single link label.
        if let html, (text?.count ?? 0) >= Self.articleTextThreshold {
            return ResolvedDragContent(
                contentType: .richHTML,
                pageURL: url,
                text: text,
                html: html,
                matchedTypeIdentifiers: matched
            )
        }
        if let url {
            return ResolvedDragContent(
                contentType: .webLink,
                pageURL: url,
                linkTitle: linkTitle,
                text: text,
                html: html,
                matchedTypeIdentifiers: matched
            )
        }
        if let html {
            return ResolvedDragContent(
                contentType: .richHTML,
                text: text,
                html: html,
                matchedTypeIdentifiers: matched
            )
        }
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ResolvedDragContent(
                contentType: .plainText,
                text: text,
                matchedTypeIdentifiers: matched
            )
        }
        return nil
    }

    // MARK: - Per-priority extraction

    private func fileURLs(in pasteboard: PasteboardReading) -> [URL]? {
        guard pasteboard.availableTypeIdentifiers.contains(PasteboardTypeID.fileURL) else { return nil }
        // Multiple files may be multiple pasteboard items, or one representation with newline-separated URLs.
        var chunks = pasteboard.allStrings(forTypeIdentifier: PasteboardTypeID.fileURL)
        if chunks.isEmpty,
           let raw = pasteboard.data(forTypeIdentifier: PasteboardTypeID.fileURL)
            .map({ String(decoding: $0, as: UTF8.self) }) {
            chunks = [raw]
        }
        let urls = chunks
            .flatMap { $0.split(separator: "\n", omittingEmptySubsequences: true) }
            .compactMap { URL(string: String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter(\.isFileURL)
        return urls.isEmpty ? nil : urls
    }

    private func imagePayload(in pasteboard: PasteboardReading, types: Set<String>) -> ResolvedDragContent? {
        for (typeIdentifier, _) in ImageTypeMapping.preferences where types.contains(typeIdentifier) {
            // Critical: read in-memory bitmap bytes. Never save only an image URL and re-fetch,
            // to avoid hotlink protection, Referer checks, and lost login state.
            if let data = pasteboard.data(forTypeIdentifier: typeIdentifier), !data.isEmpty {
                let isMovie = typeIdentifier.contains("movie") || typeIdentifier.contains("mpeg-4")
                return ResolvedDragContent(
                    contentType: isMovie ? .video : .image,
                    imageData: data,
                    imageTypeIdentifier: typeIdentifier,
                    pageURL: linkURL(in: pasteboard),
                    matchedTypeIdentifiers: [typeIdentifier]
                )
            }
        }
        return nil
    }

    private func linkURL(in pasteboard: PasteboardReading) -> URL? {
        if let raw = pasteboard.string(forTypeIdentifier: PasteboardTypeID.url),
           let url = URLNormalization.httpURL(from: raw) {
            return url
        }
        // Chrome / Edge / Firefox tab drags include a URL list
        if let raw = pasteboard.string(forTypeIdentifier: PasteboardTypeID.uriList),
           let url = Self.firstURL(inURIList: raw) {
            return url
        }
        // Firefox / Zen: UTF-16LE `URL\nTitle`
        if let moz = mozURLPayload(in: pasteboard), let url = URLNormalization.httpURL(from: moz.url) {
            return url
        }
        // Some browsers only provide the link as plain text.
        if let text = pasteboard.string(forTypeIdentifier: PasteboardTypeID.plainText),
           let url = URLNormalization.httpURL(from: text) {
            return url
        }
        return nil
    }

    /// Drag-provided title: Safari `public.url-name`, or the second line of Firefox moz-url.
    private func title(in pasteboard: PasteboardReading) -> String? {
        if let raw = pasteboard.string(forTypeIdentifier: PasteboardTypeID.urlName) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let moz = mozURLPayload(in: pasteboard), let title = moz.title {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// Parse `text/x-moz-url` (URL and title separated by newline, UTF-16LE).
    func mozURLPayload(in pasteboard: PasteboardReading) -> (url: String, title: String?)? {
        guard let data = pasteboard.data(forTypeIdentifier: PasteboardTypeID.mozURL)
            ?? pasteboard.data(forTypeIdentifier: PasteboardTypeID.mozURLData),
            !data.isEmpty else {
            return nil
        }
        guard let text = Self.decodeMozURL(data) else { return nil }
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let first = lines.first, !first.isEmpty else { return nil }
        let title = lines.dropFirst().first { !$0.isEmpty }
        return (first, title)
    }

    /// `text/uri-list`: first non-comment line (RFC 2483: lines starting with # are comments).
    static func firstURL(inURIList raw: String) -> URL? {
        for line in raw.split(whereSeparator: \.isNewline) {
            let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty, !candidate.hasPrefix("#") else { continue }
            if let url = URLNormalization.httpURL(from: candidate) { return url }
        }
        return nil
    }

    /// moz-url is usually UTF-16LE (optional BOM); some builds use UTF-8.
    static func decodeMozURL(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) {
            return String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        }
        if let utf16 = String(data: data, encoding: .utf16LittleEndian), utf16.contains("://") {
            return utf16
        }
        return String(data: data, encoding: .utf8)
    }

    /// RTF fallback: strip control words and group braces; keep readable text.
    static func stripRTF(_ raw: String) -> String {
        var output = ""
        var isSkipping = false
        var index = raw.startIndex
        while index < raw.endIndex {
            let character = raw[index]
            switch character {
            case "\\":
                isSkipping = true
            case "{", "}":
                isSkipping = false
            case " " where isSkipping:
                isSkipping = false
            default:
                if !isSkipping { output.append(character) }
            }
            index = raw.index(after: index)
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
