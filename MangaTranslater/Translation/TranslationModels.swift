//
//  TranslationModels.swift
//  MangaTranslater
//
//  页内翻译 —— 数据模型与缓存键。
//
//  流程：页图 → Vision OCR（含位置/方向）→ 翻译后端 → 排版合成 → 带译文的整页图。
//
//  与旧工程的差别（《开发手册》附录 B）：
//  - 缓存键从 `(gid, page)` 泛化为 `(sourceID, mangaURL, page)`——本项目没有 gid，
//    作品的稳定标识是「来源 + 作品地址」，阅读器只知道这三样。
//  - 平台图像类型统一为 `UIImage`（只支持 iOS 18+，不再需要 AppKit 分支）。
//

import Foundation
import CoreGraphics
import UIKit
import AppCore
import ComicDownload

// MARK: - 平台图像

/// 平台图像类型。App 只跑 iOS，这里统一到 `UIImage`。
///
/// 保留这个别名而不是到处写 `UIImage`：排版与 OCR 的代码来自跨平台实现，
/// 保留别名可以让「平台相关」只在一处出现。
typealias PlatformImage = UIImage

// MARK: - 识别结果

/// 一行被识别出来的原文（含位置与方向）。
struct MangaTextLine: Identifiable, Sendable, Equatable, Codable {
    let id: UUID
    /// 识别出的原文。
    var text: String
    /// Vision 归一化坐标（原点在**左下角**，取值 0~1）。
    var boundingBox: CGRect
    /// 是否竖排（日漫常见）。
    var isVertical: Bool
    /// Vision 置信度（0~1，用于多策略合并时择优）。
    var confidence: Float

    init(id: UUID = UUID(), text: String, boundingBox: CGRect, isVertical: Bool, confidence: Float = 1) {
        self.id = id
        self.text = text
        self.boundingBox = boundingBox
        self.isVertical = isVertical
        self.confidence = confidence
    }
}

/// 翻译并排版后的一条内容（供渲染层与缓存清单使用）。
struct MangaTranslatedLine: Identifiable, Sendable, Equatable, Codable {
    let id: UUID
    /// 原文。
    var source: String
    /// 译文。
    var translated: String
    /// Vision 归一化坐标（原点左下）。
    var boundingBox: CGRect
    /// 是否竖排。
    var isVertical: Bool

    init(
        id: UUID = UUID(),
        source: String,
        translated: String,
        boundingBox: CGRect,
        isVertical: Bool
    ) {
        self.id = id
        self.source = source
        self.translated = translated
        self.boundingBox = boundingBox
        self.isVertical = isVertical
    }
}

// MARK: - 阶段

/// 翻译阶段 —— 驱动阅读器里的进度浮层。
enum TranslationStage: Equatable, Sendable {
    case idle
    case recognizing
    case translating
    case rendering
    case done
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .recognizing, .translating, .rendering: return true
        case .idle, .done, .failed: return false
        }
    }

    var label: String {
        switch self {
        case .idle: return ""
        case .recognizing: return L("translation.stage.recognizing")
        case .translating: return L("translation.stage.translating")
        case .rendering: return L("translation.stage.rendering")
        case .done: return L("translation.stage.done")
        case .failed(let message): return message
        }
    }
}

// MARK: - 一页的结果

/// 一次页翻译的结果。
struct PageTranslation {
    /// 渲染好的、带译文的整页图。
    var image: PlatformImage
    /// 每条译文（缓存清单 / 导出 / 调试用）。
    var lines: [MangaTranslatedLine]
}

// MARK: - 缓存键

/// 译文缓存键：**来源 + 作品地址 + 页号**。
///
/// 为什么不用 `Manga.id`：`Manga.id` 就是 `<sourceID>|<url>`，
/// 展开成三段可以避免「先把 id 拆开再比较」这种容易出错的写法，
/// 也让缓存清单文件里的字段名自带含义、便于人工排查。
struct PageTranslationKey: Hashable, Sendable, CustomStringConvertible {
    let sourceID: SourceID
    let mangaURL: String
    /// 从 0 开始的页序号。
    let page: Int

    init(sourceID: SourceID, mangaURL: String, page: Int) {
        self.sourceID = sourceID
        self.mangaURL = mangaURL
        self.page = max(0, page)
    }

    /// 由作品与页号构造（阅读器只拿得到这两样）。
    init(manga: Manga, page: Int) {
        self.init(sourceID: manga.sourceID, mangaURL: manga.url, page: page)
    }

    var description: String {
        "\(sourceID.rawValue)|\(mangaURL)|\(page)"
    }

    /// 译文缓存目录名（作品粒度）。
    ///
    /// 主键里含 `/` 与 `:`（因为含 URL），直接当目录名会有路径穿越风险；
    /// 统一走 `FileNameSanitizer`（可读部分 + 稳定哈希）转成安全片段。
    ///
    /// 缓存按「作品一个目录、页号作文件名」组织，于是「删掉某作品的译文」
    /// 就是删一个目录，不需要扫描全部文件再逐个比对主键。
    var mangaStem: String {
        FileNameSanitizer.segment("\(sourceID.rawValue)|\(mangaURL)")
    }

    /// 页在缓存目录里的文件名（不含扩展名）。
    var pageFileName: String {
        String(page)
    }
}
