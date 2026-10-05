//
//  DownloadQueueTests.swift
//  MangaTranslaterTests
//
//  覆盖下载队列：正常完成、重试、失败回滚、取消清理、暂停 / 恢复、
//  并发上限、非法输入、超大单页、记录清理。
//

import Testing
import Foundation
import AppCore
import ComicNet
import ComicDownload

@Suite("下载队列")
struct DownloadQueueTests {

    private func makeJob(
        chapter: String = "c1",
        pages: [String] = ["https://example.com/1.jpg", "https://example.com/2.jpg"],
        sourceID: SourceID = SourceID("demo")
    ) -> DownloadJob {
        DownloadJob(
            sourceID: sourceID,
            mangaID: "\(sourceID.rawValue)|https://example.com/m",
            chapterID: chapter,
            chapterName: "第 1 话",
            pageURLs: pages
        )
    }

    private func makeQueue(
        configuration: DownloadQueueConfiguration = DownloadQueueConfiguration(),
        fetcher: PageFetching,
        store: PageStoring
    ) -> DownloadQueue {
        DownloadQueue(
            configuration: configuration,
            fetcher: fetcher,
            store: store,
            sleeper: { _ in }   // 测试不真实等待
        )
    }

    // MARK: 正常路径

    @Test("全部页下载成功后状态为完成")
    func completesSuccessfully() async throws {
        let store = InMemoryPageStore()
        let fetcher = StubPageFetcher(pageData: Data(repeating: 0xAB, count: 128))
        let queue = makeQueue(fetcher: fetcher, store: store)

        let job = try await queue.enqueue(makeJob(pages: [
            "https://example.com/1.jpg",
            "https://example.com/2.jpg",
            "https://example.com/3.jpg",
        ]))
        await queue.start()

        #expect(await queue.waitUntilIdle())
        let finished = try #require(await queue.job(job.id))

        #expect(finished.state == .completed)
        #expect(finished.completedPages == 3)
        #expect(finished.progress == 1.0)
        #expect(store.storedPageCount(jobID: job.id) == 3)
        #expect(fetcher.totalCalls == 3)
    }

    @Test("任务内页按顺序串行抓取")
    func pagesAreSequentialWithinJob() async throws {
        let store = InMemoryPageStore()
        let fetcher = StubPageFetcher(pageData: Data([0x01]))
        let queue = makeQueue(fetcher: fetcher, store: store)

        try await queue.enqueue(makeJob(pages: (0..<5).map { "https://example.com/\($0).jpg" }))
        await queue.start()
        #expect(await queue.waitUntilIdle())

        // 单任务内不并发抓页
        #expect(fetcher.peakConcurrency == 1)
    }

    @Test("并发任务数不超过配置上限")
    func respectsConcurrencyLimit() async throws {
        let store = InMemoryPageStore()
        let fetcher = StubPageFetcher(pageData: Data([0x01]))
        let queue = makeQueue(
            configuration: DownloadQueueConfiguration(maxConcurrentJobs: 2),
            fetcher: fetcher,
            store: store
        )

        for index in 0..<4 {
            try await queue.enqueue(makeJob(chapter: "c\(index)", pages: [
                "https://example.com/\(index)-1.jpg",
                "https://example.com/\(index)-2.jpg",
            ]))
        }
        await queue.start()
        #expect(await queue.waitUntilIdle())

        #expect(fetcher.peakConcurrency <= 2)
        #expect(await queue.allJobs().allSatisfy { $0.state == .completed })
    }

    // MARK: 重试

    @Test("首次失败后重试成功")
    func retriesThenSucceeds() async throws {
        let store = InMemoryPageStore()
        let fetcher = StubPageFetcher(scriptedResults: [
            .failure(NetworkError.timeout(seconds: 15)),
            .success(Data([0x01])),
        ])
        let queue = makeQueue(
            configuration: DownloadQueueConfiguration(maxRetriesPerPage: 2, retryBackoff: [0.01]),
            fetcher: fetcher,
            store: store
        )

        let job = try await queue.enqueue(makeJob(pages: ["https://example.com/1.jpg"]))
        await queue.start()
        #expect(await queue.waitUntilIdle())

        let finished = try #require(await queue.job(job.id))
        #expect(finished.state == .completed)
        #expect(fetcher.calls(for: "https://example.com/1.jpg") == 2)
        #expect(await queue.recordedRetryWaits().count >= 1)
    }

    @Test("重试耗尽后任务失败并清理已下载数据")
    func failsAfterExhaustingRetries() async throws {
        let store = InMemoryPageStore()
        let fetcher = StubPageFetcher(scriptedResults: [.failure(NetworkError.offline)])
        let queue = makeQueue(
            configuration: DownloadQueueConfiguration(maxRetriesPerPage: 1, retryBackoff: [0.01]),
            fetcher: fetcher,
            store: store
        )

        let job = try await queue.enqueue(makeJob(pages: ["https://example.com/1.jpg"]))
        await queue.start()
        #expect(await queue.waitUntilIdle())

        let finished = try #require(await queue.job(job.id))
        #expect(finished.state == .failed)
        #expect(finished.errorMessage != nil)
        #expect(finished.completedPages == 0)
        // 回滚：不留半成品
        #expect(store.storedPageCount(jobID: job.id) == 0)
    }

    @Test("不可重试错误立即失败，不做重试")
    func nonRetryableErrorFailsImmediately() async throws {
        let store = InMemoryPageStore()
        let fetcher = StubPageFetcher(scriptedResults: [.failure(AppError.invalidInput("坏地址"))])
        let queue = makeQueue(
            configuration: DownloadQueueConfiguration(maxRetriesPerPage: 3, retryBackoff: [0.01]),
            fetcher: fetcher,
            store: store
        )

        let job = try await queue.enqueue(makeJob(pages: ["https://example.com/1.jpg"]))
        await queue.start()
        #expect(await queue.waitUntilIdle())

        #expect(await queue.job(job.id)?.state == .failed)
        #expect(fetcher.calls(for: "https://example.com/1.jpg") == 1)
        #expect(await queue.recordedRetryWaits().isEmpty)
    }

    @Test("单页数据超过上限时失败")
    func rejectsOversizedPage() async throws {
        let store = InMemoryPageStore()
        let fetcher = StubPageFetcher(pageData: Data(repeating: 0x01, count: 4096))
        let queue = makeQueue(
            configuration: DownloadQueueConfiguration(maxRetriesPerPage: 0, maxPageBytes: 1024),
            fetcher: fetcher,
            store: store
        )

        let job = try await queue.enqueue(makeJob(pages: ["https://example.com/1.jpg"]))
        await queue.start()
        #expect(await queue.waitUntilIdle())

        #expect(await queue.job(job.id)?.state == .failed)
        #expect(store.storedPageCount(jobID: job.id) == 0)
    }

    // MARK: 暂停 / 恢复

    @Test("暂停的任务不被调度，恢复后继续完成")
    func pauseAndResume() async throws {
        let store = InMemoryPageStore()
        let fetcher = StubPageFetcher(pageData: Data([0x01]))
        let queue = makeQueue(
            configuration: DownloadQueueConfiguration(maxConcurrentJobs: 1),
            fetcher: fetcher,
            store: store
        )

        let paused = try await queue.enqueue(makeJob(chapter: "paused", pages: [
            "https://example.com/a1.jpg",
            "https://example.com/a2.jpg",
            "https://example.com/a3.jpg",
        ]))
        await queue.pause(paused.id)

        let running = try await queue.enqueue(makeJob(chapter: "running", pages: ["https://example.com/b1.jpg"]))
        await queue.start()
        #expect(await queue.waitUntilIdle())

        // 暂停的任务完全没被碰过
        #expect(await queue.job(paused.id)?.state == .paused)
        #expect(store.storedPageCount(jobID: paused.id) == 0)
        #expect(await queue.job(running.id)?.state == .completed)

        // 恢复后跑完
        await queue.resume(paused.id)
        #expect(await queue.waitUntilIdle())
        #expect(await queue.job(paused.id)?.state == .completed)
        #expect(store.storedPageCount(jobID: paused.id) == 3)
    }

    @Test("对已完成任务暂停 / 恢复为无操作")
    func pauseResumeOnFinishedIsNoop() async throws {
        let store = InMemoryPageStore()
        let queue = makeQueue(fetcher: StubPageFetcher(pageData: Data([0x01])), store: store)

        let job = try await queue.enqueue(makeJob(pages: ["https://example.com/1.jpg"]))
        await queue.start()
        #expect(await queue.waitUntilIdle())

        await queue.pause(job.id)
        #expect(await queue.job(job.id)?.state == .completed)
        await queue.resume(job.id)
        #expect(await queue.job(job.id)?.state == .completed)
    }

    // MARK: 取消

    @Test("取消排队中的任务并清理数据")
    func cancelPendingJob() async throws {
        let store = InMemoryPageStore()
        let fetcher = StubPageFetcher(pageData: Data([0x01]))
        let queue = makeQueue(
            configuration: DownloadQueueConfiguration(maxConcurrentJobs: 1),
            fetcher: fetcher,
            store: store
        )

        let first = try await queue.enqueue(makeJob(chapter: "first", pages: [
            "https://example.com/a1.jpg",
            "https://example.com/a2.jpg",
        ]))
        let second = try await queue.enqueue(makeJob(chapter: "second", pages: ["https://example.com/b1.jpg"]))

        await queue.start()
        await queue.cancel(second.id)
        #expect(await queue.waitUntilIdle())

        #expect(await queue.job(second.id)?.state == .cancelled)
        #expect(store.storedPageCount(jobID: second.id) == 0)
        #expect(await queue.job(first.id)?.state == .completed)
    }

    @Test("取消已完成任务为无操作")
    func cancelFinishedIsNoop() async throws {
        let store = InMemoryPageStore()
        let queue = makeQueue(fetcher: StubPageFetcher(pageData: Data([0x01])), store: store)

        let job = try await queue.enqueue(makeJob(pages: ["https://example.com/1.jpg"]))
        await queue.start()
        #expect(await queue.waitUntilIdle())

        await queue.cancel(job.id)
        #expect(await queue.job(job.id)?.state == .completed)
    }

    @Test("cancelAll 取消所有未终结任务")
    func cancelAllJobs() async throws {
        let store = InMemoryPageStore()
        let queue = makeQueue(
            configuration: DownloadQueueConfiguration(maxConcurrentJobs: 1),
            fetcher: StubPageFetcher(pageData: Data([0x01])),
            store: store
        )

        for index in 0..<3 {
            try await queue.enqueue(makeJob(chapter: "c\(index)", pages: ["https://example.com/\(index).jpg"]))
        }
        await queue.cancelAll()
        #expect(await queue.waitUntilIdle())
        #expect(await queue.allJobs().allSatisfy { $0.state == .cancelled })
    }

    // MARK: 非法输入

    @Test("空页列表被拒绝")
    func rejectsEmptyPages() async {
        let queue = makeQueue(fetcher: StubPageFetcher(), store: InMemoryPageStore())
        await expectThrowsAsync(AppError.invalidInput("章节没有可下载的页")) {
            _ = try await queue.enqueue(self.makeJob(pages: []))
        }
    }

    @Test("空章节标识被拒绝")
    func rejectsEmptyChapterID() async {
        let queue = makeQueue(fetcher: StubPageFetcher(), store: InMemoryPageStore())
        await expectThrowsAsync(AppError.invalidInput("章节标识为空")) {
            _ = try await queue.enqueue(self.makeJob(chapter: "", pages: ["https://example.com/1.jpg"]))
        }
    }

    @Test("重复入队被拒绝")
    func rejectsDuplicateJob() async throws {
        let queue = makeQueue(fetcher: StubPageFetcher(), store: InMemoryPageStore())
        try await queue.enqueue(makeJob(chapter: "dup", pages: ["https://example.com/1.jpg"]))

        await expectThrowsAsync(AppError.invalidInput("任务已存在：dup")) {
            _ = try await queue.enqueue(self.makeJob(chapter: "dup", pages: ["https://example.com/2.jpg"]))
        }
    }

    // MARK: 记录清理

    @Test("清理已终结任务")
    func removeFinishedJobs() async throws {
        let store = InMemoryPageStore()
        let queue = makeQueue(fetcher: StubPageFetcher(pageData: Data([0x01])), store: store)

        try await queue.enqueue(makeJob(chapter: "c1", pages: ["https://example.com/1.jpg"]))
        try await queue.enqueue(makeJob(chapter: "c2", pages: ["https://example.com/2.jpg"]))
        await queue.start()
        #expect(await queue.waitUntilIdle())

        let removed = await queue.removeFinished()
        #expect(removed == 2)
        #expect(await queue.allJobs().isEmpty)
    }

    @Test("初始状态为空闲")
    func startsIdle() async {
        let queue = makeQueue(fetcher: StubPageFetcher(), store: InMemoryPageStore())
        #expect(await queue.isIdle)
        #expect(await queue.runningJobCount == 0)
        #expect(await queue.pendingJobCount == 0)
    }

    @Test("进度计算：部分完成")
    func progressCalculation() {
        var job = makeJob(pages: ["a", "b", "c", "d"])
        job.completedPages = 1
        #expect(abs(job.progress - 0.25) < 0.0001)
        #expect(job.totalPages == 4)
    }
}
