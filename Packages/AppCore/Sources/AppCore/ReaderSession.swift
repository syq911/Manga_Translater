//
//  ReaderSession.swift
//  AppCore
//
//  阅读器会话：**纯逻辑**（无 UI、无网络、无磁盘），负责
//  「当前在第几章第几页」「能不能继续往后翻」「预加载哪些页」。
//
//  这样拆分的理由：翻页边界、章末跳转、预加载窗口这些规则最容易出
//  off-by-one 问题，但它们在 SwiftUI 里极难测；抽成值类型后可以逐条断言。
//  视图层只负责把结果画出来、把进度写回存储。
//

import Foundation

/// 翻页 / 翻章的结果。
public enum ReaderAdvanceResult: Equatable, Sendable {
    /// 在本章内移动到了某一页。
    case moved(toPage: Int)
    /// 本章读完，需要加载并进入下一章。
    case needsNextChapter
    /// 本章开头再往前，需要回到上一章末尾。
    case needsPreviousChapter
    /// 已经是全书最后一页。
    case atEnd
    /// 已经是全书第一页。
    case atStart
}

/// 阅读会话（值类型，`mutating` 方法返回结果，不做副作用）。
public struct ReaderSession: Equatable, Sendable {

    public let manga: Manga
    public private(set) var chapters: [Chapter]
    public private(set) var chapterIndex: Int
    public private(set) var pageIndex: Int

    /// - Parameters:
    ///   - chapterIndex: 会被钳制到合法范围（空章节列表时为 0）。
    ///   - pageIndex: 会被钳制到 ≥ 0（页数未知，上界由调用方在 `moveToPage` 时给出）。
    public init(
        manga: Manga,
        chapters: [Chapter],
        chapterIndex: Int = 0,
        pageIndex: Int = 0
    ) {
        self.manga = manga
        self.chapters = chapters
        self.chapterIndex = chapters.isEmpty ? 0 : min(max(0, chapterIndex), chapters.count - 1)
        self.pageIndex = max(0, pageIndex)
    }

    // MARK: 状态

    public var chapterCount: Int { chapters.count }

    public var currentChapter: Chapter? {
        guard chapters.indices.contains(chapterIndex) else { return nil }
        return chapters[chapterIndex]
    }

    public var hasNextChapter: Bool {
        chapterIndex + 1 < chapters.count
    }

    public var hasPreviousChapter: Bool {
        chapterIndex > 0
    }

    /// 进度标记（用于写回书架）。无章节时为 nil。
    public var progressMark: (chapterID: String, pageIndex: Int)? {
        guard let chapter = currentChapter else { return nil }
        return (chapter.id, pageIndex)
    }

    /// 是否已到全书最后一页（需要已知当前章页数）。
    public func isAtEnd(pageCount: Int) -> Bool {
        !hasNextChapter && pageIndex >= max(0, pageCount - 1)
    }

    // MARK: 移动

    /// 跳到当前章的某一页。越界会被钳制。
    /// - Returns: 是否真的发生了移动。
    @discardableResult
    public mutating func moveToPage(_ index: Int, pageCount: Int) -> Bool {
        let upper = max(0, pageCount - 1)
        let clamped = min(max(0, index), upper)
        guard clamped != pageIndex else { return false }
        pageIndex = clamped
        return true
    }

    /// 往后翻一页；到章末则请求下一章。
    public mutating func advanceForward(pageCount: Int) -> ReaderAdvanceResult {
        if pageCount <= 0 {
            // 空章节：直接尝试换章，避免卡在空白页
            return hasNextChapter ? .needsNextChapter : .atEnd
        }
        if pageIndex + 1 < pageCount {
            pageIndex += 1
            return .moved(toPage: pageIndex)
        }
        return hasNextChapter ? .needsNextChapter : .atEnd
    }

    /// 往前翻一页；到章首则请求上一章。
    public mutating func advanceBackward(pageCount: Int) -> ReaderAdvanceResult {
        if pageIndex > 0 {
            pageIndex -= 1
            return .moved(toPage: pageIndex)
        }
        return hasPreviousChapter ? .needsPreviousChapter : .atStart
    }

    /// 进入下一章（从第 0 页开始）。
    /// - Returns: 是否成功换章。
    @discardableResult
    public mutating func moveToNextChapter() -> Bool {
        guard hasNextChapter else { return false }
        chapterIndex += 1
        pageIndex = 0
        return true
    }

    /// 进入上一章（从第 0 页开始；调用方通常随后再跳到章末）。
    @discardableResult
    public mutating func moveToPreviousChapter() -> Bool {
        guard hasPreviousChapter else { return false }
        chapterIndex -= 1
        pageIndex = 0
        return true
    }

    /// 跳到指定章。
    @discardableResult
    public mutating func moveToChapter(_ index: Int) -> Bool {
        guard chapters.indices.contains(index), index != chapterIndex else { return false }
        chapterIndex = index
        pageIndex = 0
        return true
    }

    /// 跳到章末（用于「从上一章回退过来」的场景）。
    @discardableResult
    public mutating func moveToLastPage(pageCount: Int) -> Bool {
        moveToPage(max(0, pageCount - 1), pageCount: pageCount)
    }

    // MARK: 预加载

    /// 需要预加载的页范围（当前页前后各 `window` 页，已按页数钳制）。
    ///
    /// 例：pageCount=10、pageIndex=0、window=2 → `0..<3`；
    /// pageIndex=9 → `7..<10`；window=0 → 仅当前页。
    public func preloadRange(pageCount: Int, window: Int) -> Range<Int> {
        guard pageCount > 0 else { return 0..<0 }
        let clampedWindow = max(0, window)
        let lower = max(0, pageIndex - clampedWindow)
        let upper = min(pageCount, pageIndex + clampedWindow + 1)
        guard lower < upper else { return 0..<0 }
        return lower..<upper
    }

    /// 由外部（换章后）设定页数上界，保证 pageIndex 合法。
    public mutating func clampPageIndex(pageCount: Int) {
        pageIndex = min(max(0, pageIndex), max(0, pageCount - 1))
    }
}
