import Foundation
import NovPoolCore

/// 多源 UTI 拖拽解析器：按 P0 → P3 严格优先级把粘贴板归一化为 `ResolvedDragContent`。
///
/// 优先级依据产品白皮书 §3.2：
/// P0 本地文件 → P1 内存位图 → P2 网页链接 → P3 富文本 / 纯文本。
public struct PasteboardResolver: Sendable {
    /// 超过该长度即认为 `.string` 是正文而非链接文字，此时 HTML 按正文片段处理（P3）。
    public static let articleTextThreshold = 120

    public init() {}

    public func resolve(from pasteboard: PasteboardReading) -> ResolvedDragContent? {
        let types = Set(pasteboard.availableTypeIdentifiers)

        if let files = fileURLs(in: pasteboard), !files.isEmpty {
            // 按第一个文件的扩展名判定资源类型；图片/视频文件同样走文件暂存，
            // 只是后续的 OCR、云端命名与图标会据此区分。
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

        let url = linkURL(in: pasteboard)
        let linkTitle = title(in: pasteboard)
        let html = pasteboard.string(forTypeIdentifier: PasteboardTypeID.html)
        let text = pasteboard.string(forTypeIdentifier: PasteboardTypeID.plainText)
            ?? pasteboard.string(forTypeIdentifier: PasteboardTypeID.rtf).map(Self.stripRTF)

        var matched: [String] = []
        if url != nil { matched.append(PasteboardTypeID.url) }
        if html != nil { matched.append(PasteboardTypeID.html) }
        if text != nil { matched.append(PasteboardTypeID.plainText) }

        // P3 优先于 P2 的唯一情形：粘贴板里带着成段的正文（而非单个链接标签）。
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

    // MARK: - 各优先级提取

    private func fileURLs(in pasteboard: PasteboardReading) -> [URL]? {
        guard pasteboard.availableTypeIdentifiers.contains(PasteboardTypeID.fileURL) else { return nil }
        // 多文件可能是：多个 pasteboard item，或单个表示层里换行分隔的 URL 列表。
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
            // 关键：直接读取内存位图字节流。绝不只保存图片 URL 后二次请求，
            // 以规避防盗链、Referer 校验与登录态丢失。
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
        // Chrome / Edge / Firefox 拖标签时带 URL 列表
        if let raw = pasteboard.string(forTypeIdentifier: PasteboardTypeID.uriList),
           let url = Self.firstURL(inURIList: raw) {
            return url
        }
        // Firefox / Zen：UTF-16LE 的「URL\n标题」
        if let moz = mozURLPayload(in: pasteboard), let url = URLNormalization.httpURL(from: moz.url) {
            return url
        }
        // 部分浏览器只提供纯文本形式的链接。
        if let text = pasteboard.string(forTypeIdentifier: PasteboardTypeID.plainText),
           let url = URLNormalization.httpURL(from: text) {
            return url
        }
        return nil
    }

    /// 拖拽自带的标题：Safari 的 `public.url-name`，或 Firefox 的 moz-url 第二行。
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

    /// 解析 `text/x-moz-url`（URL 与标题以换行分隔，UTF-16LE 编码）。
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

    /// `text/uri-list` 取第一条非注释行（RFC 2483：以 # 开头的是注释）。
    static func firstURL(inURIList raw: String) -> URL? {
        for line in raw.split(whereSeparator: \.isNewline) {
            let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty, !candidate.hasPrefix("#") else { continue }
            if let url = URLNormalization.httpURL(from: candidate) { return url }
        }
        return nil
    }

    /// moz-url 通常是 UTF-16LE（可能带 BOM），个别版本是 UTF-8。
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

    /// RTF 兜底：剥掉控制字与分组括号，保留可读文本。
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
