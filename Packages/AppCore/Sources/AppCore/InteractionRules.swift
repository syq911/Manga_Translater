//
//  InteractionRules.swift
//  AppCore
//
//  交互判定层：把「用户点了哪里 / 滑向哪边 / 现在是什么状态」翻译成
//  「该执行哪个动作」的全部规则。
//
//  为什么单独成文件而不是留在视图里：
//
//  SwiftUI 视图**不能**直接单测（没有 ViewInspector 之类的依赖，也不该为了测试
//  引入它）。于是「点击语义」如果写在 `body` 里，就永远只能靠人工点。
//  把这些判定抽成纯函数之后，每个分支都能被穷举——而分支恰恰是最容易写错的部分
//  （右到左模式的翻页方向、下载状态到按钮的映射、哪个操作要二次确认）。
//
//  分界线：本文件**只做判定，不做副作用**。视图负责把判定结果接到
//  `DownloadCoordinator` / `LibraryStoring` 这类真正的执行者上。
//  这样「点了会怎样」的规则可以被钉死，而副作用只保留一行调用。
//
//  另一条纪律：这里**不出现任何用户可见文案**（`AppCore` 拿不到 App 的目标
//  的 `L()`）。需要界面的地方返回中性的枚举，由 App 层映射成 `L("…")`。
//

import Foundation

// MARK: - 阅读器：手势 → 翻页

/// 阅读器的手势语义。
///
/// 三个方法对应三种输入：点左/右窄带、横滑、以及窄带该多宽。
/// 「右到左」（日漫常见）只影响**方向**，不影响阈值与几何。
public enum ReaderNavigation {

    /// 点击带的宽度下限（点得太窄会点不到，尤其是单手操作时）。
    public static let tapZoneMinimumWidth: Double = 44
    /// 点击带的宽度上限（点得太宽会把中间区域挤没，双击缩放就没地方点了）。
    public static let tapZoneMaximumWidth: Double = 120
    /// 点击带占容器宽度的比例。
    public static let tapZoneWidthRatio: Double = 0.15
    /// 横滑翻页的最小位移（点）。低于它视为手抖。
    public static let swipeMinimumDistance: Double = 40

    /// 点左/右窄带是「前进」吗？
    ///
    /// - Parameters:
    ///   - isLeading: 是否是靠近屏幕「前缘」的那条带（左到右语言环境里就是左侧）。
    ///   - isRightToLeft: 是否右到左阅读。
    public static func advancesForward(tappingLeadingEdge isLeading: Bool, isRightToLeft: Bool) -> Bool {
        // 左到右：左侧=上一页（前缘是「往回」）；右到左：左侧=下一页（前缘是「往前」）
        isRightToLeft ? isLeading : !isLeading
    }

    /// 横滑是「前进（true）/ 后退（false）」还是「不翻页（nil）」。
    ///
    /// 不翻页的两种情况：放大状态下横滑是**平移**；位移不够或不以横向为主。
    public static func forward(
        forDragTranslation dx: Double,
        dy: Double,
        isZoomed: Bool,
        isRightToLeft: Bool
    ) -> Bool? {
        guard !isZoomed else { return nil }
        guard abs(dx) > abs(dy), abs(dx) > swipeMinimumDistance else { return nil }
        let swipedToLeadingEdge = dx < 0
        // 左滑在「左到右」模式是下一页；在「右到左」模式是上一页
        return isRightToLeft ? !swipedToLeadingEdge : swipedToLeadingEdge
    }

    /// 点击带该多宽。
    ///
    /// 按容器宽度取比例，并夹在上下限之间——**不写死**：
    /// 写死 60pt 在 iPhone 竖屏勉强够，到了 iPad / 横屏就窄得点不准，
    /// 而写死一个大值又会在窄屏上吃掉整个页面。
    ///
    /// - Parameter fallback: 容器宽度还没测出来时（首帧 / 载入中）用它的值。
    public static func tapZoneWidth(containerWidth: Double, fallback: Double = 60) -> Double {
        guard containerWidth > 0 else { return fallback }
        let proportional = containerWidth * tapZoneWidthRatio
        return min(tapZoneMaximumWidth, max(tapZoneMinimumWidth, proportional))
    }
}

// MARK: - 章节行的下载状态与左滑动作

/// 章节在下载上的状态（界面用）。
///
/// 刻意与 `ComicDownload.DownloadState` 分开：这一层描述的是「**界面上看到什么**」
/// （含 `downloaded` 这种由归档推导出来的状态），而包层那个是队列自己的状态机。
/// 分开之后两者可以各自演进，映射只在 `App` 层一处发生。
public enum ChapterDownloadState: Hashable, Sendable {
    /// 没下载过，也没有任务。
    case none
    /// 已入队但还没开始跑。
    case queued
    /// 正在下载。
    case active(completed: Int, total: Int)
    case paused
    case failed
    case cancelled
    /// 已归档（能离线看）。
    case downloaded
}

/// 章节行左滑能做的事情。
public enum ChapterDownloadAction: Hashable, Sendable {
    case download
    case cancel
    case deleteArchive
}

/// 章节行左滑该出现哪个按钮。
///
/// 抽出这一层的原因：这是个 7 → 3 的映射，且四个「非进行中」状态
/// （未下载 / 排队 / 失败 / 已取消）**都要给「下载」**——
/// 漏掉 `.queued` 会让用户点了下载之后收不回来（实测踩过）。
public enum ChapterActionMenu {

    public static func action(for state: ChapterDownloadState) -> ChapterDownloadAction {
        switch state {
        case .downloaded: return .deleteArchive
        case .active, .paused: return .cancel
        case .none, .queued, .failed, .cancelled: return .download
        }
    }

    /// 该动作对应的破坏性操作（用于查「要不要二次确认」）。`download` 不是破坏性操作。
    public static func destructiveAction(for state: ChapterDownloadState) -> DestructiveAction? {
        switch action(for: state) {
        case .download: return nil
        case .cancel: return .cancelDownload
        case .deleteArchive: return .deleteChapterArchive
        }
    }
}

// MARK: - 破坏性操作与二次确认

/// 会「失去点什么」的操作。
///
/// 这份清单是**唯一**的一份：界面不再各自决定「这个删除要不要问一下」，
/// 否则同类操作在两个页面会有两种行为（这正是交互清单第 11 节暴露的问题——
/// 下载页删归档要确认，作品详情页删归档不要）。
public enum DestructiveAction: String, CaseIterable, Sendable {
    /// 移出书架。
    case removeFromLibrary
    /// 删除分类。
    case deleteCategory
    /// 取消单个下载任务。
    case cancelDownload
    /// 取消全部下载任务。
    case cancelAllDownloads
    /// 删除单章归档。
    case deleteChapterArchive
    /// 删除某作品的全部归档。
    case deleteMangaArchives
    /// 清空全部归档。
    case deleteAllArchives
    /// 清除已结束的下载记录（不删文件）。
    case clearFinishedRecords
    /// 删除自建服务器（凭据要重填）。
    case deleteServer
    /// 删除源仓库（已安装的源保留）。
    case deleteRepository
    /// 清空诊断日志。
    case clearDiagnostics
    /// 清空封面缓存。
    case clearCoverCache
    /// 清空译文缓存。
    case clearTranslationCache
    /// 退出登录（本机会话，可恢复）。
    case signOut
    /// 注销账号（服务端删号，不可恢复）。
    case deleteAccount
    /// 清除某个源的登录状态（Cookie）。
    case clearSourceCookies
    /// 删除本地导入的文件（**删的是用户自己的文件**）。
    case deleteLocalBook
    /// 从备份恢复（会覆盖设置）。
    case restoreBackup
}

/// 「要不要二次确认」的单一事实来源。
///
/// 判定标准刻意不是「是不是删除」，而是**误触的代价**。四条任一成立即需确认：
///
/// | 判据 | 例子 |
/// |---|---|
/// | 丢用户数据 | 移出书架（**会一并丢掉阅读进度与分类归属**）、删除分类 |
/// | 要花钱才能恢复 | 清空译文缓存（云翻译按页扣额度） |
/// | 影响面 ≥ 2 个对象 | 取消全部下载、删除某作品全部归档、清空全部归档 |
/// | 销毁用户攒下来的离线数据 | 删除单章归档（网站在时能重下，站点没了就永久没了） |
///
/// 反过来，能「一键重来」的都不确认：取消单个任务、清除下载记录（不删文件）、
/// 清封面缓存（自动重建）、退出登录（同邮箱再登录）、清除源 Cookie（重新登录）。
/// 确认弹窗泛滥会让人闭眼点「确定」，那才是真的危险。
public enum DestructiveActionPolicy {

    public static func requiresConfirmation(_ action: DestructiveAction) -> Bool {
        switch action {
        case .removeFromLibrary,
             .deleteCategory,
             .cancelAllDownloads,
             .deleteChapterArchive,
             .deleteMangaArchives,
             .deleteAllArchives,
             .deleteServer,
             .clearTranslationCache,
             .deleteAccount,
             .deleteLocalBook,
             .restoreBackup:
            return true

        case .cancelDownload,
             .clearFinishedRecords,
             .deleteRepository,
             .clearDiagnostics,
             .clearCoverCache,
             .signOut,
             .clearSourceCookies:
            return false
        }
    }

    /// 该操作丢掉的东西是否**无法**恢复（用于界面文案的强弱）。
    ///
    /// 注意 `.removeFromLibrary` 是「部分不可恢复」：作品本身还能重新收藏，
    /// 但阅读进度与分类归属找不回来——所以它算 `false`，而**确认文案里必须说清**。
    /// `.deleteLocalBook` 与 `.deleteAccount` 才算真的回不去：
    /// 前者的文件是用户自己放进去的，删掉就没了（App 里没有回收站）。
    public static func isIrreversible(_ action: DestructiveAction) -> Bool {
        switch action {
        case .deleteAccount, .deleteLocalBook:
            return true
        case .removeFromLibrary,
             .deleteCategory,
             .cancelDownload,
             .cancelAllDownloads,
             .deleteChapterArchive,
             .deleteMangaArchives,
             .deleteAllArchives,
             .clearFinishedRecords,
             .deleteServer,
             .deleteRepository,
             .clearDiagnostics,
             .clearCoverCache,
             .clearTranslationCache,
             .signOut,
             .clearSourceCookies,
             .restoreBackup:
            return false
        }
    }

    /// 是否需要「输入的确认」（比点一下更强的确认，用于真正不可逆的操作）。
    public static func requiresTypedConfirmation(_ action: DestructiveAction) -> Bool {
        isIrreversible(action)
    }
}

// MARK: - 书架的筛选菜单

/// 书架分类筛选菜单里的一项（不含文案：标题由 App 层映射成 `L("…")`）。
///
/// 带 `Identifiable`：界面要用 `ForEach` 遍历它，而**元组没有 keypath**
/// （`ForEach(Array(….enumerated()), id: \.offset)` 编译不过），
/// 所以标识得由类型自己给出，而不是从外部拼。
public enum LibraryFilterTarget: Hashable, Identifiable, Sendable {
    case all
    case category(id: String, name: String)

    /// 用作 `ForEach` 的标识。分类用存储层给的 ID，`all` 用一个前缀固定的哨兵值
    /// ——两者不可能撞（分类 ID 是 UUID，不含 `#`）。
    public var id: String {
        switch self {
        case .all: return "#all"
        case let .category(id, _): return id
        }
    }
}

/// 筛选菜单的项与「分类被删之后选中项怎么办」。
public enum LibraryFilterMenu {

    /// 菜单项顺序：先是「全部作品」，然后是各分类（顺序取自存储层）。
    public static func targets(categories: [LibraryCategory]) -> [LibraryFilterTarget] {
        [.all] + categories.map { .category(id: $0.id, name: $0.name) }
    }

    /// 当前选中的分类还在不在？不在就退回「全部作品」。
    ///
    /// 分类可能在另一页被删掉（分类管理页），此时若继续按已删的 ID 过滤，
    /// 用户会停在一个空列表上，以为书架坏了。
    ///
    /// - Returns: 仍然有效的选中 ID；`nil` 表示应退回「全部作品」。
    public static func validSelection(_ selected: String?, categories: [LibraryCategory]) -> String? {
        guard let selected else { return nil }
        return categories.contains { $0.id == selected } ? selected : nil
    }
}
