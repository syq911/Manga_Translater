//
//  SourceScript.swift
//  SourceEngine
//
//  源脚本（单文件 JS）的静态校验与元信息提取。
//
//  为什么要有静态校验：源是用户从第三方仓库安装的**不受信任代码**。
//  安装前必须先在**不执行**的前提下把明显的垃圾/恶意脚本挡在门外
//  （超大文件、非 UTF-8、缺失必需字段、动态代码求值等），
//  执行期的沙箱限制由 `SourceRuntimeExecuting` 负责。
//
//  本文件不做 JS 求值，因此可以在任意环境（含单元测试）确定性运行。
//

import Foundation
import AppCore

/// 从脚本中提取出的元信息。
public struct SourceScriptMeta: Equatable, Sendable {
    public var id: SourceID
    public var name: String
    public var language: String
    public var baseURL: String?
    public var isNSFW: Bool
    public var version: String?
    public var rateLimitMilliseconds: Int
    public var loginURL: String?
    /// 脚本中显式声明为 `true` 的能力开关（如 `supportsLogin`）。
    public var declaredCapabilities: [String]

    public init(
        id: SourceID,
        name: String,
        language: String = "all",
        baseURL: String? = nil,
        isNSFW: Bool = false,
        version: String? = nil,
        rateLimitMilliseconds: Int = 0,
        loginURL: String? = nil,
        declaredCapabilities: [String] = []
    ) {
        self.id = id
        self.name = name
        self.language = language
        self.baseURL = baseURL
        self.isNSFW = isNSFW
        self.version = version
        self.rateLimitMilliseconds = rateLimitMilliseconds
        self.loginURL = loginURL
        self.declaredCapabilities = declaredCapabilities
    }
}

/// 静态校验失败原因。
public enum SourceScriptValidationError: Error, Equatable {
    case emptyScript
    case tooLarge(bytes: Int, limit: Int)
    case containsNullByte
    case missingMetadataBlock
    case missingField(String)
    case invalidField(name: String, reason: String)
    case forbiddenAPI(String)

    public var message: String {
        switch self {
        case .emptyScript:
            return Copy.text("error.script.empty")
        case let .tooLarge(bytes, limit):
            return Copy.format("error.script.tooLarge", bytes, limit)
        case .containsNullByte:
            return Copy.text("error.script.containsNullByte")
        case .missingMetadataBlock:
            return Copy.text("error.script.missingMetadata")
        case let .missingField(name):
            return Copy.format("error.script.missingField", name)
        case let .invalidField(name, reason):
            return Copy.format("error.script.invalidField", name, reason)
        case let .forbiddenAPI(api):
            return Copy.format("error.script.forbiddenAPI", api)
        }
    }
}

extension SourceScriptValidationError: LocalizedError {
    public var errorDescription: String? { message }
}

/// 源脚本静态校验器。
public enum SourceScriptValidator {

    /// 单个脚本的体积上限。
    public static let maxScriptBytes = 512 * 1024
    /// 元信息字段长度上限。
    public static let maxFieldLength = 200
    /// 被禁用的 API（动态求值 / 模块系统 / 二进制加载）。
    public static let forbiddenAPIs = ["eval(", "Function(", "WebAssembly", "import(", "require("]

    /// 校验脚本并返回元信息。
    /// - Throws: `SourceScriptValidationError`
    public static func validate(_ script: String) throws -> SourceScriptMeta {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SourceScriptValidationError.emptyScript }

        let byteCount = script.utf8.count
        guard byteCount <= maxScriptBytes else {
            throw SourceScriptValidationError.tooLarge(bytes: byteCount, limit: maxScriptBytes)
        }
        guard !script.contains("\u{0}") else {
            throw SourceScriptValidationError.containsNullByte
        }
        for api in forbiddenAPIs where script.contains(api) {
            throw SourceScriptValidationError.forbiddenAPI(api)
        }

        guard let block = metadataBlock(in: script) else {
            throw SourceScriptValidationError.missingMetadataBlock
        }
        let fields = extractFields(from: block)

        let id = try requiredString(fields, name: "id")
        guard ModelValidation.isValidSourceID(id) else {
            throw SourceScriptValidationError.invalidField(
                name: "id",
                reason: Copy.text("error.script.reason.keyFormat")
            )
        }

        let name = try requiredString(fields, name: "name")
        guard name.count <= maxFieldLength else {
            throw SourceScriptValidationError.invalidField(
                name: "name",
                reason: Copy.format("error.script.reason.tooLong", maxFieldLength)
            )
        }

        var baseURL: String?
        if let raw = fields["baseurl"], !raw.isEmpty {
            guard ModelValidation.isValidURLString(raw) else {
                throw SourceScriptValidationError.invalidField(
                name: "baseUrl",
                reason: Copy.text("error.script.reason.notAURL")
            )
            }
            baseURL = raw
        }

        var loginURL: String?
        if let raw = fields["loginurl"], !raw.isEmpty {
            guard ModelValidation.isValidURLString(raw) else {
                throw SourceScriptValidationError.invalidField(
                name: "loginUrl",
                reason: Copy.text("error.script.reason.notAURL")
            )
            }
            loginURL = raw
        }

        var version: String?
        if let raw = fields["version"], !raw.isEmpty {
            guard ModelValidation.isValidVersionString(raw) else {
                throw SourceScriptValidationError.invalidField(
                name: "version",
                reason: Copy.text("error.script.reason.notAVersion")
            )
            }
            version = raw
        }

        var rateLimit = 0
        if let raw = fields["ratelimitms"], !raw.isEmpty {
            guard let parsed = Int(raw), parsed >= 0, parsed <= 60_000 else {
                throw SourceScriptValidationError.invalidField(
                    name: "rateLimitMs",
                    reason: Copy.text("error.script.reason.notAnIntegerInRange")
                )
            }
            rateLimit = parsed
        }

        let isNSFW = parseBool(fields["nsfw"]) ?? false
        let language = fields["lang"].flatMap { $0.isEmpty ? nil : $0 } ?? "all"
        guard language.count <= 16 else {
            throw SourceScriptValidationError.invalidField(
                name: "lang",
                reason: Copy.text("error.script.reason.languageTooLong")
            )
        }

        let capabilities = declaredCapabilities(in: script)

        return SourceScriptMeta(
            id: SourceID(id),
            name: name,
            language: language,
            baseURL: baseURL,
            isNSFW: isNSFW,
            version: version,
            rateLimitMilliseconds: rateLimit,
            loginURL: loginURL,
            declaredCapabilities: capabilities
        )
    }

    // MARK: 内部解析

    /// 截取 `const source = { ... }` 块（括号配平，忽略字符串内的花括号）。
    static func metadataBlock(in script: String) -> String? {
        guard let range = script.range(of: "source") else { return nil }
        // 从 "source" 之后找到第一个 '{'
        var index = range.upperBound
        var depth = 0
        var started = false
        var inString: Character?
        var result = ""
        var previous: Character?

        while index < script.endIndex {
            let character = script[index]
            if let quote = inString {
                result.append(character)
                if character == quote, previous != "\\" {
                    inString = nil
                }
            } else {
                switch character {
                case "\"", "'", "`":
                    inString = character
                    result.append(character)
                case "{":
                    depth += 1
                    started = true
                    result.append(character)
                case "}":
                    depth -= 1
                    result.append(character)
                    if started, depth == 0 {
                        return result
                    }
                default:
                    if started { result.append(character) }
                }
            }
            previous = character
            index = script.index(after: index)
        }
        return started ? result : nil
    }

    /// 提取 `key: value` 形式的浅层字段（键统一小写，去掉引号）。
    static func extractFields(from block: String) -> [String: String] {
        var fields: [String: String] = [:]
        let pattern = "([A-Za-z_][A-Za-z0-9_]*)\\s*:\\s*(\"[^\"]*\"|'[^']*'|`[^`]*`|[^,}\\n]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return fields }
        let range = NSRange(block.startIndex..<block.endIndex, in: block)
        for match in regex.matches(in: block, range: range) {
            guard match.numberOfRanges == 3,
                  let keyRange = Range(match.range(at: 1), in: block),
                  let valueRange = Range(match.range(at: 2), in: block) else { continue }
            let key = String(block[keyRange]).lowercased()
            var value = String(block[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            value = stripQuotes(value)
            if fields[key] == nil {
                fields[key] = value
            }
        }
        return fields
    }

    static func stripQuotes(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        let pairs: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("`", "`")]
        for (open, close) in pairs where value.first == open && value.last == close {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    static func parseBool(_ raw: String?) -> Bool? {
        guard let raw else { return nil }
        switch raw.lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: return nil
        }
    }

    static func declaredCapabilities(in script: String) -> [String] {
        let candidates = ["login", "preferences", "filters", "latestUpdates", "popular"]
        return candidates.filter { capability in
            script.contains("\(capability):") || script.contains("\(capability) :")
        }.sorted()
    }

    private static func requiredString(_ fields: [String: String], name: String) throws -> String {
        guard let value = fields[name.lowercased()] else {
            throw SourceScriptValidationError.missingField(name)
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SourceScriptValidationError.invalidField(
                name: name,
                reason: Copy.text("error.script.reason.empty")
            )
        }
        return trimmed
    }
}
