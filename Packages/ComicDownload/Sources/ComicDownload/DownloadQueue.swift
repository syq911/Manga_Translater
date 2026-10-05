//
//  DownloadQueue.swift
//  ComicDownload
//
//  下载队列（actor）：并发上限、逐页重试、暂停 / 恢复 / 取消、
//  失败与取消时的资源清理（回滚）。
//
//  并发安全由 actor 保证；对外只暴露 async 接口。
//  重试等待通过注入的 `sleeper` 实现，测试无需真实等待。
//

import Foundation
import AppCore

/// 下载状态。
public enum DownloadState: String, Codable, Sendable {
    case pending
    case running
    case paused
    case completed
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        case .pending, .running, .paused: return false
        }
    }
}

/// 一个下载任务（一章）。
public struct DownloadJob: Identifiable, Equatable, Sendable {
    public let id: String
    public let sourceID: SourceID
    public let mangaID: String
    public let chapterID: String
    public var chapterName: String
    public let pageURLs: [String]
    public var headers: [String: String]
    public var state: DownloadState
    public var completedPages: Int
    public var pageAttempts: Int
    public var errorMessage: String?

    public init(
        sourceID: SourceID,
        mangaID: String,
        chapterID: String,
        chapterName: String,
        pageURLs: [String],
        headers: [String: String] = [:],
        state: DownloadState = .pending,
        completedPages: Int = 0,
        pageAttempts: Int = 0,
        errorMessage: String? = nil
    ) {
        self.id = chapterID
        self.sourceID = sourceID
        self.mangaID = mangaID
        self.chapterID = chapterID
        self.chapterName = chapterName
        self.pageURLs = pageURLs
        self.headers = headers
        self.state = state
        self.completedPages = completedPages
        self.pageAttempts = pageAttempts
        self.errorMessage = errorMessage
    }

    /// 进度 0...1。
    public var progress: Double {
        guard !pageURLs.isEmpty else { return 0 }
        return Double(completedPages) / Double(pageURLs.count)
    }

    public var totalPages: Int { pageURLs.count }
}

/// 队列配置。
public struct DownloadQueueConfiguration: Equatable, Sendable {
    /// 同时进行的任务数上限。
    public var maxConcurrentJobs: Int
    /// 单页最大重试次数（不含首次）。
    public var maxRetriesPerPage: Int
    /// 重试退避（秒），按顺序取，超出用最后一个。
    public var retryBackoff: [TimeInterval]
    /// 单页数据大小上限（字节）。
    public var maxPageBytes: Int

    public init(
        maxConcurrentJobs: Int = 2,
        maxRetriesPerPage: Int = 2,
        retryBackoff: [TimeInterval] = [0.5, 1.5],
        maxPageBytes: Int = 20 * 1024 * 1024
    ) {
        self.maxConcurrentJobs = max(1, maxConcurrentJobs)
        self.maxRetriesPerPage = max(0, maxRetriesPerPage)
        self.retryBackoff = retryBackoff.isEmpty ? [0.5] : retryBackoff
        self.maxPageBytes = max(1024, maxPageBytes)
    }
}

/// 下载队列。
public actor DownloadQueue {

    private let configuration: DownloadQueueConfiguration
    private let fetcher: PageFetching
    private let store: PageStoring
    private let sleeper: @Sendable (TimeInterval) async throws -> Void
    private let onChange: (@Sendable (DownloadJob) -> Void)?

    private var jobs: [String: DownloadJob] = [:]
    private var order: [String] = []
    private var active: Set<String> = []
    private var tasks: [String: Task<Void, Never>] = [:]
    /// 当前各任务的重试等待（用于统计与断言）。
    private var recordedWaits: [TimeInterval] = []

    public init(
        configuration: DownloadQueueConfiguration = DownloadQueueConfiguration(),
        fetcher: PageFetching,
        store: PageStoring,
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = { interval in
            guard interval > 0 else { return }
            try await Task.sleep(nanoseconds: UInt64((interval * 1_000_000_000).rounded()))
        },
        onChange: (@Sendable (DownloadJob) -> Void)? = nil
    ) {
        self.configuration = configuration
        self.fetcher = fetcher
        self.store = store
        self.sleeper = sleeper
        self.onChange = onChange
    }

    // MARK: 入队

    /// 加入一个任务。
    /// - Throws: `AppError.invalidInput`——页列表为空或任务重复。
    @discardableResult
    public func enqueue(_ job: DownloadJob) throws -> DownloadJob {
        guard !job.pageURLs.isEmpty else {
            throw AppError.invalidInput("章节没有可下载的页")
        }
        guard !job.chapterID.isEmpty else {
            throw AppError.invalidInput("章节标识为空")
        }
        guard jobs[job.id] == nil else {
            throw AppError.invalidInput("任务已存在：\(job.id)")
        }
        var created = job
        created.state = .pending
        jobs[created.id] = created
        order.append(created.id)
        notify(created)
        pump()
        return created
    }

    // MARK: 控制

    /// 开始（或继续）调度待处理任务。
    public func start() {
        pump()
    }

    /// 暂停任务：不再调度新页，已在进行中的页会跑完。
    public func pause(_ id: String) {
        guard var job = jobs[id], !job.state.isTerminal else { return }
        job.state = .paused
        jobs[id] = job
        notify(job)
    }

    /// 恢复任务。
    public func resume(_ id: String) {
        guard var job = jobs[id], job.state == .paused else { return }
        job.state = .pending
        jobs[id] = job
        notify(job)
        pump()
    }

    /// 取消任务：中断在途请求并清理已下载数据。
    public func cancel(_ id: String) async {
        guard var job = jobs[id], !job.state.isTerminal else { return }
        tasks[id]?.cancel()
        tasks[id] = nil
        active.remove(id)
        try? store.cleanup(jobID: id)
        job.state = .cancelled
        job.completedPages = 0
        job.errorMessage = nil
        jobs[id] = job
        notify(job)
        pump()
    }

    /// 取消全部。
    public func cancelAll() async {
        for id in jobs.keys where !(jobs[id]?.state.isTerminal ?? true) {
            await cancel(id)
        }
    }

    /// 清空所有已完成 / 失败 / 取消的记录。
    @discardableResult
    public func removeFinished() -> Int {
        let finished = jobs.filter { $0.value.state.isTerminal }.map(\.key)
        for id in finished {
            jobs.removeValue(forKey: id)
            order.removeAll { $0 == id }
        }
        return finished.count
    }

    // MARK: 查询

    public func job(_ id: String) -> DownloadJob? { jobs[id] }

    public func allJobs() -> [DownloadJob] {
        order.compactMap { jobs[$0] }
    }

    public var runningJobCount: Int { active.count }

    public var pendingJobCount: Int {
        jobs.values.filter { $0.state == .pending }.count
    }

    /// 是否已无待处理 / 进行中任务（测试与「下载全部完成」提示用）。
    public var isIdle: Bool {
        active.isEmpty && pendingJobCount == 0
    }

    /// 轮询等待队列空闲（测试用，带超时）。
    public func waitUntilIdle(timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isIdle { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return isIdle
    }

    /// 记录到的重试等待时长（测试断言用）。
    public func recordedRetryWaits() -> [TimeInterval] { recordedWaits }

    // MARK: 调度

    private func pump() {
        while active.count < configuration.maxConcurrentJobs {
            guard let id = order.first(where: { jobs[$0]?.state == .pending && !active.contains($0) }) else {
                return
            }
            guard var job = jobs[id] else { return }
            job.state = .running
            jobs[id] = job
            active.insert(id)
            notify(job)

            tasks[id] = Task { [weak self] in
                await self?.run(jobID: id)
            }
        }
    }

    /// 执行一个任务（actor 内方法，await 期间可处理其他消息）。
    private func run(jobID: String) async {
        guard var job = jobs[jobID] else { return }

        do {
            // 首次开始时准备目录（会清空上次残留）；断点恢复时保留已下载的页。
            if job.completedPages == 0 {
                try store.prepare(jobID: jobID)
            }
        } catch {
            finish(jobID: jobID, state: .failed, message: AppError.normalize(error).localizedDescription)
            return
        }

        for index in job.completedPages..<job.pageURLs.count {
            // 取消 / 暂停检查
            if jobs[jobID]?.state == .cancelled { return }
            if jobs[jobID]?.state == .paused {
                // 让出调度权，等 resume 再继续
                active.remove(jobID)
                tasks[jobID] = nil
                return
            }
            if Task.isCancelled {
                jobs[jobID]?.state = .cancelled
                try? store.cleanup(jobID: jobID)
                return
            }

            let url = job.pageURLs[index]
            var attempt = 0
            var success = false
            var lastMessage = "未知错误"

            while attempt <= configuration.maxRetriesPerPage {
                do {
                    let data = try await fetcher.fetchPage(url: url, headers: job.headers)
                    guard data.count <= configuration.maxPageBytes else {
                        throw AppError.invalidInput("单页数据过大（\(data.count) 字节）")
                    }
                    try store.store(data: data, jobID: jobID, index: index)
                    success = true
                    break
                } catch {
                    let normalized = AppError.normalize(error)
                    lastMessage = normalized.localizedDescription
                    if !normalized.isRetryable || attempt == configuration.maxRetriesPerPage {
                        break
                    }
                    let waitIndex = min(attempt, configuration.retryBackoff.count - 1)
                    let wait = configuration.retryBackoff[waitIndex]
                    recordedWaits.append(wait)
                    do {
                        try await sleeper(wait)
                    } catch {
                        // 睡眠被取消 → 视为取消
                        try? store.cleanup(jobID: jobID)
                        jobs[jobID]?.state = .cancelled
                        active.remove(jobID)
                        tasks[jobID] = nil
                        notify(jobs[jobID] ?? job)
                        return
                    }
                    attempt += 1
                    job.pageAttempts += 1
                    jobs[jobID]?.pageAttempts = job.pageAttempts
                }
            }

            guard success else {
                // 失败 → 回滚已下载数据
                try? store.cleanup(jobID: jobID)
                finish(jobID: jobID, state: .failed, message: lastMessage)
                return
            }

            job.completedPages += 1
            jobs[jobID]?.completedPages = job.completedPages
            notify(jobs[jobID] ?? job)
        }

        finish(jobID: jobID, state: .completed, message: nil)
    }

    private func finish(jobID: String, state: DownloadState, message: String?) {
        guard var job = jobs[jobID] else { return }
        job.state = state
        job.errorMessage = message
        if state != .completed {
            job.completedPages = 0
        }
        jobs[jobID] = job
        active.remove(jobID)
        tasks[jobID] = nil
        notify(job)
        pump()
    }

    private func notify(_ job: DownloadJob) {
        onChange?(job)
    }
}
