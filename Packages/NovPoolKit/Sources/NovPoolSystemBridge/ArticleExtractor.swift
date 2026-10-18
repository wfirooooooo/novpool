import Foundation

/// Body extraction result.
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
    /// The selected Body container (`article.entry-content` / `div#main` / `body`) facilitates diagnosing routes and extracting quality.
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

/// Body extraction engine abstraction.
///
/// The JavaScriptCore + Readability.js/Turndown.js engine planned in the white paper can be integrated under this protocol,
/// Interchangeable with the current native Swift implementation, the upper pipeline does not need to be changed.
public protocol ArticleExtracting: Sendable {
    func extract(html: String, baseURL: URL?) -> ArticleExtraction?
}

/// Native Swift Body Extractor (Readability Style Scoring + Markdown Rendering).
public struct HTMLExtractor: ArticleExtracting {
    /// Body length lower limit: Candidate containers below this value are considered noise, such as navigation/sidebars.
    ///
    /// The readability experience value (about 200 characters) is calibrated based on Latin; Chinese has a higher information density,
    /// The same amount of information requires only about half the characters, so here we take 120 to avoid Chinese short texts being directly discarded.
    public static let minimumContentLength = 120
    /// Markdown Body length limit to prevent excessively long pages from overloading database rows.
    public static let maximumMarkdownLength = 200_000
    /// Candidate container labels for scoring.
    static let candidateTags: Set<String> = ["article", "main", "div", "section", "td", "body", "blockquote"]
    /// Noise label: discard the entire subtree directly.
    static let noiseTags: Set<String> = [
        "script", "style", "noscript", "iframe", "svg", "template", "canvas",
        "form", "button", "input", "select", "textarea", "label",
        "video", "audio", "object", "embed", "nav", "footer", "aside",
        "link", "meta", "base", "head", "dialog", "menu",
    ]
    /// Noise class/id tokens (match word by word after splitting by non-alphanumeric characters to avoid mistakenly affecting similar words like "canvas").
    static let noiseTokens: Set<String> = [
        "ad", "ads", "advert", "advertisement", "adsbygoogle", "sponsor", "sponsored",
        "promo", "promotion", "share", "sharing", "social", "socials", "follow",
        "comment", "comments", "disqus", "related", "recommend", "recommended",
        "sidebar", "breadcrumb", "breadcrumbs", "pagination", "pager", "nav",
        "navbar", "navigation", "menu", "menus", "toolbar", "newsletter",
        "subscribe", "subscription", "cookie", "cookies", "consent", "banner",
        "popup", "modal", "overlay", "hidden", "print", "skip", "visually",
    ]
    /// Noise ARIA role.
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

    /// P3 Dragged `.html` fragment: Just score the Body, convert directly to Markdown.
    public func markdown(fromFragmentHTML html: String, baseURL: URL?) -> String {
        let nodes = parser.parseFragment(html)
        return MarkdownRenderer(baseURL: baseURL).render(nodes)
    }

    // MARK: - Noise cleanup

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

    // MARK: - Body container scoring

    static func selectContentRoot(in body: HTMLElement) -> (HTMLElement?, String, Int) {
        var best: (element: HTMLElement, score: Double, textLength: Int, selector: String)?
        /// Priority tolerance of Semantic container (article / main / itemprop=articleBody):
        /// When scores are close, prioritize selecting the Semantic label for more predictable results.
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

    /// Scoring: Body length × (1 − Link density) × Paragraph/Semantic weighting.
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

    // MARK: - truncate

    static func truncate(_ markdown: String, limit: Int) -> String {
        guard markdown.count > limit else { return markdown }
        let cut = markdown.prefix(limit)
        let boundary = cut.lastIndex(of: "\n") ?? cut.startIndex
        return String(cut[..<boundary]) + "\n\n(truncated; body too long)"
    }
}

// MARK: - Metadata

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

    /// Remove the site suffix at the end of the title (`Title - Site Name` / `Title | Site Name`).
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
            // A suffix is only recognized as the site name if it is not longer than the main part and does not exceed 20 characters, to avoid mistakenly cutting short titles that contain hyphens.
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
