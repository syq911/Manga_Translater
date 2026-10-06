//
//  RuntimeDataSource.swift
//  SourceEngine
//
//  把「运行时池 + 某个源」适配成统一的 `MangaDataSource`。
//
//  这一层薄得几乎没有逻辑，但它值钱的地方在于**边界**：
//  池负责租约 / 载入复用 / 淘汰 / 回收，适配器只负责把一次调用的
//  租约范围圈对（`withRunner` 的闭包结束时归还）。
//  如果让界面直接用池，每个调用点都要自己记得「用完要还」，
//  漏一个就会让沙箱永远不被淘汰。
//

import Foundation
import AppCore

/// 由运行时池支撑的数据来源（社区脚本源）。
public struct RuntimeDataSource: MangaDataSource {

    private let pool: SourceRuntimePool
    public let sourceID: SourceID

    public init(pool: SourceRuntimePool, sourceID: SourceID) {
        self.pool = pool
        self.sourceID = sourceID
    }

    private var key: String { sourceID.rawValue }

    public func popularManga(page: Int) async throws -> MangaListPage {
        try await pool.withRunner(for: key) { try await $0.popularManga(page: page) }
    }

    public func latestUpdates(page: Int) async throws -> MangaListPage {
        try await pool.withRunner(for: key) { try await $0.latestUpdates(page: page) }
    }

    public func search(
        page: Int,
        query: String,
        filters: SourceFilterValues
    ) async throws -> MangaListPage {
        try await pool.withRunner(for: key) {
            try await $0.search(page: page, query: query, filters: filters)
        }
    }

    public func mangaDetails(url: String) async throws -> Manga {
        try await pool.withRunner(for: key) { try await $0.mangaDetails(url: url) }
    }

    public func chapterList(mangaURL: String, mangaID: String?) async throws -> [Chapter] {
        try await pool.withRunner(for: key) {
            try await $0.chapterList(mangaURL: mangaURL, mangaID: mangaID)
        }
    }

    public func pageList(chapterURL: String) async throws -> [ComicPage] {
        try await pool.withRunner(for: key) { try await $0.pageList(chapterURL: chapterURL) }
    }

    public func filters() async throws -> [SourceFilter] {
        try await pool.withRunner(for: key) { try await $0.filters() }
    }
}

extension SourceRuntimePool: MangaDataSourceProviding {
    /// 为某个已安装的源建一个数据来源。
    ///
    /// 这里**不预先载入**脚本：`RuntimeDataSource` 的每个方法内部才 `withRunner`，
    /// 于是「只是渲染一下来源列表」不会把一堆 JS 虚拟机拉起来。
    public func dataSource(for sourceID: SourceID) async throws -> MangaDataSource {
        guard store.isInstalled(sourceID.rawValue) else {
            throw SourceRunnerError.notInstalled(sourceID.rawValue)
        }
        return RuntimeDataSource(pool: self, sourceID: sourceID)
    }
}
