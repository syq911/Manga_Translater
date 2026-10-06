//
//  CloudServiceClient.swift
//  MangaTranslater
//
//  云服务 HTTP 客户端：邮箱验证码登录 / 账号额度查询 / 翻译代理。
//
//  端点（契约见 `docs/cloud-api.md`，与《开发手册》7.1 一致）：
//    POST /auth/email/send     { email }              → { ok, expiresInSeconds }
//    POST /auth/email/verify   { email, code }        → { token, expiresAt, account }
//    GET  /me                  (Bearer)               → account
//    POST /translate           { lines, source, target } → { lines, remainingToday }
//
//  三条不可退让的设计：
//  1. **`/translate` 的请求体只有三个字段**（`CloudTranslateRequest` 显式声明
//     CodingKeys）。服务端不接收图片、不接收 URL、不留存文本；客户端这边
//     把「只发这些」写死，避免哪天顺手把整个上下文编码出去。
//  2. **错误按语义分类**，不直接把 HTTP 状态码抛给界面：401 → 未登录、
//     402 + `quota_exceeded` → 额度用尽（界面据此给升级入口）。
//  3. **传输层可注入**，因此所有分支（超时、5xx、坏 JSON、额度耗尽）
//     都能离线断言，不需要真的有一台服务器。
//

import Foundation
import AppCore
import ComicNet

struct CloudServiceClient: Sendable {

    /// 服务根地址（不含结尾 `/`）。
    let baseURL: String
    private let client: HTTPClient

    init(
        baseURL: String,
        transport: HTTPTransporting = URLSessionTransport(timeoutSeconds: 30),
        maxRetries: Int = 1,
        timeoutSeconds: Int = 30
    ) {
        self.baseURL = CloudServiceClient.normalizeBaseURL(baseURL)
        self.client = HTTPClient(
            transport: transport,
            // 账号与额度操作重试价值低（用户就在屏幕前等），
            // 只留一次重试兜网络抖动；翻译请求由上层决定是否重试。
            configuration: HTTPClient.Configuration(
                maxRetries: max(0, maxRetries),
                timeoutSeconds: max(5, timeoutSeconds),
                userAgent: HTTPClient.defaultUserAgent
            )
        )
    }

    /// 去掉结尾的全部 `/`，避免拼出 `//auth/...`。
    static func normalizeBaseURL(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }

    // MARK: - 账号

    /// 发登录验证码。
    /// - Returns: 验证码有效期（秒）。
    @discardableResult
    func sendLoginCode(email: String) async throws -> Int {
        let normalized = ModelValidation.normalizeEmail(email)
        guard ModelValidation.isValidEmail(normalized) else { throw CloudError.invalidEmail }
        let body = try encode(["email": normalized])
        let response = try await perform(path: "/auth/email/send", method: "POST", body: body, token: nil)
        let decoded: CloudSendCodeResponse = try decode(response)
        return max(0, decoded.expiresInSeconds)
    }

    /// 用验证码换登录令牌。
    ///
    /// 「恢复订阅」就是**用同一个邮箱再登录一次**：账号与权益都挂在邮箱上，
    /// 因此不需要（也不该有）另一个凭据通道。
    func verifyLoginCode(email: String, code: String) async throws -> CloudSession {
        let normalized = ModelValidation.normalizeEmail(email)
        guard ModelValidation.isValidEmail(normalized) else { throw CloudError.invalidEmail }
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else { throw CloudError.invalidCode }
        let body = try encode(["email": normalized, "code": trimmedCode])
        let response = try await perform(path: "/auth/email/verify", method: "POST", body: body, token: nil)
        let decoded: CloudVerifyResponse = try decode(response)
        return CloudSession(token: decoded.token, expiresAt: decoded.expiresAt, account: decoded.account)
    }

    /// 查当前账号与额度。
    func me(token: String) async throws -> CloudAccount {
        let response = try await perform(path: "/me", method: "GET", body: nil, token: token)
        return try decode(response)
    }

    // MARK: - 翻译

    /// 走云端代理翻译一批文本。
    ///
    /// - Parameter source: 原文语言（`auto` 时传 `"auto"`，由服务端交给模型判断）。
    func translate(
        lines: [String],
        source: TranslationLanguage,
        target: TranslationLanguage,
        token: String
    ) async throws -> CloudTranslationResult {
        let payload = CloudTranslateRequest(
            lines: lines,
            source: source.rawValue,
            target: target.rawValue
        )
        let body: Data
        do {
            body = try JSONEncoder().encode(payload)
        } catch {
            throw CloudError.badResponse
        }
        let response = try await perform(path: "/translate", method: "POST", body: body, token: token)
        let decoded: CloudTranslateResponse = try decode(response)
        guard decoded.lines.count == lines.count else {
            throw CloudError.badResponse
        }
        return CloudTranslationResult(lines: decoded.lines, remainingToday: decoded.remainingToday)
    }

    // MARK: - 内部

    private func encode(_ object: [String: String]) throws -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: object)
        } catch {
            throw CloudError.badResponse
        }
    }

    private func perform(path: String, method: String, body: Data?, token: String?) async throws -> Data {
        guard ModelValidation.isValidURLString(baseURL) else { throw CloudError.missingBaseURL }
        let urlString = baseURL + path

        var headers: [String: String] = ["Accept": "application/json"]
        if let token, !token.isEmpty {
            headers["Authorization"] = "Bearer \(token)"
        }

        let response: HTTPResponse
        do {
            if method == "GET" {
                response = try await client.get(urlString, headers: headers)
            } else {
                response = try await client.post(
                    urlString,
                    body: body ?? Data(),
                    contentType: "application/json",
                    headers: headers,
                    // 4xx 由我们自己按语义分类，不让 HTTP 层重试
                    allowsRetry: false
                )
            }
        } catch let error as NetworkError {
            throw CloudError.transport(error.errorDescription ?? "")
        } catch {
            throw CloudError.transport(error.localizedDescription)
        }

        guard response.isSuccess else {
            throw CloudServiceClient.mapFailure(status: response.statusCode, data: response.data)
        }
        return response.data
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CloudError.badResponse
        }
    }

    /// 把「状态码 + 错误信封」映射成语义化错误。
    static func mapFailure(status: Int, data: Data) -> CloudError {
        let envelope = try? JSONDecoder().decode(CloudErrorEnvelope.self, from: data)
        let code = envelope?.error ?? ""
        let message = envelope?.message ?? ""

        // 401 / `unauthorized`：令牌过期或未登录 —— 界面应引导重新登录
        if status == 401 || code == "unauthorized" {
            return .unauthorized
        }
        // 402 / `quota_exceeded`：额度用尽 —— 界面应给「升级云服务」入口
        if code == "quota_exceeded" || code == "subscription_required" {
            let remaining = envelope?.remainingToday ?? 0
            return code == "subscription_required"
                ? .subscriptionRequired
                : .quotaExceeded(remaining: remaining)
        }
        if status == 402 {
            return .subscriptionRequired
        }
        if status == 400, code == "invalid_email" {
            return .invalidEmail
        }
        if status == 400, code == "invalid_code" {
            return .invalidCode
        }
        if status == 429 {
            return .rateLimited(retryAfterSeconds: max(1, envelope?.retryAfterSeconds ?? 60))
        }
        return .server(code: code.isEmpty ? "http_\(status)" : code, message: message)
    }
}
