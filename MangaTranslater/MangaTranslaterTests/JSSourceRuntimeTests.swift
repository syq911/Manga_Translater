//
//  JSSourceRuntimeTests.swift
//  MangaTranslaterTests
//
//  JavaScriptCore 源运行时测试。
//
//  测试策略：JS 脚本夹具**内联**在文件里（测试跑在模拟器里读不到仓库目录），
//  网络用一个可编程的替身（`StubSourceTransport`），因此全部用例不依赖真实网络、
//  可重复、可并行。
//
//  覆盖：装载校验、契约方法调用、net/cookies/prefs/log 四个桥接、
//  错误传播、超时、teardown、沙箱隔离、参数校验。
//

import Testing
import Foundation
import AppCore
import ComicNet
@testable import SourceEngine

// MARK: - 网络替身

final class StubSourceTransport: SourceTransporting, @unchecked Sendable {

    struct Call: Equatable {
        let url: String
        let method: String
        let headers: [String: String]
        let body: String?
        let sourceID: String
    }

    private let lock = NSLock()
    private var recordedCalls: [Call] = []
    private var routes: [String: SourceHTTPResult] = [:]
    private var failure: Error?
    private var cookieStorage: [String: [String: String]] = [:]
    private var delayNanoseconds: UInt64 = 0

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls
    }

    func setResponse(_ result: SourceHTTPResult, for url: String) {
        lock.lock()
        routes[url] = result
        lock.unlock()
    }

    func setFailure(_ error: Error?) {
        lock.lock()
        failure = error
        lock.unlock()
    }

    func setDelay(nanoseconds: UInt64) {
        lock.lock()
        delayNanoseconds = nanoseconds
        lock.unlock()
    }

    /// 预置 Cookie（模拟已登录）。
    func seedCookies(_ cookies: [String: String], for url: String) {
        lock.lock()
        cookieStorage[url] = cookies
        lock.unlock()
    }

    // MARK: SourceTransporting

    func send(
        _ request: SourceHTTPRequest,
        sourceID: SourceID,
        rateLimitMilliseconds: Int
    ) async throws -> SourceHTTPResult {
        lock.lock()
        recordedCalls.append(
            Call(
                url: request.url,
                method: request.method,
                headers: request.headers,
                body: request.body,
                sourceID: sourceID.rawValue
            )
        )
        let failure = self.failure
        let delay = delayNanoseconds
        let route = routes[request.url]
        lock.unlock()

        if delay > 0 {
            try await Task.sleep(nanoseconds: delay)
        }
        if let failure { throw failure }
        guard let route else {
            throw SourceTransportError.notFound(request.url)
        }
        return route
    }

    func cookieHeader(for url: String, sourceID: SourceID) async -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let cookies = cookieStorage[url], !cookies.isEmpty else { return nil }
        return cookies.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "; ")
    }

    func cookies(for url: String, sourceID: SourceID) -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return cookieStorage[url] ?? [:]
    }

    func storeCookies(_ cookies: [String: String], for url: String, sourceID: SourceID) async {
        lock.lock()
        var existing = cookieStorage[url] ?? [:]
        for (key, value) in cookies { existing[key] = value }
        cookieStorage[url] = existing
        lock.unlock()
    }

    func clearCookies(sourceID: SourceID) async {
        lock.lock()
        cookieStorage.removeAll()
        lock.unlock()
    }
}

/// 线程安全的日志收集。
final class LogCollector: @unchecked Sendable {
    private var entries: [(level: String, message: String)] = []
    private let lock = NSLock()

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries.map { "\($0.level)|\($0.message)" }
    }

    func append(level: String, message: String) {
        lock.lock()
        entries.append((level, message))
        lock.unlock()
    }
}

// MARK: - 测试

@Suite("JS 源运行时")
struct JSSourceRuntimeTests {

    /// 一个不依赖 HTML 的完整源：用 net 取 JSON、用 prefs/cookies/log。
    static let demoScript = """
    const source = {
        id: "demo",
        name: "Demo Source",
        baseUrl: "https://example.com",
        lang: "all"
    };

    async function getPopularManga(page) {
        const res = await net.fetch("https://example.com/popular?page=" + page);
        const items = JSON.parse(res.body);
        return {
            mangas: items.map(function (item) {
                return { title: item.title, url: "/m/" + item.id };
            }),
            hasNextPage: items.length > 0
        };
    }

    async function getSearchManga(query, page, filters) {
        const res = await net.fetch("https://example.com/search", {
            method: "POST",
            headers: { "X-Token": "abc", "X-Page": String(page) },
            body: JSON.stringify({ q: query })
        });
        const cookieToken = cookies.get("https://example.com/search", "token");
        log.info("search done, cookie=" + cookieToken);
        return { mangas: [], hasNextPage: false, echo: res.body, cookie: cookieToken };
    }

    async function getMangaDetails(url) {
        return { title: prefs.get("titlePrefix", "T:") + url, url: url };
    }

    async function getChapterList(url) {
        return [];
    }

    async function getPageList(url) {
        return [];
    }
    """

    static let fixturePayload = #"""
    [{"id": 1, "title": "Alpha"}, {"id": 2, "title": "Beta"}]
    """#

    // MARK: 夹具

    /// 替换 demoScript 里 `getChapterList` 的实现体。
    ///
    /// 用**正则 + 忽略缩进**：多行字符串在不同上下文里的缩进不同，
    /// 早先按源码缩进写死查找串，结果替换静默失败、用例假通过/假失败。
    static func script(chapterListBody: String, extraTopLevel: String = "") -> String {
        let pattern = #"async function getChapterList\(url\) \{\s*return \[\];\s*\}"#
        let replacement = "async function getChapterList(url) { \(chapterListBody) }"
        var text = demoScript.replacingOccurrences(
            of: pattern,
            with: replacement,
            options: .regularExpression
        )
        if !extraTopLevel.isEmpty {
            text += "\n" + extraTopLevel
        }
        return text
    }

    private func makeRuntime(
        configuration: SourceRuntimeConfiguration = SourceRuntimeConfiguration(),
        preferences: SourcePreferencesStoring? = nil,
        logs: LogCollector? = nil
    ) -> (JSSourceRuntime, StubSourceTransport) {
        let transport = StubSourceTransport()
        transport.setResponse(
            SourceHTTPResult(status: 200, headers: ["Content-Type": "application/json"], body: Self.fixturePayload),
            for: "https://example.com/popular?page=1"
        )
        transport.setResponse(
            SourceHTTPResult(status: 200, headers: [:], body: "{\"ok\":true}"),
            for: "https://example.com/search"
        )
        let runtime = JSSourceRuntime(
            configuration: configuration,
            transport: transport,
            preferences: preferences ?? InMemorySourcePreferences(),
            logSink: { level, message in logs?.append(level: level, message: message) }
        )
        return (runtime, transport)
    }

    private func loadDemo(
        into runtime: JSSourceRuntime,
        script: String = JSSourceRuntimeTests.demoScript
    ) async throws {
        let meta = try SourceScriptValidator.validate(script)
        try await runtime.load(script: script, meta: meta)
    }

    // MARK: 装载校验

    @Test("装载合法脚本后可调用契约方法")
    func loadsValidScript() async throws {
        let (runtime, _) = makeRuntime()
        try await loadDemo(into: runtime)

        let result = try await runtime.call(.popularManga, arguments: ["1"])
        let json = try #require(result.data(using: .utf8))
        let decoded = try JSONSerialization.jsonObject(with: json) as? [String: Any]

        #expect(decoded?["hasNextPage"] as? Bool == true)
        let mangas = decoded?["mangas"] as? [[String: Any]]
        #expect(mangas?.count == 2)
        #expect(mangas?.first?["title"] as? String == "Alpha")
        #expect(mangas?.first?["url"] as? String == "/m/1")
    }

    @Test("装载时拒绝缺少必需方法的脚本", arguments: [
        "const source = { id: \"demo\", name: \"X\" };\nasync function getPopularManga(p) { return {}; }",
        "const source = { id: \"demo\", name: \"X\" };",
    ])
    func rejectsIncompleteScript(script: String) async throws {
        let (runtime, _) = makeRuntime()
        let meta = SourceScriptMeta(id: SourceID("demo"), name: "X")
        do {
            try await runtime.load(script: script, meta: meta)
            Issue.record("应当抛错")
        } catch let error as SourceRunnerError {
            guard case .incompleteContract = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
        }
    }

    @Test("装载时拒绝含禁用 API 的脚本")
    func rejectsForbiddenAPI() async throws {
        let (runtime, _) = makeRuntime()
        let script = Self.demoScript + "\nfunction bad() { eval(\"1\"); }"
        let meta = try SourceScriptValidator.validate(Self.demoScript)
        await #expect(throws: SourceRunnerError.self) {
            try await runtime.load(script: script, meta: meta)
        }
    }

    @Test("装载时拒绝 id 不一致的脚本")
    func rejectsMismatchedID() async throws {
        let (runtime, _) = makeRuntime()
        let meta = SourceScriptMeta(id: SourceID("other"), name: "Demo")
        do {
            try await runtime.load(script: Self.demoScript, meta: meta)
            Issue.record("应当抛错")
        } catch let error as SourceRunnerError {
            guard case .scriptRejected = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
        }
    }

    @Test("脚本顶层抛异常时报 scriptRejected")
    func rejectsThrowingScript() async throws {
        let (runtime, _) = makeRuntime()
        let script = Self.demoScript + "\nthrow new Error(\"boom\");"
        let meta = try SourceScriptValidator.validate(Self.demoScript)
        do {
            try await runtime.load(script: script, meta: meta)
            Issue.record("应当抛错")
        } catch let error as SourceRunnerError {
            guard case let .scriptRejected(reason) = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
            #expect(reason.contains("boom"))
        }
    }

    // MARK: 净桥接

    @Test("net.fetch 的 GET 请求带上 URL，并把响应体交给脚本")
    func netFetchGet() async throws {
        let (runtime, transport) = makeRuntime()
        try await loadDemo(into: runtime)
        _ = try await runtime.call(.popularManga, arguments: ["1"])

        let call = try #require(transport.calls.first)
        #expect(call.url == "https://example.com/popular?page=1")
        #expect(call.method == "GET")
        #expect(call.sourceID == "demo")
    }

    @Test("net.fetch 的 POST 带上方法、请求头与请求体")
    func netFetchPost() async throws {
        let (runtime, transport) = makeRuntime()
        try await loadDemo(into: runtime)
        let result = try await runtime.call(
            .searchManga,
            arguments: [#""query""#, "2", "{}"]
        )

        let call = try #require(transport.calls.first)
        #expect(call.method == "POST")
        #expect(call.headers["X-Token"] == "abc")
        #expect(call.headers["X-Page"] == "2")
        #expect(call.body == "{\"q\":\"query\"}")

        // 断言解析后的字段，而不是在序列化文本里找子串：
        // echo 里存的是 JSON 文本，序列化后内层引号会变成 \"，
        // 直接找 `"ok":true` 反而找不到。
        let decoded = try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any]
        #expect(decoded?["echo"] as? String == "{\"ok\":true}")
    }

    @Test("net.fetch 失败时在 JS 侧抛错（脚本可捕获并降级）")
    func netFetchFailureThrowsInJS() async throws {
        let (runtime, transport) = makeRuntime()
        try await loadDemo(into: runtime)
        transport.setFailure(NetworkError.timeout(seconds: 15))

        do {
            _ = try await runtime.call(.popularManga, arguments: ["1"])
            Issue.record("应当抛错")
        } catch let error as SourceRunnerError {
            guard case let .executionFailed(reason) = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
            #expect(reason.contains("超时") || reason.lowercased().contains("timeout"))
        }
    }

    @Test("脚本能读到该源的 Cookie")
    func cookiesBridgeReads() async throws {
        let (runtime, transport) = makeRuntime()
        transport.seedCookies(["token": "secret"], for: "https://example.com/search")
        try await loadDemo(into: runtime)

        let result = try await runtime.call(.searchManga, arguments: [#""q""#, "1", "{}"])
        #expect(result.contains("\"cookie\":\"secret\""))
    }

    @Test("脚本写入的 Cookie 会落到该源")
    func cookiesBridgeWrites() async throws {
        let (runtime, transport) = makeRuntime()
        try await loadDemo(into: runtime)

        let script = Self.demoScript.replacingOccurrences(
            of: "log.info(\"search done, cookie=\" + cookieToken);",
            with: "cookies.set(\"https://example.com/search\", { \"token\": \"new\" });"
        )
        try await loadDemo(into: runtime, script: script)
        _ = try await runtime.call(.searchManga, arguments: [#""q""#, "1", "{}"])

        // 写入是异步派发的，给它一点时间落地
        try await Task.sleep(nanoseconds: 200_000_000)
        let stored = transport.cookies(for: "https://example.com/search", sourceID: SourceID("demo"))
        #expect(stored["token"] == "new")
    }

    @Test("prefs 读不到时用默认值，写入后能读回")
    func prefsBridge() async throws {
        let (runtime, transport) = makeRuntime()
        _ = transport
        try await loadDemo(into: runtime)

        // 未设置 → 用默认值 "T:"
        let first = try await runtime.call(.mangaDetails, arguments: [#""/m/9""#])
        #expect(first.contains("\"title\":\"T:/m/9\""))

        // 设置后再读 → 用设置值
        let settings = InMemorySourcePreferences()
        settings.setValue("P:", forKey: JSSourceRuntime.preferenceKey(sourceID: SourceID("demo"), key: "titlePrefix"))
        let (runtime2, _) = makeRuntime(preferences: settings)
        try await loadDemo(into: runtime2)
        let second = try await runtime2.call(.mangaDetails, arguments: [#""/m/9""#])
        #expect(second.contains("\"title\":\"P:/m/9\""))
    }

    @Test("log 桥接把消息送到宿主，并带上来源标记")
    func logBridge() async throws {
        let logs = LogCollector()
        let (runtime, _) = makeRuntime(logs: logs)
        try await loadDemo(into: runtime)
        _ = try await runtime.call(.searchManga, arguments: [#""q""#, "1", "{}"])

        try await Task.sleep(nanoseconds: 200_000_000)
        let entries = logs.all
        #expect(entries.contains { $0.hasPrefix("info|[demo] search done") })
    }

    // MARK: 超时与生命周期

    @Test("脚本长时间不返回时按时超时")
    func callTimesOut() async throws {
        let (runtime, _) = makeRuntime(configuration: SourceRuntimeConfiguration(callTimeoutSeconds: 1))
        let script = Self.script(chapterListBody: "return await new Promise(function () {});")
        try await loadDemo(into: runtime, script: script)

        let start = Date()
        do {
            _ = try await runtime.call(.chapterList, arguments: [#""/m/1""#])
            Issue.record("应当超时")
        } catch let error as SourceRunnerError {
            guard case .executionTimeout = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
        }
        // 只验证「会超时返回」，不苛求精确时长：超时任务组在抛错后还要等
        // 被取消的 JS 调用结束，而 CI 上测试是并行执行的，任务调度可能有
        // 数秒延迟。关键语义是「不会无限等待」。
        #expect(Date().timeIntervalSince(start) < 20, "超时应返回，而不是一直挂着")
    }

    @Test("teardown 之后再调用报「未安装」")
    func teardownClearsState() async throws {
        let (runtime, _) = makeRuntime()
        try await loadDemo(into: runtime)
        await runtime.teardown()

        do {
            _ = try await runtime.call(.popularManga, arguments: ["1"])
            Issue.record("应当抛错")
        } catch let error as SourceRunnerError {
            guard case .notInstalled = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
        }
    }

    @Test("未装载就调用报「未安装」")
    func callBeforeLoadFails() async throws {
        let (runtime, _) = makeRuntime()
        do {
            _ = try await runtime.call(.popularManga, arguments: ["1"])
            Issue.record("应当抛错")
        } catch let error as SourceRunnerError {
            guard case .notInstalled = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
        }
    }

    @Test("重新载入会替换旧沙箱（旧脚本的全局不可见）")
    func reloadReplacesSandbox() async throws {
        let (runtime, _) = makeRuntime()
        let scriptA = Self.script(
            chapterListBody: "return [{ name: globalThis.__marker }];",
            extraTopLevel: "globalThis.__marker = \"A\";"
        )
        try await loadDemo(into: runtime, script: scriptA)
        let fromA = try await runtime.call(.chapterList, arguments: [#""/x""#])
        #expect(fromA.contains("\"A\""))

        try await loadDemo(into: runtime, script: Self.demoScript)
        let fromB = try await runtime.call(.chapterList, arguments: [#""/x""#])
        #expect(fromB == "[]")
    }

    // MARK: 参数与隔离

    @Test("非法 JSON 参数被拒绝", arguments: ["{not json", "nil", "\"unterminated"])
    func rejectsInvalidArguments(argument: String) async throws {
        let (runtime, _) = makeRuntime()
        try await loadDemo(into: runtime)
        do {
            _ = try await runtime.call(.popularManga, arguments: [argument])
            Issue.record("应当抛错")
        } catch let error as SourceRunnerError {
            guard case .invalidResponse = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
        }
    }

    @Test("两个运行时的沙箱互不影响")
    func sandboxesAreIsolated() async throws {
        // 两个沙箱各用自己的脚本，各自在顶层写一个全局变量；
        // 若 VM 被共享，第二个沙箱会读到第一个的值。
        func script(marker: String) -> String {
            Self.script(
                chapterListBody: #"return [{ name: String(globalThis.__marker || "none") }];"#,
                extraTopLevel: "globalThis.__marker = \"\(marker)\";"
            )
        }

        let (first, _) = makeRuntime()
        let (second, _) = makeRuntime()
        try await loadDemo(into: first, script: script(marker: "A"))
        try await loadDemo(into: second, script: script(marker: "B"))

        let firstResult = try await first.call(.chapterList, arguments: [#""/a""#])
        let secondResult = try await second.call(.chapterList, arguments: [#""/a""#])
        #expect(firstResult.contains("\"A\""))
        #expect(secondResult.contains("\"B\""))
    }

    @Test("未实现的方法在 JS 侧报错而不是静默返回")
    func missingOptionalMethodReports() async throws {
        let (runtime, _) = makeRuntime()
        try await loadDemo(into: runtime)
        do {
            _ = try await runtime.call(.filters, arguments: [])
            Issue.record("应当抛错")
        } catch let error as SourceRunnerError {
            guard case let .executionFailed(reason) = error else {
                Issue.record("错误类型不符：\(error)")
                return
            }
            #expect(reason.contains("getFilters"))
        }
    }

    // MARK: 纯函数

    @Test("decodeRequest 解析方法、头与体")
    func decodesRequest() throws {
        let request = try JSSourceRuntime.decodeRequest(
            url: "https://example.com/x",
            optionsJSON: #"{"method":"post","headers":{"A":"1"},"body":"a=1&b=2"}"#
        )
        #expect(request.method == "POST")
        #expect(request.headers["A"] == "1")
        #expect(request.body == "a=1&b=2")
    }

    @Test("decodeRequest 对空/非法 options 回退为 GET")
    func decodesRequestFallback() throws {
        #expect(try JSSourceRuntime.decodeRequest(url: "https://example.com", optionsJSON: "").method == "GET")
        #expect(try JSSourceRuntime.decodeRequest(url: "https://example.com", optionsJSON: "not json").method == "GET")
    }

    @Test("decodeRequest 支持对象体（编码为表单串）")
    func decodesFormBody() throws {
        let request = try JSSourceRuntime.decodeRequest(
            url: "https://example.com",
            optionsJSON: #"{"method":"POST","body":{"b":"2","a":"1"}}"#
        )
        #expect(request.body == "a=1&b=2")
    }

    @Test("encodeResponse 产出可解析的 JSON")
    func encodesResponse() throws {
        let text = JSSourceRuntime.encodeResponse(
            SourceHTTPResult(status: 201, headers: ["X": "1"], body: "hello")
        )
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        #expect(object?["status"] as? Int == 201)
        #expect(object?["body"] as? String == "hello")
    }

    @Test("jsonArrayLiteral 按 JSON 片段拼接并保留顺序")
    func buildsArrayLiteral() throws {
        // 参数本身就是 JSON 片段：数字、字符串、对象、数组都要原样保留
        let text = JSSourceRuntime.jsonArrayLiteral(["1", #""a""#, "{}", "[1,2]"])
        let array = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any]
        #expect(array?.count == 4)
        #expect(array?[0] as? Int == 1)
        #expect(array?[1] as? String == "a")
        #expect((array?[2] as? [String: Any])?.isEmpty == true)
        #expect(array?[3] as? [Int] == [1, 2])
    }

    @Test("jsonArrayLiteral 空参数为空数组")
    func buildsEmptyArrayLiteral() throws {
        let array = try JSONSerialization.jsonObject(with: Data(JSSourceRuntime.jsonArrayLiteral([]).utf8)) as? [Any]
        #expect(array?.isEmpty == true)
    }

    @Test("偏好键按来源隔离")
    func preferenceKeysAreNamespaced() {
        let a = JSSourceRuntime.preferenceKey(sourceID: SourceID("a"), key: "k")
        let b = JSSourceRuntime.preferenceKey(sourceID: SourceID("b"), key: "k")
        #expect(a != b)
        #expect(a == "source.a.pref.k")
    }
}
