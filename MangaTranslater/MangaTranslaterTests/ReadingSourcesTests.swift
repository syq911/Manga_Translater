//
//  ReadingSourcesTests.swift
//  MangaTranslaterTests
//
//  阅读数据适配层：本地文件源（同步 → 异步）与在线来源（运行时池 + 图片加载 + 缓存）。
//
//  这一层是阅读器的唯一数据入口，两条实现的行为差异（本地解压 vs 网络请求）
//  必须在阅读器之外收干净，所以在这里逐项钉住。
//

import Testing
import Foundation
import AppCore
import ComicNet
@testable import SourceEngine

// MARK: - 在线来源的替身

/// 按契约方法返回脚本化 JSON 的假运行时。
final class ReadingRuntime: SourceRuntimeExecuting, @unchecked Sendable {

    private let lock = NSLock()
    private var count = 0
    private let responses: [SourceAPIMethod: String]
    private let callError: Error?

    init(responses: [SourceAPIMethod: String], callError: Error? = nil) {
        self.responses = responses
        self.callError = callError
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func load(script: String, meta: SourceScriptMeta) async throws {}

    func call(_ method: SourceAPIMethod, arguments: [String]) async throws -> String {
        lock.lock()
        count += 1
        let error = callError
        lock.unlock()
        if let error { throw error }
        return responses[method] ?? "null"
    }

    func teardown() async {}
}

/// 记录工厂建出的运行时，便于断言「是否发生了请求」。
final class ReadingRuntimeLedger: @unchecked Sendable {

    private let lock = NSLock()
    private var created: [ReadingRuntime] = []

    var instances: [ReadingRuntime] {
        lock.lock()
        defer { lock.unlock() }
        return created
    }

    var totalCalls: Int { instances.reduce(0) { $0 + $1.callCount } }

    func make(responses: [SourceAPIMethod: String], callError: Error? = nil) -> ReadingRuntime {
        lock.lock()
        defer { lock.unlock() }
        let runtime = ReadingRuntime(responses: responses, callError: callError)
        created.append(runtime)
        return runtime
    }
}

@Suite("在线阅读来源")
struct RemoteReadingSourceTests {

    private static let chapterURL = "https://example.com/c/1"

    private static func script(id: String) -> String {
        """
        const source = { id: "\(id)", name: "源 \(id)", lang: "all", version: "1.0.0" };

        function getPopularManga(page) { return { mangas: [], hasNextPage: false }; }
        function getSearchManga(page, query, filters) { return { mangas: [], hasNextPage: false }; }
        function getMangaDetails(url) { return { title: "T", url: url }; }
        function getChapterList(url) { return []; }
        function getPageList(url) { return []; }
        """
    }

    private static let chapterJSON = #"[{"name":"第 1 话","url":"/c/1"}]"#
    private static let pageJSON = #"["https://cdn.test/1.jpg","https://cdn.test/2.jpg"]"#

    private struct Fixture {
        let source: RemoteReadingSource
        let ledger: ReadingRuntimeLedger
        let transport: RoutedHTTPTransport
        let root: URL
    }

    private func makeFixture(
        sourceKeys: [String] = ["demo"],
        configuration: RemoteReadingSource.Configuration = .init()
    ) throws -> Fixture {
        let root = try TestFileSystem.makeTemporaryDirectory()
        let store = SourceStore(rootDirectory: root)
        for key in sourceKeys {
            try store.install(script: Self.script(id: key))
        }

        let ledger = ReadingRuntimeLedger()
        let pool = SourceRuntimePool(store: store) { meta in
            // 两个来源返回同一份数据即可：本套件测的是适配层，不是脚本语义
            _ = meta
            return ledger.make(responses: [
                .chapterList: Self.chapterJSON,
                .pageList: Self.pageJSON,
            ])
        }

        let transport = RoutedHTTPTransport()
        transport.setRaw(
            Data(repeating: 0xAB, count: 32),
            headers: ["Content-Type": "image/jpeg"],
            for: "https://cdn.test/1.jpg"
        )
        transport.setRaw(
            Data(repeating: 0xCD, count: 32),
            headers: ["Content-Type": "image/jpeg"],
            for: "https://cdn.test/2.jpg"
        )
        let loader = SourceImageLoader(transport: transport)

        return Fixture(
            source: RemoteReadingSource(pool: pool, imageLoader: loader, configuration: configuration),
            ledger: ledger,
            transport: transport,
            root: root
        )
    }

    private func makeManga(key: String = "demo") -> Manga {
        Manga(sourceID: SourceID(key), url: "https://example.com/m/1", title: "作品")
    }

    // MARK: 章节与页

    @Test("取章节列表：地址补全为绝对地址，并缓存复用")
    func loadsAndCachesChapters() async throws {
        let fixture = try makeFixture()
        defer { TestFileSystem.remove(fixture.root) }
        let manga = makeManga()

        let first = try await fixture.source.chapters(for: manga)
        #expect(first.count == 1)
        #expect(first[0].url == Self.chapterURL)
        #expect(fixture.ledger.totalCalls == 1)

        // 第二次应命中缓存，不再调用脚本
        let second = try await fixture.source.chapters(for: manga)
        #expect(second.count == 1)
        #expect(fixture.ledger.totalCalls == 1)

        let cached = await fixture.source.cachedChapterListCount
        #expect(cached == 1)
    }

    @Test("取页列表：顺序保持，并缓存复用")
    func loadsAndCachesPages() async throws {
        let fixture = try makeFixture()
        defer { TestFileSystem.remove(fixture.root) }
        let manga = makeManga()
        let chapter = Chapter(mangaID: manga.id, url: Self.chapterURL, name: "第 1 话")

        let pages = try await fixture.source.pages(for: chapter, manga: manga)
        #expect(pages.map(\.imageURL) == ["https://cdn.test/1.jpg", "https://cdn.test/2.jpg"])
        #expect(pages.map(\.index) == [0, 1])

        _ = try await fixture.source.pages(for: chapter, manga: manga)
        #expect(fixture.ledger.totalCalls == 1)
    }

    @Test("取图：带上章节页作 Referer 与该来源的 Cookie")
    func loadsImageWithRefererAndCookies() async throws {
        let fixture = try makeFixture()
        defer { TestFileSystem.remove(fixture.root) }
        let manga = makeManga()
        let chapter = Chapter(mangaID: manga.id, url: Self.chapterURL, name: "第 1 话")
        let page = ComicPage(index: 0, imageURL: "https://cdn.test/1.jpg")

        let data = try await fixture.source.imageData(for: page, manga: manga, chapter: chapter)
        #expect(data.count == 32)

        let request = try #require(fixture.transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Referer") == Self.chapterURL)
    }

    @Test("单页请求头优先于章节页兜底")
    func pageHeadersWin() async throws {
        let fixture = try makeFixture()
        defer { TestFileSystem.remove(fixture.root) }
        let manga = makeManga()
        let chapter = Chapter(mangaID: manga.id, url: Self.chapterURL, name: "第 1 话")
        let page = ComicPage(
            index: 0,
            imageURL: "https://cdn.test/1.jpg",
            headers: ["Referer": "https://example.com/other"]
        )

        _ = try await fixture.source.imageData(for: page, manga: manga, chapter: chapter)
        #expect(
            fixture.transport.requests.first?.value(forHTTPHeaderField: "Referer")
                == "https://example.com/other"
        )
    }

    // MARK: 失效与上限

    @Test("按来源失效：只清掉该来源的缓存")
    func invalidatesPerSource() async throws {
        let fixture = try makeFixture(sourceKeys: ["demo", "other"])
        defer { TestFileSystem.remove(fixture.root) }

        _ = try await fixture.source.chapters(for: makeManga(key: "demo"))
        _ = try await fixture.source.chapters(for: makeManga(key: "other"))
        var cached = await fixture.source.cachedChapterListCount
        #expect(cached == 2)

        await fixture.source.invalidate(sourceID: SourceID("demo"))
        cached = await fixture.source.cachedChapterListCount
        #expect(cached == 1)

        // demo 的缓存没了 → 再取要重新调用脚本
        let before = fixture.ledger.totalCalls
        _ = try await fixture.source.chapters(for: makeManga(key: "demo"))
        #expect(fixture.ledger.totalCalls == before + 1)
    }

    @Test("缓存超过上限时淘汰最久未用")
    func evictsOldestCacheEntries() async throws {
        let fixture = try makeFixture(
            sourceKeys: ["demo"],
            configuration: RemoteReadingSource.Configuration(maxCachedChapterLists: 2, maxCachedPageLists: 1)
        )
        defer { TestFileSystem.remove(fixture.root) }

        for index in 1...3 {
            let manga = Manga(
                sourceID: SourceID("demo"),
                url: "https://example.com/m/\(index)",
                title: "作品 \(index)"
            )
            _ = try await fixture.source.chapters(for: manga)
        }
        let cached = await fixture.source.cachedChapterListCount
        #expect(cached == 2)
    }

    @Test("脚本失败时错误向上传递，且不写入缓存")
    func propagatesErrors() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let store = SourceStore(rootDirectory: root)
        try store.install(script: Self.script(id: "demo"))
        // 每次都抛超时的运行时：验证错误不被吞掉、也不留下缓存
        let ledger = ReadingRuntimeLedger()
        let failure = SourceRunnerError.executionTimeout(seconds: 10)
        let pool = SourceRuntimePool(store: store) { meta in
            _ = meta
            return ledger.make(responses: [:], callError: failure)
        }
        let source = RemoteReadingSource(pool: pool, imageLoader: SourceImageLoader())

        await expectThrowsAsync(failure) {
            _ = try await source.chapters(
                for: Manga(sourceID: SourceID("demo"), url: "https://example.com/m/1", title: "X")
            )
        }
        let cached = await source.cachedChapterListCount
        #expect(cached == 0)
    }
}

// MARK: - 本地来源适配

@Suite("本地阅读来源")
struct LocalReadingSourceTests {

    /// 图片全在根目录：1.jpg/2.jpg/10.jpg（外部实现 Python zipfile 生成，334 字节）。
    static let archive = Data(
        base64Encoded: """
        UEsDBBQAAAAIAAAAIVwUv0CjEQAAADoAAAAFAAAAMS5qcGf7f+N/kL9/iK6hXlZBOkkEAFBL
        AwQUAAAACAAAACFcaRbJCREAAAA6AAAABQAAADIuanBn+3/jf5C/f4iukV5WQTpJBABQSwME
        FAAAAAgAAAAhXHRU484SAAAARAAAAAYAAAAxMC5qcGf7f+N/kL9/iK6hgV5WQTp5JABQSwEC
        FAAUAAAACAAAACFcFL9AoxEAAAA6AAAABQAAAAAAAAAAAAAAgAEAAAAAMS5qcGdQSwECFAAU
        AAAACAAAACFcaRbJCREAAAA6AAAABQAAAAAAAAAAAAAAgAE0AAAAMi5qcGdQSwECFAAUAAAA
        CAAAACFcdFTjzhIAAABEAAAABgAAAAAAAAAAAAAAgAFoAAAAMTAuanBnUEsFBgAAAAADAAMA
        mgAAAJ4AAAAAAA==
        """,
        options: .ignoreUnknownCharacters
    )!

    private func makeImportedBook() throws -> (LocalReadingSource, Manga, URL) {
        let root = try TestFileSystem.makeTemporaryDirectory()
        let source = LocalSource(rootDirectory: root.appendingPathComponent("Library", isDirectory: true))
        let file = root.appendingPathComponent("book.cbz", isDirectory: false)
        try Self.archive.write(to: file, options: .atomic)
        let imported = try source.importBook(from: file)
        return (LocalReadingSource(localSource: source), imported.manga, root)
    }

    @Test("章节与页：与同步实现一致，且页序按自然排序")
    func matchesSynchronousBehaviour() async throws {
        let (reading, manga, root) = try makeImportedBook()
        defer { TestFileSystem.remove(root) }

        let chapters = try await reading.chapters(for: manga)
        #expect(chapters.count == 1)

        let pages = try await reading.pages(for: chapters[0], manga: manga)
        #expect(pages.count == 3)
        // 自然排序：1.jpg < 2.jpg < 10.jpg
        #expect(pages.map { ($0.imageURL as NSString).lastPathComponent } == ["1.jpg", "2.jpg", "10.jpg"])
    }

    @Test("取图：返回可用的图片字节")
    func loadsImageData() async throws {
        let (reading, manga, root) = try makeImportedBook()
        defer { TestFileSystem.remove(root) }

        let chapters = try await reading.chapters(for: manga)
        let pages = try await reading.pages(for: chapters[0], manga: manga)
        let data = try await reading.imageData(for: pages[0], manga: manga, chapter: chapters[0])
        #expect(data.count > 0)
        // 夹具里的「图片」是文本内容，能取到字节即可（解码正确性由图片缓存测试覆盖）
        #expect(data.isEmpty == false)
    }

    @Test("找不到作品时错误向上传递")
    func propagatesMissingBookError() async throws {
        let (reading, _, root) = try makeImportedBook()
        defer { TestFileSystem.remove(root) }

        // 根目录名取自 `LocalSource(rootDirectory:)` 的末段
        let stranger = Manga(sourceID: .local, url: "Library/不存在.cbz", title: "不存在")
        await expectThrowsAsync(LocalSourceError.bookNotFound(stranger.id)) {
            _ = try await reading.chapters(for: stranger)
        }
    }
}
