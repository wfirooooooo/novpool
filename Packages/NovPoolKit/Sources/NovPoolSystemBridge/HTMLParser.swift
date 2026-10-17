import Foundation

// MARK: - 轻量 DOM

/// 极简 HTML 文档树。只保留正文提取与 Markdown 渲染所需的信息。
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

    /// 递归收集纯文本（HTML 语义：块级之间补空白）。
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

// MARK: - 解析器

/// 容错 HTML 解析器。
///
/// 不追求 HTML5 规范的完整实现，只保证正文型页面的树结构正确：
/// 处理 void 元素、常见隐式闭合、未闭合标签、注释、`script/style` 原始文本与实体转义。
public struct HTMLParser: Sendable {
    public init() {}

    static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr",
    ]

    /// 内容不应参与正文/渲染的原始文本元素。
    static let rawTextSkipElements: Set<String> = ["script", "style", "noscript", "iframe", "svg", "template"]

    static let blockLevelTags: Set<String> = [
        "address", "article", "aside", "blockquote", "details", "div", "dl", "dd", "dt",
        "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5",
        "h6", "header", "hr", "li", "main", "nav", "ol", "p", "pre", "section", "summary",
        "table", "tbody", "td", "tfoot", "th", "thead", "tr", "ul",
    ]

    /// 新标签出现时的隐式闭合表。
    ///
    /// 语义是「打开 X 时，若栈顶是集合中的元素就闭合它」——方向很关键：
    /// 是 `p` 被下一个 `p` 闭合，而不是 `p` 去闭合 `article`。
    /// 另外任何块级标签都会闭合正处于打开状态的 `p`（见 `closableOnOpen`）。
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

    /// 打开 `name` 前需要闭合的栈顶元素集合。
    static func closableOnOpen(_ name: String) -> Set<String> {
        var closable = autoCloseOnOpen[name] ?? []
        if blockLevelTags.contains(name) { closable.insert("p") }
        return closable
    }

    /// 解析完整文档，返回合成根节点 `<document>`。
    public func parse(_ html: String) -> HTMLElement {
        let builder = HTMLTreeBuilder()
        return builder.build(Self.tokens(from: html), rootName: "document").converted()
    }

    /// 解析 HTML 片段（用于 P3 拖拽的 `.html` 表示层）。
    public func parseFragment(_ html: String) -> [HTMLNode] {
        let builder = HTMLTreeBuilder()
        let root = builder.build(Self.tokens(from: html), rootName: "fragment")
        return root.converted().children
    }

    // MARK: - 词法

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

            // 注释 / doctype / CDATA 直接跳过
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

            // script / style 等原始文本元素：内容整体跳过
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

// MARK: - 构建期节点

/// 构建期使用的引用型节点。
///
/// 必须用引用类型：值类型节点放进解析栈后拿到的是副本，给副本追加子节点不会影响
/// 父节点里那一份，出栈时整棵子树就丢了。这里先建引用树，最后一次性转成值类型。
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

/// 容错建树：处理 void 元素、隐式闭合、未闭合标签，并限制总节点数与嵌套深度。
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
                // 未闭合的中间标签一并出栈（浏览器同样会隐式闭合）。
                stack.removeSubrange(index...)
            }
        }
        return root
    }
}

// MARK: - 实体

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

    /// HTML 空白折叠：连续空白（含换行、制表、全角空格）压成单个半角空格。
    /// 首尾空白也会折叠成一个空格（由调用方 trim），否则 `<b>a</b> b` 这类
    /// 跨节点的词间空格会被吞掉。
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
