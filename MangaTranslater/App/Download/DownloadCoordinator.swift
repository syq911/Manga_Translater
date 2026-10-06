//
//  DownloadCoordinator.swift
//  MangaTranslater
//
//  下载的**唯一**入口：把「界面想下载什么」翻译成下载队列的任务，
//  并在任务完成后把散图打成 CBZ 归档。
//
//  为什么要在 `DownloadQueue` 之上再加一层：
//  `DownloadQueue` 刻意只做「给定页列表 → 逐页抓取落盘」，它不知道：
//  - 一章的页列表从哪来（要调源脚本，可能失败、可能要等网络）；
//  - 下载完的散图要变成什么（归档，这样离线阅读与本地漫画走同一条路）；
//  - 用户点「下载整话」时哪些章节该跳过（已下载的、重复点的）。
//  这些都属于应用层的编排，放在这里比塞进队列干净得多；
//  队列的测试也因此不用碰脚本与归档。
//
//  状态设计（@MainActor @Observable）：
//  - `jobs` 是队列状态的**快照**，由 `refreshJobs()` 拉取，界面直接读；
//  - `archivedByManga` 是归档状态的快照，同理。
//  两步都是「拉」而不是「推」：队列的回调跑在不确定的线程上，
//  直接往里写 UI 状态迟早会遇到「界面更新不在主线程」的偶发崩溃。
//

import Foundation
import Observation
import AppCore
import ComicDownload
import ComicNet
import SourceEngine

/// 一次「批量下载」请求的结果。
struct DownloadRequestResult: Equatable {
    /// 请求的章节数。
    let requested: Int
    /// 实际入队的章节数（已下载 / 已在队列中的会被跳过）。
    let enqueued: Int
    /// 取页列表失败等原因被跳过的章节。
    let skipped: [String]
    /// 给用户看的一句话（nil 表示无须提示）。
    var message: String? {
        if enqueued > 0 { return nil }
        if requested == 0 { return nil }
        if skipped.isEmpty { return L("downloads.nothingToDo") }
        return L("downloads.enqueueFailed")
    }
}

/// 已归档章节按作品分组（界面用）。
struct ArchivedGroup: Identifiable, Equatable {
    let mangaID: String
    let chapters: [DownloadedChapter]

    var id: String { mangaID }
    var totalBytes: Int { chapters.reduce(0) { $0 + $1.byteCount } }
    var pageCount: Int { chapters.reduce(0) { $0 + $1.pageCount } }
}

@MainActor
@Observable
final class DownloadCoordinator {

    /// 取某章的页列表（由 `AppEnvironment` 注入，走运行时池）。
    typealias PageListLoader = @Sendable (SourceID, String) async throws -> [ComicPage]

    private let queue: DownloadQueue
    private let scratch: FilePageStore
    private let archive: DownloadArchiveStore
    private let loadPageList: PageListLoader
    private let log: (String) -> Void
    /// 驱动循环的轮询间隔（测试传 0 让循环尽快收敛）。
    private let pollIntervalNanoseconds: UInt64

    // MARK: 对外状态

    /// 队列快照（顺序 = 入队顺序）。
    private(set) var jobs: [DownloadJob] = []
    /// 已归档章节，按作品分组（按作品标识排序，保证界面顺序稳定）。
    private(set) var archivedGroups: [ArchivedGroup] = []
    /// 最近一次操作给用户看的提示。
    var message: String?

    /// 正在进行的任务数。
    var activeJobCount: Int {
        jobs.filter { $0.state == .pending || $0.state == .running }.count
    }

    /// 全部已归档章节数。
    var archivedChapterCount: Int {
        archivedGroups.reduce(0) { $0 + $1.chapters.count }
    }

    /// 归档占用字节数。
    var archivedBytes: Int {
        archivedGroups.reduce(0) { $0 + $1.totalBytes }
    }

    private var archiving: Set<String> = []
    private var driver: Task<Void, Never>?

    init(
        archive: DownloadArchiveStore,
        scratchDirectory: URL,
        imageLoader: SourceImageLoader,
        configuration: DownloadQueueConfiguration = DownloadQueueConfiguration(),
        pollIntervalNanoseconds: UInt64 = 200_000_000,
        loadPageList: @escaping PageListLoader,
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.archive = archive
        self.scratch = FilePageStore(rootDirectory: scratchDirectory)
        self.loadPageList = loadPageList
        self.log = log
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.queue = DownloadQueue(
            configuration: configuration,
            fetcher: SourcePageFetcher(imageLoader: imageLoader),
            store: scratch
        )
    }

    // MARK: 查询

    /// 某章是否已下载到本地。
    func isArchived(mangaID: String, chapterID: String) -> Bool {
        archive.hasChapter(mangaID: mangaID, chapterID: chapterID)
    }

    /// 某作品已归档的章节（按归档时间倒序，最新的在前）。
    func archivedChapters(mangaID: String) -> [DownloadedChapter] {
        archive.chapters(mangaID: mangaID).sorted { $0.archivedAt > $1.archivedAt }
    }

    /// 已归档章节的 CBZ 路径（用于「导出 / 分享」）。
    func archiveURL(mangaID: String, chapterID: String) -> URL? {
        let url = archive.archiveURL(mangaID: mangaID, chapterID: chapterID)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 某章在队列里的任务。
    func job(chapterID: String) -> DownloadJob? {
        jobs.first { $0.chapterID == chapterID }
    }

    /// 该章当前的下载状态（界面用来决定按钮长什么样）。
    func state(chapterID: String) -> DownloadState? {
        job(chapterID: chapterID)?.state
    }

    /// 刷新队列与归档快照。
    func refresh() async {
        await refreshJobs()
        await refreshArchives()
    }

    private func refreshJobs() async {
        jobs = await queue.allJobs()
    }

    /// 重扫归档目录。
    ///
    /// 磁盘扫描放到后台：一本下满的合集可能有几百个章节、上百 MB 的清单读取，
    /// 在主线程做会让切到下载页时明显卡一下。
    func refreshArchives() async {
        let archive = self.archive
        let groups = await Task.detached(priority: .utility) { () -> [ArchivedGroup] in
            var byManga: [String: [DownloadedChapter]] = [:]
            for record in archive.allChapters() {
                byManga[record.mangaID, default: []].append(record)
            }
            return byManga
                .map { key, value in
                    ArchivedGroup(
                        mangaID: key,
                        chapters: value.sorted { $0.archivedAt > $1.archivedAt }
                    )
                }
                .sorted { $0.mangaID < $1.mangaID }
        }.value
        archivedGroups = groups
    }

    // MARK: 入队

    /// 下载一批章节（「下载全部」用）。
    ///
    /// 单章失败（页列表取不回来）**不中断整批**：一次「下载全部」里有 50 话，
    /// 因为第 3 话的页列表解析失败就整批不动，用户会觉得功能坏了。
    /// 失败的章节名收集起来一次性告知。
    @discardableResult
    func download(manga: Manga, chapters: [Chapter]) async -> DownloadRequestResult {
        var enqueued = 0
        var skipped: [String] = []
        for chapter in chapters {
            do {
                if try await enqueue(manga: manga, chapter: chapter) {
                    enqueued += 1
                }
            } catch {
                let reason = Self.describe(error)
                log("下载入队失败（\(chapter.name)）：\(reason)")
                skipped.append(chapter.name)
            }
        }
        let result = DownloadRequestResult(
            requested: chapters.count,
            enqueued: enqueued,
            skipped: skipped
        )
        if enqueued > 0 {
            startDriver()
        }
        message = result.message
        return result
    }

    /// 下载单章。
    @discardableResult
    func download(manga: Manga, chapter: Chapter) async -> DownloadRequestResult {
        await download(manga: manga, chapters: [chapter])
    }

    /// - Returns: 是否真的入队（已下载 / 已在队列中返回 false）。
    private func enqueue(manga: Manga, chapter: Chapter) async throws -> Bool {
        // 已下载：不重复下（用户重复点「下载」是最常见的手误）
        guard !archive.hasChapter(mangaID: manga.id, chapterID: chapter.id) else { return false }
        // 已在队列：也不重复（`enqueue` 本身会抛错，但这里提前返回更安静）
        let existing = await queue.job(chapter.id)
        guard existing == nil else { return false }

        let pages = try await loadPageList(manga.sourceID, chapter.url)
        guard !pages.isEmpty else {
            throw AppError.invalidInput("章节没有可下载的页")
        }

        // 只把「每页自带且各页一致」的请求头提升为任务级，其余按 URL 存。
        var pageHeaders: [String: [String: String]] = [:]
        for page in pages {
            guard let headers = page.headers, !headers.isEmpty else { continue }
            pageHeaders[page.imageURL] = headers
        }

        let job = DownloadJob(
            sourceID: manga.sourceID,
            mangaID: manga.id,
            chapterID: chapter.id,
            chapterName: chapter.name,
            pageURLs: pages.map(\.imageURL),
            pageHeaders: pageHeaders,
            referer: chapter.url
        )
        _ = try await queue.enqueue(job)
        await refreshJobs()
        return true
    }

    // MARK: 控制

    func pause(chapterID: String) async {
        await queue.pause(chapterID)
        await refreshJobs()
    }

    func resume(chapterID: String) async {
        await queue.resume(chapterID)
        await refreshJobs()
        startDriver()
    }

    func cancel(chapterID: String) async {
        await queue.cancel(chapterID)
        await refreshJobs()
    }

    func cancelAll() async {
        await queue.cancelAll()
        await refreshJobs()
    }

    /// 重试失败/取消的任务（把它们放回待办）。
    func retry(chapterID: String) async {
        guard let job = await queue.job(chapterID), job.state == .failed || job.state == .cancelled else {
            return
        }
        // 取消过的任务已完成页数已清零，直接重新入队即可
        await queue.cancel(chapterID)   // 确保是终结态并清掉残留
        _ = try? await queue.enqueue(DownloadJob(
            sourceID: job.sourceID,
            mangaID: job.mangaID,
            chapterID: job.chapterID,
            chapterName: job.chapterName,
            pageURLs: job.pageURLs,
            headers: job.headers,
            pageHeaders: job.pageHeaders,
            referer: job.referer,
            state: .pending
        ))
        await refreshJobs()
        startDriver()
    }

    /// 清掉已终结的任务记录。
    @discardableResult
    func removeFinished() async -> Int {
        let removed = await queue.removeFinished()
        await refreshJobs()
        return removed
    }

    // MARK: 归档维护

    /// 删除某章归档（同时清掉它的队列记录，让用户能重新下载）。
    @discardableResult
    func deleteArchive(mangaID: String, chapterID: String) async -> Bool {
        let removed = archive.removeChapter(mangaID: mangaID, chapterID: chapterID)
        if removed {
            await queue.cancel(chapterID)
            _ = await queue.removeFinished()
        }
        await refresh()
        return removed
    }

    /// 删除某作品的全部归档。
    @discardableResult
    func deleteArchives(mangaID: String) async -> Int {
        let removed = archive.removeManga(mangaID: mangaID)
        await refresh()
        return removed
    }

    /// 清空全部归档。
    @discardableResult
    func deleteAllArchives() async -> Int {
        let removed = archive.removeAll()
        await refresh()
        return removed
    }

    // MARK: 驱动

    /// 派生驱动任务（幂等）。等待收敛用 `waitUntilSettled()`。
    func startDriver() {
        guard driver == nil else { return }
        driver = Task { [weak self] in
            await self?.runDriver()
        }
    }

    /// 测试与「立即推进」入口：跑到底并完成归档，不派生任务。
    func drain() async {
        await queue.processPending()
        await finalizeCompleted()
        await refresh()
    }

    /// 等待当前驱动任务结束。
    func waitUntilSettled() async {
        await driver?.value
    }

    private func runDriver() async {
        // `processPending()` 会把当时所有待办跑完；跑完再看一次是否有新入队的。
        while true {
            await queue.processPending()
            await finalizeCompleted()
            await refreshJobs()
            if await queue.isIdle { break }
            if pollIntervalNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            } else {
                await Task.yield()
            }
        }
        await refreshArchives()
        driver = nil
    }

    /// 把已完成任务的散图打成 CBZ。
    ///
    /// 打包放在后台：一本 40 页的章节要压缩几十 MB，在主线程做会让界面卡住。
    private func finalizeCompleted() async {
        let pending = await queue.allJobs()
        for job in pending where job.state == .completed {
            guard !archiving.contains(job.id) else { continue }
            guard !archive.hasChapter(mangaID: job.mangaID, chapterID: job.chapterID) else {
                // 已经归档过（例如上次归档成功但任务记录还在）→ 清掉散图即可
                try? scratch.cleanup(jobID: job.id)
                continue
            }
            archiving.insert(job.id)
            defer { archiving.remove(job.id) }

            let scratch = self.scratch
            let archive = self.archive
            let record = await Task.detached(priority: .utility) { () -> DownloadedChapter? in
                let pages = scratch.pages(jobID: job.id)
                guard !pages.isEmpty else { return nil }
                let record = try? archive.archive(
                    pages: pages,
                    mangaID: job.mangaID,
                    chapterID: job.chapterID,
                    chapterName: job.chapterName
                )
                // 归档成功才清散图：失败时留着，下次可以直接重试打包
                if record != nil {
                    try? scratch.cleanup(jobID: job.id)
                }
                return record
            }.value

            if let record {
                log("已归档 \(job.chapterName)（\(record.pageCount) 页 / \(record.byteCount) 字节）")
            } else {
                log("归档失败：\(job.chapterName)")
                message = L("downloads.archiveFailed")
            }
        }
    }

    // MARK: 辅助

    private static func describe(_ error: Error) -> String {
        if let runnerError = error as? SourceRunnerError { return runnerError.message }
        return AppError.normalize(error).localizedDescription
    }
}
