//
//  HTTPClientTests.swift
//  MangaTranslaterTests
//
//  覆盖 HTTP 客户端：URL 校验、请求头、Cookie 注入、重试策略、
//  Retry-After 解析、超大响应、取消、节流调用、并发。
//
//  全部使用脚本化 stub，不访问真实网络。
//

import Testing
import Foundation
import AppCore
import ComicNet

@Suite("HTTP 客户端")
struct HTTPClientTests {

    private func makeClient(
        transport: StubTransport,
        maxRetries: Int = 2,
        maxResponseBytes: Int = 1024,
        cookieJar: CookieJar? = nil,
        sourceID: SourceID? = nil,
        rateLimiter: RateLimiter? = nil,
        sleepRecorder: SleepRecorder? = nil
    ) -> HTTPClient {
        HTTPClient(
            transport: transport,
            configuration: HTTPClient.Configuration(
                maxRetries: maxRetries,
                retryBackoff: [0.01, 0.02],
                maxResponseBytes: maxResponseBytes,
                timeoutSeconds: 15
            ),
            rateLimiter: rateLimiter,
            cookieJar: cookieJar,
            cookieSourceID: sourceID,
            sleeper: { interval in await sleepRecorder?.record(interval) }
        )
    }

    final class SleepRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var intervals: [TimeInterval] = []
        var recorded: [TimeInterval] {
            lock.lock()
            defer { lock.unlock() }
            return intervals
        }
        func record(_ interval: TimeInterval) {
            lock.lock()
            intervals.append(interval)
            lock.unlock()
        }
    }

    // MARK: 成功路径

    @Test("GET 成功返回数据与状态码")
    func getSuccess() async throws {
        let transport = StubTransport(data: Data("ok".utf8), statusCode: 200)
        let client = makeClient(transport: transport)

        let response = try await client.get("https://example.com/a")
        #expect(response.statusCode == 200)
        #expect(response.text == "ok")
        #expect(response.isSuccess)
        #expect(transport.requestCount == 1)
    }

    @Test("默认请求头带 User-Agent")
    func attachesUserAgent() async throws {
        let transport = StubTransport(data: Data())
        let client = makeClient(transport: transport)
        _ = try await client.get("https://example.com/a")

        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("MangaTranslater") == true)
    }

    @Test("自定义请求头可覆盖默认值")
    func customHeadersOverride() async throws {
        let transport = StubTransport(data: Data())
        let client = makeClient(transport: transport)
        _ = try await client.get("https://example.com/a", headers: ["Referer": "https://example.com/list"])

        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Referer") == "https://example.com/list")
    }

    @Test("自动注入来源 Cookie")
    func injectsCookies() async throws {
        let jar = CookieJar()
        let sourceID = SourceID("alpha")
        try jar.set(StoredCookie(name: "sid", value: "42", domain: "example.com"), for: sourceID)

        let transport = StubTransport(data: Data())
        let client = makeClient(transport: transport, cookieJar: jar, sourceID: sourceID)
        _ = try await client.get("https://example.com/a")

        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Cookie") == "sid=42")
    }

    @Test("POST 带 body 与 Content-Type")
    func postWithBody() async throws {
        let transport = StubTransport(data: Data())
        let client = makeClient(transport: transport)
        _ = try await client.post("https://example.com/a", body: Data("q=1".utf8))

        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.httpBody == Data("q=1".utf8))
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
    }

    // MARK: 非法输入

    @Test("非法 URL 立即失败且不发请求")
    func invalidURLFails() async {
        let transport = StubTransport(data: Data())
        let client = makeClient(transport: transport)

        await expectThrowsAsync(NetworkError.invalidURL("not a url")) {
            _ = try await client.get("not a url")
        }
        #expect(transport.requestCount == 0)
    }

    @Test("空 URL 与非法 scheme 被拒绝")
    func rejectsEmptyAndBadScheme() async {
        let transport = StubTransport(data: Data())
        let client = makeClient(transport: transport)

        await expectThrowsAsync(NetworkError.invalidURL("")) {
            _ = try await client.get("")
        }
        await expectThrowsAsync(NetworkError.invalidURL("ftp://example.com")) {
            _ = try await client.get("ftp://example.com")
        }
        #expect(transport.requestCount == 0)
    }

    // MARK: 错误与重试

    @Test("404 不重试直接抛出")
    func clientErrorDoesNotRetry() async {
        let transport = StubTransport(outcomes: [
            .success(data: Data(), statusCode: 404, headers: [:]),
        ])
        let client = makeClient(transport: transport)

        await expectThrowsAsync(NetworkError.httpStatus(code: 404, retryAfterSeconds: nil)) {
            _ = try await client.get("https://example.com/a")
        }
        #expect(transport.requestCount == 1)
    }

    @Test("500 按重试次数重试后失败")
    func serverErrorRetriesThenFails() async {
        let transport = StubTransport(outcomes: [
            .success(data: Data(), statusCode: 500, headers: [:]),
            .success(data: Data(), statusCode: 500, headers: [:]),
            .success(data: Data(), statusCode: 500, headers: [:]),
        ])
        let recorder = SleepRecorder()
        let client = makeClient(transport: transport, maxRetries: 2, sleepRecorder: recorder)

        await expectThrowsAsync(NetworkError.httpStatus(code: 500, retryAfterSeconds: nil)) {
            _ = try await client.get("https://example.com/a")
        }
        #expect(transport.requestCount == 3)
        #expect(recorder.recorded.count == 2)
    }

    @Test("500 后成功则返回成功结果")
    func recoversAfterRetry() async throws {
        let transport = StubTransport(outcomes: [
            .success(data: Data(), statusCode: 503, headers: [:]),
            .success(data: Data("recovered".utf8), statusCode: 200, headers: [:]),
        ])
        let client = makeClient(transport: transport, maxRetries: 2)

        let response = try await client.get("https://example.com/a")
        #expect(response.text == "recovered")
        #expect(transport.requestCount == 2)
    }

    @Test("超时错误可重试")
    func timeoutRetries() async {
        let transport = StubTransport(outcomes: [
            .failure(.timeout(seconds: 15)),
            .failure(.timeout(seconds: 15)),
        ])
        let client = makeClient(transport: transport, maxRetries: 1)

        await expectThrowsAsync(NetworkError.timeout(seconds: 15)) {
            _ = try await client.get("https://example.com/a")
        }
        #expect(transport.requestCount == 2)
    }

    @Test("离线错误可重试，但 4xx 不重试")
    func retryPolicy() {
        #expect(NetworkError.offline.isRetryable)
        #expect(NetworkError.httpStatus(code: 429, retryAfterSeconds: nil).isRetryable)
        #expect(NetworkError.httpStatus(code: 408, retryAfterSeconds: nil).isRetryable)
        #expect(!NetworkError.httpStatus(code: 403, retryAfterSeconds: nil).isRetryable)
        #expect(!NetworkError.invalidURL("x").isRetryable)
        #expect(!NetworkError.responseTooLarge(limit: 1).isRetryable)
        #expect(!NetworkError.cancelled.isRetryable)
    }

    @Test("禁用重试时只请求一次")
    func allowsRetryFalse() async {
        let transport = StubTransport(outcomes: [
            .success(data: Data(), statusCode: 500, headers: [:]),
        ])
        let client = makeClient(transport: transport, maxRetries: 3)

        await expectThrowsAsync(NetworkError.httpStatus(code: 500, retryAfterSeconds: nil)) {
            _ = try await client.get("https://example.com/a", allowsRetry: false)
        }
        #expect(transport.requestCount == 1)
    }

    // MARK: Retry-After

    @Test("429 遵循 Retry-After 秒数", arguments: ["3", " 3 ", "0"])
    func honorsRetryAfterSeconds(value: String) async {
        let transport = StubTransport(outcomes: [
            .success(data: Data(), statusCode: 429, headers: ["Retry-After": value]),
            .success(data: Data(), statusCode: 200, headers: [:]),
        ])
        let recorder = SleepRecorder()
        let client = makeClient(transport: transport, maxRetries: 1, sleepRecorder: recorder)

        _ = try? await client.get("https://example.com/a")
        #expect(recorder.recorded.count == 1)
    }

    @Test("Retry-After 解析：秒数与 HTTP 日期")
    func parseRetryAfter() {
        #expect(HTTPClient.parseRetryAfter("120") == 120)
        #expect(HTTPClient.parseRetryAfter("0") == 0)
        #expect(HTTPClient.parseRetryAfter("-5") == 0)
        #expect(HTTPClient.parseRetryAfter("garbage") == nil)
        #expect(HTTPClient.parseRetryAfter(nil) == nil)
        #expect(HTTPClient.parseRetryAfter("") == nil)

        let now = Date(timeIntervalSince1970: 0)
        let future = Date(timeIntervalSince1970: 120)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        #expect(HTTPClient.parseRetryAfter(formatter.string(from: future), now: now) == 120)
    }

    // MARK: 大小保护

    @Test("响应体超过上限被拒绝")
    func rejectsOversizedResponse() async {
        let transport = StubTransport(data: Data(repeating: 0x41, count: 4096))
        let client = makeClient(transport: transport, maxResponseBytes: 1024)

        await expectThrowsAsync(NetworkError.responseTooLarge(limit: 1024)) {
            _ = try await client.get("https://example.com/a")
        }
    }

    @Test("边界：恰好等于上限时通过")
    func acceptsExactlyAtLimit() async throws {
        let payload = Data(repeating: 0x42, count: 1024)
        let transport = StubTransport(data: payload)
        let client = makeClient(transport: transport, maxResponseBytes: 1024)

        let response = try await client.get("https://example.com/a")
        #expect(response.data.count == 1024)
    }

    // MARK: 节流

    @Test("每次请求都经过节流器")
    func usesRateLimiter() async throws {
        let limiter = RateLimiter(minInterval: 0, clock: { Date() }, sleeper: { _ in })
        let transport = StubTransport(data: Data())
        let client = makeClient(transport: transport, rateLimiter: limiter)

        _ = try await client.get("https://example.com/a")
        _ = try await client.get("https://example.com/b")

        #expect(transport.requestCount == 2)
        #expect(await limiter.lastAcquisitionDate != nil)
    }

    // MARK: 并发

    @Test("并发请求各自独立完成")
    func concurrentRequests() async throws {
        let transport = StubTransport(data: Data("x".utf8))
        let client = makeClient(transport: transport)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<10 {
                group.addTask {
                    _ = try await client.get("https://example.com/\(index)")
                }
            }
            try await group.waitForAll()
        }

        #expect(transport.requestCount == 10)
    }

    // MARK: 响应工具

    @Test("响应头大小写不敏感查找")
    func headerLookupIsCaseInsensitive() {
        let response = HTTPResponse(
            data: Data(),
            statusCode: 200,
            headers: ["retry-after": "5", "content-type": "text/html"]
        )
        #expect(response.headerValue("Retry-After") == "5")
        #expect(response.headerValue("CONTENT-TYPE") == "text/html")
        #expect(response.headerValue("missing") == nil)
    }

    @Test("错误到 AppError 的映射")
    func errorMapping() {
        #expect(NetworkError.timeout(seconds: 1).toAppError == .network("timeout(1s)"))
        #expect(NetworkError.cancelled.toAppError == .cancelled)
        // payload 是本地化文案（随设备语言变化），因此只断言「地址被带进去了」。
        if case let .invalidInput(payload) = NetworkError.invalidURL("x").toAppError {
            #expect(payload.contains("x"))
        } else {
            Issue.record("invalidURL 应映射为 AppError.invalidInput")
        }
        #expect(NetworkError.httpStatus(code: 429, retryAfterSeconds: 2).isRateLimited)
    }
}
