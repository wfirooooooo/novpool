import Foundation
import NovPoolCore
import Testing
@testable import NovPoolSystemBridge

@Suite("粘贴板 UTI 优先级解析")
struct PasteboardResolverTests {
    private let resolver = PasteboardResolver()

    @Test("P0：本地文件优先于同一粘贴板中的图片与文本")
    func fileURLWins() throws {
        let pasteboard = FakePasteboard(strings: [
            (PasteboardTypeID.fileURL, "file:///Users/wong/Desktop/report%20final.pdf"),
            (PasteboardTypeID.plainText, "一些正文"),
            (PasteboardTypeID.png, "fake-image"),
        ])
        let content = try #require(resolver.resolve(from: pasteboard))
        #expect(content.contentType == .documentPDF)
        #expect(content.fileURLs.count == 1)
        #expect(content.fileURLs[0].pathExtension == "pdf")
    }

    @Test("P0：多文件拖拽解析出全部路径，类型按首个文件判断")
    func multipleFiles() throws {
        let pasteboard = FakePasteboard(strings: [
            (PasteboardTypeID.fileURL, "file:///tmp/a.png\nfile:///tmp/b.txt"),
        ])
        let content = try #require(resolver.resolve(from: pasteboard))
        #expect(content.contentType == .image)
        #expect(content.fileURLs.map(\.lastPathComponent) == ["a.png", "b.txt"])
    }

    @Test("P1：网页图片走内存字节流，不依赖图片 URL 二次下载")
    func imageBytesWinOverLink() throws {
        let bytes = Data(repeating: 0x89, count: 64)
        let pasteboard = FakePasteboard([
            (PasteboardTypeID.png, bytes),
            (PasteboardTypeID.url, Data("https://example.com/pic.png".utf8)),
            (PasteboardTypeID.plainText, Data("https://example.com/pic.png".utf8)),
        ])
        let content = try #require(resolver.resolve(from: pasteboard))
        #expect(content.contentType == .image)
        #expect(content.imageData == bytes)
        #expect(content.imageTypeIdentifier == PasteboardTypeID.png)
        #expect(content.pageURL?.absoluteString == "https://example.com/pic.png")
    }

    @Test("P2：只有短链接文字时判定为网页链接")
    func shortLinkBecomesWebLink() throws {
        let pasteboard = FakePasteboard(strings: [
            (PasteboardTypeID.url, "https://example.com/post"),
            (PasteboardTypeID.plainText, "一篇好文"),
            (PasteboardTypeID.html, "<a href=\"https://example.com/post\">一篇好文</a>"),
        ])
        let content = try #require(resolver.resolve(from: pasteboard))
        #expect(content.contentType == .webLink)
        #expect(content.pageURL?.absoluteString == "https://example.com/post")
    }

    @Test("P3：成段正文携带 HTML 时判定为富文本")
    func longTextBecomesRichHTML() throws {
        let article = String(repeating: "这是一段足够长的正文内容，用于触发富文本判定。", count: 6)
        let pasteboard = FakePasteboard(strings: [
            (PasteboardTypeID.html, "<div><p>\(article)</p></div>"),
            (PasteboardTypeID.plainText, article),
        ])
        let content = try #require(resolver.resolve(from: pasteboard))
        #expect(content.contentType == .richHTML)
        #expect(content.text == article)
        #expect(content.html?.hasPrefix("<div>") == true)
    }

    @Test("P3：纯文本兜底")
    func plainTextFallback() throws {
        let pasteboard = FakePasteboard(strings: [(PasteboardTypeID.plainText, "随手记一句话")])
        let content = try #require(resolver.resolve(from: pasteboard))
        #expect(content.contentType == .plainText)
        #expect(content.text == "随手记一句话")
    }

    @Test("空粘贴板与纯空白文本返回 nil")
    func emptyPasteboard() {
        #expect(resolver.resolve(from: FakePasteboard()) == nil)
        #expect(resolver.resolve(from: FakePasteboard(strings: [(PasteboardTypeID.plainText, "   \n ") ])) == nil)
    }

    @Test("非 http(s) 的 URL 不当作网页链接")
    func nonHTTPURLIgnored() throws {
        let pasteboard = FakePasteboard(strings: [
            (PasteboardTypeID.url, "mailto:someone@example.com"),
            (PasteboardTypeID.plainText, "联系我"),
        ])
        let content = try #require(resolver.resolve(from: pasteboard))
        #expect(content.contentType == .plainText)
    }

    @Test("RTF 兜底剥离控制字")
    func rtfStripping() {
        let raw = "{\\rtf1\\ansi\\deff0 {\\fonttbl{\\f0 Helvetica;}}Hello 世界\\par}"
        let stripped = PasteboardResolver.stripRTF(raw)
        #expect(stripped.contains("Hello 世界"))
        #expect(!stripped.contains("rtf1"))
        #expect(!stripped.contains("fonttbl"))
    }

    // MARK: - 浏览器标签拖拽

    @Test("Firefox 标签：解析 UTF-16LE 的 text/x-moz-url（URL + 标题）")
    func firefoxTabDrag() throws {
        let payload = "https://example.com/arch\n多云架构实践"
        let data = payload.data(using: .utf16LittleEndian)!
        let pasteboard = FakePasteboard([
            (PasteboardTypeID.mozURL, data),
            (PasteboardTypeID.plainText, data),
        ])
        let content = try #require(resolver.resolve(from: pasteboard))
        #expect(content.contentType == .webLink)
        #expect(content.pageURL?.absoluteString == "https://example.com/arch")
        #expect(content.linkTitle == "多云架构实践")
    }

    @Test("Firefox 带 BOM 的 moz-url 也能解析")
    func firefoxTabDragWithBOM() throws {
        var data = Data([0xFF, 0xFE])
        data.append("https://example.com/x\n标题".data(using: .utf16LittleEndian)!)
        let pasteboard = FakePasteboard([(PasteboardTypeID.mozURL, data)])
        let content = try #require(resolver.resolve(from: pasteboard))
        #expect(content.pageURL?.absoluteString == "https://example.com/x")
        #expect(content.linkTitle == "标题")
    }

    @Test("Safari 标签：public.url + public.url-name 提供标题")
    func safariTabDrag() throws {
        let pasteboard = FakePasteboard(strings: [
            (PasteboardTypeID.url, "https://example.com/a"),
            (PasteboardTypeID.urlName, "深度技术文章"),
        ])
        let content = try #require(resolver.resolve(from: pasteboard))
        #expect(content.contentType == .webLink)
        #expect(content.linkTitle == "深度技术文章")
    }

    @Test("Chrome 标签：从 text/uri-list 取第一条非注释行")
    func chromeTabDrag() throws {
        let pasteboard = FakePasteboard(strings: [
            (PasteboardTypeID.uriList, "# 拖拽来源\nhttps://example.com/chrome-tab\nhttps://example.com/second"),
        ])
        let content = try #require(resolver.resolve(from: pasteboard))
        #expect(content.pageURL?.absoluteString == "https://example.com/chrome-tab")
    }

    @Test("uri-list 解析：跳过注释与空行，拒绝非 http(s)")
    func uriListParsing() {
        #expect(PasteboardResolver.firstURL(inURIList: "# 注释\n\nhttps://a.com/x")?.absoluteString
            == "https://a.com/x")
        #expect(PasteboardResolver.firstURL(inURIList: "javascript:alert(1)") == nil)
        #expect(PasteboardResolver.firstURL(inURIList: "   ") == nil)
    }
}
