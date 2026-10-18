import Foundation

/// Markdown → Notion Block conversion.
///
/// Pure functions, with no network dependency, so the generated JSON structure can be asserted item by item.
/// Supports: titles, paragraphs, bullet lists, numbered lists, to-dos, blockquotes, code blocks, dividers, images, inline bold/italic/code/links.
public enum NotionBlocks {
    /// Character limit for a single rich_text content in Notion.
    public static let maxRichTextCharacters = 2000
    /// The maximum number of blocks that can be submitted in a single request.
    public static let maxBlocksPerRequest = 100

    public static func blocks(fromMarkdown markdown: String, upstreamURL: URL? = nil) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var inCodeFence = false

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            paragraph.removeAll()
            guard !text.isEmpty else { return }
            blocks.append(paragraphBlock(text))
        }

        for rawLine in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                if inCodeFence {
                    blocks.append(codeBlock(codeLines.joined(separator: "\n"), language: codeLanguage))
                    codeLines.removeAll()
                    codeLanguage = nil
                    inCodeFence = false
                } else {
                    flushParagraph()
                    inCodeFence = true
                    let info = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    codeLanguage = info.isEmpty ? nil : info
                }
                continue
            }
            if inCodeFence {
                codeLines.append(rawLine)
                continue
            }

            if line.isEmpty {
                flushParagraph()
                continue
            }
            if line == "---" || line == "***" || line == "___" {
                flushParagraph()
                blocks.append(["object": "block", "type": "divider", "divider": [:]])
                continue
            }
            if let heading = headingBlock(line) {
                flushParagraph()
                blocks.append(heading)
                continue
            }
            if let todo = todoBlock(line) {
                flushParagraph()
                blocks.append(todo)
                continue
            }
            if let bullet = listBlock(line, type: "bulleted_list_item") {
                flushParagraph()
                blocks.append(bullet)
                continue
            }
            if let numbered = numberedListBlock(line) {
                flushParagraph()
                blocks.append(numbered)
                continue
            }
            if let quote = blockquoteBlock(line) {
                flushParagraph()
                blocks.append(quote)
                continue
            }
            if let image = imageBlock(line) {
                flushParagraph()
                blocks.append(image)
                continue
            }
            paragraph.append(line)
        }

        if inCodeFence, !codeLines.isEmpty {
            blocks.append(codeBlock(codeLines.joined(separator: "\n"), language: codeLanguage))
        }
        flushParagraph()

        if let upstreamURL {
            // Cross-cloud cascading: Write the direct link returned by the front-end cloud drive as a clickable paragraph in the Body.
            blocks.append(paragraphBlock(
                "Cloud file: \(upstreamURL.absoluteString)",
                link: upstreamURL
            ))
        }
        return blocks
    }

    // MARK: - Block level

    static func paragraphBlock(_ text: String, link: URL? = nil) -> [String: Any] {
        [
            "object": "block",
            "type": "paragraph",
            "paragraph": ["rich_text": richText(text, link: link)],
        ]
    }

    static func headingBlock(_ line: String) -> [String: Any]? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes <= 6 else { return nil }
        let content = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return nil }
        let type = "heading_\(min(hashes, 3))"
        return [
            "object": "block",
            "type": type,
            type: ["rich_text": richText(content)],
        ]
    }

    static func todoBlock(_ line: String) -> [String: Any]? {
        let lowered = line.lowercased()
        let checked: Bool
        let content: String
        if lowered.hasPrefix("- [x] ") || lowered.hasPrefix("* [x] ") {
            checked = true
            content = String(line.dropFirst(6))
        } else if lowered.hasPrefix("- [ ] ") || lowered.hasPrefix("* [ ] ") {
            checked = false
            content = String(line.dropFirst(6))
        } else {
            return nil
        }
        return [
            "object": "block",
            "type": "to_do",
            "to_do": ["rich_text": richText(content), "checked": checked],
        ]
    }

    static func listBlock(_ line: String, type: String) -> [String: Any]? {
        let prefixes = ["- ", "* ", "+ "]
        guard let prefix = prefixes.first(where: { line.hasPrefix($0) }) else { return nil }
        let content = String(line.dropFirst(prefix.count))
        guard !content.isEmpty else { return nil }
        return [
            "object": "block",
            "type": type,
            type: ["rich_text": richText(content)],
        ]
    }

    static func numberedListBlock(_ line: String) -> [String: Any]? {
        guard let match = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) else { return nil }
        let content = String(line[match.upperBound...])
        guard !content.isEmpty else { return nil }
        return [
            "object": "block",
            "type": "numbered_list_item",
            "numbered_list_item": ["rich_text": richText(content)],
        ]
    }

    static func blockquoteBlock(_ line: String) -> [String: Any]? {
        guard line.hasPrefix("> ") || line == ">" else { return nil }
        let content = line == ">" ? "" : String(line.dropFirst(2))
        guard !content.isEmpty else { return nil }
        return [
            "object": "block",
            "type": "quote",
            "quote": ["rich_text": richText(content)],
        ]
    }

    static func codeBlock(_ code: String, language: String?) -> [String: Any] {
        var payload: [String: Any] = ["rich_text": richText(code, code: true)]
        if let language, !language.isEmpty {
            payload["language"] = notionLanguage(language)
        }
        return ["object": "block", "type": "code", "code": payload]
    }

    static func imageBlock(_ line: String) -> [String: Any]? {
        guard line.hasPrefix("![") , let close = line.firstIndex(of: "]") else { return nil }
        let alt = String(line[line.index(after: line.startIndex)..<close])
        let remainder = line[line.index(after: close)...]
        guard remainder.hasPrefix("("), remainder.hasSuffix(")") else { return nil }
        let urlText = String(remainder.dropFirst().dropLast())
        guard let url = URL(string: urlText), url.scheme?.hasPrefix("http") == true else { return nil }
        return [
            "object": "block",
            "type": "image",
            "image": [
                "type": "external",
                "external": ["url": url.absoluteString],
                "caption": alt.isEmpty ? [] : richText(alt),
            ],
        ]
    }

    /// Notion only accepts language identifiers that it supports; any unknown ones fall back to `plain text`.
    static func notionLanguage(_ raw: String) -> String {
        let known: Set<String> = [
            "abap", "arduino", "bash", "basic", "c", "clojure", "coffeescript", "c++", "c#",
            "css", "dart", "diff", "docker", "elixir", "elm", "erlang", "flow", "fortran",
            "f#", "gherkin", "git", "glsl", "go", "graphql", "groovy", "haskell", "html",
            "java", "javascript", "json", "julia", "kotlin", "latex", "less", "lisp", "lua",
            "makefile", "markdown", "matlab", "mermaid", "nginx", "objective-c", "ocaml",
            "pascal", "perl", "php", "plain text", "powershell", "protobuf", "python", "r",
            "reason", "ruby", "rust", "sass", "scala", "scheme", "scss", "shell", "sql",
            "swift", "typescript", "vb.net", "verilog", "vhdl", "visual basic", "webassembly",
            "xml", "yaml",
        ]
        let lowered = raw.lowercased()
        if known.contains(lowered) { return lowered }
        if lowered == "js" { return "javascript" }
        if lowered == "ts" { return "typescript" }
        if lowered == "py" { return "python" }
        if lowered == "sh" || lowered == "zsh" { return "shell" }
        if lowered == "yml" { return "yaml" }
        return "plain text"
    }

    // MARK: - Inline

    /// Convert inline Markdown to a rich_text array and split it into 2000-character segments.
    public static func richText(
        _ text: String,
        link: URL? = nil,
        bold: Bool = false,
        italic: Bool = false,
        code: Bool = false
    ) -> [[String: Any]] {
        let segments = inlineSegments(text, inherited: (link, bold, italic, code))
        var objects: [[String: Any]] = []
        for segment in segments {
            for chunk in chunk(segment.text, size: maxRichTextCharacters) {
                var entry: [String: Any] = [
                    "type": "text",
                    "text": ["content": chunk],
                    "annotations": [
                        "bold": segment.bold,
                        "italic": segment.italic,
                        "strikethrough": false,
                        "underline": false,
                        "code": segment.code,
                        "color": "default",
                    ],
                ]
                if let url = segment.link {
                    entry["text"] = ["content": chunk, "link": ["url": url.absoluteString]]
                }
                objects.append(entry)
            }
        }
        return objects
    }

    struct Segment: Equatable {
        var text: String
        var link: URL?
        var bold = false
        var italic = false
        var code = false
    }

    /// Minimal inline parsing: recognize `**bold**`, `*italic*`, `` `code` ``, `[Text](Link)`.
    /// Nested structures are not supported (sufficient and behavior is predictable).
    static func inlineSegments(
        _ text: String,
        inherited: (link: URL?, bold: Bool, italic: Bool, code: Bool)
    ) -> [Segment] {
        var segments: [Segment] = []
        var buffer = ""

        func flush() {
            guard !buffer.isEmpty else { return }
            segments.append(Segment(
                text: buffer,
                link: inherited.link,
                bold: inherited.bold,
                italic: inherited.italic,
                code: inherited.code
            ))
            buffer = ""
        }

        var index = text.startIndex
        while index < text.endIndex {
            let remainder = text[index...]

            if remainder.hasPrefix("**"), let end = text.range(of: "**", range: text.index(index, offsetBy: 2)..<text.endIndex) {
                flush()
                let inner = String(text[text.index(index, offsetBy: 2)..<end.lowerBound])
                segments.append(contentsOf: inlineSegments(inner, inherited: (inherited.link, true, inherited.italic, false)))
                index = end.upperBound
                continue
            }
            if remainder.hasPrefix("`"), let end = text.range(of: "`", range: text.index(after: index)..<text.endIndex) {
                flush()
                let inner = String(text[text.index(after: index)..<end.lowerBound])
                segments.append(Segment(text: inner, link: inherited.link, bold: inherited.bold, italic: inherited.italic, code: true))
                index = end.upperBound
                continue
            }
            if remainder.hasPrefix("["), let close = text.range(of: "](", range: index..<text.endIndex),
               let end = text.range(of: ")", range: close.upperBound..<text.endIndex) {
                let label = String(text[text.index(after: index)..<close.lowerBound])
                let rawURL = String(text[close.upperBound..<end.lowerBound])
                flush()
                let link = URL(string: rawURL)
                segments.append(Segment(
                    text: label,
                    link: link ?? inherited.link,
                    bold: inherited.bold,
                    italic: inherited.italic,
                    code: false
                ))
                index = end.upperBound
                continue
            }
            if remainder.hasPrefix("*"), !remainder.hasPrefix("**"),
               let end = text.range(of: "*", range: text.index(after: index)..<text.endIndex) {
                flush()
                let inner = String(text[text.index(after: index)..<end.lowerBound])
                segments.append(contentsOf: inlineSegments(inner, inherited: (inherited.link, inherited.bold, true, false)))
                index = end.upperBound
                continue
            }

            buffer.append(text[index])
            index = text.index(after: index)
        }
        flush()
        return segments
    }

    static func chunk(_ text: String, size: Int) -> [String] {
        guard text.count > size else { return [text] }
        var result: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[start..<end]))
            start = end
        }
        return result
    }
}
