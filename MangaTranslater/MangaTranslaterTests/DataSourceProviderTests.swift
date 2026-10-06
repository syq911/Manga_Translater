//
//  DataSourceProviderTests.swift
//  MangaTranslaterTests
//
//  数据来源路由：自建服务器与社区脚本源必须各走各的路。
//
//  这个路由写错的表现很难查：脚本源的池在遇到未知 id 时会抛「源未安装」，
//  如果靠「挨个 try」来路由，服务器地址填错会显示成「源未安装」——
//  排查方向直接跑偏。所以这里把「谁的 id 归谁」钉死。
//

import Foundation
import Testing
import AppCore
import ComicNet
import SourceEngine
import AppDatabase
@testable import MangaTranslater

@Suite("数据来源路由")
struct DataSourceProviderTests {

    private static let script = """
    const source = { id: "demo", name: "示例源", lang: "all", version: "1.0.0" };

    function getPopularManga(page) { return { mangas: [], hasNextPage: false }; }
    function getSearchManga(page, query, filters) { return { mangas: [], hasNextPage: false }; }
    function getMangaDetails(url) { return { title: "T", url: url }; }
    function getChapterList(url) { return []; }
    function getPageList(url) { return []; }
    """

    private func makeWorld() throws -> (provider: CompositeDataSourceProvider, root: URL) {
        let root = try TestFileSystem.makeTemporaryDirectory()
        let sourceStore = SourceStore(rootDirectory: root.appendingPathComponent("sources"))
        try sourceStore.install(script: Self.script)

        let serverStore = ServerStore(fileURL: root.appendingPathComponent("Servers.json"))
        try serverStore.add(HostedServer(
            id: "komga-nas",
            kind: .komga,
            name: "NAS",
            baseURL: "https://nas.local:25600",
            apiKey: "secret"
        ))

        let pool = SourceRuntimePool(store: sourceStore) { _ in FakeRuntime() }
        let hosted = HostedDataSourceProvider(
            store: serverStore,
            client: HTTPClient(transport: RoutedHTTPTransport())
        )
        return (CompositeDataSourceProvider(hosted: hosted, scripts: pool), root)
    }

    @Test("自建服务器的标识走连接器，脚本源的标识走运行时池")
    func routesByOwnership() async throws {
        let (provider, root) = try makeWorld()
        defer { TestFileSystem.remove(root) }

        let hosted = try await provider.dataSource(for: SourceID("komga-nas"))
        #expect(hosted is KomgaDataSource)
        #expect(hosted.sourceID == SourceID("komga-nas"))

        let scripted = try await provider.dataSource(for: SourceID("demo"))
        #expect(scripted is RuntimeDataSource)
        #expect(scripted.sourceID == SourceID("demo"))
    }

    @Test("两边都不认识的标识报「源未安装」，而不是别的错")
    func unknownSourceReportsNotInstalled() async throws {
        let (provider, root) = try makeWorld()
        defer { TestFileSystem.remove(root) }

        await expectThrowsAsync(SourceRunnerError.notInstalled("nobody")) {
            _ = try await provider.dataSource(for: SourceID("nobody"))
        }
    }

    @Test("服务器被移除后该标识立刻失效（不留缓存）")
    func removalTakesEffectImmediately() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }
        let sourceStore = SourceStore(rootDirectory: root.appendingPathComponent("sources"))
        let serverStore = ServerStore(fileURL: root.appendingPathComponent("Servers.json"))
        try serverStore.add(HostedServer(
            id: "komga-nas",
            kind: .komga,
            name: "NAS",
            baseURL: "https://nas.local",
            apiKey: "k"
        ))
        let provider = CompositeDataSourceProvider(
            hosted: HostedDataSourceProvider(
                store: serverStore,
                client: HTTPClient(transport: RoutedHTTPTransport())
            ),
            scripts: SourceRuntimePool(store: sourceStore) { _ in FakeRuntime() }
        )

        _ = try await provider.dataSource(for: SourceID("komga-nas"))
        #expect(try serverStore.remove(id: "komga-nas"))
        await expectThrowsAsync(SourceRunnerError.notInstalled("komga-nas")) {
            _ = try await provider.dataSource(for: SourceID("komga-nas"))
        }
    }
}

// MARK: - 应用层接线

@Suite("应用层的来源列表")
@MainActor
struct AppBrowseSourceTests {

    private static let script = """
    const source = { id: "demo", name: "示例源", lang: "all", version: "1.0.0" };

    function getPopularManga(page) { return { mangas: [], hasNextPage: false }; }
    function getSearchManga(page, query, filters) { return { mangas: [], hasNextPage: false }; }
    function getMangaDetails(url) { return { title: "T", url: url }; }
    function getChapterList(url) { return []; }
    function getPageList(url) { return []; }
    """

    private func makeEnvironment() throws -> (AppEnvironment, URL) {
        let directory = try TestFileSystem.makeTemporaryDirectory()
        let suiteName = "MangaTranslaterTests.browse.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let serverStore = ServerStore(fileURL: directory.appendingPathComponent("Servers.json"))
        let environment = AppEnvironment(
            settings: AppSettings(defaults: defaults),
            sourceStore: SourceStore(rootDirectory: directory.appendingPathComponent("sources")),
            cookieJar: CookieJar(storageURL: directory.appendingPathComponent("cookies.json")),
            diagnostics: DiagnosticsLog(directory: directory),
            libraryStore: InMemoryLibraryStore(),
            localSource: LocalSource(rootDirectory: directory.appendingPathComponent("LocalLibrary")),
            dataDirectory: directory,
            isLibraryPersistent: false,
            serverStore: serverStore
        )
        return (environment, directory)
    }

    @Test("截图列表同时包含自建服务器与脚本源，且服务器排在前面")
    func browseSourcesMergesBothKinds() throws {
        let (environment, directory) = try makeEnvironment()
        defer { TestFileSystem.remove(directory) }

        try environment.sourceStore.install(script: Self.script)
        try environment.addHostedServer(
            kind: .komga,
            name: "书房 NAS",
            baseURL: "https://nas.local:25600",
            apiKey: "secret"
        )

        let sources = environment.browseSources
        #expect(sources.count == 2)
        #expect(sources[0].isHosted)
        #expect(sources[0].kind == .komga)
        #expect(sources[0].name == "书房 NAS")
        #expect(sources[0].displaySubtitle == "https://nas.local:25600")
        #expect(sources[1].id == "demo")
        #expect(sources[1].isHosted == false)
        #expect(sources[1].version == "1.0.0")
    }

    @Test("添加服务器：名字派生标识、地址校验、重名自动加序号")
    func addsHostedServers() throws {
        let (environment, directory) = try makeEnvironment()
        defer { TestFileSystem.remove(directory) }

        let first = try environment.addHostedServer(
            kind: .kavita,
            name: "Home",
            baseURL: "https://kav.local:5000/",
            apiKey: "k1"
        )
        #expect(first.id == "kavita-home")
        // 地址规范化在读取时才做，存储保留用户输入
        #expect(first.normalizedBaseURL == "https://kav.local:5000")

        let second = try environment.addHostedServer(
            kind: .kavita,
            name: "Home",
            baseURL: "https://kav2.local:5000",
            apiKey: "k2"
        )
        #expect(second.id == "kavita-home-2")

        #expect(throws: AppError.invalidInput("服务器地址要以 http:// 或 https:// 开头")) {
            try environment.addHostedServer(kind: .komga, name: "Bad", baseURL: "nas.local")
        }
        #expect(throws: AppError.invalidInput("请填一个名字")) {
            try environment.addHostedServer(kind: .komga, name: "   ", baseURL: "https://a.com")
        }
    }

    @Test("服务器标识能被解析成数据来源；移除后不再能解析")
    func resolvesHostedSource() async throws {
        let (environment, directory) = try makeEnvironment()
        defer { TestFileSystem.remove(directory) }

        let server = try environment.addHostedServer(
            kind: .komga,
            name: "NAS",
            baseURL: "https://nas.local:25600",
            apiKey: "secret"
        )
        #expect(environment.canResolveSource(server.sourceID))
        let source = try await environment.dataSource(for: server.sourceID)
        #expect(source is KomgaDataSource)

        _ = try environment.removeHostedServer(id: server.id)
        #expect(environment.canResolveSource(server.sourceID) == false)
        #expect(environment.hostedServers.isEmpty)
    }

    @Test("成人内容过滤只作用于脚本源，不影响自建服务器")
    func nsfwFilterOnlyAppliesToScripts() throws {
        let (environment, directory) = try makeEnvironment()
        defer { TestFileSystem.remove(directory) }

        let nsfw = """
        const source = { id: "nsfw", name: "NSFW 源", lang: "all", version: "1.0.0", nsfw: true };

        function getPopularManga(page) { return { mangas: [], hasNextPage: false }; }
        function getSearchManga(page, query, filters) { return { mangas: [], hasNextPage: false }; }
        function getMangaDetails(url) { return { title: "T", url: url }; }
        function getChapterList(url) { return []; }
        function getPageList(url) { return []; }
        """
        try environment.sourceStore.install(script: nsfw)
        try environment.addHostedServer(kind: .komga, name: "NAS", baseURL: "https://nas.local", apiKey: "k")

        let sources = environment.browseSources
        #expect(sources.count == 1)
        #expect(sources[0].isHosted)
        #expect(environment.hiddenSourceCount == 1)
    }
}
