//
//  SourceRunnerTests.swift
//  MangaTranslaterTests
//
//  `SourceRunner`（类型化门面）的测试。
//
//  两个层次：
//  1. **脚本化替身**：只验证门面自己的职责——参数编码、降级策略、
//     错误传播、丢弃项写日志。不牵涉 JavaScriptCore，因此可以断言
//     「脚本收到了什么参数」这种细节。
//  2. **端到端**：用真实的 `JSSourceRuntime` 跑 `docs/source-api.md` 里那份
//     canonical 示例源（与文档逐字一致），配 HTML 夹具。
//     这一步的价值是**证明文档里的示例真的能跑通**——示例用了
//     `net.get` / `html.parse` / `source.baseUrl`，任何一处桥接缺失都会在这里暴露。
//

import Testing
import Foundation
import AppCore
import ComicNet
@testable import SourceEngine

// MARK: - 脚本化替身

final class ScriptedSourceRuntime: SourceRuntimeExecuting, @unchecked Sendable {

    struct Call: Equatable {
        let method: SourceAPIMethod
        let arguments: [String]
    }

    private let lock = NSLock()
    private var responses: [SourceAPIMethod: Result<String, Error>] = [:]
    private var recorded: [Call] = []
    private var loadError: Error?
    private var callError: Error?
    private var loadCount = 0
    private var teardownCount = 0

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var loadTimes: Int {
        lock.lock()
        defer { lock.unlock() }
        return loadCount
    }

    var teardownTimes: Int {
        lock.lock()
        defer { lock.unlock() }
        return teardownCount
    }

    func stub(_ method: SourceAPIMethod, json: String) {
        lock.lock()
        responses[method] = .success(json)
        lock.unlock()
    }

    func stub(_ method: SourceAPIMethod, error: Error) {
        lock.lock()
        responses[method] = .failure(error)
        lock.unlock()
    }

    func failLoad(with error: Error) {
        lock.lock()
        loadError = error
        lock.unlock()
    }

    func failAllCalls(with error: Error) {
        lock.lock()
        callError = error
        lock.unlock()
    }

    // MARK: SourceRuntimeExecuting

    func load(script: String, meta: SourceScriptMeta) async throws {
        lock.lock()
        loadCount += 1
        let error = loadError
        lock.unlock()
        if let error { throw error }
    }

    func call(_ method: SourceAPIMethod, arguments: [String]) async throws -> String {
        lock.lock()
        recorded.append(Call(method: method, arguments: arguments))
        let generic = callError
        let result = responses[method]
        lock.unlock()

        if let generic { throw generic }
        switch result {
        case let .success(json):
            return json
        case let .failure(error):
            throw error
        case .none:
            throw SourceRunnerError.executionFailed("替身未配置 \(method.rawValue) 的返回值")
        }
    }

    func teardown() async {
        lock.lock()
        teardownCount += 1
        lock.unlock()
    }
}

// MARK: - 门面测试

/// 一个与源无关的错误类型，用于验证「外来错误会被包装」。
private struct ForeignRuntimeError: Error {}

@Suite("源执行门面")
struct SourceRunnerTests {

    /// 只用于**静态预检**（替身不执行脚本），但必须包含 5 个必需方法的声明。
    static let minimalScript = """
    const source = { id: "fake", name: "Fake", baseUrl: "https://fake.test" };

    function getPopularManga(page) { return { mangas: [], hasNextPage: false }; }
    function getSearchManga(page, query, filters) { return { mangas: [], hasNextPage: false }; }
    function getMangaDetails(url) { return { title: "T", url: url }; }
    function getChapterList(url) { return []; }
    function getPageList(url) { return []; }
    """

    /// 去掉可选方法 `getLatestUpdates`，用于验证回退到热门列表。
    static let scriptWithoutOptionalMethods = """
    const source = { id: "fake", name: "Fake" };

    function getPopularManga(page) { return { mangas: [], hasNextPage: false }; }
    function getSearchManga(page, query, filters) { return { mangas: [], hasNextPage: false }; }
    function getMangaDetails(url) { return { title: "T", url: url }; }
    function getChapterList(url) { return []; }
    function getPageList(url) { return []; }
    """

    /// 带 `getFilters` 的版本（可选方法存在时不走空数组降级）。
    static let scriptWithFilters = """
    const source = { id: "fake", name: "Fake" };

    function getPopularManga(page) { return { mangas: [], hasNextPage: false }; }
    function getSearchManga(page, query, filters) { return { mangas: [], hasNextPage: false }; }
    function getMangaDetails(url) { return { title: "T", url: url }; }
    function getChapterList(url) { return []; }
    function getPageList(url) { return []; }
    function getFilters() { return []; }
    """

    private func makeRunner(
        script: String = SourceRunnerTests.minimalScript,
        logs: LogCollector? = nil
    ) async throws -> (runner: SourceRunner, runtime: ScriptedSourceRuntime) {
        let runtime = ScriptedSourceRuntime()
        let runner = SourceRunner(
            runtime: runtime,
            meta: SourceScriptMeta(id: SourceID("fake"), name: "Fake", baseURL: "https://fake.test"),
            logSink: { level, message in logs?.append(level: level, message: message) }
        )
        try await runner.load(script: script)
        return (runner, runtime)
    }

    // MARK: 生命周期

    @Test("未载入时调用抛 notInstalled")
    func rejectsCallBeforeLoad() async throws {
        let runtime = ScriptedSourceRuntime()
        let runner = SourceRunner(
            runtime: runtime,
            meta: SourceScriptMeta(id: SourceID("fake"), name: "Fake")
        )
        do {
            _ = try await runner.popularManga()
            Issue.record("应当抛错")
        } catch let error as SourceRunnerError {
            guard case .notInstalled = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
        }
        #expect(runtime.calls.isEmpty)
    }

    @Test("载入失败时错误原样传播，且不标记为已载入")
    func propagatesLoadFailure() async throws {
        let runtime = ScriptedSourceRuntime()
        runtime.failLoad(with: SourceRunnerError.scriptRejected("太长了"))
        let runner = SourceRunner(
            runtime: runtime,
            meta: SourceScriptMeta(id: SourceID("fake"), name: "Fake")
        )
        do {
            try await runner.load(script: Self.minimalScript)
            Issue.record("应当抛错")
        } catch let error as SourceRunnerError {
            guard case .scriptRejected = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
        }
        let loaded = await runner.loaded
        #expect(loaded == false)
    }

    @Test("teardown 后调用抛 notInstalled 并释放运行时")
    func tearsDownRuntime() async throws {
        let (runner, runtime) = try await makeRunner()
        await runner.teardown()
        #expect(runtime.teardownTimes == 1)
        await expectThrowsAsync(SourceRunnerError.notInstalled("fake")) {
            _ = try await runner.popularManga()
        }
    }

    @Test("静态预检能识别脚本实现了哪些方法")
    func reportsImplementedMethods() async throws {
        let (runner, _) = try await makeRunner()
        let methods = await runner.implementedMethods
        #expect(methods.contains(.popularManga))
        #expect(methods.contains(.searchManga))
        #expect(methods.contains(.latestUpdates) == false)
        #expect(methods.contains(.filters) == false)

        let (withFilters, _) = try await makeRunner(script: Self.scriptWithFilters)
        let methodsWithFilters = await withFilters.implementedMethods
        #expect(methodsWithFilters.contains(.filters))
    }

    // MARK: 参数编码

    @Test("contract 参数按 JSON 片段传递（分页 / 字符串 / 对象）")
    func encodesArguments() async throws {
        let (runner, runtime) = try await makeRunner()
        runtime.stub(.popularManga, json: #"{"mangas":[],"hasNextPage":false}"#)
        runtime.stub(.searchManga, json: #"{"mangas":[],"hasNextPage":false}"#)

        _ = try await runner.popularManga()
        _ = try await runner.search(page: 3, query: "a\"b", filters: ["genre": "adventure"])

        let calls = runtime.calls
        #expect(calls.count == 2)
        // 页码是 JSON 数字字面量，而不是带引号的字符串
        #expect(calls[0].arguments == ["1"])
        // 查询串必须是**一层**编码：`"a\"b"` 而不是 `"\"a\\\"b\""`
        #expect(calls[1].arguments.count == 3)
        #expect(calls[1].arguments[0] == "3")
        #expect(calls[1].arguments[1] == #""a\"b""#)
        #expect(calls[1].arguments[2].contains("adventure"))
    }

    @Test("空筛选集合编码为 {}，页码下限为 1")
    func encodesEmptyArguments() async throws {
        let (runner, runtime) = try await makeRunner()
        runtime.stub(.searchManga, json: #"{"mangas":[],"hasNextPage":false}"#)
        _ = try await runner.search(page: 0, query: "", filters: [:])

        let calls = runtime.calls
        #expect(calls.first?.arguments == ["1", "\"\"", "{}"])
    }

    // MARK: 解码与降级

    @Test("热门列表解码为模型")
    func decodesPopularManga() async throws {
        let (runner, runtime) = try await makeRunner()
        runtime.stub(
            .popularManga,
            json: #"{"mangas":[{"title":"Alpha","url":"/m/1"}],"hasNextPage":true}"#
        )
        let page = try await runner.popularManga(page: 2)
        #expect(page.items.count == 1)
        #expect(page.hasNextPage)
        #expect(page.items.first?.url == "https://fake.test/m/1")
    }

    @Test("getLatestUpdates 缺失时回退到热门列表")
    func fallsBackToPopular() async throws {
        let logs = LogCollector()
        let (runner, runtime) = try await makeRunner(
            script: Self.scriptWithoutOptionalMethods,
            logs: logs
        )
        runtime.stub(.popularManga, json: #"{"mangas":[{"title":"A","url":"/m/1"}]}"#)

        let page = try await runner.latestUpdates()
        #expect(page.items.count == 1)
        // 关键断言：确实打到了 getPopularManga，而不是空手而归
        #expect(runtime.calls.map(\.method) == [.popularManga])
        #expect(logs.all.contains { $0.contains("回退到热门列表") })
    }

    @Test("getFilters 缺失时返回空数组且不调用脚本")
    func returnsEmptyFiltersWhenUnsupported() async throws {
        let (runner, runtime) = try await makeRunner(script: Self.scriptWithoutOptionalMethods)
        let filters = try await runner.filters()
        #expect(filters.isEmpty)
        #expect(runtime.calls.isEmpty)
    }

    @Test("getFilters 存在时正常解码")
    func decodesFilters() async throws {
        let (runner, runtime) = try await makeRunner(script: Self.scriptWithFilters)
        runtime.stub(
            .filters,
            json: #"[{"type":"text","key":"author","name":"作者"}]"#
        )
        let filters = try await runner.filters()
        #expect(filters.count == 1)
        #expect(filters.first?.key == "author")
        #expect(runtime.calls.map(\.method) == [.filters])
    }

    @Test("详情 / 章节 / 页面均能解码")
    func decodesDetailChapterAndPage() async throws {
        let (runner, runtime) = try await makeRunner()
        runtime.stub(
            .mangaDetails,
            json: #"{"title":"Alpha","url":"/m/1","status":"completed"}"#
        )
        runtime.stub(
            .chapterList,
            json: #"[{"name":"第 1 话","url":"/c/1","chapterNumber":1}]"#
        )
        runtime.stub(.pageList, json: #"["https://cdn.test/1.jpg"]"#)

        let manga = try await runner.mangaDetails(url: "https://fake.test/m/1")
        #expect(manga.title == "Alpha")
        #expect(manga.status == .completed)

        let chapters = try await runner.chapterList(mangaURL: manga.url)
        #expect(chapters.count == 1)
        // 省略 mangaID 时按 `<sourceID>|<url>` 派生，主键与书架条目一致
        #expect(chapters.first?.mangaID == "fake|https://fake.test/m/1")
        #expect(chapters.first?.id == "fake|https://fake.test/m/1|https://fake.test/c/1")

        let pages = try await runner.pageList(chapterURL: "https://fake.test/c/1")
        #expect(pages.count == 1)
        #expect(pages.first?.index == 0)
    }

    @Test("传入 mangaID 时章节主键跟随它")
    func respectsExplicitMangaID() async throws {
        let (runner, runtime) = try await makeRunner()
        runtime.stub(.chapterList, json: #"[{"url":"/c/1"}]"#)
        let chapters = try await runner.chapterList(mangaURL: "https://fake.test/m/1", mangaID: "自定义")
        #expect(chapters.first?.mangaID == "自定义")
    }

    @Test("条目被丢弃时写诊断日志")
    func logsSkippedItems() async throws {
        let logs = LogCollector()
        let (runner, runtime) = try await makeRunner(logs: logs)
        runtime.stub(
            .popularManga,
            json: #"{"mangas":[{"title":"A"},{"title":"B","url":"/m/2"}]}"#
        )
        let page = try await runner.popularManga()
        #expect(page.items.count == 1)
        #expect(logs.all.contains { $0.contains("1 条数据不完整") })
    }

    @Test("返回结构不合法时报 invalidResponse")
    func reportsInvalidResponse() async throws {
        let (runner, runtime) = try await makeRunner()
        runtime.stub(.popularManga, json: "这不是 JSON")
        do {
            _ = try await runner.popularManga()
            Issue.record("应当抛错")
        } catch let error as SourceRunnerError {
            guard case .invalidResponse = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
        }
    }

    @Test("运行时抛出的 SourceRunnerError 原样传播")
    func propagatesRuntimeErrors() async throws {
        let (runner, runtime) = try await makeRunner()
        runtime.stub(.popularManga, error: SourceRunnerError.executionTimeout(seconds: 10))
        await expectThrowsAsync(SourceRunnerError.executionTimeout(seconds: 10)) {
            _ = try await runner.popularManga()
        }
    }

    @Test("非 SourceRunnerError 被包装为 executionFailed")
    func wrapsForeignErrors() async throws {
        let (runner, runtime) = try await makeRunner()
        runtime.stub(.popularManga, error: ForeignRuntimeError())
        do {
            _ = try await runner.popularManga()
            Issue.record("应当抛错")
        } catch let error as SourceRunnerError {
            guard case .executionFailed = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
        }
    }
}

// MARK: - 端到端

@Suite("源端到端（契约示例源）")
struct SourceEndToEndTests {

    /// 一份「一个页面里塞下所有选择器」的夹具：示例源对不同方法使用不同选择器，
    /// 用同一份 HTML 就能驱动全部五个必需方法，省掉为每个方法各写一份夹具。
    static let pageHTML = """
    <html><body>
    <div class="item"><a class="title" href="/m/alpha">Alpha</a><img src="/covers/alpha.jpg"></div>
    <div class="item"><a class="title" href="/m/beta">Beta</a><img src="/covers/beta.jpg"></div>
    <a class="next" href="?page=2">下一页</a>
    <h1 class="title">Alpha 详情</h1>
    <span class="author">作者甲</span>
    <div class="summary">摘要文本</div>
    <span class="genre">冒险</span>
    <img class="cover" src="/covers/alpha.jpg">
    <ul class="chapters">
    <li data-date="2024-01-02T03:04:05Z"><a href="/c/1">第 1 话</a></li>
    <li><a href="/c/2">第 2 话</a></li>
    </ul>
    <div class="page"><img data-src="https://cdn.test/1.jpg"></div>
    <div class="page"><img data-src="https://cdn.test/2.jpg"></div>
    </body></html>
    """

    /// 端到端装备：真实 JS 运行时 + 可编程传输层。
    private func makeRunner() throws -> (runner: SourceRunner, transport: StubSourceTransport) {
        let transport = StubSourceTransport()
        let body = Self.pageHTML
        for url in [
            "https://example.com/popular?page=1",
            "https://example.com/latest?page=1",
            "https://example.com/search?q=alpha&page=1",
            "https://example.com/m/alpha",
            "https://example.com/c/1",
        ] {
            transport.setResponse(
                SourceHTTPResult(status: 200, headers: ["Content-Type": "text/html"], body: body),
                for: url
            )
        }

        let meta = try SourceScriptValidator.validate(SourceAPIDocTests.canonicalExample)
        let runtime = JSSourceRuntime(transport: transport)
        let runner = SourceRunner(runtime: runtime, meta: meta)
        return (runner, transport)
    }

    @Test("加载文档示例源：元信息与必需方法齐备")
    func loadsCanonicalExample() async throws {
        let (runner, _) = try makeRunner()
        try await runner.load(script: SourceAPIDocTests.canonicalExample)
        let methods = await runner.implementedMethods
        #expect(methods.count == SourceAPIMethod.allCases.count)
        let meta = await runner.sourceMeta
        #expect(meta.id == SourceID("demo"))
        #expect(meta.baseURL == "https://example.com")
        #expect(meta.rateLimitMilliseconds == 500)
    }

    @Test("热门列表：net.get + html.parse + 相对地址补全")
    func popularMangaEndToEnd() async throws {
        let (runner, transport) = try makeRunner()
        try await runner.load(script: SourceAPIDocTests.canonicalExample)

        let page = try await runner.popularManga(page: 1)
        #expect(page.items.count == 2)
        #expect(page.items.map(\.title) == ["Alpha", "Beta"])
        #expect(page.items.map(\.url) == [
            "https://example.com/m/alpha",
            "https://example.com/m/beta",
        ])
        #expect(page.items.first?.coverURL == "https://example.com/covers/alpha.jpg")
        #expect(page.hasNextPage)

        // 证明 `net.get(url, headers?)` 真的把请求发到了示例源拼出来的地址
        #expect(transport.calls.map(\.url).contains("https://example.com/popular?page=1"))
    }

    @Test("最新更新：走 getLatestUpdates 分支")
    func latestUpdatesEndToEnd() async throws {
        let (runner, transport) = try makeRunner()
        try await runner.load(script: SourceAPIDocTests.canonicalExample)

        let page = try await runner.latestUpdates(page: 1)
        #expect(page.items.count == 2)
        #expect(transport.calls.map(\.url).contains("https://example.com/latest?page=1"))
    }

    @Test("搜索：查询串被正确编码进地址")
    func searchEndToEnd() async throws {
        let (runner, transport) = try makeRunner()
        try await runner.load(script: SourceAPIDocTests.canonicalExample)

        let page = try await runner.search(page: 1, query: "alpha")
        #expect(page.items.count == 2)
        #expect(page.hasNextPage == false)
        #expect(transport.calls.map(\.url).contains("https://example.com/search?q=alpha&page=1"))
    }

    @Test("详情：标题 / 作者 / 摘要 / 题材 / 状态")
    func mangaDetailsEndToEnd() async throws {
        let (runner, _) = try makeRunner()
        try await runner.load(script: SourceAPIDocTests.canonicalExample)

        let manga = try await runner.mangaDetails(url: "https://example.com/m/alpha")
        #expect(manga.title == "Alpha 详情")
        #expect(manga.author == "作者甲")
        #expect(manga.summary == "摘要文本")
        #expect(manga.genres == ["冒险"])
        #expect(manga.status == .ongoing)
        #expect(manga.coverURL == "https://example.com/covers/alpha.jpg")
        #expect(manga.id == "demo|https://example.com/m/alpha")
    }

    @Test("章节列表：日期可解析、缺失日期为 nil")
    func chapterListEndToEnd() async throws {
        let (runner, _) = try makeRunner()
        try await runner.load(script: SourceAPIDocTests.canonicalExample)

        let chapters = try await runner.chapterList(mangaURL: "https://example.com/m/alpha")
        #expect(chapters.count == 2)
        #expect(chapters.map(\.name) == ["第 1 话", "第 2 话"])
        #expect(chapters.map(\.url) == [
            "https://example.com/c/1",
            "https://example.com/c/2",
        ])
        #expect(chapters[0].dateUploaded != nil)
        #expect(chapters[1].dateUploaded == nil)
        // 示例源固定返回 chapterNumber: 0
        #expect(chapters.allSatisfy { $0.chapterNumber == 0 })
    }

    @Test("页面列表：顺序即阅读顺序")
    func pageListEndToEnd() async throws {
        let (runner, _) = try makeRunner()
        try await runner.load(script: SourceAPIDocTests.canonicalExample)

        let pages = try await runner.pageList(chapterURL: "https://example.com/c/1")
        #expect(pages.map(\.imageURL) == [
            "https://cdn.test/1.jpg",
            "https://cdn.test/2.jpg",
        ])
        #expect(pages.map(\.index) == [0, 1])
    }

    @Test("筛选项：同步方法也能拿到结果")
    func filtersEndToEnd() async throws {
        let (runner, _) = try makeRunner()
        try await runner.load(script: SourceAPIDocTests.canonicalExample)

        let filters = try await runner.filters()
        #expect(filters.map(\.kind) == [.text, .select, .sort])
        #expect(filters.map(\.key) == ["author", "genre", "sort"])
        #expect(filters[1].options.count == 1)
    }

    @Test("teardown 后可重新载入同一来源")
    func reloadAfterTeardown() async throws {
        let (runner, _) = try makeRunner()
        try await runner.load(script: SourceAPIDocTests.canonicalExample)
        _ = try await runner.popularManga(page: 1)

        await runner.teardown()
        await expectThrowsAsync(SourceRunnerError.notInstalled("demo")) {
            _ = try await runner.popularManga(page: 1)
        }

        try await runner.load(script: SourceAPIDocTests.canonicalExample)
        let page = try await runner.popularManga(page: 1)
        #expect(page.items.count == 2)
    }
}
