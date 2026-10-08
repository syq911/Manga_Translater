//
//  BackupBundle.swift
//  MangaTranslater
//
//  备份 / 恢复（手册 §7 的设置项之一）。
//
//  设计上只有两条硬规则，其余都是围绕它们展开：
//
//  1. **凭据绝不进备份文件。** 服务器配置会被导出，但 apiKey / 密码 / 用户名
//     一律不带——备份文件是会被丢进 iCloud、微信、邮件里的那种东西，
//     而钥匙串是另一码事（手册 §5.2 要求凭据进 Keychain，备份不属于它）。
//     恢复后服务器仍然在，只是要重新填一次凭据。
//  2. **恢复不覆盖。** 分类按名字去重、仓库取并集、服务器按标识去重、
//     书架条目已存在的**跳过**（本地进度优先）。理由是：恢复的典型场景是
//     「换机」或「手机 + 平板」，两边都可能有更新的进度；
//     一个「点一下就把本地进度冲掉」的恢复按钮是危险品。
//
//  版本号是文件的第一道闸：来自更新版本的备份会被明确拒绝，
//  而不是「尽力解析然后给出半截数据」。
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers
import AppCore
import SourceEngine

// MARK: - 文件格式

/// 备份文件的内容。
struct BackupBundle: Codable, Equatable {

    /// 当前格式版本。**加字段不算升级**（解码时缺字段用默认值），
    /// 只有「旧版本 App 无法安全理解新文件」时才 +1。
    static let currentVersion = 1

    /// 备份就是**纯 JSON**。
    ///
    /// 刻意不自定义一个加密/打包格式：
    /// 1. 用户能自己打开看内容（「备份里到底有什么」是个合理的问题）；
    /// 2. 版本号、字段名都写在文件里，出问题时能对着文档排查；
    /// 3. 不需要在 Info.plist 里声明自定义 UTI（少一处容易配错的地方）。
    /// 「凭据不进备份」这条规则由字段结构保证，不靠加密。
    static let contentTypeExtension = "json"

    var version: Int
    var exportedAt: Date
    var appVersion: String
    var settings: SettingsSnapshot
    var repositories: [String]
    var categories: [LibraryCategory]
    var library: [LibraryEntry]
    var servers: [BackupServer]

    init(
        version: Int = BackupBundle.currentVersion,
        exportedAt: Date = Date(),
        appVersion: String,
        settings: SettingsSnapshot,
        repositories: [String] = [],
        categories: [LibraryCategory] = [],
        library: [LibraryEntry] = [],
        servers: [BackupServer] = []
    ) {
        self.version = version
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.settings = settings
        self.repositories = repositories
        self.categories = categories
        self.library = library
        self.servers = servers
    }

    /// 解码时**缺字段用默认值**：这样「新版本导出的文件」在旧版本上仍能被读，
    /// 前提是 `version <= currentVersion`；旧文件读进新版本更是不在话下。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
        self.exportedAt = try container.decodeIfPresent(Date.self, forKey: .exportedAt) ?? Date(timeIntervalSince1970: 0)
        self.appVersion = try container.decodeIfPresent(String.self, forKey: .appVersion) ?? ""
        self.settings = try container.decodeIfPresent(SettingsSnapshot.self, forKey: .settings) ?? SettingsSnapshot()
        self.repositories = try container.decodeIfPresent([String].self, forKey: .repositories) ?? []
        self.categories = try container.decodeIfPresent([LibraryCategory].self, forKey: .categories) ?? []
        self.library = try container.decodeIfPresent([LibraryEntry].self, forKey: .library) ?? []
        self.servers = try container.decodeIfPresent([BackupServer].self, forKey: .servers) ?? []
    }

    /// 人可读的内容概览（导出后与恢复前都用它告诉用户「这里面有什么」）。
    var summary: Summary {
        Summary(
            categories: categories.count,
            libraryEntries: library.count,
            repositories: repositories.count,
            servers: servers.count
        )
    }

    struct Summary: Equatable {
        let categories: Int
        let libraryEntries: Int
        let repositories: Int
        let servers: Int
    }

    // MARK: 编解码

    /// 编码成写进文件的字节。
    ///
    /// `sortedKeys` 是刻意的：同样的数据每次导出的字节完全一致，
    /// 于是「备份文件有没有变」可以用 diff 看出来，测试里也能直接比字符串。
    ///
    /// 时间用 ISO8601（**不带小数秒**）：备份里的时间戳精确到秒就够了，
    /// 而少一种格式变体就少一处跨平台解析差异。代价是「编码再解码」会丢掉亚秒部分，
    /// 因此拿 `Date()` 直接往返比对必然不等——测试里专门有一条用例钉住这个精度。
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// 从文件字节解析。
    ///
    /// 三种失败分得很清楚，因为界面上要说的三句话完全不同：
    /// 文件是空的 / 不是备份文件 / 备份来自更新版本。
    static func decoded(from data: Data) throws -> BackupBundle {
        guard !data.isEmpty else { throw BackupError.emptyFile }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle: BackupBundle
        do {
            bundle = try decoder.decode(BackupBundle.self, from: data)
        } catch {
            throw BackupError.notABackup
        }
        guard bundle.version <= currentVersion else {
            throw BackupError.unsupportedVersion(bundle.version)
        }
        return bundle
    }
}

/// 备份里的服务器配置：**只有连接信息，没有任何凭据**。
struct BackupServer: Codable, Equatable {
    var id: String
    var kind: HostedServerKind
    var name: String
    var baseURL: String

    init(server: HostedServer) {
        self.id = server.id
        self.kind = server.kind
        self.name = server.name
        self.baseURL = server.normalizedBaseURL
    }

    /// 还原成可用的配置（凭据为空，界面会显示「无凭据」提醒重填）。
    func makeServer() -> HostedServer {
        HostedServer(id: id, kind: kind, name: name, baseURL: baseURL)
    }
}

enum BackupError: LocalizedError, Equatable {
    case emptyFile
    case notABackup
    case unsupportedVersion(Int)
    case unreadable

    var errorDescription: String? {
        switch self {
        case .emptyFile:
            return L("backup.error.empty")
        case .notABackup:
            return L("backup.error.notABackup")
        case let .unsupportedVersion(version):
            return String(format: L("backup.error.newerVersion"), version)
        case .unreadable:
            return L("backup.error.unreadable")
        }
    }
}

// MARK: - 合并规则（纯函数）

/// 「恢复时要写进什么」的判定。全是纯函数，因此可以逐条钉住。
enum BackupMerge {

    /// 需要新建的分类名。
    ///
    /// 按「忽略大小写与首尾空白」去重（`ModelValidation.categoryNameKey`），
    /// 与「新建分类不能重名」的规则保持一致——否则恢复完会出现两个「追更」。
    static func categoryNamesToCreate(
        backup: [LibraryCategory],
        existing: [LibraryCategory]
    ) -> [String] {
        var taken = Set(existing.map { ModelValidation.categoryNameKey($0.name) })
        var result: [String] = []
        for category in backup {
            let key = ModelValidation.categoryNameKey(category.name)
            guard !key.isEmpty, !taken.contains(key) else { continue }
            taken.insert(key)
            result.append(category.name)
        }
        return result
    }

    /// 需要新增的仓库地址（去掉已在本地存在的，保留原有顺序）。
    static func repositoriesToAdd(backup: [String], existing: [String]) -> [String] {
        var seen = Set(existing)
        var result: [String] = []
        for repository in backup {
            guard !seen.contains(repository) else { continue }
            seen.insert(repository)
            result.append(repository)
        }
        return result
    }

    /// 需要新增的服务器（按标识去重——同标识视为同一台，本地那份优先）。
    static func serversToAdd(backup: [BackupServer], existing: [HostedServer]) -> [BackupServer] {
        var seen = Set(existing.map(\.id))
        var result: [BackupServer] = []
        for server in backup {
            guard !seen.contains(server.id) else { continue }
            seen.insert(server.id)
            result.append(server)
        }
        return result
    }

    /// 需要写入的书架条目。
    ///
    /// **已存在的直接跳过**：本地那份带着更新的阅读进度，恢复不该把它冲掉。
    /// 这一条是整个恢复流程里唯一「会丢数据」的地方，所以它是显式规则而不是顺带行为。
    static func entriesToAdd(
        backup: [LibraryEntry],
        existingMangaIDs: Set<String>
    ) -> [LibraryEntry] {
        var seen = existingMangaIDs
        var result: [LibraryEntry] = []
        for entry in backup {
            guard !seen.contains(entry.manga.id) else { continue }
            seen.insert(entry.manga.id)
            result.append(entry)
        }
        return result
    }

    /// 分类归属的重映射：备份里的分类名 → 本地分类标识。
    ///
    /// 恢复分类时新分类会拿到**新的标识**（`createCategory` 自己生成），
    /// 所以条目的 `categoryID` 不能照抄，必须按名字重新对上；
    /// 对不上的（用户删掉了那个分类）落回「未分类」。
    static func categoryRemap(
        backupCategories: [LibraryCategory],
        localCategories: [LibraryCategory]
    ) -> [String: String] {
        var byName: [String: String] = [:]
        for category in localCategories {
            byName[ModelValidation.categoryNameKey(category.name)] = category.id
        }
        var remap: [String: String] = [:]
        for category in backupCategories {
            guard let target = byName[ModelValidation.categoryNameKey(category.name)] else { continue }
            remap[category.id] = target
        }
        return remap
    }
}

// MARK: - 恢复结果

/// 恢复完成后告诉用户「到底写进去了什么」。
///
/// 恢复是**合并**，所以「什么都没变」也是一个合法结果（本地都已存在），
/// 这时要明确说出来，而不是给一句含糊的「恢复成功」让人以为哪里没生效。
struct BackupRestoreReport: Equatable {
    var settingsApplied: Bool
    var categoriesCreated: Int
    var entriesAdded: Int
    var repositoriesAdded: Int
    var serversAdded: Int

    var changedAnything: Bool {
        settingsApplied
            || categoriesCreated > 0
            || entriesAdded > 0
            || repositoriesAdded > 0
            || serversAdded > 0
    }
}

// MARK: - SwiftUI 文件导出

/// 把备份字节交给系统文件导出面板。
struct BackupDocument: FileDocument {

    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw BackupError.unreadable
        }
        self.data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
