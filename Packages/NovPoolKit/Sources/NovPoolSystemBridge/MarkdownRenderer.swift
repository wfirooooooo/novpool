import Foundation

/// HTML → Markdown renderer.
///
/// The product white paper planning uses embedded Turndown.js (JavaScriptCore) to do the same thing; it cannot be accessed offline in the development environment.
/// This script is implemented here in equivalent native Swift, retaining headings, lists, code blocks, blockquotes, bold/italic, links,
/// Image and GFM table structures. The `ArticleExtracting` protocol retains the access point for replacement with the JS engine.
public struct MarkdownRenderer: Sendable {
    public var baseURL: URL?

    /// Tags that do not participate in rendering at all.
    static let skippedTags: Set<String> = [
        "script", "style", "noscript", "iframe", "svg", "template", "canvas",
        "form", "button", "input", "select", "textarea", "label", "option",
        "video", "audio", "source", "track", "object", "embed", "map", "area",
        "link", "meta", "base", "head", "title", "dialog",
    ]

    /// Transparent container: does not produce Markdown syntax on its own, only renders child nodes.
    static let transparentTags: Set<String> = [
        "html", "body", "document", "fragment", "figure-inline", "div", "section",
        "article", "main", "header", "footer", "aside", "nav", "span", "center", "font",
        "fieldset", "details", "summary", "address", "abbr", "time", "mark", "u",
        "small", "big", "bdi", "bdo", "ruby", "rt", "rp", "wbr", "tbody", "thead",
        "tfoot", "caption", "colgroup", "col", "slot", "hgroup",
    ]

    public init(baseURL: URL? = nil) {
        self.baseURL = baseURL
    }

    /// Render a set of nodes, with empty lines separating the blocks.
    public func render(_ nodes: [HTMLNode]) -> String {
        normalize(renderBlocks(nodes).joined(separator: "\n\n"))
    }

    public func render(element: HTMLElement) -> String {
        render(element.children)
    }

    // MARK: - Block level

    private func renderBlocks(_ nodes: [HTMLNode]) -> [String] {
        var blocks: [String] = []
        var inlineBuffer = ""

        func flushInline() {
            let text = Self.cleanInline(inlineBuffer)
            inlineBuffer = ""
            guard !text.isEmpty else { return }
            blocks.append(text)
        }

        for node in nodes {
            switch node {
            case .text(let raw):
                inlineBuffer += HTMLText.collapseWhitespace(raw)

            case .element(let element):
                let name = element.name
                if Self.skippedTags.contains(name) { continue }

                // Transparent containers (div / section / article / main …): do not generate their own semantics,
                // But it must be recursive by 'blocks', otherwise internal headings, lists, and code blocks will be compressed into a single line.
                if Self.transparentTags.contains(name) {
                    flushInline()
                    blocks.append(contentsOf: renderBlocks(element.children))
                    continue
                }

                guard Self.isBlock(name) else {
                    inlineBuffer += renderInline(element)
                    continue
                }

                flushInline()
                switch name {
                case "h1", "h2", "h3", "h4", "h5", "h6":
                    let level = Int(String(name.dropFirst())) ?? 1
                    let text = Self.cleanInline(renderInline(element))
                    if !text.isEmpty {
                        blocks.append(String(repeating: "#", count: min(level, 6)) + " " + text)
                    }

                case "p":
                    let text = Self.cleanInline(renderInline(element))
                    if !text.isEmpty { blocks.append(text) }

                case "ul", "ol":
                    let list = renderList(element, ordered: name == "ol")
                    if !list.isEmpty { blocks.append(list) }

                case "blockquote":
                    let inner = renderBlocks(element.children).joined(separator: "\n\n")
                    if !inner.isEmpty { blocks.append(Self.quote(inner)) }

                case "pre":
                    if let code = Self.codeBlock(element) { blocks.append(code) }

                case "hr":
                    blocks.append("---")

                case "table":
                    if let table = renderTable(element) { blocks.append(table) }

                case "dl":
                    let definitionList = renderDefinitionList(element)
                    if !definitionList.isEmpty { blocks.append(definitionList) }

                case "figure":
                    blocks.append(contentsOf: renderFigure(element))

                default:
                    blocks.append(contentsOf: renderBlocks(element.children))
                }
            }
        }
        flushInline()
        return blocks.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Block-level tag determination: Remove transparent containers from the HTML block-level set, then add back the tags that actually generate block-level syntax.
    static func isBlock(_ name: String) -> Bool {
        let structural: Set<String> = [
            "p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li",
            "blockquote", "pre", "hr", "table", "dl", "figure",
        ]
        if structural.contains(name) { return true }
        return HTMLParser.blockLevelTags.contains(name) && !transparentTags.contains(name)
    }

    // MARK: - Inline

    private func renderInline(_ element: HTMLElement) -> String {
        var output = ""
        for node in element.children {
            switch node {
            case .text(let raw):
                output += HTMLText.collapseWhitespace(raw)
            case .element(let child):
                if Self.skippedTags.contains(child.name) { continue }
                switch child.name {
                case "br":
                    output += " "
                case "img":
                    output += Self.imageMarkdown(child, baseURL: baseURL)
                case "a":
                    output += linkMarkdown(child)
                case "strong", "b":
                    output += Self.wrap("**", renderInline(child))
                case "em", "i", "cite", "var":
                    output += Self.wrap("*", renderInline(child))
                case "del", "s", "strike":
                    output += Self.wrap("~~", renderInline(child))
                case "code", "kbd", "samp", "tt":
                    output += Self.inlineCode(Self.cleanInline(renderInline(child), collapse: false))
                default:
                    output += renderInline(child)
                }
            }
        }
        return output
    }

    private func linkMarkdown(_ element: HTMLElement) -> String {
        let label = Self.cleanInline(renderInline(element))
        guard let url = URLResolver.resolve(element.attribute("href"), base: baseURL),
              URLResolver.isRenderableLink(url) else {
            return label
        }
        // Only wrap one image link: keep it as an image (then you can wrap it again with a clickable link outside).
        if element.children.count == 1,
           case .element(let only) = element.children[0],
           only.name == "img" {
            return Self.imageMarkdown(only, baseURL: baseURL, linkURL: url)
        }
        guard !label.isEmpty else { return "<\(Self.escapeDestination(url.absoluteString))>" }
        return "[\(label)](\(Self.escapeDestination(url.absoluteString)))"
    }

    static func imageMarkdown(_ element: HTMLElement, baseURL: URL?, linkURL: URL? = nil) -> String {
        let alt = escapeText(element.attribute("alt") ?? element.attribute("title") ?? "")
        let source = element.attribute("src")
            ?? element.attribute("data-src")
            ?? element.attribute("data-original")
        guard let url = URLResolver.resolve(source, base: baseURL) else { return "" }
        let image = "![\(alt)](\(escapeDestination(url.absoluteString)))"
        guard let linkURL else { return image }
        return "[\(image)](\(escapeDestination(linkURL.absoluteString)))"
    }

    // MARK: - List / Table / Definition List

    private func renderList(_ element: HTMLElement, ordered: Bool) -> String {
        var position = Int(element.attribute("start") ?? "1") ?? 1
        var lines: [String] = []

        for node in element.children {
            guard case .element(let item) = node, item.name == "li" else { continue }
            let marker = ordered ? "\(position). " : "- "
            position += 1

            var checkbox = ""
            let blocks = renderBlocks(item.children)
            if let input = Self.firstDescendant(in: item, named: "input"),
               (input.attribute("type") ?? "").lowercased() == "checkbox" {
                checkbox = input.attribute("checked") == nil ? "[ ] " : "[x] "
            }

            let indent = String(repeating: " ", count: marker.count)
            let bodyLines = blocks.isEmpty
                ? [""]
                : blocks.flatMap { block in
                    block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                }
            lines.append(marker + checkbox + bodyLines[0])
            for line in bodyLines.dropFirst() {
                lines.append(line.isEmpty ? "" : indent + line)
            }
        }
        return lines.joined(separator: "\n")
    }

    private func renderTable(_ element: HTMLElement) -> String? {
        let rows = Self.descendants(of: element, named: "tr")
        guard !rows.isEmpty else { return nil }

        let rendered: [[String]] = rows.map { row in
            Self.directChildren(of: row, named: ["td", "th"]).map { cell in
                Self.cleanInline(renderBlocks(cell.children).joined(separator: " "))
            }
        }
        guard let header = rendered.first, !header.isEmpty else { return nil }

        let columnCount = max(header.count, rendered.map(\.count).max() ?? 0)
        func padded(_ cells: [String]) -> [String] {
            cells.map { $0.replacingOccurrences(of: "|", with: "\\|") }
                + Array(repeating: "", count: max(0, columnCount - cells.count))
        }

        var lines = ["| " + padded(header).joined(separator: " | ") + " |"]
        lines.append("| " + Array(repeating: "---", count: columnCount).joined(separator: " | ") + " |")
        for row in rendered.dropFirst() {
            lines.append("| " + padded(row).joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    private func renderDefinitionList(_ element: HTMLElement) -> String {
        var lines: [String] = []
        for node in element.children {
            guard case .element(let child) = node else { continue }
            switch child.name {
            case "dt":
                let term = Self.cleanInline(renderBlocks(child.children).joined(separator: " "))
                if !term.isEmpty { lines.append("- **\(term)**") }
            case "dd":
                let definition = Self.cleanInline(renderBlocks(child.children).joined(separator: " "))
                if !definition.isEmpty { lines.append("  \(definition)") }
            default:
                break
            }
        }
        return lines.joined(separator: "\n")
    }

    private func renderFigure(_ element: HTMLElement) -> [String] {
        var blocks: [String] = []
        let media = element.children.filter { node in
            guard case .element(let child) = node else { return false }
            return child.name == "img" || child.name == "picture"
        }
        if !media.isEmpty {
            let markdown = Self.cleanInline(
                renderInline(HTMLElement(name: "figure-inline", children: media))
            )
            if !markdown.isEmpty { blocks.append(markdown) }
        }
        for node in element.children {
            guard case .element(let caption) = node, caption.name == "figcaption" else { continue }
            let text = Self.cleanInline(renderBlocks(caption.children).joined(separator: " "))
            if !text.isEmpty { blocks.append("*\(text)*") }
        }
        return blocks.isEmpty ? renderBlocks(element.children) : blocks
    }

    // MARK: - Tool

    static func codeBlock(_ element: HTMLElement) -> String? {
        let code = firstDescendant(in: element, named: "code") ?? element
        let text = code.textContent.trimmingCharacters(in: .newlines)
        guard !text.isEmpty else { return nil }
        return "```\(languageHint(code) ?? "")\n\(text)\n```"
    }

    static func languageHint(_ element: HTMLElement) -> String? {
        for className in element.classNames {
            for prefix in ["language-", "lang-", "highlight-"] where className.hasPrefix(prefix) {
                return String(className.dropFirst(prefix.count))
            }
        }
        return element.attribute("data-language")
    }

    static func quote(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? ">" : "> \($0)" }
            .joined(separator: "\n")
    }

    /// Emphasis marker: leave the leading and trailing spaces outside the marker to avoid producing invalid syntax like `** bold **`.
    static func wrap(_ marker: String, _ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let leading = String(text.prefix { $0.isWhitespace })
        let trailing = String(text.reversed().prefix { $0.isWhitespace }.reversed())
        return "\(leading)\(marker)\(trimmed)\(marker)\(trailing)"
    }

    static func inlineCode(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let fence = trimmed.contains("`") ? "``" : "`"
        return "\(fence)\(trimmed)\(fence)"
    }

    static func cleanInline(_ text: String, collapse: Bool = true) -> String {
        guard collapse else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        var value = HTMLText.collapseWhitespace(text)
        value = value.replacingOccurrences(of: "\n", with: " ")
        while value.contains("  ") {
            value = value.replacingOccurrences(of: "  ", with: " ")
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func escapeText(_ raw: String) -> String {
        var output = ""
        output.reserveCapacity(raw.count)
        for character in raw {
            if ["*", "_", "`", "[", "]", "|"].contains(character) {
                output.append("\\")
            }
            output.append(character)
        }
        return output
    }

    static func escapeDestination(_ raw: String) -> String {
        raw.replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
            .replacingOccurrences(of: " ", with: "%20")
    }

    static func firstDescendant(in element: HTMLElement, named name: String) -> HTMLElement? {
        for node in element.children {
            guard case .element(let child) = node else { continue }
            if child.name == name { return child }
            if let found = firstDescendant(in: child, named: name) { return found }
        }
        return nil
    }

    static func descendants(of element: HTMLElement, named name: String) -> [HTMLElement] {
        var results: [HTMLElement] = []
        for node in element.children {
            guard case .element(let child) = node else { continue }
            if child.name == name { results.append(child) }
            results.append(contentsOf: descendants(of: child, named: name))
        }
        return results
    }

    static func directChildren(of element: HTMLElement, named names: Set<String>) -> [HTMLElement] {
        element.children.compactMap { node in
            guard case .element(let child) = node, names.contains(child.name) else { return nil }
            return child
        }
    }

    /// Trim whitespace: remove trailing spaces and compress consecutive blank lines into a single blank line.
    private func normalize(_ markdown: String) -> String {
        var lines: [String] = []
        var previousBlank = false
        let normalizedNewlines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        for rawLine in normalizedNewlines.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).replacingOccurrences(
                of: "[ \\t]+$",
                with: "",
                options: .regularExpression
            )
            let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if isBlank && previousBlank { continue }
            lines.append(line)
            previousBlank = isBlank
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Relative URL parsing and renderability determination.
public enum URLResolver {
    public static func resolve(_ raw: String?, base: URL?) -> URL? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()
        // Discard script protocols and inline data (data: Images are large in size and not suitable for archival references).
        guard !lowered.hasPrefix("javascript:"), !lowered.hasPrefix("data:") else { return nil }
        if lowered.hasPrefix("mailto:") || lowered.hasPrefix("tel:") {
            return URL(string: trimmed)
        }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        guard let base else { return URL(string: trimmed) }
        return URL(string: trimmed, relativeTo: base)?.absoluteURL
    }

    public static func isRenderableLink(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto", "tel": true
        default: false
        }
    }
}
