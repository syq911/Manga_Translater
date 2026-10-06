//
//  SourceRuntimePoolTests.swift
//  MangaTranslaterTests
//
//  运行时池：载入一次、复用、single-flight、LRU 淘汰、租约保护、失效重载。
//
//  为什么这些用例值钱：池的行为错了不会立刻报错，而是表现为
//  「偶尔调用失败」「内存涨上去下不来」「同一个源状态莫名重置」——
//  全是难查的问题。这里用替身运行时把每种时序都摆出来验证。
//

import Testing
import Foundation
import AppCore
@testable import SourceEngine

// MARK: - 替身运行时

/// 可观测的假运行时：记录 load / teardown 次数，可注入延迟与错误。
final class FakeRuntime: SourceRuntimeExecuting, @unchecked Sendable {

    private let lock = NSLock()
    private var loadCount = 0
    private var teardownCount = 0
    private var callCount = 0
    private let delayNanoseconds: UInt64
    private let loadError: Error?

    init(delayNanoseconds: UInt64 = 0, loadError: Error? = nil) {
        self.delayNanoseconds = delayNanoseconds
        self.loadError = loadError
    }

    var loads: Int {
        lock.lock()
        defer { lock.unlock() }
        return loadCount
    }

    var teardowns: Int {
        lock.lock()
        defer { lock.unlock() }
        return teardownCount
    }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCount
    }

    func load(script: String, meta: SourceScriptMeta) async throws {
        lock.lock()
        loadCount += 1
        let error = loadError
        lock.unlock()
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if let error { throw error }
    }

    func call(_ method: SourceAPIMethod, arguments: [String]) async throws -> String {
        lock.lock()
        callCount += 1
        lock.unlock()
        return #"{"mangas":[],"hasNextPage":false}"#
    }

    func teardown() async {
        lock.lock()
        teardownCount += 1
        lock.unlock()
    }
}

/// 记录工厂建过的每一个运行时。
final class FakeRuntimeFactory: @unchecked Sendable {

    private let lock = NSLock()
    private var created: [FakeRuntime] = []
    private let delayNanoseconds: UInt64
    private let loadError: Error?

    init(delayNanoseconds: UInt64 = 0, loadError: Error? = nil) {
        self.delayNanoseconds = delayNanoseconds
        self.loadError = loadError
    }

    var instances: [FakeRuntime] {
        lock.lock()
        defer { lock.unlock() }
        return created
    }

    var count: Int { instances.count }

    func make() -> FakeRuntime {
        lock.lock()
        defer { lock.unlock() }
        let runtime = FakeRuntime(delayNanoseconds: delayNanoseconds, loadError: loadError)
        created.append(runtime)
        return runtime
    }
}

// MARK: - 测试

@Suite("源运行时池")
struct SourceRuntimePoolTests {

    /// 通过静态校验、实现全部必需方法的脚本（`id` 必须与要装的 key 一致）。
    static func script(id: String) -> String {
        """
        const source = { id: "\(id)", name: "源 \(id)", lang: "all", version: "1.0.0" };

        function getPopularManga(page) { return { mangas: [], hasNextPage: false }; }
        function getSearchManga(page, query, filters) { return { mangas: [], hasNextPage: false }; }
        function getMangaDetails(url) { return { title: "T", url: url }; }
        function getChapterList(url) { return []; }
        function getPageList(url) { return []; }
        """
    }

    private func makeStore(root: URL, keys: [String]) throws -> SourceStore {
        let store = SourceStore(rootDirectory: root)
        for key in keys {
            try store.install(script: Self.script(id: key))
        }
        return store
    }

    private func makePool(
        store: SourceStore,
        factory: FakeRuntimeFactory,
        maxLoadedSources: Int = 3,
        logs: LogCollector? = nil
    ) -> SourceRuntimePool {
        SourceRuntimePool(
            store: store,
            configuration: SourceRuntimePool.Configuration(maxLoadedSources: maxLoadedSources),
            logSink: { level, message in logs?.append(level: level, message: message) },
            makeRuntime: { _ in factory.make() }
        )
    }

    // MARK: 载入与复用

    @Test("首次取用时载入，之后复用同一个运行时")
    func loadsOnceAndReuses() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let store = try makeStore(root: root, keys: ["alpha"])
        let factory = FakeRuntimeFactory()
        let pool = makePool(store: store, factory: factory)

        let first = try await pool.runner(for: "alpha")
        let second = try await pool.runner(for: "alpha")
        _ = try await first.popularManga()
        _ = try await second.popularManga()

        #expect(factory.count == 1)
        #expect(factory.instances[0].loads == 1)
        #expect(factory.instances[0].calls == 2)
        let keys = await pool.loadedKeys
        #expect(keys == ["alpha"])
    }

    @Test("并发取同一个源只载入一次（single-flight）")
    func loadsOnceUnderConcurrency() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let store = try makeStore(root: root, keys: ["alpha"])
        // 让载入慢一点，制造出「多个调用同时进来」的窗口
        let factory = FakeRuntimeFactory(delayNanoseconds: 60_000_000)
        let pool = makePool(store: store, factory: factory)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    _ = try? await pool.runner(for: "alpha")
                }
            }
        }

        #expect(factory.count == 1)
        #expect(factory.instances[0].loads == 1)
    }

    @Test("未安装的源报 notInstalled，不创建运行时")
    func reportsMissingSource() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let store = try makeStore(root: root, keys: [])
        let factory = FakeRuntimeFactory()
        let pool = makePool(store: store, factory: factory)

        await expectThrowsAsync(SourceRunnerError.notInstalled("nope")) {
            _ = try await pool.runner(for: "nope")
        }
        await expectThrowsAsync(SourceRunnerError.notInstalled("../etc/passwd")) {
            _ = try await pool.runner(for: "../etc/passwd")
        }
        #expect(factory.count == 0)
    }

    @Test("脚本缺必需方法时报 incompleteContract，且不建运行时")
    func reportsBrokenScript() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        // 直接写一个缺必需方法的脚本文件（绕过 install 的校验）
        let store = SourceStore(rootDirectory: root)
        try FileManager.default.createDirectory(at: store.sourcesDirectory, withIntermediateDirectories: true)
        let broken = "const source = { id: \"broken\", name: \"B\" };"
        try Data(broken.utf8).write(to: store.scriptURL(for: "broken"))

        let factory = FakeRuntimeFactory()
        let pool = makePool(store: store, factory: factory)
        do {
            _ = try await pool.runner(for: "broken")
            Issue.record("应当抛错")
        } catch let error as SourceRunnerError {
            guard case let .incompleteContract(missing) = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
            #expect(missing.count == 5)
            #expect(missing.contains("getPopularManga"))
        }
        // 契约预检在建运行时之前，因此一个虚拟机都不该被创建
        #expect(factory.count == 0)
    }

    @Test("载入失败后不会留下半成品，下次取用会重新尝试")
    func recoversFromLoadFailure() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let store = try makeStore(root: root, keys: ["alpha"])
        let factory = FakeRuntimeFactory(loadError: SourceRunnerError.executionFailed("虚拟机起不来"))
        let pool = makePool(store: store, factory: factory)

        await expectThrowsAsync(SourceRunnerError.executionFailed("虚拟机起不来")) {
            _ = try await pool.runner(for: "alpha")
        }
        let loaded = await pool.isLoaded("alpha")
        #expect(loaded == false)

        // 第二次仍然会尝试载入（而不是把失败缓存下来）
        await expectThrowsAsync(SourceRunnerError.executionFailed("虚拟机起不来")) {
            _ = try await pool.runner(for: "alpha")
        }
        #expect(factory.count == 2)
    }

    // MARK: 淘汰

    @Test("超过上限时淘汰最久未使用的源")
    func evictsLeastRecentlyUsed() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let store = try makeStore(root: root, keys: ["alpha", "beta", "gamma"])
        let factory = FakeRuntimeFactory()
        let pool = makePool(store: store, factory: factory, maxLoadedSources: 2)

        // 用 withRunner：租约在闭包结束时归还，否则源会一直「在用」而不被淘汰
        try await pool.withRunner(for: "alpha") { _ in }
        try await pool.withRunner(for: "beta") { _ in }
        // 再用一次 alpha，让它变成「最近使用」→ 下一个被淘汰的应是 beta
        try await pool.withRunner(for: "alpha") { _ in }
        try await pool.withRunner(for: "gamma") { _ in }

        let keys = await pool.loadedKeys
        #expect(keys == ["alpha", "gamma"])
        #expect(factory.instances.count == 3)
        // 只有 beta 被回收过
        #expect(factory.instances.map(\.teardowns).reduce(0, +) == 1)
        let betaLoaded = await pool.isLoaded("beta")
        #expect(betaLoaded == false)
    }

    @Test("有租约的源不会被淘汰（宁可临时超限）")
    func protectsLeasedSources() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let store = try makeStore(root: root, keys: ["alpha", "beta", "gamma"])
        let factory = FakeRuntimeFactory()
        let logs = LogCollector()
        let pool = makePool(store: store, factory: factory, maxLoadedSources: 1, logs: logs)

        try await pool.withRunner(for: "alpha") { runner in
            // 租约期间再取两个源：alpha 不能被淘汰，池子临时超限
            _ = try await pool.runner(for: "beta")
            _ = try await pool.runner(for: "gamma")
            _ = try await runner.popularManga()
        }

        let keys = await pool.loadedKeys
        #expect(keys.contains("alpha"))
        #expect(keys.count == 3)
        // alpha 全程只建了一个运行时，说明它没有在使用中被回收重建
        #expect(factory.instances.count == 3)
        // 超限但不淘汰这件事本身要留痕，否则线上只会看到「内存莫名偏高」
        #expect(logs.all.contains { $0.contains("都在使用中") })
    }

    @Test("租约释放后恢复可淘汰")
    func releasesLeaseAfterUse() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let store = try makeStore(root: root, keys: ["alpha", "beta"])
        let factory = FakeRuntimeFactory()
        let pool = makePool(store: store, factory: factory, maxLoadedSources: 1)

        try await pool.withRunner(for: "alpha") { _ in
            #expect(factory.count == 1)
        }
        _ = try await pool.runner(for: "beta")

        let keys = await pool.loadedKeys
        #expect(keys == ["beta"])
        #expect(factory.instances[0].teardowns == 1)
    }

    // MARK: 失效与重载

    @Test("invalidate 后重新载入")
    func reloadsAfterInvalidate() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let store = try makeStore(root: root, keys: ["alpha"])
        let factory = FakeRuntimeFactory()
        let pool = makePool(store: store, factory: factory)

        _ = try await pool.runner(for: "alpha")
        await pool.invalidate("alpha")
        #expect(factory.instances[0].teardowns == 1)

        _ = try await pool.runner(for: "alpha")
        #expect(factory.count == 2)
    }

    @Test("卸载后取用报 notInstalled")
    func reportsAfterUninstall() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let store = try makeStore(root: root, keys: ["alpha"])
        let factory = FakeRuntimeFactory()
        let pool = makePool(store: store, factory: factory)

        _ = try await pool.runner(for: "alpha")
        _ = try store.uninstall(key: "alpha")
        await pool.invalidate("alpha")

        await expectThrowsAsync(SourceRunnerError.notInstalled("alpha")) {
            _ = try await pool.runner(for: "alpha")
        }
    }

    @Test("invalidateAll 释放全部运行时")
    func invalidatesEverything() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let store = try makeStore(root: root, keys: ["alpha", "beta"])
        let factory = FakeRuntimeFactory()
        let pool = makePool(store: store, factory: factory)

        _ = try await pool.runner(for: "alpha")
        _ = try await pool.runner(for: "beta")
        await pool.invalidateAll()

        let keys = await pool.loadedKeys
        #expect(keys.isEmpty)
        #expect(factory.instances.map(\.teardowns) == [1, 1])
    }

    @Test("可以读到已驻留源的元信息")
    func exposesLoadedMeta() async throws {
        let root = try TestFileSystem.makeTemporaryDirectory()
        defer { TestFileSystem.remove(root) }

        let store = try makeStore(root: root, keys: ["alpha"])
        let factory = FakeRuntimeFactory()
        let pool = makePool(store: store, factory: factory)

        _ = try await pool.runner(for: "alpha")
        let meta = await pool.loadedMeta("alpha")
        #expect(meta?.id == SourceID("alpha"))
        #expect(meta?.name == "源 alpha")
        let beforeLoad = await pool.loadedMeta("beta")
        #expect(beforeLoad == nil)
    }
}

// MARK: - 可见性规则

@Suite("源可见性")
struct SourceVisibilityRuleTests {

    private func source(_ key: String, nsfw: Bool) -> InstalledSource {
        InstalledSource(
            key: key,
            name: "源 \(key)",
            version: "1.0.0",
            language: "all",
            isNSFW: nsfw,
            installedAt: Date(timeIntervalSince1970: 0),
            byteCount: 100
        )
    }

    @Test("未开启 NSFW 时隐藏成人内容源，且不隐藏其他源")
    func hidesNSFWWhenDisabled() {
        let sources = [source("a", nsfw: false), source("b", nsfw: true), source("c", nsfw: false)]
        let visible = SourceVisibilityRule.visible(sources, showsNSFWSources: false)
        #expect(visible.map(\.key) == ["a", "c"])

        let hidden = SourceVisibilityRule.hidden(sources, showsNSFWSources: false)
        #expect(hidden.map(\.key) == ["b"])
        #expect(SourceVisibilityRule.hiddenReason(hidden[0], showsNSFWSources: false) != nil)
    }

    @Test("开启 NSFW 后全部可见")
    func showsEverythingWhenEnabled() {
        let sources = [source("a", nsfw: false), source("b", nsfw: true)]
        let visible = SourceVisibilityRule.visible(sources, showsNSFWSources: true)
        #expect(visible.map(\.key) == ["a", "b"])
        #expect(SourceVisibilityRule.hidden(sources, showsNSFWSources: true).isEmpty)
        #expect(SourceVisibilityRule.hiddenReason(sources[1], showsNSFWSources: true) == nil)
    }
}
