//
//  CloudTranslationService.swift
//  MangaTranslater
//
//  云服务翻译后端：把 `MangaTranslator` 接到云代理上。
//
//  这层薄适配负责三件事：
//  1. **分块**（与自备密钥后端共用 `TranslationChunking`），避免一次请求过大；
//  2. **错误翻译**：把 `CloudError` 映射成 `TranslationError`，
//     于是编排器/界面只认识一套错误语义，不必分别处理「HTTP 401」和「未登录」；
//  3. **额度回传**：服务端每次都会带上「今天还剩几页」，这里回调给账号模型，
//     界面就能实时更新额度，而不必再发一次 `/me`。
//
//  额度用尽时**不在这里重试、也不降级到别的后端**：换后端意味着把用户的原文
//  悄悄发给另一个服务，这是用户没有同意的数据流向。额度问题由界面提示，
//  由用户决定是升级还是改用自备密钥。
//

import Foundation
import AppCore

struct CloudTranslationService: MangaTranslator {

    let client: CloudServiceClient
    let token: String

    private let chunkSize: Int
    /// 每次翻译后回传今天的剩余页数。
    private let onRemaining: @Sendable (Int) -> Void

    init(
        client: CloudServiceClient,
        token: String,
        chunkSize: Int = TranslationChunking.defaultSize,
        onRemaining: @escaping @Sendable (Int) -> Void = { _ in }
    ) {
        self.client = client
        self.token = token
        self.chunkSize = max(1, chunkSize)
        self.onRemaining = onRemaining
    }

    func translate(
        _ texts: [String],
        source: TranslationLanguage,
        target: TranslationLanguage
    ) async throws -> [String] {
        guard !texts.isEmpty else { return [] }

        var results: [String] = []
        results.reserveCapacity(texts.count)
        for chunk in TranslationChunking.chunks(of: texts, size: chunkSize) {
            do {
                let result = try await client.translate(
                    lines: chunk,
                    source: source,
                    target: target,
                    token: token
                )
                guard result.lines.count == chunk.count else {
                    throw TranslationError.countMismatch(expected: chunk.count, got: result.lines.count)
                }
                onRemaining(result.remainingToday)
                results.append(contentsOf: result.lines)
            } catch let error as CloudError {
                throw error.asTranslationError
            } catch let error as TranslationError {
                throw error
            } catch {
                throw TranslationError.cloud(error.localizedDescription)
            }
        }
        return results
    }
}
