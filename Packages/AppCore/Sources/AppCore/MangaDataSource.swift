//
//  MangaDataSource.swift
//  AppCore
//
//  统一的数据来源接口。
//
//  为什么要有它：本项目的数据来源不止一种——
//  1. 社区脚本源（JavaScriptCore 沙箱，`SourceRunner`）；
//  2. 用户自建的 Komga / Kavita 服务器（宿主内置的连接器，走 REST API）；
//  3. 以后可能还有别的（局域网目录、其他自建服务…）。
//
//  界面（浏览、搜索、详情、章节、阅读）只认这个协议，
//  于是「数据从哪来」的差异全部落在实现里，加一种来源不需要动界面。
//  这和阅读侧的 `MangaReadingSource` 是同一套思路：
//  能在界面里消失的条件分支，就让它消失。
//
//  注意：协议刻意与 `SourceRunner` 的方法形状一致（同名、同参、
//  同错误语义），这样脚本源只需一层薄适配器即可接上，
//  也不会出现「两个入口对同一件事有不同说法」。
//

import Foundation

/// 统一的数据来源。
public protocol MangaDataSource: Sendable {
    /// 来源标识（与 `Manga.sourceID` 对应）。
    var sourceID: SourceID { get }

    /// 热门列表。`page` 从 1 开始。
    func popularManga(page: Int) async throws -> MangaListPage

    /// 最新更新。`page` 从 1 开始。
    ///
    /// 来源没有「最新」概念时**回退到热门**（而不是报错）：
    /// 界面上少一个 tab 比多一个报错好。
    func latestUpdates(page: Int) async throws -> MangaListPage

    /// 搜索。`page` 从 1 开始。
    func search(page: Int, query: String, filters: SourceFilterValues) async throws -> MangaListPage

    /// 作品详情。
    func mangaDetails(url: String) async throws -> Manga

    /// 章节列表。
    /// - Parameter mangaID: 作品主键；省略时按 `Manga.makeID` 派生。
    func chapterList(mangaURL: String, mangaID: String?) async throws -> [Chapter]

    /// 页列表，返回顺序即阅读顺序。
    func pageList(chapterURL: String) async throws -> [ComicPage]

    /// 筛选项。不支持的来源返回空数组。
    func filters() async throws -> [SourceFilter]
}

public extension MangaDataSource {
    /// 默认没有筛选项：搜索框照常可用。
    func filters() async throws -> [SourceFilter] { [] }

    /// 默认「最新」= 热门。
    func latestUpdates(page: Int) async throws -> MangaListPage {
        try await popularManga(page: page)
    }
}

/// 按来源标识解析数据来源。
///
/// 为什么要「解析」而不是直接持有字典：脚本源的沙箱是**按需载入**的
/// （载入要建 JS 虚拟机，很贵），只能在真正要用的时候才建。
/// 这个协议把「什么时候建」留在实现里。
public protocol MangaDataSourceProviding: Sendable {
    /// - Throws: 来源不存在 / 未安装时抛出实现方的错误。
    func dataSource(for sourceID: SourceID) async throws -> MangaDataSource
}

/// 「连得上吗」的自检。
///
/// 与 `popularManga` 分开：用户填完服务器地址后先要一句「连接成功，N 个书库」，
/// 而不是一屏作品封面——后者在 500 部作品的服务器上要拉好几秒，
/// 也会让人误以为「已经能用了」。
public protocol MangaDataSourceProbing: Sendable {
    /// 做一次最小请求并返回一句描述。
    /// - Throws: 连不上 / 凭据不对时抛错。
    func probe() async throws -> String
}
