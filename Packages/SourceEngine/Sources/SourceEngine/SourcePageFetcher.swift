//
//  SourcePageFetcher.swift
//  SourceEngine
//
//  把「源图片加载」适配成下载队列要的 `PageFetching`。
//
//  为什么要单独一层适配器，而不是让 `DownloadQueue` 直接用 `SourceImageLoader`：
//  `ComicDownload` 不认识「来源」这个概念（它只认 URL 与请求头），
//  而带 Cookie / 防盗链 Referer 是来源侧的知识。适配器就是这两者的接缝，
//  也正因为存在这个接缝，`DownloadQueue` 的测试才能完全离线。
//
//  为什么用 `JobAwarePageFetching` 而不是构造时就绑定来源：
//  队列里可能同时排着**多个来源**的任务（比如书架里 A 站和 B 站各下一话），
//  而队列只有一个 `fetcher`。按任务取来源信息，队列就不必按来源拆成多个实例。
//

import Foundation
import AppCore
import ComicDownload

/// 在线来源的分页抓取器。
///
/// 来源标识与 Referer 都从任务上取（见 `DownloadJob.sourceID` / `DownloadJob.referer`），
/// 因此**一个实例可以服务所有来源**。
public struct SourcePageFetcher: JobAwarePageFetching {

    private let imageLoader: SourceImageLoader

    public init(imageLoader: SourceImageLoader) {
        self.imageLoader = imageLoader
    }

    public func fetchPage(url: String, headers: [String: String], job: DownloadJob) async throws -> Data {
        try await imageLoader.imageData(
            forURL: url,
            sourceID: job.sourceID,
            // 页级请求头优先（契约允许每页自带），其次任务级
            headers: job.headers(forURL: url),
            referer: job.referer
        )
    }

    /// 队列在 fetcher 支持 `JobAwarePageFetching` 时不会走这条路径。
    /// 留着是为了协议完整；真被调到说明调用方漏了任务上下文，
    /// 与其默默发一个不带 Cookie 的请求（多半会拿到登录页），不如直接报错。
    public func fetchPage(url: String, headers: [String: String]) async throws -> Data {
        _ = url
        _ = headers
        throw AppError.invalidInput("在线来源的下载必须带上任务上下文（来源 / Referer）")
    }
}
