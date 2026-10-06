//
//  SourceImageLoader.swift
//  SourceEngine
//
//  图片字节的取回口：封面与漫画页共用一套规则。
//
//  为什么不复用 `SourceTransporting`：那条桥接给源脚本用，返回的是**字符串**
//  （契约里的响应体是文本），而图片是二进制、且体积上限完全不同
//  （契约 §5.3 单页 ≤20 MB，桥接响应上限只有 4 MB）。把两者混在一起，
//  迟早会出现「文本桥接的 4 MB 上限把大图砍掉」这种难查的问题。
//
//  与 `HTTPClient` 的分工：请求构造、重试、超时、体积上限、Cookie 注入
//  全部交给它（`HTTPClient` 已按来源绑定 CookieJar），这里只补三件事：
//  1. 图片专属的上限（20 MB）与超时；
//  2. 页级请求头（`PageRef.headers`，例如防盗链需要的 `Referer`）；
//  3. **明显不是图片的响应直接拒绝**——防盗链站点常返回 200 + HTML 错误页，
//     放过去只会让图片解码器报一堆看不懂的错。
//

import Foundation
import AppCore
import ComicNet

/// 图片来源错误。
public enum SourceImageError: Error, Equatable {
    case invalidURL(String)
    case blockedScheme(String)
    case tooLarge(limit: Int)
    case notAnImage(String)
    case emptyResponse
    case unavailable(String)
    case cancelled

    public var message: String {
        switch self {
        case let .invalidURL(url): return "图片地址不合法：\(url)"
        case let .blockedScheme(scheme): return "不支持的图片协议：\(scheme)"
        case let .tooLarge(limit): return "图片过大（上限 \(limit) 字节）"
        case let .notAnImage(contentType): return "返回的不是图片（\(contentType)）"
        case .emptyResponse: return "图片内容为空"
        case let .unavailable(reason): return "图片获取失败：\(reason)"
        case .cancelled: return "图片获取已取消"
        }
    }
}

extension SourceImageError: LocalizedError {
    public var errorDescription: String? { message }
}

/// 图片字节加载器。
public struct SourceImageLoader: Sendable {

    /// 加载配置。
    public struct Configuration: Sendable, Equatable {
        /// 单张图片上限（契约 §5.3 默认 20 MB）。
        public var maxBytes: Int
        /// 单张图片超时（秒）。
        public var timeoutSeconds: Int

        public init(maxBytes: Int = 20 * 1024 * 1024, timeoutSeconds: Int = 20) {
            self.maxBytes = max(1024, maxBytes)
            self.timeoutSeconds = max(5, timeoutSeconds)
        }
    }

    private let cookieJar: CookieJar?
    private let transport: HTTPTransporting
    private let configuration: Configuration

    public init(
        cookieJar: CookieJar? = nil,
        transport: HTTPTransporting = URLSessionTransport(),
        configuration: Configuration = Configuration()
    ) {
        self.cookieJar = cookieJar
        self.transport = transport
        self.configuration = configuration
    }

    // MARK: 取图

    /// 取一页的图片字节。
    ///
    /// - Parameters:
    ///   - page: 页描述，其 `headers`（如 `Referer`）会并入请求头。
    ///   - sourceID: 归属来源，用于带该来源的 Cookie。
    ///   - referer: 页级请求头未指定 `Referer` 时使用的默认值
    ///     （通常是章节页地址，防盗链站点常要求它）。
    public func imageData(
        for page: ComicPage,
        sourceID: SourceID,
        referer: String? = nil
    ) async throws -> Data {
        try await imageData(
            forURL: page.imageURL,
            sourceID: sourceID,
            headers: page.headers ?? [:],
            referer: referer
        )
    }

    /// 取任意图片地址的字节（封面、或自行构造的页地址）。
    public func imageData(
        forURL urlString: String,
        sourceID: SourceID,
        headers: [String: String] = [:],
        referer: String? = nil
    ) async throws -> Data {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            throw SourceImageError.invalidURL(urlString)
        }
        guard scheme == "http" || scheme == "https" else {
            throw SourceImageError.blockedScheme(scheme)
        }

        var requestHeaders = headers
        if !requestHeaders.keys.contains(where: { $0.lowercased() == "referer" }), let referer {
            requestHeaders["Referer"] = referer
        }

        let client = HTTPClient(
            transport: transport,
            configuration: HTTPClient.Configuration(
                // 图片重试一次就够：多试几次只会让等图的用户更久
                maxRetries: 1,
                retryBackoff: [0.5],
                maxResponseBytes: configuration.maxBytes,
                timeoutSeconds: configuration.timeoutSeconds
            ),
            cookieJar: cookieJar,
            cookieSourceID: sourceID
        )

        let response: HTTPResponse
        do {
            response = try await client.get(trimmed, headers: requestHeaders)
        } catch let error as NetworkError {
            throw Self.map(error, url: trimmed)
        } catch is CancellationError {
            throw SourceImageError.cancelled
        } catch {
            throw SourceImageError.unavailable(error.localizedDescription)
        }

        guard !response.data.isEmpty else {
            throw SourceImageError.emptyResponse
        }
        // 防盗链站点经常「200 + HTML 错误页」，早点识别比让解码器报错清楚得多
        if let contentType = response.headerValue("Content-Type"), Self.isClearlyNotImage(contentType) {
            throw SourceImageError.notAnImage(contentType)
        }
        return response.data
    }

    // MARK: 内部

    /// 只有**明确不是图片**的类型才拒绝。
    ///
    /// 不写「必须是 image/*」的白名单：很多图床返回 `application/octet-stream`
    /// 甚至不带 `Content-Type`，按白名单会把正常图片拦掉。
    static func isClearlyNotImage(_ contentType: String) -> Bool {
        let lowered = contentType.lowercased()
        if lowered.hasPrefix("text/") { return true }
        if lowered.contains("html") { return true }
        if lowered.contains("json") { return true }
        if lowered.contains("xml") { return true }
        return false
    }

    static func map(_ error: NetworkError, url: String) -> SourceImageError {
        switch error {
        case let .invalidURL(value):
            return .invalidURL(value)
        case let .responseTooLarge(limit):
            return .tooLarge(limit: limit)
        case let .httpStatus(code, _):
            return .unavailable("HTTP \(code)")
        case let .timeout(seconds):
            return .unavailable("超时（\(seconds) 秒）")
        case .offline:
            return .unavailable("网络不可用")
        case .cancelled:
            return .cancelled
        case let .transport(reason):
            return .unavailable(reason)
        case let .decoding(reason):
            return .unavailable(reason)
        @unknown default:
            return .unavailable("\(url)：\(error.localizedDescription)")
        }
    }
}
