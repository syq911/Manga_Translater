//
//  IntegrationTests.swift
//  MangaTranslaterTests
//
//  集成测试：把多个模块串起来跑端到端流程（全程本地、无网络）。
//
//  覆盖三条主干：
//  1. 安装源 → 记录仓库 → 读取脚本 → 契约校验；
//  2. 下载若干页 → 导出 CBZ → 重新读取校验；
//  3. 应用环境装配（AppEnvironment）与设置 / Cookie 的联动。
//

import Testing
import Foundation
import AppCore
import ComicNet
import SourceEngine
import ComicDownload
@testable import MangaTranslater

@Suite("端到端集成")
struct IntegrationTests {

    private let scriptTemplate = """
    const source = {
      id: "demo",
      name: "示例源",
      lang: "zh",
      baseUrl: "https://example.com",
      nsfw: false,
      version: "1.0.0"
    };
    async function getPopularManga(page) { return { mangas: [], hasNextPage: false }; }
    async function getSearchManga(page, query, filters) { return { mangas: [], hasNextPage: false }; }
    async function getMangaDetails(mangaUrl) { return { title: "t" }; }
    async function getChapterList(mangaUrl) { return []; }
    async function getPageList(chapterUrl) { return []; }
    """

    // MARK: 1. 源安装链路

    @Test("添加仓库 → 安装源 → 读回 → 契约完整")
    func sourceInstallPipeline() throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let store = SourceStore(rootDirectory: root)
        let repository = "https://example.com/repo/index.json"

        #expect(try store.addRepository(repository))
        #expect(store.repositories == [repository])

        // 模拟从仓库拉到的索引
        let indexData = Data("""
        [{ "name": "示例源", "fileName": "demo.js", "key": "demo", "version": "1.0.0" }]
        """.utf8)
        let entries = try SourceIndexParser.parse(data: indexData)
        let entry = try #require(entries.first)

        let downloadURL = try #require(SourceIndexParser.scriptURL(for: entry, repositoryURL: repository))
        #expect(downloadURL == "https://example.com/repo/demo.js")

        // 安装并读回
        let installed = try store.install(script: scriptTemplate)
        #expect(installed.key == entry.key)

        let readBack = try store.script(for: entry.key)
        #expect(readBack == scriptTemplate)

        // 契约与元信息
        #expect(SourceAPIContract.isComplete(readBack))
        let meta = try SourceScriptValidator.validate(readBack)
        #expect(meta.id == SourceID("demo"))
        #expect(meta.version == "1.0.0")
        #expect(meta.isNSFW == false)

        // 重启后仍然存在
        let reloaded = SourceStore(rootDirectory: root)
        #expect(reloaded.isInstalled("demo"))
        #expect(reloaded.repositories == [repository])
    }

    @Test("卸载源后重启不再出现")
    func uninstallIsPersistent() throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let store = SourceStore(rootDirectory: root)
        try store.install(script: scriptTemplate)
        try store.uninstall(key: "demo")

        let reloaded = SourceStore(rootDirectory: root)
        #expect(!reloaded.isInstalled("demo"))
        #expect(!FileManager.default.fileExists(atPath: reloaded.scriptURL(for: "demo").path))
    }

    // MARK: 2. 下载 → 导出 CBZ

    @Test("下载三页 → 导出 CBZ → 校验内容与顺序")
    func downloadThenExportPipeline() async throws {
        let directory = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(directory) }

        let store = FilePageStore(rootDirectory: directory.appendingPathComponent("pages"))
        let pageBytes: [Data] = [
            Data(repeating: 0x11, count: 64),
            Data(repeating: 0x22, count: 64),
            Data(repeating: 0x33, count: 64),
        ]
        let fetcher = StubPageFetcher(scriptedResults: pageBytes.map { .success($0) })

        let queue = DownloadQueue(
            configuration: DownloadQueueConfiguration(maxConcurrentJobs: 1),
            fetcher: fetcher,
            store: store,
            sleeper: { _ in }
        )

        let job = DownloadJob(
            sourceID: SourceID("demo"),
            mangaID: "demo|https://example.com/m",
            chapterID: "chapter-1",
            chapterName: "第 1 话",
            pageURLs: (1...3).map { "https://example.com/\($0).jpg" }
        )
        try await queue.enqueue(job)
        await queue.start()

        let idle = await queue.waitUntilIdle()
        #expect(idle)
        #expect(await queue.job(job.id)?.state == .completed)
        #expect(store.storedPageCount(jobID: job.id) == 3)

        // 导出
        let exported = try CbzExporter().export(
            pages: [
                CbzPage(index: 0, data: pageBytes[0]),
                CbzPage(index: 1, data: pageBytes[1]),
                CbzPage(index: 2, data: pageBytes[2]),
            ],
            title: "第 1 话"
        )

        let reader = try ZipArchiveReader(data: exported)
        #expect(reader.entryNames == ["comicinfo.txt", "0001.jpg", "0002.jpg", "0003.jpg"])
        #expect(try reader.data(for: "0002.jpg") == pageBytes[1])
    }

    @Test("下载失败时不留残页，可直接重试")
    func failedDownloadLeavesNoPartialData() async throws {
        let directory = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(directory) }

        let store = FilePageStore(rootDirectory: directory.appendingPathComponent("pages"))
        let fetcher = StubPageFetcher(scriptedResults: [
            .success(Data([0x01])),
            .failure(NetworkError.offline),
        ])

        let queue = DownloadQueue(
            configuration: DownloadQueueConfiguration(maxConcurrentJobs: 1, maxRetriesPerPage: 0),
            fetcher: fetcher,
            store: store,
            sleeper: { _ in }
        )

        let job = DownloadJob(
            sourceID: SourceID("demo"),
            mangaID: "demo|https://example.com/m",
            chapterID: "chapter-2",
            chapterName: "第 2 话",
            pageURLs: ["https://example.com/1.jpg", "https://example.com/2.jpg"]
        )
        try await queue.enqueue(job)
        await queue.start()
        #expect(await queue.waitUntilIdle())

        #expect(await queue.job(job.id)?.state == .failed)
        #expect(store.storedPageCount(jobID: job.id) == 0)
    }

    // MARK: 3. 应用环境装配

    @Test("应用环境可从注入的依赖构建，并反映设置与 Cookie")
    @MainActor
    func appEnvironmentWiring() throws {
        let directory = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(directory) }

        let suiteName = "MangaTranslaterTests.env.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        let sourceStore = SourceStore(rootDirectory: directory.appendingPathComponent("sources"))
        let cookieJar = CookieJar(storageURL: directory.appendingPathComponent("cookies.json"))
        let environment = AppEnvironment(
            settings: settings,
            sourceStore: sourceStore,
            cookieJar: cookieJar,
            diagnostics: DiagnosticsLog(directory: directory),
            dataDirectory: directory
        )

        #expect(environment.repositories.isEmpty)
        #expect(environment.installedSources.isEmpty)

        // 安装一个源后环境可见
        try environment.sourceStore.install(script: scriptTemplate)
        #expect(environment.installedSources.count == 1)
        #expect(environment.installedSources.first?.key == "demo")

        // Cookie 按来源隔离
        let sourceID = SourceID("demo")
        try environment.cookieJar.set(StoredCookie(name: "sid", value: "1", domain: "example.com"), for: sourceID)
        #expect(environment.cookieJar.hasCookies(for: sourceID))
        #expect(!environment.cookieJar.hasCookies(for: SourceID("other")))

        // NSFW 默认关闭且受年龄门槛约束
        #expect(environment.settings.showsNSFWSources == false)
        #expect(environment.settings.setShowsNSFWSources(true) == false)
    }

    @Test("设置与 HTTP 客户端联动：超时与 User-Agent 可配置")
    func settingsDriveHTTPClient() async throws {
        let suiteName = "MangaTranslaterTests.http.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        settings.requestTimeoutSeconds = 30

        let transport = StubTransport(data: Data("ok".utf8))
        let client = HTTPClient(
            transport: transport,
            configuration: HTTPClient.Configuration(timeoutSeconds: settings.requestTimeoutSeconds),
            sleeper: { _ in }
        )

        let response = try await client.get("https://example.com/a")
        #expect(response.text == "ok")
        #expect(transport.requests.first?.timeoutInterval == 30)
    }

    @Test("源请求节流与 Cookie 一起作用于同一来源")
    func sourceScopedNetworking() async throws {
        let sourceID = SourceID("demo")
        let jar = CookieJar()
        try jar.set(StoredCookie(name: "sid", value: "abc", domain: "example.com"), for: sourceID)

        let limiter = RateLimiter(minInterval: 0, clock: { Date() }, sleeper: { _ in })
        let transport = StubTransport(data: Data("body".utf8))
        let client = HTTPClient(
            transport: transport,
            configuration: HTTPClient.Configuration(maxRetries: 0),
            rateLimiter: limiter,
            cookieJar: jar,
            cookieSourceID: sourceID,
            sleeper: { _ in }
        )

        _ = try await client.get("https://example.com/list")
        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Cookie") == "sid=abc")
    }
}
