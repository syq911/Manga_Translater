//
//  CSSSelector.swift
//  SourceEngine
//
//  极简 CSS 选择器解析与匹配（零第三方依赖）。
//
//  支持源作者真正会用到的子集：
//  - 类型：`div`、通配 `*`
//  - id：`#main`
//  - class：`.item`（可多个）
//  - 属性：`[href]`（存在）、`[data-id="1"]`（精确）、
//    `[href^="http"]` / `[href$=".jpg"]` / `[href*="/m/"]`（前缀/后缀/包含）
//  - 组合子：后代（空格）与直接子代（`>`）
//
//  不支持（明确不做，避免复杂度失控）：伪类、伪元素、`:nth-child`、
//  属性选择器的大小写标志 `i`、逗号并列选择器。源作者如需要，
//  请在脚本里多次调用或自行过滤。
//
//  匹配策略：**从左到右**推进「当前候选集合」——
//  每一步在上一步结果的指定范围（后代 / 直接子代）里筛选，最后一步的输出即结果。
//  结果按文档顺序去重。
//

import Foundation

// MARK: - 模型

/// 属性要求。
public struct CSSAttributeRequirement: Equatable, Sendable {
    /// 匹配方式。
    public enum Match: Equatable, Sendable {
        case exists
        case equals(String)
        case prefix(String)
        case suffix(String)
        case contains(String)
    }

    public let name: String
    public let match: Match

    public init(name: String, match: Match) {
        self.name = name
        self.match = match
    }

    func isSatisfied(by element: HTMLElement) -> Bool {
        guard let value = element.attribute(name) else { return false }
        switch match {
        case .exists: return true
        case let .equals(expected): return value == expected
        case let .prefix(expected): return value.hasPrefix(expected)
        case let .suffix(expected): return value.hasSuffix(expected)
        case let .contains(expected): return value.contains(expected)
        }
    }
}

/// 不含组合子的简单选择器。
public struct CSSSimpleSelector: Equatable, Sendable {
    /// 小写标签名；nil 或 `*` 表示任意标签。
    public let tag: String?
    public let id: String?
    public let classes: [String]
    public let attributes: [CSSAttributeRequirement]

    public init(
        tag: String? = nil,
        id: String? = nil,
        classes: [String] = [],
        attributes: [CSSAttributeRequirement] = []
    ) {
        self.tag = tag
        self.id = id
        self.classes = classes
        self.attributes = attributes
    }

    /// 是否为「无条件」选择器（`*` 或全空）。
    ///
    /// 注意 `*` 会被解析成 `tag == "*"`（保留原始信息便于诊断），
    /// 因此这里要把它与 `nil` 一并视为「任意标签」。
    public var isUniversal: Bool {
        (tag == nil || tag == "*") && id == nil && classes.isEmpty && attributes.isEmpty
    }

    public func matches(_ element: HTMLElement) -> Bool {
        if let tag, tag != "*", element.tag != tag { return false }
        if let id, element.id != id { return false }
        if !classes.isEmpty {
            let elementClasses = Set(element.classes)
            for name in classes where !elementClasses.contains(name) { return false }
        }
        for requirement in attributes where !requirement.isSatisfied(by: element) {
            return false
        }
        return true
    }
}

/// 组合子。
public enum CSSCombinator: Equatable, Sendable {
    /// 后代（含任意深度）。
    case descendant
    /// 直接子代。
    case child
}

/// 选择器链中的一步。
public struct CSSSelectorStep: Equatable, Sendable {
    public let combinator: CSSCombinator
    public let simple: CSSSimpleSelector

    public init(combinator: CSSCombinator, simple: CSSSimpleSelector) {
        self.combinator = combinator
        self.simple = simple
    }
}

/// 选择器。
public struct CSSSelector: Equatable, Sendable {
    public let steps: [CSSSelectorStep]

    public init(steps: [CSSSelectorStep]) {
        self.steps = steps
    }
}

/// 选择器错误。
public enum CSSSelectorError: Error, Equatable {
    case empty
    case danglingCombinator
    case invalidSimpleSelector(String)
    case invalidAttribute(String)

    public var message: String {
        switch self {
        case .empty: return "选择器为空"
        case .danglingCombinator: return "组合子后缺少选择器"
        case let .invalidSimpleSelector(text): return "无法解析的选择器片段：\(text)"
        case let .invalidAttribute(text): return "无法解析的属性选择器：\(text)"
        }
    }
}

extension CSSSelectorError: LocalizedError {
    public var errorDescription: String? { message }
}

// MARK: - 解析

public enum CSSSelectorParser {

    /// 解析选择器字符串。
    /// - Throws: `CSSSelectorError`
    public static func parse(_ raw: String) throws -> CSSSelector {
        let normalized = normalize(raw)
        let tokens = normalized.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { throw CSSSelectorError.empty }

        var steps: [CSSSelectorStep] = []
        var pendingCombinator: CSSCombinator?

        for token in tokens {
            if token == ">" {
                guard pendingCombinator == nil else { throw CSSSelectorError.danglingCombinator }
                pendingCombinator = .child
                continue
            }
            let simple = try parseSimpleSelector(token)
            // 第一步恒为「后代」（相对上下文节点）
            let combinator = steps.isEmpty ? CSSCombinator.descendant : (pendingCombinator ?? .descendant)
            steps.append(CSSSelectorStep(combinator: combinator, simple: simple))
            pendingCombinator = nil
        }

        guard pendingCombinator == nil else { throw CSSSelectorError.danglingCombinator }
        guard !steps.isEmpty else { throw CSSSelectorError.empty }
        return CSSSelector(steps: steps)
    }

    /// 把 `a>b` 规范成 `a > b`，让后续按空白切分即可。
    static func normalize(_ raw: String) -> String {
        var output = ""
        var inAttribute = false
        var quote: Character?

        for character in raw {
            if let current = quote {
                if character == current { quote = nil }
                output.append(character)
                continue
            }
            switch character {
            case "[": inAttribute = true; output.append(character)
            case "]": inAttribute = false; output.append(character)
            case "\"", "'" where inAttribute: quote = character; output.append(character)
            case ">" where !inAttribute: output += " > "
            default: output.append(character)
            }
        }
        return output
    }

    /// 解析 `div#id.a.b[attr][attr="v"]`。
    static func parseSimpleSelector(_ token: String) throws -> CSSSimpleSelector {
        var tag: String?
        var id: String?
        var classes: [String] = []
        var attributes: [CSSAttributeRequirement] = []

        var index = token.startIndex
        while index < token.endIndex {
            let character = token[index]

            if character == "#" || character == "." {
                let name = readName(token, from: token.index(after: index))
                guard !name.isEmpty else {
                    throw CSSSelectorError.invalidSimpleSelector(token)
                }
                if character == "#" {
                    if id == nil { id = name }
                } else {
                    classes.append(name)
                }
                index = token.index(index, offsetBy: name.count + 1)
                continue
            }

            if character == "[" {
                guard let close = token[index...].firstIndex(of: "]") else {
                    throw CSSSelectorError.invalidAttribute(String(token[index...]))
                }
                let body = String(token[token.index(after: index)..<close])
                attributes.append(try parseAttribute(body))
                index = token.index(after: close)
                continue
            }

            // 类型选择器（只允许出现在最前面）
            if tag == nil {
                let name = readTagName(token, from: index)
                guard !name.isEmpty else {
                    throw CSSSelectorError.invalidSimpleSelector(token)
                }
                tag = name.lowercased()
                index = token.index(index, offsetBy: name.count)
                continue
            }

            throw CSSSelectorError.invalidSimpleSelector(token)
        }

        return CSSSimpleSelector(tag: tag, id: id, classes: classes, attributes: attributes)
    }

    static func parseAttribute(_ body: String) throws -> CSSAttributeRequirement {
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw CSSSelectorError.invalidAttribute(body) }

        // 找运算符
        let operators = ["^=", "$=", "*=", "="]
        for op in operators {
            guard let range = trimmed.range(of: op) else { continue }
            let name = String(trimmed[trimmed.startIndex..<range.lowerBound])
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            guard !name.isEmpty else { throw CSSSelectorError.invalidAttribute(body) }
            var value = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            value = stripQuotes(value)
            let match: CSSAttributeRequirement.Match
            switch op {
            case "^=": match = .prefix(value)
            case "$=": match = .suffix(value)
            case "*=": match = .contains(value)
            default: match = .equals(value)
            }
            return CSSAttributeRequirement(name: name, match: match)
        }

        return CSSAttributeRequirement(name: trimmed.lowercased(), match: .exists)
    }

    /// 读 `#id` / `.class` 的名称（到下一个特殊字符为止）。
    static func readName(_ token: String, from start: String.Index) -> String {
        var index = start
        var result = ""
        while index < token.endIndex {
            let character = token[index]
            if character == "#" || character == "." || character == "[" || character == ":" { break }
            result.append(character)
            index = token.index(after: index)
        }
        return result
    }

    /// 读类型选择器名称。
    static func readTagName(_ token: String, from start: String.Index) -> String {
        var index = start
        var result = ""
        while index < token.endIndex {
            let character = token[index]
            if character == "#" || character == "." || character == "[" { break }
            result.append(character)
            index = token.index(after: index)
        }
        return result
    }

    static func stripQuotes(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        for quote: Character in ["\"", "'"] where value.first == quote && value.last == quote {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}

// MARK: - 查询

public enum CSSSelectorEngine {

    /// 在文档内查询（结果按文档顺序去重）。
    /// - Throws: `CSSSelectorError`
    public static func select(_ raw: String, in root: HTMLElement) throws -> [HTMLElement] {
        let selector = try CSSSelectorParser.parse(raw)
        return select(selector, in: root)
    }

    public static func selectFirst(_ raw: String, in root: HTMLElement) throws -> HTMLElement? {
        try select(raw, in: root).first
    }

    /// 用已解析的选择器查询。
    public static func select(_ selector: CSSSelector, in root: HTMLElement) -> [HTMLElement] {
        var current: [HTMLElement] = [root]

        for step in selector.steps {
            var next: [HTMLElement] = []
            var seen = Set<Int>()
            for context in current {
                let pool: [HTMLElement]
                switch step.combinator {
                case .descendant: pool = context.descendants
                case .child: pool = context.childElements
                }
                for candidate in pool where step.simple.matches(candidate) {
                    if seen.insert(candidate.nodeID).inserted {
                        next.append(candidate)
                    }
                }
            }
            current = next
            if current.isEmpty { break }
        }

        return current
    }
}

// MARK: - 元素上的便捷查询

extension HTMLElement {

    /// 在本元素**子树内**查询（不含自身，与文档级查询语义一致）。
    /// - Throws: `CSSSelectorError`
    public func select(_ selector: String) throws -> [HTMLElement] {
        try CSSSelectorEngine.select(selector, in: self)
    }

    /// 子树内的第一个匹配。
    public func selectFirst(_ selector: String) throws -> HTMLElement? {
        try CSSSelectorEngine.selectFirst(selector, in: self)
    }
}
