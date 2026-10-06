//
//  SourceBrowseModel.swift
//  MangaTranslater
//
//  某个来源的作品列表状态机（热门 / 搜索 / 翻页）。
//
//  为什么把逻辑从视图里抽出来：这段逻辑踩的坑全是「状态」问题
//  （重复触发、翻页追加、失败保留已有列表、末页不再请求），
//  放在视图里只能用眼睛看；抽成 `@Observable` 类就能直接写单元测试。
//
//  与来源执行层的耦合通过 `Loader` 闭包注入：视图传入「用运行时池跑一次
//  getPopularManga / getSearchManga」，测试传入脚本化的假实现——
//  这里不需要知道 JavaScriptCore 的存在。
//

import Foundation
import Observation
import AppCore
import SourceEngine

@MainActor
@Observable
final class SourceBrowseModel {

    /// 一次「取第 N 页」的调用（页码从 1 开始）。
    typealias Loader = @Sendable (Int) async throws -> MangaListPage

    /// 列表状态。
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var items: [Manga] = []
    private(set) var hasNextPage = false
    /// 已加载到第几页（0 表示还没加载过）。
    private(set) var loadedPage = 0
    /// 正在追加下一页（用于底部加载指示，不影响 `phase`）。
    private(set) var isLoadingMore = false

    private let load: Loader

    init(loader: @escaping Loader) {
        self.load = loader
    }

    /// 加载完成但一条都没有。
    var isEmpty: Bool {
        phase == .loaded && items.isEmpty
    }

    /// 失败原因（供界面展示）。
    var failureMessage: String? {
        if case let .failed(message) = phase { return message }
        return nil
    }

    // MARK: 行为

    /// 首次加载 / 重新加载（清空现有列表）。
    func loadFirstPage() async {
        // 已经有一页数据时不重复加载，避免每次回到界面都闪一下
        guard phase == .idle || failureMessage != nil else { return }
        await perform(page: 1, reset: true)
    }

    /// 强制重新加载（下拉刷新）。
    func refresh() async {
        await perform(page: 1, reset: true)
    }

    /// 追加下一页；没有下一页或正在加载时不做任何事。
    func loadNextPage() async {
        guard hasNextPage, !isLoadingMore, phase != .loading else { return }
        await perform(page: loadedPage + 1, reset: false)
    }

    private func perform(page targetPage: Int, reset: Bool) async {
        if reset {
            phase = .loading
        } else {
            isLoadingMore = true
        }
        defer { isLoadingMore = false }

        do {
            let result = try await load(targetPage)
            if reset {
                items = result.items
            } else {
                items.append(contentsOf: result.items)
            }
            loadedPage = targetPage
            hasNextPage = result.hasNextPage
            phase = .loaded
        } catch {
            // 失败**不清空**已有列表：翻页失败时把用户已经看到的内容抹掉，
            // 比直接提示失败更让人恼火。
            phase = .failed(Self.message(for: error))
        }
    }

    /// 把底层错误转成给人看的文案。
    static func message(for error: Error) -> String {
        if let runnerError = error as? SourceRunnerError { return runnerError.message }
        return error.localizedDescription
    }
}
