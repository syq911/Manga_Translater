//
//  TranslationService.swift
//  MangaTranslater
//
//  翻译后端：协议 + 自备密钥（BYOK，OpenAI 兼容端点）。
//
//  后端有三条路（《开发手册》6.2）：
//  - BYOK：用户自带 Key，直连 DeepSeek 或**任意 OpenAI 兼容服务**；
//  - 云服务：走官方托管代理（`CloudTranslationService`，见 Cloud/）；
//  - Apple 端上翻译：系统框架（`AppleTranslationBridge`）。
//
//  三者都实现同一个 `MangaTranslator`，于是编排器（TranslationController）
//  里只有一处 `switch`，翻译之外的一切（队列、进度、缓存、排版）完全共用。
//
//  接口契约（务必保持）：返回数组的**长度与顺序**必须与入参一致，
//  否则排版会把译文盖到错误的文字框上——这比翻错一行更糟，
//  因此长度不符一律抛 `countMismatch` 而不是尽力对齐。
//

import Foundation
import AppCore
import ComicNet

// MARK: - 错误

enum TranslationError: LocalizedError, Equatable {
    case missingAPIKey
    case badURL
    case http(status: Int, body: String)
    case emptyResponse
    case countMismatch(expected: Int, got: Int)
    case noTextRecognized
    case imageUnavailable
    case cancelled
    /// 云服务未登录。
    case notSignedIn
    /// 云服务免费额度用尽。
    case quotaExceeded(remaining: Int)
    /// 云服务需要订阅（免费额度与订阅都不满足时）。
    case subscriptionRequired
    /// 云服务侧的其他失败（含服务端返回的业务错误）。
    case cloud(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return L("translation.error.missingKey")
        case .badURL:
            return L("translation.error.badURL")
        case let .http(status, body):
            return String(format: L("translation.error.http"), status, body)
        case .emptyResponse:
            return L("translation.error.empty")
        case let .countMismatch(expected, got):
            return String(format: L("translation.error.countMismatch"), expected, got)
        case .noTextRecognized:
            return L("translation.error.noText")
        case .imageUnavailable:
            return L("translation.error.imageUnavailable")
        case .cancelled:
            return L("translation.error.cancelled")
        case .notSignedIn:
            return L("translation.error.notSignedIn")
        case let .quotaExceeded(remaining):
            return String(format: L("translation.error.quotaExceeded"), remaining)
        case .subscriptionRequired:
            return L("translation.error.subscriptionRequired")
        case let .cloud(reason):
            return String(format: L("translation.error.cloud"), reason)
        }
    }

    /// 额度类错误：界面据此显示「升级云服务」入口，而不是普通失败横幅。
    var isQuotaRelated: Bool {
        switch self {
        case .quotaExceeded, .subscriptionRequired: return true
        default: return false
        }
    }
}

// MARK: - 协议

/// 翻译后端。
protocol MangaTranslator: Sendable {
    /// 批量翻译。返回数组长度、顺序必须与 `texts` 一致。
    func translate(
        _ texts: [String],
        source: TranslationLanguage,
        target: TranslationLanguage
    ) async throws -> [String]
}

// MARK: - 自备密钥（OpenAI 兼容）

/// 走 OpenAI 兼容 `/chat/completions` 的后端。
///
/// 拆成「分块 + 重试」两件事，都是被真实使用暴露出来的：
/// 1. **分块**：一页可能有几十行对白，整批发过去可能顶到上下文上限，
///    结果就是模型丢掉一部分、条数与输入不符而整页失败。按 `chunkSize` 切块
///    逐块翻译再按原顺序拼起来，单块失败只影响该块。
/// 2. **重试**：接口偶发 5xx / 超时。仅对「可重试」的错误重试，
///    4xx（Key 错、参数错）直接抛出——重试只会把同一个错误再撞一遍。
struct DeepSeekTranslator: MangaTranslator {

    let apiKey: String
    let baseURL: String
    let model: String

    private let transport: HTTPTransporting
    private let sleeper: @Sendable (TimeInterval) async throws -> Void
    /// 单次请求最多携带的文本条数。
    private let chunkSize: Int
    /// 单块的最大尝试次数（含首次）。
    private let maxAttempts: Int

    init(
        apiKey: String,
        baseURL: String,
        model: String,
        transport: HTTPTransporting = URLSessionTransport(timeoutSeconds: 60),
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = { interval in
            guard interval > 0 else { return }
            try await Task.sleep(nanoseconds: UInt64((interval * 1_000_000_000).rounded()))
        },
        chunkSize: Int = 40,
        maxAttempts: Int = 2
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.transport = transport
        self.sleeper = sleeper
        self.chunkSize = max(1, chunkSize)
        self.maxAttempts = max(1, maxAttempts)
    }

    // MARK: 主入口

    func translate(
        _ texts: [String],
        source: TranslationLanguage,
        target: TranslationLanguage
    ) async throws -> [String] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw TranslationError.missingAPIKey }
        guard !texts.isEmpty else { return [] }

        var results: [String] = []
        results.reserveCapacity(texts.count)
        for chunk in Self.chunks(of: texts, size: chunkSize) {
            let translated = try await translateChunk(chunk, source: source, target: target, key: key)
            results.append(contentsOf: translated)
        }
        guard results.count == texts.count else {
            throw TranslationError.countMismatch(expected: texts.count, got: results.count)
        }
        return results
    }

    /// 把输入切成定长块（保留顺序）。
    static func chunks(of texts: [String], size: Int) -> [[String]] {
        guard size > 0, !texts.isEmpty else { return texts.isEmpty ? [] : [texts] }
        var result: [[String]] = []
        var index = 0
        while index < texts.count {
            let end = min(index + size, texts.count)
            result.append(Array(texts[index..<end]))
            index = end
        }
        return result
    }

    // MARK: 单块

    private func translateChunk(
        _ texts: [String],
        source: TranslationLanguage,
        target: TranslationLanguage,
        key: String
    ) async throws -> [String] {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        let endpoint = trimmed + "/chat/completions"
        // 用项目统一的 URL 校验（只认 http/https 且必须有主机名），
        // 而不是只看 `URL(string:)` 是否返回 nil：新版 Foundation 会把非法字符
        // 百分号编码后照样返回一个相对 URL，那种「看起来成功」的地址发出去只会得到
        // 一个莫名的网络错误。
        guard ModelValidation.isValidURLString(endpoint), let url = URL(string: endpoint) else {
            throw TranslationError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let payload = ChatRequest(
            model: model,
            messages: [
                ChatMessage(role: "system", content: Self.systemPrompt(source: source, target: target)),
                ChatMessage(role: "user", content: Self.userPrompt(texts: texts)),
            ],
            temperature: 1.1,
            stream: false
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let content = try await send(request)
        return try Self.parseTranslations(content, expected: texts.count)
    }

    /// 发送请求（含可重试错误的重试）。
    private func send(_ request: URLRequest) async throws -> String {
        var lastError: TranslationError = .emptyResponse
        for attempt in 0..<maxAttempts {
            do {
                let (data, response) = try await transport.send(request)
                let status = response.statusCode
                guard (200..<300).contains(status) else {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    let error = TranslationError.http(status: status, body: String(body.prefix(300)))
                    lastError = error
                    guard Self.isRetryable(status: status), attempt < maxAttempts - 1 else { throw error }
                    try await sleeper(Self.backoff(attempt: attempt))
                    continue
                }
                guard let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data),
                      let content = decoded.choices.first?.message.content else {
                    throw TranslationError.emptyResponse
                }
                return content
            } catch let error as TranslationError {
                lastError = error
                throw error
            } catch is CancellationError {
                throw TranslationError.cancelled
            } catch {
                // 传输层错误（超时 / 断连）值得再试一次
                lastError = .cloud((error as NSError).localizedDescription)
                guard attempt < maxAttempts - 1 else { throw lastError }
                try await sleeper(Self.backoff(attempt: attempt))
            }
        }
        throw lastError
    }

    static func isRetryable(status: Int) -> Bool {
        status == 408 || status == 429 || (500...599).contains(status)
    }

    static func backoff(attempt: Int) -> TimeInterval {
        min(4, 0.6 * pow(2, Double(max(0, attempt))))
    }

    // MARK: 提示词

    static func systemPrompt(source: TranslationLanguage, target: TranslationLanguage) -> String {
        let sourceHint = source.promptName.isEmpty ? L("translation.prompt.autoSource") : source.promptName
        return """
        你是一名资深的漫画本地化译者。用户会给你一个 JSON 字符串数组，每一项是一段漫画对白或旁白。
        请把每一项翻译成\(target.promptName)。源语言为\(sourceHint)。
        要求：
        1. 严格只输出一个 JSON 字符串数组，长度与顺序和输入完全一致；不要输出解释、标题或 Markdown 代码块。
        2. 译文简洁、口语化，符合漫画对白语气，不要逐字硬译。
        3. 拟声词/语气词翻成自然的目标语言表达。
        """
    }

    static func userPrompt(texts: [String]) -> String {
        let data = (try? JSONEncoder().encode(texts)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    // MARK: 解析

    /// 从模型输出里提取 JSON 字符串数组，并校验条数。
    static func parseTranslations(_ content: String, expected: Int) throws -> [String] {
        let cleaned = stripCodeFences(content)
        guard let start = cleaned.firstIndex(of: "["),
              let end = cleaned.lastIndex(of: "]"),
              start <= end else {
            throw TranslationError.emptyResponse
        }
        let json = String(cleaned[start...end])
        guard let data = json.data(using: .utf8) else {
            throw TranslationError.emptyResponse
        }

        var result: [String]?
        if let strings = try? JSONDecoder().decode([String].self, from: data) {
            result = strings
        } else if let any = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            result = any.map { $0 as? String ?? String(describing: $0) }
        }

        guard let translations = result else { throw TranslationError.emptyResponse }
        guard translations.count == expected else {
            throw TranslationError.countMismatch(expected: expected, got: translations.count)
        }
        return translations
    }

    /// 去掉 ```json ... ``` 代码块围栏。
    static func stripCodeFences(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("```") {
            if let newline = value.firstIndex(of: "\n") {
                value = String(value[value.index(after: newline)...])
            }
            if let range = value.range(of: "```", options: .backwards) {
                value = String(value[..<range.lowerBound])
            }
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - OpenAI 兼容请求 / 响应

private struct ChatMessage: Encodable {
    let role: String
    let content: String
}

private struct ChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let stream: Bool
}

private struct ChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message
    }
    let choices: [Choice]
}
