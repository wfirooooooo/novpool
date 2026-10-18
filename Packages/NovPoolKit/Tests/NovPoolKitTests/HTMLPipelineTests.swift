import Foundation
import Testing
@testable import NovPoolSystemBridge

@Suite("HTML Body Extraction and Markdown Rendering")
struct HTMLPipelineTests {
    private let extractor = HTMLExtractor()
    private let baseURL = URL(string: "https://blog.example.com/posts/arch")

    private var articleHTML: String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <title>Cloud Architecture Practice - Sample Blog</title>
          <meta property="og:site_name" content="Sample Blog">
          <meta name="description" content="A practical record on multi-cloud archiving architecture.">
          <meta name="author" content="Zhang San">
          <meta property="article:published_time" content="2026-03-09T10:00:00Z">
          <link rel="canonical" href="/posts/arch">
          <style>body { color: red; }</style>
          <script>var tracking = 1;</script>
        </head>
        <body>
          <nav class="site-nav"><a href="/">Home</a><a href="/about">About</a></nav>
          <div class="ad-banner">Advertising Space for Rent</div>
          <article class="post">
            <h1>Cloud Architecture Practice</h1>
            <p>Routing dropped content into <strong>Cloudy</strong> storage needs a <em>Reliable</em> pipeline.</p>
            <p>See the <a href="/docs/spec">Standard Document</a> and <a href="https://notion.so/x">Notion</a>.</p>
            <ul>
              <li>Local staging</li>
              <li>Hash deduplication</li>
            </ul>
            <blockquote><p>First save locally, then upload to the cloud.</p></blockquote>
            <pre><code class="language-swift">let value = 1 &amp;&amp; 2</code></pre>
            <table>
              <tr><th>Hierarchy</th><th>Responsibilities</th></tr>
              <tr><td>Capture layer</td><td>Analyze Clipboard</td></tr>
            </table>
            <figure>
              <img src="/img/arch.png" alt="Architecture Diagram">
              <figcaption>Overall architecture</figcaption>
            </figure>
            <p>Tail paragraph &amp; End, with &#39;Single quotation mark&#39; and &#x4E2D;&#x6587;.</p>
          </article>
          <aside class="sidebar"><p>Related recommendations: other articles</p></aside>
          <div class="comments"><p>Comments section content should not enter Body</p></div>
          <footer><p>© 2026 Sample Blog</p></footer>
        </body>
        </html>
        """
    }

    @Test("Metadata extraction: title, author, abstract, site, canonical, publish time, language")
    func metadata() throws {
        let article = try #require(extractor.extract(html: articleHTML, baseURL: baseURL))
        #expect(article.title == "Cloud Architecture Practice")
        #expect(article.byline == "Zhang San")
        #expect(article.excerpt == "A practical record on multi-cloud archiving architecture.")
        #expect(article.siteName == "Sample Blog")
        #expect(article.publishedTime == "2026-03-09T10:00:00Z")
        #expect(article.language == "en")
        #expect(article.canonicalURL?.absoluteString == "https://blog.example.com/posts/arch")
    }

    @Test("BodySelect hits the Semantic container, and the noise blocks are eliminated")
    func contentSelection() throws {
        let article = try #require(extractor.extract(html: articleHTML, baseURL: baseURL))
        #expect(article.contentSelector.hasPrefix("article"))
        #expect(!article.markdown.contains("Advertising Space for Rent"))
        #expect(!article.markdown.contains("Related recommendations"))
        #expect(!article.markdown.contains("Comments section content"))
        #expect(!article.markdown.contains("© 2026"))
        #expect(!article.markdown.contains("var tracking"))
        #expect(!article.markdown.contains("color: red"))
    }

    @Test("Markdown structure: headings, emphasis, lists, blockquotes, code blocks, tables, images")
    func markdownStructure() throws {
        let markdown = try #require(extractor.extract(html: articleHTML, baseURL: baseURL)).markdown

        #expect(markdown.contains("# Cloud Architecture Practice"))
        #expect(markdown.contains("**Cloudy**"))
        #expect(markdown.contains("*Reliable*"))
        // Convert relative links to absolute addresses
        #expect(markdown.contains("[Standard Document](https://blog.example.com/docs/spec)"))
        #expect(markdown.contains("[Notion](https://notion.so/x)"))
        #expect(markdown.contains("- Local staging"))
        #expect(markdown.contains("- Hash deduplication"))
        #expect(markdown.contains("> First save locally, then upload to the cloud."))
        #expect(markdown.contains("```swift"))
        #expect(markdown.contains("let value = 1 && 2"))
        #expect(markdown.contains("| Hierarchy | Responsibilities |"))
        #expect(markdown.contains("| Capture layer | Analyze Clipboard |"))
        #expect(markdown.contains("![Architecture Diagram](https://blog.example.com/img/arch.png)"))
        #expect(markdown.contains("*Overall architecture*"))
    }

    @Test("Entity Decoding: Named Entities, Decimal and Hexadecimal Numeric Entities")
    func entityDecoding() throws {
        let markdown = try #require(extractor.extract(html: articleHTML, baseURL: baseURL)).markdown
        #expect(markdown.contains("Tail paragraph & End"))
        #expect(markdown.contains("'Single quotation mark'"))
        #expect(markdown.contains("中文"))
    }

    @Test("Spaces between words across nodes are not swallowed")
    func inlineSpacing() {
        let markdown = extractor.markdown(fromFragmentHTML: "<p>Prefix<b>Bold</b> Suffix</p>", baseURL: nil)
        #expect(markdown == "Prefix**Bold** Suffix")
    }

    @Test("javascript: and data: Link degrade to Plain Text")
    func unsafeLinks() {
        let markdown = extractor.markdown(
            fromFragmentHTML: #"<p><a href="javascript:alert(1)">Click me</a> <a href="data:image/png;base64,AAA">Picture</a></p>"#,
            baseURL: nil
        )
        #expect(markdown == "Click me Picture")
    }

    @Test("Convert task list checkboxes to GFM syntax")
    func taskList() {
        let markdown = extractor.markdown(
            fromFragmentHTML: #"<ul><li><input type="checkbox" checked>Completed</li><li><input type="checkbox">To-do</li></ul>"#,
            baseURL: nil
        )
        #expect(markdown.contains("- [x] Completed"))
        #expect(markdown.contains("- [ ] To-do"))
    }

    @Test("Remove site suffix from title")
    func titleSuffixCleanup() {
        let html = """
        <html><head><title>In-depth technical article - Sample Blog</title></head>
        <body><article><p>\(String(repeating: "BodyContent.", count: 60))</p></article></body></html>
        """
        let article = extractor.extract(html: html, baseURL: baseURL)
        #expect(article?.title == "In-depth technical article")
    }

    @Test("Pages with content that is too short do not produce extraction results")
    func rejectsThinContent() {
        #expect(extractor.extract(html: "<html><body><p>Too short</p></body></html>", baseURL: nil) == nil)
        #expect(extractor.extract(html: "", baseURL: nil) == nil)
    }

    @Test("Unclosed tags and implicit closures do not break the structure")
    func malformedHTML() {
        let markdown = extractor.markdown(
            fromFragmentHTML: "<div><p>First paragraph<p>Second paragraph<ul><li>A<li>B</ul></div>",
            baseURL: nil
        )
        #expect(markdown.contains("First paragraph"))
        #expect(markdown.contains("Second paragraph"))
        #expect(markdown.contains("- A"))
        #expect(markdown.contains("- B"))
    }

    @Test("script / style original text skipped as a whole")
    func rawTextElements() {
        let markdown = extractor.markdown(
            fromFragmentHTML: "<div><script>if (a < b) { evil(); }</script><p>Body</p><style>p{}</style></div>",
            baseURL: nil
        )
        #expect(markdown == "Body")
    }

    @Test("Truncate the extra-long body at paragraph boundaries")
    func truncation() {
        let paragraph = String(repeating: "Content", count: 50)
        let long = (0..<300).map { _ in "<p>\(paragraph)</p>" }.joined()
        let markdown = extractor.markdown(fromFragmentHTML: long, baseURL: nil)
        let truncated = HTMLExtractor.truncate(markdown, limit: 1000)
        #expect(truncated.count < markdown.count)
        #expect(truncated.hasSuffix("(truncated; body too long)"))
    }

    @Test("Navigation containers with high link density will not be selected as the Body")
    func linkDensityGuard() throws {
        let linkList = (0..<60).map { #"<li><a href="/p/\#($0)">Navigation Link Text\#($0)</a></li>"# }.joined()
        let html = """
        <html><body>
          <div class="nav-links"><ul>\(linkList)</ul></div>
          <section id="content">
            <p>\(String(repeating: "This is the real body paragraph.", count: 30))</p>
          </section>
        </body></html>
        """
        let article = try #require(extractor.extract(html: html, baseURL: baseURL))
        #expect(article.markdown.contains("This is the real body paragraph"))
        #expect(!article.markdown.contains("Navigation Link Text"))
    }
}
