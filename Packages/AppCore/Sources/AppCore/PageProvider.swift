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
