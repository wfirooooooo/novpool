import Foundation
import Testing
@testable import NovPoolCore
@testable import NovPoolSystemBridge

@Suite("网页抓取与字符集处理")
struct WebFetchTests {
    private let url = URL(string: "https://blog.example.com/post")!

    private func articleHTML(body: String = String(repeating: "这是一段足够长的正文内容。", count: 12)) -> String {
        """
        <html><head><title>测试文章</title></head>
        <body><article><h1>测试文章</h1><p>\(body)</p>
        <p><a href="/next">下一篇</a></p></article></body></html>
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

    @Test("抓取成功：提取标题与 Markdown 正文，相对链接按重定向后的 URL 解析")
    func successfulFetch() async throws {
        let transport = StubTransport(responses: [
            payload(html: articleHTML(), finalURL: URL(string: "https://blog.example.com/redirected/post")!),
        ])
        let fetcher = WebContentFetcher(transport: transport)

        let result = await fetcher.fetchArticle(from: url)
        let article = try #require(result.article)
        #expect(article.title == "测试文章")
        #expect(article.markdown.contains("[下一篇](https://blog.example.com/next)"))

        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("NovPool") == true)
        #expect(request.value(forHTTPHeaderField: "Accept-Language")?.contains("zh") == true)
    }

    @Test("非 HTML 响应直接跳过，不浪费解析")
    func nonHTMLResponse() async {
        let transport = StubTransport(responses: [
            HTTPPayload(statusCode: 200, headers: ["Content-Type": "image/png"], body: Data([0x89, 0x50])),
        ])
        let result = await WebContentFetcher(transport: transport).fetchArticle(from: url)
        #expect(result == .notHTML(contentType: "image/png"))
    }

    @Test("HTTP 错误与网络失败分别归类，不抛异常")
    func errorMapping() async {
        let notFound = StubTransport(responses: [payload(html: "<html></html>", statusCode: 404)])
        #expect(await WebContentFetcher(transport: notFound).fetchArticle(from: url) == .httpError(status: 404))

        let offline = StubTransport()
        if case .transportError = await WebContentFetcher(transport: offline).fetchArticle(from: url) {
            // 预期分支
        } else {
            Issue.record("离线传输应归类为 transportError")
        }
    }

    @Test("超过体积上限的页面跳过提取")
    func sizeLimit() async {
        let big = String(repeating: "x", count: 5_000)
        let transport = StubTransport(responses: [payload(html: big)])
        let fetcher = WebContentFetcher(
            transport: transport,
            configuration: .init(maxBytes: 1_000)
        )
        #expect(await fetcher.fetchArticle(from: url) == .tooLarge(bytes: 5_000))
    }

    @Test("非 http(s) 链接不抓取")
    func nonHTTPScheme() async {
        let transport = StubTransport(responses: [payload(html: articleHTML())])
        let fetcher = WebContentFetcher(transport: transport)
        let result = await fetcher.fetchArticle(from: URL(string: "mailto:a@b.com")!)
        #expect(result == .notHTML(contentType: "mailto"))
        #expect(transport.requests.isEmpty)
    }

    @Test("无法提取正文的页面归类为 unparseable")
    func unparseable() async {
        let transport = StubTransport(responses: [payload(html: "<html><body><p>短</p></body></html>")])
        #expect(await WebContentFetcher(transport: transport).fetchArticle(from: url) == .unparseable)
    }

    // MARK: - 字符集

    @Test("Content-Type 中的 charset 生效")
    func charsetFromContentType() {
        let text = "中文内容"
        let encoding = HTMLCharset.encoding(named: "gb18030")!
        let data = text.data(using: encoding)!
        let decoded = HTMLCharset.decode(data, contentType: "text/html; charset=gb18030")
        #expect(decoded?.contains("中文内容") == true)
        #expect(HTMLCharset.charsetName(inContentType: "text/html; charset=\"UTF-8\"") == "UTF-8")
        #expect(HTMLCharset.charsetName(inContentType: "text/html") == nil)
    }

    @Test("BOM 优先于声明的字符集")
    func bomWins() {
        let text = "带 BOM 的文本"
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(text.data(using: .utf8)!)
        #expect(HTMLCharset.decode(data, contentType: "text/html; charset=gb18030")?.contains("带 BOM 的文本") == true)
    }

    @Test("无声明 charset 时从 meta 标签嗅探（GBK 站点）")
    func metaCharsetSniffing() throws {
        let html = "<html><head><meta charset=\"gbk\"><title>中文站点</title></head><body>正文</body></html>"
        let data = try #require(html.data(using: HTMLCharset.encoding(named: "gbk")!))
        let decoded = try #require(HTMLCharset.decode(data, contentType: "text/html"))
        #expect(decoded.contains("中文站点"))
        #expect(decoded.contains("正文"))
    }

    @Test("无任何线索时 UTF-8 兜底，非法字节不崩溃")
    func fallbackDecoding() {
        let plain = Data("纯英文".utf8)
        #expect(HTMLCharset.decode(plain)?.contains("纯英文") == true)
        // 非法 UTF-8 字节序列：最终由 Latin-1 兜底，保证不返回 nil、不抛错。
        #expect(HTMLCharset.decode(Data([0x80, 0x81, 0xFF])) != nil)
    }
}
