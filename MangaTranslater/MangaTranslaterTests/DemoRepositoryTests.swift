//
//  DemoRepositoryTests.swift
//  MangaTranslaterTests
//
//  M2 验收用例：**一个自建的中性测试仓库，能看在线漫画**。
//
//  走的链路与真实使用完全一致，只是把网络换成路由替身、把站点换成
//  `tools/make_demo_repo.py` 生成的那套页面（`DemoCorpus` 与生成器逐字一致）：
//
//      拉 index.json → 解析 → 安装（静态校验 + 落盘）
//        → 载入沙箱 → 热门/最新/搜索 → 详情 → 章节 → 页列表 → 取图
//
//  为什么这条用例比「单测各层」更值钱：它把「契约、校验、解码、沙箱、图片加载」
//  串成一条链，任何一环与文档不符（例如文档写 `net.get` 而实现只有 `net.fetch`）
//  都会在这里红。
//

import Testing
import Foundation
import AppCore
import ComicNet
@testable import SourceEngine

@Suite("自测仓库端到端（M2 验收）")
struct DemoRepositoryTests {

    private static let mangaOneURL = DemoCorpus.baseURL + "/manga-1.html"
    private static let chapterOneURL = DemoCorpus.baseURL + "/chapter-1.html"
    private static let searchURL = DemoCorpus.baseURL + "/search.html?q=demo&page=1"

    private static let imageNames = [
        "cover-1.png", "cover-2.png", "page-1.png", "page-2.png", "page-3.png",
    ]

    private struct Fixture {
        let store: SourceStore
        let service: SourceRepositoryService
        let pool: SourceRuntimePool
        let reading: RemoteReadingSource
        /// 页面请求（走源脚本的 `net.get`）
        let pageTransport: StubSourceTransport
        /// 图片请求（走 `SourceImageLoader`）
        let imageTransport: RoutedHTTPTransport
        let root: URL
    }

    private func makeFixture() throws -> Fixture {
        let root = try TestFileSystem.makeTemporaryDirectory()
        let store = SourceStore(rootDirectory: root.appendingPathComponent("SourcesRoot", isDirectory: true))

        // 1) 仓库侧：index.json 与 demo.js 由普通 HTTP 客户端取（不带来源 Cookie）
        let repoTransport = RoutedHTTPTransport()
        repoTransport.set(DemoCorpus.indexJSON, for: DemoCorpus.baseURL + "/index.json")
        repoTransport.set(DemoCorpus.sourceScript, for: DemoCorpus.baseURL + "/demo.js")
        let service = SourceRepositoryService(
            store: store,
            client: HTTPClient(
                transport: repoTransport,
                configuration: HTTPClient.Configuration(maxRetries: 0, retryBackoff: [0], timeoutSeconds: 5)
            )
        )

        // 2) 页面侧：真实 JavaScriptCore 运行时 + 路由替身（脚本里的 net.get 走这里）
        let pageTransport = StubSourceTransport()
        for name in DemoCorpus.pageNames {
            let body = try #require(DemoCorpus.pages[name], "缺少页面 \(name)")
            pageTransport.setResponse(
                SourceHTTPResult(status: 200, headers: ["Content-Type": "text/html"], body: body),
                for: DemoCorpus.baseURL + "/" + name
            )
        }
        // 搜索页带查询串：URL 必须与脚本拼出来的完全一致
        let searchBody = try #require(DemoCorpus.pages["search.html"])
        pageTransport.setResponse(
            SourceHTTPResult(status: 200, headers: ["Content-Type": "text/html"], body: searchBody),
            for: Self.searchURL
        )

        let pool = SourceRuntimePool(store: store) { _ in
            JSSourceRuntime(
                transport: pageTransport,
                configuration: SourceRuntimeConfiguration(callTimeoutSeconds: 10)
            )
        }

        // 3) 图片侧：二进制走 `SourceImageLoader`
        let imageTransport = RoutedHTTPTransport()
        for name in Self.imageNames {
            imageTransport.setRaw(
                DemoCorpus.pngBytes,
                headers: ["Content-Type": "image/png"],
                for: DemoCorpus.baseURL + "/img/" + name
            )
        }
        let reading = RemoteReadingSource(
            pool: pool,
            imageLoader: SourceImageLoader(transport: imageTransport)
        )

        return Fixture(
            store: store,
            service: service,
            pool: pool,
            reading: reading,
            pageTransport: pageTransport,
            imageTransport: imageTransport,
            root: root
        )
    }

    /// 安装并返回该作品的 `Manga`（模拟用户从列表点进详情前的状态）。
    private func installDemo(_ fixture: Fixture) async throws -> Manga {
        _ = try await fixture.service.install(key: "demo", from: DemoCorpus.baseURL)
        return Manga(sourceID: SourceID("demo"), url: Self.mangaOneURL, title: "Demo Manga One")
    }

    // MARK: 仓库 → 安装

    @Test("拉索引 → 安装 → 落盘")
    func installsFromDemoRepository() async throws {
        let fixture = try makeFixture()
        defer { TestFileSystem.remove(fixture.root) }

        let catalog = try await fixture.service.catalog(for: DemoCorpus.baseURL)
        #expect(catalog.entries.count == 1)

        let entry = try #require(catalog.entries.first)
        #expect(entry.key == "demo")
        #expect(entry.name == "Demo Source")
        #expect(entry.version == "1.0.0")
        #expect(entry.isInstalled == false)
        #expect(entry.isInstallable)
        #expect(entry.scriptURL == DemoCorpus.baseURL + "/demo.js")

        let installed = try await fixture.service.install(entry)
        #expect(installed.key == "demo")
        #expect(installed.byteCount > 0)
        #expect(fixture.store.isInstalled("demo"))
        // 落盘的脚本与生成器一致（静态校验通过才可能走到这里）
        #expect(try fixture.store.script(for: "demo") == DemoCorpus.sourceScript)
    }

    // MARK: 浏览

    @Test("热门列表：分页与相对地址补全")
    func browsesPopularPages() async throws {
        let fixture = try makeFixture()
        defer { TestFileSystem.remove(fixture.root) }
        _ = try await installDemo(fixture)

        let first = try await fixture.pool.withRunner(for: "demo") { runner in
            try await runner.popularManga(page: 1)
        }
        #expect(first.items.map(\.title) == ["Demo Manga One", "Demo Manga Two"])
        #expect(first.items.map(\.url) == [
            Self.mangaOneURL,
            DemoCorpus.baseURL + "/manga-2.html",
        ])
        #expect(first.items.first?.coverURL == DemoCorpus.baseURL + "/img/cover-1.png")
        #expect(first.hasNextPage)

        // 第二页没有 a.next → hasNextPage 为 false
        let second = try await fixture.pool.withRunner(for: "demo") { runner in
            try await runner.popularManga(page: 2)
        }
        #expect(second.items.count == 1)
        #expect(second.hasNextPage == false)
    }

    @Test("最新更新与搜索")
    func browsesLatestAndSearch() async throws {
        let fixture = try makeFixture()
        defer { TestFileSystem.remove(fixture.root) }
        _ = try await installDemo(fixture)

        let latest = try await fixture.pool.withRunner(for: "demo") { runner in
            try await runner.latestUpdates(page: 1)
        }
        #expect(latest.items.count == 1)
        #expect(latest.items.first?.title == "Demo Manga One")

        let results = try await fixture.pool.withRunner(for: "demo") { runner in
            try await runner.search(page: 1, query: "demo")
        }
        #expect(results.items.count == 2)
        #expect(results.hasNextPage == false)
        // 搜索地址确实带上了查询串
        #expect(fixture.pageTransport.calls.contains { $0.url == Self.searchURL })
    }

    @Test("详情：作者 / 画师 / 题材 / 状态")
    func loadsDetails() async throws {
        let fixture = try makeFixture()
        defer { TestFileSystem.remove(fixture.root) }
        let manga = try await installDemo(fixture)

        let detail = try await fixture.pool.withRunner(for: "demo") { runner in
            try await runner.mangaDetails(url: manga.url)
        }
        #expect(detail.title == "Demo Manga One")
        #expect(detail.author == "Demo Author")
        #expect(detail.artist == "Demo Artist")
        #expect(detail.summary == "A neutral sample title used to exercise the reader end to end.")
        #expect(detail.genres == ["Adventure", "Comedy"])
        #expect(detail.status == .ongoing)
        #expect(detail.coverURL == DemoCorpus.baseURL + "/img/cover-1.png")
        #expect(detail.id == manga.id)
    }

    @Test("章节：编号与两种日期写法都能解析")
    func loadsChapters() async throws {
        let fixture = try makeFixture()
        defer { TestFileSystem.remove(fixture.root) }
        let manga = try await installDemo(fixture)

        let chapters = try await fixture.pool.withRunner(for: "demo") { runner in
            try await runner.chapterList(mangaURL: manga.url)
        }
        #expect(chapters.map(\.name) == ["Chapter 1", "Chapter 2"])
        #expect(chapters.map(\.url) == [
            Self.chapterOneURL,
            DemoCorpus.baseURL + "/chapter-2.html",
        ])
        // data-number 是字符串（"1"/"2"），宿主应接受数字字符串
        #expect(chapters.map(\.chapterNumber) == [1, 2])
        // 一条 ISO8601、一条 yyyy-MM-dd
        #expect(chapters[0].dateUploaded != nil)
        #expect(chapters[1].dateUploaded != nil)
    }

    @Test("页列表：顺序即阅读顺序")
    func loadsPageList() async throws {
        let fixture = try makeFixture()
        defer { TestFileSystem.remove(fixture.root) }
        let manga = try await installDemo(fixture)

        let reading = fixture.reading
        let chapters = try await reading.chapters(for: manga)
        let pages = try await reading.pages(for: chapters[0], manga: manga)

        #expect(pages.map(\.imageURL) == [
            DemoCorpus.baseURL + "/img/page-1.png",
            DemoCorpus.baseURL + "/img/page-2.png",
        ])
        #expect(pages.map(\.index) == [0, 1])
    }

    // MARK: 阅读

    @Test("取图：拿到真实图片字节，并带章节页作 Referer")
    func loadsImageBytes() async throws {
        let fixture = try makeFixture()
        defer { TestFileSystem.remove(fixture.root) }
        let manga = try await installDemo(fixture)

        let reading = fixture.reading
        let chapters = try await reading.chapters(for: manga)
        let pages = try await reading.pages(for: chapters[0], manga: manga)
        let data = try await reading.imageData(for: pages[0], manga: manga, chapter: chapters[0])

        #expect(data == DemoCorpus.pngBytes)
        // PNG magic：确认确实是图片而不是错误页
        #expect(data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(fixture.imageTransport.requests.first?.value(forHTTPHeaderField: "Referer") == Self.chapterOneURL)
    }

    @Test("阅读来源缓存章节与页列表")
    func cachesWithinReadingSource() async throws {
        let fixture = try makeFixture()
        defer { TestFileSystem.remove(fixture.root) }
        let manga = try await installDemo(fixture)
        let reading = fixture.reading

        let chapters = try await reading.chapters(for: manga)
        _ = try await reading.chapters(for: manga)
        _ = try await reading.pages(for: chapters[0], manga: manga)
        _ = try await reading.pages(for: chapters[0], manga: manga)

        let chapterLists = await reading.cachedChapterListCount
        let pageLists = await reading.cachedPageListCount
        #expect(chapterLists == 1)
        #expect(pageLists == 1)

        // 页面请求次数：getChapterList 与 getPageList 各一次（第二次命中缓存）
        let pageCalls = fixture.pageTransport.calls.filter { $0.sourceID == "demo" }
        #expect(pageCalls.count == 2)
    }

    @Test("筛选项：由源声明，宿主可渲染")
    func loadsFilters() async throws {
        let fixture = try makeFixture()
        defer { TestFileSystem.remove(fixture.root) }
        _ = try await installDemo(fixture)

        let filters = try await fixture.pool.withRunner(for: "demo") { runner in
            try await runner.filters()
        }
        #expect(filters.map(\.kind) == [.text, .select])
        #expect(filters.map(\.key) == ["author", "genre"])
        #expect(filters[1].options.map(\.value) == ["", "adventure"])
        #expect(filters.defaultValues()["genre"] == "")
    }
}
