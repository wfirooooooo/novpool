import Foundation

// MARK: - Lightweight DOM

/// Minimal HTML Document tree. Only retain the information needed for Body extraction and Markdown rendering.
public enum HTMLNode: Sendable, Equatable {
    case element(HTMLElement)
    case text(String)
}

public struct HTMLElement: Sendable, Equatable {
    public var name: String
    public var attributes: [String: String]
    public var children: [HTMLNode]

    public init(name: String, attributes: [String: String] = [:], children: [HTMLNode] = []) {
        self.name = name
        self.attributes = attributes
        self.children = children
    }

    public func attribute(_ key: String) -> String? {
        attributes[key.lowercased()]
    }

    public var id: String? { attribute("id") }

    public var classNames: [String] {
        (attribute("class") ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
    }

    public func hasClass(matching needle: String) -> Bool {
        classNames.contains { $0.lowercased().contains(needle) }
    }

    /// Recursively collect Plain Text (HTML Semantic: insert spaces between block-level elements).
    public var textContent: String {
        var output = ""
        collectText(into: &output)
        return output
    }

    private func collectText(into output: inout String) {
        for child in children {
            switch child {
            case .text(let value):
                output += value
            case .element(let element):
                if HTMLParser.voidElements.contains(element.name) {
                    if element.name == "br" { output += " " }
                    continue
                }
                if HTMLParser.blockLevelTags.contains(element.name) {
                    output += " "
                }
                element.collectText(into: &output)
            }
        }
    }
}

// MARK: - Parser

/// Fault-tolerant HTML parser.
///
/// Do not pursue a complete implementation of the HTML5 specification, only ensure that the tree structure of Body-type pages is correct:
/// Handle void elements, common implicit closures, unclosed tags, comments, `script/style` raw text, and entity escaping.
public struct HTMLParser: Sendable {
    public init() {}

    static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr",
    ]

    /// Content should not be included in the Body/raw Text elements for rendering.
    static let rawTextSkipElements: Set<String> = ["script", "style", "noscript", "iframe", "svg", "template"]

    static let blockLevelTags: Set<String> = [
        "address", "article", "aside", "blockquote", "details", "div", "dl", "dd", "dt",
        "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5",
        "h6", "header", "hr", "li", "main", "nav", "ol", "p", "pre", "section", "summary",
        "table", "tbody", "td", "tfoot", "th", "thead", "tr", "ul",
    ]

    /// Implicitly closed table when a new tag appears.
    ///
    /// Semantic is 'When opening X, if the top of the stack is an element in the set, then close it' — the direction is very important:
    /// It is the `p` that is closed by the next `p`, not the `p` that closes the `article`.
    /// In addition, any block-level tag will close a `p` that is currently in an open state (see `closableOnOpen`).
    static let autoCloseOnOpen: [String: Set<String>] = [
        "p": ["p"],
        "li": ["li"],
        "dt": ["dt", "dd"],
        "dd": ["dt", "dd"],
        "tr": ["tr"],
        "td": ["td", "th"],
        "th": ["td", "th"],
        "option": ["option"],
    ]

    /// The set of top-of-stack elements that need to be closed before opening `name`.
    static func closableOnOpen(_ name: String) -> Set<String> {
        var closable = autoCloseOnOpen[name] ?? []
        if blockLevelTags.contains(name) { closable.insert("p") }
        return closable
    }

    /// Parse the complete document and return the composite root node `<document>`.
    public func parse(_ html: String) -> HTMLElement {
        let builder = HTMLTreeBuilder()
        return builder.build(Self.tokens(from: html), rootName: "document").converted()
    }

    /// Parse HTML fragments (for the `.html` representation layer used in P3 drag-and-drop).
    public func parseFragment(_ html: String) -> [HTMLNode] {
        let builder = HTMLTreeBuilder()
        let root = builder.build(Self.tokens(from: html), rootName: "fragment")
        return root.converted().children
    }

    // MARK: - Lexical

    enum Token: Equatable {
        case text(String)
        case startTag(String, [String: String], Bool)
        case endTag(String)
    }

    static func tokens(from html: String) -> [Token] {
        var tokens: [Token] = []
        var index = html.startIndex

        func isAtEnd(_ position: String.Index) -> Bool { position >= html.endIndex }

        while index < html.endIndex {
            guard let open = html[index...].firstIndex(of: "<") else {
                let tail = String(html[index...])
                appendText(tail, to: &tokens)
                break
            }
            if open > index {
                appendText(String(html[index..<open]), to: &tokens)
            }
            guard open < html.endIndex else { break }

            // Comments / doctype / CDATA are skipped directly
            if html[open...].hasPrefix("<!--") {
                if let end = html.range(of: "-->", range: html.index(open, offsetBy: 4)..<html.endIndex) {
                    index = end.upperBound
                } else {
                    break
                }
                continue
            }
            if html[open...].hasPrefix("<!") {
                if let end = html[open...].firstIndex(of: ">") {
                    index = html.index(after: end)
                } else {
                    break
                }
                continue
            }

            guard let close = html[open...].firstIndex(of: ">") else {
                appendText(String(html[open...]), to: &tokens)
                break
            }
            let rawTag = String(html[html.index(after: open)..<close])
            index = html.index(after: close)

            if rawTag.hasPrefix("/") {
                let name = rawTag.dropFirst().trimmingCharacters(in: .whitespaces).lowercased()
                if !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == ":" }) {
                    tokens.append(.endTag(name))
                } else if let spaceIndex = name.firstIndex(where: \.isWhitespace) {
                    tokens.append(.endTag(String(name[..<spaceIndex])))
                }
                continue
            }

            let isSelfClosing = rawTag.hasSuffix("/")
            let body = isSelfClosing ? String(rawTag.dropLast()) : rawTag
            let (name, attributes) = parseTagBody(body)
            guard !name.isEmpty else { continue }
            tokens.append(.startTag(name, attributes, isSelfClosing))

            // Original text elements such as script/style: skip the entire content
            if !isSelfClosing, rawTextSkipElements.contains(name) {
                let closingTag = "</\(name)"
                if let end = html[index...].range(of: closingTag, options: .caseInsensitive) {
                    index = end.upperBound
                    if let gt = html[index...].firstIndex(of: ">") {
                        index = html.index(after: gt)
                    }
                    tokens.append(.endTag(name))
                } else {
                    index = html.endIndex
                    tokens.append(.endTag(name))
                }
            }
        }
        return tokens
    }

    private static func appendText(_ raw: String, to tokens: inout [Token]) {
        guard !raw.isEmpty else { return }
        tokens.append(.text(HTMLText.decodeEntities(raw)))
    }

    static func parseTagBody(_ body: String) -> (name: String, attributes: [String: String]) {
        var name = ""
        var attributes: [String: String] = [:]
        var index = body.startIndex

        while index < body.endIndex, body[index].isWhitespace { index = body.index(after: index) }
        while index < body.endIndex, !body[index].isWhitespace {
            name.append(body[index].lowercased())
            index = body.index(after: index)
        }

        while index < body.endIndex {
            while index < body.endIndex, body[index].isWhitespace { index = body.index(after: index) }
            guard index < body.endIndex else { break }

            var key = ""
            while index < body.endIndex, !body[index].isWhitespace, body[index] != "=" {
                key.append(body[index].lowercased())
                index = body.index(after: index)
            }
            guard !key.isEmpty else {
                index = body.index(after: index)
                continue
            }

            var value = ""
            if index < body.endIndex, body[index] == "=" {
                index = body.index(after: index)
                if index < body.endIndex, body[index] == "\"" || body[index] == "'" {
                    let quote = body[index]
                    index = body.index(after: index)
                    while index < body.endIndex, body[index] != quote {
                        value.append(body[index])
                        index = body.index(after: index)
                    }
                    if index < body.endIndex { index = body.index(after: index) }
                } else {
                    while index < body.endIndex, !body[index].isWhitespace {
                        value.append(body[index])
                        index = body.index(after: index)
                    }
                }
            }
            attributes[key] = HTMLText.decodeEntities(value)
        }

        return (name, attributes)
    }
}

// MARK: - Construction Phase Milestone

/// Reference-type nodes used during the build phase.
///
/// You must use reference types: when a value type node is put into the parse stack, what you get is a copy, and adding child nodes to the copy will not have any effect.
/// The part in the parent node—when it is popped, the entire subtree is lost. Here, we first build a reference tree, and finally convert it to a value type all at once.
final class RawElement {
    let name: String
    let attributes: [String: String]
    let depth: Int
    var children: [RawChild] = []

    init(name: String, attributes: [String: String] = [:], depth: Int = 0) {
        self.name = name
        self.attributes = attributes
        self.depth = depth
    }

    func converted() -> HTMLElement {
        HTMLElement(
            name: name,
            attributes: attributes,
            children: children.map { child in
                switch child {
                case .text(let value): .text(value)
                case .element(let element): .element(element.converted())
                }
            }
        )
    }
}

enum RawChild {
    case element(RawElement)
    case text(String)
}

/// Fault-tolerant tree construction: handles void elements, implicit closures, unclosed tags, and limits the total number of nodes and nesting depth.
final class HTMLTreeBuilder {
    static let maxNodes = 200_000
    static let maxDepth = 256

    func build(_ tokens: [HTMLParser.Token], rootName: String) -> RawElement {
        let root = RawElement(name: rootName)
        var stack: [RawElement] = [root]
        var nodeCount = 0

        for token in tokens {
            switch token {
            case .text(let value):
                stack[stack.count - 1].children.append(.text(value))

            case .startTag(let name, let attributes, let isSelfClosing):
                guard nodeCount < Self.maxNodes else { continue }
                let closable = HTMLParser.closableOnOpen(name)
                while !closable.isEmpty, stack.count > 1, closable.contains(stack[stack.count - 1].name) {
                    stack.removeLast()
                }
                let element = RawElement(name: name, attributes: attributes, depth: stack.count)
                nodeCount += 1
                stack[stack.count - 1].children.append(.element(element))
                if !isSelfClosing,
                   !HTMLParser.voidElements.contains(name),
                   stack.count < Self.maxDepth {
                    stack.append(element)
                }

            case .endTag(let name):
                guard let index = stack.lastIndex(where: { $0.name == name }), index > 0 else { continue }
                // Unclosed intermediate tags are also popped from the stack (browsers will implicitly close them as well).
                stack.removeSubrange(index...)
            }
        }
        return root
    }
}

// MARK: - Entity

enum HTMLText {
    static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "hellip": "…", "mdash": "—", "ndash": "–", "rsquo": "’", "lsquo": "‘",
        "ldquo": "“", "rdquo": "”", "middot": "·", "times": "×", "copy": "©",
        "reg": "®", "trade": "™", "laquo": "«", "raquo": "»", "deg": "°",
    ]

    static func decodeEntities(_ raw: String) -> String {
        guard raw.contains("&") else { return raw }
        var output = ""
        output.reserveCapacity(raw.count)
        var index = raw.startIndex

        while index < raw.endIndex {
            guard raw[index] == "&",
                  let semicolon = raw[index...].firstIndex(of: ";"),
                  raw.distance(from: index, to: semicolon) <= 12 else {
                output.append(raw[index])
                index = raw.index(after: index)
                continue
            }
            let entity = String(raw[raw.index(after: index)..<semicolon])
            if let decoded = decode(entity) {
                output += decoded
                index = raw.index(after: semicolon)
            } else {
                output.append(raw[index])
                index = raw.index(after: index)
            }
        }
        return output
    }

    static func decode(_ entity: String) -> String? {
        if entity.hasPrefix("#") {
            let digits = entity.dropFirst()
            let value: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits)
            }
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }
        return namedEntities[entity.lowercased()]
    }

    /// HTML whitespace collapsing: consecutive whitespace (including line breaks, tabs, full-width spaces) is compressed into a single half-width space.
    /// Leading and trailing spaces will also be collapsed into a single space (trimmed by the caller), otherwise `<b>a</b> b>` like this
    /// Whitespace between words across nodes will be swallowed.
    static func collapseWhitespace(_ raw: String) -> String {
        var output = ""
        var pendingSpace = false
        for character in raw {
            if character.isWhitespace || character == "\u{00A0}" {
                pendingSpace = true
            } else {
                if pendingSpace {
                    output.append(" ")
                    pendingSpace = false
                }
                output.append(character)
            }
        }
        if pendingSpace { output.append(" ") }
        return output
    }
}
