//
//  SourceRepositoryService.swift
//  SourceEngine
//
//  源仓库的**网络侧**：拉索引、列可装源、装脚本、查更新。
//
//  分工（不要越界）：
//  - `SourceIndexParser` 负责「一段 JSON 是否合法」；
//  - `SourceStore` 负责「磁盘上有什么、怎么安全落盘」；
//  - 本类型只负责「把两者用网络串起来」，不碰文件系统细节。
//
//  合规底线（改动前请先读开发手册）：
//  - **不内置任何仓库地址**，仓库列表完全由用户填写；
//  - 本类型不解析、不缓存、不转发任何站点内容，只搬运源脚本本身。
//
//  安全要点：
//  - 索引里的 `fileName` 来自网络，落盘前由 `SourceIndexParser.isSafeFileName` 把关；
//  - 装之前必须确认**脚本声明的 id 与索引里的 key 一致**，否则会出现
//    「索引说装了 foo、磁盘上却是 bar.js」的不一致状态；
//  - 脚本必须是合法 UTF-8（二进制内容会被静态校验误当成字符集问题，不如直接拒）。
//

import Foundation
import AppCore
import ComicNet

// MARK: - 仓库条目

/// 仓库里的一条可装源（合并了索引信息与本地安装状态）。
public struct RepositoryEntry: Sendable, Equatable, Identifiable {

    /// 索引里的 key，同时是安装后的来源 ID。
    public var id: String { key }
    public let key: String
    public let name: String
    public let version: String
    public let summary: String?
    /// 该条目所属的仓库地址（用户填写的那份）。
    public let repositoryURL: String
    /// 脚本下载地址；仓库地址不合法时为 nil。
    public let scriptURL: String?
    /// 本地已安装的版本；未安装为 nil。
    public let installedVersion: String?

    public init(
        key: String,
        name: String,
        version: String,
        summary: String? = nil,
        repositoryURL: String,
        scriptURL: String? = nil,
        installedVersion: String? = nil
    ) {
        self.key = key
        self.name = name
        self.version = version
        self.summary = summary
        self.repositoryURL = repositoryURL
        self.scriptURL = scriptURL
        self.installedVersion = installedVersion
    }

    /// 是否已安装。
    public var isInstalled: Bool { installedVersion != nil }

    /// 是否有更新（已安装且仓库版本更高）。
    public var hasUpdate: Bool {
        guard let installedVersion else { return false }
        return SourceVersion.isNewer(version, than: installedVersion)
    }

    /// 能否安装（地址可解析）。地址不合法时 UI 应禁用按钮并说明原因。
    public var isInstallable: Bool { scriptURL != nil }
}

/// 一个仓库的目录（索引 + 本地状态）。
public struct RepositoryCatalog: Sendable, Equatable {
    public let repositoryURL: String
    public let entries: [RepositoryEntry]

    public init(repositoryURL: String, entries: [RepositoryEntry]) {
        self.repositoryURL = repositoryURL
        self.entries = entries
    }

    /// 尚未安装的条目数。
    public var availableCount: Int { entries.filter { !$0.isInstalled }.count }
    /// 可更新的条目数。
    public var updateCount: Int { entries.filter(\.hasUpdate).count }
}

/// 刷新多个仓库时的逐条结果：单个仓库失败不影响其他仓库。
public struct RepositoryCatalogResult: Sendable, Equatable {
    public let repositoryURL: String
    public let catalog: RepositoryCatalog?
    public let errorMessage: String?

    public init(repositoryURL: String, catalog: RepositoryCatalog?, errorMessage: String?) {
        self.repositoryURL = repositoryURL
        self.catalog = catalog
        self.errorMessage = errorMessage
    }

    public var isSuccess: Bool { catalog != nil }
}

// MARK: - 错误

/// 仓库操作错误。
public enum SourceRepositoryError: Error, Equatable {
    case invalidRepositoryURL(String)
    case indexUnavailable(String)
    case indexRejected(String)
    case scriptUnavailable(String)
    case keyMismatch(expected: String, actual: String)
    case entryNotFound(String)

    public var message: String {
        switch self {
        case let .invalidRepositoryURL(url):
            return "仓库地址不合法：\(url)"
        case let .indexUnavailable(reason):
            return "无法获取 index.json：\(reason)"
        case let .indexRejected(reason):
            return "仓库索引被拒绝：\(reason)"
        case let .scriptUnavailable(reason):
            return "无法获取源脚本：\(reason)"
        case let .keyMismatch(expected, actual):
            return "脚本声明的来源标识（\(actual)）与仓库索引（\(expected)）不一致"
        case let .entryNotFound(key):
            return "仓库里没有这个源：\(key)"
        }
    }
}

extension SourceRepositoryError: LocalizedError {
    public var errorDescription: String? { message }
}

// MARK: - 服务

/// 源仓库服务（actor：同一实例的内部状态不被并发访问）。
public actor SourceRepositoryService {

    private let store: SourceStore
    private let client: HTTPClient

    public init(store: SourceStore, client: HTTPClient) {
        self.store = store
        self.client = client
    }

    // MARK: 拉取目录

    /// 拉取并解析单个仓库的目录。
    public func catalog(for repositoryURL: String) async throws -> RepositoryCatalog {
        guard let indexURL = SourceIndexParser.indexURL(for: repositoryURL) else {
            throw SourceRepositoryError.invalidRepositoryURL(repositoryURL)
        }

        let response: HTTPResponse
        do {
            response = try await client.get(indexURL, allowsRetry: true)
        } catch {
            throw SourceRepositoryError.indexUnavailable(
                (error as? NetworkError)?.errorDescription ?? error.localizedDescription
            )
        }
        guard response.isSuccess else {
            throw SourceRepositoryError.indexUnavailable("HTTP \(response.statusCode)")
        }

        let entries: [SourceIndexEntry]
        do {
            entries = try SourceIndexParser.parse(data: response.data)
        } catch let error as SourceIndexError {
            throw SourceRepositoryError.indexRejected(error.message)
        } catch {
            throw SourceRepositoryError.indexRejected(error.localizedDescription)
        }

        let installed = store.installedSources()
        // 「已安装」与「已安装且带版本号」是两件事：脚本可以不声明 version，
        // 但装了就是装了，不能因为版本为 nil 就显示成「未安装」。
        let installedKeys = Set(installed.map(\.key))
        var installedVersions: [String: String] = [:]
        for source in installed {
            if let version = source.version {
                installedVersions[source.key] = version
            }
        }

        let merged = entries.map { entry in
            RepositoryEntry(
                key: entry.key,
                name: entry.name,
                version: entry.version,
                summary: entry.description,
                repositoryURL: repositoryURL,
                scriptURL: SourceIndexParser.scriptURL(for: entry, repositoryURL: repositoryURL),
                installedVersion: installedKeys.contains(entry.key) ? installedVersions[entry.key] : nil
            )
        }
        return RepositoryCatalog(repositoryURL: repositoryURL, entries: merged)
    }

    /// 刷新**全部**已添加仓库。单个仓库失败只记录该条的错误，不影响其他仓库。
    public func catalogs() async -> [RepositoryCatalogResult] {
        let repositories = store.repositories
        guard !repositories.isEmpty else { return [] }

        var results: [RepositoryCatalogResult] = []
        for repository in repositories {
            do {
                let catalog = try await catalog(for: repository)
                results.append(
                    RepositoryCatalogResult(repositoryURL: repository, catalog: catalog, errorMessage: nil)
                )
            } catch let error as SourceRepositoryError {
                results.append(
                    RepositoryCatalogResult(
                        repositoryURL: repository,
                        catalog: nil,
                        errorMessage: error.message
                    )
                )
            } catch {
                results.append(
                    RepositoryCatalogResult(
                        repositoryURL: repository,
                        catalog: nil,
                        errorMessage: error.localizedDescription
                    )
                )
            }
        }
        return results
    }

    /// 所有仓库里可更新的条目（用于设置页的「有 N 个源可更新」）。
    public func availableUpdates() async -> [RepositoryEntry] {
        await catalogs().flatMap { $0.catalog?.entries.filter(\.hasUpdate) ?? [] }
    }

    // MARK: 安装

    /// 安装仓库里的某条源。
    ///
    /// 流程：解析脚本地址 → 下载 → UTF-8 解码 → **key 一致性检查** →
    /// 静态校验并原子落盘（`SourceStore.install` 自带回滚）。
    @discardableResult
    public func install(_ entry: RepositoryEntry) async throws -> InstalledSource {
        guard let scriptURL = entry.scriptURL else {
            throw SourceRepositoryError.invalidRepositoryURL(entry.repositoryURL)
        }

        let response: HTTPResponse
        do {
            response = try await client.get(scriptURL, allowsRetry: true)
        } catch {
            throw SourceRepositoryError.scriptUnavailable(
                (error as? NetworkError)?.errorDescription ?? error.localizedDescription
            )
        }
        guard response.isSuccess else {
            throw SourceRepositoryError.scriptUnavailable("HTTP \(response.statusCode)")
        }
        guard let script = String(data: response.data, encoding: .utf8) else {
            throw SourceRepositoryError.scriptUnavailable("脚本不是合法的 UTF-8 文本")
        }

        // 索引与脚本必须说同一个 key，否则会出现「索引装的是 A、磁盘上是 B」
        let meta: SourceScriptMeta
        do {
            meta = try SourceScriptValidator.validate(script)
        } catch let error as SourceScriptValidationError {
            throw SourceRepositoryError.scriptUnavailable(error.message)
        }
        guard meta.id.rawValue == entry.key else {
            throw SourceRepositoryError.keyMismatch(expected: entry.key, actual: meta.id.rawValue)
        }

        do {
            return try store.install(script: script)
        } catch let error as SourceScriptValidationError {
            throw SourceRepositoryError.scriptUnavailable(error.message)
        } catch {
            throw SourceRepositoryError.scriptUnavailable(error.localizedDescription)
        }
    }

    /// 从仓库里按 key 安装（UI 只知道 key 时用）。
    @discardableResult
    public func install(key: String, from repositoryURL: String) async throws -> InstalledSource {
        let catalog = try await catalog(for: repositoryURL)
        guard let entry = catalog.entries.first(where: { $0.key == key }) else {
            throw SourceRepositoryError.entryNotFound(key)
        }
        return try await install(entry)
    }

    /// 只下载脚本内容（不落盘）。用于「查看源码」这类只读需求与测试。
    public func scriptContent(of entry: RepositoryEntry) async throws -> String {
        guard let scriptURL = entry.scriptURL else {
            throw SourceRepositoryError.invalidRepositoryURL(entry.repositoryURL)
        }
        let response: HTTPResponse
        do {
            response = try await client.get(scriptURL, allowsRetry: true)
        } catch {
            throw SourceRepositoryError.scriptUnavailable(
                (error as? NetworkError)?.errorDescription ?? error.localizedDescription
            )
        }
        guard response.isSuccess else {
            throw SourceRepositoryError.scriptUnavailable("HTTP \(response.statusCode)")
        }
        guard let script = String(data: response.data, encoding: .utf8) else {
            throw SourceRepositoryError.scriptUnavailable("脚本不是合法的 UTF-8 文本")
        }
        return script
    }
}
