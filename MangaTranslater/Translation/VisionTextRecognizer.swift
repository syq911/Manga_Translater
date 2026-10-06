//
//  VisionTextRecognizer.swift
//  MangaTranslater
//
//  Apple Vision OCR —— 输出带位置与竖/横排方向的文本行。
//
//  策略：**原图直接识别**，并把两套 Vision 文本 API 的结果合并去重：
//  1. 现代 Swift API `RecognizeTextRequest`（iOS 18+，与系统「实况文本」同源）
//     —— 开启自动语言检测，最接近系统原生识别效果；
//  2. 传统 `VNRecognizeTextRequest`（指定语言），作为补充。
//
//  不做放大 / 分块 / 缩放等重采样：放大只是插值、不会增加真实细节，分块会把整行切在
//  块边界并丢失整页版式上下文。两套 API 都直接吃原始位图，合并只增加召回、不覆盖彼此结果。
//
//  唯一的例外是可选的「漏行兜底」：某些系统版本上 Vision 有已知的整页漏行回归，
//  当合并后命中过少时，把整页横向压扁重试一次并合并。该步骤可在设置中关闭。
//
//  并发硬约束：现代 Vision API 超过 2 个并行会死锁，调用方（TranslationController）
//  必须把并行度限制在 2 以内。
//

import Foundation
import Vision
import CoreGraphics
import ImageIO
import AppCore

/// OCR 能力抽象。
///
/// 存在的理由是可测性：编排器（`TranslationController`）要单独验证
/// 「队列 / 进度 / 缓存 / 额度降级」这些规则，不该被迫跑真实 Vision
/// （慢，且识别结果随系统版本浮动）。生产实现就是 `VisionTextRecognizer`。
protocol TextRecognizing: Sendable {
    /// 识别一页里的文本行。
    func recognizeLines(in cgImage: CGImage) async throws -> [MangaTextLine]
}

struct VisionTextRecognizer {

    /// 识别语言（BCP-47，如 "ja-JP" / "zh-Hans"）。
    var languages: [String]
    /// 语言纠错。中日文必须开启，否则可能零观测。
    var usesLanguageCorrection: Bool = true
    /// 合并后命中行数低于该值时，可选触发「漏行兜底」。
    var lineDropFallbackThreshold: Int = 3
    /// 是否启用漏行兜底。
    var usesLineDropFallback: Bool = true

    /// 兜底用的通用多语言集合。
    static let broadLanguages = ["ja-JP", "zh-Hans", "zh-Hant", "en-US"]
    /// 合并去重的 IoU 阈值。
    static let mergeIoU: CGFloat = 0.4

    // MARK: 主入口

    func recognize(
        in cgImage: CGImage,
        orientation: CGImagePropertyOrientation = .up
    ) async throws -> [MangaTextLine] {
        let pageAspect = CGFloat(cgImage.width) / CGFloat(max(1, cgImage.height))
        diag("翻译/OCR: 原图直出 \(cgImage.width)x\(cgImage.height) 语言=\(languages) 兜底=\(usesLineDropFallback)")

        var groups: [[MangaTextLine]] = []
        var firstError: Error?
        var sawSuccess = false

        // 1) 现代 Vision API，自动检测语言
        do {
            let lines = try await runModern(on: cgImage, pageAspect: pageAspect)
            sawSuccess = true
            diag("翻译/OCR[现代API·自动语言] → 行=\(lines.count)")
            groups.append(lines)
        } catch {
            if firstError == nil { firstError = error }
            diag("翻译/OCR[现代API] 抛错 —— \(error)")
        }

        // 2) 传统 Vision API，指定语言
        do {
            let lines = try runLegacy(
                on: cgImage,
                languages: languages,
                pageAspect: pageAspect,
                orientation: orientation
            )
            sawSuccess = true
            diag("翻译/OCR[传统API·\(languages)] → 行=\(lines.count)")
            groups.append(lines)
        } catch {
            if firstError == nil { firstError = error }
            diag("翻译/OCR[传统API] 抛错 —— \(error)")
        }

        // 2b) 传统 Vision API，不指定语言（沿用系统偏好语言）
        do {
            let lines = try runLegacy(
                on: cgImage,
                languages: nil,
                pageAspect: pageAspect,
                orientation: orientation
            )
            sawSuccess = true
            diag("翻译/OCR[传统API·系统语言] → 行=\(lines.count)")
            groups.append(lines)
        } catch {
            if firstError == nil { firstError = error }
            diag("翻译/OCR[传统API·系统语言] 抛错 —— \(error)")
        }

        // 3) 指定语言为空时补一次通用多语言（传统 API）
        if groups.flatMap({ $0 }).isEmpty, languages != Self.broadLanguages {
            do {
                let lines = try runLegacy(
                    on: cgImage,
                    languages: Self.broadLanguages,
                    pageAspect: pageAspect,
                    orientation: orientation
                )
                sawSuccess = true
                diag("翻译/OCR[传统API·多语言] → 行=\(lines.count)")
                groups.append(lines)
            } catch {
                if firstError == nil { firstError = error }
                diag("翻译/OCR[传统API·多语言] 抛错 —— \(error)")
            }
        }

        var merged = Self.merge(groups)
        diag("翻译/OCR: 合并去重 → 行=\(merged.count) 示例=\(merged.prefix(4).map(\.text))")

        // 4) 漏行兜底：仅在命中过少时触发，且与现有结果合并
        if usesLineDropFallback, merged.count < lineDropFallbackThreshold,
           let squashed = Self.squashHorizontally(cgImage, factor: 0.8) {
            do {
                let lines = try runLegacy(
                    on: squashed,
                    languages: languages,
                    pageAspect: pageAspect,
                    orientation: orientation
                )
                diag("翻译/OCR[压扁0.8兜底] → 行=\(lines.count)")
                merged = Self.merge([merged, lines])
            } catch {
                diag("翻译/OCR[压扁0.8兜底] 抛错 —— \(error)")
            }
        }

        if merged.isEmpty, !sawSuccess, let firstError { throw firstError }
        return merged
    }

    // MARK: - 现代 Vision API（iOS 18+）

    private func runModern(on image: CGImage, pageAspect: CGFloat) async throws -> [MangaTextLine] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = usesLanguageCorrection
        request.automaticallyDetectsLanguage = true

        let observations = try await request.perform(on: image)
        var lines: [MangaTextLine] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let box = observation.boundingBox.cgRect   // 归一化，原点左下
            guard box.width > 0, box.height > 0 else { continue }
            let vertical = Self.isVertical(box: box, text: text, pageAspect: pageAspect)
            lines.append(MangaTextLine(
                text: text,
                boundingBox: box,
                isVertical: vertical,
                confidence: Float(candidate.confidence)
            ))
        }
        return lines
    }

    // MARK: - 传统 Vision API

    private func runLegacy(
        on image: CGImage,
        languages: [String]?,
        pageAspect: CGFloat,
        orientation: CGImagePropertyOrientation
    ) throws -> [MangaTextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        if let languages, !languages.isEmpty {
            request.recognitionLanguages = languages
        }
        request.usesLanguageCorrection = usesLanguageCorrection

        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        try handler.perform([request])
        return Self.lines(from: request.results ?? [], pageAspect: pageAspect)
    }

    /// 漏行兜底专用：把整页按横向系数压扁（纯缩放，归一化坐标不变，无需回映射）。
    static func squashHorizontally(_ cgImage: CGImage, factor: CGFloat) -> CGImage? {
        let outW = max(1, Int((CGFloat(cgImage.width) * factor).rounded()))
        let outH = max(1, cgImage.height)
        guard let context = CGContext(
            data: nil,
            width: outW,
            height: outH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        return context.makeImage()
    }

    // MARK: - 观测 → 文本行

    static func lines(
        from observations: [VNRecognizedTextObservation],
        pageAspect: CGFloat
    ) -> [MangaTextLine] {
        var lines: [MangaTextLine] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let box = observation.boundingBox   // 归一化，原点左下
            guard box.width > 0, box.height > 0 else { continue }
            let vertical = isVertical(box: box, text: text, pageAspect: pageAspect)
            lines.append(MangaTextLine(
                text: text,
                boundingBox: box,
                isVertical: vertical,
                confidence: candidate.confidence
            ))
        }
        return lines
    }

    /// 判定竖排：把归一化包围盒换算成**像素纵横比**再比较（页面非正方时修正）。
    /// 单字符无法判断方向，按横排处理。
    static func isVertical(box: CGRect, text: String, pageAspect: CGFloat = 1) -> Bool {
        guard box.width > 0, box.height > 0, text.count > 1 else { return false }
        // 像素高/宽 = (box.height/box.width) / pageAspect，其中 pageAspect = W/H
        return box.height > box.width * 1.6 * max(0.05, pageAspect)
    }

    // MARK: - 合并（纯逻辑，可单测）

    /// 合并多次识别结果：IoU 超阈值视为同一行，保留置信度更高 / 更长的那条。
    static func merge(_ groups: [[MangaTextLine]]) -> [MangaTextLine] {
        var result: [MangaTextLine] = []
        for line in groups.flatMap({ $0 }) {
            if let index = result.firstIndex(where: { iou($0.boundingBox, line.boundingBox) >= mergeIoU }) {
                let existing = result[index]
                let better = line.confidence > existing.confidence
                    || (line.confidence == existing.confidence && line.text.count > existing.text.count)
                if better { result[index] = line }
            } else {
                result.append(line)
            }
        }
        return result
    }

    static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let interArea = inter.width * inter.height
        let union = a.width * a.height + b.width * b.height - interArea
        return union > 0 ? interArea / union : 0
    }
}

/// 让排版方向（`orientation` 有默认值）不影响协议匹配：
/// 默认参数不算重载，必须显式写一个只有一个参数的同名方法来满足协议。
extension VisionTextRecognizer: TextRecognizing {
    func recognizeLines(in cgImage: CGImage) async throws -> [MangaTextLine] {
        try await recognize(in: cgImage, orientation: .up)
    }
}
