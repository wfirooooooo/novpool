import Foundation
import Testing
@testable import NovPoolSystemBridge

@Suite("HTML 正文提取与 Markdown 渲染")
struct HTMLPipelineTests {
    private let extractor = HTMLExtractor()
    private let baseURL = URL(string: "https://blog.example.com/posts/arch")

    private var articleHTML: String {
        """
        <!DOCTYPE html>
        <html lang="zh-Hans">
        <head>
          <title>多云架构实践 - 示例博客</title>
          <meta property="og:site_name" content="示例博客">
          <meta name="description" content="一篇关于多云归档架构的实践记录。">
          <meta name="author" content="张三">
          <meta property="article:published_time" content="2026-03-09T10:00:00Z">
          <link rel="canonical" href="/posts/arch">
          <style>body { color: red; }</style>
          <script>var tracking = 1;</script>
        </head>
        <body>
          <nav class="site-nav"><a href="/">首页</a><a href="/about">关于</a></nav>
          <div class="ad-banner">广告位招租</div>
          <article class="post">
            <h1>多云架构实践</h1>
            <p>把拖拽的内容路由到 <strong>多云</strong> 存储，需要一条 <em>可靠</em> 的流水线。</p>
            <p>参考 <a href="/docs/spec">规范文档</a> 与 <a href="https://notion.so/x">Notion</a>。</p>
            <ul>
              <li>本地暂存</li>
              <li>哈希去重</li>
            </ul>
            <blockquote><p>先落本地，再传云端。</p></blockquote>
            <pre><code class="language-swift">let value = 1 &amp;&amp; 2</code></pre>
            <table>
              <tr><th>层级</th><th>职责</th></tr>
              <tr><td>捕获层</td><td>解析粘贴板</td></tr>
            </table>
            <figure>
              <img src="/img/arch.png" alt="架构图">
              <figcaption>整体架构</figcaption>
            </figure>
            <p>尾部段落 &amp; 结束，含 &#39;单引号&#39; 与 &#x4E2D;&#x6587;。</p>
          </article>
          <aside class="sidebar"><p>相关推荐：别的文章</p></aside>
          <div class="comments"><p>评论区内容不该进正文</p></div>
          <footer><p>© 2026 示例博客</p></footer>
        </body>
        </html>
        """
    }

    @Test("元数据提取：标题、作者、摘要、站点、canonical、发布时间、语言")
    func metadata() throws {
        let article = try #require(extractor.extract(html: articleHTML, baseURL: baseURL))
        #expect(article.title == "多云架构实践")
        #expect(article.byline == "张三")
        #expect(article.excerpt == "一篇关于多云归档架构的实践记录。")
        #expect(article.siteName == "示例博客")
        #expect(article.publishedTime == "2026-03-09T10:00:00Z")
        #expect(article.language == "zh-Hans")
        #expect(article.canonicalURL?.absoluteString == "https://blog.example.com/posts/arch")
    }

    @Test("正文选择命中语义容器，噪声区块被剔除")
    func contentSelection() throws {
        let article = try #require(extractor.extract(html: articleHTML, baseURL: baseURL))
        #expect(article.contentSelector.hasPrefix("article"))
        #expect(!article.markdown.contains("广告位招租"))
        #expect(!article.markdown.contains("相关推荐"))
        #expect(!article.markdown.contains("评论区内容"))
        #expect(!article.markdown.contains("© 2026"))
        #expect(!article.markdown.contains("var tracking"))
        #expect(!article.markdown.contains("color: red"))
    }

    @Test("Markdown 结构：标题、强调、列表、引用、代码块、表格、图片")
    func markdownStructure() throws {
        let markdown = try #require(extractor.extract(html: articleHTML, baseURL: baseURL)).markdown

        #expect(markdown.contains("# 多云架构实践"))
        #expect(markdown.contains("**多云**"))
        #expect(markdown.contains("*可靠*"))
        // 相对链接补全为绝对地址
        #expect(markdown.contains("[规范文档](https://blog.example.com/docs/spec)"))
        #expect(markdown.contains("[Notion](https://notion.so/x)"))
        #expect(markdown.contains("- 本地暂存"))
        #expect(markdown.contains("- 哈希去重"))
        #expect(markdown.contains("> 先落本地，再传云端。"))
        #expect(markdown.contains("```swift"))
        #expect(markdown.contains("let value = 1 && 2"))
        #expect(markdown.contains("| 层级 | 职责 |"))
        #expect(markdown.contains("| 捕获层 | 解析粘贴板 |"))
        #expect(markdown.contains("![架构图](https://blog.example.com/img/arch.png)"))
        #expect(markdown.contains("*整体架构*"))
    }

    @Test("实体解码：命名实体、十进制与十六进制数字实体")
    func entityDecoding() throws {
        let markdown = try #require(extractor.extract(html: articleHTML, baseURL: baseURL)).markdown
        #expect(markdown.contains("尾部段落 & 结束"))
        #expect(markdown.contains("'单引号'"))
        #expect(markdown.contains("中文"))
    }

    @Test("跨节点词间空格不被吞掉")
    func inlineSpacing() {
        let markdown = extractor.markdown(fromFragmentHTML: "<p>前缀 <b>粗体</b> 后缀</p>", baseURL: nil)
        #expect(markdown == "前缀 **粗体** 后缀")
    }

    @Test("javascript: 与 data: 链接退化为纯文本")
    func unsafeLinks() {
        let markdown = extractor.markdown(
            fromFragmentHTML: #"<p><a href="javascript:alert(1)">点我</a> <a href="data:image/png;base64,AAA">图</a></p>"#,
            baseURL: nil
        )
        #expect(markdown == "点我 图")
    }

    @Test("任务列表复选框转成 GFM 语法")
    func taskList() {
        let markdown = extractor.markdown(
            fromFragmentHTML: #"<ul><li><input type="checkbox" checked>已完成</li><li><input type="checkbox">待办</li></ul>"#,
            baseURL: nil
        )
        #expect(markdown.contains("- [x] 已完成"))
        #expect(markdown.contains("- [ ] 待办"))
    }

    @Test("标题去掉站点后缀")
    func titleSuffixCleanup() {
        let html = """
        <html><head><title>深度技术文章 - 示例博客</title></head>
        <body><article><p>\(String(repeating: "正文内容。", count: 60))</p></article></body></html>
        """
        let article = extractor.extract(html: html, baseURL: baseURL)
        #expect(article?.title == "深度技术文章")
    }

    @Test("内容过短的页面不产生提取结果")
    func rejectsThinContent() {
        #expect(extractor.extract(html: "<html><body><p>太短</p></body></html>", baseURL: nil) == nil)
        #expect(extractor.extract(html: "", baseURL: nil) == nil)
    }

    @Test("未闭合标签与隐式闭合不会破坏结构")
    func malformedHTML() {
        let markdown = extractor.markdown(
            fromFragmentHTML: "<div><p>第一段<p>第二段<ul><li>甲<li>乙</ul></div>",
            baseURL: nil
        )
        #expect(markdown.contains("第一段"))
        #expect(markdown.contains("第二段"))
        #expect(markdown.contains("- 甲"))
        #expect(markdown.contains("- 乙"))
    }

    @Test("script / style 原始文本整体跳过")
    func rawTextElements() {
        let markdown = extractor.markdown(
            fromFragmentHTML: "<div><script>if (a < b) { evil(); }</script><p>正文</p><style>p{}</style></div>",
            baseURL: nil
        )
        #expect(markdown == "正文")
    }

    @Test("超长正文按段落边界截断")
    func truncation() {
        let paragraph = String(repeating: "内容", count: 50)
        let long = (0..<300).map { _ in "<p>\(paragraph)</p>" }.joined()
        let markdown = extractor.markdown(fromFragmentHTML: long, baseURL: nil)
        let truncated = HTMLExtractor.truncate(markdown, limit: 1000)
        #expect(truncated.count < markdown.count)
        #expect(truncated.hasSuffix("（正文过长，已截断）"))
    }

    @Test("链接密度高的导航容器不会被选为正文")
    func linkDensityGuard() throws {
        let linkList = (0..<60).map { #"<li><a href="/p/\#($0)">导航链接文字 \#($0)</a></li>"# }.joined()
        let html = """
        <html><body>
          <div class="nav-links"><ul>\(linkList)</ul></div>
          <section id="content">
            <p>\(String(repeating: "这是真正的正文段落。", count: 30))</p>
          </section>
        </body></html>
        """
        let article = try #require(extractor.extract(html: html, baseURL: baseURL))
        #expect(article.markdown.contains("这是真正的正文段落"))
        #expect(!article.markdown.contains("导航链接文字"))
    }
}
