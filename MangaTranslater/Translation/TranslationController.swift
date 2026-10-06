//
//  TranslationController.swift
//  MangaTranslater
//
//  页内翻译编排器：识别 → 翻译 → 排版，按 (来源, 作品地址, 页号) 缓存译文图。
//
//  交互（《开发手册》6.3）：
//  顶部翻译按钮**点一下开启连续翻译**（当前页 + 后面几页并行翻译），
//  **再点一下显示原文**。翻页时自动把新进入窗口的页补进队列，
//  因此可以一路往下看，不必每页手动点。
//
//  刻意做的三件事：
//  1. **预取窗口远小于读图预加载窗口**（见 `settings.translationPrefetchWindow`）：
//     看图免费，翻译按页计费/耗额度，默认往前只取 2 页。
//  2. **额度不足不打断阅读**：额度类错误单独放在 `quotaMessage` 里，
//     由界面显示一个可点掉的横幅 + 「升级云服务」入口，而不是弹窗或中断。
//  3. **失败页不再反复试探**：失败记进 `cacheProbe`，避免每次刷新界面
//     都去磁盘查一次不存在的缓存。
//
//  并行度：现代 Vision API 超过 2 个并行会死锁；端上翻译会话也只支持一个，
//  因此上限分别是 2 / 1。这是硬约束，不是调优参数。
//

import Foundation
import Observation
import CoreGraphics
import UIKit
import AppCore

@MainActor
@Observable
final class TranslationController {

    /// 解析「当前该用哪个后端」。注入以便测试替换成脚本化后端；
    /// 生产实现由 `AppEnvironment` 组装（读设置 + 自备密钥 + 云会话）。
    typealias Resolver = @MainActor (TranslationBackend) -> MangaTranslator?

    /// 造一个 OCR 识别器。注入以便测试不依赖真实 Vision。
    typealias RecognizerFactory = @Sendable (TranslationLanguage, Bool) -> TextRecognizing

    // MARK: 可观察状态

    /// 连续翻译是否开启（顶部按钮的开关状态）。
    private(set) var isActive = false
    /// 是否显示译文（false 时显示原图）。
    private(set) var showsTranslation = false
    /// 队列中 + 进行中的页数。
    private(set) var pendingCount = 0
    /// 本次会话已完成的页数。
    private(set) var completedCount = 0
    /// 最近一次失败（界面显示可点掉的横幅）。
    private(set) var failureMessage: String?
    /// 额度类问题的说明（界面显示「升级云服务」入口，不打断阅读）。
    private(set) var quotaMessage: String?

    // MARK: 依赖

    /// Apple 端上翻译桥；视图侧用 `.translationTask(translation.appleBridge.configuration)` 消费。
    @ObservationIgnored let appleBridge: AppleTranslationBridge

    @ObservationIgnored private let store: TranslationStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let resolver: Resolver
    @ObservationIgnored private let makeRecognizer: RecognizerFactory

    // MARK: 内部状态

    private struct Job {
        let manga: Manga
        let page: Int
        let image: PlatformImage
    }

    @ObservationIgnored private var queue: [PageTranslationKey] = []
    @ObservationIgnored private var running: Set<PageTranslationKey> = []
    @ObservationIgnored private var jobs: [PageTranslationKey: Job] = [:]
    @ObservationIgnored private var tasks: [PageTranslationKey: Task<Void, Never>] = [:]
    /// 已探过的缓存：true=有、false=没有。避免在界面刷新时反复查磁盘。
    @ObservationIgnored private var cacheProbe: [PageTranslationKey: Bool] = [:]
    /// 已排版好的整页图（小容量 LRU，避免每帧去解 PNG）。
    @ObservationIgnored private var memory: [PageTranslationKey: PlatformImage] = [:]
    @ObservationIgnored private var memoryOrder: [PageTranslationKey] = []
    /// 内存里保留的译文页数上限。
    private static let memoryLimit = 16

    init(
        store: TranslationStore,
        settings: AppSettings,
        resolver: @escaping Resolver,
        appleBridge: AppleTranslationBridge? = nil,
        makeRecognizer: RecognizerFactory? = nil
    ) {
        self.store = store
        self.settings = settings
        self.resolver = resolver
        self.appleBridge = appleBridge ?? AppleTranslationBridge()
        // 默认值刻意写成 `nil` + init 体内兜底（而不是直接给默认实参）：
        // 默认实参在调用方求值，而 `defaultRecognizer` 是主 actor 隔离的静态成员，
        // 写成默认实参会被并发检查拒绝。
        self.makeRecognizer = makeRecognizer ?? Self.defaultRecognizer
    }

    /// 生产环境的识别器：原图直接识别，语言与漏行兜底取自设置。
    static let defaultRecognizer: RecognizerFactory = { language, usesLineDropFallback in
        var recognizer = VisionTextRecognizer(languages: language.visionLanguages)
        recognizer.usesLineDropFallback = usesLineDropFallback
        return recognizer
    }

    // MARK: - 查询

    var isBusy: Bool { pendingCount > 0 }

    /// 还剩多少页没译完（进度浮层文案用）。
    var remainingCount: Int { pendingCount }

    /// 这一页是否已有译文（内存或缓存）。
    func hasTranslation(for manga: Manga, page: Int) -> Bool {
        let key = PageTranslationKey(manga: manga, page: page)
        if memory[key] != nil { return true }
        if let probed = cacheProbe[key] { return probed }
        let exists = store.contains(key)
        cacheProbe[key] = exists
        return exists
    }

    /// 展示用图片：显示译文且该页已有译文时返回译文图，否则返回原图。
    func displayImage(for manga: Manga, page: Int, original: PlatformImage?) -> PlatformImage? {
        guard showsTranslation else { return original }
        let key = PageTranslationKey(manga: manga, page: page)
        if let cached = memory[key] {
            touchMemory(key)
            return cached
        }
        // 已经探过且确认没有缓存 → 不再碰磁盘
        if cacheProbe[key] == false { return original }
        guard let stored = store.image(for: key) else {
            cacheProbe[key] = false
            return original
        }
        cacheProbe[key] = true
        putMemory(stored, for: key)
        return stored
    }

    func dismissFailure() { failureMessage = nil }

    func dismissQuotaNotice() { quotaMessage = nil }

    // MARK: - 顶部按钮：开 / 关连续翻译

    func toggle(manga: Manga, currentPage: Int, preloaded: [Int: PlatformImage]) {
        if isActive {
            isActive = false
            showsTranslation = false
            cancelPending()
        } else {
            isActive = true
            showsTranslation = true
            failureMessage = nil
            enqueuePreloaded(manga: manga, currentPage: currentPage, preloaded: preloaded)
        }
    }

    // MARK: - 翻页：补齐队列

    func onVisiblePageChanged(manga: Manga, currentPage: Int, preloaded: [Int: PlatformImage]) {
        guard isActive else { return }
        // 丢掉已经翻过去的页：释放内存，也避免把额度花在不会看的页上
        let stale = queue.filter { (jobs[$0]?.page ?? 0) < currentPage }
        queue.removeAll { stale.contains($0) }
        for key in stale { jobs[key] = nil }
        enqueuePreloaded(manga: manga, currentPage: currentPage, preloaded: preloaded)
    }

    /// 退出阅读器：取消全部在跑的任务并清掉内存状态。**磁盘缓存保留**
    /// （下次看同一话不必重复花钱）。
    func stopAndReset() {
        isActive = false
        showsTranslation = false
        cancelPending()
        memory.removeAll()
        memoryOrder.removeAll()
        cacheProbe.removeAll()
        completedCount = 0
        failureMessage = nil
        quotaMessage = nil
        appleBridge.cancel()
    }

    /// 清掉某作品的**磁盘**译文缓存（设置页「清理译文缓存」用）。
    ///
    /// 只动这一件的记录：内存与「已探过缓存」表里其他作品的条目必须留着，
    /// 否则清一次某个作品会把所有作品的命中判断都打回「未探过」，
    /// 白白多一轮磁盘探测。
    func purgeCache(for manga: Manga) {
        let sourceID = manga.sourceID
        let mangaURL = manga.url
        memory = memory.filter { !Self.belongs($0.key, toSource: sourceID, mangaURL: mangaURL) }
        memoryOrder.removeAll { Self.belongs($0, toSource: sourceID, mangaURL: mangaURL) }
        cacheProbe = cacheProbe.filter { !Self.belongs($0.key, toSource: sourceID, mangaURL: mangaURL) }
        store.removeAll(sourceID: sourceID, mangaURL: mangaURL)
    }

    private static func belongs(_ key: PageTranslationKey, toSource sourceID: SourceID, mangaURL: String) -> Bool {
        key.sourceID == sourceID && key.mangaURL == mangaURL
    }

    // MARK: - 入队

    private func enqueuePreloaded(manga: Manga, currentPage: Int, preloaded: [Int: PlatformImage]) {
        let window = settings.translationPrefetchWindow
        let lower = currentPage - window
        let upper = currentPage + window
        let pages = preloaded.keys
            .filter { $0 >= max(0, lower) && $0 <= upper }
            .sorted {
                abs($0 - currentPage) == abs($1 - currentPage)
                    ? $0 < $1
                    : abs($0 - currentPage) < abs($1 - currentPage)
            }
        for page in pages {
            guard let image = preloaded[page] else { continue }
            enqueue(manga: manga, page: page, image: image)
        }
        pump()
    }

    private func enqueue(manga: Manga, page: Int, image: PlatformImage) {
        let key = PageTranslationKey(manga: manga, page: page)
        if memory[key] != nil || cacheProbe[key] == true { return }
        if jobs[key] != nil || running.contains(key) { return }
        jobs[key] = Job(manga: manga, page: page, image: image)
        queue.append(key)
    }

    // MARK: - 队列调度

    private func pump() {
        while running.count < maxConcurrent, !queue.isEmpty {
            let key = queue.removeFirst()
            running.insert(key)
            tasks[key] = Task { [weak self] in
                await self?.process(key)
                self?.finish(key)
            }
        }
        pendingCount = queue.count + running.count
    }

    private func finish(_ key: PageTranslationKey) {
        running.remove(key)
        tasks[key] = nil
        jobs[key] = nil
        pendingCount = queue.count + running.count
        pump()
    }

    private func cancelPending() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        queue.removeAll()
        running.removeAll()
        jobs.removeAll()
        pendingCount = 0
    }

    private var maxConcurrent: Int {
        // 端上翻译框架一次只支持一个会话；现代 Vision 并行超过 2 会死锁。
        settings.translationBackend == .appleOnDevice ? 1 : 2
    }

    // MARK: - 单页流程

    private func process(_ key: PageTranslationKey) async {
        guard let job = jobs[key] else { return }
        do {
            guard let cgImage = MangaTypesetter.cgImage(of: job.image) else {
                throw TranslationError.imageUnavailable
            }
            try Task.checkCancellation()

            // OCR 放到后台线程：Vision 是 CPU 密集的，占住主线程会让翻页卡顿
            let recognizer = makeRecognizer(settings.sourceLanguage, settings.usesLineDropFallback)
            let lines: [MangaTextLine] = try await Task.detached(priority: .userInitiated) {
                try await recognizer.recognizeLines(in: cgImage)
            }.value
            try Task.checkCancellation()
            guard !lines.isEmpty else { throw TranslationError.noTextRecognized }

            let translations = try await translate(lines.map(\.text))
            guard translations.count == lines.count else {
                throw TranslationError.countMismatch(expected: lines.count, got: translations.count)
            }
            try Task.checkCancellation()

            let translatedLines = zip(lines, translations).map { line, text in
                MangaTranslatedLine(
                    source: line.text,
                    translated: text,
                    boundingBox: line.boundingBox,
                    isVertical: line.isVertical
                )
            }
            let options = MangaTypesetter.Options(
                useSampledBackground: settings.translationUsesSampledBackground,
                showOriginalText: settings.translationShowsOriginalText,
                fontScale: CGFloat(settings.fontScale)
            )
            let rendered = MangaTypesetter.render(original: job.image, lines: translatedLines, options: options)

            try Task.checkCancellation()
            store.store(image: rendered, lines: translatedLines, for: key)
            cacheProbe[key] = true
            putMemory(rendered, for: key)
            completedCount += 1
            if isActive { showsTranslation = true }
            diag("翻译: 完成 \(key.description) 行=\(lines.count)")
        } catch is CancellationError {
            // 用户关闭或翻页丢弃，静默
        } catch {
            handleFailure(error, key: key)
        }
    }

    private func translate(_ texts: [String]) async throws -> [String] {
        switch settings.translationBackend {
        case .appleOnDevice:
            return try await appleBridge.translate(
                texts,
                source: settings.sourceLanguage,
                target: settings.targetLanguage
            )
        case .bringYourOwnKey, .cloudService:
            guard let translator = resolver(settings.translationBackend) else {
                throw TranslationError.notSignedIn
            }
            return try await translator.translate(
                texts,
                source: settings.sourceLanguage,
                target: settings.targetLanguage
            )
        }
    }

    private func handleFailure(_ error: Error, key: PageTranslationKey) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let translationError = error as? TranslationError
        if translationError?.isQuotaRelated == true {
            // 额度问题单独呈现：界面给「升级云服务」入口，不打断阅读
            quotaMessage = message
        } else {
            failureMessage = message
            // 记成「没有缓存」，避免每帧都去磁盘探一次
            cacheProbe[key] = false
        }
        diag("翻译: 失败 \(key.description) —— \(message)")
    }

    // MARK: - 内存 LRU

    private func touchMemory(_ key: PageTranslationKey) {
        memoryOrder.removeAll { $0 == key }
        memoryOrder.append(key)
    }

    private func putMemory(_ image: PlatformImage, for key: PageTranslationKey) {
        memory[key] = image
        touchMemory(key)
        while memoryOrder.count > Self.memoryLimit, let oldest = memoryOrder.first {
            memoryOrder.removeFirst()
            memory.removeValue(forKey: oldest)
        }
    }
}
