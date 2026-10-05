//
//  HTMLDocument.swift
//  SourceEngine
//
//  极简 HTML 解析与 DOM 模型（零第三方依赖）。
//
//  为什么自己写：源脚本最常用的能力就是「取回 HTML → 用 CSS 选择器提取字段」。
//  引第三方解析器会给包引入外部依赖与供应链风险（见开发手册的依赖策略），
//  而源需要的子集其实很小：标签 / 属性 / 文本 / 注释跳过。
//
//  明确**不做**的事（避免复杂度失控）：
//  - 不做 HTML5 的容错纠错（不猜测未闭合标签的归属，按栈结构收尾）；
//  - 不支持 `<table>` 的隐式标签补全、`<template>` 内容等特殊规则；
//  - 文本统一折叠空白（`&nbsp;` 也视为空格），源作者需要原文时可用 `html` 字段。
//
//  解析结果构建成「带稳定编号」的元素树：编号用于选择器结果的去重。
//

import Foundation

// MARK: - 节点

/// DOM 节点。
public indirect enum HTMLNode: Equatable, Sendable {
    case element(HTMLElement)
    case text(String)

    public var asElement: HTMLElement? {
        if case let .element(element) = self { return element }
        return nil
    }

    public var textContent: String {
        switch self {
        case let .text(value): return value
        case let .element(element): return element.textContent
        }
    }
}

/// 元素。
public struct HTMLElement: Equatable, Sendable {
    /// 解析时分配的稳定编号（用于结果去重与排序）。
    public let nodeID: Int
    /// 小写标签名。
    public let tag: String
    /// 属性（键为小写；HTML 属性名大小写不敏感）。
    public let attributes: [String: String]
    public let children: [HTMLNode]

    public init(nodeID: Int, tag: String, attributes: [String: String], children: [HTMLNode]) {
        self.nodeID = nodeID
        self.tag = tag
        self.attributes = attributes
        self.children = children
    }

    public var id: String? { attributes["id"] }

    /// class 列表（按空白切分，忽略空项）。
    public var classes: [String] {
        guard let raw = attributes["class"] else { return [] }
        return raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// 文本内容（递归拼接并折叠空白）。
    public var textContent: String {
        HTMLText.collapseWhitespace(children.map(\.textContent).joined())
    }

    /// 直属子元素。
    public var childElements: [HTMLElement] {
        children.compactMap(\.asElement)
    }

    /// 自身 + 全部后代（前序）。
    public var descendantsAndSelf: [HTMLElement] {
        var result: [HTMLElement] = [self]
        for child in childElements {
            result.append(contentsOf: child.descendantsAndSelf)
        }
        return result
    }

    /// 全部后代（前序，不含自身）。
    public var descendants: [HTMLElement] {
        childElements.flatMap(\.descendantsAndSelf)
    }

    /// 取出某个属性的值。
    public func attribute(_ name: String) -> String? {
        attributes[name.lowercased()]
    }

    /// 序列化为 HTML 文本（调试与「原样取一段」时用；不保证与输入逐字一致）。
    public var outerHTML: String {
        var output = "<\(tag)"
        for key in attributes.keys.sorted() {
            let value = attributes[key] ?? ""
            output += " \(key)=\"\(value.replacingOccurrences(of: "\"", with: "&quot;"))\""
        }
        if children.isEmpty, HTMLParser.voidTags.contains(tag) {
            return output + ">"
        }
        output += ">"
        for child in children {
            switch child {
            case let .text(value): output += HTMLText.escape(value)
            case let .element(element): output += element.outerHTML
            }
        }
        return output + "</\(tag)>"
    }
}

// MARK: - 文档

/// 解析后的文档。
public struct HTMLDocument: Sendable {
    /// 文档根（`tag` 为 `#document`，不是真实元素）。
    public let root: HTMLElement
    /// 原始文本长度（诊断用）。
    public let sourceLength: Int

    /// 用选择器查询。
    public func select(_ selector: String) throws -> [HTMLElement] {
        try CSSSelectorEngine.select(selector, in: root)
    }

    /// 只取第一个匹配。
    public func selectFirst(_ selector: String) throws -> HTMLElement? {
        try CSSSelectorEngine.selectFirst(selector, in: root)
    }
}

// MARK: - 解析器

public enum HTMLParser {

    /// 自闭合（void）标签：不进入栈，也不需要结束标签。
    public static let voidTags: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr",
    ]

    /// 内容按原样保留（不解析内部标签）的标签。
    static let rawTextTags: Set<String> = ["script", "style"]

    /// 解析 HTML 文本。
    ///
    /// 容错策略：遇到不匹配的结束标签就忽略；文本结束时仍在栈里的标签自动闭合。
    public static func parse(_ html: String) -> HTMLDocument {
        var builder = TreeBuilder()
        var index = html.startIndex
        var pendingText = ""
        /// 当前处于 raw text 的标签（script/style）。
        var rawTextTag: String?

        func flushText() {
            guard !pendingText.isEmpty else { return }
            builder.appendText(pendingText)
            pendingText = ""
        }

        while index < html.endIndex {
            let character = html[index]

            if let tag = rawTextTag {
                // raw text 模式：一直读到对应的结束标签
                if character == "<", html[index...].hasPrefix("</\(tag)") {
                    flushText()
                    let closeEnd = html[index...].firstIndex(of: ">") ?? html.endIndex
                    index = html.index(after: closeEnd)
                    builder.closeTag(tag)
                    rawTextTag = nil
                } else {
                    pendingText.append(character)
                    index = html.index(after: index)
                }
                continue
            }

            guard character == "<" else {
                pendingText.append(character)
                index = html.index(after: index)
                continue
            }

            // 注释 / DOCTYPE / CDATA
            if html[index...].hasPrefix("<!--") {
                flushText()
                index = skip(until: "-->", in: html, from: html.index(index, offsetBy: 4))
                continue
            }
            if html[index...].hasPrefix("<!") || html[index...].hasPrefix("<?") {
                flushText()
                index = skip(until: ">", in: html, from: index)
                continue
            }

            // 结束标签
            if html[index...].hasPrefix("</") {
                flushText()
                let closeEnd = html[index...].firstIndex(of: ">") ?? html.endIndex
                let inner = html[html.index(index, offsetBy: 2)..<closeEnd]
                let name = inner.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
                builder.closeTag(name.lowercased())
                index = html.index(after: closeEnd)
                continue
            }

            // 开始标签
            flushText()
            guard let (tagText, nextIndex) = readTag(from: index, in: html) else {
                // 不是合法标签（例如 `a < b`）：当作普通文本
                pendingText.append(character)
                index = html.index(after: index)
                continue
            }
            let (tagName, attributes, selfClosing) = parseTag(tagText)
            // 合法标签名必须以字母开头，且标签内部不能再出现 `<`。
            // 典型反例：文本 "3 < 4</p>" 里的 `<` 会被读到下一个 `>`，
            // 得到 `" 4</p"` 这种「标签名」——必须当作文本，否则内容会凭空消失。
            let isValidTag = (tagName.first?.isLetter ?? false) && !tagText.contains("<")
            if isValidTag {
                builder.openTag(tagName, attributes: attributes, selfClosing: selfClosing)
                if rawTextTags.contains(tagName), !selfClosing {
                    rawTextTag = tagName
                }
            } else {
                pendingText.append(character)
                index = html.index(after: index)
                continue
            }
            index = nextIndex
        }

        flushText()
        builder.closeAll()
        let root = builder.finish()
        return HTMLDocument(root: root, sourceLength: html.count)
    }

    // MARK: 扫描辅助

    /// 从 `<` 开始读取一个完整标签，返回标签内部文本与下一个位置。
    static func readTag(from start: String.Index, in html: String) -> (String, String.Index)? {
        var index = html.index(after: start)
        var quote: Character?
        var inner = ""
        while index < html.endIndex {
            let character = html[index]
            if let current = quote {
                if character == current { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return (inner, html.index(after: index))
            }
            inner.append(character)
            index = html.index(after: index)
        }
        return nil   // 没有闭合的 `>`，视为不完整
    }

    static func skip(until marker: String, in html: String, from start: String.Index) -> String.Index {
        guard let range = html.range(of: marker, range: start..<html.endIndex) else {
            return html.endIndex
        }
        return range.upperBound
    }

    /// 解析标签内部文本：`div class="a" id='b' disabled /`。
    static func parseTag(_ text: String) -> (name: String, attributes: [String: String], selfClosing: Bool) {
        var selfClosing = false
        var body = Substring(text)
        if body.hasSuffix("/") {
            selfClosing = true
            body = body.dropLast()
        }

        var scanner = SubstringScanner(body)
        let name = scanner.readName().lowercased()
        var attributes: [String: String] = [:]

        while true {
            scanner.skipWhitespace()
            guard !scanner.isAtEnd else { break }
            let key = scanner.readName().lowercased()
            guard !key.isEmpty else {
                scanner.advance()
                continue
            }
            scanner.skipWhitespace()
            if scanner.peek() == "=" {
                scanner.advance()
                scanner.skipWhitespace()
                attributes[key] = HTMLText.decodeEntities(scanner.readValue())
            } else if attributes[key] == nil {
                attributes[key] = ""      // 布尔属性（如 disabled）
            }
        }
        return (name, attributes, selfClosing)
    }
}

/// 极简下标扫描器（避免到处写 index 运算）。
struct SubstringScanner {
    private let text: Substring
    private var index: Substring.Index

    init(_ text: Substring) {
        self.text = text
        self.index = text.startIndex
    }

    var isAtEnd: Bool { index >= text.endIndex }

    func peek() -> Character? {
        index < text.endIndex ? text[index] : nil
    }

    mutating func advance() {
        if index < text.endIndex { index = text.index(after: index) }
    }

    mutating func skipWhitespace() {
        while index < text.endIndex, text[index].isWhitespace { advance() }
    }

    /// 读标签名 / 属性名：直到空白、`=`、`/` 或结尾。
    mutating func readName() -> String {
        var result = ""
        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace || character == "=" || character == "/" { break }
            result.append(character)
            advance()
        }
        return result
    }

    /// 读属性值：带引号读到配对引号，否则读到空白。
    mutating func readValue() -> String {
        guard let first = peek() else { return "" }
        if first == "\"" || first == "'" {
            advance()
            var result = ""
            while index < text.endIndex, text[index] != first {
                result.append(text[index])
                advance()
            }
            advance()   // 吃掉闭引号
            return result
        }
        var result = ""
        while index < text.endIndex, !text[index].isWhitespace {
            result.append(text[index])
            advance()
        }
        return result
    }
}

/// 建树器（栈式）。
struct TreeBuilder {
    private var nextID = 0
    private var stack: [PartialElement] = []
    private var rootChildren: [HTMLNode] = []

    struct PartialElement {
        var nodeID: Int
        var tag: String
        var attributes: [String: String]
        var children: [HTMLNode]
    }

    mutating func appendText(_ raw: String) {
        let text = HTMLText.decodeEntities(raw)
        guard !text.isEmpty else { return }
        append(node: .text(text))
    }

    mutating func openTag(_ tag: String, attributes: [String: String], selfClosing: Bool) {
        let element = PartialElement(
            nodeID: allocateID(),
            tag: tag,
            attributes: attributes,
            children: []
        )
        if selfClosing || HTMLParser.voidTags.contains(tag) {
            append(node: .element(element.finalized()))
        } else {
            stack.append(element)
        }
    }

    mutating func closeTag(_ tag: String) {
        guard !stack.isEmpty else { return }
        // 从栈顶往下找同名标签；找不到就忽略这个结束标签
        guard let position = stack.lastIndex(where: { $0.tag == tag }) else { return }
        // 处于更深层的标签因为没有闭合，就地自动闭合
        while stack.count > position + 1 {
            let element = stack.removeLast()
            append(node: .element(element.finalized()))
        }
        let element = stack.removeLast()
        append(node: .element(element.finalized()))
    }

    mutating func closeAll() {
        while let element = stack.popLast() {
            append(node: .element(element.finalized()))
        }
    }

    mutating func finish() -> HTMLElement {
        HTMLElement(nodeID: allocateID(), tag: "#document", attributes: [:], children: rootChildren)
    }

    private mutating func allocateID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    private mutating func append(node: HTMLNode) {
        if stack.isEmpty {
            rootChildren.append(node)
        } else {
            stack[stack.count - 1].children.append(node)
        }
    }
}

extension TreeBuilder.PartialElement {
    func finalized() -> HTMLElement {
        HTMLElement(nodeID: nodeID, tag: tag, attributes: attributes, children: children)
    }
}
