import Foundation
import Testing
@testable import NovPoolCore
@testable import NovPoolSystemBridge

@Suite("Web Scraping and Character Set Handling")
struct WebFetchTests {
    private let url = URL(string: "https://blog.example.com/post")!

    private func articleHTML(body: String = String(repeating: "This is a body content that is long enough.", count: 12)) -> String {
        """
        <html><head><title>Test article</title></head>
        <body><article><h1>Test article</h1><p>\(body)</p>
        <p><a href="/next">Next article</a></p></article></body></html>
        """
    }

    private func payload(
        html: String,
        statusCode: Int = 200,
        contentType: String = "text/html; charset=utf-8",
        finalURL: URL? = nil
    ) -> HTTPPayload {
        HTTPPayload(
            statusCode: statusCode,
            headers: ["Content-Type": contentType],
            body: Data(html.utf8),
            finalURL: finalURL ?? url
        )
    }

    @Test("Capture successful: extract title and Markdown body, resolve relative links according to the redirected URL")
    func successfulFetch() async throws {
        let transport = StubTransport(responses: [
            payload(html: articleHTML(), finalURL: URL(string: "https://blog.example.com/redirected/post")!),
        ])
        let fetcher = WebContentFetcher(transport: transport)

        let result = await fetcher.fetchArticle(from: url)
        let article = try #require(result.article)
        #expect(article.title == "Test article")
        #expect(article.markdown.contains("[Next article](https://blog.example.com/next)"))

        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("NovPool") == true)
        #expect(request.value(forHTTPHeaderField: "Accept-Language")?.contains("zh") == true)
    }

    @Test("Non-HTML responses are skipped directly, no parsing wasted")
    func nonHTMLResponse() async {
        let transport = StubTransport(responses: [
            HTTPPayload(statusCode: 200, headers: ["Content-Type": "image/png"], body: Data([0x89, 0x50])),
        ])
        let result = await WebContentFetcher(transport: transport).fetchArticle(from: url)
        #expect(result == .notHTML(contentType: "image/png"))
    }

    @Test("HTTP Errors and network failures are categorized separately, without throwing exceptions")
    func errorMapping() async {
        let notFound = StubTransport(responses: [payload(html: "<html></html>", statusCode: 404)])
        #expect(await WebContentFetcher(transport: notFound).fetchArticle(from: url) == .httpError(status: 404))

        let offline = StubTransport()
        if case .transportError = await WebContentFetcher(transport: offline).fetchArticle(from: url) {
            // Expected branch
        } else {
            Issue.record("Offline transmission should be classified as transportError")
        }
    }

    @Test("Pages exceeding the volume limit are skipped for extraction")
    func sizeLimit() async {
        let big = String(repeating: "x", count: 5_000)
        let transport = StubTransport(responses: [payload(html: big)])
        let fetcher = WebContentFetcher(
            transport: transport,
            configuration: .init(maxBytes: 1_000)
        )
        #expect(await fetcher.fetchArticle(from: url) == .tooLarge(bytes: 5_000))
    }

    @Test("Non-http(s) links are not crawled")
    func nonHTTPScheme() async {
        let transport = StubTransport(responses: [payload(html: articleHTML())])
        let fetcher = WebContentFetcher(transport: transport)
        let result = await fetcher.fetchArticle(from: URL(string: "mailto:a@b.com")!)
        #expect(result == .notHTML(contentType: "mailto"))
        #expect(transport.requests.isEmpty)
    }

    @Test("Pages from which the Body cannot be extracted are classified as unparseable")
    func unparseable() async {
        let transport = StubTransport(responses: [payload(html: "<html><body><p>short</p></body></html>")])
        #expect(await WebContentFetcher(transport: transport).fetchArticle(from: url) == .unparseable)
    }

    // MARK: - Character set

    @Test("The charset in Content-Type takes effect")
    func charsetFromContentType() {
        let text = "Chinese content"
        let encoding = HTMLCharset.encoding(named: "gb18030")!
        let data = text.data(using: encoding)!
        let decoded = HTMLCharset.decode(data, contentType: "text/html; charset=gb18030")
        #expect(decoded?.contains("Chinese content") == true)
        #expect(HTMLCharset.charsetName(inContentType: "text/html; charset=\"UTF-8\"") == "UTF-8")
        #expect(HTMLCharset.charsetName(inContentType: "text/html") == nil)
    }

    @Test("BOM takes precedence over the declared character set")
    func bomWins() {
        let text = "Text with BOM"
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(text.data(using: .utf8)!)
        #expect(HTMLCharset.decode(data, contentType: "text/html; charset=gb18030")?.contains("Text with BOM") == true)
    }

    @Test("Sniff from meta tag when no charset is declared (GBK site)")
    func metaCharsetSniffing() throws {
        let html = "<html><head><meta charset=\"gbk\"><title>Chinese site</title></head><body>Body</body></html>"
        let data = try #require(html.data(using: HTMLCharset.encoding(named: "gbk")!))
        let decoded = try #require(HTMLCharset.decode(data, contentType: "text/html"))
        #expect(decoded.contains("Chinese site"))
        #expect(decoded.contains("Body"))
    }

    @Test("When there are no clues, fall back to UTF-8; illegal bytes do not crash")
    func fallbackDecoding() {
        let plain = Data("Pure English".utf8)
        #expect(HTMLCharset.decode(plain)?.contains("Pure English") == true)
        // Illegal UTF-8 byte sequence: ultimately fall back to Latin-1 to ensure nil is not returned and no error is thrown.
        #expect(HTMLCharset.decode(Data([0x80, 0x81, 0xFF])) != nil)
    }
}
