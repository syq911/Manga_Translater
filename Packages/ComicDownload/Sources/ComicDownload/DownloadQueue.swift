//
//  DownloadQueue.swift
//  ComicDownload
//
//  下载队列（actor）。
//
//  设计（0.2.0 重构）：
//  - **不派生后台任务来驱动状态机**。推进流程是显式的 async 方法
//    `processPending()`：它依次取出待办任务、逐页抓取。于是
//    「何时推进一页、何时算结束」完全由调用方掌握 —— 测试无需轮询等待，
//    也不存在后台任务被调度器挂起的可能（0.1.0 的 `Task{}` 方案在 CI 上
//    出现过任务永久停在中途的实测问题）。
//  - `start()` 是给 App 用的便利入口：内部派生**一个**任务去跑
//    `processPending()`，等待结束用 `waitUntilIdle()`。
//  - 取消是**协作式**的：置状态为 `.cancelled`，处理循环在下一页边界收尾并
//    清理，不依赖 `Task.cancel()`（也就能保证「取消后磁盘无残留」可被测试断言）。
//  - `processPending()` 单线程推进，因此同一时刻只会处理一个任务，
//    `maxConcurrentJobs` 天然不会被突破。
//
//  重试等待通过注入的 `sleeper` 实现，测试无需真实等待。
//

import Foundation
import AppCore
import ComicNet

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
    /// 作品标题。队列本身不用它，但「下载」页要显示「哪部作品的哪一话」——
    /// 只靠主键（含 URL）没法给人看。
    public var mangaTitle: String
    public let chapterID: String
    public var chapterName: String
    public let pageURLs: [String]
    public var headers: [String: String]
    /// 页级请求头（按 URL）。契约允许每页带自己的 `headers`，
    /// 而队列抓页时只给得到 URL——所以这里按 URL 存一份，抓取器按 URL 取用。
    public var pageHeaders: [String: [String: String]]
    /// 抓图时的 `Referer`（通常是章节页地址）。防盗链站点的必需项。
    public var referer: String?
    public var state: DownloadState
    public var completedPages: Int
    public var pageAttempts: Int
    public var errorMessage: String?

    public init(
        sourceID: SourceID,
        mangaID: String,
        mangaTitle: String = "",
        chapterID: String,
        chapterName: String,
        pageURLs: [String],
        headers: [String: String] = [:],
        pageHeaders: [String: [String: String]] = [:],
        referer: String? = nil,
        state: DownloadState = .pending,
        completedPages: Int = 0,
        pageAttempts: Int = 0,
        errorMessage: String? = nil
    ) {
        self.id = chapterID
        self.sourceID = sourceID
        self.mangaID = mangaID
        self.mangaTitle = mangaTitle
        self.chapterID = chapterID
        self.chapterName = chapterName
        self.pageURLs = pageURLs
        self.headers = headers
        self.pageHeaders = pageHeaders
        self.referer = referer
        self.state = state
        self.completedPages = completedPages
        self.pageAttempts = pageAttempts
        self.errorMessage = errorMessage
    }

    /// 某一页实际要带的请求头。
    ///
    /// **逐键**合并：页级只覆盖它自己声明的键，其余从任务级取。
    /// 直接整体替换是错的——页级只写了 `X-Page` 时，任务级的 `Referer`
    /// 会被整块丢掉，防盗链站点立刻 403。
    /// 同名键比较用**小写**：HTTP 头不区分大小写，`referer` 与 `Referer`
    /// 同时存在会让底层只取其中一个，行为变得不可预测。
    public func headers(forURL url: String) -> [String: String] {
        guard let page = pageHeaders[url], !page.isEmpty else { return headers }
        var merged = headers
        for (key, value) in page {
            for existing in merged.keys where existing.lowercased() == key.lowercased() {
                merged.removeValue(forKey: existing)
            }
            merged[key] = value
        }
        return merged
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
    private var isProcessing = false
    private var processingTask: Task<Void, Never>?
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
    /// - Throws: `AppError.invalidInput`——页列表为空、章节标识为空或任务重复。
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
        created.completedPages = 0
        created.pageAttempts = 0
        created.errorMessage = nil
        jobs[created.id] = created
        order.append(created.id)
        notify(created)
        return created
    }

    // MARK: 驱动

    /// App 用入口：派生一个任务推进队列（幂等）。
    /// 等待结束用 `waitUntilIdle()`；测试建议直接 `await processPending()`。
    ///
    /// 这里用 `Task.detached` 而不是 `Task {}`：后者会继承 actor 隔离，
    /// 在 CI 上实测出现过后台任务停在中途不再推进的情况；detached
    /// 明确跑在全局执行器上，只在访问状态时才跳回 actor，语义更清晰。
    public func start() {
        guard processingTask == nil else { return }
        processingTask = Task.detached(priority: .utility) { [weak self] in
            await self?.processPending()
            await self?.clearProcessingTask()
        }
    }

    /// 依次处理所有待办任务，直到没有待办为止。
    ///
    /// - 可安全重复调用；正在处理时再次调用立即返回（`isProcessing` 保护）。
    /// - 每推进一页前检查任务状态，因此暂停 / 取消都在页边界生效。
    public func processPending() async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }

        while let id = nextPendingJobID() {
            jobs[id]?.state = .running
            if let job = jobs[id] { notify(job) }
            await process(jobID: id)
        }
    }

    private func clearProcessingTask() {
        processingTask = nil
    }

    /// 取下一个待办任务（跳过暂停 / 已取消 / 已结束的）。
    private func nextPendingJobID() -> String? {
        order.first { jobs[$0]?.state == .pending }
    }

    // MARK: 控制

    /// 暂停任务：不再被调度。正在抓取的那一页会跑完，之后停在页边界。
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
    }

    /// 取消任务：置为取消并清理已下载数据。
    /// 若该任务正在处理，处理循环会在页边界停止后续抓取。
    public func cancel(_ id: String) async {
        guard var job = jobs[id], !job.state.isTerminal else { return }
        job.state = .cancelled
        job.completedPages = 0
        job.errorMessage = nil
        jobs[id] = job
        try? store.cleanup(jobID: id)
        notify(job)
    }

    /// 取消全部未终结任务。
    public func cancelAll() async {
        for id in order where !(jobs[id]?.state.isTerminal ?? true) {
            await cancel(id)
        }
    }

    /// 移除单个任务的记录（含已终结的）。返回是否移除。
    ///
    /// 「重新下载一个取消/失败的章节」必须先把旧记录摘掉：
    /// 队列里同 ID 只能有一个任务（`enqueue` 会拒绝重复），
    /// 而终结态的记录**会一直留着**——不摘掉就永远入不了队。
    @discardableResult
    public func remove(_ id: String) -> Bool {
        guard jobs.removeValue(forKey: id) != nil else { return false }
        order.removeAll { $0 == id }
        return true
    }

    /// 清空所有已终结任务的记录。返回清理条数。
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

    public var runningJobCount: Int {
        jobs.values.filter { $0.state == .running }.count
    }

    public var pendingJobCount: Int {
        jobs.values.filter { $0.state == .pending }.count
    }

    /// 是否已无待办 / 处理中任务。
    public var isIdle: Bool {
        !isProcessing && pendingJobCount == 0 && runningJobCount == 0
    }

    /// 轮询等待队列空闲（供 `start()` 之后使用；带超时）。
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

    // MARK: 处理

    /// 处理单个任务（actor 内方法，await 期间可响应其他消息）。
    private func process(jobID: String) async {
        guard var job = jobs[jobID] else { return }

        // 首次开始时准备目录（清空上次残留）；断点续跑保留已下载的页。
        if job.completedPages == 0 {
            do {
                try store.prepare(jobID: jobID)
            } catch {
                finish(jobID: jobID, state: .failed, message: AppError.normalize(error).localizedDescription)
                return
            }
        }

        for index in job.completedPages..<job.pageURLs.count {
            // 页边界状态检查：暂停 / 取消在此生效
            guard let current = jobs[jobID] else { return }
            switch current.state {
            case .paused, .cancelled, .completed, .failed:
                return
            case .pending, .running:
                break
            }

            let url = job.pageURLs[index]
            var attempt = 0
            var succeeded = false
            var lastMessage = "未知错误"

            while true {
                do {
                    let data = try await Self.fetchPage(
                        using: fetcher,
                        url: url,
                        headers: current.headers(forURL: url),
                        job: current
                    )
                    guard data.count <= configuration.maxPageBytes else {
                        throw AppError.invalidInput(
                            "单页数据过大（\(data.count) 字节，上限 \(configuration.maxPageBytes)）"
                        )
                    }
                    try store.store(data: data, jobID: jobID, index: index)
                    succeeded = true
                    break
                } catch {
                    let normalized = AppError.normalize(error)
                    // 错误信息与可重试判定都用网络层的精细表述：
                    // AppCore 不认识 NetworkError（依赖方向不允许反向 import），
                    // 只靠 AppError 会把 timeout 退化成不可重试的 .unknown。
                    lastMessage = Self.describe(error) ?? normalized.localizedDescription
                    let retryable = Self.isRetryable(error)
                    let canRetry = retryable && attempt < configuration.maxRetriesPerPage
                    guard canRetry else { break }

                    let waitIndex = min(attempt, configuration.retryBackoff.count - 1)
                    let wait = configuration.retryBackoff[waitIndex]
                    recordedWaits.append(wait)
                    do {
                        try await sleeper(wait)
                    } catch {
                        // 等待被取消 → 视为任务取消
                        jobs[jobID]?.state = .cancelled
                        try? store.cleanup(jobID: jobID)
                        if let updated = jobs[jobID] { notify(updated) }
                        return
                    }
                    attempt += 1
                    job.pageAttempts += 1
                    jobs[jobID]?.pageAttempts = job.pageAttempts
                }
            }

            guard succeeded else {
                // 回滚：不留半成品
                try? store.cleanup(jobID: jobID)
                finish(jobID: jobID, state: .failed, message: lastMessage)
                return
            }

            job.completedPages += 1
            jobs[jobID]?.completedPages = job.completedPages
            if let updated = jobs[jobID] { notify(updated) }
        }

        finish(jobID: jobID, state: .completed, message: nil)
    }

    // MARK: 错误判定

    /// 抓一页。支持 `JobAwarePageFetching` 的抓取器会拿到完整任务上下文
    /// （来源 Cookie / Referer 都由它决定）。
    private static func fetchPage(
        using fetcher: PageFetching,
        url: String,
        headers: [String: String],
        job: DownloadJob
    ) async throws -> Data {
        if let aware = fetcher as? JobAwarePageFetching {
            return try await aware.fetchPage(url: url, headers: headers, job: job)
        }
        return try await fetcher.fetchPage(url: url, headers: headers)
    }

    /// 是否可重试。网络层的错误类型携带更精细的判定
    /// （4xx 不重试、429/5xx/超时/离线可重试），优先使用它。
    public static func isRetryable(_ error: Error) -> Bool {
        if let networkError = error as? NetworkError {
            return networkError.isRetryable
        }
        return AppError.normalize(error).isRetryable
    }

    /// 人类可读的错误描述。网络错误用它自己的本地化文案。
    public static func describe(_ error: Error) -> String? {
        if let networkError = error as? NetworkError {
            return networkError.errorDescription
        }
        return nil
    }

    private func finish(jobID: String, state: DownloadState, message: String?) {
        guard var job = jobs[jobID] else { return }
        job.state = state
        job.errorMessage = message
        if state != .completed {
            job.completedPages = 0
        }
        jobs[jobID] = job
        notify(job)
    }

    private func notify(_ job: DownloadJob) {
        onChange?(job)
    }
}
