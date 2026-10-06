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
    /// 源仓库服务（拉索引 / 装脚本 / 查更新）。
    let repositoryService: SourceRepositoryService
    /// 已安装源的运行时池（按需载入 JS 沙箱，上限内复用与回收）。
    let runtimePool: SourceRuntimePool
    /// 自建服务器（Komga / Kavita）的配置。
    let serverStore: ServerStore
    /// 数据来源总入口：自建服务器走 REST 连接器，其余走脚本源运行时池。
    let dataSourceProvider: CompositeDataSourceProvider
    /// 图片字节加载器（封面 / 漫画页）。走来源 Cookie 与 20 MB 上限。
    let imageLoader: SourceImageLoader
    /// 本地文件源的阅读适配器。
    private let localReadingSource: LocalReadingSource
    /// 在线来源的阅读适配器（章节 / 页列表缓存 + 图片加载 + 已下载章节优先）。
    private let remoteReadingSource: RemoteReadingSource
    /// 下载归档（已下载章节的 CBZ）。
    let archiveStore: DownloadArchiveStore
    /// 下载编排（入队 / 进度 / 归档）。界面只跟它打交道。
    let downloads: DownloadCoordinator
    /// 下载期间的后台执行断言（用户切走 App 后还能多跑一会儿）。
    let backgroundExecution: BackgroundExecutionKeeper

    init(
        settings: AppSettings,
        sourceStore: SourceStore,
        cookieJar: CookieJar,
        diagnostics: DiagnosticsLog,
        libraryStore: LibraryStoring,
        localSource: LocalSource,
        dataDirectory: URL,
        isLibraryPersistent: Bool,
        coverCache: CoverThumbnailCache? = nil,
        repositoryService: SourceRepositoryService? = nil,
        runtimePool: SourceRuntimePool? = nil,
        imageLoader: SourceImageLoader? = nil,
        archiveStore: DownloadArchiveStore? = nil,
        downloads: DownloadCoordinator? = nil,
        serverStore: ServerStore? = nil,
        dataSourceProvider: CompositeDataSourceProvider? = nil
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

        let resolvedImageLoader = imageLoader ?? SourceImageLoader(cookieJar: cookieJar)
        self.imageLoader = resolvedImageLoader

        // 源侧依赖：仓库请求走一个独立的 HTTP 客户端（不带任何来源 Cookie——
        // 拉索引时用户还没选定来源，带上 Cookie 既无意义也泄露面更大）。
        self.repositoryService = repositoryService ?? SourceRepositoryService(
            store: sourceStore,
            client: HTTPClient(transport: URLSessionTransport())
        )

        let resolvedPool: SourceRuntimePool
        if let runtimePool {
            resolvedPool = runtimePool
        } else {
            // 所有来源共用一个 `DefaultSourceTransport`：它内部已按来源
            // 分别持有 HTTPClient 与限速器，源之间互不影响。
            let transport = DefaultSourceTransport(cookieJar: cookieJar)
            resolvedPool = SourceRuntimePool(
                store: sourceStore,
                logSink: { level, message in
                    diagnostics.log("[源运行时] \(level): \(message)")
                },
                makeRuntime: { meta in
                    JSSourceRuntime(
                        transport: transport,
                        preferences: UserDefaultsSourcePreferences(),
                        logSink: { level, message in
                            diagnostics.log("[源 \(meta.id.rawValue)] \(level): \(message)")
                        }
                    )
                }
            )
        }
        self.runtimePool = resolvedPool

        // 下载归档：`Downloads/` 存成品 CBZ，`DownloadScratch/` 是抓取过程中的散图。
        // 分两个目录是刻意的——归档目录里出现任何东西都意味着「这一章能离线看」，
        // 混进散图会让「文件在 = 下完了」这条判断失效。
        let resolvedArchive = archiveStore ?? DownloadArchiveStore(
            rootDirectory: dataDirectory.appendingPathComponent("Downloads", isDirectory: true)
        )
        self.archiveStore = resolvedArchive

        // 自建服务器：配置存一个 JSON；请求走**独立的** HTTP 客户端
        // （不挂任何来源 Cookie——那是脚本源的容器，服务器用自己的凭据）。
        let resolvedServerStore = serverStore ?? ServerStore(
            fileURL: dataDirectory.appendingPathComponent("Servers.json", isDirectory: false)
        )
        self.serverStore = resolvedServerStore

        let resolvedProvider = dataSourceProvider ?? CompositeDataSourceProvider(
            hosted: HostedDataSourceProvider(
                store: resolvedServerStore,
                client: HTTPClient(transport: URLSessionTransport())
            ),
            scripts: resolvedPool
        )
        self.dataSourceProvider = resolvedProvider

        // 阅读适配器：本地走 LocalSource（同步 → 异步），在线走数据来源 + 图片加载器；
        // 在线侧带上归档，于是「已下载的章节」离线可读、也不会重复走网络。
        self.localReadingSource = LocalReadingSource(localSource: localSource)
        self.remoteReadingSource = RemoteReadingSource(
            provider: resolvedProvider,
            imageLoader: resolvedImageLoader,
            archive: resolvedArchive
        )

        let keeper = BackgroundExecutionKeeper()
        self.backgroundExecution = keeper

        if let downloads {
            self.downloads = downloads
        } else {
            self.downloads = DownloadCoordinator(
                archive: resolvedArchive,
                scratchDirectory: dataDirectory.appendingPathComponent("DownloadScratch", isDirectory: true),
                imageLoader: resolvedImageLoader,
                loadPageList: { sourceID, chapterURL in
                    try await resolvedProvider.dataSource(for: sourceID).pageList(chapterURL: chapterURL)
                },
                log: { message in
                    diagnostics.log("[下载] \(message)")
                },
                beginBackgroundWork: {
                    // `@MainActor` 隔离：协调器本身就在主线程上跑，这里只是跳一次隔离
                    Task { @MainActor in
                        keeper.begin(name: "manga-download")
                    }
                },
                endBackgroundWork: {
                    Task { @MainActor in keeper.end() }
                }
            )
        }
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

    /// 界面上**可见**的已安装源：成人内容源在用户未于设置中开启时被过滤掉。
    ///
    /// 界面一律用这个而不是 `installedSources`——过滤规则只在一处实现
    /// （`SourceVisibilityRule`），避免某个页面漏掉。
    var visibleInstalledSources: [InstalledSource] {
        SourceVisibilityRule.visible(installedSources, showsNSFWSources: settings.showsNSFWSources)
    }

    /// 被隐藏的已安装源数量（界面据此提示「另有 N 个成人内容源已隐藏」）。
    var hiddenSourceCount: Int {
        SourceVisibilityRule.hidden(installedSources, showsNSFWSources: settings.showsNSFWSources).count
    }

    // MARK: 浏览来源（脚本源 + 自建服务器）

    /// 已配置的自建服务器。
    var hostedServers: [HostedServer] {
        serverStore.all()
    }

    /// 浏览页要显示的来源列表。
    ///
    /// 顺序：自建服务器在前（那是用户自己的库，最常用），脚本源随后。
    /// 成人内容过滤只作用于脚本源——服务器上的内容由用户自己管理。
    var browseSources: [BrowseSource] {
        let hosted = hostedServers.map { BrowseSource(server: $0) }
        let scripts = SourceVisibilityRule
            .visible(installedSources, showsNSFWSources: settings.showsNSFWSources)
            .map { BrowseSource(installed: $0) }
        return hosted + scripts
    }

    /// 某个来源标识是否能解析成数据来源（用于界面提前禁用无效入口）。
    func canResolveSource(_ sourceID: SourceID) -> Bool {
        serverStore.server(id: sourceID.rawValue) != nil || sourceStore.isInstalled(sourceID.rawValue)
    }

    /// 取某个来源的数据来源（脚本源会按需载入沙箱；服务器会建连接器）。
    func dataSource(for sourceID: SourceID) async throws -> MangaDataSource {
        try await dataSourceProvider.dataSource(for: sourceID)
    }

    // MARK: 登录与人工验证（契约 §8）

    /// 源的登录页地址（脚本声明 `loginUrl` 才有）。
    ///
    /// 会做一次静态校验来读元信息——比载入 JS 沙箱便宜得多
    /// （界面只是要判断「要不要显示登录按钮」）。
    func loginURL(for sourceID: SourceID) -> String? {
        guard let script = try? sourceStore.script(for: sourceID.rawValue),
              let meta = try? SourceScriptValidator.validate(script)
        else { return nil }
        guard let login = meta.loginURL, !login.isEmpty else { return nil }
        return login
    }

    /// 「打开网页验证」用的地址：优先登录页，其次来源主页 / 服务器地址。
    ///
    /// 人工验证（Cloudflare 之类）发生在**任意**页面上，所以没有登录页时
    /// 也要能给一个入口——退化成来源主页，用户在那里点过验证后
    /// 同域的 Cookie 一样会被收割。
    func webVerificationURL(for sourceID: SourceID) -> String? {
        if let login = loginURL(for: sourceID) { return login }
        if let server = serverStore.server(id: sourceID.rawValue) {
            return server.normalizedBaseURL
        }
        guard let script = try? sourceStore.script(for: sourceID.rawValue),
              let meta = try? SourceScriptValidator.validate(script)
        else { return nil }
        let base = meta.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (base?.isEmpty == false) ? base : nil
    }

    /// 该来源容器里是否已有 Cookie（界面据此显示「退出登录」）。
    func hasSourceCookies(_ sourceID: SourceID) -> Bool {
        cookieJar.hasCookies(for: sourceID)
    }

    /// 清空该来源的 Cookie（同时落盘）。
    func clearSourceCookies(_ sourceID: SourceID) {
        cookieJar.clear(sourceID: sourceID)
        // `persist()` 是 throwing（写盘可能失败）；这里失败不致命——
        // 内存里的容器已经清干净了，只是磁盘上还留着旧值，下次启动会再清一遍。
        try? cookieJar.persist()
        diag("AppEnvironment: 已清空来源 \(sourceID.rawValue) 的登录状态")
    }

    // MARK: 自建服务器

    /// 添加一台服务器（id 由名称派生，冲突自动加序号）。
    @discardableResult
    func addHostedServer(
        kind: HostedServerKind,
        name: String,
        baseURL: String,
        apiKey: String? = nil,
        username: String? = nil,
        password: String? = nil
    ) throws -> HostedServer {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw AppError.invalidInput("请填一个名字") }
        guard HostedServer.isValidBaseURL(baseURL) else {
            throw AppError.invalidInput("服务器地址要以 http:// 或 https:// 开头")
        }
        let existing = Set(serverStore.all().map(\.id))
        let identifier = HostedServer.makeID(kind: kind, name: trimmedName, existing: existing)
        let server = HostedServer(
            id: identifier,
            kind: kind,
            name: trimmedName,
            baseURL: baseURL,
            apiKey: apiKey,
            username: username,
            password: password
        )
        try serverStore.add(server)
        diag("AppEnvironment: 已添加 \(kind.displayName) 服务器 \(identifier)")
        return server
    }

    /// 更新一台服务器（地址 / 凭据）。
    func updateHostedServer(_ server: HostedServer) throws {
        try serverStore.update(server)
    }

    /// 移除一台服务器。返回是否真的删掉了。
    @discardableResult
    func removeHostedServer(id: String) throws -> Bool {
        try serverStore.remove(id: id)
    }

    /// 连接自检：给用户一句「连得上吗」的答复。
    func probeHostedServer(_ server: HostedServer) async -> Result<String, HostedServerError> {
        do {
            let source = try await dataSourceProvider.dataSource(for: server.sourceID)
            guard let probing = source as? MangaDataSourceProbing else {
                return .success("已连接")
            }
            return .success(try await probing.probe())
        } catch let error as HostedServerError {
            return .failure(error)
        } catch {
            return .failure(HostedServerError.map(error))
        }
    }

    // MARK: 源仓库

    /// 刷新全部仓库目录。单个仓库失败只影响该条结果，不影响其他仓库。
    func reloadRepositoryCatalogs() async -> [RepositoryCatalogResult] {
        await repositoryService.catalogs()
    }

    /// 安装仓库里的某个源；成功后回收同 key 的旧运行时与阅读缓存（脚本内容已变）。
    @discardableResult
    func installSource(_ entry: RepositoryEntry) async throws -> InstalledSource {
        let installed = try await repositoryService.install(entry)
        await runtimePool.invalidate(installed.key)
        await remoteReadingSource.invalidate(sourceID: SourceID(installed.key))
        diag("AppEnvironment: 已安装源 \(installed.key) v\(installed.version ?? "-")")
        return installed
    }

    /// 卸载源并回收其运行时与阅读缓存。
    @discardableResult
    func uninstallSource(_ key: String) async throws -> Bool {
        let removed = try sourceStore.uninstall(key: key)
        if removed {
            await runtimePool.invalidate(key)
            await remoteReadingSource.invalidate(sourceID: SourceID(key))
        }
        return removed
    }

    // MARK: 阅读数据来源

    /// 取某个作品的阅读数据来源：本地文件源或在线来源。
    ///
    /// 阅读器只认 `MangaReadingSource`，因此这里的分支是**唯一**一处
    /// 「本地 / 在线」的判定。
    func readingSource(for manga: Manga) -> MangaReadingSource {
        manga.sourceID == .local ? localReadingSource : remoteReadingSource
    }

    // MARK: 源运行

    /// 取某个源的运行器（首次会载入脚本，之后复用）。
    ///
    /// - Warning: 这种方式拿到的运行器**不受租约保护**，可能在池内淘汰时被回收。
    ///   长时间操作请直接用 `runtimePool.withRunner(for:_:)`。
    func sourceRunner(for key: String) async throws -> SourceRunner {
        try await runtimePool.runner(for: key)
    }

    /// 归还租约（与 `sourceRunner(for:)` 配对）。
    func releaseSource(_ key: String) async {
        await runtimePool.release(key)
    }

    /// 回收全部源运行时与阅读缓存（设置页「全部重载」、或内存吃紧时调用）。
    func releaseAllSourceRuntimes() async {
        await runtimePool.invalidateAll()
        await remoteReadingSource.invalidateAll()
    }

    /// 文件系统里的本地作品（不依赖数据库）。
    func localBooks() -> [Manga] {
        (try? localSource.books()) ?? []
    }

    /// 本地作品的封面缩略图（取首页 → 缩放 → 缓存）。取不到返回 nil。
    ///
    /// 只在 `sourceID == .local` 时可用；在线源的封面走 `loadRemoteCover(for:)`。
    func coverThumbnail(for manga: Manga) -> Data? {
        guard manga.sourceID == .local else { return nil }
        let source = localSource
        return coverCache.thumbnail(mangaID: manga.id) {
            try source.coverData(for: manga)
        }
    }

    /// 在线来源的封面原始字节（未缩放）。
    ///
    /// 交给 `CoverThumbnailView` 后再进同一个缓存做缩放与落盘；
    /// 这里只保证「带该来源的 Cookie、受体积上限保护、失败不抛给界面」。
    func loadRemoteCover(for manga: Manga) async -> Data? {
        guard manga.sourceID != .local, let coverURL = manga.coverURL else { return nil }
        do {
            return try await imageLoader.imageData(
                forURL: coverURL,
                sourceID: manga.sourceID,
                // 防盗链站点常要求封面请求带作品页作 Referer
                referer: manga.url
            )
        } catch {
            diag("AppEnvironment: 封面下载失败 —— \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: 下载

    /// 书架里的作品（不在书架里返回 nil）。
    ///
    /// 下载页只拿得到主键；要显示作品名或让用户点进去阅读，就得回到书架查。
    func libraryEntryManga(mangaID: String) -> Manga? {
        (try? libraryStore.entry(mangaID: mangaID))?.manga
    }

    /// 某章是否已下载到本地（界面据此显示「已下载」并停用下载按钮）。
    func isChapterDownloaded(mangaID: String, chapterID: String) -> Bool {
        archiveStore.hasChapter(mangaID: mangaID, chapterID: chapterID)
    }

    /// 下载一批章节（「下载全部」）。
    @discardableResult
    func downloadChapters(_ chapters: [Chapter], of manga: Manga) async -> DownloadRequestResult {
        await downloads.download(manga: manga, chapters: chapters)
    }

    /// 加入书架。已存在时只更新作品信息，**不覆盖阅读进度**。
    @discardableResult
    func addToLibrary(_ manga: Manga, categoryID: String? = nil) -> LibraryEntry? {
        if let existing = try? libraryStore.entry(mangaID: manga.id) {
            var updated = existing
            updated.manga = manga
            // `save` 返回 Void，用 `_ =` 显式丢弃 `try?` 的包装结果，
            // 否则会报 "result of 'try?' is unused"。
            _ = try? libraryStore.save(updated)
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
