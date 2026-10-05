//
//  ReaderSessionTests.swift
//  MangaTranslaterTests
//
//  阅读器内核（AppCore.ReaderSession）测试：翻页边界、章末/章首跳转、
//  空章节、预加载窗口、进度标记。
//
//  这些规则全是 off-by-one 高发区，必须在值类型层面钉死；
//  SwiftUI 视图里没有分支逻辑（视图只把结果画出来）。
//

import Testing
import Foundation
import AppCore

@Suite("阅读器内核")
struct ReaderSessionTests {

    private func makeManga() -> Manga {
        Manga(sourceID: .local, url: "LocalLibrary/a-1234abcd.cbz", title: "测试作品")
    }

    private func makeChapters(_ count: Int) -> [Chapter] {
        let manga = makeManga()
        return (0..<count).map { index in
            Chapter(mangaID: manga.id, url: "LocalLibrary/a-1234abcd.cbz#ch\(index)", name: "第 \(index + 1) 话")
        }
    }

    private func makeSession(chapterCount: Int = 3, chapterIndex: Int = 0, pageIndex: Int = 0) -> ReaderSession {
        ReaderSession(
            manga: makeManga(),
            chapters: makeChapters(chapterCount),
            chapterIndex: chapterIndex,
            pageIndex: pageIndex
        )
    }

    // MARK: 初始化与状态

    @Test("初始化钳制越界的章节下标")
    func clampsInitialChapterIndex() {
        #expect(makeSession(chapterCount: 3, chapterIndex: 99).chapterIndex == 2)
        #expect(makeSession(chapterCount: 3, chapterIndex: -5).chapterIndex == 0)
    }

    @Test("初始化钳制负页码")
    func clampsInitialPageIndex() {
        #expect(makeSession(pageIndex: -3).pageIndex == 0)
    }

    @Test("空章节列表：无当前章且不能换章")
    func handlesEmptyChapterList() {
        let session = makeSession(chapterCount: 0)
        #expect(session.chapterCount == 0)
        #expect(session.currentChapter == nil)
        #expect(session.hasNextChapter == false)
        #expect(session.hasPreviousChapter == false)
        #expect(session.progressMark == nil)
        #expect(session.isAtEnd(pageCount: 0))
    }

    @Test("当前章与前后章判断")
    func reportsChapterNeighbours() {
        let first = makeSession(chapterCount: 3, chapterIndex: 0)
        #expect(first.currentChapter?.name == "第 1 话")
        #expect(!first.hasPreviousChapter)
        #expect(first.hasNextChapter)

        let last = makeSession(chapterCount: 3, chapterIndex: 2)
        #expect(last.currentChapter?.name == "第 3 话")
        #expect(last.hasPreviousChapter)
        #expect(!last.hasNextChapter)
    }

    @Test("进度标记反映当前章节与页码")
    func exposesProgressMark() {
        let session = makeSession(chapterCount: 2, chapterIndex: 1, pageIndex: 4)
        let mark = session.progressMark
        #expect(mark?.chapterID == makeChapters(2)[1].id)
        #expect(mark?.pageIndex == 4)
    }

    // MARK: 页内移动

    @Test("moveToPage 会钳制到合法范围")
    func moveToPageClamps() {
        var session = makeSession(pageIndex: 2)
        // 先调用（mutating），再断言：`#expect` 的闭包会把变量变成不可变
        let outcome1 = session.moveToPage(5, pageCount: 10)
        #expect(outcome1)
        #expect(session.pageIndex == 5)

        // 先调用（mutating），再断言：`#expect` 的闭包会把变量变成不可变
        let outcome2 = session.moveToPage(999, pageCount: 10)
        #expect(outcome2)
        #expect(session.pageIndex == 9)

        // 先调用（mutating），再断言：`#expect` 的闭包会把变量变成不可变
        let outcome3 = session.moveToPage(-4, pageCount: 10)
        #expect(outcome3)
        #expect(session.pageIndex == 0)
    }

    @Test("moveToPage 目标与当前一致时返回 false")
    func moveToSamePageDoesNothing() {
        var session = makeSession(pageIndex: 3)
        // 先调用（mutating），再断言：`#expect` 的闭包会把变量变成不可变
        let outcome4 = session.moveToPage(3, pageCount: 10)
        #expect(!outcome4)
    }

    @Test("pageCount 为 0 时 moveToPage 不越界")
    func moveToPageWithEmptyChapter() {
        var session = makeSession(pageIndex: 0)
        // 先调用（mutating），再断言：`#expect` 的闭包会把变量变成不可变
        let outcome5 = session.moveToPage(3, pageCount: 0)
        #expect(!outcome5)
        #expect(session.pageIndex == 0)
    }

    @Test("moveToLastPage 跳到末页")
    func movesToLastPage() {
        var session = makeSession(pageIndex: 0)
        // 先调用（mutating），再断言：`#expect` 的闭包会把变量变成不可变
        let outcome6 = session.moveToLastPage(pageCount: 7)
        #expect(outcome6)
        #expect(session.pageIndex == 6)
    }

    // MARK: 前进

    @Test("章内前进逐页移动")
    func advancesWithinChapter() {
        var session = makeSession(pageIndex: 0)
        // 先调用（mutating），再断言：`#expect` 的闭包会把变量变成不可变
        let outcome7 = session.advanceForward(pageCount: 3) == .moved(toPage: 1)
        #expect(outcome7)
        // 先调用（mutating），再断言：`#expect` 的闭包会把变量变成不可变
        let outcome8 = session.advanceForward(pageCount: 3) == .moved(toPage: 2)
        #expect(outcome8)
    }

    @Test("章末前进请求下一章")
    func requestsNextChapterAtChapterEnd() {
        var session = makeSession(chapterCount: 3, chapterIndex: 0, pageIndex: 2)
        // 先调用（mutating），再断言：`#expect` 的闭包会把变量变成不可变
        let outcome9 = session.advanceForward(pageCount: 3)
        #expect(outcome9 == .needsNextChapter)
        // 状态不变，等调用方换章
        #expect(session.pageIndex == 2)
    }

    @Test("全书最后一页返回 atEnd")
    func reportsAtEnd() {
        var session = makeSession(chapterCount: 3, chapterIndex: 2, pageIndex: 2)
        // 先调用（mutating），再断言：`#expect` 的闭包会把变量变成不可变
        let outcome10 = session.advanceForward(pageCount: 3)
        #expect(outcome10 == .atEnd)
        #expect(session.isAtEnd(pageCount: 3))
    }

    @Test("空章节前进：有下一章则请求换章，否则 atEnd")
    func advancesFromEmptyChapter() {
        var middle = makeSession(chapterCount: 3, chapterIndex: 0)
        // 先调用（mutating），再断言：`#expect` 的闭包会把变量变成不可变
        let outcome11 = middle.advanceForward(pageCount: 0)
        #expect(outcome11 == .needsNextChapter)

        var last = makeSession(chapterCount: 1, chapterIndex: 0)
        // 先调用（mutating），再断言：`#expect` 的闭包会把变量变成不可变
        let outcome12 = last.advanceForward(pageCount: 0)
        #expect(outcome12 == .atEnd)
    }

    // MARK: 后退

    @Test("章内后退逐页移动")
    func movesBackwardWithinChapter() {
        var session = makeSession(pageIndex: 2)
        // 先调用（mutating），再断言：`#expect` 的闭包会把变量变成不可变
        let outcome13 = session.advanceBackward(pageCount: 3) == .moved(toPage: 1)
        #expect(outcome13)
        // 先调用（mutating），再断言：`#expect` 的闭包会把变量变成不可变
        let outcome14 = session.advanceBackward(pageCount: 3) == .moved(toPage: 0)
        #expect(outcome14)
    }

    @Test("章首后退请求上一章")
    func requestsPreviousChapterAtChapterStart() {
        var session = makeSession(chapterCount: 3, chapterIndex: 1, pageIndex: 0)
        // 先调用（mutating），再断言：`#expect` 的闭包会把变量变成不可变
        let outcome15 = session.advanceBackward(pageCount: 3)
        #expect(outcome15 == .needsPreviousChapter)
        #expect(session.pageIndex == 0)
    }

    @Test("全书第一页返回 atStart")
    func reportsAtStart() {
        var session = makeSession(chapterCount: 3, chapterIndex: 0, pageIndex: 0)
        // 先调用（mutating），再断言：`#expect` 的闭包会把变量变成不可变
        let outcome16 = session.advanceBackward(pageCount: 3)
        #expect(outcome16 == .atStart)
    }

    // MARK: 换章

    @Test("换到下一章会把页码重置为 0")
    func movesToNextChapter() {
        var session = makeSession(chapterCount: 3, chapterIndex: 0, pageIndex: 5)
        // 先调用（mutating），再断言：`#expect` 的闭包会把变量变成不可变
        let outcome17 = session.moveToNextChapter()
        #expect(outcome17)
        #expect(session.chapterIndex == 1)
        #expect(session.pageIndex == 0)
        #expect(session.currentChapter?.name == "第 2 话")
    }

    @Test("换到上一章会把页码重置为 0")
    func movesToPreviousChapter() {
        var session = makeSession(chapterCount: 3, chapterIndex: 2, pageIndex: 4)
        // 先调用（mutating），再断言：`#expect` 的闭包会把变量变成不可变
        let outcome18 = session.moveToPreviousChapter()
        #expect(outcome18)
        #expect(session.chapterIndex == 1)
        #expect(session.pageIndex == 0)
    }

    @Test("边界换章失败且状态不变")
    func refusesChapterTransitionAtBounds() {
        var first = makeSession(chapterCount: 2, chapterIndex: 0, pageIndex: 3)
        // 先调用（mutating），再断言：`#expect` 的闭包会把变量变成不可变
        let outcome19 = first.moveToPreviousChapter()
        #expect(!outcome19)
        #expect(first.chapterIndex == 0)
        #expect(first.pageIndex == 3)

        var last = makeSession(chapterCount: 2, chapterIndex: 1, pageIndex: 1)
        // 先调用（mutating），再断言：`#expect` 的闭包会把变量变成不可变
        let outcome20 = last.moveToNextChapter()
        #expect(!outcome20)
        #expect(last.chapterIndex == 1)
        #expect(last.pageIndex == 1)
    }

    @Test("跳到指定章")
    func movesToSpecificChapter() {
        var session = makeSession(chapterCount: 4, chapterIndex: 1, pageIndex: 7)
        // 先调用（mutating），再断言：`#expect` 的闭包会把变量变成不可变
        let outcome21 = session.moveToChapter(3)
        #expect(outcome21)
        #expect(session.chapterIndex == 3)
        #expect(session.pageIndex == 0)

        // 先调用（mutating），再断言
        let movedToExisting = session.moveToChapter(3)
        #expect(!movedToExisting)     // 已在目标章
        let movedOutOfRange = session.moveToChapter(99)
        #expect(!movedOutOfRange)     // 越界
        #expect(session.chapterIndex == 3)
    }

    // MARK: 预加载

    @Test("预加载范围：中间页前后各 window 页")
    func preloadRangeInMiddle() {
        let session = makeSession(pageIndex: 5)
        #expect(session.preloadRange(pageCount: 20, window: 2) == 3..<8)
    }

    @Test("预加载范围：页首与页尾被钳制")
    func preloadRangeClampsAtEdges() {
        #expect(makeSession(pageIndex: 0).preloadRange(pageCount: 10, window: 2) == 0..<3)
        #expect(makeSession(pageIndex: 9).preloadRange(pageCount: 10, window: 2) == 7..<10)
    }

    @Test("预加载范围：window 为 0 只含当前页")
    func preloadRangeWithZeroWindow() {
        #expect(makeSession(pageIndex: 4).preloadRange(pageCount: 10, window: 0) == 4..<5)
    }

    @Test("预加载范围：window 超过页数时覆盖全书")
    func preloadRangeWithLargeWindow() {
        #expect(makeSession(pageIndex: 2).preloadRange(pageCount: 5, window: 99) == 0..<5)
    }

    @Test("预加载范围：负数 window 视为 0")
    func preloadRangeWithNegativeWindow() {
        #expect(makeSession(pageIndex: 2).preloadRange(pageCount: 5, window: -3) == 2..<3)
    }

    @Test("预加载范围：空章节返回空区间")
    func preloadRangeWithNoPages() {
        let range = makeSession(pageIndex: 0).preloadRange(pageCount: 0, window: 3)
        #expect(range.isEmpty)
    }

    // MARK: 钳制

    @Test("clampPageIndex 保证页码落在有效范围")
    func clampsPageIndex() {
        var session = makeSession(pageIndex: 50)
        session.clampPageIndex(pageCount: 10)
        #expect(session.pageIndex == 9)

        session.clampPageIndex(pageCount: 0)
        #expect(session.pageIndex == 0)
    }

    // MARK: 一致性

    @Test("连续前进到最后会依次经过每一页")
    func forwardTraversalVisitsEveryPage() {
        var session = makeSession(chapterCount: 2, chapterIndex: 0)
        var visited: [String] = []
        var chapter = 0
        var pageCount = 3

        for _ in 0..<20 {
            visited.append("\(session.chapterIndex):\(session.pageIndex)")
            switch session.advanceForward(pageCount: pageCount) {
            case let .moved(toPage):
                #expect(toPage == session.pageIndex)
            case .needsNextChapter:
                chapter += 1
                // 先调用（mutating），再断言：`#expect` 的闭包会把变量变成不可变
                let outcome22 = session.moveToNextChapter()
                #expect(outcome22)
            case .atEnd:
                #expect(visited.count == 6)   // 2 章 × 3 页
                return
            case .needsPreviousChapter, .atStart:
                Issue.record("前进过程中不应出现后退结果")
                return
            }
            _ = chapter
        }
        Issue.record("遍历未在预期步数内结束")
    }
}
