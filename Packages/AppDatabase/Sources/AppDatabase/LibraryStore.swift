//
//  LibraryStore.swift
//  AppDatabase
//
//  书架持久化的**接口与数据契约**（不含实现细节）。
//
//  这样分层的好处：UI / 业务只依赖协议，将来若把 GRDB 换成别的实现，
//  调用方零改动；测试也可以用内存实现替身。
//

import Foundation
import AppCore

/// 书架排序方式。
public enum LibrarySortOrder: String, Sendable, CaseIterable {
    /// 最近阅读优先（从未读过的排在最后），其次按加入时间倒序。
    case lastRead
    /// 标题排序（大小写不敏感），其次是加入时间倒序。
    case title
    /// 最近加入优先。
    case recentlyAdded

    // 展示名不在这里：本包拿不到 App 目标的 `L()`。
    // 界面上的排序名称见 App 层 `Localization+Names.swift`（`localizedName`）。
}

/// 阅读历史条目。
///
/// `Codable`：历史以 JSON payload 落库（见 `DatabaseLibraryStore`）。
public struct ReadingHistoryEntry: Identifiable, Codable, Equatable, Sendable {
    /// 主键：`<mangaID>|<chapterID>`，同一章节只保留一条。
    public let id: String
    public let mangaID: String
    public let chapterID: String
    public var chapterName: String
    public var pageIndex: Int
    public var readAt: Date

    public init(
        mangaID: String,
        chapterID: String,
        chapterName: String = "",
        pageIndex: Int = 0,
        readAt: Date = Date()
    ) {
        self.id = ReadingHistoryEntry.makeID(mangaID: mangaID, chapterID: chapterID)
        self.mangaID = mangaID
        self.chapterID = chapterID
        self.chapterName = chapterName
        self.pageIndex = max(0, pageIndex)
        self.readAt = readAt
    }

    public static func makeID(mangaID: String, chapterID: String) -> String {
        "\(mangaID)|\(chapterID)"
    }
}

/// 书架存储错误。
public enum LibraryStoreError: Error, Equatable {
    /// 目标条目不存在（用于需要存在的操作）。
    case entryNotFound(String)
    /// 页码为负。
    case invalidPageIndex(Int)
    /// 数量参数越界（如 limit ≤ 0 之外的非法值）。
    case invalidLimit(Int)
    /// 数据库里的行不符合预期（列缺失 / 类型不符 / JSON 损坏）。
    case corruptRow(reason: String)
    /// 分类不存在。
    case categoryNotFound(String)
    /// 分类名重复（比较时忽略大小写与首尾空白）。
    case duplicateCategoryName(String)
    /// 分类名不合法（清洗后为空，或超出长度上限）。
    case invalidCategoryName(String)

    public var message: String {
        switch self {
        case let .entryNotFound(id): return Copy.format("error.library.entryNotFound", id)
        case let .invalidPageIndex(index): return Copy.format("error.library.invalidPageIndex", index)
        case let .invalidLimit(limit): return Copy.format("error.library.invalidLimit", limit)
        case let .corruptRow(reason): return Copy.format("error.library.corruptRow", reason)
        case let .categoryNotFound(id): return Copy.format("error.library.categoryNotFound", id)
        case let .duplicateCategoryName(name): return Copy.format("error.library.duplicateCategoryName", name)
        case let .invalidCategoryName(name): return Copy.format("error.library.invalidCategoryName", name)
        }
    }

    public var toAppError: AppError {
        switch self {
        case let .entryNotFound(id): return .notFound(Copy.format("error.library.payloadEntry", id))
        case let .invalidPageIndex(index): return .invalidInput(Copy.format("error.library.payloadPageIndex", index))
        case let .invalidLimit(limit): return .invalidInput(Copy.format("error.library.payloadLimit", limit))
        case let .corruptRow(reason): return .unknown(Copy.format("error.library.payloadCorruptRow", reason))
        case let .categoryNotFound(id): return .notFound(Copy.format("error.library.payloadCategory", id))
        case let .duplicateCategoryName(name): return .invalidInput(Copy.format("error.library.payloadDuplicateName", name))
        case let .invalidCategoryName(name): return .invalidInput(Copy.format("error.library.payloadInvalidName", name))
        }
    }
}

extension LibraryStoreError: LocalizedError {
    public var errorDescription: String? { message }
}

/// 书架存储抽象。
///
/// 约定：
/// - 所有方法都是**同步**的：GRDB 内部会处理并发，调用方（MainActor 的 UI）
///   应通过 `Task.detached` 或后台队列避免阻塞主线程；本层不做异步包装，
///   以免把并发策略写死在持久层。
/// - 写操作要么全成功，要么抛错且不留下部分写入（依赖事务）。
public protocol LibraryStoring: Sendable {

    // MARK: 书架

    /// 新增或整体更新一个条目（以 `manga.id` 为主键 upsert）。
    @discardableResult
    func save(_ entry: LibraryEntry) throws -> LibraryEntry

    /// 读取单个条目。
    func entry(mangaID: String) throws -> LibraryEntry?

    /// 列出条目。`categoryID` 为 nil 表示不过滤。
    func entries(sortedBy order: LibrarySortOrder, categoryID: String?) throws -> [LibraryEntry]

    /// 是否已收藏。
    func contains(mangaID: String) throws -> Bool

    /// 条目总数。
    func count() throws -> Int

    /// 移除条目（同时清掉它的阅读历史）。返回是否真的删除了。
    @discardableResult
    func remove(mangaID: String) throws -> Bool

    /// 清空书架（含历史）。返回删除的条目数。
    @discardableResult
    func removeAll() throws -> Int

    // MARK: 阅读进度

    /// 记录阅读位置：更新条目的进度字段，并写入/更新阅读历史。
    /// - Throws: `LibraryStoreError.invalidPageIndex`（负数）、`.entryNotFound`（条目不存在）
    func updateProgress(
        mangaID: String,
        chapterID: String,
        chapterName: String,
        pageIndex: Int,
        at date: Date
    ) throws

    // MARK: 组织

    /// 置顶 / 取消置顶。
    func setPinned(mangaID: String, isPinned: Bool) throws

    /// 设置分类（nil 表示移出分类）。
    func setCategory(mangaID: String, categoryID: String?) throws

    /// 设置未读数（负数按 0 处理）。
    func setUnreadCount(mangaID: String, count: Int) throws

    // MARK: 分类

    /// 分类列表（按 `sortOrder` 升序，其次按名称）。
    ///
    /// 分类是独立实体，因此**空分类也会出现**（用户新建后不会因没有作品而消失）。
    func categories() throws -> [LibraryCategory]

    /// 新建分类。
    /// - Throws: `.invalidCategoryName`（清洗后为空）、`.duplicateCategoryName`（重名）
    @discardableResult
    func createCategory(name: String) throws -> LibraryCategory

    /// 重命名分类。重命名不影响条目引用（`id` 不变）。
    /// - Throws: `.categoryNotFound`、`.invalidCategoryName`、`.duplicateCategoryName`
    @discardableResult
    func renameCategory(id: String, to name: String) throws -> LibraryCategory

    /// 删除分类：分类下的条目**移出分类但不删除**。返回受影响的条目数。
    /// - Throws: `.categoryNotFound`
    @discardableResult
    func deleteCategory(id: String) throws -> Int

    /// 按给定顺序重排分类；未出现在列表里的分类保持相对顺序并排在后面。
    func reorderCategories(_ orderedIDs: [String]) throws

    // MARK: 阅读历史

    /// 记录一条历史（同一 作品+章节 覆盖更新）。
    func recordHistory(
        mangaID: String,
        chapterID: String,
        chapterName: String,
        pageIndex: Int,
        at date: Date
    ) throws

    /// 最近的阅读历史（按时间倒序）。
    /// - Throws: `LibraryStoreError.invalidLimit`
    func recentHistory(limit: Int) throws -> [ReadingHistoryEntry]

    /// 某个作品的历史（按时间倒序）。
    func history(mangaID: String) throws -> [ReadingHistoryEntry]

    /// 删除某条历史。返回是否删除成功。
    @discardableResult
    func removeHistory(mangaID: String, chapterID: String) throws -> Bool

    /// 清空历史。返回删除条数。
    @discardableResult
    func clearHistory() throws -> Int

    /// 只保留最近 `keep` 条历史，返回清理条数。
    @discardableResult
    func pruneHistory(keep: Int) throws -> Int
}
