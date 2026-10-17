import Foundation

/// 正文提取结果。
public struct ArticleExtraction: Sendable, Equatable {
    public let title: String
    public let byline: String?
    public let excerpt: String?
    public let siteName: String?
    public let canonicalURL: URL?
    public let publishedTime: String?
    public let language: String?
    public let markdown: String
    public let textLength: Int
    /// 选中的正文容器（`article.entry-content` / `div#main` / `body`），便于诊断路由与提取质量。
    public let contentSelector: String

    public init(
        title: String,
        byline: String? = nil,
        excerpt: String? = nil,
        siteName: String? = nil,
        canonicalURL: URL? = nil,
        publishedTime: String? = nil,
        language: String? = nil,
        markdown: String,
        textLength: Int,
        contentSelector: String
    ) {
        self.title = title
        self.byline = byline
        self.excerpt = excerpt
        self.siteName = siteName
        self.canonicalURL = canonicalURL
        self.publishedTime = publishedTime
        self.language = language
        self.markdown = markdown
        self.textLength = textLength
        self.contentSelector = contentSelector
    }
}

/// 正文提取引擎抽象。
///
/// 白皮书规划的 JavaScriptCore + Readability.js/Turndown.js 引擎可在此协议下接入，
/// 与当前的原生 Swift 实现互换，上层流水线无需改动。
public protocol ArticleExtracting: Sendable {
    func extract(html: String, baseURL: URL?) -> ArticleExtraction?
}

/// 原生 Swift 正文提取器（Readability 风格打分 + Markdown 渲染）。
public struct HTMLExtractor: ArticleExtracting {
    /// 正文长度下限：低于该值的候选容器视为导航/侧栏等噪声。
    ///
    /// Readability 的经验值（约 200 字符）是按拉丁文标定的；中文信息密度更高，
    /// 同样的信息量只需一半左右字符，因此这里取 120，避免中文短文被直接丢弃。
    public static let minimumContentLength = 120
    /// Markdown 正文长度上限，避免超长页面把数据库行撑爆。
    public static let maximumMarkdownLength = 200_000
    /// 用于打分的候选容器标签。
    static let candidateTags: Set<String> = ["article", "main", "div", "section", "td", "body", "blockquote"]
    /// 噪声标签：整棵子树直接丢弃。
    static let noiseTags: Set<String> = [
        "script", "style", "noscript", "iframe", "svg", "template", "canvas",
        "form", "button", "input", "select", "textarea", "label",
        "video", "audio", "object", "embed", "nav", "footer", "aside",
        "link", "meta", "base", "head", "dialog", "menu",
    ]
    /// 噪声 class / id 词元（按非字母数字切分后逐词匹配，避免误伤 "canvas" 这类近似词）。
    static let noiseTokens: Set<String> = [
        "ad", "ads", "advert", "advertisement", "adsbygoogle", "sponsor", "sponsored",
        "promo", "promotion", "share", "sharing", "social", "socials", "follow",
        "comment", "comments", "disqus", "related", "recommend", "recommended",
        "sidebar", "breadcrumb", "breadcrumbs", "pagination", "pager", "nav",
        "navbar", "navigation", "menu", "menus", "toolbar", "newsletter",
        "subscribe", "subscription", "cookie", "cookies", "consent", "banner",
        "popup", "modal", "overlay", "hidden", "print", "skip", "visually",
    ]
    /// 噪声 ARIA role。
    static let noiseRoles: Set<String> = [
        "navigation", "banner", "complementary", "contentinfo", "search",
        "form", "dialog", "menu", "menubar", "tablist", "tooltip",
    ]

    private let parser = HTMLParser()
    private let renderer: MarkdownRenderer

    public init() {
        self.renderer = MarkdownRenderer()
    }

    public func extract(html: String, baseURL: URL?) -> ArticleExtraction? {
        let document = parser.parse(html)
        let metadata = Metadata(document: document, baseURL: baseURL)
        guard let body = MarkdownRenderer.firstDescendant(in: document, named: "body") ?? document as HTMLElement? else {
            return nil
        }

        let cleanedBody = Self.strippingNoise(body)
        let (content, selector, textLength) = Self.selectContentRoot(in: cleanedBody)
        guard let content, textLength >= 60 else { return nil }

        let markdown = Self.truncate(
            MarkdownRenderer(baseURL: metadata.canonicalURL ?? baseURL).render(element: content),
            limit: Self.maximumMarkdownLength
        )
        guard !markdown.isEmpty else { return nil }

        return ArticleExtraction(
            title: metadata.resolvedTitle(in: content),
            byline: metadata.byline,
            excerpt: metadata.excerpt,
            siteName: metadata.siteName,
            canonicalURL: metadata.canonicalURL,
            publishedTime: metadata.publishedTime,
            language: metadata.language,
            markdown: markdown,
            textLength: textLength,
            contentSelector: selector
        )
    }

    /// P3 拖拽的 `.html` 片段：不过正文打分，直接转 Markdown。
    public func markdown(fromFragmentHTML html: String, baseURL: URL?) -> String {
        let nodes = parser.parseFragment(html)
        return MarkdownRenderer(baseURL: baseURL).render(nodes)
    }

    // MARK: - 噪声清理

    static func strippingNoise(_ element: HTMLElement) -> HTMLElement {
        var copy = element
        copy.children = element.children.compactMap { node -> HTMLNode? in
            guard case .element(let child) = node else { return node }
            guard !isNoise(child) else { return nil }
            return .element(strippingNoise(child))
        }
        return copy
    }

    static func isNoise(_ element: HTMLElement) -> Bool {
        if noiseTags.contains(element.name) { return true }
        if let role = element.attribute("role")?.lowercased(), noiseRoles.contains(role) { return true }
        if element.attribute("hidden") != nil { return true }
        if (element.attribute("aria-hidden") ?? "").lowercased() == "true" { return true }
        if let style = element.attribute("style")?.lowercased(),
           style.contains("display:none") || style.contains("display: none") {
            return true
        }
        return tokens(of: element).contains { noiseTokens.contains($0) }
    }

    static func tokens(of element: HTMLElement) -> [String] {
        var raw = element.classNames
        if let id = element.id { raw.append(id) }
        return raw.flatMap { value in
            value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        }
    }

    // MARK: - 正文容器打分

    static func selectContentRoot(in body: HTMLElement) -> (HTMLElement?, String, Int) {
        var best: (element: HTMLElement, score: Double, textLength: Int, selector: String)?
        /// 语义容器（article / main / itemprop=articleBody）的优先容差：
        /// 打分接近时优先选语义标签，结果更可预测。
        var semantic: (element: HTMLElement, score: Double, textLength: Int, selector: String)?
        let semanticTolerance = 0.85

        func visit(_ element: HTMLElement, path: String) {
            let selector = path.isEmpty ? element.name : "\(element.name)\(path)"
            if candidateTags.contains(element.name) {
                let text = HTMLText.collapseWhitespace(element.textContent)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let length = text.count
                if length >= minimumContentLength {
                    let score = contentScore(element: element, textLength: length)
                    if best == nil || score > best!.score {
                        best = (element, score, length, selector)
                    }
                    if isSemanticContainer(element), semantic == nil || score > semantic!.score {
                        semantic = (element, score, length, selector)
                    }
                }
            }
            for child in element.children {
                guard case .element(let childElement) = child else { continue }
                visit(childElement, path: childElement.name == "div" || childElement.name == "section" ? selector : "")
            }
        }

        visit(body, path: "")

        if let semantic, let best, semantic.score >= best.score * semanticTolerance {
            return (semantic.element, semantic.selector, semantic.textLength)
        }
        guard let best else {
            let fallbackText = HTMLText.collapseWhitespace(body.textContent)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (body, "body", fallbackText.count)
        }
        return (best.element, best.selector, best.textLength)
    }

    static func isSemanticContainer(_ element: HTMLElement) -> Bool {
        if element.name == "article" || element.name == "main" { return true }
        if element.attribute("itemprop") == "articleBody" { return true }
        return (element.attribute("role") ?? "").lowercased() == "main"
    }

    /// 打分：正文长度 ×（1 − 链接密度）× 段落/语义加权。
    static func contentScore(element: HTMLElement, textLength: Int) -> Double {
        let linkLength = MarkdownRenderer.descendants(of: element, named: "a")
            .reduce(0) { $0 + $1.textContent.count }
        let density = textLength > 0 ? min(1, Double(linkLength) / Double(textLength)) : 1
        let paragraphCount = MarkdownRenderer.descendants(of: element, named: "p").count

        var score = Double(textLength) * (1 - density)
        score *= 1 + min(0.5, Double(paragraphCount) * 0.05)
        switch element.name {
        case "article": score *= 1.2
        case "main": score *= 1.15
        case "body": score *= 0.8
        default: break
        }
        if (element.attribute("role") ?? "").lowercased() == "main" { score *= 1.15 }
        if element.attribute("itemprop") == "articleBody" { score *= 1.2 }
        return score
    }

    // MARK: - 截断

    static func truncate(_ markdown: String, limit: Int) -> String {
        guard markdown.count > limit else { return markdown }
        let cut = markdown.prefix(limit)
        let boundary = cut.lastIndex(of: "\n") ?? cut.startIndex
        return String(cut[..<boundary]) + "\n\n（正文过长，已截断）"
    }
}

// MARK: - 元数据

private struct Metadata {
    let document: HTMLElement
    let baseURL: URL?

    var siteName: String? { metaContent("og:site_name") }
    var language: String? {
        MarkdownRenderer.firstDescendant(in: document, named: "html")?.attribute("lang")
            ?? metaContent("og:locale")
    }

    var excerpt: String? {
        let candidates = [
            metaContent("og:description"),
            metaContent("description"),
            metaContent("twitter:description"),
        ]
        return candidates.compactMap { $0 }.first { !$0.isEmpty }
    }

    var byline: String? {
        let candidates = [
            metaContent("author"),
            metaContent("article:author"),
            metaContent("og:article:author"),
            metaContent("twitter:creator"),
        ]
        return candidates.compactMap { $0 }.first { !$0.isEmpty }
    }

    var publishedTime: String? {
        let candidates = [
            metaContent("article:published_time"),
            metaContent("datePublished"),
            metaContent("og:updated_time"),
        ]
        return candidates.compactMap { $0 }.first { !$0.isEmpty }
    }

    var canonicalURL: URL? {
        if let link = MarkdownRenderer.descendants(of: document, named: "link").first(where: {
            ($0.attribute("rel") ?? "").lowercased().split(whereSeparator: \.isWhitespace)
                .contains("canonical")
        }), let url = URLResolver.resolve(link.attribute("href"), base: baseURL) {
            return url
        }
        return URLResolver.resolve(metaContent("og:url"), base: baseURL)
    }

    func resolvedTitle(in content: HTMLElement) -> String {
        let raw = [
            metaContent("og:title"),
            metaContent("twitter:title"),
            MarkdownRenderer.firstDescendant(in: document, named: "title")?.textContent,
            MarkdownRenderer.firstDescendant(in: content, named: "h1")?.textContent,
            MarkdownRenderer.firstDescendant(in: document, named: "h1")?.textContent,
        ]
        .compactMap { $0 }
        .map { HTMLText.collapseWhitespace($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
        return Self.cleanedTitle(raw ?? "", siteName: siteName)
    }

    /// 去掉标题尾部的站点后缀（`标题 - 站点名` / `标题 | 站点名`）。
    static func cleanedTitle(_ raw: String, siteName: String?) -> String {
        let separators = [" | ", " - ", " – ", " — ", " · ", " _ "]
        for separator in separators {
            guard let range = raw.range(of: separator, options: .backwards) else { continue }
            let head = String(raw[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let tail = String(raw[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard head.count >= 4, !tail.isEmpty else { continue }
            if let siteName, tail.caseInsensitiveCompare(siteName) == .orderedSame {
                return head
            }
            // 后缀不长于主体且不超过 20 字时才认定为站点名，避免误砍含连字符的短标题。
            if tail.count <= 20, head.count >= 4, tail.count <= head.count {
                return head
            }
        }
        return raw
    }

    private func metaContent(_ key: String) -> String? {
        let lowered = key.lowercased()
        for meta in MarkdownRenderer.descendants(of: document, named: "meta") {
            let identifiers = [
                meta.attribute("property"),
                meta.attribute("name"),
                meta.attribute("itemprop"),
            ].compactMap { $0?.lowercased() }
            if identifiers.contains(lowered), let content = meta.attribute("content") {
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }
}
