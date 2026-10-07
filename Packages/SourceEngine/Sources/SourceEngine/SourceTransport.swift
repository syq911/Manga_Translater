//
//  SourceTransport.swift
//  SourceEngine
//
//  源脚本的网络与存储桥接层。
//
//  为什么单独抽象：JS 沙箱里的 `net.fetch` / `cookies` 不能直接摸到
//  `URLSession` 与文件系统——它们必须经由这一层，好处有三：
//  1. **按源隔离**：Cookie 与节流都以 `SourceID` 为界，源之间互不可见；
//  2. **可注入**：测试用替身即可完整驱动 JS 运行时，不需要真实网络；
//  3. **收口风险**：请求头、体积上限、协议白名单都在这里统一把关。
//

import Foundation
import AppCore
import ComicNet

/// 源发起的一次 HTTP 请求（来自 JS 的 `net.fetch`）。
public struct SourceHTTPRequest: Equatable, Sendable {
    public var url: String
    /// 仅支持 GET / POST；其他方法在桥接层被拒绝。
    public var method: String
    public var headers: [String: String]
    /// 文本形式的请求体（源通常提交表单）。
    public var body: String?
    /// 显式 Content-Type；为 nil 时按表单处理。
    public var contentType: String?

    public init(
        url: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: String? = nil,
        contentType: String? = nil
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.contentType = contentType
    }
}

/// 源收到的一次 HTTP 响应。
public struct SourceHTTPResult: Equatable, Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: String

    public init(status: Int, headers: [String: String] = [:], body: String) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public var isSuccess: Bool { (200...299).contains(status) }
}

/// 源桥接错误。
public enum SourceTransportError: Error, Equatable {
    case unsupportedMethod(String)
    case blockedScheme(String)
    case blockedHost(String)
    case bodyTooLarge(bytes: Int, limit: Int)
    case notFound(String)

    public var message: String {
        switch self {
        case let .unsupportedMethod(method):
            return Copy.format("error.transport.unsupportedMethod", method)
        case let .blockedScheme(scheme): return Copy.format("error.transport.blockedScheme", scheme)
        case let .blockedHost(host): return Copy.format("error.transport.blockedHost", host)
        case let .bodyTooLarge(bytes, limit):
            return Copy.format("error.transport.bodyTooLarge", bytes, limit)
        case let .notFound(url): return Copy.format("error.transport.notFound", url)
        }
    }
}

extension SourceTransportError: LocalizedError {
    public var errorDescription: String? { message }
}

/// 源网络桥接抽象。
public protocol SourceTransporting: Sendable {
    /// 发起请求。实现方负责带上该源的 Cookie 并遵守节流。
    func send(
        _ request: SourceHTTPRequest,
        sourceID: SourceID,
        rateLimitMilliseconds: Int
    ) async throws -> SourceHTTPResult

    /// 该源在某地址上的 Cookie（`name=value; ...`）；无则 nil。
    func cookieHeader(for url: String, sourceID: SourceID) async -> String?

    /// 该源在某地址上可见的 Cookie（结构化，供 `cookies.getAll` 使用）。
    ///
    /// - Important: **同步且必须是非阻塞的纯内存读取**。JS 侧的 `cookies.get`
    ///   是同步 API，若这里需要等待异步工作，就会在 JS 执行线程上形成自锁。
    ///   实现请直接读内存中的 Cookie 存储（`CookieJar` 本身线程安全）。
    func cookies(for url: String, sourceID: SourceID) -> [String: String]

    /// 写入 Cookie（源在 JS 里维护会话用）。
    func storeCookies(_ cookies: [String: String], for url: String, sourceID: SourceID) async

    /// 清除该源的全部 Cookie。
    func clearCookies(sourceID: SourceID) async
}

/// 默认实现：组合 `HTTPClient`（重试/超时/体积上限）+ `CookieJar` + `RateLimiter`。
///
/// 每个源各自持有一份 `HTTPClient` 与 `RateLimiter`：`HTTPClient` 绑定
/// 「某个源的 CookieJar 视图」，节流也必须是**按源独立**的——
/// 共享一个限速器会让慢源拖住快源。
public final class DefaultSourceTransport: SourceTransporting, @unchecked Sendable {

    private let transport: HTTPTransporting
    private let cookieJar: CookieJar
    private let configuration: HTTPClient.Configuration
    private let lock = NSLock()
    private var clients: [String: HTTPClient] = [:]

    public init(
        cookieJar: CookieJar,
        transport: HTTPTransporting = URLSessionTransport(),
        configuration: HTTPClient.Configuration = HTTPClient.Configuration()
    ) {
        self.cookieJar = cookieJar
        self.transport = transport
        self.configuration = configuration
    }

    /// 取（或创建）某源的客户端。Cookie 与限速器都按源绑定。
    private func client(for sourceID: SourceID, rateLimitMilliseconds: Int) -> HTTPClient {
        lock.lock()
        defer { lock.unlock() }
        if let existing = clients[sourceID.rawValue] { return existing }
        let limiter = RateLimiter(minInterval: TimeInterval(max(0, rateLimitMilliseconds)) / 1000)
        let client = HTTPClient(
            transport: transport,
            configuration: configuration,
            rateLimiter: limiter,
            cookieJar: cookieJar,
            cookieSourceID: sourceID
        )
        clients[sourceID.rawValue] = client
        return client
    }

    // MARK: 请求

    public func send(
        _ request: SourceHTTPRequest,
        sourceID: SourceID,
        rateLimitMilliseconds: Int
    ) async throws -> SourceHTTPResult {
        let method = request.method.uppercased()
        guard method == "GET" || method == "POST" else {
            throw SourceTransportError.unsupportedMethod(request.method)
        }
        try Self.assertAllowedURL(request.url)

        let client = client(for: sourceID, rateLimitMilliseconds: rateLimitMilliseconds)
        let response: HTTPResponse
        if method == "GET" {
            response = try await client.get(request.url, headers: request.headers)
        } else {
            let contentType = request.contentType ?? "application/x-www-form-urlencoded"
            response = try await client.post(
                request.url,
                body: Data((request.body ?? "").utf8),
                contentType: contentType,
                headers: request.headers
            )
        }

        guard response.data.count <= configuration.maxResponseBytes else {
            throw SourceTransportError.bodyTooLarge(
                bytes: response.data.count,
                limit: configuration.maxResponseBytes
            )
        }

        return SourceHTTPResult(
            status: response.statusCode,
            headers: response.headers,
            body: response.text
        )
    }

    /// 只允许 http/https；`http` 仅限本机（本机调试自建仓库），与全仓约定一致。
    static func assertAllowedURL(_ urlString: String) throws {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            throw SourceTransportError.blockedHost(urlString)
        }
        guard scheme == "http" || scheme == "https" else {
            throw SourceTransportError.blockedScheme(scheme)
        }
        if scheme == "http" {
            let host = url.host?.lowercased() ?? ""
            guard host == "localhost" || host == "127.0.0.1" || host == "::1" else {
                throw SourceTransportError.blockedScheme(Copy.text("error.transport.payloadHTTP"))
            }
        }
    }

    // MARK: Cookie

    public func cookieHeader(for url: String, sourceID: SourceID) async -> String? {
        cookieJar.cookieHeader(for: sourceID, url: url)
    }

    public func cookies(for url: String, sourceID: SourceID) -> [String: String] {
        guard let parsed = URL(string: url), let host = parsed.host else { return [:] }
        let path = parsed.path.isEmpty ? "/" : parsed.path
        var result: [String: String] = [:]
        for cookie in cookieJar.cookies(for: sourceID, host: host, path: path) {
            result[cookie.name] = cookie.value
        }
        return result
    }

    public func storeCookies(_ cookies: [String: String], for url: String, sourceID: SourceID) async {
        let host = URL(string: url)?.host ?? ""
        for (name, value) in cookies {
            let cookie = StoredCookie(name: name, value: value, domain: host, path: "/")
            // 非法名（含 ; 或 =）由 CookieJar 拒绝；这里静默跳过——
            // 源脚本传入脏数据不该让整次调用失败。
            try? cookieJar.set(cookie, for: sourceID)
        }
    }

    public func clearCookies(sourceID: SourceID) async {
        cookieJar.clear(sourceID: sourceID)
    }
}
