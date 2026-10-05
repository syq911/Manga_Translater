//
//  HTTPClient.swift
//  ComicNet
//
//  统一 HTTP 客户端：URL 校验 → 节流 → 注入 Cookie/UA → 发送 →
//  重试（仅可重试错误，遵循 Retry-After）→ 响应体大小保护。
//
//  传输层抽象为 `HTTPTransporting`，因此单元测试可以完全离线运行：
//  注入一个脚本化的 stub 即可覆盖超时、5xx 重试、429、超大响应等分支。
//

import Foundation
import AppCore

/// HTTP 响应（已做大小校验）。
public struct HTTPResponse: Sendable, Equatable {
    public let data: Data
    public let statusCode: Int
    public let headers: [String: String]

    public init(data: Data, statusCode: Int, headers: [String: String] = [:]) {
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
    }

    public var isSuccess: Bool { (200...299).contains(statusCode) }

    /// 以 UTF-8 解码文本（失败返回空串）。
    public var text: String {
        String(decoding: data, as: UTF8.self)
    }

    public func headerValue(_ name: String) -> String? {
        headers.first { $0.key.lowercased() == name.lowercased() }?.value
    }
}

/// 传输层抽象。
public protocol HTTPTransporting: Sendable {
    /// 发送请求。返回原始数据与响应对象。
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// 基于 URLSession 的默认传输实现。
public struct URLSessionTransport: HTTPTransporting {
    private let session: URLSession

    public init(timeoutSeconds: Int = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = TimeInterval(timeoutSeconds)
        configuration.timeoutIntervalForResource = TimeInterval(max(timeoutSeconds, 30))
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    public init(session: URLSession) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw NetworkError.transport("非 HTTP 响应")
            }
            return (data, http)
        } catch let error as NetworkError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .timedOut:
                throw NetworkError.timeout(seconds: Int(request.timeoutInterval))
            case .notConnectedToInternet, .networkConnectionLost:
                throw NetworkError.offline
            case .cancelled:
                throw NetworkError.cancelled
            default:
                throw NetworkError.transport("URLError(\(error.code.rawValue))")
            }
        } catch is CancellationError {
            throw NetworkError.cancelled
        }
    }
}

/// HTTP 客户端。
public struct HTTPClient: Sendable {

    public struct Configuration: Sendable {
        /// 最大重试次数（不含首次请求）。
        public var maxRetries: Int
        /// 每次重试前的退避秒数（按索引取，超出则用最后一个）。
        public var retryBackoff: [TimeInterval]
        /// 响应体上限（字节）。
        public var maxResponseBytes: Int
        /// 单次请求超时（秒）。
        public var timeoutSeconds: Int
        /// 默认 User-Agent。
        public var userAgent: String

        public init(
            maxRetries: Int = 2,
            retryBackoff: [TimeInterval] = [0.5, 1.5],
            maxResponseBytes: Int = 20 * 1024 * 1024,
            timeoutSeconds: Int = 15,
            userAgent: String = HTTPClient.defaultUserAgent
        ) {
            self.maxRetries = max(0, maxRetries)
            self.retryBackoff = retryBackoff.isEmpty ? [0.5] : retryBackoff
            self.maxResponseBytes = max(1024, maxResponseBytes)
            self.timeoutSeconds = max(5, timeoutSeconds)
            self.userAgent = userAgent
        }
    }

    public static let defaultUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) MangaTranslater/0.1"

    private let transport: HTTPTransporting
    private let configuration: Configuration
    private let rateLimiter: RateLimiter?
    private let cookieJar: CookieJar?
    private let cookieSourceID: SourceID?
    private let sleeper: @Sendable (TimeInterval) async throws -> Void

    public init(
        transport: HTTPTransporting,
        configuration: Configuration = Configuration(),
        rateLimiter: RateLimiter? = nil,
        cookieJar: CookieJar? = nil,
        cookieSourceID: SourceID? = nil,
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = { interval in
            guard interval > 0 else { return }
            try await Task.sleep(nanoseconds: UInt64((interval * 1_000_000_000).rounded()))
        }
    ) {
        self.transport = transport
        self.configuration = configuration
        self.rateLimiter = rateLimiter
        self.cookieJar = cookieJar
        self.cookieSourceID = cookieSourceID
        self.sleeper = sleeper
    }

    // MARK: 公开接口

    public func get(
        _ urlString: String,
        headers: [String: String] = [:],
        allowsRetry: Bool = true
    ) async throws -> HTTPResponse {
        try await perform(
            urlString: urlString,
            method: "GET",
            body: nil,
            contentType: nil,
            headers: headers,
            allowsRetry: allowsRetry
        )
    }

    public func post(
        _ urlString: String,
        body: Data,
        contentType: String = "application/x-www-form-urlencoded",
        headers: [String: String] = [:],
        allowsRetry: Bool = true
    ) async throws -> HTTPResponse {
        try await perform(
            urlString: urlString,
            method: "POST",
            body: body,
            contentType: contentType,
            headers: headers,
            allowsRetry: allowsRetry
        )
    }

    // MARK: 内部

    private func perform(
        urlString: String,
        method: String,
        body: Data?,
        contentType: String?,
        headers: [String: String],
        allowsRetry: Bool
    ) async throws -> HTTPResponse {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ModelValidation.isValidURLString(trimmed), let url = URL(string: trimmed) else {
            throw NetworkError.invalidURL(urlString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = TimeInterval(configuration.timeoutSeconds)
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let body {
            request.httpBody = body
        }
        if let cookieJar, let cookieSourceID,
           let cookieHeader = cookieJar.cookieHeader(for: cookieSourceID, url: trimmed) {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        let attempts = allowsRetry ? configuration.maxRetries + 1 : 1
        var lastError: NetworkError = .transport("未发起请求")

        for attempt in 0..<attempts {
            try Task.checkCancellation()
            if let rateLimiter {
                try await rateLimiter.acquire()
            }
            do {
                let (data, response) = try await transport.send(request)
                let status = response.statusCode
                let headerMap = HTTPClient.headerMap(from: response)

                guard 200...299 ~= status else {
                    let retryAfter = HTTPClient.parseRetryAfter(headerMap["retry-after"])
                    lastError = .httpStatus(code: status, retryAfterSeconds: retryAfter)
                    if lastError.isRetryable, attempt < attempts - 1 {
                        try await backoff(attempt: attempt, retryAfter: retryAfter)
                        continue
                    }
                    throw lastError
                }

                guard data.count <= configuration.maxResponseBytes else {
                    throw NetworkError.responseTooLarge(limit: configuration.maxResponseBytes)
                }

                return HTTPResponse(data: data, statusCode: status, headers: headerMap)
            } catch let error as NetworkError {
                lastError = error
                if error.isRetryable, attempt < attempts - 1 {
                    try await backoff(attempt: attempt, retryAfter: nil)
                    continue
                }
                throw error
            } catch is CancellationError {
                throw NetworkError.cancelled
            } catch {
                let mapped = NetworkError.transport((error as NSError).localizedDescription)
                lastError = mapped
                if attempt < attempts - 1 {
                    try await backoff(attempt: attempt, retryAfter: nil)
                    continue
                }
                throw mapped
            }
        }

        throw lastError
    }

    private func backoff(attempt: Int, retryAfter: Int?) async throws {
        if let retryAfter, retryAfter > 0 {
            try await sleeper(TimeInterval(min(retryAfter, 30)))
            return
        }
        let index = min(attempt, configuration.retryBackoff.count - 1)
        try await sleeper(configuration.retryBackoff[index])
    }

    static func headerMap(from response: HTTPURLResponse) -> [String: String] {
        var map: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let name = key as? String, let text = value as? String else { continue }
            map[name.lowercased()] = text
        }
        return map
    }

    /// 解析 `Retry-After`。支持秒数与 HTTP 日期两种形式；无法解析返回 nil。
    ///
    /// 公开给上层与测试使用：自定义重试策略时同样需要这套解析规则。
    public static func parseRetryAfter(_ raw: String?, now: Date = Date()) -> Int? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let seconds = Int(trimmed) {
            return max(0, seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: trimmed) else { return nil }
        return max(0, Int(date.timeIntervalSince(now).rounded()))
    }
}
