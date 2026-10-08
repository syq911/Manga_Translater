//
//  BackupTests.swift
//  MangaTranslaterTests
//
//  备份 / 恢复（O-8）。
//
//  这个功能的风险不在「能不能导出」，而在两件**用户看不见**的事：
//
//  1. **凭据有没有跟着备份文件跑出去。** 备份文件会被丢进 iCloud、邮件、聊天窗口，
//     所以「文件里到底有什么」必须由测试钉死，而不是靠代码注释承诺。
//  2. **恢复会不会把本地进度冲掉。** 恢复的典型场景是换机或手机+平板，
//     两边都可能有更新的进度；一个「点一下就把本地冲掉」的恢复是危险品。
//
//  所以这里的断言集中在「不该出现的字节」与「不该被改的数据」上。
//

import Foundation
import Testing
import AppCore
import ComicNet
import SourceEngine
import AppDatabase
@testable import MangaTranslater

@Suite("备份 · 文件格式")
struct BackupFormatTests {

    private static func sampleManga(_ index: Int = 1) -> Manga {
        Manga(sourceID: SourceID("demo"), url: "https://example.com/m/\(index)", title: "M\(index)")
    }

    private static func sampleBundle() -> BackupBundle {
        let category = LibraryCategory(id: "cat-1", name: "追更", sortOrder: 0)
        var entry = LibraryEntry(manga: sampleManga(), categoryID: category.id)
        entry.lastReadChapterID = "demo|https://example.com/c/3"
        entry.lastReadPageIndex = 7
        entry.unreadCount = 2
        entry.isPinned = true
        return BackupBundle(
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000),
            appVersion: "1.0.0",
            settings: SettingsSnapshot(readerTheme: .sepia, fontScale: 1.4),
            repositories: ["https://example.com/repo.json"],
            categories: [category],
            library: [entry],
            servers: [BackupServer(server: HostedServer(
                id: "komga-nas",
                kind: .komga,
                name: "NAS",
                baseURL: "https://nas.local/"
            ))]
        )
    }

    @Test("编码 → 解码 往返一致")
    func roundTrip() throws {
        let bundle = Self.sampleBundle()
        let decoded = try BackupBundle.decoded(from: try bundle.encoded())
        #expect(decoded == bundle)
    }

    @Test("同样的数据每次导出的字节完全一致（用户可以 diff 两份备份）")
    func stableBytes() throws {
        let bundle = Self.sampleBundle()
        #expect(try bundle.encoded() == (try bundle.encoded()))
    }

    @Test("只有版本号的最小文件也能读：缺的字段用默认值")
    func minimalFile() throws {
        let data = Data(#"{"version": 1}"#.utf8)
        let bundle = try BackupBundle.decoded(from: data)
        #expect(bundle.version == 1)
        #expect(bundle.settings == SettingsSnapshot())
        #expect(bundle.library.isEmpty)
        #expect(bundle.categories.isEmpty)
        #expect(bundle.repositories.isEmpty)
        #expect(bundle.servers.isEmpty)
    }

    @Test("导出地址里带尾斜杠的服务器会被规范化（否则恢复后地址会漂）")
    func serverAddressIsNormalized() throws {
        let bundle = Self.sampleBundle()
        #expect(bundle.servers.first?.baseURL == "https://nas.local")
    }

    @Test("空文件：说得清是「文件是空的」")
    func emptyFile() {
        #expect(throws: BackupError.emptyFile) {
            _ = try BackupBundle.decoded(from: Data())
        }
    }

    @Test("不是备份文件：说得清是「这文件不对」，而不是抛一个 JSON 解析错误")
    func notABackup() {
        #expect(throws: BackupError.notABackup) {
            _ = try BackupBundle.decoded(from: Data("hello".utf8))
        }
        #expect(throws: BackupError.notABackup) {
            _ = try BackupBundle.decoded(from: Data("[]".utf8))
        }
    }

    @Test("来自更新版本的备份被明确拒绝，而不是尽力解析出半截数据")
    func futureVersionRejected() throws {
        let data = Data(#"{"version": 99}"#.utf8)
        #expect(throws: BackupError.unsupportedVersion(99)) {
            _ = try BackupBundle.decoded(from: data)
        }
    }

    @Test("三种失败对应三句不同的话（界面要说的话不一样）")
    func errorsHaveDistinctMessages() {
        let messages = [
            BackupError.emptyFile.errorDescription,
            BackupError.notABackup.errorDescription,
            BackupError.unsupportedVersion(2).errorDescription,
            BackupError.unreadable.errorDescription,
        ]
        let nonEmpty = messages.compactMap { $0 }.filter { !$0.isEmpty }
        #expect(nonEmpty.count == 4)
        #expect(Set(nonEmpty).count == 4, "四种错误的文案不能重复")
    }

    @Test("内容概览只数数量，不泄露内容")
    func summaryCounts() {
        let summary = Self.sampleBundle().summary
        #expect(summary.categories == 1)
        #expect(summary.libraryEntries == 1)
        #expect(summary.repositories == 1)
        #expect(summary.servers == 1)
    }
}

@Suite("备份 · 合并规则")
struct BackupMergeTests {

    private static func category(id: String, name: String) -> LibraryCategory {
        LibraryCategory(id: id, name: name)
    }

    private static func entry(_ index: Int) -> LibraryEntry {
        LibraryEntry(
            manga: Manga(
                sourceID: SourceID("demo"),
                url: "https://example.com/m/\(index)",
                title: "M\(index)"
            )
        )
    }

    @Test("分类按名字去重（忽略大小写与首尾空白，与「不能重名」的规则一致）")
    func categoryNamesDedupe() {
        let backup = [
            Self.category(id: "a", name: "追更"),
            Self.category(id: "b", name: " 追更 "),
            Self.category(id: "c", name: "TOREAD"),
            Self.category(id: "d", name: "已完结"),
        ]
        let existing = [Self.category(id: "x", name: "toread")]
        #expect(BackupMerge.categoryNamesToCreate(backup: backup, existing: existing) == ["追更", "已完结"])
    }

    @Test("空名字或纯空白名字的分类不会被建出来")
    func emptyCategoryNamesSkipped() {
        let backup = [Self.category(id: "a", name: "   "), Self.category(id: "b", name: "")]
        #expect(BackupMerge.categoryNamesToCreate(backup: backup, existing: []).isEmpty)
    }

    @Test("仓库取并集，且保持备份里的顺序")
    func repositoriesUnion() {
        let backup = ["https://a/repo.json", "https://b/repo.json", "https://a/repo.json"]
        let existing = ["https://b/repo.json"]
        #expect(BackupMerge.repositoriesToAdd(backup: backup, existing: existing) == ["https://a/repo.json"])
    }

    @Test("服务器按标识去重（同标识 = 同一台，本地那份优先）")
    func serversByIdentifier() {
        let backup = [
            BackupServer(server: HostedServer(id: "komga-a", kind: .komga, name: "A", baseURL: "https://a")),
            BackupServer(server: HostedServer(id: "kavita-b", kind: .kavita, name: "B", baseURL: "https://b")),
        ]
        let existing = [HostedServer(id: "komga-a", kind: .komga, name: "A(local)", baseURL: "https://a2")]
        let added = BackupMerge.serversToAdd(backup: backup, existing: existing)
        #expect(added.map(\.id) == ["kavita-b"])
    }

    @Test("书架条目：已存在的跳过（本地进度优先）")
    func entriesSkipExisting() {
        let backup = [Self.entry(1), Self.entry(2), Self.entry(1)]
        let existing: Set<String> = [Self.entry(1).manga.id]
        let added = BackupMerge.entriesToAdd(backup: backup, existingMangaIDs: existing)
        #expect(added.map(\.manga.id) == [Self.entry(2).manga.id])
    }

    @Test("分类归属按名字重映射（新分类会拿到新标识，不能照抄旧 ID）")
    func categoryRemapByName() {
        let backup = [Self.category(id: "old-1", name: "追更"), Self.category(id: "old-2", name: "已删")]
        let local = [Self.category(id: "new-1", name: "追更")]
        let remap = BackupMerge.categoryRemap(backupCategories: backup, localCategories: local)
        #expect(remap == ["old-1": "new-1"], "对不上的分类落回未分类，而不是指向一个不存在的 ID")
    }
}

@Suite("备份 · 端到端恢复")
@MainActor
struct BackupRestoreTests {

    /// 造一个「够用」的应用环境：内存书架 + 临时目录 + 独立 UserDefaults。
    private static func makeEnvironment() throws -> (AppEnvironment, URL) {
        let root = try TestFileSystem.makeTemporaryDirectory()
        let suiteName = "BackupRestoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let environment = AppEnvironment(
            settings: AppSettings(defaults: defaults),
            sourceStore: SourceStore(rootDirectory: root.appendingPathComponent("sources")),
            cookieJar: CookieJar(storageURL: root.appendingPathComponent("cookies.json")),
            diagnostics: DiagnosticsLog(directory: root),
            libraryStore: InMemoryLibraryStore(),
            localSource: LocalSource(rootDirectory: root.appendingPathComponent("local")),
            dataDirectory: root,
            isLibraryPersistent: false
        )
        return (environment, root)
    }

    @Test("备份文件里**没有**任何凭据（apiKey / 密码 / 用户名都不进去）")
    func backupContainsNoCredentials() throws {
        let (environment, root) = try Self.makeEnvironment()
        defer { TestFileSystem.remove(root) }

        try environment.serverStore.add(HostedServer(
            id: "komga-nas",
            kind: .komga,
            name: "NAS",
            baseURL: "https://nas.local",
            apiKey: "SECRET-API-KEY-9f3",
            username: "credential-user-9f3",
            password: "SECRET-PASSWORD-9f3"
        ))

        let text = String(decoding: try environment.makeBackupBundle().encoded(), as: UTF8.self)
        #expect(!text.contains("SECRET-API-KEY-9f3"))
        #expect(!text.contains("SECRET-PASSWORD-9f3"))
        #expect(!text.contains("credential-user-9f3"))
        // 但服务器本身要在——否则用户恢复完发现「服务器都没了」
        #expect(text.contains("komga-nas"))
    }

    @Test("端到端：A 导出、B 恢复，设置生效、进度与分类都跟着过来")
    func endToEndRestore() throws {
        let (source, sourceRoot) = try Self.makeEnvironment()
        defer { TestFileSystem.remove(sourceRoot) }

        source.settings.fontScale = 1.4
        let category = try source.libraryStore.createCategory(name: "追更")
        let manga = Manga(sourceID: SourceID("demo"), url: "https://example.com/m/1", title: "Sample")
        var entry = LibraryEntry(manga: manga, categoryID: category.id)
        entry.lastReadChapterID = "demo|https://example.com/c/7"
        entry.lastReadPageIndex = 12
        _ = try source.libraryStore.save(entry)
        _ = try source.sourceStore.addRepository("https://example.com/repo.json")
        try source.serverStore.add(HostedServer(
            id: "komga-nas", kind: .komga, name: "NAS", baseURL: "https://nas.local", apiKey: "k"
        ))

        let data = try source.makeBackupBundle().encoded()

        let (target, targetRoot) = try Self.makeEnvironment()
        defer { TestFileSystem.remove(targetRoot) }

        let bundle = try BackupBundle.decoded(from: data)
        let report = try target.restore(from: bundle)

        #expect(report.settingsApplied)
        #expect(report.categoriesCreated == 1)
        #expect(report.entriesAdded == 1)
        #expect(report.repositoriesAdded == 1)
        #expect(report.serversAdded == 1)
        #expect(report.changedAnything)

        #expect(target.settings.fontScale == 1.4, "设置是**覆盖**语义（用户在确认弹窗里已经被告知）")
        let restored = try #require(try target.libraryStore.entry(mangaID: manga.id))
        #expect(restored.lastReadChapterID == "demo|https://example.com/c/7")
        #expect(restored.lastReadPageIndex == 12)
        #expect(restored.categoryID != nil, "分类归属按名字重新对上")
        #expect(target.repositories.contains("https://example.com/repo.json"))
        #expect(target.hostedServers.count == 1)
        #expect(target.hostedServers.first?.hasCredentials == false, "凭据不进备份，界面会提示重填")
    }

    @Test("恢复是合并：本地已有的作品（进度更新）不被覆盖")
    func restoreDoesNotClobberLocalProgress() throws {
        let (source, sourceRoot) = try Self.makeEnvironment()
        defer { TestFileSystem.remove(sourceRoot) }
        let manga = Manga(sourceID: SourceID("demo"), url: "https://example.com/m/1", title: "Sample")
        var older = LibraryEntry(manga: manga)
        older.lastReadChapterID = "demo|https://example.com/c/1"
        older.lastReadPageIndex = 3
        _ = try source.libraryStore.save(older)
        _ = try source.libraryStore.createCategory(name: "追更")
        let data = try source.makeBackupBundle().encoded()

        let (target, targetRoot) = try Self.makeEnvironment()
        defer { TestFileSystem.remove(targetRoot) }
        var newer = LibraryEntry(manga: manga)
        newer.lastReadChapterID = "demo|https://example.com/c/9"
        newer.lastReadPageIndex = 99
        _ = try target.libraryStore.save(newer)
        _ = try target.libraryStore.createCategory(name: "追更")

        let report = try target.restore(from: BackupBundle.decoded(from: data))

        #expect(report.entriesAdded == 0, "已有作品跳过")
        #expect(report.categoriesCreated == 0, "同名分类不重复创建")
        #expect(report.repositoriesAdded == 0)
        #expect(report.serversAdded == 0)
        let kept = try #require(try target.libraryStore.entry(mangaID: manga.id))
        #expect(kept.lastReadPageIndex == 99, "本地进度优先——这是恢复流程里唯一可能丢数据的地方")
    }

    @Test("什么都没得恢复时也如实说：不谎称「恢复成功」")
    func noOpRestoreIsReported() throws {
        let (environment, root) = try Self.makeEnvironment()
        defer { TestFileSystem.remove(root) }
        let empty = BackupBundle(appVersion: "1.0.0", settings: SettingsSnapshot())

        let report = try environment.restore(from: empty)

        // 设置一定会被应用，所以「什么都不做」在这种语义下不存在——
        // 界面据此说「设置已应用」而不是「恢复成功」。
        #expect(report.settingsApplied)
        #expect(report.categoriesCreated == 0)
        #expect(report.entriesAdded == 0)
        #expect(report.repositoriesAdded == 0)
        #expect(report.serversAdded == 0)
    }
}
