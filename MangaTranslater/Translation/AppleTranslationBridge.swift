//
//  AppleTranslationBridge.swift
//  MangaTranslater
//
//  Apple 端上翻译（iOS 18+ 的 Translation 框架）—— 免费、无需配置。
//
//  框架的 `TranslationSession` 只能由 SwiftUI 的 `.translationTask` 提供，
//  因此这里持有「待翻译文本 + 结果 continuation」，由视图侧用 `.translationTask` 消费：
//  编排器 `await bridge.translate(...)` → 本类设置 `configuration` 触发视图修饰符
//  → 视图调用 `run(session:)` → continuation 回填结果。
//
//  已知约束（据此定并行度）：同一时刻只支持一个会话，因此端上翻译时并行度必须为 1。
//

import Foundation
import Observation
import Translation
import AppCore

@available(iOS 18.0, *)
@MainActor
@Observable
final class AppleTranslationBridge {

    /// 供视图绑定：非 nil 时触发 `.translationTask`。
    var configuration: TranslationSession.Configuration?

    @ObservationIgnored private var pendingTexts: [String] = []
    @ObservationIgnored private var continuation: CheckedContinuation<[String], Error>?

    /// 触发一次 Apple 端上翻译。
    func translate(
        _ texts: [String],
        source: TranslationLanguage,
        target: TranslationLanguage
    ) async throws -> [String] {
        guard !texts.isEmpty else { return [] }
        guard continuation == nil else { throw TranslationError.cancelled }
        return try await withCheckedThrowingContinuation { cont in
            self.pendingTexts = texts
            self.continuation = cont
            let sourceLanguage = Self.localeLanguage(for: source)
            let targetLanguage = Locale.Language(identifier: target.rawValue)
            self.configuration = TranslationSession.Configuration(source: sourceLanguage, target: targetLanguage)
        }
    }

    /// 由视图的 `.translationTask` 调用。
    func run(session: TranslationSession) async {
        guard let pending = continuation else { return }
        continuation = nil
        let texts = pendingTexts
        pendingTexts = []
        configuration = nil
        do {
            var results: [String] = []
            results.reserveCapacity(texts.count)
            for text in texts {
                let response = try await session.translate(text)
                results.append(response.targetText)
            }
            pending.resume(returning: results)
        } catch {
            pending.resume(throwing: error)
        }
    }

    /// 用户取消了本次翻译（例如退出阅读器）。
    func cancel() {
        guard let pending = continuation else { return }
        continuation = nil
        pendingTexts = []
        configuration = nil
        pending.resume(throwing: TranslationError.cancelled)
    }

    static func localeLanguage(for source: TranslationLanguage) -> Locale.Language? {
        switch source {
        case .auto: return nil
        case .japanese: return Locale.Language(identifier: "ja")
        case .english: return Locale.Language(identifier: "en")
        case .simplifiedChinese: return Locale.Language(identifier: "zh-Hans")
        case .traditionalChinese: return Locale.Language(identifier: "zh-Hant")
        case .korean: return Locale.Language(identifier: "ko")
        }
    }
}
