//
//  PageProvider.swift
//  AppCore
//
//  页数据来源抽象。
//
//  为什么放在 AppCore：阅读器只关心「给我第 N 页的图片数据」，
//  不关心它是从本地归档解出来的，还是从网络下载的。
//  于是本地文件源与在线源各自实现这一个协议，阅读器零分支。
//

import Foundation

/// 页数据提供者。
public protocol PageDataProviding: Sendable {
    /// 取得一页的图片数据。
    /// - Parameters:
    ///   - page: 页描述（含 `imageURL` 定位信息与可选请求头）。
    ///   - manga: 所属作品。
    ///   - chapter: 所属章节。
    /// - Throws: 实现方各自的错误；调用方应能容忍单页失败（跳过该页并提示）。
    func imageData(for page: ComicPage, manga: Manga, chapter: Chapter) async throws -> Data
}

/// 章节与页列表的提供者。
///
/// 与 `PageDataProviding` 分开是为了让「只需要图片字节」的场景（例如预先下载）
/// 不必依赖章节列表的实现。
public protocol ChapterListProviding: Sendable {
    /// 取作品的章节列表（顺序即来源给出的顺序，宿主不重排）。
    func chapters(for manga: Manga) async throws -> [Chapter]

    /// 取某一章的页列表（顺序即阅读顺序）。
    func pages(for chapter: Chapter, manga: Manga) async throws -> [ComicPage]
}

/// 阅读器需要的全部数据来源。
///
/// 阅读器只依赖这一个协议：本地文件源与在线来源各自实现，
/// 于是「翻页、预加载、进度保存」这些规则对两者完全相同，
/// 阅读器里没有任何 `if 是本地 / 如果是在线` 的分支。
public protocol MangaReadingSource: ChapterListProviding, PageDataProviding {}
