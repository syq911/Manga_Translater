//
//  SourceIndex.swift
//  SourceEngine
//
//  源仓库索引（`index.json`）的解析与校验。
//
//  仓库格式（与社区既有习惯保持一致，便于生态直接迁移）：
//  [
//    { "name": "示例源", "fileName": "example.js", "key": "example",
//      "version": "1.0.0", "description": "可选说明" }
//  ]
//
//  安全要点：`fileName` 来自网络，必须做**路径穿越**与扩展名校验，
//  否则恶意仓库可以写任意路径（如 `../../Documents/evil.js`）。
//

import Foundation
import AppCore

/// 一条仓库索引项。
public struct SourceIndexEntry: Codable, Equatable, Sendable {
    public let name: String
    public let fileName: String
    public let key: String
    public let version: String
    public let description: String?

    public init(name: String, fileName: String, key: String, version: String, description: String? = nil) {
        self.name = name
        self.fileName = fileName
        self.key = key
        self.version = version
        self.description = description
    }
}

/// 索引解析错误。
public enum SourceIndexError: Error, Equatable {
    case invalidJSON(String)
    case emptyIndex
    case tooManyEntries(Int)
    case invalidEntry(index: Int, reason: String)
    case duplicateKey(String)
    case unsafeFileName(String)
    case tooLarge(bytes: Int, limit: Int)

    public var message: String {
        switch self {
        case let .invalidJSON(reason): return "index.json 不是合法 JSON：\(reason)"
        case .emptyIndex: return "仓库里没有任何源"
        case let .tooManyEntries(count): return "仓库条目过多（\(count)）"
        case let .invalidEntry(index, reason): return "第 \(index) 条不合法：\(reason)"
        case let .duplicateKey(key): return "来源 key 重复：\(key)"
        case let .unsafeFileName(name): return "文件名不安全：\(name)"
        case let .tooLarge(bytes, limit): return "索引过大（\(bytes) 字节，上限 \(limit)）"
        }
    }
}

extension SourceIndexError: LocalizedError {
    public var errorDescription: String? { message }
}

/// 仓库索引解析器。
public enum SourceIndexParser {

    /// 索引体积上限。
    public static let maxIndexBytes = 1024 * 1024
    /// 单仓库条目上限。
    public static let maxEntries = 500
    /// 文件名长度上限。
    public static let maxFileNameLength = 128

    /// 解析索引数据。
    /// - Throws: `SourceIndexError`
    public static func parse(data: Data) throws -> [SourceIndexEntry] {
        guard data.count <= maxIndexBytes else {
            throw SourceIndexError.tooLarge(bytes: data.count, limit: maxIndexBytes)
        }

        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw SourceIndexError.invalidJSON((error as NSError).localizedDescription)
        }

        guard let array = raw as? [[String: Any]] else {
            throw SourceIndexError.invalidJSON("根节点必须是数组")
        }
        guard !array.isEmpty else {
            throw SourceIndexError.emptyIndex
        }
        guard array.count <= maxEntries else {
            throw SourceIndexError.tooManyEntries(array.count)
        }

        var entries: [SourceIndexEntry] = []
        var seenKeys = Set<String>()

        for (index, item) in array.enumerated() {
            let name = try requiredString(item["name"], field: "name", index: index)
            let key = try requiredString(item["key"], field: "key", index: index)
            let version = try requiredString(item["version"], field: "version", index: index)
            let fileName = try requiredString(item["fileName"], field: "fileName", index: index)

            guard ModelValidation.isValidSourceID(key) else {
                throw SourceIndexError.invalidEntry(index: index, reason: "key 不符合命名规则（\(key)）")
            }
            guard ModelValidation.isValidVersionString(version) else {
                throw SourceIndexError.invalidEntry(index: index, reason: "version 不是合法版本号（\(version)）")
            }
            guard name.count <= SourceScriptValidator.maxFieldLength else {
                throw SourceIndexError.invalidEntry(index: index, reason: "name 过长")
            }
            guard isSafeFileName(fileName) else {
                throw SourceIndexError.unsafeFileName(fileName)
            }
            guard seenKeys.insert(key).inserted else {
                throw SourceIndexError.duplicateKey(key)
            }

            let description = (item["description"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            entries.append(
                SourceIndexEntry(
                    name: name,
                    fileName: fileName,
                    key: key,
                    version: version,
                    description: (description?.isEmpty ?? true) ? nil : description
                )
            )
        }

        return entries
    }

    /// 文件名安全性：只允许单层文件名、必须以 `.js` 结尾、
    /// 不含路径分隔符与 `..`、长度受限。
    public static func isSafeFileName(_ fileName: String) -> Bool {
        guard (1...maxFileNameLength).contains(fileName.count) else { return false }
        guard fileName.hasSuffix(".js") else { return false }
        guard !fileName.contains("/"), !fileName.contains("\\") else { return false }
        guard !fileName.contains("..") else { return false }
        guard !fileName.hasPrefix(".") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        return fileName.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// 把索引项对应的下载地址拼出来（相对仓库目录地址）。
    public static func scriptURL(for entry: SourceIndexEntry, repositoryURL: String) -> String? {
        guard let lastSlash = repositoryURL.lastIndex(of: "/") else { return nil }
        let base = repositoryURL[repositoryURL.startIndex...lastSlash]
        guard base.hasPrefix("http") else { return nil }
        return base + entry.fileName
    }

    private static func requiredString(_ value: Any?, field: String, index: Int) throws -> String {
        guard let text = value as? String else {
            throw SourceIndexError.invalidEntry(index: index, reason: "\(field) 缺失或类型错误")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SourceIndexError.invalidEntry(index: index, reason: "\(field) 为空")
        }
        return trimmed
    }
}
