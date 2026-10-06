//
//  DownloadedReadingTests.swift
//  MangaTranslaterTests
//
//  已下载章节的阅读：**归档优先**。
//
//  这是「下载」这个功能真正的价值所在——下载完了却不能离线看，等于没下。
//  两条断言最关键：
//  1. 已归档的章节取页列表**不问脚本**（脚本要联网，离线时必然失败）；
//  2. 已归档的章节取图**不发请求**（否则离线读不了，在线时还白费流量）。
//

import Foundation
import Testing
import AppCore
import ComicDownload
import SourceEngine

@Suite("已下载章节的阅读")
struct DownloadedReadingTests {

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

    private struct Fixture {
        let source: RemoteReadingSource
        let archive: DownloadArchiveStore
        let transport: RoutedHTTPTransport
        let ledger: ReadingRuntimeLedger
        let root: URL
    }

    private func makeFixture() throws -> Fixture {
        let root = try TestFileSystem.makeTemporaryDirectory()
        let store = SourceStore(rootDirectory: root.appendingPathComponent("Sources"))
        try store.install(script: Self.script(id: "demo"))

        let ledger = ReadingRuntimeLedger()
        let pool = SourceRuntimePool(store: store) { _ in
            // 脚本返回值刻意留空：归档优先的路径**不该走到这里**
            ledger.make(responses: [.chapterList: "[]", .pageList: "[]"])
        }

        let transport = RoutedHTTPTransport()
        transport.setRaw(
            Data(repeating: 0xAB, count: 32),
            headers: ["Content-Type": "image/jpeg"],
            for: "https://cdn.test/1.jpg"
        )

        let archive = DownloadArchiveStore(rootDirectory: root.appendingPathComponent("Downloads"))
        let source = RemoteReadingSource(
            pool: pool,
            imageLoader: SourceImageLoader(transport: transport),
            archive: archive
        )
        return Fixture(source: source, archive: archive, transport: transport, ledger: ledger, root: root)
    }

    private func makeManga() -> Manga {
        Manga(sourceID: SourceID("demo"), url: "https://example.com/m/1", title: "作品")
    }

    private func makeChapter(_ manga: Manga) -> Chapter {
        Chapter(mangaID: manga.id, url: "https://example.com/c/1", name: "第 1 话")
    }

    @Test("已归档章节的页列表来自归档，不调用脚本")
    func pagesComeFromArchiveWithoutScript() async throws {
        let fixture = try makeFixture()
        defer { TestFileSystem.remove(fixture.root) }

        let manga = makeManga()
        let chapter = makeChapter(manga)
        try fixture.archive.archive(
            pages: [
                CbzPage(index: 0, data: Data("p0".utf8)),
                CbzPage(index: 1, data: Data("p1".utf8)),
                CbzPage(index: 2, data: Data("p2".utf8)),
            ],
            mangaID: manga.id,
            chapterID: chapter.id,
            chapterName: chapter.name
        )

        let pages = try await fixture.source.pages(for: chapter, manga: manga)
        #expect(pages.count == 3)
        #expect(pages.map(\.index) == [0, 1, 2])
        // 脚本一次都没被调用 → 离线也能列出页
        #expect(fixture.ledger.totalCalls == 0)
    }

    @Test("已归档章节取图不发网络请求，字节与归档一致")
    func imagesComeFromArchiveWithoutNetwork() async throws {
        let fixture = try makeFixture()
        defer { TestFileSystem.remove(fixture.root) }

        let manga = makeManga()
        let chapter = makeChapter(manga)
        try fixture.archive.archive(
            pages: [
                CbzPage(index: 0, data: Data("hello-0".utf8)),
                CbzPage(index: 1, data: Data("hello-1".utf8)),
            ],
            mangaID: manga.id,
            chapterID: chapter.id,
            chapterName: chapter.name
        )

        let pages = try await fixture.source.pages(for: chapter, manga: manga)
        let first = try await fixture.source.imageData(for: pages[0], manga: manga, chapter: chapter)
        let second = try await fixture.source.imageData(for: pages[1], manga: manga, chapter: chapter)

        #expect(first == Data("hello-0".utf8))
        #expect(second == Data("hello-1".utf8))
        #expect(fixture.transport.requests.isEmpty)
    }

    @Test("未归档章节仍走网络")
    func unarchivedChapterUsesNetwork() async throws {
        let fixture = try makeFixture()
        defer { TestFileSystem.remove(fixture.root) }

        let manga = makeManga()
        let chapter = makeChapter(manga)
        // 归档目录是空的
        #expect(fixture.source.isChapterArchived(mangaID: manga.id, chapterID: chapter.id) == false)

        let page = ComicPage(index: 0, imageURL: "https://cdn.test/1.jpg")
        let data = try await fixture.source.imageData(for: page, manga: manga, chapter: chapter)
        #expect(data.count == 32)
        #expect(fixture.transport.requests.count == 1)
    }

    @Test("归档里缺某页时该页回落网络，其余页仍读本地")
    func missingPageFallsBackToNetwork() async throws {
        let fixture = try makeFixture()
        defer { TestFileSystem.remove(fixture.root) }

        let manga = makeManga()
        let chapter = makeChapter(manga)
        try fixture.archive.archive(
            pages: [CbzPage(index: 0, data: Data("local-0".utf8))],
            mangaID: manga.id,
            chapterID: chapter.id,
            chapterName: chapter.name
        )

        // 第 0 页在归档里；第 1 页不在 → 应当去网络
        let first = ComicPage(index: 0, imageURL: "https://cdn.test/1.jpg")
        let second = ComicPage(index: 1, imageURL: "https://cdn.test/1.jpg")

        #expect(try await fixture.source.imageData(for: first, manga: manga, chapter: chapter) == Data("local-0".utf8))
        _ = try await fixture.source.imageData(for: second, manga: manga, chapter: chapter)
        #expect(fixture.transport.requests.count == 1)
    }

    @Test("归档是「只有第 0 页」时页列表只给 1 页（不按脚本的页数撒谎）")
    func pageListMatchesArchiveContents() async throws {
        let fixture = try makeFixture()
        defer { TestFileSystem.remove(fixture.root) }

        let manga = makeManga()
        let chapter = makeChapter(manga)
        try fixture.archive.archive(
            pages: [CbzPage(index: 0, data: Data("only".utf8))],
            mangaID: manga.id,
            chapterID: chapter.id,
            chapterName: chapter.name
        )

        let pages = try await fixture.source.pages(for: chapter, manga: manga)
        #expect(pages.count == 1)
    }

    @Test("已归档章节标识集合可用于界面打「已下载」标记")
    func exposesArchivedChapterIDs() throws {
        let fixture = try makeFixture()
        defer { TestFileSystem.remove(fixture.root) }

        let manga = makeManga()
        let chapter = makeChapter(manga)
        try fixture.archive.archive(
            pages: [CbzPage(index: 0, data: Data("x".utf8))],
            mangaID: manga.id,
            chapterID: chapter.id,
            chapterName: chapter.name
        )

        #expect(fixture.source.isChapterArchived(mangaID: manga.id, chapterID: chapter.id))
        #expect(fixture.source.archivedChapterIDs(mangaID: manga.id) == [chapter.id])
        #expect(fixture.source.archivedChapterIDs(mangaID: "别的作品").isEmpty)
    }

    @Test("没接归档时行为与从前一致（全走网络）")
    func worksWithoutArchive() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let store = SourceStore(rootDirectory: root.appendingPathComponent("Sources"))
        try store.install(script: Self.script(id: "demo"))
        let ledger = ReadingRuntimeLedger()
        let pool = SourceRuntimePool(store: store) { _ in ledger.make(responses: [.pageList: "[]"]) }

        let transport = RoutedHTTPTransport()
        transport.setRaw(
            Data(repeating: 0x01, count: 8),
            headers: ["Content-Type": "image/jpeg"],
            for: "https://cdn.test/1.jpg"
        )
        let source = RemoteReadingSource(
            pool: pool,
            imageLoader: SourceImageLoader(transport: transport)
        )

        let manga = makeManga()
        let page = ComicPage(index: 0, imageURL: "https://cdn.test/1.jpg")
        _ = try await source.imageData(for: page, manga: manga, chapter: makeChapter(manga))
        #expect(transport.requests.count == 1)
        #expect(source.isChapterArchived(mangaID: manga.id, chapterID: "x") == false)
    }
}
