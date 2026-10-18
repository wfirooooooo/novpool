import Foundation
import NovPoolCore
import Testing
@testable import NovPoolSystemBridge

@Suite("Clipboard UTI Priority Analysis")
struct PasteboardResolverTests {
    private let resolver = PasteboardResolver()

    @Test("P0: Local files take precedence over images and text on the same clipboard")
    func fileURLWins() throws {
        let pasteboard = FakePasteboard(strings: [
            (PasteboardTypeID.fileURL, "file:///tmp/novpool-fixtures/report%20final.pdf"),
            (PasteboardTypeID.plainText, "Some Body"),
            (PasteboardTypeID.png, "fake-image"),
        ])
        let content = try #require(resolver.resolve(from: pasteboard))
        #expect(content.contentType == .documentPDF)
        #expect(content.fileURLs.count == 1)
        #expect(content.fileURLs[0].pathExtension == "pdf")
    }

    @Test("P0: Parse all paths from multiple file drags, and determine the type based on the first file")
    func multipleFiles() throws {
        let pasteboard = FakePasteboard(strings: [
            (PasteboardTypeID.fileURL, "file:///tmp/a.png\nfile:///tmp/b.txt"),
        ])
        let content = try #require(resolver.resolve(from: pasteboard))
        #expect(content.contentType == .image)
        #expect(content.fileURLs.map(\.lastPathComponent) == ["a.png", "b.txt"])
        let expanded = content.expandedForIngest()
        #expect(expanded.map(\.contentType) == [.image, .genericFile])
        #expect(expanded.map { $0.fileURLs.map(\.lastPathComponent) } == [["a.png"], ["b.txt"]])
    }

    @Test("P0: Enumerate all file URLs when there are multiple pasteboard items")
    func multiplePasteboardItems() throws {
        // Simulate NSPasteboardReader.allStrings: one URL per item
        struct MultiItemPasteboard: PasteboardReading {
            var availableTypeIdentifiers: [String] { [PasteboardTypeID.fileURL] }
            func data(forTypeIdentifier typeIdentifier: String) -> Data? { nil }
            func string(forTypeIdentifier typeIdentifier: String) -> String? {
                // Like the real NSPasteboard: aggregate read only gives the first item
                "file:///tmp/only-first.png"
            }
            func allStrings(forTypeIdentifier typeIdentifier: String) -> [String] {
                ["file:///tmp/only-first.png", "file:///tmp/second.txt"]
            }
        }
        let content = try #require(resolver.resolve(from: MultiItemPasteboard()))
        #expect(content.fileURLs.map(\.lastPathComponent) == ["only-first.png", "second.txt"])
    }

    @Test("P1: WebImage uses in-memory byte stream, does not rely on Image URL for secondary download")
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

    @Test("P2: It is determined as a WebLink only when there is a short Link text")
    func shortLinkBecomesWebLink() throws {
        let pasteboard = FakePasteboard(strings: [
            (PasteboardTypeID.url, "https://example.com/post"),
            (PasteboardTypeID.plainText, "A good article"),
            (PasteboardTypeID.html, "<a href=\"https://example.com/post\">A good article</a>"),
        ])
        let content = try #require(resolver.resolve(from: pasteboard))
        #expect(content.contentType == .webLink)
        #expect(content.pageURL?.absoluteString == "https://example.com/post")
    }

    @Test("P3: When the Body contains a block of HTML, it is considered Rich Text")
    func longTextBecomesRichHTML() throws {
        let article = String(repeating: "This is a long enough body content to trigger the Rich Text determination.", count: 6)
        let pasteboard = FakePasteboard(strings: [
            (PasteboardTypeID.html, "<div><p>\(article)</p></div>"),
            (PasteboardTypeID.plainText, article),
        ])
        let content = try #require(resolver.resolve(from: pasteboard))
        #expect(content.contentType == .richHTML)
        #expect(content.text == article)
        #expect(content.html?.hasPrefix("<div>") == true)
    }

    @Test("P3: Plain Text Bottom Line")
    func plainTextFallback() throws {
        let pasteboard = FakePasteboard(strings: [(PasteboardTypeID.plainText, "Jot down a sentence casually")])
        let content = try #require(resolver.resolve(from: pasteboard))
        #expect(content.contentType == .plainText)
        #expect(content.text == "Jot down a sentence casually")
    }

    @Test("An empty clipboard and a completely blank Text return nil")
    func emptyPasteboard() {
        #expect(resolver.resolve(from: FakePasteboard()) == nil)
        #expect(resolver.resolve(from: FakePasteboard(strings: [(PasteboardTypeID.plainText, "   \n ") ])) == nil)
    }

    @Test("Non-http(s) URLs are not treated as WebLinks")
    func nonHTTPURLIgnored() throws {
        let pasteboard = FakePasteboard(strings: [
            (PasteboardTypeID.url, "mailto:someone@example.com"),
            (PasteboardTypeID.plainText, "Contact me"),
        ])
        let content = try #require(resolver.resolve(from: pasteboard))
        #expect(content.contentType == .plainText)
    }

    @Test("RTF Bottom-Line Stripping Control Character")
    func rtfStripping() {
        let raw = "{\\rtf1\\ansi\\deff0 {\\fonttbl{\\f0 Helvetica;}}Hello World\\par}"
        let stripped = PasteboardResolver.stripRTF(raw)
        #expect(stripped.contains("Hello World"))
        #expect(!stripped.contains("rtf1"))
        #expect(!stripped.contains("fonttbl"))
    }

    // MARK: - Browser tab drag

    @Test("Firefox tab: parse text/x-moz-url (URL + title) in UTF-16LE")
    func firefoxTabDrag() throws {
        let payload = "https://example.com/arch\nCloud Architecture Practice"
        let data = payload.data(using: .utf16LittleEndian)!
        let pasteboard = FakePasteboard([
            (PasteboardTypeID.mozURL, data),
            (PasteboardTypeID.plainText, data),
        ])
        let content = try #require(resolver.resolve(from: pasteboard))
        #expect(content.contentType == .webLink)
        #expect(content.pageURL?.absoluteString == "https://example.com/arch")
        #expect(content.linkTitle == "Cloud Architecture Practice")
    }

    @Test("Firefox can also parse moz-urls with BOM")
    func firefoxTabDragWithBOM() throws {
        var data = Data([0xFF, 0xFE])
        data.append("https://example.com/x\nTitle".data(using: .utf16LittleEndian)!)
        let pasteboard = FakePasteboard([(PasteboardTypeID.mozURL, data)])
        let content = try #require(resolver.resolve(from: pasteboard))
        #expect(content.pageURL?.absoluteString == "https://example.com/x")
        #expect(content.linkTitle == "Title")
    }

    @Test("Safari tab: public.url + public.url-name provides title")
    func safariTabDrag() throws {
        let pasteboard = FakePasteboard(strings: [
            (PasteboardTypeID.url, "https://example.com/a"),
            (PasteboardTypeID.urlName, "In-depth technical article"),
        ])
        let content = try #require(resolver.resolve(from: pasteboard))
        #expect(content.contentType == .webLink)
        #expect(content.linkTitle == "In-depth technical article")
    }

    @Test("Chrome tab: Get the first non-comment line from text/uri-list")
    func chromeTabDrag() throws {
        let pasteboard = FakePasteboard(strings: [
            (PasteboardTypeID.uriList, "# Drag source\nhttps://example.com/chrome-tab\nhttps://example.com/second"),
        ])
        let content = try #require(resolver.resolve(from: pasteboard))
        #expect(content.pageURL?.absoluteString == "https://example.com/chrome-tab")
    }

    @Test("uri-list parsing: skip comments and empty lines, reject non-http(s)")
    func uriListParsing() {
        #expect(PasteboardResolver.firstURL(inURIList: "# Annotation\n\nhttps://a.com/x")?.absoluteString
            == "https://a.com/x")
        #expect(PasteboardResolver.firstURL(inURIList: "javascript:alert(1)") == nil)
        #expect(PasteboardResolver.firstURL(inURIList: "   ") == nil)
    }
}
