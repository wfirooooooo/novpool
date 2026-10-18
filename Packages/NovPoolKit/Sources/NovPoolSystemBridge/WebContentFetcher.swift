import Foundation
import NovPoolCore

/// Capture result. The reason for failure is kept in the enumeration to facilitate diagnosing 'why this item did not extract the Body'.
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

/// WebBody capture + extraction.
///
/// Full-process best-effort: If any step fails, only return the result enumeration, do not throw, do not block the main drag-and-drop flow.
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

/// Web character set determination: BOM → Content-Type → `<meta charset>` → UTF-8 → Latin-1.
///
/// Chinese sites largely use GBK / GB18030. If this step is not done, you will get a screen full of garbled text, and Body extraction and all retrieval will fail.
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
        // Final fallback: Latin-1 will not fail on any byte string, at least ensuring that subsequent steps do not crash.
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

    /// Previously, sniff `<meta charset="...">` / `<meta http-equiv=... content="text/html; charset=...">` within a certain number of bytes.
    public static func charsetName(inMetaTagOf data: Data) -> String? {
        let prefix = data.prefix(sniffBytes)
        guard let head = String(data: prefix, encoding: .isoLatin1) else { return nil }
        let lowered = head.lowercased()

        if let range = lowered.range(of: "charset=") {
            var tail = lowered[range.upperBound...]
            // In reality, it is almost always <meta charset="gbk"> (with quotes); if the quotes are not removed, an empty value will be obtained.
            // Then reverting to Latin-1, the entire page of Chinese became garbled.
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

    /// IANA character set name → Swift encoding (overrides utf-8 / gbk / gb18030 / big5 / shift_jis / euc-kr, etc.).
    static func encoding(named name: String) -> String.Encoding? {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
        return String.Encoding(rawValue: nsEncoding)
    }
}
