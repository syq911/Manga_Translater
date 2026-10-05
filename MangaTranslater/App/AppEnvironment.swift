//
//  AppEnvironment.swift
//  MangaTranslater
//
//  应用级依赖容器。集中持有设置、源仓库、Cookie、书架存储、本地文件源与诊断日志，
//  通过 SwiftUI Environment 下发给各视图，避免视图各自 new 一份。
//

import Foundation
import Observation
import AppCore
import ComicNet
import SourceEngine
import ComicDownload
import AppDatabase

@MainActor
@Observable
final class AppEnvironment {

    let settings: AppSettings
    let sourceStore: SourceStore
    let cookieJar: CookieJar
    let diagnostics: DiagnosticsLog
    /// 书架存储（正常为 GRDB；磁盘不可用时降级为内存实现）。
    let libraryStore: LibraryStoring
    /// 本地文件源（CBZ / ZIP）。
    let localSource: LocalSource
    /// 应用数据根目录（Application Support/MangaTranslater）。
    let dataDirectory: URL
    /// 书架是否持久化。false 表示已降级为内存存储（UI 应提示用户）。
    let isLibraryPersistent: Bool
    /// 封面缩略图缓存（内存 + 磁盘）。
    let coverCache: CoverThumbnailCache

    init(
        settings: AppSettings,
        sourceStore: SourceStore,
        cookieJar: CookieJar,
        diagnostics: DiagnosticsLog,
        libraryStore: LibraryStoring,
        localSource: LocalSource,
        dataDirectory: URL,
        isLibraryPersistent: Bool,
        coverCache: CoverThumbnailCache? = nil
    ) {
        self.settings = settings
        self.sourceStore = sourceStore
        self.cookieJar = cookieJar
        self.diagnostics = diagnostics
        self.libraryStore = libraryStore
        self.localSource = localSource
        self.dataDirectory = dataDirectory
        self.isLibraryPersistent = isLibraryPersistent
        // 默认按数据目录派生，测试可注入替身
        self.coverCache = coverCache ?? CoverThumbnailCache(dataDirectory: dataDirectory)
    }

    /// 按默认路径构建。任一步失败都降级而非崩溃，保证 App 一定能启动。
    static func makeDefault() -> AppEnvironment {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let root = base.appendingPathComponent("MangaTranslater", isDirectory: true)

        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            diag("AppEnvironment: 无法创建数据目录，退回临时目录 —— \(error.localizedDescription)")
        }

        let settings = AppSettings()
        let sourceStore = SourceStore(rootDirectory: root.appendingPathComponent("SourcesRoot", isDirectory: true))
        let cookieJar = CookieJar(storageURL: root.appendingPathComponent("cookies.json", isDirectory: false))
        let localSource = LocalSource(rootDirectory: root.appendingPathComponent("LocalLibrary", isDirectory: true))

        // 书架：优先持久化；失败则降级为内存并明确告知 UI
        var libraryStore: LibraryStoring
        var isPersistent = true
        do {
            let database = try AppDatabase.open(
                .file(root.appendingPathComponent("library.sqlite", isDirectory: false))
            )
            libraryStore = DatabaseLibraryStore(database: database)
        } catch {
            diag("AppEnvironment: 书架数据库不可用，降级为内存存储 —— \(error.localizedDescription)")
            libraryStore = InMemoryLibraryStore()
            isPersistent = false
        }

        diag("AppEnvironment: 启动，数据目录 = \(root.path)，书架持久化 = \(isPersistent)")
        return AppEnvironment(
            settings: settings,
            sourceStore: sourceStore,
            cookieJar: cookieJar,
            diagnostics: .shared,
            libraryStore: libraryStore,
            localSource: localSource,
            dataDirectory: root,
            isLibraryPersistent: isPersistent
        )
    }

    // MARK: 便捷访问

    /// 已在设置页与浏览页重复使用的「已安装源」快照。
    var installedSources: [InstalledSource] {
        sourceStore.installedSources()
    }

    /// 已添加的源仓库（出厂为空）。
    var repositories: [String] {
        sourceStore.repositories
    }

    /// 文件系统里的本地作品（不依赖数据库）。
    func localBooks() -> [Manga] {
        (try? localSource.books()) ?? []
    }

    /// 本地作品的封面缩略图（取首页 → 缩放 → 缓存）。取不到返回 nil。
    ///
    /// 只在 `sourceID == .local` 时可用；在线源的封面走网络（M2 接入）。
    func coverThumbnail(for manga: Manga) -> Data? {
        guard manga.sourceID == .local else { return nil }
        let source = localSource
        return coverCache.thumbnail(mangaID: manga.id) {
            try source.coverData(for: manga)
        }
    }

    /// 加入书架。已存在时只更新作品信息，**不覆盖阅读进度**。
    @discardableResult
    func addToLibrary(_ manga: Manga, categoryID: String? = nil) -> LibraryEntry? {
        if let existing = try? libraryStore.entry(mangaID: manga.id) {
            var updated = existing
            updated.manga = manga
            try? libraryStore.save(updated)
            return updated
        }
        let entry = LibraryEntry(manga: manga, categoryID: categoryID)
        do {
            try libraryStore.save(entry)
            return entry
        } catch {
            diag("AppEnvironment: 加入书架失败 —— \(error.localizedDescription)")
            return nil
        }
    }
}
