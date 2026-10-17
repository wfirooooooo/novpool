import Foundation
import NovPoolCore

/// 抓取结果。失败原因保留在枚举里，便于诊断「为什么这条没提取到正文」。
public enum WebFetchResult: Sendable, Equatable {
    case extracted(ArticleExtraction)
    case notHTML(contentType: String?)
    case tooLarge(bytes: Int)
    case httpError(status: Int)
    case undecodable
    case unparseable
    case transportError(String)

    public var article: ArticleExtraction? {
        if case .extracted(let article) = self { return article }
        return nil
    }
}

/// 网页正文抓取 + 提取。
///
/// 全程 best-effort：任何一步失败都只返回结果枚举，不抛出、不阻塞拖拽主流程。
public struct WebContentFetcher: Sendable {
    public struct Configuration: Sendable {
        public var timeout: TimeInterval
        public var maxBytes: Int
        public var userAgent: String
        public var acceptLanguage: String

        public init(
            timeout: TimeInterval = 8,
            maxBytes: Int = 3_000_000,
            userAgent: String = "Mozilla/5.0 (Macintosh; Apple Silicon) NovPool/0.2 (+local knowledge capture)",
            acceptLanguage: String = "zh-CN,zh;q=0.9,en;q=0.8"
        ) {
            self.timeout = timeout
            self.maxBytes = maxBytes
            self.userAgent = userAgent
            self.acceptLanguage = acceptLanguage
        }
    }

    private let transport: any HTTPTransport
    private let extractor: any ArticleExtracting
    private let configuration: Configuration

    public init(
        transport: any HTTPTransport = URLSessionTransport(),
        extractor: any ArticleExtracting = HTMLExtractor(),
        configuration: Configuration = Configuration()
    ) {
        self.transport = transport
        self.extractor = extractor
        self.configuration = configuration
    }

    public func fetchArticle(from url: URL) async -> WebFetchResult {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .notHTML(contentType: url.scheme)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = configuration.timeout
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(configuration.acceptLanguage, forHTTPHeaderField: "Accept-Language")
        request.setValue("text/html,application/xhtml+xml;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")

        let payload: HTTPPayload
        do {
            payload = try await transport.get(request)
        } catch {
            return .transportError(error.localizedDescription)
        }

        guard (200..<300).contains(payload.statusCode) else {
            return .httpError(status: payload.statusCode)
        }
        if let contentType = payload.contentType, !Self.isHTMLContentType(contentType) {
            return .notHTML(contentType: contentType)
        }
        guard payload.body.count <= configuration.maxBytes else {
            return .tooLarge(bytes: payload.body.count)
        }
        guard let html = HTMLCharset.decode(payload.body, contentType: payload.contentType) else {
            return .undecodable
        }

        let baseURL = payload.finalURL ?? url
        guard let article = extractor.extract(html: html, baseURL: baseURL) else {
            return .unparseable
        }
        return .extracted(article)
    }

    static func isHTMLContentType(_ raw: String) -> Bool {
        let lowered = raw.lowercased()
        return lowered.contains("text/html")
            || lowered.contains("application/xhtml")
            || lowered.contains("text/plain")
    }
}

/// 网页字符集判定：BOM → Content-Type → `<meta charset>` → UTF-8 → Latin-1。
///
/// 中文站点大量使用 GBK / GB18030，不做这一步会得到满屏乱码，正文提取与检索全部失效。
public enum HTMLCharset {
    public static let sniffBytes = 4096

    public static func decode(_ data: Data, contentType: String? = nil) -> String? {
        if let encoding = encodingFromBOM(data), let text = String(data: data, encoding: encoding) {
            return text
        }
        if let name = charsetName(inContentType: contentType) ?? charsetName(inMetaTagOf: data),
           let encoding = encoding(named: name),
           let text = String(data: data, encoding: encoding) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        // 最后兜底：Latin-1 对任意字节串都不会失败，至少保证后续步骤不崩溃。
        return String(data: data, encoding: .isoLatin1)
    }

    public static func charsetName(inContentType contentType: String?) -> String? {
        guard let contentType else { return nil }
        for component in contentType.split(separator: ";") {
            let trimmed = component.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("charset=") else { continue }
            let value = trimmed.dropFirst("charset=".count)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            return value.isEmpty ? nil : String(value)
        }
        return nil
    }

    /// 从前若干字节里嗅探 `<meta charset="...">` / `<meta http-equiv=... content="text/html; charset=...">`。
    public static func charsetName(inMetaTagOf data: Data) -> String? {
        let prefix = data.prefix(sniffBytes)
        guard let head = String(data: prefix, encoding: .isoLatin1) else { return nil }
        let lowered = head.lowercased()

        if let range = lowered.range(of: "charset=") {
            var tail = lowered[range.upperBound...]
            // 现实中几乎都是 <meta charset="gbk">（带引号）；不剥掉引号会得到空值，
            // 进而退回 Latin-1，整页中文变成乱码。
            if let first = tail.first, first == "\"" || first == "'" {
                tail = tail.dropFirst()
            }
            let value = tail.prefix { character in
                character.isLetter || character.isNumber || character == "-" || character == "_"
            }
            if !value.isEmpty { return String(value) }
        }
        return nil
    }

    static func encodingFromBOM(_ data: Data) -> String.Encoding? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return .utf8 }
        if data.starts(with: [0xFF, 0xFE]) { return .utf16LittleEndian }
        if data.starts(with: [0xFE, 0xFF]) { return .utf16BigEndian }
        return nil
    }

    /// IANA 字符集名 → Swift 编码（覆盖 utf-8 / gbk / gb18030 / big5 / shift_jis / euc-kr 等）。
    static func encoding(named name: String) -> String.Encoding? {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
        return String.Encoding(rawValue: nsEncoding)
    }
}
