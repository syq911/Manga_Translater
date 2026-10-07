//
//  SourceStore.swift
//  SourceEngine
//
//  源仓库管理：仓库 URL 列表 + 已安装源脚本的落盘、更新与卸载。
//
//  两条硬约束：
//  1. **出厂零源**——`repositories` 初始为空，App 不预置任何仓库，
//     用户必须自己添加。这是合规底线，不要在代码里加默认值。
//  2. **安装必须可回滚**——写文件、替换旧版本、写元数据任一步失败，
//     都要恢复到安装前的状态，绝不留下半个文件或丢失旧版本。
//
//  文件系统抽象为 `SourceFileSystem`，测试可注入失败实现来验证回滚路径。
//

import Foundation
import AppCore

/// 已安装源的元信息。
public struct InstalledSource: Codable, Equatable, Sendable {
    public var key: String
    public var name: String
    public var version: String?
    public var language: String
    public var isNSFW: Bool
    public var installedAt: Date
    public var byteCount: Int

    public init(
        key: String,
        name: String,
        version: String?,
        language: String,
        isNSFW: Bool,
        installedAt: Date,
        byteCount: Int
    ) {
        self.key = key
        self.name = name
        self.version = version
        self.language = language
        self.isNSFW = isNSFW
        self.installedAt = installedAt
        self.byteCount = byteCount
    }
}

/// 文件系统抽象（用于失败注入测试）。
public protocol SourceFileSystem: Sendable {
    func ensureDirectory(at url: URL) throws
    func exists(at url: URL) -> Bool
    func read(from url: URL) throws -> Data
    func write(_ data: Data, to url: URL) throws
    func move(from source: URL, to destination: URL) throws
    func remove(at url: URL) throws
    func listFiles(in url: URL) throws -> [String]
}

/// 默认实现（FileManager）。
public struct DefaultSourceFileSystem: SourceFileSystem {
    public init() {}

    public func ensureDirectory(at url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    public func exists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func read(from url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    public func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    public func move(from source: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    public func remove(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func listFiles(in url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path)
    }
}

/// 源仓库与已安装源的管理器。
public final class SourceStore: @unchecked Sendable {

    public static let sourcesDirectoryName = "Sources"
    public static let repositoriesFileName = "repositories.json"
    public static let metadataFileName = "installed.json"

    private let rootDirectory: URL
    private let fileSystem: SourceFileSystem
    private let lock = NSLock()
    private var repositoryList: [String]
    private var metadata: [String: InstalledSource]

    public init(rootDirectory: URL, fileSystem: SourceFileSystem = DefaultSourceFileSystem()) {
        self.rootDirectory = rootDirectory
        self.fileSystem = fileSystem
        self.repositoryList = []
        self.metadata = [:]
        loadRepositories()
        loadMetadata()
    }

    // MARK: 路径

    public var sourcesDirectory: URL {
        rootDirectory.appendingPathComponent(Self.sourcesDirectoryName, isDirectory: true)
    }

    private var repositoriesFileURL: URL {
        rootDirectory.appendingPathComponent(Self.repositoriesFileName, isDirectory: false)
    }

    private var metadataFileURL: URL {
        rootDirectory.appendingPathComponent(Self.metadataFileName, isDirectory: false)
    }

    /// 源脚本落盘地址。`key` 已通过命名规则校验，不含路径分隔符。
    public func scriptURL(for key: String) -> URL {
        sourcesDirectory.appendingPathComponent("\(key).js", isDirectory: false)
    }

    // MARK: 仓库

    /// 已添加的仓库地址列表（出厂为空）。
    public var repositories: [String] {
        lock.lock()
        defer { lock.unlock() }
        return repositoryList
    }

    /// 添加仓库。重复添加返回 false；地址非法抛错。
    @discardableResult
    public func addRepository(_ urlString: String) throws -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ModelValidation.isValidURLString(trimmed) else {
            throw AppError.invalidInput(Copy.format("error.store.invalidRepositoryURL", urlString))
        }
        lock.lock()
        guard !repositoryList.contains(trimmed) else {
            lock.unlock()
            return false
        }
        repositoryList.append(trimmed)
        let snapshot = repositoryList
        lock.unlock()
        try persistRepositories(snapshot)
        diag("SourceEngine: 添加源仓库 \(trimmed)")
        return true
    }

    /// 移除仓库。不存在返回 false。
    @discardableResult
    public func removeRepository(_ urlString: String) throws -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        guard let index = repositoryList.firstIndex(of: trimmed) else {
            lock.unlock()
            return false
        }
        repositoryList.remove(at: index)
        let snapshot = repositoryList
        lock.unlock()
        try persistRepositories(snapshot)
        return true
    }

    /// 清空仓库列表。
    @discardableResult
    public func removeAllRepositories() throws -> Int {
        lock.lock()
        let count = repositoryList.count
        repositoryList.removeAll()
        lock.unlock()
        try persistRepositories([])
        return count
    }

    private func persistRepositories(_ list: [String]) throws {
        do {
            try fileSystem.ensureDirectory(at: rootDirectory)
            let data = try JSONEncoder().encode(list)
            try fileSystem.write(data, to: repositoriesFileURL)
        } catch {
            throw AppError.normalize(error)
        }
    }

    private func loadRepositories() {
        guard fileSystem.exists(at: repositoriesFileURL),
              let data = try? fileSystem.read(from: repositoriesFileURL),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return }
        lock.lock()
        repositoryList = list
        lock.unlock()
    }

    // MARK: 安装 / 卸载

    /// 已安装源列表（按名称排序）。
    public func installedSources() -> [InstalledSource] {
        lock.lock()
        defer { lock.unlock() }
        return metadata.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func isInstalled(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return metadata[key] != nil
    }

    /// 安装 / 覆盖一个源脚本。
    ///
    /// 流程（任一步失败都会回滚到安装前状态）：
    /// 1. 静态校验脚本；
    /// 2. 写入临时文件；
    /// 3. 旧版本先移到备份；
    /// 4. 临时文件就位；
    /// 5. 写元数据；
    /// 6. 删除备份。
    @discardableResult
    public func install(script: String, at date: Date = Date()) throws -> InstalledSource {
        let meta = try SourceScriptValidator.validate(script)
        let key = meta.id.rawValue

        // 双重保险：key 会作为文件名使用。
        guard ModelValidation.isValidSourceID(key) else {
            throw AppError.invalidInput(Copy.format("error.store.invalidKey", key))
        }

        let finalURL = scriptURL(for: key)
        let temporaryURL = sourcesDirectory.appendingPathComponent("\(key).js.tmp", isDirectory: false)
        let backupURL = sourcesDirectory.appendingPathComponent("\(key).js.bak", isDirectory: false)

        do {
            try fileSystem.ensureDirectory(at: sourcesDirectory)
            try fileSystem.write(Data(script.utf8), to: temporaryURL)

            let hadPrevious = fileSystem.exists(at: finalURL)
            if hadPrevious {
                try fileSystem.move(from: finalURL, to: backupURL)
            }

            do {
                try fileSystem.move(from: temporaryURL, to: finalURL)
            } catch {
                if hadPrevious, fileSystem.exists(at: backupURL) {
                    try? fileSystem.move(from: backupURL, to: finalURL)
                }
                try? fileSystem.remove(at: temporaryURL)
                throw AppError.fileSystem(Copy.format("error.store.scriptWriteFailed", key))
            }

            let entry = InstalledSource(
                key: key,
                name: meta.name,
                version: meta.version,
                language: meta.language,
                isNSFW: meta.isNSFW,
                installedAt: date,
                byteCount: script.utf8.count
            )

            do {
                try updateMetadata { $0[key] = entry }
            } catch {
                // 元数据写入失败 → 连文件一起回滚，保证「要么全新版本，要么旧版本」。
                try? fileSystem.remove(at: finalURL)
                if hadPrevious, fileSystem.exists(at: backupURL) {
                    try? fileSystem.move(from: backupURL, to: finalURL)
                }
                throw AppError.fileSystem(Copy.format("error.store.metadataWriteFailed", key))
            }

            if fileSystem.exists(at: backupURL) {
                try? fileSystem.remove(at: backupURL)
            }

            diag("SourceEngine: 安装源 \(key) v\(meta.version ?? "-")，\(script.utf8.count) 字节")
            return entry
        } catch let error as SourceScriptValidationError {
            throw error
        } catch {
            throw AppError.normalize(error)
        }
    }

    /// 卸载源。不存在返回 false。
    @discardableResult
    public func uninstall(key: String) throws -> Bool {
        guard ModelValidation.isValidSourceID(key) else {
            throw AppError.invalidInput(Copy.format("error.store.invalidKey", key))
        }
        lock.lock()
        let existed = metadata[key] != nil
        lock.unlock()
        guard existed else { return false }

        try updateMetadata { $0.removeValue(forKey: key) }
        try? fileSystem.remove(at: scriptURL(for: key))
        try? fileSystem.remove(at: sourcesDirectory.appendingPathComponent("\(key).js.tmp"))
        try? fileSystem.remove(at: sourcesDirectory.appendingPathComponent("\(key).js.bak"))
        diag("SourceEngine: 卸载源 \(key)")
        return true
    }

    /// 读取已安装脚本内容。
    public func script(for key: String) throws -> String {
        guard ModelValidation.isValidSourceID(key) else {
            throw AppError.invalidInput(Copy.format("error.store.invalidKey", key))
        }
        let url = scriptURL(for: key)
        guard fileSystem.exists(at: url) else {
            throw AppError.notFound(Copy.format("error.store.payloadScript", key))
        }
        do {
            let data = try fileSystem.read(from: url)
            return String(decoding: data, as: UTF8.self)
        } catch {
            throw AppError.normalize(error)
        }
    }

    private func updateMetadata(_ mutate: (inout [String: InstalledSource]) -> Void) throws {
        lock.lock()
        var working = metadata
        mutate(&working)
        lock.unlock()

        do {
            try fileSystem.ensureDirectory(at: rootDirectory)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(working)
            try fileSystem.write(data, to: metadataFileURL)
        } catch {
            throw AppError.normalize(error)
        }

        lock.lock()
        metadata = working
        lock.unlock()
    }

    private func loadMetadata() {
        guard fileSystem.exists(at: metadataFileURL),
              let data = try? fileSystem.read(from: metadataFileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([String: InstalledSource].self, from: data) else { return }
        lock.lock()
        metadata = decoded
        lock.unlock()
    }
}
