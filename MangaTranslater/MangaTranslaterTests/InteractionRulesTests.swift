//
//  InteractionRulesTests.swift
//  MangaTranslaterTests
//
//  「模拟点击」测试：把用户在界面上能做的动作（点哪一侧、往哪边滑、左滑一个
//  什么状态的章节、按哪个破坏性按钮）按**生产代码的真实规则**作用到状态上，
//  再断言结果。
//
//  这个文件的存在本身就是一条设计约束：
//
//  - 规则必须住在 `AppCore.ReaderNavigation` / `ChapterActionMenu` /
//    `DestructiveActionPolicy` / `LibraryFilterMenu` / `SourceEngine.ServerFormValidator`
//    里，而不是散在视图的 `body` 里——否则这里根本没法写。
//  - 视图只把规则结果接到执行者上。规则错了这里红，接线错了靠人工点。
//
//  覆盖方式以**穷举**为主：不是「挑几个有代表性的例子」，而是把
//  「模式 × 侧」「状态 × 动作」「枚举全体」逐个走一遍——分支漏一个就有一条断言红。
//

import Foundation
import Testing
import AppCore
import AppDatabase
import SourceEngine
@testable import MangaTranslater

// MARK: - 阅读器手势

@Suite("交互 · 阅读器手势")
struct ReaderGestureTests {

    // MARK: 点两侧

    // 参数顺序与下面的形参一致：`(isRightToLeft, isLeading, 期望是否前进)`。
    // `isLeading` 是「靠屏幕前缘的那条带」（左到右语言里就是左侧），
    // 因此「右侧」是 `isLeading: false`——第一版把这两个写反了，四条全红。
    @Test("点两侧窄带：模式 × 侧 四种组合穷举", arguments: [
        (false, true, false),    // 左到右 · 点左侧 → 后退
        (false, false, true),    // 左到右 · 点右侧 → 前进
        (true, true, true),      // 右到左 · 点左侧 → 前进
        (true, false, false),    // 右到左 · 点右侧 → 后退
    ])
    func tapZoneDirection(isRightToLeft: Bool, isLeading: Bool, expected: Bool) {
        #expect(
            ReaderNavigation.advancesForward(
                tappingLeadingEdge: isLeading,
                isRightToLeft: isRightToLeft
            ) == expected
        )
    }

    @Test("两条窄带的方向永远相反（否则会有一条点了没反应）")
    func tapZonesAreOpposite() {
        for isRightToLeft in [false, true] {
            let leading = ReaderNavigation.advancesForward(
                tappingLeadingEdge: true,
                isRightToLeft: isRightToLeft
            )
            let trailing = ReaderNavigation.advancesForward(
                tappingLeadingEdge: false,
                isRightToLeft: isRightToLeft
            )
            #expect(leading != trailing)
        }
    }

    // MARK: 横滑

    @Test("左到右模式的横滑方向")
    func swipeDirectionLeftToRight() {
        // 左滑（dx < 0）= 往下一页翻
        #expect(ReaderNavigation.forward(
            forDragTranslation: -120, dy: 4, isZoomed: false, isRightToLeft: false
        ) == true)
        // 右滑 = 往上一页翻
        #expect(ReaderNavigation.forward(
            forDragTranslation: 120, dy: -4, isZoomed: false, isRightToLeft: false
        ) == false)
    }

    @Test("右到左模式的横滑方向与左到右相反")
    func swipeDirectionRightToLeft() {
        #expect(ReaderNavigation.forward(
            forDragTranslation: -120, dy: 4, isZoomed: false, isRightToLeft: true
        ) == false)
        #expect(ReaderNavigation.forward(
            forDragTranslation: 120, dy: -4, isZoomed: false, isRightToLeft: true
        ) == true)
    }

    @Test("放大状态下横滑只平移，不翻页", arguments: [-400, -200, 0, 200, 400])
    func zoomedSwipeNeverTurnsPage(dx: Double) {
        for isRightToLeft in [false, true] {
            #expect(ReaderNavigation.forward(
                forDragTranslation: dx, dy: 0, isZoomed: true, isRightToLeft: isRightToLeft
            ) == nil)
        }
    }

    @Test("位移不够或竖滑为主时不翻页", arguments: [
        (39.0, 0.0),      // 差一点点到阈值
        (0.0, 0.0),       // 没动
        (10.0, 60.0),     // 竖滑为主
        (-30.0, 80.0),    // 斜着但纵向更大
        (-60.0, 60.0),    // 正好 45°，纵向不占优 → 不翻页（`>` 而非 `>=`）
    ])
    func swipeBelowThresholdDoesNothing(dx: Double, dy: Double) {
        for isZoomed in [false, true] {
            for isRightToLeft in [false, true] {
                #expect(ReaderNavigation.forward(
                    forDragTranslation: dx,
                    dy: dy,
                    isZoomed: isZoomed,
                    isRightToLeft: isRightToLeft
                ) == nil)
            }
        }
    }

    @Test("恰好超过阈值就翻页（边界值的两侧都要钉住）")
    func swipeAtThreshold() {
        #expect(ReaderNavigation.forward(
            forDragTranslation: -41, dy: 0, isZoomed: false, isRightToLeft: false
        ) == true)
        #expect(ReaderNavigation.forward(
            forDragTranslation: 41, dy: 0, isZoomed: false, isRightToLeft: false
        ) == false)
    }

    // MARK: 点击带宽度

    @Test("点击带宽度按比例，且夹在上下限之间", arguments: [
        (0.0, 60.0),        // 还没测出容器宽 → 用兜底值
        (200.0, 44.0),      // 30 < 44 → 取 44
        (300.0, 45.0),      // 45
        (390.0, 58.5),      // iPhone 竖屏
        (430.0, 64.5),
        (800.0, 120.0),     // 120 恰好到上限
        (1024.0, 120.0),    // iPad 不继续变宽
        (3000.0, 120.0),
    ])
    func tapZoneWidth(containerWidth: Double, expected: Double) {
        #expect(ReaderNavigation.tapZoneWidth(containerWidth: containerWidth) == expected)
    }

    @Test("点击带宽度随容器单调不减，且永不宽于容器")
    func tapZoneWidthIsMonotonic() {
        // 从 20 起步，**跳过 0**：宽度 0 走的是「容器还没测出来」的兜底值（60），
        // 而兜底值比下限 44 大，所以从 0 起步必然出现一次「回退」——
        // 那是这条断言写错了，不是实现错了（第一版就是这样假红）。
        var previous = 0.0
        for width in stride(from: 20.0, through: 2000.0, by: 20.0) {
            let zone = ReaderNavigation.tapZoneWidth(containerWidth: width)
            #expect(zone >= previous, "宽度 \(width) 处出现了回退")
            #expect(zone <= max(width, 60), "点击带不该宽过容器")
            previous = zone
        }
    }

    @Test("容器宽度未知时用兜底值（首帧 / 载入中）")
    func tapZoneWidthFallsBackBeforeLayout() {
        #expect(ReaderNavigation.tapZoneWidth(containerWidth: 0) == 60)
        #expect(ReaderNavigation.tapZoneWidth(containerWidth: -1) == 60)
        #expect(ReaderNavigation.tapZoneWidth(containerWidth: 0, fallback: 30) == 30)
    }

    @Test("窄屏上两侧点击带加起来不超过 40%，中间区域留得住")
    func tapZonesLeaveMiddleArea() {
        for width in [320.0, 375.0, 390.0, 430.0, 1024.0] {
            let zone = ReaderNavigation.tapZoneWidth(containerWidth: width)
            #expect(zone * 2 < width, "\(width) pt 宽屏上两条点击带占满，双击缩放没地方点")
        }
    }
}

// MARK: - 翻页的端到端模拟

/// 按 `ReaderView` 的真实规则把「点了哪 / 滑了多远」作用到 `ReaderSession`。
///
/// 只镜像**规则**，不镜像 UI：点右侧 → `advancesForward` → `advanceForward`
/// 或 `advanceBackward`，遇到章边界按生产代码的方式换章（往回翻时停在上一章末页）。
/// 规则一旦写错，这里的断言就会红。
private struct ReaderSimulator {

    enum Event: Equatable {
        case pageMoved(toPage: Int)
        case enteredNextChapter
        case enteredPreviousChapter(toPage: Int)
        case blockedAtEnd
        case blockedAtStart
        /// 放大状态下没有翻页（横滑被当成平移）。
        case ignoredBecauseZoomed
    }

    private(set) var session: ReaderSession
    private(set) var events: [Event] = []
    /// 每一章的页数（`ReaderView` 里是「载入章节后回填」的）。
    var pageCount: Int
    var isRightToLeft: Bool

    init(chapters: Int = 2, pageCount: Int = 3, isRightToLeft: Bool = false) {
        let manga = Manga(sourceID: SourceID("demo"), url: "https://example.com/m/1", title: "Sample")
        let chapterList = (1...chapters).map {
            Chapter(mangaID: manga.id, url: "https://example.com/c/\($0)", name: "Chapter \($0)")
        }
        self.session = ReaderSession(manga: manga, chapters: chapterList)
        self.pageCount = pageCount
        self.isRightToLeft = isRightToLeft
    }

    /// 位置（章、页）。用数组而不是元组：带标签的元组与字面量比较在 Swift 里
    /// 会触发隐式转换规则，断言写起来容易踩坑。
    var position: [Int] { [session.chapterIndex, session.pageIndex] }

    func at(chapter: Int, page: Int) -> Bool {
        session.chapterIndex == chapter && session.pageIndex == page
    }

    mutating func tap(leadingEdge: Bool) {
        apply(ReaderNavigation.advancesForward(tappingLeadingEdge: leadingEdge, isRightToLeft: isRightToLeft))
    }

    /// 底部栏「上一页 / 下一页」按钮（不随阅读方向变）。
    mutating func tapPreviousPageButton() { apply(false) }
    mutating func tapNextPageButton() { apply(true) }

    mutating func swipe(dx: Double, dy: Double, isZoomed: Bool = false) {
        guard let forward = ReaderNavigation.forward(
            forDragTranslation: dx,
            dy: dy,
            isZoomed: isZoomed,
            isRightToLeft: isRightToLeft
        ) else {
            if isZoomed { events.append(.ignoredBecauseZoomed) }
            return
        }
        apply(forward)
    }

    private mutating func apply(_ forward: Bool) {
        let result = forward
            ? session.advanceForward(pageCount: pageCount)
            : session.advanceBackward(pageCount: pageCount)

        switch result {
        case let .moved(toPage):
            events.append(.pageMoved(toPage: toPage))
        case .needsNextChapter:
            if session.moveToNextChapter() {
                events.append(.enteredNextChapter)
            } else {
                events.append(.blockedAtEnd)
            }
        case .needsPreviousChapter:
            if session.moveToPreviousChapter() {
                session.moveToLastPage(pageCount: pageCount)
                events.append(.enteredPreviousChapter(toPage: session.pageIndex))
            } else {
                events.append(.blockedAtStart)
            }
        case .atEnd:
            events.append(.blockedAtEnd)
        case .atStart:
            events.append(.blockedAtStart)
        }
        session.clampPageIndex(pageCount: pageCount)
    }
}

@Suite("交互 · 连点模拟")
struct TapSequenceSimulationTests {

    @Test("左到右：连点右侧 6 次，跨章走到第二章末页")
    func tappingTrailingEdgeWalksForward() {
        var reader = ReaderSimulator(chapters: 2, pageCount: 3, isRightToLeft: false)

        reader.tap(leadingEdge: false)   // 0 → 1
        #expect(reader.at(chapter: 0, page: 1))
        reader.tap(leadingEdge: false)   // 1 → 2
        #expect(reader.at(chapter: 0, page: 2))
        reader.tap(leadingEdge: false)   // 章末 → 换章
        #expect(reader.at(chapter: 1, page: 0))
        reader.tap(leadingEdge: false)
        reader.tap(leadingEdge: false)
        #expect(reader.at(chapter: 1, page: 2))

        // 全书最后一页再往前：只提示，不动
        reader.tap(leadingEdge: false)
        #expect(reader.at(chapter: 1, page: 2))
        #expect(reader.events.last == .blockedAtEnd)
    }

    @Test("右到左：点左侧是前进（同一侧在两种模式下方向相反）")
    func tappingLeadingEdgeWalksForwardWhenRightToLeft() {
        var reader = ReaderSimulator(chapters: 1, pageCount: 3, isRightToLeft: true)
        reader.tap(leadingEdge: true)
        #expect(reader.at(chapter: 0, page: 1))
        reader.tap(leadingEdge: true)
        #expect(reader.at(chapter: 0, page: 2))
        #expect(!reader.events.contains(.blockedAtStart))
    }

    @Test("右到左：点右侧是后退，在第一章第一页只提示")
    func tappingTrailingEdgeGoesBackWhenRightToLeft() {
        var reader = ReaderSimulator(chapters: 1, pageCount: 3, isRightToLeft: true)
        reader.tap(leadingEdge: false)
        #expect(reader.at(chapter: 0, page: 0))
        #expect(reader.events == [.blockedAtStart])
    }

    @Test("第一章第一页再往回翻：回到上一章末页（因为根本没有上一章）")
    func backwardAtFirstChapterStartIsBlocked() {
        var reader = ReaderSimulator(chapters: 2, pageCount: 3)
        reader.tapPreviousPageButton()
        #expect(reader.at(chapter: 0, page: 0))
        #expect(reader.events == [.blockedAtStart])
    }

    @Test("第二章第一页往回翻：落到上一章末页而不是章首")
    func backwardFromSecondChapterLandsOnLastPageOfPrevious() {
        var reader = ReaderSimulator(chapters: 2, pageCount: 3)
        // 先走到第二章第一页
        for _ in 0..<3 { reader.tapNextPageButton() }
        #expect(reader.at(chapter: 1, page: 0))

        reader.tapPreviousPageButton()
        #expect(reader.at(chapter: 0, page: 2))
        #expect(reader.events.last == .enteredPreviousChapter(toPage: 2))
    }

    @Test("底部栏按钮不随阅读方向变化（方向只影响点击带与横滑）")
    func bottomBarButtonsIgnoreReadingDirection() {
        var ltr = ReaderSimulator(chapters: 1, pageCount: 3, isRightToLeft: false)
        var rtl = ReaderSimulator(chapters: 1, pageCount: 3, isRightToLeft: true)
        ltr.tapNextPageButton()
        rtl.tapNextPageButton()
        #expect(ltr.position == rtl.position)
    }

    @Test("模拟横滑一页：左到右左滑前进、右滑后退")
    func swipeMovesOnePage() {
        var reader = ReaderSimulator(chapters: 1, pageCount: 5, isRightToLeft: false)
        reader.swipe(dx: -150, dy: 5)
        #expect(reader.at(chapter: 0, page: 1))
        reader.swipe(dx: 150, dy: 5)
        #expect(reader.at(chapter: 0, page: 0))
    }

    @Test("放大后横滑不翻页（只记一次「被忽略」）")
    func zoomedSwipeDoesNotMove() {
        var reader = ReaderSimulator(chapters: 1, pageCount: 5)
        reader.swipe(dx: -300, dy: 0, isZoomed: true)
        #expect(reader.at(chapter: 0, page: 0))
        #expect(reader.events == [.ignoredBecauseZoomed])
    }

    @Test("空章节：往前翻直接请求换章，不会卡在空白页")
    func emptyChapterRequestsNextChapter() {
        var reader = ReaderSimulator(chapters: 2, pageCount: 0)
        reader.tapNextPageButton()
        #expect(reader.events == [.enteredNextChapter])
    }

    @Test("单章作品：翻到最后一页后无法再前进")
    func singleChapterCannotAdvancePastEnd() {
        var reader = ReaderSimulator(chapters: 1, pageCount: 2)
        reader.tapNextPageButton()
        reader.tapNextPageButton()
        #expect(reader.at(chapter: 0, page: 1))
        #expect(reader.events == [.pageMoved(toPage: 1), .blockedAtEnd])
    }
}

// MARK: - 章节行左滑

@Suite("交互 · 章节行左滑")
struct ChapterSwipeMenuTests {

    /// 界面上的七种状态，穷举。
    static let allStates: [ChapterDownloadState] = [
        .none,
        .queued,
        .active(completed: 3, total: 10),
        .paused,
        .failed,
        .cancelled,
        .downloaded,
    ]

    @Test("状态 → 按钮 的映射逐条钉住")
    func actionPerState() {
        let expected: [ChapterDownloadState: ChapterDownloadAction] = [
            .none: .download,
            .queued: .download,
            .active(completed: 3, total: 10): .cancel,
            .paused: .cancel,
            .failed: .download,
            .cancelled: .download,
            .downloaded: .deleteArchive,
        ]
        for state in Self.allStates {
            #expect(ChapterActionMenu.action(for: state) == expected[state], "状态 \(state) 的按钮不对")
        }
    }

    @Test("「已排队」必须给「下载」按钮（否则用户点了收不回来）")
    func queuedIsCancellableByDownloadingAgain() {
        // `.queued` 走的是「再点一次下载」——协调器对已存在且未终结的任务会拒绝入队，
        // 但至少不会让用户看到一个点不动的行。这条断言把「队列里也要给按钮」钉住。
        #expect(ChapterActionMenu.action(for: .queued) == .download)
    }

    @Test("失败与已取消都能重下（而不是显示成「已下载」）")
    func terminalFailuresAllowRedownload() {
        #expect(ChapterActionMenu.action(for: .failed) == .download)
        #expect(ChapterActionMenu.action(for: .cancelled) == .download)
    }

    @Test("下载中 / 暂停 → 取消；已归档 → 删除归档")
    func activeAndDownloadedStates() {
        #expect(ChapterActionMenu.action(for: .active(completed: 0, total: 1)) == .cancel)
        #expect(ChapterActionMenu.action(for: .paused) == .cancel)
        #expect(ChapterActionMenu.action(for: .downloaded) == .deleteArchive)
    }

    @Test("只有「删除归档」需要二次确认；「下载」不是破坏性操作、「取消」不需要确认")
    func confirmationFollowsPolicy() {
        for state in Self.allStates {
            switch ChapterActionMenu.action(for: state) {
            case .download:
                #expect(ChapterActionMenu.destructiveAction(for: state) == nil, "下载不该被当成破坏性操作")
            case .cancel:
                // 取消单个任务可以一键重来，按策略**不**确认；
                // 但它确实是破坏性操作的一种（会丢掉已抓的页），所以映射要给出它。
                #expect(ChapterActionMenu.destructiveAction(for: state) == .cancelDownload)
                #expect(!DestructiveActionPolicy.requiresConfirmation(.cancelDownload))
            case .deleteArchive:
                // 删归档是**唯一**需要确认的那个：它是用户攒下来的离线数据，
                // 站点没了就永久没了（策略层与界面都据此裁决）
                #expect(ChapterActionMenu.destructiveAction(for: state) == .deleteChapterArchive)
                #expect(DestructiveActionPolicy.requiresConfirmation(.deleteChapterArchive))
            }
        }
    }

    @Test("每个状态都有唯一确定的按钮（不会有「无按钮」的空行）")
    func everyStateHasExactlyOneAction() {
        for state in Self.allStates {
            // `action(for:)` 是全函数（没有返回值可选项），这里再确认它落在三个合法值之一
            let action = ChapterActionMenu.action(for: state)
            #expect([ChapterDownloadAction.download, .cancel, .deleteArchive].contains(action))
        }
    }
}

// MARK: - 破坏性操作与二次确认

@Suite("交互 · 破坏性操作矩阵")
struct DestructiveActionPolicyTests {

    /// 期望矩阵。**刻意写死**：新增一个 `DestructiveAction` 而不更新这张表，
    /// 上面的 `allCases` 计数断言会先红，逼作者回来想一遍「它要不要确认」。
    static let expectedConfirmation: [DestructiveAction: Bool] = [
        .removeFromLibrary: true,
        .deleteCategory: true,
        .cancelDownload: false,
        .cancelAllDownloads: true,
        .deleteChapterArchive: true,
        .deleteMangaArchives: true,
        .deleteAllArchives: true,
        .clearFinishedRecords: false,
        .deleteServer: true,
        .deleteRepository: false,
        .clearDiagnostics: false,
        .clearCoverCache: false,
        .clearTranslationCache: true,
        .signOut: false,
        .deleteAccount: true,
        .clearSourceCookies: false,
        // 本轮新增（O-8 / O-9）
        .deleteLocalBook: true,
        .restoreBackup: true,
    ]

    @Test("枚举全体都被矩阵覆盖（数量不对就说明漏了）")
    func matrixCoversAllCases() {
        #expect(DestructiveAction.allCases.count == Self.expectedConfirmation.count)
        for action in DestructiveAction.allCases {
            #expect(Self.expectedConfirmation[action] != nil, "\(action.rawValue) 没写进期望矩阵")
        }
    }

    @Test("矩阵逐条吻合")
    func policyMatchesMatrix() {
        for action in DestructiveAction.allCases {
            let expected = Self.expectedConfirmation[action]
            #expect(
                DestructiveActionPolicy.requiresConfirmation(action) == expected,
                "\(action.rawValue) 的确认策略与矩阵不符"
            )
        }
    }

    @Test("同一类操作在两个页面必须是同一种策略（这是 O-1 的修复本身）")
    func sameActionSamePolicy() {
        // 删除单章归档：下载页与作品详情页都走 `.deleteChapterArchive`
        #expect(DestructiveActionPolicy.requiresConfirmation(.deleteChapterArchive))
        // 删除某作品全部归档：同理
        #expect(DestructiveActionPolicy.requiresConfirmation(.deleteMangaArchives))
        // 而「清理译文缓存」是唯一会浪费钱的清理动作 → 也必须确认
        #expect(DestructiveActionPolicy.requiresConfirmation(.clearTranslationCache))
    }

    @Test("只有「注销账号」与「删除本地文件」是不可恢复的")
    func irreversibleSetIsExplicit() {
        let irreversible: Set<DestructiveAction> = [.deleteAccount, .deleteLocalBook]
        for action in DestructiveAction.allCases {
            #expect(
                DestructiveActionPolicy.isIrreversible(action) == irreversible.contains(action),
                "\(action.rawValue) 的可恢复性判断不对"
            )
        }
        // 说明为什么是这两个：
        // - 注销账号：服务端删号，回不来；
        // - 删除本地文件：删的是**用户自己放进来的文件**，App 里没有回收站。
        // 其余操作要么能重做（重下 / 重翻），要么能重建（封面缓存），
        // 所以它们「算破坏性操作但不算不可逆」。
    }

    @Test("不可恢复的操作要「输入确认」而不是「点一下确认」")
    func typedConfirmationMatchesIrreversibility() {
        for action in DestructiveAction.allCases {
            #expect(
                DestructiveActionPolicy.requiresTypedConfirmation(action)
                    == DestructiveActionPolicy.isIrreversible(action)
            )
        }
    }

    @Test("能一键重来的操作不确认（否则确认弹窗会让人闭眼点确定）", arguments: [
        DestructiveAction.cancelDownload,
        .clearFinishedRecords,
        .clearCoverCache,
        .signOut,
        .clearSourceCookies,
        .deleteRepository,
        .clearDiagnostics,
    ])
    func cheapActionsDoNotAsk(action: DestructiveAction) {
        #expect(!DestructiveActionPolicy.requiresConfirmation(action))
    }

    @Test("rawValue 是文档与代码之间的合同（交互清单第 11 节按它对齐）")
    func rawValuesAreStable() {
        #expect(DestructiveAction.removeFromLibrary.rawValue == "removeFromLibrary")
        #expect(DestructiveAction.clearTranslationCache.rawValue == "clearTranslationCache")
        // 全部 rawValue 唯一
        #expect(Set(DestructiveAction.allCases.map(\.rawValue)).count == DestructiveAction.allCases.count)
    }
}

// MARK: - 书架筛选菜单

@Suite("交互 · 书架筛选与排序")
struct LibraryMenuTests {

    private static func category(_ id: String, _ name: String, order: Int = 0) -> LibraryCategory {
        LibraryCategory(id: id, name: name, sortOrder: order)
    }

    @Test("没有分类时只剩「全部作品」")
    func emptyCategories() {
        let targets = LibraryFilterMenu.targets(categories: [])
        #expect(targets == [.all])
    }

    @Test("菜单项顺序 = 「全部作品」+ 各分类（顺序取存储层）")
    func targetsFollowStorageOrder() {
        let categories = [
            Self.category("a", "Alpha", order: 0),
            Self.category("b", "Beta", order: 1),
            Self.category("c", "Gamma", order: 2),
        ]
        let targets = LibraryFilterMenu.targets(categories: categories)
        #expect(targets == [
            .all,
            .category(id: "a", name: "Alpha"),
            .category(id: "b", name: "Beta"),
            .category(id: "c", name: "Gamma"),
        ])
    }

    @Test("分类改名后菜单项跟着变（菜单不是快照）")
    func renamedCategoryShowsNewName() {
        let before = LibraryFilterMenu.targets(categories: [Self.category("a", "Alpha")])
        let after = LibraryFilterMenu.targets(categories: [Self.category("a", "Renamed")])
        #expect(before != after)
        #expect(after.contains(.category(id: "a", name: "Renamed")))
    }

    @Test("菜单项的标识互不重复（`ForEach` 依赖它，撞了会丢行）")
    func targetIdentifiersAreUnique() {
        let categories = [
            Self.category("a", "Alpha"),
            Self.category("b", "Beta"),
        ]
        let ids = LibraryFilterMenu.targets(categories: categories).map(\.id)
        #expect(Set(ids).count == ids.count)
        // 「全部作品」的哨兵值不能与分类 ID 撞：分类 ID 是 UUID，不含 `#`
        #expect(LibraryFilterTarget.all.id == "#all")
        #expect(!ids.contains(where: { $0 != "#all" && $0.hasPrefix("#") }))
    }

    @Test("选中项仍然存在时保持不变")
    func selectionSurvivesIfCategoryStillExists() {
        let categories = [Self.category("a", "Alpha"), Self.category("b", "Beta")]
        #expect(LibraryFilterMenu.validSelection("b", categories: categories) == "b")
    }

    @Test("选中项被删掉后回退「全部作品」（否则会停在一个空列表上）")
    func selectionFallsBackWhenCategoryDeleted() {
        let categories = [Self.category("a", "Alpha")]
        #expect(LibraryFilterMenu.validSelection("gone", categories: categories) == nil)
        #expect(LibraryFilterMenu.validSelection("gone", categories: []) == nil)
    }

    @Test("未选中任何分类时保持 nil（= 全部作品）")
    func nilSelectionStaysNil() {
        #expect(LibraryFilterMenu.validSelection(nil, categories: [Self.category("a", "Alpha")]) == nil)
    }

    @Test("排序偏好：能识别就沿用，认不出就回退默认", arguments: [
        ("lastRead", LibrarySortOrder.lastRead),
        ("title", LibrarySortOrder.title),
        ("recentlyAdded", LibrarySortOrder.recentlyAdded),
        ("", LibrarySortOrder.lastRead),
        ("TITLE", LibrarySortOrder.lastRead),          // 大小写不匹配也算认不出
        ("rainbow", LibrarySortOrder.lastRead),        // 被改坏
        ("lastread", LibrarySortOrder.lastRead),
    ])
    func sortOrderParsing(raw: String, expected: LibrarySortOrder) {
        #expect(LibraryPreferences.sortOrder(from: raw) == expected)
    }

    @Test("nil 也回退默认（首次启动时键不存在）")
    func sortOrderParsingNil() {
        #expect(LibraryPreferences.sortOrder(from: nil) == LibraryPreferences.defaultSortOrder)
    }

    @Test("布局偏好：能识别就沿用，认不出回退默认", arguments: [
        ("grid", LibraryPreferences.DisplayMode.grid),
        ("list", LibraryPreferences.DisplayMode.list),
        ("", LibraryPreferences.DisplayMode.grid),
        ("GRID", LibraryPreferences.DisplayMode.grid),
        ("cards", LibraryPreferences.DisplayMode.grid),
    ])
    func displayModeParsing(raw: String, expected: LibraryPreferences.DisplayMode) {
        #expect(LibraryPreferences.displayMode(from: raw) == expected)
    }

    @Test("默认布局是手册 §8.1 要求的网格；读不到时也回退到它")
    func displayModeDefaultsToGrid() {
        #expect(LibraryPreferences.defaultDisplayMode == .grid)
        #expect(LibraryPreferences.displayMode(from: nil) == .grid)
        #expect(LibraryPreferences.DisplayMode.allCases.count == 2)
    }

    @Test("每个排序方式都能被自己序列化后再解析回来（往返一致）")
    func sortOrderRoundTrip() {
        for order in LibrarySortOrder.allCases {
            #expect(LibraryPreferences.sortOrder(from: order.rawValue) == order)
        }
    }
}

// MARK: - 服务器表单

@Suite("交互 · 服务器表单")
struct ServerFormTests {

    @Test("空名字报名字问题，合法地址不报地址问题")
    func missingName() {
        #expect(ServerFormValidator.issues(name: "", baseURL: "https://nas.local/komga") == [.missingName])
        #expect(ServerFormValidator.issues(name: "   ", baseURL: "https://nas.local/komga") == [.missingName])
    }

    @Test("有名字但地址不合法时报地址问题")
    func invalidAddress() {
        #expect(ServerFormValidator.issues(name: "NAS", baseURL: "") == [.invalidAddress])
        #expect(ServerFormValidator.issues(name: "NAS", baseURL: "nas.local") == [.invalidAddress])
        #expect(ServerFormValidator.issues(name: "NAS", baseURL: "ftp://nas.local") == [.invalidAddress])
    }

    @Test("两个都坏时顺序固定（界面只显示第一条）")
    func issueOrderIsStable() {
        #expect(ServerFormValidator.issues(name: "", baseURL: "") == [.missingName, .invalidAddress])
    }

    @Test("可保存的组合逐条穷举", arguments: [
        ("NAS", "https://nas.local", true),
        ("NAS", "https://nas.local:8080", true),
        ("NAS", "https://nas.local/komga", true),
        ("NAS", "http://192.168.1.9:25600/kavita/", true),
        ("", "https://nas.local", false),
        ("NAS", "", false),
        ("NAS", "https://", false),
        ("", "", false),
    ])
    func canSave(name: String, baseURL: String, expected: Bool) {
        #expect(ServerFormValidator.canSave(name: name, baseURL: baseURL) == expected)
    }

    @Test("canSave 与 issues 永远一致（不能出现「能保存但报错」）")
    func canSaveAgreesWithIssues() {
        let names = ["", " ", "NAS", "  NAS  "]
        let urls = ["", "nas.local", "ftp://x", "https://nas.local", "http://a.b:8080/p"]
        for name in names {
            for url in urls {
                #expect(ServerFormValidator.canSave(name: name, baseURL: url)
                    == ServerFormValidator.issues(name: name, baseURL: url).isEmpty)
            }
        }
    }

    // MARK: 表单合并（「空 = 不改」的语义）

    private static func server() -> HostedServer {
        HostedServer(
            id: "komga-nas",
            kind: .komga,
            name: "NAS",
            baseURL: "https://nas.local/komga/",
            apiKey: "key-1",
            username: "reader",
            password: "pw-1"
        )
    }

    @Test("编辑时凭据留空 = 不改（改地址不会顺手清掉密钥）")
    func emptyCredentialsKeepExisting() {
        let existing = Self.server()
        var draft = ServerFormDraft.editing(existing)
        draft.baseURL = "https://other.local/komga"

        let merged = draft.merged(into: existing, assigningID: existing.id)
        #expect(merged.apiKey == "key-1")
        #expect(merged.password == "pw-1")
        #expect(merged.baseURL == "https://other.local/komga")
        #expect(merged.id == existing.id, "编辑不该换标识")
    }

    @Test("编辑时填入新密钥 = 覆盖；填入空用户名 = 清空用户名")
    func explicitEmptyClearsUsername() {
        let existing = Self.server()
        var draft = ServerFormDraft.editing(existing)
        draft.apiKey = "  key-2  "
        draft.username = ""
        draft.password = "pw-2"

        let merged = draft.merged(into: existing, assigningID: existing.id)
        #expect(merged.apiKey == "key-2", "新密钥要去掉首尾空白")
        #expect(merged.username == nil, "用户名留空表示清空")
        #expect(merged.password == "pw-2")
    }

    @Test("地址与名字落盘前会被规范化")
    func nameAndAddressAreNormalized() {
        let draft = ServerFormDraft(
            kind: .kavita,
            name: "  My NAS  ",
            baseURL: "  https://nas.local/kavita///  "
        )
        let merged = draft.merged(into: nil, assigningID: "kavita-my-nas")
        #expect(merged.name == "My NAS")
        #expect(merged.baseURL == "https://nas.local/kavita")
        #expect(merged.id == "kavita-my-nas")
        #expect(merged.apiKey == nil)
        #expect(merged.username == nil)
    }

    @Test("编辑时填充表单：凭据不回显（空字符串）")
    func editingDraftDoesNotEchoCredentials() {
        let draft = ServerFormDraft.editing(Self.server())
        #expect(draft.apiKey.isEmpty)
        #expect(draft.password.isEmpty)
        #expect(draft.username == "reader", "用户名是明文可见的，可以回显")
        #expect(draft.baseURL == "https://nas.local/komga", "地址按规范化后的形态显示")
    }

    @Test("draft.issues 与校验器一致")
    func draftIssuesMatchValidator() {
        var draft = ServerFormDraft()
        #expect(draft.issues() == [.missingName, .invalidAddress])
        draft.name = "NAS"
        draft.baseURL = "https://nas.local"
        #expect(draft.issues().isEmpty)
    }

    @Test("新增时标识由调用方给出，合并不会替它改主意")
    func newServerKeepsGivenID() {
        let draft = ServerFormDraft(kind: .komga, name: "NAS", baseURL: "https://nas.local")
        let first = draft.merged(into: nil, assigningID: "komga-nas")
        let second = draft.merged(into: nil, assigningID: "komga-nas-2")
        #expect(first.id == "komga-nas")
        #expect(second.id == "komga-nas-2")
    }
}

// MARK: - 跳页输入（O-11）

@Suite("交互 · 跳页输入")
struct ReaderJumpTests {

    @Test("直接输入页码（1 基输入 → 0 基下标）", arguments: [
        ("1", 48, PageJumpResult.jump(toIndex: 0)),
        ("12", 48, .jump(toIndex: 11)),
        ("48", 48, .jump(toIndex: 47)),
        ("  12  ", 48, .jump(toIndex: 11)),
    ])
    func plainInput(input: String, pageCount: Int, expected: PageJumpResult) {
        #expect(ReaderJump.resolvePage(input: input, pageCount: pageCount) == expected)
    }

    @Test("粘贴「12 / 48」这种页码标签也能用", arguments: [
        "12/48",
        "12 / 48",
        " 12 ／ 48 ",
    ])
    func pastedPageLabel(input: String) {
        #expect(ReaderJump.resolvePage(input: input, pageCount: 48) == .jump(toIndex: 11))
    }

    @Test("全角数字（中文输入法）能识别", arguments: [
        "１２",
        "１２／４８",
        "１２ ／ ４８",
    ])
    func fullWidthDigits(input: String) {
        #expect(ReaderJump.resolvePage(input: input, pageCount: 48) == .jump(toIndex: 11))
    }

    @Test("越界：钳制到边界并说明，而不是拒绝", arguments: [
        ("0", 48, PageJumpResult.outOfRange(clampedIndex: 0)),
        ("-1", 48, .outOfRange(clampedIndex: 0)),
        ("49", 48, .outOfRange(clampedIndex: 47)),
        ("999", 48, .outOfRange(clampedIndex: 47)),
    ])
    func outOfRangeIsClamped(input: String, pageCount: Int, expected: PageJumpResult) {
        // 打错一位数字时，「跳到最后一页」比「弹个错然后什么都不做」更接近意图
        #expect(ReaderJump.resolvePage(input: input, pageCount: pageCount) == expected)
    }

    @Test("解析不出来就明确报错（不能静默变成「点了没反应」）", arguments: [
        "", "   ", "abc", "/", "12x", "1.5", "一", "１２a",
    ])
    func invalidInputs(input: String) {
        #expect(ReaderJump.resolvePage(input: input, pageCount: 48) == .invalid)
    }

    @Test("页数为 0（还没载入完）时任何输入都不算合法")
    func zeroPageCount() {
        #expect(ReaderJump.resolvePage(input: "1", pageCount: 0) == .invalid)
        #expect(ReaderJump.resolvePage(input: "0", pageCount: 0) == .invalid)
    }

    @Test("全角数字与全角斜杠都被归一化，其它字符原样保留")
    func normalization() {
        #expect(ReaderJump.normalizedDigits("１２３") == "123")
        #expect(ReaderJump.normalizedDigits("１２／４８") == "12/48")
        #expect(ReaderJump.normalizedDigits("　12　") == "12")
        #expect(ReaderJump.normalizedDigits("12a") == "12a", "不做激进清洗，交给解析层报错")
    }

    @Test("跳到页：把解析结果作用到阅读会话上，页码真的变了")
    func jumpMovesSession() throws {
        let manga = Manga(sourceID: SourceID("demo"), url: "https://example.com/m/1", title: "Sample")
        let chapters = [Chapter(mangaID: manga.id, url: "https://example.com/c/1", name: "Ch 1")]
        var session = ReaderSession(manga: manga, chapters: chapters, pageIndex: 0)
        let pageCount = 48

        let result = ReaderJump.resolvePage(input: "12", pageCount: pageCount)
        guard case let .jump(toIndex) = result else {
            Issue.record("期望能解析出页码，实际 \(result)")
            return
        }
        // `#expect` 里不调 mutating 方法：先取返回值再断言（预检第 5 项的要求）
        let moved = session.moveToPage(toIndex, pageCount: pageCount)
        #expect(moved)
        #expect(session.pageIndex == 11)
    }

    @Test("跳到最后一页：边界输入落在最后一页而不是越界")
    func jumpToLastPage() {
        let manga = Manga(sourceID: SourceID("demo"), url: "https://example.com/m/1", title: "Sample")
        let chapters = [Chapter(mangaID: manga.id, url: "https://example.com/c/1", name: "Ch 1")]
        var session = ReaderSession(manga: manga, chapters: chapters, pageIndex: 0)
        let pageCount = 48

        guard case let .outOfRange(clampedIndex) = ReaderJump.resolvePage(input: "999", pageCount: pageCount) else {
            Issue.record("越界输入应当被钳制")
            return
        }
        session.moveToPage(clampedIndex, pageCount: pageCount)
        #expect(session.pageIndex == pageCount - 1)
    }

    @Test("跳到当前页不会产生「变化」（避免白闪一次）")
    func jumpToSamePageIsNoop() {
        let manga = Manga(sourceID: SourceID("demo"), url: "https://example.com/m/1", title: "Sample")
        let chapters = [Chapter(mangaID: manga.id, url: "https://example.com/c/1", name: "Ch 1")]
        var session = ReaderSession(manga: manga, chapters: chapters, pageIndex: 5)
        let moved = session.moveToPage(5, pageCount: 48)
        #expect(moved == false)
    }
}
