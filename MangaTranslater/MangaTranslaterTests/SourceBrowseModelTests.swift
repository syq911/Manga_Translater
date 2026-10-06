//
//  SourceBrowseModelTests.swift
//  MangaTranslaterTests
//
//  `SourceBrowseModel`（来源浏览列表状态机）的单元测试。
//
//  为什么值得测：这段逻辑的缺陷都是「状态」层面的——重复请求、
//  翻页把第一页覆盖掉、失败时把已经看到的内容清空。
//  用脚本化加载器把每种时序摆出来，比在模拟器上滑列表可靠得多。
//

import Testing
import Foundation
import AppCore
@testable import SourceEngine
@testable import MangaTranslater

// MARK: - 工具

/// 线程安全的请求记录器。
final class PageRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var pages: [Int] = []

    var requestedPages: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return pages
    }

    func record(_ page: Int) {
        lock.lock()
        pages.append(page)
        lock.unlock()
    }
}

/// 构造一页假数据。
///
/// 放在文件作用域（而不是 suite 的方法）是刻意的：suite 是 `@MainActor` 隔离的，
/// 而加载器闭包是 `@Sendable` 非隔离闭包，在里面调 suite 的方法会报隔离错误。
private func makePage(_ titles: [String], hasNextPage: Bool) -> MangaListPage {
    let items = titles.map { title in
        Manga(sourceID: SourceID("demo"), url: "/m/\(title)", title: title)
    }
    return MangaListPage(items: items, hasNextPage: hasNextPage)
}

@Suite("来源浏览模型")
@MainActor
struct SourceBrowseModelTests {

    private func makeModel(
        recorder: PageRequestRecorder = PageRequestRecorder(),
        delayNanoseconds: UInt64 = 0,
        respond: @escaping @Sendable (Int) throws -> MangaListPage
    ) -> SourceBrowseModel {
        SourceBrowseModel { page in
            recorder.record(page)
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            return try respond(page)
        }
    }

    // MARK: 正常路径

    @Test("首次加载：填入列表并进入已加载状态")
    func loadsFirstPage() async {
        let recorder = PageRequestRecorder()
        let model = makeModel(recorder: recorder) { _ in
            makePage(["A", "B"], hasNextPage: true)
        }

        #expect(model.phase == .idle)
        await model.loadFirstPage()

        #expect(model.phase == .loaded)
        #expect(model.items.map(\.title) == ["A", "B"])
        #expect(model.hasNextPage)
        #expect(model.loadedPage == 1)
        #expect(recorder.requestedPages == [1])
        #expect(model.isEmpty == false)
    }

    @Test("翻页：追加到列表末尾而不是覆盖")
    func appendsNextPage() async {
        let recorder = PageRequestRecorder()
        let model = makeModel(recorder: recorder) { page in
            page == 1
                ? makePage(["A", "B"], hasNextPage: true)
                : makePage(["C"], hasNextPage: false)
        }

        await model.loadFirstPage()
        await model.loadNextPage()

        #expect(model.items.map(\.title) == ["A", "B", "C"])
        #expect(model.loadedPage == 2)
        #expect(model.hasNextPage == false)
        #expect(recorder.requestedPages == [1, 2])
    }

    @Test("末页之后不再请求下一页")
    func stopsAtLastPage() async {
        let recorder = PageRequestRecorder()
        let model = makeModel(recorder: recorder) { _ in
            makePage(["A"], hasNextPage: false)
        }

        await model.loadFirstPage()
        await model.loadNextPage()
        await model.loadNextPage()

        #expect(recorder.requestedPages == [1])
    }

    @Test("加载完成后重复调用 loadFirstPage 不会重复请求")
    func doesNotReloadWhenAlreadyLoaded() async {
        let recorder = PageRequestRecorder()
        let model = makeModel(recorder: recorder) { _ in
            makePage(["A"], hasNextPage: false)
        }

        await model.loadFirstPage()
        await model.loadFirstPage()

        #expect(recorder.requestedPages == [1])
    }

    @Test("refresh 强制重新加载")
    func refreshReloads() async {
        let recorder = PageRequestRecorder()
        let model = makeModel(recorder: recorder) { _ in
            makePage(["A"], hasNextPage: true)
        }

        await model.loadFirstPage()
        await model.refresh()

        #expect(recorder.requestedPages == [1, 1])
        #expect(model.items.count == 1)
        #expect(model.loadedPage == 1)
    }

    @Test("空结果是合法结果，不算失败")
    func treatsEmptyAsLoaded() async {
        let model = makeModel { _ in makePage([], hasNextPage: false) }
        await model.loadFirstPage()

        #expect(model.phase == .loaded)
        #expect(model.isEmpty)
    }

    // MARK: 失败路径

    @Test("首屏失败：进入失败态并给出原因")
    func reportsFirstPageFailure() async {
        let model = makeModel { _ in
            throw SourceRunnerError.executionTimeout(seconds: 10)
        }
        await model.loadFirstPage()

        #expect(model.failureMessage == SourceRunnerError.executionTimeout(seconds: 10).message)
        #expect(model.items.isEmpty)
        // 失败后允许再次尝试
        await model.loadFirstPage()
    }

    @Test("翻页失败：保留已经看到的内容")
    func keepsItemsWhenPagingFails() async {
        let model = makeModel { page in
            if page == 1 { return makePage(["A", "B"], hasNextPage: true) }
            throw SourceRunnerError.invalidResponse("第二页结构不合法")
        }

        await model.loadFirstPage()
        await model.loadNextPage()

        #expect(model.items.map(\.title) == ["A", "B"])
        #expect(model.failureMessage != nil)
        #expect(model.loadedPage == 1)
    }

    // MARK: 并发

    @Test("并发触发只发一次请求")
    func deduplicatesConcurrentLoads() async {
        let recorder = PageRequestRecorder()
        let model = makeModel(recorder: recorder, delayNanoseconds: 30_000_000) { _ in
            makePage(["A"], hasNextPage: false)
        }

        async let first: Void = model.loadFirstPage()
        async let second: Void = model.loadFirstPage()
        _ = await (first, second)

        #expect(recorder.requestedPages == [1])
        #expect(model.items.count == 1)
    }

    @Test("错误文案优先用源错误自己的 message")
    func mapsRunnerErrorMessages() {
        #expect(
            SourceBrowseModel.message(for: SourceRunnerError.notInstalled("demo"))
                == SourceRunnerError.notInstalled("demo").message
        )
        #expect(SourceBrowseModel.message(for: SourceImageError.emptyResponse).isEmpty == false)
    }
}
