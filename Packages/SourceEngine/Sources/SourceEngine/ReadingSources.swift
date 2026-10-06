//
//  ReadingSources.swift
//  SourceEngine
//
//  阅读数据的两个实现：本地文件源（同步 → 异步适配）与在线来源（运行时池 + 图片加载）。
//
//  为什么适配层放在 SourceEngine 而不是 App：
//  `LocalSource` 与 `SourceRuntimePool` 都在这个包里，适配器只是它们的薄壳；
//  放在这里就能被单元测试直接覆盖，阅读器那边只看到一个 `MangaReadingSource`。
//
//  两条实现共同的约定：
//  - **失败语义向上传递**，不吞错：阅读器需要区分「这一章没有页」与「网络失败了」；
//  - 单页取图失败由阅读器决定怎么办（跳过并提示），适配层不代它做决定。
//

import Foundation
import AppCore
import ComicDownload

// MARK: - 本地文件源

/// 把本地文件源的**同步**接口包成阅读器需要的异步接口。
///
/// 为什么内部用 `Task.detached` 而不是直接同步调用：解压与读盘是阻塞操作。
/// 阅读器的加载入口跑在主线程（SwiftUI 的 `.task`），直接同步调用会把
/// 解压耗时算进主线程——本地大归档翻页时的卡顿就是这么来的。
public struct LocalReadingSource: MangaReadingSource {

    private let localSource: LocalSource

    public init(localSource: LocalSource) {
        self.localSource = localSource
    }

    public func chapters(for manga: Manga) async throws -> [Chapter] {
        let source = localSource
        return try await Task.detached(priority: .userInitiated) {
            try source.chapters(for: manga)
        }.value
    }

    public func pages(for chapter: Chapter, manga: Manga) async throws -> [ComicPage] {
        let source = localSource
        return try await Task.detached(priority: .userInitiated) {
            try source.pages(for: chapter, manga: manga)
        }.value
    }

    public func imageData(for page: ComicPage, manga: Manga, chapter: Chapter) async throws -> Data {
        let source = localSource
        _ = chapter     // 本地页的定位信息已在 page.imageURL 里
        return try await Task.detached(priority: .userInitiated) {
            try source.imageDataSync(for: page, manga: manga)
        }.value
    }
}

// MARK: - 在线来源

/// 用「某个数据来源」取章节、页列表与图片。
///
/// 职责边界：
/// - 「数据从哪来」交给 `MangaDataSourceProviding`：脚本源走运行时池，
///   自建服务器（Komga / Kavita）走各自的 REST 连接器——本类型不需要知道；
/// - 「怎么取图片字节」交给 `SourceImageLoader`（体积上限、Referer、Cookie）；
/// - 本类型只做**缓存**与**串联**。
///
/// 缓存的两点考虑：
/// 1. 阅读时来回翻章很常见，章节列表与页列表**没必要每次重取**；
/// 2. 缓存必须能按来源失效——源脚本更新后旧结果就是错的
///    （`invalidate(sourceID:)`，由 App 在安装/更新/卸载后调用）。
public actor RemoteReadingSource: MangaReadingSource {

    /// 缓存配置。上限都按「条数」计，不做字节估算——这里缓存的是元数据，很小。
    public struct Configuration: Sendable, Equatable {
        /// 缓存多少个作品的章节列表。
        public var maxCachedChapterLists: Int
        /// 缓存多少章的页列表。
        public var maxCachedPageLists: Int

        public init(maxCachedChapterLists: Int = 8, maxCachedPageLists: Int = 16) {
            self.maxCachedChapterLists = max(1, maxCachedChapterLists)
            self.maxCachedPageLists = max(1, maxCachedPageLists)
        }
    }

    private let provider: MangaDataSourceProviding
    private let imageLoader: SourceImageLoader
    private let configuration: Configuration
    /// 下载归档（可选）。装了它才有「离线可读 + 不重复下载」。
    private let archive: DownloadArchiveStore?

    /// 作品主键 → 章节列表；以及最近使用顺序（末尾最新）。
    private var chapterLists: [String: [Chapter]] = [:]
    private var chapterOrder: [String] = []
    /// 章节主键 → 页列表。
    private var pageLists: [String: [ComicPage]] = [:]
    private var pageOrder: [String] = []

    public init(
        provider: MangaDataSourceProviding,
        imageLoader: SourceImageLoader,
        archive: DownloadArchiveStore? = nil,
        configuration: Configuration = Configuration()
    ) {
        self.provider = provider
        self.imageLoader = imageLoader
        self.archive = archive
        self.configuration = configuration
    }

    /// 只用脚本源时的便捷构造（测试与旧调用点用）。
    public init(
        pool: SourceRuntimePool,
        imageLoader: SourceImageLoader,
        archive: DownloadArchiveStore? = nil,
        configuration: Configuration = Configuration()
    ) {
        self.init(
            provider: pool,
            imageLoader: imageLoader,
            archive: archive,
            configuration: configuration
        )
    }

    // MARK: 章节

    public func chapters(for manga: Manga) async throws -> [Chapter] {
        if let cached = chapterLists[manga.id] {
            touch(&chapterOrder, manga.id)
            return cached
        }
        let source = try await provider.dataSource(for: manga.sourceID)
        let url = manga.url
        let identifier = manga.id
        let loaded = try await source.chapterList(mangaURL: url, mangaID: identifier)
        store(loaded, for: manga.id, into: &chapterLists, order: &chapterOrder,
              limit: configuration.maxCachedChapterLists)
        return loaded
    }

    // MARK: 页

    public func pages(for chapter: Chapter, manga: Manga) async throws -> [ComicPage] {
        if let cached = pageLists[chapter.id] {
            touch(&pageOrder, chapter.id)
            return cached
        }
        // 已下载的章节**不问脚本**：脚本要联网，而下载的意义就是没网也能看。
        // 页定位符用归档私有 scheme，读图时由 `imageData` 直接命中归档
        // （绝不会真的发出去，所以不必是 http(s)）。
        if let archived = archivedPages(mangaID: manga.id, chapterID: chapter.id) {
            store(archived, for: chapter.id, into: &pageLists, order: &pageOrder,
                  limit: configuration.maxCachedPageLists)
            return archived
        }
        let source = try await provider.dataSource(for: manga.sourceID)
        let url = chapter.url
        let loaded = try await source.pageList(chapterURL: url)
        store(loaded, for: chapter.id, into: &pageLists, order: &pageOrder,
              limit: configuration.maxCachedPageLists)
        return loaded
    }

    // MARK: 归档（离线阅读）

    /// 归档页的定位符前缀。
    ///
    /// 用私有 scheme 而不是伪造一个 http 地址：伪造地址一旦因为某条分支漏了拦截，
    /// 就会真的朝一个不存在的域名发请求；私有 scheme 只会立刻报「不支持的协议」，
    /// 问题定位成本低得多。
    public static let archiveURLScheme = "manga-archive"

    /// 某章是否已下载到本地。
    public nonisolated func isChapterArchived(mangaID: String, chapterID: String) -> Bool {
        archive?.hasChapter(mangaID: mangaID, chapterID: chapterID) ?? false
    }

    /// 某作品已下载的章节标识集合（作品详情页用来打「已下载」标记）。
    public nonisolated func archivedChapterIDs(mangaID: String) -> Set<String> {
        guard let archive else { return [] }
        return Set(archive.chapters(mangaID: mangaID).map(\.chapterID))
    }

    /// 已归档章节的页列表；未归档返回 nil。
    ///
    /// 页数取归档里的**真实条目数**而不是清单记录：清单可能因为旧版本没有写全，
    /// 而能读出来的页才是真能看的页。
    private func archivedPages(mangaID: String, chapterID: String) -> [ComicPage]? {
        guard let archive,
              let count = archive.pageCount(mangaID: mangaID, chapterID: chapterID),
              count > 0
        else { return nil }
        return (0..<count).map { index in
            ComicPage(index: index, imageURL: "\(Self.archiveURLScheme)://\(index)")
        }
    }

    // MARK: 图片

    /// 取页图。
    ///
    /// 标记 `nonisolated` 是刻意的：这条路完全不碰 actor 状态（缓存里只有元数据），
    /// 而图片下载可能持续几百毫秒——没必要让它们排队经过同一个 actor。
    ///
    /// 顺序是**先归档、后网络**：已下载的章节不该再耗一次流量，
    /// 且下载的意义就是没网也能看（离线时若先试网络，会先卡一次超时）。
    public nonisolated func imageData(
        for page: ComicPage,
        manga: Manga,
        chapter: Chapter
    ) async throws -> Data {
        if let archive,
           let local = archive.pageData(
               mangaID: manga.id,
               chapterID: chapter.id,
               pageIndex: page.index
           ) {
            return local
        }
        return try await imageLoader.imageData(
            for: page,
            sourceID: manga.sourceID,
            // 防盗链站点常要求图片请求带章节页作 Referer
            referer: chapter.url
        )
    }

    // MARK: 缓存管理

    /// 丢掉某个来源的全部缓存（安装 / 更新 / 卸载该源之后必须调用）。
    public func invalidate(sourceID: SourceID) {
        let prefix = "\(sourceID.rawValue)|"
        chapterLists = chapterLists.filter { !$0.key.hasPrefix(prefix) }
        chapterOrder.removeAll { $0.hasPrefix(prefix) }
        pageLists = pageLists.filter { !$0.key.hasPrefix(prefix) }
        pageOrder.removeAll { $0.hasPrefix(prefix) }
    }

    public func invalidateAll() {
        chapterLists.removeAll()
        chapterOrder.removeAll()
        pageLists.removeAll()
        pageOrder.removeAll()
    }

    /// 当前缓存的章节列表数量（诊断与测试用）。
    public var cachedChapterListCount: Int { chapterLists.count }
    /// 当前缓存的页列表数量。
    public var cachedPageListCount: Int { pageLists.count }

    // MARK: 内部

    private func touch(_ order: inout [String], _ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func store(
        _ value: [Chapter],
        for key: String,
        into storage: inout [String: [Chapter]],
        order: inout [String],
        limit: Int
    ) {
        storage[key] = value
        touch(&order, key)
        while order.count > limit {
            let oldest = order.removeFirst()
            storage.removeValue(forKey: oldest)
        }
    }

    private func store(
        _ value: [ComicPage],
        for key: String,
        into storage: inout [String: [ComicPage]],
        order: inout [String],
        limit: Int
    ) {
        storage[key] = value
        touch(&order, key)
        while order.count > limit {
            let oldest = order.removeFirst()
            storage.removeValue(forKey: oldest)
        }
    }
}
