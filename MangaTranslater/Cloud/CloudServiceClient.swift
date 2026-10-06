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
//  四条不可退让的设计：
//
//  1. **不用 `ComicNet.HTTPClient`，直接用传输层。**
//     这一条是被 CI 教会的：`HTTPClient` 的语义是「非 2xx 就抛 `NetworkError`」，
//     而它的错误里**不带响应体**。可 API 客户端必须拿到状态码**和**错误体才能分类——
//     401 要退回未登录、402 + `quota_exceeded` 要给升级入口。实测结果是所有
//     业务错误都被压成了 `transport("服务器返回 401")`，
//     精心写的 `mapFailure` 成了死代码、错误分类测试全红。
//     `HTTPClient` 是为**抓站**设计的（Cookie 注入、按源限流、正文体积上限），
//     这里用不上；传输层本身可注入，测试照样能离线跑。
//
//  2. **`/translate` 的请求体只有三个字段**（`CloudTranslateRequest` 显式声明
//     CodingKeys）。服务端不接收图片、不接收 URL、不留存文本；客户端这边
//     把「只发这些」写死，避免哪天顺手把整个上下文编码出去。
//
//  3. **错误按语义分类**，不直接把 HTTP 状态码抛给界面。
//
//  4. **传输层可注入**，因此所有分支（超时、5xx、坏 JSON、额度耗尽）
//     都能离线断言，不需要真的有一台服务器。
//

import Foundation
import AppCore
import ComicNet

struct CloudServiceClient: Sendable {

    /// 服务根地址（不含结尾 `/`）。
    let baseURL: String

    private let transport: HTTPTransporting
    /// 响应体上限。账号与译文都是文本，2 MB 绰绰有余，超出即视为异常。
    private let maxResponseBytes: Int
    /// 单次请求超时（秒）。
    private let timeoutSeconds: Int

    init(
        baseURL: String,
        transport: HTTPTransporting = URLSessionTransport(timeoutSeconds: 30),
        maxResponseBytes: Int = 2 * 1024 * 1024,
        timeoutSeconds: Int = 30
    ) {
        self.baseURL = CloudServiceClient.normalizeBaseURL(baseURL)
        self.transport = transport
        self.maxResponseBytes = max(1024, maxResponseBytes)
        self.timeoutSeconds = max(5, timeoutSeconds)
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
        let data = try await perform(path: "/auth/email/send", method: "POST", body: body, token: nil)
        let decoded: CloudSendCodeResponse = try decode(data)
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
        let data = try await perform(path: "/auth/email/verify", method: "POST", body: body, token: nil)
        let decoded: CloudVerifyResponse = try decode(data)
        return CloudSession(token: decoded.token, expiresAt: decoded.expiresAt, account: decoded.account)
    }

    /// 查当前账号与额度。
    func me(token: String) async throws -> CloudAccount {
        let data = try await perform(path: "/me", method: "GET", body: nil, token: token)
        return try decode(data)
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
        let data = try await perform(path: "/translate", method: "POST", body: body, token: token)
        // 刻意**不在这里**校验译文条数：这一层只能抛 `CloudError`，
        // 而「条数不符」在翻译层有更精确的表达（`TranslationError.countMismatch`）。
        // 两层各抛一种错，会让调用方要判断两次、界面文案也会不一致。
        // 校验统一放在 `CloudTranslationService`：那里是 `MangaTranslator` 的实现，
        // 也是「长度必须与输入一致」这条契约真正生效的地方。
        let decoded: CloudTranslateResponse = try decode(data)
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
        let endpoint = baseURL + path
        guard ModelValidation.isValidURLString(endpoint), let url = URL(string: endpoint) else {
            throw CloudError.missingBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = TimeInterval(timeoutSeconds)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if method != "GET" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body ?? Data()
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as NetworkError {
            throw CloudError.transport(error.errorDescription ?? "")
        } catch {
            throw CloudError.transport(error.localizedDescription)
        }

        guard (200...299).contains(response.statusCode) else {
            throw CloudServiceClient.mapFailure(status: response.statusCode, data: data)
        }
        guard data.count <= maxResponseBytes else { throw CloudError.badResponse }
        return data
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
