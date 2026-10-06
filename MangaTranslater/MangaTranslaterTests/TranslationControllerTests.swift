//
//  TranslationControllerTests.swift
//  MangaTranslaterTests
//
//  翻译编排：开关、队列与预取窗口、进度、缓存命中不重复翻译、
//  失败与额度降级（额度问题不打断阅读）、退出重置。
//
//  OCR 与翻译后端都注入替身，因此这些用例跑得快、结果确定，
//  不依赖真实 Vision 或网络。
//

import Foundation
import Testing
import CoreGraphics
import UIKit
import AppCore
@testable import MangaTranslater

// MARK: - 替身

/// 固定输出的识别器。
private final class StubRecognizer: TextRecognizing, @unchecked Sendable {
    private let lines: [MangaTextLine]
    private let error: TranslationError?

    init(lines: [MangaTextLine], error: TranslationError? = nil) {
        self.lines = lines
        self.error = error
    }

    convenience init(lineCount: Int) {
        let lines = (0..<lineCount).map { index in
            MangaTextLine(
                text: "原文\(index)",
                boundingBox: CGRect(x: 0.1, y: 0.1 + Double(index) * 0.1, width: 0.3, height: 0.05),
                isVertical: false,
                confidence: 0.9
            )
        }
        self.init(lines: lines)
    }

    func recognizeLines(in cgImage: CGImage) async throws -> [MangaTextLine] {
        if let error { throw error }
        return lines
    }
}

/// 脚本化翻译后端。
private final class StubTranslator: MangaTranslator, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private let handler: @Sendable ([String]) throws -> [String]

    init(handler: @escaping @Sendable ([String]) throws -> [String]) {
        self.handler = handler
    }

    /// 把每条原文前面加上前缀，长度与顺序保持不变。
    convenience init(prefix: String = "译:") {
        self.init { texts in texts.map { prefix + $0 } }
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recorded.count
    }

    var lastTexts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded.last ?? []
    }

    func translate(
        _ texts: [String],
        source: TranslationLanguage,
        target: TranslationLanguage
    ) async throws -> [String] {
        lock.lock()
        recorded.append(texts)
        lock.unlock()
        return try handler(texts)
    }
}

// MARK: - 用例

@Suite("翻译编排")
@MainActor
struct TranslationControllerTests {

    private static let manga = Manga(
        sourceID: SourceID("demo"),
        url: "https://example.com/m/1",
        title: "Demo"
    )

    private static func makeSettings() throws -> (AppSettings, UserDefaults, String) {
        let suiteName = "TranslationControllerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (AppSettings(defaults: defaults), defaults, suiteName)
    }

    private static func makePage(seed: CGFloat = 0.4) -> UIImage {
        let context = CGContext(
            data: nil,
            width: 32,
            height: 48,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.setFillColor(CGColor(red: seed, green: seed, blue: seed, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: 32, height: 48))
        guard let cgImage = context?.makeImage() else { return UIImage() }
        return UIImage(cgImage: cgImage)
    }

    private static func preloaded(pages: ClosedRange<Int>, seed: CGFloat = 0.4) -> [Int: UIImage] {
        var result: [Int: UIImage] = [:]
        for page in pages { result[page] = makePage(seed: seed) }
        return result
    }

    private static func makeController(
        settings: AppSettings,
        recognizer: StubRecognizer,
        translator: StubTranslator,
        store: TranslationStore = TranslationStore(root: nil),
        backend: TranslationBackend = .bringYourOwnKey
    ) -> TranslationController {
        settings.translationBackend = backend
        return TranslationController(
            store: store,
            settings: settings,
            resolver: { _ in translator },
            makeRecognizer: { _, _ in recognizer }
        )
    }

    /// 等编排器把手头的活干完（含 finish() 的收尾）。
    ///
    /// 超时给得比较宽松（默认 10 秒）：这些用例本身是毫秒级的，
    /// 但测试进程里同时可能有真机 Vision 在跑（大图 OCR，CPU 密集），
    /// 协作线程池被抢占会让 `Task.detached` 就绪得慢一些。
    /// 超时太紧会把「机器忙」误判成「逻辑错」——那种红灯最难查。
    private static func settle(_ controller: TranslationController, timeout: TimeInterval = 10) async {
        let deadline = Date().addingTimeInterval(timeout)
        while controller.isBusy, Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }

    // MARK: 开关

    @Test("点一下开启连续翻译并立即出译文")
    func toggleEnablesTranslation() async throws {
        let (settings, defaults, suite) = try Self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = Self.makeController(
            settings: settings,
            recognizer: StubRecognizer(lineCount: 2),
            translator: StubTranslator()
        )

        #expect(!controller.isActive)
        #expect(!controller.showsTranslation)

        controller.toggle(manga: Self.manga, currentPage: 0, preloaded: Self.preloaded(pages: 0...0))
        #expect(controller.isActive)
        #expect(controller.showsTranslation)
        #expect(controller.isBusy)

        await Self.settle(controller)
        #expect(!controller.isBusy)
        #expect(controller.completedCount == 1)
        #expect(controller.hasTranslation(for: Self.manga, page: 0))
        #expect(controller.failureMessage == nil)
    }

    @Test("再点一下显示原文并停止在跑的翻译")
    func toggleOffShowsOriginal() async throws {
        let (settings, defaults, suite) = try Self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = Self.makeController(
            settings: settings,
            recognizer: StubRecognizer(lineCount: 1),
            translator: StubTranslator()
        )

        controller.toggle(manga: Self.manga, currentPage: 0, preloaded: Self.preloaded(pages: 0...3))
        controller.toggle(manga: Self.manga, currentPage: 0, preloaded: Self.preloaded(pages: 0...3))

        #expect(!controller.isActive)
        #expect(!controller.showsTranslation)
        #expect(!controller.isBusy)
    }

    // MARK: 展示

    @Test("未开启翻译时展示原图")
    func displayReturnsOriginalWhenInactive() throws {
        let (settings, defaults, suite) = try Self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = Self.makeController(
            settings: settings,
            recognizer: StubRecognizer(lineCount: 1),
            translator: StubTranslator()
        )
        let original = Self.makePage(seed: 0.1)
        let shown = controller.displayImage(for: Self.manga, page: 0, original: original)
        #expect(shown === original)
    }

    @Test("译文图与原图尺寸一致")
    func translatedImageKeepsSize() async throws {
        let (settings, defaults, suite) = try Self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = Self.makeController(
            settings: settings,
            recognizer: StubRecognizer(lineCount: 2),
            translator: StubTranslator()
        )
        let original = Self.makePage()
        controller.toggle(manga: Self.manga, currentPage: 0, preloaded: [0: original])
        await Self.settle(controller)

        let shown = try #require(controller.displayImage(for: Self.manga, page: 0, original: original))
        #expect(shown.size == original.size)
    }

    // MARK: 预取窗口

    @Test("只翻译预取窗口内的页")
    func prefetchWindowLimitsQueue() async throws {
        let (settings, defaults, suite) = try Self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.translationPrefetchWindow = 1

        let translator = StubTranslator()
        let controller = Self.makeController(
            settings: settings,
            recognizer: StubRecognizer(lineCount: 1),
            translator: translator
        )
        // 当前页 2，窗口 ±1 → 只该翻译 1/2/3（即便已加载 0…5）
        controller.toggle(manga: Self.manga, currentPage: 2, preloaded: Self.preloaded(pages: 0...5))
        await Self.settle(controller)

        #expect(translator.callCount == 3)
        #expect(controller.completedCount == 3)
        #expect(controller.hasTranslation(for: Self.manga, page: 0) == false)
        #expect(controller.hasTranslation(for: Self.manga, page: 5) == false)
    }

    @Test("预取窗口为 0 时只翻译当前页")
    func zeroPrefetchWindowTranslatesCurrentPageOnly() async throws {
        let (settings, defaults, suite) = try Self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.translationPrefetchWindow = 0

        let translator = StubTranslator()
        let controller = Self.makeController(
            settings: settings,
            recognizer: StubRecognizer(lineCount: 1),
            translator: translator
        )
        controller.toggle(manga: Self.manga, currentPage: 3, preloaded: Self.preloaded(pages: 0...6))
        await Self.settle(controller)

        #expect(translator.callCount == 1)
        #expect(controller.hasTranslation(for: Self.manga, page: 3))
    }

    @Test("翻页会补队列，且丢掉已翻过去的页")
    func pageChangeRefillsQueue() async throws {
        let (settings, defaults, suite) = try Self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.translationPrefetchWindow = 1

        let translator = StubTranslator()
        let controller = Self.makeController(
            settings: settings,
            recognizer: StubRecognizer(lineCount: 1),
            translator: translator
        )
        controller.toggle(manga: Self.manga, currentPage: 0, preloaded: Self.preloaded(pages: 0...2))
        await Self.settle(controller)

        // 翻到第 3 页：窗口变成 2/3/4
        controller.onVisiblePageChanged(manga: Self.manga, currentPage: 3, preloaded: Self.preloaded(pages: 2...4))
        await Self.settle(controller)

        #expect(controller.hasTranslation(for: Self.manga, page: 3))
        #expect(controller.hasTranslation(for: Self.manga, page: 4))
        #expect(controller.completedCount == 5)
    }

    @Test("未开启时翻页不会触发翻译")
    func pageChangeWithoutToggleDoesNothing() async throws {
        let (settings, defaults, suite) = try Self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let translator = StubTranslator()
        let controller = Self.makeController(
            settings: settings,
            recognizer: StubRecognizer(lineCount: 1),
            translator: translator
        )
        controller.onVisiblePageChanged(manga: Self.manga, currentPage: 1, preloaded: Self.preloaded(pages: 0...2))
        await Self.settle(controller)
        #expect(translator.callCount == 0)
        #expect(!controller.isBusy)
    }

    // MARK: 缓存

    @Test("已缓存的页不会重复翻译")
    func cachedPageIsNotTranslatedTwice() async throws {
        let (settings, defaults, suite) = try Self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let translator = StubTranslator()
        let controller = Self.makeController(
            settings: settings,
            recognizer: StubRecognizer(lineCount: 1),
            translator: translator
        )

        controller.toggle(manga: Self.manga, currentPage: 0, preloaded: Self.preloaded(pages: 0...0))
        await Self.settle(controller)
        #expect(translator.callCount == 1)

        // 关掉再开：这一页已在缓存里，不该再花一次额度
        controller.toggle(manga: Self.manga, currentPage: 0, preloaded: Self.preloaded(pages: 0...0))
        controller.toggle(manga: Self.manga, currentPage: 0, preloaded: Self.preloaded(pages: 0...0))
        await Self.settle(controller)

        #expect(translator.callCount == 1)
    }

    @Test("落盘缓存跨实例复用")
    func diskCacheIsReusedByNewController() async throws {
        let (settings, defaults, suite) = try Self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let firstTranslator = StubTranslator()
        let first = Self.makeController(
            settings: settings,
            recognizer: StubRecognizer(lineCount: 1),
            translator: firstTranslator,
            store: TranslationStore(root: root)
        )
        first.toggle(manga: Self.manga, currentPage: 0, preloaded: Self.preloaded(pages: 0...0))
        await Self.settle(first)
        #expect(firstTranslator.callCount == 1)

        // 新会话（新实例、新内存缓存）：这一页应当从磁盘命中
        let secondTranslator = StubTranslator()
        let second = Self.makeController(
            settings: settings,
            recognizer: StubRecognizer(lineCount: 1),
            translator: secondTranslator,
            store: TranslationStore(root: root)
        )
        #expect(second.hasTranslation(for: Self.manga, page: 0))

        second.toggle(manga: Self.manga, currentPage: 0, preloaded: Self.preloaded(pages: 0...0))
        await Self.settle(second)
        #expect(secondTranslator.callCount == 0)
    }

    // MARK: 失败与降级

    @Test("译文条数不匹配 → 横幅提示且不写缓存")
    func countMismatchShowsFailure() async throws {
        let (settings, defaults, suite) = try Self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let translator = StubTranslator(handler: { _ in ["只有一条"] })
        let controller = Self.makeController(
            settings: settings,
            recognizer: StubRecognizer(lineCount: 3),
            translator: translator
        )
        controller.toggle(manga: Self.manga, currentPage: 0, preloaded: Self.preloaded(pages: 0...0))
        await Self.settle(controller)

        #expect(controller.failureMessage != nil)
        #expect(!controller.hasTranslation(for: Self.manga, page: 0))
        #expect(controller.isActive)   // 失败不该关掉翻译模式
    }

    @Test("识别不到文字 → 横幅提示")
    func emptyRecognitionShowsFailure() async throws {
        let (settings, defaults, suite) = try Self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = Self.makeController(
            settings: settings,
            recognizer: StubRecognizer(lines: []),
            translator: StubTranslator()
        )
        controller.toggle(manga: Self.manga, currentPage: 0, preloaded: Self.preloaded(pages: 0...0))
        await Self.settle(controller)
        #expect(controller.failureMessage != nil)
        #expect(controller.completedCount == 0)
    }

    @Test("额度用尽 → 走升级提示而不是失败横幅，且不打断阅读")
    func quotaErrorShowsUpgradeNotice() async throws {
        let (settings, defaults, suite) = try Self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let translator = StubTranslator(handler: { _ in throw TranslationError.quotaExceeded(remaining: 0) })
        let controller = Self.makeController(
            settings: settings,
            recognizer: StubRecognizer(lineCount: 1),
            translator: translator,
            backend: .cloudService
        )
        controller.toggle(manga: Self.manga, currentPage: 0, preloaded: Self.preloaded(pages: 0...0))
        await Self.settle(controller)

        #expect(controller.quotaMessage != nil)
        #expect(controller.failureMessage == nil)
        #expect(controller.isActive)
        #expect(controller.showsTranslation)

        controller.dismissQuotaNotice()
        #expect(controller.quotaMessage == nil)
    }

    @Test("云服务未登录 → 普通失败提示")
    func cloudWithoutTranslatorFails() async throws {
        let (settings, defaults, suite) = try Self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.translationBackend = .cloudService
        let controller = TranslationController(
            store: TranslationStore(root: nil),
            settings: settings,
            resolver: { _ in nil },
            makeRecognizer: { _, _ in StubRecognizer(lineCount: 1) }
        )
        controller.toggle(manga: Self.manga, currentPage: 0, preloaded: Self.preloaded(pages: 0...0))
        await Self.settle(controller)

        #expect(controller.failureMessage != nil)
        #expect(controller.quotaMessage == nil)
    }

    @Test("失败横幅可以点掉")
    func failureMessageIsDismissible() async throws {
        let (settings, defaults, suite) = try Self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let translator = StubTranslator(handler: { _ in throw TranslationError.emptyResponse })
        let controller = Self.makeController(
            settings: settings,
            recognizer: StubRecognizer(lineCount: 1),
            translator: translator
        )
        controller.toggle(manga: Self.manga, currentPage: 0, preloaded: Self.preloaded(pages: 0...0))
        await Self.settle(controller)
        #expect(controller.failureMessage != nil)
        controller.dismissFailure()
        #expect(controller.failureMessage == nil)
    }

    // MARK: 退出与清理

    @Test("退出阅读器会取消在跑的任务并复位状态")
    func stopAndResetClearsState() async throws {
        let (settings, defaults, suite) = try Self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = Self.makeController(
            settings: settings,
            recognizer: StubRecognizer(lineCount: 1),
            translator: StubTranslator()
        )
        controller.toggle(manga: Self.manga, currentPage: 0, preloaded: Self.preloaded(pages: 0...2))
        controller.stopAndReset()

        #expect(!controller.isActive)
        #expect(!controller.showsTranslation)
        #expect(!controller.isBusy)
        #expect(controller.completedCount == 0)
        #expect(controller.failureMessage == nil)
        #expect(controller.quotaMessage == nil)
    }

    @Test("清理某作品的译文缓存只影响该作品")
    func purgeCacheOnlyTouchesTargetManga() async throws {
        let (settings, defaults, suite) = try Self.makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        // 两个作品分别由**两个会话**翻译（`toggle` 是开关：同一个会话里再点一次
        // 是「显示原文」，不是「开始翻译另一个作品」）。
        let store = TranslationStore(root: root)
        let other = Manga(sourceID: SourceID("demo"), url: "https://example.com/m/2", title: "Other")

        let first = Self.makeController(
            settings: settings,
            recognizer: StubRecognizer(lineCount: 1),
            translator: StubTranslator(),
            store: store
        )
        first.toggle(manga: Self.manga, currentPage: 0, preloaded: Self.preloaded(pages: 0...0))
        await Self.settle(first)

        let second = Self.makeController(
            settings: settings,
            recognizer: StubRecognizer(lineCount: 1),
            translator: StubTranslator(),
            store: store
        )
        second.toggle(manga: other, currentPage: 0, preloaded: Self.preloaded(pages: 0...0, seed: 0.7))
        await Self.settle(second)
        #expect(second.completedCount == 1)

        #expect(second.hasTranslation(for: Self.manga, page: 0))
        second.purgeCache(for: Self.manga)
        #expect(!second.hasTranslation(for: Self.manga, page: 0))
        #expect(second.hasTranslation(for: other, page: 0))
    }
}
