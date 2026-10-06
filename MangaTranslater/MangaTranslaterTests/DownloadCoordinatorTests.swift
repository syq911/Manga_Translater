//
//  DownloadCoordinatorTests.swift
//  MangaTranslaterTests
//
//  下载编排：入队、跳过已下载、批量容错、推进与归档、暂停 / 取消 / 重试、归档维护。
//
//  全部离线：图片走 `StubTransport`，页列表走注入的闭包，归档落临时目录。
//

import Foundation
import Testing
import AppCore
import ComicNet
import ComicDownload
import SourceEngine
@testable import MangaTranslater

@Suite("下载编排")
@MainActor
struct DownloadCoordinatorTests {

    // MARK: 夹具

    /// 一页图片的最小可用响应（内容不必真是图片，归档不校验像素）。
    private static func imageOutcome() -> StubTransport.Outcome {
        .success(data: Data("IMAGE".utf8), statusCode: 200, headers: ["Content-Type": "image/png"])
    }

    private static func manga() -> Manga {
        Manga(sourceID: SourceID("demo"), url: "https://example.com/m/1", title: "Demo")
    }

    private static func chapter(_ index: Int, pages: Int = 3) -> (Chapter, [ComicPage]) {
        let manga = Self.manga()
        let chapter = Chapter(
            mangaID: manga.id,
            url: "https://example.com/c/\(index)",
            name: "第 \(index) 话"
        )
        let pages = (0..<pages).map { page in
            ComicPage(index: page, imageURL: "https://example.com/c/\(index)/\(page).jpg")
        }
        return (chapter, pages)
    }

    /// 一个「页列表可脚本化」的编排器。
    private static func makeCoordinator(
        root: URL,
        imageOutcomes: [StubTransport.Outcome],
        pagesByChapter: [String: [ComicPage]],
        failingChapters: Set<String> = [],
        configuration: DownloadQueueConfiguration = DownloadQueueConfiguration(maxRetriesPerPage: 0),
        log: @escaping (String) -> Void = { _ in }
    ) -> (DownloadCoordinator, DownloadArchiveStore) {
        let archive = DownloadArchiveStore(
            rootDirectory: root.appendingPathComponent("Downloads", isDirectory: true)
        )
        let loader = SourceImageLoader(transport: StubTransport(outcomes: imageOutcomes))
        let coordinator = DownloadCoordinator(
            archive: archive,
            scratchDirectory: root.appendingPathComponent("Scratch", isDirectory: true),
            imageLoader: loader,
            configuration: configuration,
            pollIntervalNanoseconds: 0,
            loadPageList: { _, chapterURL in
                if failingChapters.contains(chapterURL) {
                    throw SourceRunnerError.executionFailed("页列表取不到")
                }
                guard let pages = pagesByChapter[chapterURL] else {
                    throw SourceRunnerError.executionFailed("未配置的章节")
                }
                return pages
            },
            log: log
        )
        return (coordinator, archive)
    }

    // MARK: 入队与归档

    @Test("下载整章：归档可读回，散图被清掉")
    func downloadsAndArchives() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let (chapter, pages) = Self.chapter(1)
        let (coordinator, archive) = Self.makeCoordinator(
            root: root,
            imageOutcomes: [Self.imageOutcome()],
            pagesByChapter: [chapter.url: pages]
        )

        let result = await coordinator.download(manga: Self.manga(), chapter: chapter)
        #expect(result.enqueued == 1)
        await coordinator.drain()

        let mangaID = Self.manga().id
        #expect(archive.hasChapter(mangaID: mangaID, chapterID: chapter.id))
        #expect(archive.pageCount(mangaID: mangaID, chapterID: chapter.id) == 3)

        // 归档做完了，散图目录就该消失——否则磁盘上会长期留两份数据
        let scratch = root.appendingPathComponent("Scratch", isDirectory: true)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []
        #expect(leftovers.isEmpty)

        // 快照里进度到 100%
        let job = try #require(coordinator.job(chapterID: chapter.id))
        #expect(job.state == .completed)
        #expect(job.completedPages == 3)
        #expect(job.progress == 1.0)

        // 归档状态快照里能查到
        await coordinator.refreshArchives()
        #expect(coordinator.archivedChapterCount == 1)
        #expect(coordinator.archivedGroups.first?.mangaID == mangaID)
    }

    @Test("已下载的章节再点下载会被跳过")
    func skipsAlreadyDownloaded() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let (chapter, pages) = Self.chapter(1)
        let (coordinator, _) = Self.makeCoordinator(
            root: root,
            imageOutcomes: [Self.imageOutcome()],
            pagesByChapter: [chapter.url: pages]
        )
        let manga = Self.manga()

        _ = await coordinator.download(manga: manga, chapter: chapter)
        await coordinator.drain()
        #expect(coordinator.isArchived(mangaID: manga.id, chapterID: chapter.id))

        let again = await coordinator.download(manga: manga, chapter: chapter)
        #expect(again.enqueued == 0)
        #expect(again.message == L("downloads.nothingToDo"))
    }

    @Test("重复点击不会产生两个任务")
    func duplicateTapIsIgnored() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let (chapter, pages) = Self.chapter(1)
        let (coordinator, _) = Self.makeCoordinator(
            root: root,
            imageOutcomes: [Self.imageOutcome()],
            pagesByChapter: [chapter.url: pages]
        )
        let manga = Self.manga()

        let first = await coordinator.download(manga: manga, chapter: chapter)
        let second = await coordinator.download(manga: manga, chapter: chapter)
        #expect(first.enqueued == 1)
        #expect(second.enqueued == 0)

        await coordinator.drain()
        #expect(coordinator.jobs.count == 1)
    }

    @Test("批量下载：单章取页失败不中断整批")
    func batchToleratesSingleFailure() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let (good1, pages1) = Self.chapter(1)
        let (bad, _) = Self.chapter(2)
        let (good3, pages3) = Self.chapter(3)

        let (coordinator, archive) = Self.makeCoordinator(
            root: root,
            imageOutcomes: [Self.imageOutcome()],
            pagesByChapter: [good1.url: pages1, good3.url: pages3],
            failingChapters: [bad.url]
        )
        let manga = Self.manga()

        let result = await coordinator.download(manga: manga, chapters: [good1, bad, good3])
        #expect(result.requested == 3)
        #expect(result.enqueued == 2)
        #expect(result.skipped == [bad.name])

        await coordinator.drain()
        #expect(archive.hasChapter(mangaID: manga.id, chapterID: good1.id))
        #expect(archive.hasChapter(mangaID: manga.id, chapterID: good3.id))
        #expect(archive.hasChapter(mangaID: manga.id, chapterID: bad.id) == false)
    }

    @Test("没有可下载的页时计入 skipped 而不是建空任务")
    func emptyPageListIsSkipped() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let (chapter, _) = Self.chapter(1)
        let (coordinator, _) = Self.makeCoordinator(
            root: root,
            imageOutcomes: [Self.imageOutcome()],
            pagesByChapter: [chapter.url: []]
        )

        let result = await coordinator.download(manga: Self.manga(), chapter: chapter)
        #expect(result.enqueued == 0)
        #expect(result.skipped == [chapter.name])
        #expect(coordinator.jobs.isEmpty)
    }

    @Test("假数据里的页级请求头被保留为任务级映射")
    func keepsPerPageHeaders() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let manga = Self.manga()
        let chapter = Chapter(mangaID: manga.id, url: "https://example.com/c/1", name: "第 1 话")
        let pages = [
            ComicPage(index: 0, imageURL: "https://img.example.com/0.jpg", headers: ["Referer": "https://example.com/c/1"]),
            ComicPage(index: 1, imageURL: "https://img.example.com/1.jpg", headers: ["Referer": "https://example.com/c/1"]),
        ]
        let (coordinator, _) = Self.makeCoordinator(
            root: root,
            imageOutcomes: [Self.imageOutcome()],
            pagesByChapter: [chapter.url: pages]
        )

        _ = await coordinator.download(manga: manga, chapter: chapter)
        let job = try #require(coordinator.job(chapterID: chapter.id))
        #expect(job.pageHeaders.count == 2)
        #expect(job.headers(forURL: "https://img.example.com/0.jpg")["Referer"] == "https://example.com/c/1")
        // 任务级 Referer 兜底：章节页地址
        #expect(job.referer == chapter.url)
    }

    // MARK: 失败与重试

    @Test("整章失败：不留半成品，任务标为 failed")
    func failedJobLeavesNoPartialData() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let (chapter, pages) = Self.chapter(1)
        let (coordinator, archive) = Self.makeCoordinator(
            root: root,
            imageOutcomes: [.failure(.httpStatus(code: 403, retryAfterSeconds: nil))],
            pagesByChapter: [chapter.url: pages]
        )
        let manga = Self.manga()

        _ = await coordinator.download(manga: manga, chapter: chapter)
        await coordinator.drain()

        let job = try #require(coordinator.job(chapterID: chapter.id))
        #expect(job.state == .failed)
        #expect(job.errorMessage?.isEmpty == false)
        #expect(archive.hasChapter(mangaID: manga.id, chapterID: chapter.id) == false)

        let scratch = root.appendingPathComponent("Scratch", isDirectory: true)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test("单页超过体积上限视为失败")
    func oversizedPageFails() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let (chapter, pages) = Self.chapter(1)
        let (coordinator, _) = Self.makeCoordinator(
            root: root,
            imageOutcomes: [.success(
                data: Data(repeating: 0x41, count: 4096),
                statusCode: 200,
                headers: ["Content-Type": "image/png"]
            )],
            pagesByChapter: [chapter.url: pages],
            configuration: DownloadQueueConfiguration(maxRetriesPerPage: 0, maxPageBytes: 1024)
        )

        _ = await coordinator.download(manga: Self.manga(), chapter: chapter)
        await coordinator.drain()
        #expect(coordinator.job(chapterID: chapter.id)?.state == .failed)
    }

    @Test("重试失败的任务会重新入队并最终完成")
    func retryFailedJob() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let (chapter, pages) = Self.chapter(1)
        // 第一次 403，之后成功
        let (coordinator, archive) = Self.makeCoordinator(
            root: root,
            imageOutcomes: [
                .failure(.httpStatus(code: 403, retryAfterSeconds: nil)),
                Self.imageOutcome(),
            ],
            pagesByChapter: [chapter.url: pages]
        )
        let manga = Self.manga()

        _ = await coordinator.download(manga: manga, chapter: chapter)
        await coordinator.drain()
        #expect(coordinator.job(chapterID: chapter.id)?.state == .failed)

        await coordinator.retry(chapterID: chapter.id)
        await coordinator.drain()
        #expect(coordinator.job(chapterID: chapter.id)?.state == .completed)
        #expect(archive.hasChapter(mangaID: manga.id, chapterID: chapter.id))
    }

    // MARK: 控制

    @Test("暂停的任务不会被推进；恢复后继续")
    func pauseAndResume() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let (chapter, pages) = Self.chapter(1)
        let (coordinator, archive) = Self.makeCoordinator(
            root: root,
            imageOutcomes: [Self.imageOutcome()],
            pagesByChapter: [chapter.url: pages]
        )
        let manga = Self.manga()

        _ = await coordinator.download(manga: manga, chapter: chapter)
        await coordinator.pause(chapterID: chapter.id)
        await coordinator.drain()

        #expect(coordinator.job(chapterID: chapter.id)?.state == .paused)
        #expect(archive.hasChapter(mangaID: manga.id, chapterID: chapter.id) == false)

        // 暂停中再 drain 也不动
        await coordinator.drain()
        #expect(coordinator.job(chapterID: chapter.id)?.state == .paused)

        await coordinator.resume(chapterID: chapter.id)
        await coordinator.drain()
        #expect(coordinator.job(chapterID: chapter.id)?.state == .completed)
        #expect(archive.hasChapter(mangaID: manga.id, chapterID: chapter.id))
    }

    @Test("取消的任务不产生归档，可重新下载")
    func cancelLeavesNothingBehind() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let (chapter, pages) = Self.chapter(1)
        let (coordinator, archive) = Self.makeCoordinator(
            root: root,
            imageOutcomes: [Self.imageOutcome()],
            pagesByChapter: [chapter.url: pages]
        )
        let manga = Self.manga()

        _ = await coordinator.download(manga: manga, chapter: chapter)
        await coordinator.cancel(chapterID: chapter.id)
        await coordinator.drain()

        #expect(coordinator.job(chapterID: chapter.id)?.state == .cancelled)
        #expect(archive.hasChapter(mangaID: manga.id, chapterID: chapter.id) == false)

        // 取消后重新下载应当能正常入队
        let again = await coordinator.download(manga: manga, chapter: chapter)
        #expect(again.enqueued == 1)
        await coordinator.drain()
        #expect(archive.hasChapter(mangaID: manga.id, chapterID: chapter.id))
    }

    @Test("清掉已终结任务记录")
    func removesFinishedJobs() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let (chapter, pages) = Self.chapter(1)
        let (coordinator, _) = Self.makeCoordinator(
            root: root,
            imageOutcomes: [Self.imageOutcome()],
            pagesByChapter: [chapter.url: pages]
        )

        _ = await coordinator.download(manga: Self.manga(), chapter: chapter)
        await coordinator.drain()
        #expect(coordinator.jobs.count == 1)

        let removed = await coordinator.removeFinished()
        #expect(removed == 1)
        #expect(coordinator.jobs.isEmpty)
    }

    // MARK: 归档维护

    @Test("删除归档后再查是「没下载」，并能重新下载")
    func deleteArchiveAllowsRedownload() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let (chapter, pages) = Self.chapter(1)
        let (coordinator, archive) = Self.makeCoordinator(
            root: root,
            imageOutcomes: [Self.imageOutcome()],
            pagesByChapter: [chapter.url: pages]
        )
        let manga = Self.manga()

        _ = await coordinator.download(manga: manga, chapter: chapter)
        await coordinator.drain()
        #expect(coordinator.archiveURL(mangaID: manga.id, chapterID: chapter.id) != nil)

        #expect(await coordinator.deleteArchive(mangaID: manga.id, chapterID: chapter.id))
        #expect(coordinator.isArchived(mangaID: manga.id, chapterID: chapter.id) == false)
        #expect(coordinator.archiveURL(mangaID: manga.id, chapterID: chapter.id) == nil)
        #expect(archive.allChapters().isEmpty)

        let again = await coordinator.download(manga: manga, chapter: chapter)
        #expect(again.enqueued == 1)
    }

    @Test("按作品与整体删除归档，并统计占用")
    func deleteByMangaAndAll() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let manga = Self.manga()
        let (c1, p1) = Self.chapter(1)
        let (c2, p2) = Self.chapter(2)
        let (coordinator, archive) = Self.makeCoordinator(
            root: root,
            imageOutcomes: [Self.imageOutcome()],
            pagesByChapter: [c1.url: p1, c2.url: p2]
        )

        _ = await coordinator.download(manga: manga, chapters: [c1, c2])
        await coordinator.drain()
        await coordinator.refreshArchives()
        #expect(coordinator.archivedChapterCount == 2)
        #expect(coordinator.archivedBytes > 0)
        #expect(coordinator.archivedGroups.first?.pageCount == 6)

        #expect(await coordinator.deleteArchives(mangaID: manga.id) == 2)
        #expect(coordinator.archivedChapterCount == 0)

        _ = await coordinator.download(manga: manga, chapter: c1)
        await coordinator.drain()
        #expect(await coordinator.deleteAllArchives() == 1)
        #expect(archive.allChapters().isEmpty)
    }

    // MARK: 后台执行

    /// 记录后台断言的开合次数。
    private final class BackgroundWorkLedger: @unchecked Sendable {
        private let lock = NSLock()
        private var begins = 0
        private var ends = 0

        func recordBegin() {
            lock.lock(); begins += 1; lock.unlock()
        }

        func recordEnd() {
            lock.lock(); ends += 1; lock.unlock()
        }

        var beginCount: Int {
            lock.lock(); defer { lock.unlock() }; return begins
        }

        var endCount: Int {
            lock.lock(); defer { lock.unlock() }; return ends
        }
    }

    @Test("驱动下载期间申请后台时间，结束后归还")
    func holdsBackgroundWorkWhileDownloading() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let (chapter, pages) = Self.chapter(1)
        let archive = DownloadArchiveStore(
            rootDirectory: root.appendingPathComponent("Downloads", isDirectory: true)
        )
        let ledger = BackgroundWorkLedger()
        let coordinator = DownloadCoordinator(
            archive: archive,
            scratchDirectory: root.appendingPathComponent("Scratch", isDirectory: true),
            imageLoader: SourceImageLoader(transport: StubTransport(outcomes: [Self.imageOutcome()])),
            configuration: DownloadQueueConfiguration(maxRetriesPerPage: 0),
            pollIntervalNanoseconds: 0,
            loadPageList: { _, _ in pages },
            log: { _ in },
            beginBackgroundWork: { ledger.recordBegin() },
            endBackgroundWork: { ledger.recordEnd() }
        )

        _ = await coordinator.download(manga: Self.manga(), chapter: chapter)
        await coordinator.waitUntilSettled()

        #expect(coordinator.job(chapterID: chapter.id)?.state == .completed)
        #expect(archive.hasChapter(mangaID: Self.manga().id, chapterID: chapter.id))
        // 一次驱动 = 一次申请 + 一次归还；不归还的话系统会把进程强杀
        #expect(ledger.beginCount == 1)
        #expect(ledger.endCount == 1)
    }

    @Test("归档时按「归档时间倒序」返回，最新的在最前")
    func archivedChaptersAreNewestFirst() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let manga = Self.manga()
        let (c1, p1) = Self.chapter(1)
        let (c2, p2) = Self.chapter(2)
        let (coordinator, _) = Self.makeCoordinator(
            root: root,
            imageOutcomes: [Self.imageOutcome()],
            pagesByChapter: [c1.url: p1, c2.url: p2]
        )

        _ = await coordinator.download(manga: manga, chapter: c1)
        await coordinator.drain()
        try await Task.sleep(nanoseconds: 5_000_000)
        _ = await coordinator.download(manga: manga, chapter: c2)
        await coordinator.drain()

        let archived = coordinator.archivedChapters(mangaID: manga.id)
        #expect(archived.count == 2)
        #expect(archived.first?.chapterID == c2.id)
    }
}
